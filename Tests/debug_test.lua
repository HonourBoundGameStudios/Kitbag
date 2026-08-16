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
dofile("KitbagRules.lua")
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
-- The rule engine's half of the world (EPIC-VERIFY)
-- ---------------------------------------------------------------------------
--
-- Gear, bags and plans answer "did the swap work". They say nothing about the half of the addon that
-- DECIDES to swap, which is the half that has never run in the client. A dump that cannot show the
-- forms the client reported, the state the engine snapshotted, and which rule won is a dump that
-- costs a second /reload for every rule question — and a /reload is a loading screen for a human.

local ruled = {
    when = "2026-08-14 10:00:00",
    schema = 2,
    -- Index 0 always exists and is not a form; a class with no forms has only this.
    forms = { [0] = "no form", [1] = "Bear Form", [3] = "form 3" },
    state = { form = 3, combat = true, stealth = false, zone = "Orgrimmar",
              buff = { ["Mark of the Wild"] = true, ["Thorns"] = true } },
    rules = {
        { set = "Tank", priority = 50, when = { combat = true } },
        { set = "Cat",  priority = 10, when = { form = 1 } },
        { set = "Old",  priority = 99, enabled = false, when = {} },
    },
    explain = { chosen = "Tank", considered = {
        { set = "Tank", priority = 50, matched = true },
        { set = "Cat",  priority = 10, matched = false, reason = "form" },
        { set = "Old",  priority = 99, matched = false, reason = "disabled" },
    } },
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

-- The snapshot the engine matched against. Sorted, and false is stated: "the dump did not mention
-- stealth" and "the player was not stealthed" are different facts that must not look alike.
has(rtext, "STATE", "the state snapshot the engine matched against is dumped")
has(rtext, "combat = true", "…each condition key with its value")
has(rtext, "stealth = false", "…including the false ones, stated rather than omitted")
has(rtext, "zone = Orgrimmar", "…and text conditions verbatim, since Match compares them with ==")
-- A membership condition holds a set, and pairs() order would make two identical dumps differ.
has(rtext, "buff = Mark of the Wild, Thorns", "a set-valued key lists its members, sorted")
H.ok(rtext:find("combat = true", 1, true) < rtext:find("zone = Orgrimmar", 1, true),
    "state keys are dumped in name order, so two dumps can be diffed")

-- Every rule, why it did or didn't fire, and which one won. This is `/kit why` written to disk: the
-- question a rule bug asks is never "what are my rules" but "why did THAT one win".
has(rtext, "RULES", "the rules are dumped")
has(rtext, "chosen: Tank", "…with the winner named in the heading, not left to be worked out")
has(rtext, '1. "Tank"', "…each rule numbered by its list position, which is the documented tiebreak")
has(rtext, "priority 50", "…with the priority that decided it")
has(rtext, "in combat", "…and its conditions in the same English the rule list shows")
has(rtext, "MATCHED", "a rule that fired says so")
has(rtext, "no: form", "…and one that did not names the condition that failed, as Explain reports it")
has(rtext, "no: disabled", "…with a disabled rule distinguished from one whose conditions missed")

-- A form condition reads with the client's own label, which is the second proof FormLabels worked:
-- "in form 3" in a rule the player wrote as "Cat Form" is a bug report on its own.
has(rtext, "in Bear Form", "a form condition is described with the label the client gave")

-- ---------------------------------------------------------------------------
-- The engine's own memory, and whether its events exist (BUG-9)
-- ---------------------------------------------------------------------------
--
-- "I mounted and nothing happened" is a report the dump above cannot answer. Every section of it
-- describes the world; none describes the ENGINE, and the two ways a rule silently does nothing both
-- live there:
--
--   * The engine already believes it put that set on. `active` is set before the equip is attempted
--     and is not cleared when the equip fails, so a swap that failed once looks, to Rules.Next, like
--     a swap that is still on — and the rule never fires again.
--   * The event never arrived. Events.Enable() registers inside pcall because not every flavour has
--     every event, which means a missing PLAYER_MOUNT_DISPLAY_CHANGED is indistinguishable from a
--     rule that simply did not match. Bugs.md has carried that caveat as an unknown since it was
--     written; a dump that states it turns the unknown into a line of text.

local engine = {
    when = "2026-08-16 09:00:00",
    sets = {},
    engine = {
        autoSwap = true,
        active = "FASTHOJ+TRAVEL",
        deferred = "Tanky-Heal-PVP",
        restorePoint = true,
        events = {
            { name = "PLAYER_ENTERING_WORLD", registered = true },
            { name = "PLAYER_MOUNT_DISPLAY_CHANGED", registered = false },
        },
    },
}
local etext = report(engine)

has(etext, "ENGINE", "what the rule engine remembers is a section of its own")
has(etext, "auto-swap: true", "…starting with the switch that turns every rule off at once")
has(etext, "holding: FASTHOJ+TRAVEL",
    "the set the engine believes is on is named — no rule can re-fire while it is held")
has(etext, "deferred: Tanky-Heal-PVP", "…and a step waiting for combat to end, which looks identical")
has(etext, "restore point: held", "…and whether there is gear to come back to")

has(etext, "EVENTS", "whether each watched event registered is a section of its own")
has(etext, "PLAYER_ENTERING_WORLD", "…naming every event the engine asked for")
-- On the same LINE as its event, not merely somewhere in the section: two events and two verdicts
-- in a section is not an answer to which of them is missing.
H.ok(etext:find("PLAYER_MOUNT_DISPLAY_CHANGED%s+NOT REGISTERED") ~= nil,
    "…and shouting about the one this flavour does not have, since pcall swallowed it silently")
H.ok(etext:find("PLAYER_ENTERING_WORLD%s+registered") ~= nil,
    "…while the ones that took are quietly marked, so the missing one stands out")

-- The absences again. An engine holding nothing is the normal case and must not read like an
-- unread one: "no set is held" is the fact that clears the stale-`active` suspicion outright.
local idle = report({ when = "now", sets = {}, engine = {
    autoSwap = false, active = nil, deferred = nil, restorePoint = false, events = {} } })
has(idle, "auto-swap: false", "auto-swap being off is stated — it is a whole-addon explanation")
has(idle, "holding: (nothing)", "an engine holding no set says so rather than omitting the line")
has(idle, "deferred: (nothing)", "…and so does an empty deferral")
has(idle, "restore point: (none)", "…and so does an absent restore point")
has(idle, "(no events registered)",
    "an engine that registered nothing says so — it is why every rule would be dead")

-- An engine that could not be read at all is a third state, and not the same as an idle one: the
-- first says nothing is known, the second says nothing is held.
local unread = report({ when = "now", sets = {} })
local section = unread:match("ENGINE\n(.-)\n\n") or ""
has(section, "(not read)", "an unreadable engine says so rather than reading as idle")

-- And an engine that threw while being read says THAT, rather than reporting as unread. The dump is
-- asked for when something is already wrong, so its own failure has to survive into the text.
has(report({ when = "now", sets = {}, engine = { failed = "attempt to index a nil value" } }),
    "could not be read: attempt to index a nil value",
    "an engine read that errored reports the error instead of hiding behind '(not read)'")

-- The empty cases, stated rather than omitted. "No rules" is the single most likely explanation for
-- "it never swapped", and a dump that simply has no RULES section cannot distinguish it from a dump
-- taken before rules were read.
local bare = report({ when = "now", sets = {} })
has(bare, "(no forms)", "a class with no shapeshift forms says so")
has(bare, "(no rules)", "no rules at all is stated — it is the likeliest reason nothing ever swapped")
has(bare, "(not read)", "…and an unread state says that, rather than looking like an empty one")

-- Robustness. A dump is asked for precisely when something is wrong, so it must survive a world
-- that is already broken — a nil plan, no sets, no bags. A debug tool that errors is worse than no
-- debug tool: it hides the bug behind its own.
H.ok(pcall(D.Report, { when = "now", rules = { { set = "X" } } }),
    "rules with no explain alongside them dump rather than erroring")
H.ok(pcall(D.Report, { when = "now", state = { buff = {} } }),
    "a state holding an empty set dumps rather than erroring")
H.ok(pcall(D.Report, { when = "now", sets = {} }), "a world with no sets dumps rather than erroring")
H.ok(pcall(D.Report, { when = "now", sets = { { name = "X", slots = {} } } }),
    "a set whose plan could not be built dumps rather than erroring")
H.ok(pcall(D.Report, {}), "an empty world dumps rather than erroring")

H.done()
