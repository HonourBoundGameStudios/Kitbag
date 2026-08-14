-- KitbagImport — PURE: read another addon's saved sets into Kitbag's shape.
--
-- Takes the table the other addon's SavedVariables already put in the global environment and returns
-- plain Kitbag sets plus a report of what it did. No client calls and no writes: the caller decides
-- what to keep. That split is what lets the whole conversion be tested against real ItemRack data
-- outside the game — see Tests/import_test.lua.
--
-- Someone importing is handing over gear sets they have curated for years. The rules that follow
-- from that: never overwrite a set they already have, never invent a "strip this slot" instruction
-- from data we failed to read, and account for everything skipped rather than quietly dropping it.

Kitbag = Kitbag or {}

local Core = Kitbag.Core

local Import = {}

-- ItemRack keeps its own scratch sets in the same table as the user's, prefixed with "~"
-- (~CombatQueue, ~Unequip). They are on every character and are not sets anyone made.
local INTERNAL_PREFIX = "~"

--- Convert one ItemRack `equip` array into Kitbag `slots`.
--
-- ItemRack indexes it by inventory slot id and only lists the slots the set manages, so:
--   a string  -> the item, reduced to a Kitbag key
--   0         -> `false`, deliberately empty (ItemRack's AllowEmpty) — the one case that strips
--   absent    -> absent, meaning "don't touch this slot"
--   unreadable-> absent, and counted. Guessing `false` here would undress the wearer.
--
-- Only the 19 real slots are read. Real files carry `[0] = 0`, so anything walking this table with
-- ipairs or # reads it wrong.
local function slotsFrom(equip)
    local slots, count, unreadable = {}, 0, 0

    for _, s in ipairs(Core.SLOTS) do
        local entry = equip[s.id]
        if entry == 0 then
            slots[s.id], count = false, count + 1
        elseif type(entry) == "string" then
            local key = Core.ItemKey(entry)
            if key then
                slots[s.id], count = key, count + 1
            else
                unreadable = unreadable + 1
            end
        end
    end

    return slots, count, unreadable
end

--- Read an `ItemRackUser` table into Kitbag sets.
--
--   user     : the ItemRackUser global, or nil if that addon was never installed
--   existing : the sets Kitbag already has, so a name clash can be refused rather than overwrite
--
-- Returns { sets = { [name] = set }, imported = n, unreadable = n, skipped = { {name=, why=} } }
-- with `skipped` sorted by name so the report reads the same every time. Nothing here can error on
-- malformed input: this runs against a global another addon wrote, and a bad import must not take
-- Kitbag down at login.
function Import.FromItemRack(user, existing)
    local out = { sets = {}, imported = 0, unreadable = 0, skipped = {} }

    local sets = type(user) == "table" and type(user.Sets) == "table" and user.Sets
    if not sets then return out end

    local function skip(name, why)
        out.skipped[#out.skipped + 1] = { name = name, why = why }
    end

    for name, set in pairs(sets) do
        if type(name) ~= "string" or name == "" then          -- nothing to call it: not importable
            -- deliberately silent; there is no name to report it under
        elseif string.sub(name, 1, 1) == INTERNAL_PREFIX then
            skip(name, "internal")
        elseif type(set) ~= "table" or type(set.equip) ~= "table" then
            skip(name, "malformed")
        elseif existing and existing[name] then
            skip(name, "exists")
        else
            local slots, count, unreadable = slotsFrom(set.equip)
            out.unreadable = out.unreadable + unreadable
            if count == 0 then
                skip(name, "empty")
            else
                out.sets[name] = {
                    name = name, slots = slots, icon = set.icon,
                    -- COMPAT-5: ItemRack's per-set keybinding. Carried on the set; binding it is
                    -- the client's job, not this file's.
                    key = type(set.key) == "string" and set.key ~= "" and set.key or nil,
                }
                out.imported = out.imported + 1
            end
        end
    end

    table.sort(out.skipped, function(a, b) return a.name < b.name end)
    return out
end

--- Is there anything worth offering to import? (UI-18)
--
-- Returns { count = n } when pressing Import would actually bring sets across, and nil otherwise —
-- so the window's button can hide rather than sit there permanently offering a migration that has
-- already happened. The rule is deliberately the strict one: a name clash is NOT an offer, because
-- importing over it is refused by design and the button would do nothing but re-report the clash.
--
-- This is `FromItemRack` run as a dry run — it writes nothing, and the caller throws the sets away.
-- Asking the same function the import itself uses is what stops the button and `/kit import` from
-- disagreeing about whether there is anything left to do.
function Import.Offer(user, existing)
    local result = Import.FromItemRack(user, existing)
    if result.imported == 0 then return nil end
    return { count = result.imported }
end

-- ---------------------------------------------------------------------------
-- Options and keybindings (COMPAT-5)
-- ---------------------------------------------------------------------------

-- Which ItemRack settings have a Kitbag equivalent, and which way round. Everything absent from this
-- table is deliberately not imported: most of ItemRack's options configure a UI Kitbag does not
-- have, and a setting that half-transfers is worse than one that plainly did not.
--
-- `invert` covers the pairs that are stored the opposite way up — ItemRack asks whether to SHOW the
-- minimap button, Kitbag stores whether to HIDE it.
local OPTION_MAP = {
    EnableEvents      = { path = "autoSwap" },
    ShowMinimap       = { path = "minimap.hide", invert = true },
    EnableTrinketMenu = { path = "trinkets.hide", invert = true },
}

--- Read an `ItemRackSettings` table into { [kitbagOptionPath] = value }.
--
-- ItemRack stores "ON"/"OFF" strings. An option it never stored is ABSENT from the result rather
-- than false: ItemRack omits a setting sitting at its own default, and reading that as OFF would
-- quietly turn auto-swap off for everyone who never touched it.
function Import.OptionsFromItemRack(settings)
    local out = {}
    if type(settings) ~= "table" then return out end

    for key, mapping in pairs(OPTION_MAP) do
        local raw = settings[key]
        if raw ~= nil then
            local on = raw == "ON" or raw == true or raw == 1
            -- Spelled out: `invert and not on or on` collapses to `on` whenever `not on` is false,
            -- which is exactly the half of the truth table the inversion exists for.
            if mapping.invert then on = not on end
            out[mapping.path] = on
        end
    end

    return out
end

--- Work out which keybindings can actually be applied, and which cannot.
--
-- Returns { bind = { { key =, set = } }, conflicts = { { key =, set = } } }, ordered by key so the
-- result is the same every time. Two sets on one key is authorable in ItemRack and cannot be
-- honoured; the contest is settled by set name — arbitrary, but stable and explainable — and the
-- loser is reported rather than silently dropped.
function Import.BindingPlan(sets)
    local claims = {}
    if type(sets) == "table" then
        for name, set in pairs(sets) do
            if type(set) == "table" and type(set.key) == "string" and set.key ~= "" then
                local claim = claims[set.key]
                if not claim or name < claim then claims[set.key] = name end
            end
        end
    end

    local bind, conflicts = {}, {}
    for key, winner in pairs(claims) do
        bind[#bind + 1] = { key = key, set = winner }
    end
    for name, set in pairs(sets or {}) do
        if type(set) == "table" and type(set.key) == "string" and set.key ~= ""
            and claims[set.key] ~= name then
            conflicts[#conflicts + 1] = { key = set.key, set = name }
        end
    end

    table.sort(bind, function(a, b) return a.key < b.key end)
    table.sort(conflicts, function(a, b) return a.set < b.set end)
    return { bind = bind, conflicts = conflicts }
end

Kitbag.Import = Import
return Import
