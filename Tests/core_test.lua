-- KitbagCore — pure item identity + equip planning.
--
-- This is the file ItemRack never had. Every "it equipped the wrong thing / left a slot empty /
-- dropped my offhand into the void" complaint is a *planning* bug, and a planner that only exists
-- inside the client can only be tested by wearing the bug. So Kitbag's planner takes plain tables
-- in and returns a plain ordered plan out, and lives here where it can be cornered.
--
-- Usage: lua Tests/core_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")
local C = dofile("KitbagCore.lua")

H.start("KitbagCore")

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

-- A colon-delimited body with no "item:" prefix. Two things arrive in this shape and both matter:
--
--   * ItemKey's OWN output. Feeding a stored key back through must return it unchanged, or any code
--     that re-normalises saved data silently turns every item into nil and the whole set reads as
--     "missing" — a landmine for a feature nobody has written yet.
--   * ItemRack's SavedVariables, which store "22196:1891:::::::60::::::::::" — note the EMPTY
--     fields rather than zeros. Needed by the importer (COMPAT-1).

H.eq(C.ItemKey("19019:2504:0:0:0:0:0"), "19019:2504:0:0:0:0:0",
    "ItemKey is idempotent — its own output survives a second pass unchanged")
H.eq(C.ItemKey("22196:1891:::::::60::::::::::"), "22196:1891:0:0:0:0:0",
    "an ItemRack string with empty fields reads as zeros, keeping the enchant")
H.eq(C.ItemKey("16955::::::::60::::::::::"), "16955:0:0:0:0:0:0",
    "an unenchanted ItemRack string reduces to the bare item")
H.eq(C.ItemKey("::::::"), nil, "colons with no id at all are not an item")
H.eq(C.ItemKey("notanitem"), nil, "a non-numeric string is not an item")
H.eq(C.ItemKey("0::::::"), nil, "item id 0 is not an item, however it is spelled")

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
-- The bank (CORE-2)
-- ---------------------------------------------------------------------------
--
-- "Missing" and "in your bank, twenty yards away" are different answers and only one of them is
-- actionable. A location entry flagged `bank = true` is a real sighting of the item, so the planner
-- must name it as such — and must still refuse to use it while the bank window is shut, because
-- PickupContainerItem on a bank bag does nothing when the bank is closed.

local function banked(key, bag, slot) return { [key] = { bag = bag, slot = slot, bank = true } } end

