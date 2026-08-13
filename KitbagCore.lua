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

    local function unequip(slotId)
        actions[#actions + 1] = { kind = "unequip", to = slotId, key = cur[slotId] }
        cur[slotId] = nil
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

    return {
        actions = actions,
        missing = missing,
        -- How much of what's missing is merely out of reach. The UI turns this into "3 pieces are in
        -- your bank" instead of "3 missing", which is the difference between a bug report and a walk.
        atBank = atBank,
        -- Only a plan with nothing to do AND nothing it couldn't do is a no-op. A plan that is empty
        -- because half the set is in the bank is not "already worn", and must not be skipped
        -- silently — that difference is a bug report waiting to happen.
        empty = #actions == 0 and #missing == 0,
    }
end

Kitbag.Core = Core
return Core
