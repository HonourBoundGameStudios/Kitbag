-- PanoplyCore — pure item identity + equip planning.
--
-- This is the file ItemRack never had. Every "it equipped the wrong thing / left a slot empty /
-- dropped my offhand into the void" complaint is a *planning* bug, and a planner that only exists
-- inside the client can only be tested by wearing the bug. So Panoply's planner takes plain tables
-- in and returns a plain ordered plan out, and lives here where it can be cornered.
--
-- Usage: lua Tests/core_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")
local C = dofile("PanoplyCore.lua")

H.start("PanoplyCore")

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------

H.eq(#C.SLOTS, 19, "SLOTS covers all 19 equippable inventory slots")
H.eq(C.SlotById(1).key, "HEAD", "slot 1 is HEAD")
H.eq(C.SlotById(16).key, "MAINHAND", "slot 16 is MAINHAND")
H.eq(C.SlotById(17).key, "OFFHAND", "slot 17 is OFFHAND")
H.eq(C.SlotById(99), nil, "an unknown slot id resolves to nil rather than erroring")

-- ---------------------------------------------------------------------------
-- ItemKey — the identity two "identical" items are compared by
-- ---------------------------------------------------------------------------
--
-- Two Thunderfuries are not the same item if one is enchanted and one is not. Identity has to carry
-- the enchant and the gems, or a set will happily equip the wrong copy and look like it worked.

H.eq(C.ItemKey("|cff0070dd|Hitem:7073:0:0:0:0:0:0:0:0|h[Broken Fang]|h|r"), "7073:0:0:0:0:0:0",
    "ItemKey parses a full item link down to id:enchant:gems:suffix")
H.eq(C.ItemKey("item:19019:2504:0:0:0:0:0:0:60"), "19019:2504:0:0:0:0:0",
    "ItemKey keeps the enchant id, so an enchanted copy is a distinct item")
H.eq(C.ItemKey(19019), "19019:0:0:0:0:0:0", "a bare numeric id normalises to a full key")
H.eq(C.ItemKey(nil), nil, "ItemKey(nil) is nil, not an error — an empty slot has no identity")
H.eq(C.ItemKey(""), nil, "ItemKey on an empty string is nil")
H.eq(C.ItemId("19019:2504:0:0:0:0:0"), 19019, "ItemId recovers the numeric id from a key")

-- ---------------------------------------------------------------------------
-- Plan — the heart of it
-- ---------------------------------------------------------------------------
--
-- Plan(equipped, set, where, meta) -> { actions = {…}, missing = {…}, empty = bool }
--   equipped : { [slotId] = itemKey }            what is worn right now
--   set      : { slots = { [slotId] = key | false } }   false = deliberately empty; absent = ignore
--   where    : { [itemKey] = { bag = b, slot = s } }    where an unworn copy can be found
--   meta     : { twoHand = { [itemKey] = true } }       facts the client knows and pure code cannot

local RING_A = "11669:0:0:0:0:0:0"
local RING_B = "12545:0:0:0:0:0:0"
local SWORD = "18348:0:0:0:0:0:0"
local TWOHAND = "17182:0:0:0:0:0:0"
local SHIELD = "17066:0:0:0:0:0:0"
local HELM = "16963:0:0:0:0:0:0"

local function bagged(key, bag, slot) return { [key] = { bag = bag, slot = slot } } end

-- 1. Already wearing it: a plan with nothing in it. The single most important case — an auto-swap
--    rule that re-fires on every combat event must be a no-op when nothing needs to change.
local plan = C.Plan({ [16] = SWORD }, { slots = { [16] = SWORD } }, {})
H.eq(#plan.actions, 0, "no actions when the set is already worn")
H.eq(#plan.missing, 0, "nothing missing when the set is already worn")
H.eq(plan.empty, true, "plan.empty flags a no-op so callers can skip the swap entirely")

-- 2. A slot the set does not mention is left alone. A set is a patch, not a full outfit — a
--    "Fishing" set that only names the pole must not strip your armour.
plan = C.Plan({ [1] = HELM, [16] = SWORD }, { slots = { [16] = TWOHAND } }, bagged(TWOHAND, 1, 5))
H.eq(#plan.actions, 1, "a slot absent from the set is untouched")
H.eq(plan.actions[1].to, 16, "only the slot the set names is acted on")

-- 3. A slot the set explicitly wants empty (false, not nil) is unequipped.
plan = C.Plan({ [17] = SHIELD }, { slots = { [17] = false } }, {})
H.eq(#plan.actions, 1, "slot = false means 'deliberately empty' and produces one action")
H.eq(plan.actions[1].kind, "unequip", "that action is an unequip")
H.eq(plan.actions[1].to, 17, "the emptied slot is the one the set named")

-- 4. Equipping a two-hander must free the offhand FIRST. Reversed, the client refuses the swap and
--    the shield stays on — the classic "my set only half-applied" report.
plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = TWOHAND } },
    bagged(TWOHAND, 1, 5), { twoHand = { [TWOHAND] = true } })
H.eq(#plan.actions, 2, "a two-hander swap is two actions: free the offhand, then equip")
H.eq(plan.actions[1].kind, "unequip", "the first action frees the offhand")
H.eq(plan.actions[1].to, 17, "…and it is the offhand that is freed")
H.eq(plan.actions[2].to, 16, "the two-hander lands in the mainhand second")

-- 4b. …but ONLY if the two-hander can actually be equipped. Freeing the off hand for a weapon that
--     turns out to be in the bank strips the shield and puts nothing in its place — the player is
--     left worse off than if they had never clicked. Availability is checked before anything moves.
plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = TWOHAND } },
    {}, { twoHand = { [TWOHAND] = true } })
