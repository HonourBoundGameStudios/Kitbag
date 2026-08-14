-- KitbagCore — PURE: item identity, set capture, and the equip planner.
--
-- Nothing in here touches the WoW API. It takes plain tables describing the world and returns a
-- plain, ordered plan; KitbagEquip is the only file allowed to carry that plan out against the
-- client. That split is the whole point: an equip planner that lives inside the client can only be
-- tested by wearing the bug, and "it half-applied my set" is the single most common thing people
-- report about gear managers.
--
-- Tested by Tests/core_test.lua, which runs under plain Lua 5.1 outside the game.

-- One namespace global (Code Style: prefix any unavoidable global with the addon name). The
-- addon-private `...` table can't be shared with Tests/, which loads each module with dofile().
Kitbag = Kitbag or {}

local Core = {}

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------
-- The 19 equippable inventory slots, in paperdoll reading order. `key` is the stable token the
-- SavedVariables and the UI use; `label` is what a human sees. Ids are Blizzard's and never change.

Core.SLOTS = {
    { id = 1,  key = "HEAD",     label = "Head" },
    { id = 2,  key = "NECK",     label = "Neck" },
    { id = 3,  key = "SHOULDER", label = "Shoulder" },
    { id = 4,  key = "SHIRT",    label = "Shirt" },
    { id = 5,  key = "CHEST",    label = "Chest" },
    { id = 6,  key = "WAIST",    label = "Waist" },
    { id = 7,  key = "LEGS",     label = "Legs" },
    { id = 8,  key = "FEET",     label = "Feet" },
    { id = 9,  key = "WRIST",    label = "Wrist" },
    { id = 10, key = "HANDS",    label = "Hands" },
    { id = 11, key = "FINGER1",  label = "Ring 1" },
    { id = 12, key = "FINGER2",  label = "Ring 2" },
    { id = 13, key = "TRINKET1", label = "Trinket 1" },
    { id = 14, key = "TRINKET2", label = "Trinket 2" },
    { id = 15, key = "BACK",     label = "Back" },
    { id = 16, key = "MAINHAND", label = "Main hand" },
    { id = 17, key = "OFFHAND",  label = "Off hand" },
    { id = 18, key = "RANGED",   label = "Ranged" },
    { id = 19, key = "TABARD",   label = "Tabard" },
}

Core.MAINHAND, Core.OFFHAND = 16, 17

local byId = {}
for _, s in ipairs(Core.SLOTS) do byId[s.id] = s end

--- The slot record for an inventory slot id, or nil if the id isn't an equippable slot.
-- Returns nil rather than erroring: slot ids arrive from saved data and from the client, and a
-- stale one should be skippable, not fatal.
function Core.SlotById(id)
    return byId[id]
end

-- ---------------------------------------------------------------------------
-- Item identity
-- ---------------------------------------------------------------------------