plan = C.Plan({}, { slots = { [16] = SWORD } }, banked(SWORD, -1, 3))
H.eq(#plan.actions, 0, "an item in the bank cannot be equipped with the bank closed")
H.eq(#plan.missing, 1, "…so it is reported rather than silently skipped")
H.eq(plan.missing[1].where, "bank", "…and the report says WHERE it is, not just that it is absent")
H.eq(plan.atBank, 1, "the plan counts how much of the set is waiting at the bank")

-- With the bank open the very same location is usable, which is what makes "complete this set at the
-- bank" a real offer rather than a suggestion to go and shuffle bags by hand.
plan = C.Plan({}, { slots = { [16] = SWORD } }, banked(SWORD, -1, 3), { bankOpen = true })
H.eq(#plan.actions, 1, "with the bank open the bank copy is a legitimate source")
H.eq(#plan.missing, 0, "…and nothing is missing any more")
H.eq(plan.actions[1].from.bag, -1, "the action sources it from the bank container")
H.eq(plan.atBank, 0, "nothing is left at the bank once the bank copies are usable")

-- An item nobody can find at all still reports no location. "where = nil" is the honest answer and
-- must not be conflated with "bank", or the UI sends the player to the bank for nothing.
plan = C.Plan({}, { slots = { [16] = SWORD } }, {})
H.eq(plan.missing[1].where, nil, "an item found nowhere reports no location")
H.eq(plan.atBank, 0, "…and does not count towards the bank total")

-- The off-hand guard has to hold for the bank too. A two-hander sitting in the bank must not cost
-- you your shield: the same "check availability before moving anything" rule, one source further out.
plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = TWOHAND } },
    banked(TWOHAND, -1, 3), { twoHand = { [TWOHAND] = true } })
H.eq(#plan.actions, 0, "a two-hander in the bank does not strip the off hand")
H.eq(plan.missing[1].where, "bank", "…and is reported as a bank item")

-- ---------------------------------------------------------------------------
-- Inheritance (CORE-3)
-- ---------------------------------------------------------------------------
--
-- "Raid Fire" is "Raid" with two pieces changed. Stored as a full outfit it duplicates seventeen
-- slots, and re-enchanting one shared item means editing five sets and forgetting the sixth. Stored
-- as a delta on a parent, the shared piece lives in exactly one place.

local sets = {
    Raid      = { name = "Raid", slots = { [1] = HELM, [11] = RING_A, [16] = SWORD } },
    ["Raid Fire"] = { name = "Raid Fire", parent = "Raid", slots = { [11] = RING_B } },
}

local flat = C.Resolve(sets, "Raid Fire")
H.eq(flat.slots[1], HELM, "an inherited slot comes through from the parent")
H.eq(flat.slots[16], SWORD, "…every one of them")
H.eq(flat.slots[11], RING_B, "a slot the child names overrides the parent's")
H.eq(flat.name, "Raid Fire", "the resolved set keeps the child's name, not the parent's")
H.eq(flat.parent, nil, "…and is flat: a resolved set has no parent left to chase")
H.eq(sets["Raid Fire"].slots[1], nil, "resolving does not mutate the stored delta")

-- A child that empties a slot the parent fills. `false` has to survive inheritance or "Raid, but no
-- shield" is unsayable — and unsayable is how you end up storing the whole outfit again.
sets["Raid Bare"] = { name = "Raid Bare", parent = "Raid", slots = { [1] = false } }
H.eq(C.Resolve(sets, "Raid Bare").slots[1], false,
    "a child can empty a slot its parent fills, and false is not mistaken for 'unset'")

-- Chains resolve all the way up. Grandparent -> parent -> child, nearest wins.
sets["Raid Fire Solo"] = { name = "Raid Fire Solo", parent = "Raid Fire", slots = { [16] = TWOHAND } }
flat = C.Resolve(sets, "Raid Fire Solo")
H.eq(flat.slots[1], HELM, "a grandparent's slot reaches the grandchild")
H.eq(flat.slots[11], RING_B, "the nearer ancestor wins over the further one")
H.eq(flat.slots[16], TWOHAND, "the child still wins over both")

-- A parent that no longer exists must degrade to "just the delta", not to nil. Deleting a set the
-- player forgot was a parent should cost them the inherited pieces, never the whole child set.
sets.Orphan = { name = "Orphan", parent = "Gone", slots = { [16] = SWORD } }
flat = C.Resolve(sets, "Orphan")
H.eq(flat.slots[16], SWORD, "a missing parent leaves the child's own slots intact")
H.eq(flat.slots[1], nil, "…and simply contributes nothing")

-- A cycle is authorable by hand-editing SavedVariables and must terminate. An addon that hangs the
-- client on login is worse than any wrong outfit.
sets.Loop = { name = "Loop", parent = "Loop2", slots = { [1] = HELM } }
sets.Loop2 = { name = "Loop2", parent = "Loop", slots = { [16] = SWORD } }
flat = C.Resolve(sets, "Loop")
H.eq(flat.slots[1], HELM, "a parent cycle resolves rather than hanging")
H.eq(flat.slots[16], SWORD, "…visiting each set in the cycle exactly once")

H.eq(C.Resolve(sets, "Nope"), nil, "resolving a set that does not exist is nil, not an error")

-- Diff — what makes a full capture into a delta. Saving "Raid Fire" while wearing it captures all
-- nineteen slots; dropping everything the parent already says is what leaves a delta behind.
local full = { name = "Raid Fire", slots = { [1] = HELM, [11] = RING_B, [16] = SWORD } }
local delta = C.Diff(full, sets.Raid)
H.eq(delta.slots[1], nil, "a slot identical to the parent's drops out of the delta")
H.eq(delta.slots[16], nil, "…all of them")
H.eq(delta.slots[11], RING_B, "a slot that differs is kept")
H.eq(delta.name, "Raid Fire", "the delta keeps its name")
H.eq(C.Diff(full, nil).slots[1], HELM, "with no parent, a diff is the set unchanged")

-- ---------------------------------------------------------------------------
-- Explaining a plan (UI-6)
-- ---------------------------------------------------------------------------
--
-- The row says "3 swaps". Hovering it should say which three. This is the same information the
-- driver is about to act on, turned into slot-by-slot lines — so what the tooltip promises and what
-- the driver does cannot drift apart, because they are the same list.

plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = TWOHAND, [1] = HELM } },
    bagged(TWOHAND, 1, 5), { twoHand = { [TWOHAND] = true } })
