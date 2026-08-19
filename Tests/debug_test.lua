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

-- ---------------------------------------------------------------------------
-- The world the swap was attempted in (EPIC-VERIFY)
-- ---------------------------------------------------------------------------
--
-- Gear, bags and plans answer "did the swap work". The forms the client reported and the conditions
-- the player was under when it ran are the rest of that answer, and a dump that cannot show them
-- costs a second /reload for every question — and a /reload is a loading screen for a human.
--
-- This section used to cover the rule engine's half too: the state it matched on, every rule and why
-- it fired. The engine is shelved (Icebox/), and those sections went out of the dump with it.

local ruled = {
    when = "2026-08-14 10:00:00",
    schema = 2,
    -- Index 0 always exists and is not a form; a class with no forms has only this.
    forms = { [0] = "no form", [1] = "Bear Form", [3] = "form 3" },
    state = { combat = true, mounted = true, stealth = false, dead = false, casting = false },
    sets = {},
}
local rtext = report(ruled)

-- Which schema the stored data is at. The 1 -> 2 migration runs exactly once on data nobody can
-- regenerate (VERIFY-5), so "did it run" must be readable without guessing from the shape of a set.
has(rtext, "db schema: 2", "the dump states the schema the stored data is at")

-- The forms the CLIENT reported, verbatim. GetShapeshiftFormInfo's signature differs per flavour and
-- getting it wrong does not error — it silently labels everything "form <n>". That fallback string is
-- therefore the fingerprint of the bug, and it has to survive into the dump unchanged to be spotted.
has(rtext, "FORMS", "the shapeshift forms the client reported are a section of their own")
has(rtext, "0: no form", "…including index 0, which every class has")
has(rtext, "1: Bear Form", "…named, which is what proves the per-flavour signature was read right")
has(rtext, "3: form 3", "…and an unnamed form keeps its fallback, the fingerprint of a wrong signature")

-- What the player was under when the dump was taken. Sorted, and false is stated: "the dump did not
-- mention stealth" and "the player was not stealthed" are different facts that must not look alike.
has(rtext, "STATE", "the conditions the player was under are dumped")
has(rtext, "combat = true", "…each key with its value")
has(rtext, "mounted = true", "…including the one that triggers most of the reports this answers")
has(rtext, "stealth = false", "…and the false ones, stated rather than omitted")
H.ok(rtext:find("casting = false", 1, true) < rtext:find("mounted = true", 1, true),
    "state keys are dumped in name order, so two dumps can be diffed")


-- ---------------------------------------------------------------------------
-- The last swap attempt, and why it ended that way (BUG-9)
-- ---------------------------------------------------------------------------
--
-- The driver now says why it gave up, but it says it in the chat frame — which is gone by the time
-- anyone thinks to look, and which nobody was watching at the moment it scrolled past. The failure
-- being diagnosed happens once, on a mount, in combat; the round trip that costs a human action is
-- the reload, so the answer has to be waiting in the file when the dump is read rather than needing
-- the fault to be reproduced on demand.

local swapped = report({ when = "now", sets = {}, swaps = { {
    set = "FASTHOJ+TRAVEL", ok = false,
    reason = "stuck on Off hand — the game said: You are mounted.", when = "12:04:31" } } })
has(swapped, "RECENT SWAPS", "the swap history is a section of its own")
has(swapped, "FASTHOJ+TRAVEL", "…naming the set that was attempted")
has(swapped, "failed", "…saying plainly that it did not finish")
has(swapped, "stuck on Off hand — the game said: You are mounted.",
    "…and carrying the client's own words, which is the whole point of the section")
has(swapped, "12:04:31",
    "…stamped, so a failure from an hour ago cannot be read as the one just reproduced")

-- A swap that WORKED is worth as much as one that did not: it is what separates "the rule never
-- fired" from "the rule fired and the equip failed", and those send a reader to opposite files.
local ok = report({ when = "now", sets = {}, swaps = { {
    set = "Heal-PVP", ok = true, when = "12:05:02" } } })
has(ok, "succeeded", "a swap that worked is recorded too — it is how a failed rule is ruled out")