H.eq(#plan.actions, 0, "an unavailable two-hander does NOT cost you your off hand")
H.eq(#plan.missing, 1, "…it is reported missing instead")

-- 4c. A two-hander already worn in the off hand moves to the main hand as a slot-to-slot swap.
--     Unequipping the off hand "to make room" would throw away the very item being equipped.
plan = C.Plan({ [16] = SWORD, [17] = TWOHAND }, { slots = { [16] = TWOHAND } },
    {}, { twoHand = { [TWOHAND] = true } })
H.eq(#plan.actions, 1, "a two-hander worn in the off hand is moved, not discarded")
H.eq(plan.actions[1].from.equipped, 17, "…and the move sources it from the off hand")

-- 5. The wanted item is already worn in the sibling slot. Moving ring 12 onto slot 11 swaps BOTH
--    rings in one gesture, so the second slot needs no action of its own — and neither ring is
--    "missing". ItemRack's ring/trinket shuffle is exactly this case, and it is why the planner
--    simulates its own effects as it goes instead of resolving each slot in isolation.
plan = C.Plan({ [11] = RING_A, [12] = RING_B }, { slots = { [11] = RING_B, [12] = RING_A } }, {})
H.eq(#plan.missing, 0, "a ring worn in the other ring slot is not 'missing'")
H.eq(#plan.actions, 1, "swapping two worn rings is ONE move, because the move swaps them both")
H.eq(plan.actions[1].from.equipped, 12, "the source is the slot the wanted ring is worn in")
H.eq(plan.actions[1].to, 11, "the destination is the slot that wanted it")

-- 6. An item that is neither worn nor in a bag is reported, and does not fabricate an action.
plan = C.Plan({}, { slots = { [16] = SWORD } }, {})
H.eq(#plan.actions, 0, "a missing item produces no action")
H.eq(#plan.missing, 1, "a missing item is reported")
H.eq(plan.missing[1].slot, 16, "the report names the slot it was wanted for")
H.eq(plan.missing[1].key, SWORD, "the report names the item that could not be found")
H.eq(plan.empty, false, "a plan that could not be fully built is not 'empty'")

-- 7. A plain fetch from the bags.
plan = C.Plan({}, { slots = { [16] = SWORD } }, bagged(SWORD, 2, 7))
H.eq(#plan.actions, 1, "one action to equip one bagged item")
H.eq(plan.actions[1].kind, "equip", "…and it is an equip")
H.eq(plan.actions[1].from.bag, 2, "the action carries the source bag")
H.eq(plan.actions[1].from.slot, 7, "the action carries the source bag slot")
H.eq(plan.actions[1].to, 16, "the action carries the destination inventory slot")
H.eq(plan.actions[1].key, SWORD, "the action carries the item it moves, for the log and the retry")

-- 8. Guards. A malformed call is a caller bug and should say so loudly rather than silently
--    equipping nothing and looking like a game problem.
H.errors(function() C.Plan(nil, { slots = {} }, {}) end, "Plan requires the equipped table")
H.errors(function() C.Plan({}, nil, {}) end, "Plan requires a set")
H.errors(function() C.Plan({}, { slots = { [42] = SWORD } }, {}) end, "Plan rejects an unknown slot id")

-- ---------------------------------------------------------------------------
-- CaptureSet — "save what I'm wearing"
-- ---------------------------------------------------------------------------

local set = C.CaptureSet({ [1] = HELM, [16] = SWORD }, "Tank")
H.eq(set.name, "Tank", "a captured set carries its name")
H.eq(set.slots[16], SWORD, "a captured set records what was worn")
H.eq(set.slots[17], false, "an empty slot captures as false — deliberately empty, not 'ignore'")
H.errors(function() C.CaptureSet({}, "") end, "a set must be named")

-- A captured set round-trips: capturing what you wear and immediately applying it is a no-op.
H.eq(C.Plan({ [1] = HELM, [16] = SWORD }, set, {}).empty, true,
    "capture then apply is a no-op — the round-trip that proves capture and plan agree")

H.done()
