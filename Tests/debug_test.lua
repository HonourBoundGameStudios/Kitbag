-- KitbagDebug — the dump the Admiral clicks and the agent reads.
--
-- The addon cannot talk to anything outside the client: no sockets, no HTTP, no file IO. The one
-- sanctioned channel is SavedVariables, written on /reload. So diagnosis works like this — a button
-- writes the whole world into KitbagDB, the player reloads, and the agent reads the file off disk.
-- That makes the FORMAT the load-bearing part: a line that omits the thing that was wrong costs a
-- whole round trip through another human being, which is the cost this file exists to remove.
--
-- Usage: lua Tests/debug_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

dofile("KitbagCompat.lua")
dofile("KitbagCore.lua")
local D = dofile("KitbagDebug.lua")

H.start("KitbagDebug")

local SWORD = "item:1234"
local TWOHAND = "item:5678"
local SHIELD = "item:9999"

-- Report(world) -> { <line>, … }. Pure: it is handed a plain reading of the world and returns text.
local function report(world)
    return table.concat(D.Report(world), "\n")
end

local function has(text, want, msg)
    H.ok(text:find(want, 1, true) ~= nil, msg)
end

local world = {
    when = "2026-08-13 23:42:52",
    flavour = "Classic Era",
    interface = 11507,
    version = "0.1.0",
    worn = { [16] = TWOHAND },
    bags = { { id = 0, free = 2, family = 0 }, { id = 1, free = 0, family = 0 } },
    sets = {
        { name = "FASTHOJ+TRAVEL", parent = nil,
          slots = { [16] = TWOHAND, [17] = false },
          plan = { actions = { { kind = "unequip", to = 17, key = SHIELD } },
                   missing = {}, needsBagSlots = 1, blocked = nil } },
        { name = "AAA", parent = "FASTHOJ+TRAVEL",
          slots = { [16] = SWORD },
          plan = { actions = {}, missing = { { slot = 16, key = SWORD, where = "bank" } },
                   needsBagSlots = 0, blocked = "bags" } },
    },
}
local text = report(world)

-- The header. Which build produced the dump matters more than anything else in it: half of a bug
-- report is finding out the client was running yesterday's file (see UI-15's blank panel).
has(text, "2026-08-13 23:42:52", "the dump is stamped, so a stale one is obvious")
has(text, "Classic Era", "…and says which flavour it came from")
has(text, "11507", "…and the interface number the client actually loaded")
has(text, "0.1.0", "…and the addon version, so a stale deploy cannot masquerade as a bug")

-- The world the planner read. Slots are named, not numbered: "17" means nothing to a reader and the
-- whole point is that the reader is not holding this file open.
has(text, "Main hand", "worn gear is listed by slot label, not by id")
has(text, "16", "…with the raw id too, since that is what the plan's actions carry")
has(text, TWOHAND, "…and the item key exactly as stored, enchant and suffix included")
has(text, "17: (nothing)", "an EMPTY slot is stated, not omitted — 'nothing there' is an answer")

has(text, "bag 0: 2 free", "each bag's free count is dumped")
has(text, "bag 1: 0 free", "…including the full ones, which is where 'That bag is full' came from")

-- Every set, and what it actually stores. `false` and absent are different answers and must not
-- print the same way; conflating them is the bug behind half the equip reports.
has(text, 'set "FASTHOJ+TRAVEL"', "each set is dumped by name")
has(text, "Off hand = (empty)", "a slot stored as false reads as a deliberate empty")
has(text, "Main hand = " .. TWOHAND, "…and a named item reads as its key")
has(text, "inherits FASTHOJ+TRAVEL", "a child names its parent, since its slots are only half the set")

-- The plan the driver would be handed. This is the answer to "why did it say stuck on Off hand".
has(text, "unequip -> Off hand", "each planned action reads as verb and slot")
has(text, "needs 1 bag slot", "…with the bag cost the guard compares against")
has(text, "missing: Main hand", "an item the plan could not find is named by slot")
has(text, "bank", "…and says it is at the bank rather than lost")
has(text, "blocked: bags", "a refused plan says why, in the same word the code uses")

-- Order is fixed so two dumps can be diffed. pairs() order would make every dump look changed.
H.ok(text:find('set "AAA"', 1, true) < text:find('set "FASTHOJ+TRAVEL"', 1, true),
    "sets are dumped in name order, so two dumps can be diffed")

-- Robustness. A dump is asked for precisely when something is wrong, so it must survive a world
-- that is already broken — a nil plan, no sets, no bags. A debug tool that errors is worse than no
-- debug tool: it hides the bug behind its own.
H.ok(pcall(D.Report, { when = "now", sets = {} }), "a world with no sets dumps rather than erroring")
H.ok(pcall(D.Report, { when = "now", sets = { { name = "X", slots = {} } } }),
    "a set whose plan could not be built dumps rather than erroring")
H.ok(pcall(D.Report, {}), "an empty world dumps rather than erroring")

H.done()
