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
                out.sets[name] = { name = name, slots = slots, icon = set.icon }
                out.imported = out.imported + 1
            end
        end
    end

    table.sort(out.skipped, function(a, b) return a.name < b.name end)
    return out
end

Kitbag.Import = Import
return Import
