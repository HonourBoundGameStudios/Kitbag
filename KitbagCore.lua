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

-- ---------------------------------------------------------------------------
-- The planner
-- ---------------------------------------------------------------------------

--- Work out the ordered moves that turn what you're wearing into the set you asked for.
--
--   equipped : { [slotId] = itemKey }                   what is worn right now
--   set      : { slots = { [slotId] = key | false } }   false = empty it; absent = don't touch it
--   where    : { [itemKey] = { bag = b, slot = s } }    where an unworn copy can be found
--   meta     : { twoHand = { [itemKey] = true } }       facts only the client knows
--
-- Returns { actions = {…}, missing = {…}, empty = bool }, where each action is one of
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

    for slotId in pairs(set.slots) do
        assert(byId[slotId], "Plan: set names unknown inventory slot " .. tostring(slotId))
    end

    -- Working copy of the world, mutated as each action is planned.
    local cur = {}
    for slotId, key in pairs(equipped) do cur[slotId] = key end

    local actions, missing = {}, {}

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
            local at = not src and where[want] or nil

            if not src and not at then
                missing[#missing + 1] = { slot = slotId, key = want }
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
        -- Only a plan with nothing to do AND nothing it couldn't do is a no-op. A plan that is empty
        -- because half the set is in the bank is not "already worn", and must not be skipped
        -- silently — that difference is a bug report waiting to happen.
        empty = #actions == 0 and #missing == 0,
    }
end

Kitbag.Core = Core
return Core