local lines = C.Explain(plan)
H.eq(#lines, 3, "every action in the plan gets a line, including the ones nobody asked for")
H.eq(lines[1].slot, "Off hand", "…named by the slot a player sees, not by its id")
H.eq(lines[1].verb, "take off", "freeing the off hand reads as taking something off")
H.eq(lines[1].key, SHIELD, "…and carries the item, so the caller can name it")
H.eq(lines[2].verb, "put on", "an equip from the bags reads as putting something on")
H.eq(lines[2].slot, "Main hand", "the lines follow the plan's own order")
-- The helm was never supplied, so it is not an action at all — and it still gets a line, at the end
-- with the rest of what could not be done.
H.eq(lines[3].slot, "Head", "what could not be done comes after what can")
H.eq(lines[3].verb, "not found", "…and says so")

-- A slot-to-slot move is a different sentence: nothing new comes out of a bag and the other slot
-- changes too, which is exactly the behaviour that surprises people about ring swaps.
plan = C.Plan({ [11] = RING_A, [12] = RING_B }, { slots = { [11] = RING_B, [12] = RING_A } }, {})
lines = C.Explain(plan)
H.eq(#lines, 1, "the ring swap is one line, because it is one move")
H.eq(lines[1].verb, "move from", "…and reads as a move")
H.eq(lines[1].from, "Ring 2", "…naming where it comes from")

-- What can't be done belongs in the same list. A tooltip that lists three moves and stays silent
-- about the fourth item being in the bank is the tooltip that gets Kitbag blamed.
plan = C.Plan({}, { slots = { [16] = SWORD, [1] = HELM } }, banked(HELM, -1, 2))
lines = C.Explain(plan)
H.eq(#lines, 2, "missing items are lines too")
H.eq(lines[1].verb, "in your bank", "…saying where it is when that is known")
H.eq(lines[1].slot, "Head", "…for the slot that wanted it")
H.eq(lines[2].verb, "not found", "…and saying so plainly when it is not")

H.eq(#C.Explain({ actions = {}, missing = {} }), 0, "a plan with nothing in it explains nothing")
H.eq(#C.Explain(nil), 0, "…and neither does no plan at all")

-- ---------------------------------------------------------------------------
-- Per-slot alternatives (UI-5)
-- ---------------------------------------------------------------------------
--
-- "Hover a slot, see everything you own that fits it, click to wear it." Which items fit which slot
-- is a fixed table the client will not tell you — GetItemInfo gives an equip location token and you
-- have to know that a ring goes in either finger slot and a shield only in the off hand.

H.eq(C.SlotsFor("INVTYPE_HEAD")[1], 1, "a helm goes on your head")
H.eq(#C.SlotsFor("INVTYPE_HEAD"), 1, "…and nowhere else")
H.eq(#C.SlotsFor("INVTYPE_FINGER"), 2, "a ring fits either finger")
H.eq(C.SlotsFor("INVTYPE_FINGER")[2], 12, "…including the second one")
H.eq(#C.SlotsFor("INVTYPE_TRINKET"), 2, "and a trinket either trinket slot")
H.eq(#C.SlotsFor("INVTYPE_WEAPON"), 2, "a one-hander can go in either hand")
H.eq(C.SlotsFor("INVTYPE_2HWEAPON")[1], 16, "a two-hander only in the main hand")
H.eq(#C.SlotsFor("INVTYPE_2HWEAPON"), 1, "…and only there")
H.eq(C.SlotsFor("INVTYPE_SHIELD")[1], 17, "a shield only in the off hand")
H.eq(C.SlotsFor("INVTYPE_ROBE")[1], 5, "a robe is a chest piece under a different token")
H.eq(#C.SlotsFor("INVTYPE_BAG"), 0, "something that is not equippable gear fits no slot")
H.eq(#C.SlotsFor(nil), 0, "…and an uncached item, which reads as nil, fits none either")

-- Alternatives — the flyout's contents. Everything you own that fits, minus what is already there,
-- because offering to equip the item you are wearing is a menu entry that does nothing.
local where = {
    [RING_A] = { bag = 0, slot = 1 },
    [RING_B] = { bag = 0, slot = 2 },
    [SHIELD] = { bag = 0, slot = 3 },
    [HELM]   = { bag = 0, slot = 4 },
}
local locations = {
    [RING_A] = "INVTYPE_FINGER",
    [RING_B] = "INVTYPE_FINGER",
    [SHIELD] = "INVTYPE_SHIELD",
    [HELM]   = "INVTYPE_HEAD",
}

local alts = C.Alternatives(11, { [11] = RING_A }, where, locations)
H.eq(#alts, 1, "the ring already on that finger is not offered again")
H.eq(alts[1].key, RING_B, "…and the other one is")
H.eq(alts[1].bag, 0, "an alternative carries where to get it from")

-- A ring worn on the OTHER finger is still an alternative for this one: swapping which finger they
-- sit on is a real thing people do, and the planner already handles the two-way swap.
alts = C.Alternatives(11, { [11] = RING_A, [12] = RING_B }, where, locations)
H.eq(#alts, 1, "a ring worn on the other finger is still offered for this one")
H.eq(alts[1].key, RING_B, "…as itself")
H.eq(alts[1].worn, 12, "…marked with the slot it is currently worn in")

H.eq(#C.Alternatives(17, {}, where, locations), 1, "the off hand offers the shield")
H.eq(#C.Alternatives(2, {}, where, locations), 0, "a slot you own nothing for offers nothing")

-- Order has to be stable — a menu whose entries move between two hovers is unusable — and pairs()
-- over the bag contents is not.
local first = C.Alternatives(11, {}, where, locations)
local second = C.Alternatives(11, {}, where, locations)
H.eq(#first, 2, "both rings are offered when neither is worn")
H.eq(first[1].key, second[1].key, "the order is the same every time")
H.eq(first[1].key < first[2].key, true, "…and is sorted, rather than whatever pairs() produced")

-- ---------------------------------------------------------------------------
-- The stand-in icon (UI-4)
-- ---------------------------------------------------------------------------
--
-- A set can be given an icon, but most never will be, and a list of identical question marks is no
-- better than a list of names. So a set without one borrows the icon of the item that best
-- identifies it. Which item that is is a judgement, and judgements belong here rather than in the
-- frame: the weapon first, because "Fishing" is the pole and "Tank" is the shield-and-mace, then the
-- big obvious armour pieces, and only then whatever the set happens to name.

H.eq(C.IconItem({ slots = { [1] = HELM, [16] = SWORD } }), SWORD,
    "the main hand stands in for the set before anything else does")
H.eq(C.IconItem({ slots = { [1] = HELM, [5] = SHIELD } }), HELM,
    "with no weapon, the head is the next most recognisable piece")
H.eq(C.IconItem({ slots = { [19] = SHIELD } }), SHIELD,
    "a set of nothing but a tabard still gets the tabard's icon rather than nothing")
H.eq(C.IconItem({ slots = { [1] = false, [16] = false } }), nil,
    "a set that equips nothing has no item to borrow from")
H.eq(C.IconItem({ slots = {} }), nil, "…and neither does an empty one")

-- Deterministic: the same set must not pick a different icon between two openings of the window.
local wide = { slots = { [11] = RING_A, [12] = RING_B, [13] = SHIELD, [15] = HELM } }
H.eq(C.IconItem(wide), C.IconItem(wide), "the choice is stable for the same set")
H.eq(C.IconItem(wide), RING_A,
    "…and falls back to plain slot order once none of the preferred slots are named")

-- ---------------------------------------------------------------------------
-- The full-bag guard (CORE-5)
-- ---------------------------------------------------------------------------
--
-- Taking something off needs somewhere to put it. With no free bag slot the client simply refuses,
-- and the driver spends its whole retry budget discovering that before reporting a set as "stuck on
-- Off hand" — which reads as a Kitbag bug rather than as a full bag. Counted up front instead.

plan = C.Plan({ [17] = SHIELD }, { slots = { [17] = false } }, {}, { freeBagSlots = 0 })
H.eq(plan.needsBagSlots, 1, "an unequip needs one free bag slot to put the item into")
H.eq(plan.blocked, "bags", "…and with none free the plan says why before anything is attempted")

plan = C.Plan({ [17] = SHIELD }, { slots = { [17] = false } }, {}, { freeBagSlots = 1 })
H.eq(plan.blocked, nil, "one free slot is enough for one unequip")

-- Equipping from a bag is a swap: the worn item lands in the bag slot the new one came from, so it
-- costs nothing. Counting it would refuse perfectly possible swaps on a nearly full bag, which is
-- the more annoying failure of the two.
plan = C.Plan({ [16] = SWORD }, { slots = { [16] = TWOHAND } }, bagged(TWOHAND, 1, 5),
    { freeBagSlots = 0 })
H.eq(plan.needsBagSlots, 0, "a bag-to-body swap needs no free slot — the old item takes the new one's place")
H.eq(plan.blocked, nil, "…so a full bag does not block it")

-- Two unequips need two slots. The count is cumulative: the first one's item is still in the bag
-- when the second is attempted.
plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = false, [17] = false } }, {},
    { freeBagSlots = 1 })
H.eq(plan.needsBagSlots, 2, "two unequips need two free slots, not one reused twice")
H.eq(plan.blocked, "bags", "…and one free slot is not enough")

-- The two-hander case is where this actually bites: the plan quietly adds an unequip of the off hand
-- that the player never asked for, so a set that looks like a single swap needs a free slot anyway.
plan = C.Plan({ [16] = SWORD, [17] = SHIELD }, { slots = { [16] = TWOHAND } },
    bagged(TWOHAND, 1, 5), { twoHand = { [TWOHAND] = true }, freeBagSlots = 0 })
H.eq(plan.needsBagSlots, 1, "freeing the off hand for a two-hander needs a bag slot of its own")
H.eq(plan.blocked, "bags", "…and that is caught before the shield comes off")

-- Unknown is not zero. Kitbag must never refuse a swap because it failed to read the bags.
plan = C.Plan({ [17] = SHIELD }, { slots = { [17] = false } }, {})
H.eq(plan.blocked, nil, "with no bag count supplied, the plan proceeds rather than refusing")
H.eq(plan.needsBagSlots, 1, "…but still says what it would need")

-- ---------------------------------------------------------------------------
-- Totals (CORE-4)
-- ---------------------------------------------------------------------------
--
-- Two questions a set list should answer without being clicked: how good is this set, and is any of
-- it about to break. Both are arithmetic over facts only the client has, so the client hands them in
-- and the arithmetic lives here where it can be cornered.
--
--   info : { [itemKey] = { level = n, durability = 0..1 | nil } }

local info = {
    [HELM]  = { level = 66, durability = 1.0 },
    [SWORD] = { level = 70, durability = 0.5 },
    [SHIELD]= { level = 62, durability = 0.1 },
}

local totals = C.Totals({ slots = { [1] = HELM, [16] = SWORD } }, info)
H.eq(totals.items, 2, "the totals count the items the set names")
H.eq(totals.known, 2, "…and how many of them the client could actually answer for")
H.eq(totals.level, 68, "the item level is the average over the set")
H.eq(totals.durability, 0.5, "durability is the WEAKEST piece, not the average — that is what breaks")

-- An empty slot is a deliberate choice, not an item, and must not drag the average down to zero.
totals = C.Totals({ slots = { [1] = HELM, [17] = false } }, info)
H.eq(totals.items, 1, "a slot the set deliberately empties is not an item")
H.eq(totals.level, 66, "…and does not count as item level 0")

-- GetItemInfo returns nil for anything the client has not cached, which happens constantly on a
-- fresh login. An unknown item must reduce confidence, never fabricate a number: averaging it in as
-- zero is the same class of bug as treating nil as "not a two-hander".
totals = C.Totals({ slots = { [1] = HELM, [16] = SWORD, [15] = "999:0:0:0:0:0:0" } }, info)
H.eq(totals.items, 3, "an uncached item is still part of the set")
H.eq(totals.known, 2, "…but it is not something we know about")
H.eq(totals.level, 68, "…and it is left out of the average rather than counted as zero")
H.eq(totals.complete, false, "the totals say plainly that they are partial")

totals = C.Totals({ slots = { [1] = HELM } }, info)
H.eq(totals.complete, true, "…and say so when they are not")

-- Durability is unknown for anything not currently worn — there is no API for a bagged item's
-- durability — so an unknown must not read as a full bar and hide a piece at 5%.
totals = C.Totals({ slots = { [1] = HELM, [16] = SWORD } },
    { [HELM] = { level = 66 }, [SWORD] = { level = 70, durability = 0.5 } })
H.eq(totals.durability, 0.5, "unknown durability neither counts as full nor as broken")

totals = C.Totals({ slots = { [1] = HELM } }, { [HELM] = { level = 66 } })
H.eq(totals.durability, nil, "with nothing known, durability is nil rather than a made-up number")

-- Nothing at all: a set of empty slots has no level, and reporting 0 would sort it below every real
-- set as though it were terrible rather than empty.
totals = C.Totals({ slots = { [1] = false } }, info)
H.eq(totals.items, 0, "a set that equips nothing has no items")
H.eq(totals.level, nil, "…and no item level, rather than a level of zero")

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