-- And a success carries its reason when it has one, because "succeeded" covers both a set that was
-- equipped and a set that had nothing to do. Those are the two halves of BUG-10 — "a rule that
-- matches can do nothing at all, silently" — and a dump that reads them the same way cannot tell a
-- swap that happened from a swap that was a no-op.
local noop = report({ when = "now", sets = {}, swaps = { {
    set = "Heal-PVP", ok = true, reason = "already wearing it", when = "12:05:02" } } })
has(noop, "already wearing it",
    "a swap that succeeded by having nothing to do says so — it is not the same as one that moved gear")

-- The reason there is a history at all. SavedVariables reaches disk on /reload, so two attempts
-- before one reload used to leave only the second — and a reader then diagnoses an attempt nobody
-- asked about. That happened three times in one session on 2026-08-16.
local both = report({ when = "now", sets = {}, swaps = {
    { set = "PVE-Heal", ok = false, reason = "stuck on Chest", when = "12:06:00" },
    { set = "FASTHOJ+TRAVEL", ok = true, when = "12:04:31" },
} })
has(both, "stuck on Chest", "the newest attempt is reported")
has(both, "FASTHOJ+TRAVEL", "…and the one before it survives rather than being overwritten")
H.ok(both:find("PVE-Heal", 1, true) < both:find("FASTHOJ+TRAVEL", 1, true),
    "newest first, so the attempt just made is the one at the top")

-- Nothing attempted yet is a third state, and not the same as a swap that failed silently.
has(report({ when = "now", sets = {} }), "(nothing attempted",
    "no swap since login says so rather than the section going missing")

-- The world at the moment it failed, which is the belt to UI_ERROR_MESSAGE's braces. The client is
-- not obliged to say anything at all when it refuses an action, and a bare "stuck on Off hand" would
-- leave BUG-9 exactly where it started. Every condition is stated in BOTH directions: "not in
-- combat" is the line that RULES OUT the leading suspect, and a reader must never have to infer an
-- absence from a missing word.
local stated = report({ when = "now", sets = {}, swaps = { {
    set = "FASTHOJ+TRAVEL", ok = false, reason = "stuck on Off hand", when = "12:04:31",
    state = { combat = true, mounted = true, dead = false, casting = false } } } })
has(stated, "combat yes", "being in combat at the moment of failure is stated")
has(stated, "mounted yes", "…and being mounted, which is what triggered this swap in the first place")
has(stated, "dead no", "…and the conditions that were NOT true are stated too, not left out")
has(stated, "casting no", "…all four, so absence is never something the reader has to infer")

-- A record from a build that did not capture the state must not read as a build that captured it
-- and found nothing. That distinction is the whole of what a stale deploy costs.
local unstated = report({ when = "now", sets = {}, swaps = { {
    set = "X", ok = false, reason = "stuck on Off hand", when = "12:06:00" } } })
H.ok(not unstated:find("combat", 1, true),
    "a record with no state does not manufacture one")

-- A failure the client said nothing about must not invent a reason. That case is itself evidence:
-- it means the action was refused with no message, which is a different suspect list.
local quiet = report({ when = "now", sets = {}, swaps = { {
    set = "X", ok = false, reason = "stuck on Off hand", when = "12:06:00" } } })
has(quiet, "stuck on Off hand", "a failure the client did not explain reports what is known")

-- The empty cases, stated rather than omitted: an absent section and an empty one are different
-- answers, and only one of them is a fact about the world.
local bare = report({ when = "now", sets = {} })
has(bare, "(no forms)", "a class with no shapeshift forms says so")
has(bare, "(not read)", "…and an unread state says that, rather than looking like an empty one")

-- Robustness. A dump is asked for precisely when something is wrong, so it must survive a world
-- that is already broken — a nil plan, no sets, no bags. A debug tool that errors is worse than no
-- debug tool: it hides the bug behind its own.
H.ok(pcall(D.Report, { when = "now", state = { failed = "could not be read" } }),
    "a state that could not be read dumps rather than erroring")
H.ok(pcall(D.Report, { when = "now", sets = {} }), "a world with no sets dumps rather than erroring")
H.ok(pcall(D.Report, { when = "now", sets = { { name = "X", slots = {} } } }),
    "a set whose plan could not be built dumps rather than erroring")
H.ok(pcall(D.Report, {}), "an empty world dumps rather than erroring")

H.done()