--- Reduce an item link (or a bare item id) to the identity a set compares by.
--
-- Two Thunderfuries are not interchangeable if one is enchanted and one is not, so identity carries
-- the enchant, the four gem sockets and the suffix — but deliberately NOT the uniqueId or the link
-- level, which differ between two genuinely identical copies and would make a set unmatchable.
-- Returns nil for an empty slot; an empty slot has no identity and should not be a magic string.
function Core.ItemKey(link)
    if link == nil then return nil end
    if type(link) == "number" then link = tostring(link) end
    if type(link) ~= "string" or link == "" then return nil end

    local body = string.match(link, "item:([%-%d:]*)")
    if not body then
        -- No "item:" prefix: a bare id, one of ItemKey's own keys, or an ItemRack SavedVariables
        -- string ("22196:1891:::::::60::::::::::" — empty fields, not zeros). Accepting the
        -- colon-delimited form is what makes ItemKey idempotent, so re-normalising stored data is
        -- safe rather than silently turning every item into nil.
        body = string.match(link, "^%s*([%-%d][%-%d:]*)%s*$")
        if not body then return nil end
    end

    local f = {}
    for part in string.gmatch(body .. ":", "([^:]*):") do f[#f + 1] = part end
    local function num(i) return tonumber(f[i]) or 0 end

    local id = num(1)
    if id == 0 then return nil end
    return string.format("%d:%d:%d:%d:%d:%d:%d", id, num(2), num(3), num(4), num(5), num(6), num(7))
end

--- The numeric item id back out of a key — for GetItemInfo, icons, and tooltips.
function Core.ItemId(key)
    if type(key) ~= "string" then return nil end
    return tonumber(string.match(key, "^(%d+)"))
end

-- ---------------------------------------------------------------------------
-- Sets
-- ---------------------------------------------------------------------------

--- The name a set will actually be stored under, or nil if it is not a usable name.
--
-- There is more than one door into creating a set — saving what you are wearing, starting an empty
-- one, the slash command — and the stored name is the identity everything else keys off: the set
-- list, `parent`, the macro, the keybinding. A name trimmed at one door and not at another produces
-- "Tank" and "Tank " sitting side by side in the list looking identical, and no way to tell which
-- one a rule is pointing at. One function so that cannot happen.
function Core.CleanName(name)
    if type(name) ~= "string" then return nil end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return nil end
    return name
end

--- Capture what is currently worn as a named set.
--
-- Every slot is recorded, and an empty one records as `false` — "deliberately empty" — rather than
-- being left out. Leaving it out would mean "ignore this slot", and a set saved bare-headed that
-- then refuses to take your helmet off is not the set you saved.
function Core.CaptureSet(equipped, name)
    assert(type(equipped) == "table", "CaptureSet: equipped must be a table of [slotId] = itemKey")
    assert(type(name) == "string" and name ~= "", "CaptureSet: a set must be named")

    local slots = {}
    for _, s in ipairs(Core.SLOTS) do
        slots[s.id] = equipped[s.id] or false
    end
    return { name = name, slots = slots }
end

--- Flatten a set and its ancestors into one outfit the planner can take (CORE-3).
--
-- A set may name a `parent`, in which case it stores only what differs: "Raid Fire" is "Raid" with
-- two pieces changed. The nearest declaration of a slot wins, so a child overrides its parent and a
-- parent overrides a grandparent. `false` is a value like any other here — "Raid, but no shield"
-- must be sayable, or the only way to express it is to duplicate the whole outfit, which is the
-- thing inheritance exists to stop.
--
-- Returns a NEW table; the stored delta is never mutated. Returns nil if `name` names no set.
function Core.Resolve(sets, name)
    if type(sets) ~= "table" then return nil end
    local set = sets[name]
    if type(set) ~= "table" then return nil end

    -- Walk up first, then apply back down, so the nearest ancestor is written last and wins.
    -- `seen` both terminates a hand-edited cycle and stops a diamond being applied twice: an addon
    -- that hangs the client on login is worse than any wrong outfit.
    local chain, seen, cursor = {}, {}, set
    while type(cursor) == "table" and not seen[cursor] do
        seen[cursor] = true
        chain[#chain + 1] = cursor
        -- A parent that no longer exists contributes nothing. Deleting a set someone forgot was a
        -- parent should cost the inherited pieces, never the whole child.
        cursor = cursor.parent and sets[cursor.parent] or nil
    end

    local slots = {}
    for i = #chain, 1, -1 do
        for slotId, key in pairs(chain[i].slots or {}) do
            slots[slotId] = key
        end
    end

    return { name = set.name or name, icon = set.icon, slots = slots }
end

--- Reduce a full capture to only what its parent does not already say.
--
-- This is what turns "save what I'm wearing" into a delta: capture records all nineteen slots, and
-- everything the parent already gets right is redundant duplication that will drift out of step the
-- first time the parent is re-enchanted.
function Core.Diff(set, parent)
    assert(type(set) == "table" and type(set.slots) == "table", "Diff: set must be a table with .slots")

    local slots = {}
    local base = parent and parent.slots or {}
    for slotId, key in pairs(set.slots) do
        if base[slotId] ~= key then slots[slotId] = key end
    end

    return { name = set.name, icon = set.icon, parent = set.parent, slots = slots }
end

-- How far up a chain is worth walking. `Resolve` terminates on a cycle by remembering what it has
-- visited; these two walk by key rather than by table, since `parent` points at a key and the two can
-- drift apart in hand-edited SavedVariables. A hop count is the cheaper guard for that.
local MAX_HOPS = 64

--- Does `name` inherit from `ancestor`, directly or through a chain?
--
-- The question a new parent has to answer before it is accepted: pointing a set at one of its own
-- descendants closes a cycle. `Resolve` would survive that — it terminates — but the outfit it
-- produced would depend on where you started reading, which is exactly the unpredictability
-- inheritance exists to remove.
function Core.Descends(sets, name, ancestor)
    if type(sets) ~= "table" then return false end

    local cursor, hops = sets[name], 0
    while type(cursor) == "table" and cursor.parent and hops < MAX_HOPS do
        if cursor.parent == ancestor then return true end
        cursor = sets[cursor.parent]
        hops = hops + 1
    end
    return false
end

--- The sets that may legally become `name`'s parent, sorted (UI-11).
--
-- A menu has to know this before it is drawn: offering a choice that will then be refused is worse
-- than not offering it, because the refusal arrives after the click. The current parent is included
-- so the menu can tick it.
function Core.ParentChoices(sets, name)
    local choices = {}
    if type(sets) ~= "table" or type(sets[name]) ~= "table" then return choices end

    for key in pairs(sets) do
        if key ~= name and not Core.Descends(sets, key, name) then
            choices[#choices + 1] = key
        end
    end
    table.sort(choices)
    return choices
end

--- Put one item in one slot of a set, or take the slot out of it entirely (UI-14).
--
-- The three states a slot can be in are the whole of this function, and the difference between the
-- last two is the one that gets built wrong:
--
--   key    an item — the set puts this on
--   false  deliberately empty — the set takes off whatever is there
--   nil    absent — the set has no opinion and you keep wearing what you have
--
-- Capture writes `false` for every empty slot precisely so that a set saved bare-headed removes your
-- helmet, which means "drop this slot" cannot be spelled the same way as "empty this slot". For a
-- set stored as a delta, absence also means "let the parent decide" — Resolve already reads it that
-- way, so dropping a slot and inheriting it are the same write.
--
-- Mutates `set` and returns whether anything actually changed, so a caller can skip a redraw. An
-- unknown slot id or an unreadable item is refused rather than stored: both arrive from the client
-- and from saved data, and a key nothing can ever match would read in the window as an item you have
-- lost rather than as a slot that was never set.
function Core.SetSlot(set, slotId, key)
    if type(set) ~= "table" then return false end
    if not Core.SlotById(slotId) then return false end

    if key ~= nil and key ~= false then
        key = Core.ItemKey(key)
        if not key then return false end
    end

    set.slots = set.slots or {}
    if set.slots[slotId] == key then return false end
    set.slots[slotId] = key
    return true
end

--- What re-capturing over an existing set would throw away (BUG-3).
--
--   set      : the set as it stands, RESOLVED — { slots = { [slotId] = key | false } }
--   equipped : what is on the player now — { [slotId] = key }
--
-- Returns an array of { slot = id, key = key }, in slot order, one per slot the save would drop.
--
-- Overwriting a set with what you are wearing is the ordinary way to keep it current, so this must
-- not report an ordinary save. A slot counts as lost only when the set names an item that the
-- capture does not hold in ANY slot: that item is somewhere the capture cannot see — the bank, an
-- alt, a hand-picked choice — and once the save lands, nothing in the addon knows it was ever there.
-- An item that merely moved slots is still in the capture and is not a loss, or every trinket swap
-- would raise a prompt and the prompt would stop being read.
--
-- `false` is not a loss either. "Deliberately empty" is a decision the capture can restate; it is
-- not a piece of gear that goes missing.
function Core.SaveLoss(set, equipped)
    local lost = {}
    if type(set) ~= "table" or type(set.slots) ~= "table" then return lost end

    local held = {}
    for _, key in pairs(equipped or {}) do
        if key then held[key] = true end
    end

    -- Walked over SLOTS rather than over set.slots: pairs() has no order, and a prompt that lists
    -- the same two slots in a different order each time cannot be read at a glance.
    for _, s in ipairs(Core.SLOTS) do
        local key = set.slots[s.id]
        if key and not held[key] then
            lost[#lost + 1] = { slot = s.id, key = key }
        end
    end

    return lost
end

--- How good a set is and how close it is to breaking (CORE-4).
--
--   set  : { slots = { [slotId] = key | false } }
--   info : { [itemKey] = { level = n, durability = 0..1 | nil } }
--
-- Returns { items, known, complete, level, durability, broken }.
--
-- Two deliberate choices. The average item level is taken over the items the client could actually
-- answer for, and `complete` says whether that was all of them — GetItemInfo returns nil constantly
-- on a fresh login, and averaging an unknown in as zero would show a raid set as green trash.
-- Durability is the WEAKEST piece rather than the average, because a set is only as wearable as the
-- item that is about to break, and an average happily hides one dead piece behind seventeen fresh ones.
function Core.Totals(set, info)
    assert(type(set) == "table" and type(set.slots) == "table", "Totals: set must be a table with .slots")
    info = info or {}

    local items, known, sum = 0, 0, 0
    local weakest, broken = nil, 0

    for _, s in ipairs(Core.SLOTS) do
        local key = set.slots[s.id]
        -- `false` is a slot the set deliberately empties. It is not an item and must not be averaged
        -- in as item level 0.
        if type(key) == "string" then
            items = items + 1
            local fact = info[key]
            if fact and fact.level then
                known = known + 1
                sum = sum + fact.level
            end
            if fact and fact.durability then
                if not weakest or fact.durability < weakest then weakest = fact.durability end
                if fact.durability <= 0 then broken = broken + 1 end
            end
        end
    end

    return {
        items = items,
        known = known,
        complete = known == items,
        level = known > 0 and (sum / known) or nil,
        durability = weakest,
        broken = broken,
    }
end

-- ---------------------------------------------------------------------------
-- Action-bar macros (UI-8)
-- ---------------------------------------------------------------------------
--
-- An addon cannot put a button on the action bar. What it can do is make a macro and hand it to the
-- cursor, which is what dragging a set off the list does.

local MACRO_PREFIX = "Kit: "
local MACRO_LIMIT = 16          -- the client's cap on a macro name

--- A macro name for a set, unique against `taken` and short enough for the client to accept.
--
-- The front of the name is kept, because that is the part that identifies the set. `taken` is the
-- set of names OTHER sets already hold — two long set names truncating identically would otherwise
-- silently share one macro, and dragging the second would repoint the first.
function Core.MacroName(setName, taken)
    taken = taken or {}

    local base = MACRO_PREFIX .. tostring(setName)
    if #base <= MACRO_LIMIT and not taken[base] then return base end

    local trimmed = string.sub(base, 1, MACRO_LIMIT)
    if not taken[trimmed] then return trimmed end

    -- Replace the last character rather than appending: there is no room to append.
    for suffix = 2, 9 do
        local candidate = string.sub(base, 1, MACRO_LIMIT - 1) .. suffix
        if not taken[candidate] then return candidate end
    end
    return trimmed
end

--- The macro body that equips a set. `/kit equip` takes the rest of the line, so a name with spaces
-- in it needs no quoting.
function Core.MacroBody(setName)
    return "/kit equip " .. tostring(setName)
end

--- A plan as slot-by-slot lines, for the tooltip that previews it (UI-6).
--
-- Returns { { slot = "Off hand", verb = "take off", key = …, from = "Ring 2" }, … } in the plan's
-- own order, with the things it could not do on the end.
--
-- Built from the plan rather than re-derived from the set, so what the tooltip promises and what the
-- driver does cannot drift apart — they are the same list. The item names are left to the caller,
-- because only the client knows them.
function Core.Explain(plan)
    local lines = {}
    if type(plan) ~= "table" then return lines end

    local function label(slotId)
        local s = Core.SlotById(slotId)
        return s and s.label or ("slot " .. tostring(slotId))
    end

    for _, action in ipairs(plan.actions or {}) do
        if action.kind == "unequip" then
            lines[#lines + 1] = { slot = label(action.to), verb = "take off", key = action.key }
        elseif action.from and action.from.equipped then
            lines[#lines + 1] = {
                slot = label(action.to), verb = "move from", key = action.key,
                from = label(action.from.equipped),
            }
        else
            lines[#lines + 1] = { slot = label(action.to), verb = "put on", key = action.key }
        end
    end

    for _, miss in ipairs(plan.missing or {}) do
        lines[#lines + 1] = {
            slot = label(miss.slot),
            verb = miss.where == "bank" and "in your bank" or "not found",
            key = miss.key,
            missing = true,
        }
    end

    return lines
end

-- ---------------------------------------------------------------------------
-- The paperdoll view of a set (UI-13)
-- ---------------------------------------------------------------------------

--- Where each slot sits on the doll, in Blizzard's own arrangement.
--
-- Data rather than nineteen hand-placed SetPoints, because that grid fails silently: a slot listed
-- twice draws over itself and a slot forgotten simply is not there, and neither reads as a bug until
-- someone goes looking for their off hand. As a table it is one assertion in the test suite.
Core.DOLL_LAYOUT = {
    left   = { 1, 2, 3, 15, 5, 4, 19, 9 },      -- head down to wrist, cloak and shirt among them
    right  = { 10, 6, 7, 8, 11, 12, 13, 14 },   -- hands down to feet, then rings and trinkets
    bottom = { 16, 17, 18 },                    -- the weapons, in a row of their own
}

--- One cell per equippable slot: { [slotId] = { slot = <record>, key = …, state = "worn" } }.
--
-- The state is read out of the PLAN, never re-derived from the set, for the same reason Explain is:
-- the panel and the driver must not be able to disagree about what is about to happen. `key` is what
-- the slot will hold *afterwards* — nil where the set says nothing, false where it ends empty.
--
-- The states, and why each is worth its own word:
--   unset   the set never mentions this slot, so it keeps whatever you are wearing
--   worn    the set's item is already on — nothing to do
--   swap    the plan will put the item in
--   clear   the slot ends empty, whether the set asked for that or a two-hander forced it
--   bank    the item exists but is at the bank, which is a walk, not a loss
--   missing the item is nowhere
--   unknown there is no plan yet, so there is no verdict — and "worn" would be a guess
function Core.Doll(set, plan)
    local slots = (type(set) == "table" and set.slots) or {}
    local cells = {}

    local acting, absent = {}, {}
    if type(plan) == "table" then
        for _, action in ipairs(plan.actions or {}) do acting[action.to] = action end
        for _, miss in ipairs(plan.missing or {}) do absent[miss.slot] = miss end
    end

    for _, s in ipairs(Core.SLOTS) do
        local key, state = slots[s.id], nil
        local miss, action = absent[s.id], acting[s.id]

        if miss then
            -- Keep the item on the cell: a slot you cannot fill is far more useful greyed out
            -- holding the thing you are missing than blank.
            state, key = (miss.where == "bank") and "bank" or "missing", miss.key
        elseif action then
            -- An unequip can land on a slot the set never named — freeing the off hand for a
            -- two-hander is the common one — so the plan, not the set, decides this cell.
            if action.kind == "unequip" then
                state, key = "clear", false
            else
                state, key = "swap", action.key
            end
        elseif key == nil then
            state = "unset"
        elseif key == false then
            state = "clear"
        elseif not plan then
            state = "unknown"
        else
            state = "worn"
        end

        cells[s.id] = { slot = s, key = key, state = state }
    end

    return cells
end

-- ---------------------------------------------------------------------------
-- Where an item can go (UI-5)
-- ---------------------------------------------------------------------------
--
-- The client hands out an equip-location token and leaves you to know what it means. This is that
-- knowledge, in one table, so the paperdoll flyouts and anything else that asks "what fits here"
-- agree — and so it can be checked without a game.
local FITS = {
    INVTYPE_HEAD            = { 1 },
    INVTYPE_NECK            = { 2 },
    INVTYPE_SHOULDER        = { 3 },
    INVTYPE_BODY            = { 4 },        -- the shirt
    INVTYPE_CHEST           = { 5 },
    INVTYPE_ROBE            = { 5 },        -- a chest piece under a second token
    INVTYPE_WAIST           = { 6 },
    INVTYPE_LEGS            = { 7 },
    INVTYPE_FEET            = { 8 },
    INVTYPE_WRIST           = { 9 },
    INVTYPE_HAND            = { 10 },
    INVTYPE_FINGER          = { 11, 12 },
    INVTYPE_TRINKET         = { 13, 14 },
    INVTYPE_CLOAK           = { 15 },
    INVTYPE_WEAPON          = { 16, 17 },   -- a one-hander goes in either hand
    INVTYPE_2HWEAPON        = { 16 },
    INVTYPE_WEAPONMAINHAND  = { 16 },
    INVTYPE_WEAPONOFFHAND   = { 17 },
    INVTYPE_SHIELD          = { 17 },
    INVTYPE_HOLDABLE        = { 17 },
    INVTYPE_RANGED          = { 18 },
    INVTYPE_RANGEDRIGHT     = { 18 },
    INVTYPE_THROWN          = { 18 },
    INVTYPE_RELIC           = { 18 },
    INVTYPE_TABARD          = { 19 },
}

local NO_SLOTS = {}

--- The inventory slots an item with this equip location can occupy. Empty for anything that is not
-- equippable gear — including nil, which is what an uncached item reads as.
function Core.SlotsFor(equipLocation)
    return FITS[equipLocation] or NO_SLOTS
end

--- Everything you own that could go in this slot.
--
--   equipped  : { [slotId] = itemKey }
--   where     : { [itemKey] = { bag =, slot = } }        unworn copies
--   locations : { [itemKey] = "INVTYPE_…" }              what the client says each one is
--   exclude   : an item key to leave out, or nil for the whole wardrobe
--
-- Returns an ordered list of { key, bag, slot, worn }, sorted by key so the list does not reshuffle
-- itself between two openings. `worn` is the slot an entry is currently worn in, if any.
--
-- Two callers ask this with different exclusions, and the difference is the question each is asking.
-- The flyout on the character sheet asks "what else could I be wearing here", so it takes out what
-- is already on — offering it would be an entry that does nothing. The set editor asks "what should
-- this set put here", where the item on your body is the most likely answer of all, because building
-- a set is usually wearing what you want and changing two pieces. One function with the exclusion
-- passed in, so the fitting rules cannot drift apart between the two panels.
function Core.Choices(slotId, equipped, where, locations, exclude)
    equipped, where, locations = equipped or {}, where or {}, locations or {}

    local function fits(key)
        for _, id in ipairs(Core.SlotsFor(locations[key])) do
            if id == slotId then return true end
        end
        return false
    end

    local byKey = {}
    for key, at in pairs(where) do
        if key ~= exclude and fits(key) then
            byKey[key] = { key = key, bag = at.bag, slot = at.slot, bank = at.bank }
        end
    end
    for id, key in pairs(equipped) do
        -- A worn copy beats a bagged one: moving it is a single slot-to-slot swap, where fetching
        -- from the bag would take the worn one off first. Identical keys are the same item by
        -- definition — the key carries the enchant and the gems — so this loses nothing.
        if key ~= exclude and fits(key) then byKey[key] = { key = key, worn = id } end
    end

    local found = {}
    for _, entry in pairs(byKey) do found[#found + 1] = entry end
    table.sort(found, function(a, b) return a.key < b.key end)
    return found
end

--- The flyout's contents (UI-5): everything that fits, other than what is in the slot already.
function Core.Alternatives(slotId, equipped, where, locations)
    equipped = equipped or {}
    return Core.Choices(slotId, equipped, where, locations, equipped[slotId])
end

-- Which item best identifies a set, for the icon a set without one borrows (UI-4).
--
-- The weapon first: "Fishing" is the pole, "Tank" is the mace, and the hands are what a player
-- pictures when they name a set. Then the big obvious armour, then whatever the set happens to name,
-- in slot order — a stable answer matters more than a clever one, because an icon that changes
-- between two openings of the window makes the list unreadable.
local ICON_PREFERENCE = { 16, 18, 17, 1, 5, 3, 7 }

--- The item key whose icon should stand in for this set, or nil if the set equips nothing.
function Core.IconItem(set)
    if type(set) ~= "table" or type(set.slots) ~= "table" then return nil end

    for _, slotId in ipairs(ICON_PREFERENCE) do
        if type(set.slots[slotId]) == "string" then return set.slots[slotId] end
    end
    for _, s in ipairs(Core.SLOTS) do
        if type(set.slots[s.id]) == "string" then return set.slots[s.id] end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The planner
-- ---------------------------------------------------------------------------

--- Work out the ordered moves that turn what you're wearing into the set you asked for.
--
--   equipped : { [slotId] = itemKey }                   what is worn right now
--   set      : { slots = { [slotId] = key | false } }   false = empty it; absent = don't touch it
--   where    : { [itemKey] = { bag = b, slot = s, bank = bool } }  where an unworn copy can be found
--   meta     : { twoHand = { … }, bankOpen = bool }     facts only the client knows
--
-- Returns { actions = {…}, missing = {…}, atBank = n, empty = bool }, where each action is one of
--   { kind = "equip",   from = { bag = b, slot = s } | { equipped = slotId }, to = slotId, key = k }
--   { kind = "unequip", to = slotId, key = k }
--
-- The planner simulates its own effects as it walks the slots, which is what makes the ring and
-- trinket shuffle come out right: moving the ring you want from slot 12 onto slot 11 swaps both
-- rings at once, so by the time slot 12 is considered it is already correct and needs no move.
-- Resolving each slot against the original state instead — the obvious implementation — emits a
-- second move that undoes the first.
function Core.Plan(equipped, set, where, meta)
    assert(type(equipped) == "table", "Plan: equipped must be a table of [slotId] = itemKey")
    assert(type(set) == "table" and type(set.slots) == "table", "Plan: set must be a table with .slots")
    where = where or {}
    meta = meta or {}
    local twoHand = meta.twoHand or {}

    -- A bank sighting is a real answer to "where is it" but not a usable source while the bank
    -- window is shut: PickupContainerItem on a bank bag simply does nothing then, and a plan built
    -- on one would fail every retry and report as stuck. So the location is remembered and the item
    -- is treated as out of reach until the player is standing at the bank.
    local bankOpen = meta.bankOpen and true or false
    local function reachable(at)
        if not at then return nil end
        if at.bank and not bankOpen then return nil end
        return at
    end

    for slotId in pairs(set.slots) do
        assert(byId[slotId], "Plan: set names unknown inventory slot " .. tostring(slotId))
    end

    -- Working copy of the world, mutated as each action is planned.
    local cur = {}
    for slotId, key in pairs(equipped) do cur[slotId] = key end

    local actions, missing = {}, {}
    local atBank = 0

    -- Taking something off needs somewhere to put it (CORE-5). Only an unequip does: equipping from
    -- a bag is a swap, and the worn item lands in the slot the new one came from. Counting those
    -- would refuse perfectly possible swaps on a nearly full bag.
    local needsBagSlots = 0

    local function unequip(slotId)
        actions[#actions + 1] = { kind = "unequip", to = slotId, key = cur[slotId] }
        cur[slotId] = nil
        needsBagSlots = needsBagSlots + 1
    end

    -- Which equipped slot currently holds this item, ignoring `except`.
    local function wornIn(key, except)
        for _, s in ipairs(Core.SLOTS) do
            if s.id ~= except and cur[s.id] == key then return s.id end
        end
        return nil
    end

    -- Walk in slot order, not pairs() order: the plan a player sees must be the same every time.
    for _, s in ipairs(Core.SLOTS) do
        local slotId = s.id
        local want = set.slots[slotId]

        if want == nil then
            -- The set doesn't mention this slot. A set is a patch, not a full outfit.
        elseif want == false then
            if cur[slotId] then unequip(slotId) end
        elseif cur[slotId] ~= want then
            -- Find the item BEFORE moving anything. Freeing the off hand for a two-hander that turns
            -- out to be in the bank strips the shield and puts nothing in its place, leaving the
            -- player worse off than if they had never clicked.
            local src = wornIn(want, slotId)
            local seen = not src and where[want] or nil
            local at = reachable(seen)

            if not src and not at then
                local place = seen and seen.bank and "bank" or nil
                if place == "bank" then atBank = atBank + 1 end
                missing[#missing + 1] = { slot = slotId, key = want, where = place }
            else
                -- A two-hander needs the off hand free before the client will accept it. Reversed,
                -- the swap is silently refused and the set half-applies — the classic report.
                -- Unless the two-hander IS the off hand: then the slot-to-slot move below carries
                -- it across, and unequipping first would throw away the item being equipped.
                if slotId == Core.MAINHAND and twoHand[want]
                    and cur[Core.OFFHAND] and src ~= Core.OFFHAND then
                    unequip(Core.OFFHAND)
                end

                if src then
                    -- Slot-to-slot: the client swaps the two items, so update both sides.
                    actions[#actions + 1] =
                        { kind = "equip", from = { equipped = src }, to = slotId, key = want }
                    cur[src], cur[slotId] = cur[slotId], want
                else
                    actions[#actions + 1] =
                        { kind = "equip", from = { bag = at.bag, slot = at.slot }, to = slotId, key = want }
                    cur[slotId] = want
                end
            end
        end
    end

    -- A known-too-small bag is a refusal with a reason; an UNKNOWN bag count is not. Kitbag must
    -- never decline a swap because it failed to read the bags — the whole point of catching this is
    -- to replace a confusing failure with a clear one, not to add a new way to fail.
    local blocked = nil
    if meta.freeBagSlots and needsBagSlots > meta.freeBagSlots then blocked = "bags" end

    return {
        actions = actions,
        missing = missing,
        -- How many free bag slots performing this plan will consume, and why it will not be
        -- attempted if that is more than there are.
        needsBagSlots = needsBagSlots,
        blocked = blocked,
        -- How much of what's missing is merely out of reach. The UI turns this into "3 pieces are in
        -- your bank" instead of "3 missing", which is the difference between a bug report and a walk.
        atBank = atBank,
        -- Only a plan with nothing to do AND nothing it couldn't do is a no-op. A plan that is empty
        -- because half the set is in the bank is not "already worn", and must not be skipped
        -- silently — that difference is a bug report waiting to happen.
        empty = #actions == 0 and #missing == 0,
        -- Whether the set says anything AT ALL, which `empty` cannot tell you: a blank set and a set
        -- you are already wearing both have nothing to do, and they are opposite answers. Read off
        -- the declarations rather than off the items, so that "strip to your shirt" — every slot
        -- named, every one of them `false` — stays a real set with plenty to say.
        nothing = next(set.slots) == nil,
    }
end

Kitbag.Core = Core
return Core
