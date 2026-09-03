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

-- A tooltip built from the id alone is the base item: no enchant, no gems, and — the one that shows
-- up as "my stats are missing" — no random suffix. "of the Eagle" IS the stats, so a preview of
-- item:12345 shows a belt with nothing on it. The key already carries all of it; hand the whole
-- thing to SetHyperlink.
H.eq(C.ItemLink("19019:2504:0:0:0:0:0"), "item:19019:2504:0:0:0:0:0",
    "ItemLink keeps the enchant, so the preview shows the enchant line")
H.eq(C.ItemLink("7073:0:0:0:0:0:-19"), "item:7073:0:0:0:0:0:-19",
    "ItemLink keeps the random suffix, which on a Classic drop IS the stats")
H.eq(C.ItemLink(nil), nil, "ItemLink(nil) is nil — an empty slot has no tooltip")
H.eq(C.ItemLink("not an item"), nil, "ItemLink refuses a string that is not a key")

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
local TRINKET_A = "11815:0:0:0:0:0:0"
local TRINKET_B = "11122:0:0:0:0:0:0"
local TRINKET_C = "10418:0:0:0:0:0:0"

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

-- 5b. The other half of the same shuffle, and the one that was WRONG (BUG-15). The wanted item is
--     worn in a slot the plan has ALREADY filled from a bag. Equipping from a bag is a swap — the
--     worn item lands in the bag slot the new one came from, which is why `needsBagSlots` charges
--     nothing for it — so the displaced trinket is still perfectly reachable and must not be
--     reported "not found anywhere" while it sits in the player's bag.
--     Pobble's `Tanky-Heal-PVP`: Hand of Justice worn in trinket 1, wanted in trinket 2.
plan = C.Plan({ [13] = TRINKET_A, [14] = TRINKET_B },
    { slots = { [13] = TRINKET_C, [14] = TRINKET_A } }, bagged(TRINKET_C, 4, 3))
H.eq(#plan.missing, 0, "an item displaced INTO a bag by an earlier action is not 'missing'")
H.eq(#plan.actions, 2, "…it is fetched back, so the shuffle is two moves")
H.eq(plan.actions[2].to, 14, "the second move fills the slot that wanted the displaced item")
H.eq(plan.actions[2].key, TRINKET_A, "…with the displaced item")
H.eq(plan.actions[2].from.bag, 4, "…sourced from the bag slot the first move put it in")
H.eq(plan.actions[2].from.slot, 3, "…naming that exact slot, which is the one the client uses")

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

-- Which sets may legally become a given set's parent (UI-11). `/kit inherit` could ask the player to
-- type a name and refuse the bad ones afterwards; a menu has to know the answer BEFORE it is drawn,
-- or it offers a choice it will then reject. The illegal ones are exactly the ones that would close
-- a cycle: the set itself, and anything already descended from it.
H.eq(table.concat(C.ParentChoices(sets, "Raid"), ", "), "Loop, Loop2, Orphan",
    "a set's own descendants are not offered as its parent, and it is not offered itself")
H.eq(table.concat(C.ParentChoices(sets, "Raid Fire Solo"), ", "),
    "Loop, Loop2, Orphan, Raid, Raid Bare, Raid Fire",
    "…while its ancestors are, since re-parenting upward closes no cycle")
H.eq(#C.ParentChoices(sets, "Nope"), 0, "a set that does not exist has no choices, and no error")
-- A set already inside a hand-edited cycle still gets offered everything outside it — re-parenting
-- it somewhere legal is the repair, so refusing to offer that would leave the cycle unfixable from
-- the window. Only its own descendant, the other half of the cycle, drops out.
H.eq(table.concat(C.ParentChoices(sets, "Loop"), ", "),
    "Orphan, Raid, Raid Bare, Raid Fire, Raid Fire Solo",
    "a set in a cycle can be pointed out of it, but not at the set that points back")

-- The same walk `Sets.Inherit` guards with, named once so the menu and the command cannot disagree
-- about what a loop is.
H.ok(C.Descends(sets, "Raid Fire Solo", "Raid"), "a grandchild descends from its grandparent")
H.ok(not C.Descends(sets, "Raid", "Raid Fire Solo"), "…and the grandparent does not descend from it")
H.ok(not C.Descends(sets, "Raid", "Raid"), "a set does not descend from itself")
H.ok(not C.Descends(sets, "Orphan", "Raid"), "a missing parent ends the walk rather than erroring")

-- ---------------------------------------------------------------------------
-- Action-bar macros (UI-8)
-- ---------------------------------------------------------------------------
--
-- The client will not let an addon put a button on the action bar, so dragging a set there means
-- making a macro and handing it to the cursor. Macro names are capped at 16 characters, which is
-- shorter than plenty of set names — and two sets truncating to the same name would silently
-- overwrite each other's macro, which is the bug worth writing a test for.

H.eq(C.MacroName("Tank"), "Kit: Tank", "a short set name is used as it is")
H.eq(#C.MacroName("Molten Core Fire Resist"), 16, "a long one is cut to what the client will take")
H.eq(C.MacroName("Molten Core Fire Resist"), "Kit: Molten Core",
    "…keeping the front, which identifies it")

-- The collision. Two sets that truncate the same way must not end up sharing one macro.
local taken = { ["Kit: Molten Core"] = true }
H.eq(C.MacroName("Molten Core Fire Resist", taken), "Kit: Molten Cor2",
    "a name already taken gets a number, in the same 16 characters")
taken["Kit: Molten Cor2"] = true
H.eq(C.MacroName("Molten Core Fire Resist", taken), "Kit: Molten Cor3", "…and keeps counting")

-- A set that already owns its macro keeps it, rather than growing a second one each time it is
-- dragged. `taken` is what other sets hold, so the set's own name is not in it.
H.eq(C.MacroName("Tank", { ["Kit: Raid"] = true }), "Kit: Tank",
    "someone else's macro does not push a set off its own name")

H.eq(C.MacroBody("Tank"), "/kit equip Tank", "the macro equips the set by name")
H.eq(C.MacroBody("Raid Fire"), "/kit equip Raid Fire",
    "…including one with a space, which needs no quoting because the command takes the rest of the line")

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
-- ---------------------------------------------------------------------------
-- StateWords — the conditions a failed swap failed in, as one line (BUG-9)
-- ---------------------------------------------------------------------------
--
-- One vocabulary, because two readers ask this question: the dump prints it and /kit verify prints
-- it, and a self-check whose wording has drifted from the dump's is a self-check nobody can quote.
--
-- Every condition is stated in BOTH directions. "combat no" is the line that RULES OUT the leading
-- suspect for BUG-9, and a reader must never have to infer an absence from a word that is not there
-- — which is exactly what a list of only the true ones would ask of them.

H.eq(C.StateWords({ combat = true, mounted = true, dead = false, casting = false }),
    "combat yes, mounted yes, dead no, casting no",
    "every condition is named, in a fixed order, with a yes or a no against each")
H.eq(C.StateWords({ combat = false, mounted = false, dead = false, casting = false }),
    "combat no, mounted no, dead no, casting no",
    "all-clear is stated in full rather than collapsing to 'nothing notable'")

-- A record from an older build carries no state at all, and that is not the same claim as a build
-- that looked and found nothing. Nil in, nil out; the callers omit the line entirely.
H.eq(C.StateWords(nil), nil, "no state recorded is nil, not a line of four noes")

-- Conditions this client could not answer arrive absent rather than false, and absent must read the
-- same as false: an unasked question is not a yes.
H.eq(C.StateWords({ combat = true }), "combat yes, mounted no, dead no, casting no",
    "a condition the client could not answer reads as no rather than vanishing from the line")

-- BUG-13's discriminator. Two instances now say "picked up, but the bag move had not completed",
-- and the one number that would separate the two candidate causes was never recorded: how much bag
-- room there was AT THE MOMENT IT FAILED. The planner counts free slots before it starts
-- (`meta.freeBagSlots`) and refuses outright when there are too few — so a failure that got as far
-- as picking the item up is one the planner believed it had room for, and either the bags filled
-- underneath it or the room it counted was not room this item could use. Those want opposite fixes
-- and no amount of re-reading the driver distinguishes them.
--
-- Reported against what the plan NEEDED, not alone: "bag room 0" is alarming and "bag room 0 of 0
-- needed" is a swap that wanted no room at all, which is a different bug entirely.
H.eq(C.StateWords({ room = 3, need = 1 }),
    "combat no, mounted no, dead no, casting no, bag room 3 of 1 needed",
    "the bag room at the moment of failure is on the line, against what the plan needed")
H.eq(C.StateWords({ room = 0, need = 1 }),
    "combat no, mounted no, dead no, casting no, bag room 0 of 1 needed",
    "…and no room at all is stated as a number rather than by its absence")

-- The same rule the whole function is built on, applied to the new pair: a build that never captured
-- this must not read like one that looked and found none. Zero and unknown are opposite findings
-- here — zero would explain BUG-13 outright, and unknown explains nothing.
H.eq(C.StateWords({ combat = true, room = 0 }),
    "combat yes, mounted no, dead no, casting no, bag room 0",
    "room with no plan figure to compare against still reports the room")
H.eq(C.StateWords({ combat = true }), "combat yes, mounted no, dead no, casting no",
    "a record from a build that never counted bag room says nothing about it, rather than 0")

-- ---------------------------------------------------------------------------
-- PushSwap — a rolling history of attempts, not just the last one
-- ---------------------------------------------------------------------------
--
-- SavedVariables reaches disk on /reload, so a record made by an action lands on the NEXT reload.
-- Storing only the most recent attempt means a player who clicks twice before reloading silently
-- destroys the first one — which happened three times in one session on 2026-08-16, each time
-- costing a round trip to discover the record on disk described an attempt nobody was asking about.
-- A short history makes one reload carry everything since the last one.

H.eq(#C.PushSwap(nil, { set = "A" }, 3), 1, "the first attempt starts a history rather than erroring")
H.eq(C.PushSwap(nil, { set = "A" }, 3)[1].set, "A", "…and is the newest entry")

local hist = C.PushSwap(C.PushSwap(nil, { set = "A" }, 3), { set = "B" }, 3)
H.eq(hist[1].set, "B", "newest first, because that is the one a reader wants and the one a UI shows")
H.eq(hist[2].set, "A", "…and the older attempt survives rather than being overwritten")

-- Bounded, or a long session grows the saved file without limit — and SavedVariables is written in
-- full on every reload, so an unbounded log is a growing cost on every single one.
local many = nil
for i = 1, 10 do many = C.PushSwap(many, { set = "S" .. i }, 3) end
H.eq(#many, 3, "the history is capped")
H.eq(many[1].set, "S10", "…keeping the newest")
H.eq(many[3].set, "S8", "…and dropping the oldest")

-- A caller that forgets the limit gets a sane one rather than an unbounded list, because the failure
-- mode is invisible: nothing breaks, the file just grows for ever.
H.ok(#C.PushSwap({ {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} }, { set = "A" }) <= 10,
    "no limit given falls back to a bounded default rather than growing without end")

-- StowBags — which bags a removed item is offered to
-- ---------------------------------------------------------------------------
--
-- The other end of the same count. The driver used to put a removed item down by trying the backpack
-- and then every bag in turn until one took it — and every bag it hit on the way answered "That bag
-- is full" in the chat frame. A swap that worked perfectly still read as a string of errors, with
-- nothing to distinguish that spam from a swap that had genuinely failed.
--
-- This is the rule freeBagSlots above is counted BY, named once so the count and the attempt cannot
-- be about two different sets of bags.
--
--   StowBags(bags) -> the usable ones, in order.  bags : { { id =, free =, family = }, … }

local function stowIds(bags)
    local ids = {}
    for _, bag in ipairs(C.StowBags(bags)) do ids[#ids + 1] = bag.id end
    return table.concat(ids, ",")
end

H.eq(stowIds({ { id = 0, free = 0, family = 0 }, { id = 1, free = 4, family = 0 } }), "1",
    "a bag with no room is never offered the item — that is the 'That bag is full' message")
H.eq(stowIds({ { id = 0, free = 2, family = 0 }, { id = 1, free = 4, family = 0 } }), "0,1",
    "bags with room are offered in order, the backpack first")

-- A quiver's free slots will never take a helmet, so offering it one is an error message with no
-- chance of success behind it — and counting those slots promises room that does not exist.
H.eq(stowIds({ { id = 0, free = 0, family = 0 }, { id = 1, free = 8, family = 1 },
               { id = 2, free = 1, family = 0 } }), "2",
    "a special bag is skipped however much room it has")
H.eq(stowIds({ { id = 3, free = 1 } }), "3",
    "a bag whose family the client did not name counts as usable, not as lost capacity")

-- Nowhere to put it is a real state: the planner blocks the set up front, but a bag can fill between
-- the plan and the action. An empty answer leaves the item on the cursor for ClearCursor to put
-- back, which is quiet and correct; trying anyway is loud and still fails.
H.eq(stowIds({ { id = 0, free = 0, family = 0 } }), "",
    "no bag with room -> nothing to try, rather than one error per bag")

-- ---------------------------------------------------------------------------
-- StowSlot — WHICH slot a removed item is put into (BUG-13)
-- ---------------------------------------------------------------------------
--
-- BUG-13, settled by hand at the client after four rounds of instruments. `PutItemInBag` does not
-- work here: the driver picked the shield up, called it against a bag with thirteen free slots, and
-- the client did nothing and said nothing. The Admiral then dragged the same shield into the same bag
-- by hand, mounted, while the addon was actively fighting them for it — so the client was willing in
-- the exact state the driver failed in, and the call was the fault.
--
-- The replacement is not a new idea, it is the one call in this addon that demonstrably works: every
-- successful equip moves an item with PickupContainerItem. But that call names a SLOT rather than
-- asking a bag to find room, so the choosing becomes ours — which is the good kind of trade, because
-- choosing is exactly what can be cornered in a test and "ask the client and hope" is not.
--
--   StowSlot(bags, contents) -> bagId, slot.  contents[bagId][slot] = true where something already is

H.eq(select("#", C.StowSlot({}, {})), 2, "the answer is always a pair, even when it is nil, nil")

local BAGS = { { id = 0, free = 1, family = 0, size = 4 }, { id = 4, free = 2, family = 0, size = 3 } }

local bag, slot = C.StowSlot(BAGS, { [0] = { true, true, true } })
H.eq(bag, 0, "the first usable bag with a free slot wins, backpack first")
H.eq(slot, 4, "…and the slot chosen is the first EMPTY one, not slot 1")

-- The case Pobble actually had: a full backpack and every free slot in the last bag. The old code
-- turned this into a single PutItemInBag against bag 4, which is the call that does nothing.
bag, slot = C.StowSlot(BAGS, { [0] = { true, true, true, true }, [4] = { true } })
H.eq(bag, 4, "a full bag is passed over for the next one with room")
H.eq(slot, 2, "…and the first free slot in THAT bag is the target")

-- StowBags' rules still apply, because this walks it rather than re-deciding: a special bag's slots
-- are not candidates however empty, and no bag with room means no answer at all.
H.eq(C.StowSlot({ { id = 1, free = 8, family = 1, size = 8 } }, {}), nil,
    "a special bag's empty slots are not offered a shield")
H.eq(C.StowSlot({ { id = 0, free = 0, family = 0, size = 4 } }, {}), nil,
    "a bag with no room yields no slot, so the caller puts nothing anywhere")

-- The disagreement worth catching: `free` comes from the client's own count and the occupancy from
-- reading the slots, so a bag can claim room while every slot reads full. Trusting `free` and
-- returning a slot anyway would put the item nowhere and report success.
H.eq(C.StowSlot({ { id = 2, free = 3, family = 0, size = 2 } }, { [2] = { true, true } }), nil,
    "a bag that claims room but reads full yields nothing rather than a slot that is not empty")

-- A bag whose size the client could not answer has no slots to offer, which must not read as
-- "slot 1 is free" — that would drop the item onto whatever is actually in there.
H.eq(C.StowSlot({ { id = 3, free = 2, family = 0 } }, {}), nil,
    "a bag with no known size is skipped rather than assumed to start at slot 1")

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

-- ---------------------------------------------------------------------------
-- Doll — the set inspector's paperdoll (UI-13)
-- ---------------------------------------------------------------------------
--
-- The layout is data because a hand-placed grid of nineteen slots fails silently: a slot listed
-- twice draws over itself and a slot forgotten simply is not there, and neither looks like a bug
-- until someone goes hunting for their off hand.

local seen, cells = {}, 0
for _, column in ipairs({ C.DOLL_LAYOUT.left, C.DOLL_LAYOUT.right, C.DOLL_LAYOUT.bottom }) do
    for _, slotId in ipairs(column) do
        H.ok(not seen[slotId], "slot " .. slotId .. " is placed exactly once on the doll")
        H.ok(C.SlotById(slotId) ~= nil, "…and is a real equippable slot")
        seen[slotId] = true
        cells = cells + 1
    end
end
H.eq(cells, 19, "the doll has a cell for every equippable slot and no more")
H.eq(#C.DOLL_LAYOUT.left, 8, "the left column holds eight, as the character sheet does")
H.eq(#C.DOLL_LAYOUT.right, 8, "…and the right column eight")
H.eq(#C.DOLL_LAYOUT.bottom, 3, "…and the weapons sit in a row of three beneath")

-- The cells themselves are read out of the PLAN, not re-derived from the set, for the same reason
-- Explain is: the panel and the driver must not be able to disagree about what is about to happen.

-- Wearing the helm already, sword waiting in a bag, and the set deliberately empties the tabard.
local dollSet = { name = "Tank", slots = { [1] = HELM, [16] = SWORD, [19] = false } }
local dollPlan = C.Plan({ [1] = HELM, [19] = SWORD }, dollSet,
    { [SWORD] = { bag = 0, slot = 1 } }, { freeBagSlots = 4 })
local doll = C.Doll(dollSet, dollPlan)

H.eq(doll[1].state, "worn", "a slot whose item is already on reads as worn")
H.eq(doll[1].key, HELM, "…and carries the item, so the cell can show its icon")
H.eq(doll[16].state, "swap", "a slot the plan will fill reads as a swap")
H.eq(doll[16].key, SWORD, "…carrying what is going in, not what is coming off")
H.eq(doll[19].state, "clear", "a slot the set deliberately empties reads as clear")
H.eq(doll[19].key, false, "…and ends holding nothing, which is false rather than nil")
H.eq(doll[2].state, "unset", "a slot the set never mentions is untouched, not empty")
H.eq(doll[2].key, nil, "…and has no item of its own")
H.eq(doll[3].slot.label, "Shoulder", "every cell carries its slot record, for the label and tooltip")

local count = 0
for _ in pairs(doll) do count = count + 1 end
H.eq(count, 19, "Doll answers for all nineteen slots, so no cell has to be invented by the caller")

-- A slot the set does not name can still be emptied by the plan: a two-hander frees the off hand.
-- Showing that as "untouched" is exactly the half-applied-swap surprise Kitbag exists to prevent.
local twoHandSet = { name = "Fury", slots = { [16] = TWOHAND } }
local twoHandPlan = C.Plan({ [16] = SWORD, [17] = SHIELD }, twoHandSet,
    { [TWOHAND] = { bag = 0, slot = 1 } },
    { twoHand = { [TWOHAND] = true }, freeBagSlots = 4 })
local twoHandDoll = C.Doll(twoHandSet, twoHandPlan)
H.eq(twoHandDoll[17].state, "clear", "the off hand a two-hander frees is shown as being emptied")
H.eq(twoHandDoll[17].key, false, "…ending empty, though the set never mentioned that slot")

-- What cannot be done has to look different from what merely has not happened yet.
local goneSet = { name = "Gone", slots = { [11] = RING_A, [12] = RING_B } }
local gonePlan = C.Plan({}, goneSet, { [RING_A] = { bag = 0, slot = 1, bank = true } })
local goneDoll = C.Doll(goneSet, gonePlan)
H.eq(goneDoll[11].state, "bank", "an item sitting in the bank says so, rather than reading as lost")
H.eq(goneDoll[11].key, RING_A, "…and still names the item, so the cell can show it greyed")
H.eq(goneDoll[12].state, "missing", "an item found nowhere is missing")

-- Doll is called on every refresh, including before a plan exists. It must degrade, not throw.
local bare = C.Doll({ name = "Bare", slots = { [1] = HELM } }, nil)
H.eq(bare[1].state, "unknown", "with no plan there is no verdict — and 'worn' would be a guess")
H.eq(bare[1].key, HELM, "…but the set's own contents are still worth drawing")
H.eq(bare[2].state, "unset", "…and a slot the set never named is still plainly unset")
H.eq(C.Doll(nil, nil)[1].state, "unset", "no set at all draws an empty doll rather than erroring")

-- ---------------------------------------------------------------------------
-- A set that names nothing at all (UI-16)
-- ---------------------------------------------------------------------------
--
-- An empty set is now a thing that exists: UI-16 creates one so it can be filled in slot by slot
-- from gear that never leaves the bank. It has nothing to do, so it plans as `empty` — but "nothing
-- to do because you are already wearing it" and "nothing to do because it says nothing" are
-- opposite answers, and the window paints the first one green. `empty` alone cannot tell them
-- apart, so the plan says which it is.

plan = C.Plan({ [1] = HELM }, { slots = {} }, {})
H.eq(plan.empty, true, "a set that names nothing has nothing to do")
H.eq(plan.nothing, true, "…but it is empty because it is BLANK, not because you are wearing it")

plan = C.Plan({ [1] = HELM }, { slots = { [1] = HELM } }, {})
H.eq(plan.empty, true, "a set you are already wearing also has nothing to do")
H.eq(plan.nothing, false, "…and that is the other answer entirely — it names something")

-- A set of nothing but deliberate emptiness is NOT blank: "strip to your shirt" is a real set, and
-- it has plenty to say. This is the assertion that keeps `nothing` from being read off the item
-- count, where an all-`false` set would look identical to one that was never filled in.
plan = C.Plan({ [1] = HELM }, { slots = { [1] = false } }, {}, { freeBagSlots = 4 })
H.eq(plan.nothing, false, "a set that deliberately empties a slot is not a blank set")
H.eq(#plan.actions, 1, "…and it has work to do, which a blank set never does")

-- The case where "blank" and "inherits everything" look identical in storage (VERIFY-10). A child
-- set's own delta can be completely empty while the set it describes is fully specified by its
-- parent — that is what inheritance IS. `nothing` is read off `set.slots`, so it gives the right
-- answer only if the plan is built on the RESOLVED set and not on the stored delta. Get that wrong
-- and a perfectly good inheriting set reports "Empty — nothing in it yet" on the row, in the row
-- tooltip, in the inspector and from `/kit equip`, all four agreeing and all four wrong.
--
-- Characterization: this passes today. It is here because the four surfaces above each test the flag
-- separately, so the flag is the one thing that must not quietly change meaning underneath them.
local inheriting = C.Resolve({
    Parent = { slots = { [1] = HELM } },
    Child  = { slots = {}, parent = "Parent" },
}, "Child")
H.eq(next(inheriting.slots) ~= nil, true, "a blank child resolves to its parent's slots")
plan = C.Plan({}, inheriting, {}, { freeBagSlots = 4 })
H.eq(plan.nothing, false,
    "a set whose own delta is empty is NOT blank when it inherits — it is fully specified")

-- ---------------------------------------------------------------------------
-- Readiness — one verdict, read by every surface that says how ready a set is (VERIFY-10)
-- ---------------------------------------------------------------------------
--
-- Four places answer "what stands between you and wearing this": the list row, the row tooltip, the
-- inspector's note and `/kit equip`. Each used to walk its own `if plan.nothing then … elseif
-- plan.empty then …` chain, which means the precedence existed four times and was tested nowhere.
--
-- The order is the whole of it, and one pair in particular: `nothing` MUST be asked before `empty`.
-- A blank set and a set you are already wearing both have no actions and nothing missing, so `empty`
-- is true for both — and getting the order wrong paints a set that says nothing at all green and
-- calls it worn, which is how a half-built set looks finished. That is UI-16's original bug, and
-- with the chain written out four times it could come back in any one of them alone.
--
-- The verdict is a WORD, not a sentence: the four surfaces phrase it differently on purpose ("empty"
-- in a column six characters wide, "Empty — click a slot to say what goes there." under the doll),
-- and pushing the phrasing in here would force them to share wording they have no business sharing.
-- What they must share is which question won.

H.eq(C.Readiness(nil).state, "unknown",
    "no plan yet is its own answer — every other state would be a guess")

H.eq(C.Readiness(C.Plan({ [1] = HELM }, { slots = {} }, {})).state, "blank",
    "a set that names nothing reads as BLANK, not as worn — this is UI-16's whole point")

H.eq(C.Readiness(C.Plan({ [1] = HELM }, { slots = { [1] = HELM } }, {})).state, "worn",
    "…while a set you are already in reads as worn")

-- Bags before missing: a full bag stops the entire swap, so it is the thing to fix first, and a
-- reader told "2 missing" would go looking for gear they are standing on.
local blockedPlan = C.Plan({ [1] = HELM, [5] = "999:0:0:0:0:0:0" },
    { slots = { [1] = false, [5] = false } }, {}, { freeBagSlots = 0 })
local blockedVerdict = C.Readiness(blockedPlan)
H.eq(blockedVerdict.state, "bags", "a plan the bags cannot absorb reads as bags first")
H.eq(blockedVerdict.count, blockedPlan.needsBagSlots,
    "…counting the slots it needs, since 'bags full' alone does not say how many to free")

-- "At bank" only when the bank explains ALL of it. A set that is part banked and part genuinely lost
-- must not send the player on a trip that cannot finish the set.
local banked = C.Readiness({ actions = {}, missing = { { slot = 1 }, { slot = 5 } }, atBank = 2 })
H.eq(banked.state, "bank", "everything missing being at the bank is a walk, not a loss")
H.eq(banked.count, 2, "…and the count is what to expect to find there")

local partly = C.Readiness({ actions = {}, missing = { { slot = 1 }, { slot = 5 } }, atBank = 1 })
H.eq(partly.state, "missing",
    "one piece at the bank and one nowhere is MISSING — a bank trip would not finish the set")
H.eq(partly.count, 2, "…counting everything not to hand, not just the lost half")

local work = C.Readiness(C.Plan({}, { slots = { [1] = HELM } }, { [HELM] = { bag = 0, slot = 1 } },
    { freeBagSlots = 4 }))
H.eq(work.state, "swaps", "a plan with moves in it reads as swaps")
H.eq(work.count, 1, "…counting the moves, which is what the row shows")

-- ---------------------------------------------------------------------------
-- CleanName — the name a set is actually stored under (UI-16)
-- ---------------------------------------------------------------------------
--
-- Three doors create a set now — "save what I'm wearing", "new empty set", and the slash command —
-- and a name that is trimmed at one door and not at another produces two sets whose names look
-- identical in the list. One function, so "Tank" and "Tank " cannot both exist.

H.eq(C.CleanName("Tank"), "Tank", "an ordinary name is left alone")
H.eq(C.CleanName("  Tank  "), "Tank", "surrounding space is trimmed, not stored")
H.eq(C.CleanName("Raid Fire"), "Raid Fire", "a name may contain spaces — sets are named by people")
H.eq(C.CleanName(""), nil, "an empty name is not a name")
H.eq(C.CleanName("   "), nil, "…and neither is one made only of space")
H.eq(C.CleanName(nil), nil, "nil is refused rather than erroring — it arrives from an empty edit box")
H.eq(C.CleanName(42), nil, "…as is anything that is not a string")

-- ---------------------------------------------------------------------------
-- Choices — the wardrobe for one slot, for editing a set (UI-14)
-- ---------------------------------------------------------------------------
--
-- The flyout on the character sheet asks "what else could I be wearing here", so it leaves out what
-- is already on. Editing a SET asks a different question — "what should this set put here" — and
-- there the item currently on your body is the single most likely answer, because building a set
-- usually means taking what you are wearing and changing two pieces. Same fitting rules, one fewer
-- exclusion, so they are one function with the exclusion passed in rather than two that can drift.

local wardrobe = {
    [RING_A] = { bag = 0, slot = 1 },
    [SHIELD] = { bag = 0, slot = 3 },
}
local wardrobeLoc = {
    [RING_A] = "INVTYPE_FINGER",
    [RING_B] = "INVTYPE_FINGER",
    [SHIELD] = "INVTYPE_SHIELD",
}

local choices = C.Choices(11, { [11] = RING_B }, wardrobe, wardrobeLoc)
H.eq(#choices, 2, "editing a slot offers the ring you are wearing as well as the one in the bag")
H.eq(choices[1].key, RING_A, "…sorted, so the panel does not reshuffle between two clicks")
H.eq(choices[1].bag, 0, "…each carrying where it can be found")
H.eq(choices[2].key, RING_B, "…and the worn one is in the list")
H.eq(choices[2].worn, 11, "…marked with the slot it is worn in, so it can be shown as such")

-- A set may perfectly well name an item that is sitting in the bank — the set is a list of what to
-- wear, not a promise about where things are, and the inspector already says "in your bank" when it
-- comes to equipping it. So the editor offers banked items and has to be able to mark them, which
-- means the flag has to survive the trip out of the bag scan.
local banked = C.Choices(1, {}, { [HELM] = { bag = -1, slot = 2, bank = true } },
    { [HELM] = "INVTYPE_HEAD" })
H.eq(#banked, 1, "an item in the bank is still something a set can name")
H.eq(banked[1].bank, true, "…and says so, so the picker can mark it rather than promise it is to hand")

H.eq(#C.Choices(2, {}, wardrobe, wardrobeLoc), 0, "a slot you own nothing for offers nothing")
H.eq(#C.Choices(17, {}, wardrobe, wardrobeLoc), 1, "the off hand offers the shield")
H.eq(#C.Choices(nil, {}, wardrobe, wardrobeLoc), 0, "no slot asked about offers nothing, not an error")

-- Alternatives is Choices with the worn item taken out, and must stay that way: the flyout's whole
-- job is to offer something OTHER than what is on.
H.eq(#C.Alternatives(11, { [11] = RING_B }, wardrobe, wardrobeLoc), 1,
    "the flyout still leaves out the item already in the slot")

-- ---------------------------------------------------------------------------
-- SetSlot — editing one slot of a set (UI-14)
-- ---------------------------------------------------------------------------
--
-- Three states, and the difference between the last two is the one people get wrong: an item, a
-- deliberate `false` ("take whatever is there off"), and absence ("this set has no opinion, keep
-- wearing what you have"). Capture writes false for every empty slot precisely so a set saved
-- bare-headed takes your helmet off; dropping a slot has to be a separate gesture from emptying it.

local edited = { name = "Tank", slots = { [1] = HELM, [16] = SWORD } }

H.eq(C.SetSlot(edited, 16, TWOHAND), true, "putting an item in a slot reports that it changed")
H.eq(edited.slots[16], TWOHAND, "…and the set now names it")
H.eq(C.SetSlot(edited, 17, "item:17066:0:0:0:0:0:0:0:0"), true, "a raw link is accepted")
H.eq(edited.slots[17], SHIELD, "…and normalised to a key, as everything stored in a set is")

H.eq(C.SetSlot(edited, 1, false), true, "a slot can be set to deliberately empty")
H.eq(edited.slots[1], false, "…which stores as false, the same thing capture writes")

H.eq(C.SetSlot(edited, 16, nil), true, "dropping a slot from the set reports a change")
H.eq(edited.slots[16], nil, "…and leaves no opinion behind — absent, not false")
H.eq(C.SetSlot(edited, 16, nil), false, "…and dropping it again changes nothing")

H.eq(C.SetSlot(edited, 99, HELM), false, "an unknown slot id is refused rather than stored")
H.eq(edited.slots[99], nil, "…and nothing is written for it")
H.eq(C.SetSlot(edited, 5, "notanitem"), false, "something that is not an item is refused")
H.eq(edited.slots[5], nil, "…rather than stored as a key that can never be found")
H.eq(C.SetSlot(nil, 1, HELM), false, "no set at all is refused rather than erroring")

-- A set may be stored as a delta on a parent, in which case dropping a slot means "let the parent
-- decide" rather than "wear nothing" — which is exactly what absence already means to Resolve. This
-- is the assertion that keeps the editing gesture and the inheritance rule in agreement.
local parent = { name = "Base", slots = { [1] = HELM, [16] = SWORD } }
local child = { name = "Fire", parent = "Base", slots = { [16] = TWOHAND } }
local family = { Base = parent, Fire = child }
H.eq(C.Resolve(family, "Fire").slots[16], TWOHAND, "a child overrides its parent's slot")
C.SetSlot(child, 16, nil)
H.eq(C.Resolve(family, "Fire").slots[16], SWORD, "dropping the override hands the slot back to the parent")
C.SetSlot(child, 16, false)
H.eq(C.Resolve(family, "Fire").slots[16], false, "…where emptying it instead overrides the parent with nothing")

-- ---------------------------------------------------------------------------
-- SaveLoss — what re-saving over an existing set would throw away (BUG-3)
-- ---------------------------------------------------------------------------
--
-- "Save what I'm wearing" over a set that already exists is the normal way to keep a set current,
-- and it is also the one gesture that can destroy work no capture can put back: a set built by hand
-- out of bank gear names items that are not on your body.
--
-- The rule that separates the two, and the reason this is not a blanket "are you sure": a slot is
-- only LOST when the set names an item the capture does not hold ANYWHERE. Moving a trinket between
-- the two trinket slots loses nothing, because the item is still in the capture. Asking every time
-- would train the player to click through the one prompt that matters.

local BANK_RING = "19147:0:0:0:0:0:0"
local worn = { [1] = HELM, [11] = RING_A, [12] = RING_B, [16] = SWORD }

H.eq(#C.SaveLoss({ slots = worn }, worn), 0,
    "re-saving a set you are already wearing loses nothing")
H.eq(#C.SaveLoss({ slots = { [11] = RING_A, [12] = RING_B } }, { [11] = RING_B, [12] = RING_A }), 0,
    "swapping two items between slots is not a loss — both are still in the capture")

local lost = C.SaveLoss({ slots = { [1] = HELM, [11] = BANK_RING } }, worn)
H.eq(#lost, 1, "a set naming an item you are not wearing loses exactly that slot")
H.eq(lost[1].slot, 11, "…reported by the slot the set named it in")
H.eq(lost[1].key, BANK_RING, "…and by the item, so the prompt can name what it is about to drop")

local many = C.SaveLoss({ slots = { [16] = TWOHAND, [1] = HELM, [11] = BANK_RING } }, { [1] = HELM })
H.eq(#many, 2, "every unrecoverable slot is reported, not just the first")
H.ok(many[1].slot < many[2].slot,
    "…in slot order, because a prompt that reshuffles itself cannot be read twice")

H.eq(#C.SaveLoss({ slots = { [1] = false } }, worn), 0,
    "a slot the set deliberately empties is not a loss — false is not an item to lose")
H.eq(#C.SaveLoss({ slots = {} }, worn), 0, "an empty set has nothing to lose")
H.eq(#C.SaveLoss(nil, worn), 0, "no set at all loses nothing, rather than erroring")
H.eq(#C.SaveLoss({ slots = { [1] = HELM } }, nil), 1,
    "…while wearing nothing at all loses every item the set named")

-- ---------------------------------------------------------------------------
-- ScrollOffset (VERIFY-11)
-- ---------------------------------------------------------------------------
--
-- Both scrolling lists — the set list and the rule list — read their row offset straight out of
-- Blizzard's FauxScrollFrame and index the data with it. Nothing clamps it against the data, so a
-- list that SHRINKS while scrolled down keeps an offset the shortened list cannot support, every row
-- indexes past the end, and the frame goes blank. That is not a cosmetic fault: to the player the
-- rules have vanished, and the natural response to a blank list is to write them again.
--
-- Trusting FauxScrollFrame_Update to fix this up is the assumption worth refusing. It is Blizzard
-- internals, its clamping differs between flavours, and it is invisible from here — which is exactly
-- the shape of thing this codebase makes pure and tests instead.

H.eq(C.ScrollOffset(20, 8, 5), 5, "an offset the list can support is used as-is")
H.eq(C.ScrollOffset(20, 8, 12), 12, "…including the very last one that still fills the rows")
H.eq(C.ScrollOffset(20, 8, 13), 12, "an offset past the end is pulled back to the last full page")
H.eq(C.ScrollOffset(20, 8, 999), 12, "…however far past the end it is")

-- The one that matters: deleting rules until fewer remain than there are rows. The backlog calls
-- this out by name — "puts the list back at the top rather than leaving it blank".
H.eq(C.ScrollOffset(5, 8, 4), 0, "a list shorter than its rows goes back to the top, never blank")
H.eq(C.ScrollOffset(8, 8, 3), 0, "…and one exactly filling its rows has nowhere to scroll to")
H.eq(C.ScrollOffset(0, 8, 6), 0, "an emptied list goes to the top rather than indexing nowhere")
H.eq(C.ScrollOffset(9, 8, 5), 1, "one row past a full page scrolls by exactly one")

-- Junk in. This runs on every redraw, including the redraw that follows a delete, so it must not be
-- the thing that throws.
H.eq(C.ScrollOffset(20, 8, -3), 0, "a negative offset is not trusted either")
H.eq(C.ScrollOffset(20, 8, nil), 0, "a missing offset reads as the top")
H.eq(C.ScrollOffset(nil, 8, 4), 0, "no count at all reads as an empty list")
H.eq(C.ScrollOffset(20, nil, 4), 0, "no row count reads as no room, so nothing is indexed")
H.eq(C.ScrollOffset(20, 8, 4.7), 4, "a fractional offset is floored, since it indexes a table")

-- ---------------------------------------------------------------------------
-- DeleteImpact (BUG-8)
-- ---------------------------------------------------------------------------
--
-- Deleting a set is the one unrecoverable thing the window does, so it asks first — and the question
-- has to name the CONSEQUENCES, not just the set. A set with children does not simply vanish: the
-- children keep working but quietly shrink to their own slots, which is discovered later by equipping
-- one and finding half an outfit.
--
-- Same shape as ParentChoices (UI-11): Sets.Delete could report the orphans afterwards, but a
-- confirmation has to know them BEFORE it is drawn. One pure answer, so the prompt and the delete
-- cannot disagree about what is about to happen.

local family = {
    Base = { name = "Base", slots = { [1] = HELM } },
    Fire = { name = "Fire", parent = "Base", slots = { [16] = SWORD } },
    Frost = { name = "Frost", parent = "Base", slots = { [16] = TWOHAND } },
    Alone = { name = "Alone", slots = { [5] = CHEST } },
}

local impact = C.DeleteImpact(family, "Base")
H.eq(impact.exists, true, "deleting a set that is there is possible")
H.eq(#impact.orphans, 2, "every set that inherits from it is counted")
H.eq(impact.orphans[1], "Fire", "…named, so the prompt can list them")
H.eq(impact.orphans[2], "Frost", "…in name order, so the prompt reads the same twice running")

local lonely = C.DeleteImpact(family, "Alone")
H.eq(lonely.exists, true, "a set with no children is still deletable")
H.eq(#lonely.orphans, 0, "…and orphans nobody, so the prompt stays short")

-- A child being deleted takes nothing with it — the direction of the relationship matters, and
-- getting it backwards would warn about the parent every time a child was removed.
H.eq(#C.DeleteImpact(family, "Fire").orphans, 0, "deleting a CHILD orphans nothing")

local missing = C.DeleteImpact(family, "Nope")
H.eq(missing.exists, false, "a set that is not there reports so rather than erroring")
H.eq(#missing.orphans, 0, "…and orphans nothing")

H.eq(C.DeleteImpact(nil, "Base").exists, false, "no sets at all is not a crash")
H.eq(C.DeleteImpact(family, nil).exists, false, "no name at all is not a crash")

-- ---------------------------------------------------------------------------
-- CopySet — a set as another character would have to store it (CORE-7)
-- ---------------------------------------------------------------------------
--
-- The sharp one is inheritance. A stored child holds only what differs from its parent, and the
-- parent is another set in THIS character's list. Copying the delta across hands the alt a set that
-- resolves against a parent it does not have — which is not an error, because Resolve treats a
-- missing parent as contributing nothing. It is the "it half-applied my set" report, arriving as a
-- set that looks complete in the list and turns out to be two slots.

local copy, why = C.CopySet(family, "Fire", {})
H.eq(why, nil, "copying a set that exists is allowed")
H.eq(copy.name, "Fire", "the copy keeps its name")
H.eq(copy.slots[16], SWORD, "…and its own slots")
H.eq(copy.slots[1], HELM, "…AND the slots it was inheriting, flattened in")
H.eq(copy.parent, nil, "the copy inherits from nothing — the alt has no such parent set")

-- Deep, not shared. Two characters' set lists live in one saved file, so a shared slots table would
-- make editing the alt's copy silently edit the original, and the two would look independent.
copy.slots[16] = TWOHAND
H.eq(family.Fire.slots[16], SWORD, "editing the copy does not reach back into the original")

local iconed = { Kept = { name = "Kept", icon = "Interface\\Icons\\Ability_Warrior_Rampage",
    slots = { [1] = HELM } } }
H.eq(C.CopySet(iconed, "Kept", {}).icon, "Interface\\Icons\\Ability_Warrior_Rampage",
    "a chosen icon travels with the set — it is the set's identity in the list")

-- Refusals. Never overwrite: the same judgement Sets.New and the ItemRack import make, and for the
-- same reason — replacing a curated set is unrecoverable and refusing is not.
local clash = { Fire = { name = "Fire", slots = {} } }
local blocked, reason = C.CopySet(family, "Fire", clash)
H.eq(blocked, nil, "a name the target already uses is refused rather than overwritten")
H.eq(reason, "exists", "…and says which refusal it was, so the caller can name the clash")

local gone, goneWhy = C.CopySet(family, "Nope", {})
H.eq(gone, nil, "copying a set that does not exist is refused")
H.eq(goneWhy, "no-set", "…distinctly from a clash, because they ask different things of the player")

local same, sameWhy = C.CopySet(family, "Alone", family)
H.eq(same, nil, "copying a set onto its own character is refused")
H.eq(sameWhy, "same", "…named, because 'Alone already exists' would be a baffling way to say it")

H.eq(C.CopySet(nil, "Fire", {}), nil, "no source list at all is not a crash")
H.eq(C.CopySet(family, "Fire", nil), nil, "no target list at all is not a crash")

-- ---------------------------------------------------------------------------
-- CopyChoices — who a copy can be offered to, and who already has the name (UI-20)
-- ---------------------------------------------------------------------------
--
-- `CopySet` refuses a name the target already uses, which is the right answer for a typed command
-- and the wrong one for a click: the refusal arrives AFTER the press, naming a character the player
-- has already chosen. A menu has to know the clash before it draws the entry, so the knowledge
-- lives here — one list, marked — rather than the window asking a second question of its own and
-- getting an answer that could drift from the one `CopyTo` will give.
--
-- Self is left off entirely rather than marked, the UI-11 way: a choice that will be refused is
-- worse than a shorter menu. Compared by BUCKET identity, not by key, so this cannot disagree with
-- `CopySet`'s `same` refusal — that one is by identity too.

local mine  = { Fire = { name = "Fire", slots = {} } }
local alt   = { Fire = { name = "Fire", slots = {} }, Tank = { name = "Tank", slots = {} } }
local roster = {
    ["Pobble - Whitemane"]    = { sets = mine },
    ["Deller - Whitemane"]    = { sets = alt },
    ["Rinanella - Whitemane"] = { sets = {} },
}

local choices = C.CopyChoices(roster, roster["Pobble - Whitemane"], "Fire")
H.eq(#choices, 2, "every OTHER character is a choice")
H.eq(choices[1].key, "Deller - Whitemane", "sorted, so the menu does not reorder between opens")
H.eq(choices[2].key, "Rinanella - Whitemane", "…all the way down")
H.eq(choices[1].taken, true, "a character that already has a set of that name is marked")
H.eq(choices[2].taken, false, "…and one that does not is not")

local other = C.CopyChoices(roster, roster["Pobble - Whitemane"], "Tank")
H.eq(other[1].taken, true, "the mark is about THIS name, not about having any sets at all")
H.eq(other[2].taken, false, "…and an empty character takes anything")

-- The bucket, not the key: whatever `chars` files this character under, the one thing that must
-- never be offered is the list the copy would come FROM.
local aliased = { A = roster["Pobble - Whitemane"], B = roster["Deller - Whitemane"] }
local byIdentity = C.CopyChoices(aliased, roster["Pobble - Whitemane"], "Fire")
H.eq(#byIdentity, 1, "self is excluded by bucket identity, whatever key it is filed under")
H.eq(byIdentity[1].key, "B", "…leaving the others")

H.eq(#C.CopyChoices(nil, {}, "Fire"), 0, "no roster at all is not a crash")
H.eq(#C.CopyChoices(roster, nil, "Fire"), 3, "no own bucket excludes nobody rather than erroring")
H.eq(C.CopyChoices(roster, roster["Pobble - Whitemane"], nil)[1].taken, false,
    "no name at all marks nothing as taken — there is no clash to have yet")


-- ---------------------------------------------------------------------------
-- CanSwap — may gear move right now (UI-19)
-- ---------------------------------------------------------------------------
--
-- The point of answering this here rather than in each frame: the window, the trinket bar and the
-- paperdoll flyouts must not each grow their own opinion of what "dead" means. `Compat.IsBusy`
-- decides whether the driver acts, and this decides whether the control offering the action is even
-- pressable. If those two ever disagree you get back exactly the bug UI-19 describes — a button
-- that looks live and reports failure ten seconds later.
--
-- Takes a `Compat.ActionState()`-shaped table, which is what makes it answerable without dying.

H.ok(C.CanSwap({ combat = false, mounted = false, dead = false, casting = false }),
    "a live, idle player may swap")

local blockedDead, deadWhy = C.CanSwap({ dead = true })
H.eq(blockedDead, false, "a dead or ghost player may not swap")
H.eq(deadWhy, "dead", "…and says which condition stopped it, so the tooltip can explain the grey")

local blockedCast, castWhy = C.CanSwap({ casting = true })
H.eq(blockedCast, false, "a casting player may not swap — a swap mid-cast cancels the cast")
H.eq(castWhy, "casting", "…named distinctly from death, which asks a different thing of the player")

-- Combat and mounted are recorded by ActionState and are deliberately NOT blockers: we do not yet
-- know that the client refuses either, and greying a control the client would have honoured is a
-- worse bug than the one this fixes.
H.ok(C.CanSwap({ combat = true, mounted = true }),
    "combat and mounted are recorded, not refused — guessing would block swaps the client allows")

-- Dead outranks casting: a cast ends by itself in a second or two and death does not, so naming the
-- transient one would send the player off to wait for the wrong thing to pass.
H.eq(select(2, C.CanSwap({ dead = true, casting = true })), "dead",
    "when both hold, the durable condition is the one named")

-- A state that could not be read must not grey the button. Refusing on an absent reading would
-- disable the controls on any flavour whose API we failed to call, silently and permanently.
H.ok(C.CanSwap(nil), "an unreadable state allows the swap rather than blocking it forever")
H.ok(C.CanSwap({}), "an empty state is 'nothing is wrong', not 'everything is'")

-- The wording lives with the decision for the same reason the decision does: three frames writing
-- their own sentence is three chances to explain the grey differently, or not at all (UI-11).
H.ok(type(C.SWAP_BLOCKED) == "table", "the reasons carry player-facing wording")
H.ok(type(C.SWAP_BLOCKED.dead) == "string" and type(C.SWAP_BLOCKED.casting) == "string",
    "…for every reason CanSwap can return")


-- ---------------------------------------------------------------------------
-- BindingKey — a keystroke composed into a binding string (UI-12)
-- ---------------------------------------------------------------------------
--
-- Capturing a key is three lines of frame code; deciding what the keystroke MEANS is where the
-- mistakes are, so that half lives here. The order of the modifiers is Blizzard's own —
-- ALT-CTRL-SHIFT-KEY — and it is not a preference: `SetBindingClick` matches the string, so
-- "SHIFT-ALT-E" binds a key nobody can press.

H.eq(C.BindingKey("E"), "E", "an unmodified key is its own binding")
H.eq(C.BindingKey("E", true), "SHIFT-E", "shift composes onto the front")
H.eq(C.BindingKey("E", false, true), "CTRL-E", "so does ctrl")
H.eq(C.BindingKey("E", false, false, true), "ALT-E", "and alt")
H.eq(C.BindingKey("E", true, true, true), "ALT-CTRL-SHIFT-E",
    "all three compose in Blizzard's order — SetBindingClick matches the string, so the order is "
    .. "correctness rather than taste")
H.eq(C.BindingKey("F12", true), "SHIFT-F12", "a named key is used as the client gives it")

-- A modifier held on its own is the player part-way through a chord, not a binding. Taking it would
-- bind SHIFT the moment they reached for SHIFT-E, and SHIFT is not a key anyone wants to lose.
for _, mod in ipairs({ "LSHIFT", "RSHIFT", "LCTRL", "RCTRL", "LALT", "RALT" }) do
    H.eq(C.BindingKey(mod, true), nil, mod .. " alone is a chord in progress, not a binding")
end

-- ESCAPE is refused here rather than only in the frame that captures it. It closes every window in
-- the game, and a build where some other path could bind it is a build where the player cannot get
-- out of the window they bound it from.
H.eq(C.BindingKey("ESCAPE"), nil, "ESCAPE is never a binding, whatever asks")
H.eq(C.BindingKey("ESCAPE", true, true, true), nil, "…modifiers do not make it one")
H.eq(C.BindingKey(nil), nil, "no key at all is nil rather than an error")
H.eq(C.BindingKey(""), nil, "an empty key is nil — the client sends one for some devices")

-- ---------------------------------------------------------------------------
-- BindingImpact — what giving a set a key would cost (UI-12)
-- ---------------------------------------------------------------------------
--
-- The same shape as DeleteImpact and for the same reason: the window has to know the consequence
-- BEFORE it acts, so the control and the act cannot disagree about what is going to happen.
--
-- The consequence worth knowing is that keys are exclusive. `Import.BindingPlan` settles two sets
-- claiming one key by set name — arbitrary but stable, which is the right answer for an ItemRack
-- import where nobody chose. It is the WRONG answer for a deliberate press: assign SHIFT-E to
-- "Raid" while "Farm" holds it and the plan hands the key back to "Farm", so the binding the player
-- just made silently does nothing. A deliberate act wins, and the set it took the key from is named
-- so the player is told rather than left to find out.

local KEYED = {
    Farm = { name = "Farm", key = "SHIFT-E", slots = {} },
    Raid = { name = "Raid", slots = {} },
    Bank = { name = "Bank", key = "CTRL-B", slots = {} },
}

local free = C.BindingImpact(KEYED, "Raid", "SHIFT-Q")
H.eq(free.ok, true, "a key nobody holds is simply assigned")
H.eq(free.taken, nil, "…and takes it from nobody")

local stolen = C.BindingImpact(KEYED, "Raid", "SHIFT-E")
H.eq(stolen.ok, true, "a key another set holds is still assigned — a deliberate press wins")
H.eq(stolen.taken, "Farm", "…and names the set it has to be taken from, so the player is told")

-- The set it names must be the one that loses it. Nothing else here reads that field, so an
-- off-by-one in the search would be invisible until someone lost a binding they never touched.
H.eq(C.BindingImpact(KEYED, "Bank", "SHIFT-E").taken, "Farm",
    "the loser is found by the key, not by the order of the list")

local same = C.BindingImpact(KEYED, "Farm", "SHIFT-E")
H.eq(same.ok, true, "re-pressing a set's own key is allowed")
H.eq(same.taken, nil, "…and does not report the set as stealing from itself")

local cleared = C.BindingImpact(KEYED, "Farm", nil)
H.eq(cleared.ok, true, "clearing a key is allowed")
H.eq(cleared.taken, nil, "…and takes nothing from anyone")

H.eq(C.BindingImpact(KEYED, "Nope", "SHIFT-E").ok, false,
    "a set that does not exist cannot be given a key")
H.eq(C.BindingImpact(KEYED, "Nope", "SHIFT-E").why, "no-set",
    "…and says why, distinctly, because the window and the slash command answer it differently")
H.eq(C.BindingImpact(nil, "Farm", "SHIFT-E").ok, false, "no set list at all is not a crash")

-- ---------------------------------------------------------------------------
-- BindingLabel — what the key button says before and after a proposal (UI-30)
-- ---------------------------------------------------------------------------
--
-- A capture is no longer the change: it is a proposal the player must confirm with Enter. The
-- label is pure so the consequence shown at the button cannot drift away from BindingImpact's
-- answer between the capture and the commit.
H.eq(C.BindingLabel(nil, nil), "Key…", "an unbound set invites a new key")
H.eq(C.BindingLabel("CTRL-1", nil), "CTRL-1", "a bound set shows its committed key")
H.eq(C.BindingLabel("CTRL-1", "SHIFT-E", { ok = true }),
    "SHIFT-E — Enter to keep, Escape to cancel",
    "a captured key is proposed, not committed")
H.eq(C.BindingLabel("CTRL-1", "SHIFT-E", { ok = true, taken = "Farm" }),
    "SHIFT-E — Enter to keep, Escape to cancel (takes it from Farm)",
    "the proposal names the other set that would lose the key")

-- The impact must not be the change. A question that mutates would make the confirmation and the
-- act the same event, and the window asks this on every redraw to draw the button's label.
C.BindingImpact(KEYED, "Raid", "SHIFT-E")
H.eq(KEYED.Farm.key, "SHIFT-E", "asking what a binding would cost changes nothing")
H.eq(KEYED.Raid.key, nil, "…on either side of the exchange")


-- Every holder, not just the first one found. An ItemRack import can leave two sets carrying one
-- key — BindingPlan picks which of them BINDS without disturbing the losers' stored key — so
-- clearing one and stopping would leave the other still claiming it, and the player's brand-new
-- binding would lose the very next arbitration. Sorted, because `pairs` has no order and a chat
-- line that names a different set on each run is worse than one that names the wrong set every time.
local DOUBLED = {
    Alpha = { name = "Alpha", key = "SHIFT-E", slots = {} },
    Beta = { name = "Beta", key = "SHIFT-E", slots = {} },
    Mine = { name = "Mine", slots = {} },
}
local both = C.BindingImpact(DOUBLED, "Mine", "SHIFT-E")
H.eq(#both.takenFrom, 2, "both sets holding the key are reported, not the first one found")
H.eq(both.takenFrom[1], "Alpha", "…in a stable order")
H.eq(both.takenFrom[2], "Beta", "…so the same press reports the same thing twice running")
H.eq(both.taken, "Alpha", "`taken` is the one to name in a message: the first of them")


-- ---------------------------------------------------------------------------
-- RenameImpact (UI-29)
-- ---------------------------------------------------------------------------
--
-- A rename is not a rename of one string. A set's name is its identity everywhere else in the addon:
-- a child holds its parent BY NAME, a rule names its set BY NAME, and a keybinding is keyed by the
-- set it belongs to. Change the name in the list alone and every one of those becomes a pointer to a
-- set that does not exist — and none of them says so. `Resolve` treats a missing parent as
-- contributing nothing, so an orphaned child equips half an outfit and looks fine in the list.
--
-- DeleteImpact's shape, and for DeleteImpact's reason: the window has to know the consequence BEFORE
-- it is drawn, so the confirmation and the act cannot form two opinions of what is about to happen.
-- A question, never the change.

local kin = {
    Base  = { name = "Base", slots = {}, key = "SHIFT-E" },
    Child = { name = "Child", parent = "Base", slots = {} },
    Other = { name = "Other", parent = "Base", slots = {} },
    Alone = { name = "Alone", slots = {} },
}
local kinRules = {
    { set = "Base",  priority = 50 },
    { set = "Alone", priority = 10 },
    { set = "Base",  priority = 20 },
}

local ren = C.RenameImpact(kin, kinRules, "Base", "Tank")
H.eq(ren.ok, true, "renaming a set that exists to an unused name is allowed")
H.eq(ren.why, nil, "…with no refusal to explain")
H.eq(ren.name, "Tank", "the impact carries the name that will actually be stored")
H.eq(#ren.children, 2, "every set inheriting from the old name is reported")
H.eq(ren.children[1], "Child", "…in a stable order, so one press reports the same twice running")
H.eq(ren.children[2], "Other", "…and the second of them")
H.eq(#ren.rules, 2, "every rule naming the old set is reported")
H.eq(ren.rules[1], 1, "…by index, because a rule has no other identity")
H.eq(ren.rules[2], 3, "…in list order, not pairs() order")
H.eq(ren.key, "SHIFT-E", "the keybinding travelling with the set is named, so it can be re-applied")

-- Only downwards, exactly as DeleteImpact goes: renaming a CHILD changes nothing for its parent, and
-- getting the direction backwards would warn about the parent on every rename of a child.
local child = C.RenameImpact(kin, kinRules, "Child", "Sprog")
H.eq(#child.children, 0, "renaming a child reports no children of its own")
H.eq(#child.rules, 0, "…and no rules, because none names it")
H.eq(child.key, nil, "…and no key, because it carries none")

-- The refusals. Distinguished rather than folded into one false, for CopySet's reason: "that name is
-- taken" and "that is not a name" want different responses from the player.
H.eq(C.RenameImpact(kin, kinRules, "Nobody", "Tank").why, "no-set",
    "renaming a set that does not exist is refused, and says which half is wrong")
H.eq(C.RenameImpact(kin, kinRules, "Base", "Alone").why, "exists",
    "renaming onto a name already in use is refused BEFORE the press, not after")
H.eq(C.RenameImpact(kin, kinRules, "Base", "   ").why, "bad-name",
    "a name that is only whitespace is not a name")
H.eq(C.RenameImpact(kin, kinRules, "Base", nil).why, "bad-name", "…and neither is nothing at all")
H.eq(C.RenameImpact(nil, kinRules, "Base", "Tank").why, "no-set", "a missing set list is refused")

-- Trimming happens HERE, or it happens in one door and not another and the list ends up holding
-- "Tank" and "Tank " looking identical (CleanName's whole reason for existing).
local padded = C.RenameImpact(kin, kinRules, "Base", "  Tank  ")
H.eq(padded.ok, true, "a padded name is trimmed rather than refused")
H.eq(padded.name, "Tank", "…and the impact names the trimmed form, which is what will be stored")
H.eq(C.RenameImpact(kin, kinRules, "Base", " Base ").why, "same",
    "renaming a set to the name it already has is a no-op, not a clash with itself")

-- Rules are ICED but their data is not (see Icebox/README.md), and a rename that skipped them would
-- leave a stored rule pointing at nothing for whenever the engine comes back. Absent rules are an
-- empty answer rather than an error, because that is what every caller passes today.
local noRules = C.RenameImpact(kin, nil, "Base", "Tank")
H.eq(noRules.ok, true, "a caller with no rules at all still gets an answer")
H.eq(#noRules.rules, 0, "…and it is an empty list rather than a nil to guard against")

H.done()
