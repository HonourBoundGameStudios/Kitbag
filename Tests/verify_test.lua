-- KitbagVerify — the in-client self-check, and the report it writes out.
--
-- EPIC-VERIFY is a long list of "has this frame ever actually been drawn", and answering it by hand
-- costs a person twenty minutes of careful clicking per pass. Most of it does not need a person: a
-- frame either shows or it does not, a dropdown either opens or it does not, and the addon can ask
-- itself. What it CANNOT ask itself is whether the result looks right — so the report has to keep
-- "I checked and it passed" and "I could not check" firmly apart.
--
-- That separation is the whole reason this file exists. A self-check that quietly counts what it
-- skipped as what it passed is worse than no self-check: it manufactures confidence, which is the
-- one thing a verification pass must never do.
--
-- Usage: lua Tests/verify_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

dofile("KitbagCompat.lua")
dofile("KitbagCore.lua")
local V = dofile("KitbagVerify.lua")

H.start("KitbagVerify")

local function report(results, world)
    return table.concat(V.Report(results, world), "\n")
end

local function has(text, want, msg)
    H.ok(text:find(want, 1, true) ~= nil, msg)
end

-- ---------------------------------------------------------------------------
-- The three outcomes
-- ---------------------------------------------------------------------------

local results = {
    { id = "forms",   label = "Shapeshift form labels", ok = true,
      detail = "0 no form, 1 Bear Form" },
    { id = "menu",    label = "Inherit menu opens",     ok = false,
      detail = "DropDownList1 did not show" },
    { id = "bank",    label = "Bank contents readable", ok = nil,
      detail = "the bank is not open" },
}

local text = report(results, { when = "2026-08-14 12:00:00", version = "0.1.0",
    flavour = "Classic", interface = 11509 })

has(text, "2026-08-14 12:00:00", "the run is stamped, so a stale report is obvious")
has(text, "0.1.0", "…and names the build, since a stale deploy explains most surprises")
has(text, "11509", "…and the interface the client actually loaded")

has(text, "PASS", "a check that ran and succeeded says PASS")
has(text, "FAIL", "…one that ran and failed says FAIL")
-- The load-bearing word. Not "pass", not "fail", and never silently absent.
has(text, "SKIP", "…and one that could not run says SKIP, which is neither of the other two")

has(text, "Shapeshift form labels", "each check is named in words, not by id alone")
has(text, "0 no form, 1 Bear Form", "…and a passing check still reports WHAT it saw")
has(text, "DropDownList1 did not show", "…a failing one reports what went wrong")
has(text, "the bank is not open", "…and a skipped one says why it could not be checked")

-- ---------------------------------------------------------------------------
-- The summary
-- ---------------------------------------------------------------------------
--
-- The number a reader takes away. Skipped checks are counted SEPARATELY and never folded into the
-- passes — "9 of 12 passed" over a run that skipped two is a lie that reads as a success.

has(text, "1 passed", "the summary counts what actually passed")
has(text, "1 failed", "…what failed")
has(text, "1 skipped", "…and what was skipped, as its own number")

local allGood = report({ { id = "a", label = "A", ok = true } }, {})
has(allGood, "1 passed", "a clean run counts its passes")
H.ok(not allGood:find("FAIL", 1, true), "…and does not mention failure when there was none")

-- A run where everything was skipped must NOT read as a success. This is the specific failure this
-- report is shaped to prevent: a harness run before the player logged in, reporting all green.
local skipped = report({ { id = "a", label = "A", ok = nil, detail = "not logged in" } }, {})
has(skipped, "0 passed", "a run that checked nothing passed nothing")
has(skipped, "1 skipped", "…and says so")
has(skipped, "NOTHING WAS VERIFIED", "…and shouts, because all-skipped looks like all-green")

-- ---------------------------------------------------------------------------
-- Order and robustness
-- ---------------------------------------------------------------------------

H.ok(text:find("Shapeshift", 1, true) < text:find("Inherit", 1, true),
    "checks report in the order they were declared, so two runs can be diffed")

local nodetail = report({ { id = "x", label = "X", ok = true } }, {})
has(nodetail, "X", "a check with no detail still reports its name and outcome")

H.ok(pcall(V.Report, {}, {}), "an empty run reports rather than erroring")
H.ok(pcall(V.Report, nil, nil), "no results at all reports rather than erroring")
has(report({}, {}), "no checks", "…and an empty run says there was nothing to do")

-- ---------------------------------------------------------------------------
-- The check registry
-- ---------------------------------------------------------------------------
--
-- The checks themselves touch the client, so they cannot run here — but their SHAPE can be pinned.
-- A check with no id cannot be diffed between runs and one with no label cannot be read.

H.ok(type(V.CHECKS) == "table" and #V.CHECKS > 0, "there is a registry of checks")

local seen = {}
for i, check in ipairs(V.CHECKS) do
    H.ok(type(check.id) == "string" and check.id ~= "", "check " .. i .. " has an id")
    H.ok(not seen[check.id], "check " .. i .. " (" .. tostring(check.id) .. ") has a UNIQUE id")
    seen[check.id] = true
    H.ok(type(check.label) == "string" and check.label ~= "",
        "check " .. tostring(check.id) .. " has a human-readable label")
    H.ok(type(check.run) == "function", "check " .. tostring(check.id) .. " has something to run")
end

-- Every check names the backlog item it answers, so a green run can be turned back into ticks
-- without anyone re-deriving which check was standing in for which item. A BUG id counts: a check
-- can stand in for "the client is running a build that contains the fix", which is the question a
-- bug fixed outside the game leaves behind, and there is no VERIFY item to hang that on.
for _, check in ipairs(V.CHECKS) do
    H.ok(type(check.item) == "string"
        and (check.item:match("^VERIFY%-%d+$") or check.item:match("^BUG%-%d+$")),
        "check " .. tostring(check.id) .. " names the item it answers")
end

-- The instrumentation BUG-9 is waiting on. It is diagnostic rather than cosmetic, so the failure
-- mode it guards against is the worst kind: a client session spent reproducing a fault against a
-- build that cannot record the answer, which reads exactly like the fault not being reproducible.
-- UI-15's blank panel was the previous build still deployed; this is the same lesson, pre-empted.
local byId = {}
for _, check in ipairs(V.CHECKS) do byId[check.id] = check end
H.ok(byId["swap-record"] ~= nil,
    "a check proves the running build can record WHY a swap failed, not just that one did")
H.eq(byId["swap-record"] and byId["swap-record"].item, "BUG-9",
    "…and it names the bug it is standing in for")

-- VERIFY-8's remaining half. The window's Equip and Delete buttons moved out of the rows and now act
-- on "the selected set", which is a file-local in KitbagUI — so from outside the addon there is no
-- way to tell whether the selection the buttons read is the row the player actually clicked. That is
-- the failure this check exists for, and it is a nasty one: acting on the wrong selection destroys
-- the wrong set, silently, and looks exactly like the right thing until you look at what is left.
H.ok(byId["selection"] ~= nil,
    "a check proves the window's selection follows the row, so Equip/Delete act on what is shown")
H.eq(byId["selection"] and byId["selection"].item, "VERIFY-8",
    "…and it names the item it answers")

-- VERIFY-10's picker questions are geometry, and geometry is the one thing on that list a person is
-- WORST at: "does the scroll bar clear the last column" is a three-pixel question answered by eye
-- with "looks fine". Worse, BAR_STRIP is our guess at how far outside its scroll frame Blizzard
-- hangs a FauxScrollFrame bar — their number, not ours, so it cannot be reasoned from this side and
-- has to be measured against a real one.
H.ok(byId["picker-layout"] ~= nil,
    "a check measures the picker's layout, rather than asking someone to eyeball three pixels")
H.eq(byId["picker-layout"] and byId["picker-layout"].item, "VERIFY-10",
    "…and it names the item it answers")

-- VERIFY-10's other half (UI-16). "Does the bottom row still fit at 660 wide?" is arithmetic a
-- person cannot do by eye, because the failure is not a gap that looks tight — UIPanelButtonTemplate
-- does not shrink its text, it lets the label run out under the button's own edge. So a row that has
-- overflowed reads as a button with a slightly odd label rather than as a layout fault, and the
-- second button UI-16 added is what spent the row's remaining room.
H.ok(byId["bottom-row"] ~= nil,
    "a check measures whether the window's bottom row still fits the second button UI-16 added")
H.eq(byId["bottom-row"] and byId["bottom-row"].item, "VERIFY-10",
    "…and it names the item it answers")

-- VERIFY-10's last question: is a new set selected the MOMENT it is made, or only at the next
-- unrelated refresh? Correct by construction — UI.Select is the one path anything chooses a set by
-- (VERIFY-8) and `created` goes through it — but "by construction" is what the previous version of
-- this said before the window's own refresh turned out to return early while hidden. The only proof
-- is pressing the button the player presses, so the check must drive KitbagNewSetButton and NOT call
-- Sets.New itself: a check that takes the shortcut proves the store works and says nothing about the
-- wiring between the button and the selection, which is the entire question.
H.ok(byId["new-set-selected"] ~= nil,
    "a check proves a freshly made set is selected at once, not at the next unrelated refresh")
H.eq(byId["new-set-selected"] and byId["new-set-selected"].item, "VERIFY-10",
    "…and it names the item it answers")

-- VERIFY-3's last half needs a set that is ACTUALLY part-banked, and finding one is a reading rather
-- than a judgement — so the addon should do it instead of asking someone to open the bank and squint
-- at set rows. Two things fall out of one check: whether a real bank, with real gear in it, makes a
-- real set report `atBank` at all (the pure branches are covered, the join never has been), and the
-- NAME of the set to use for the half that genuinely needs a person to press Equip twice.
H.ok(byId["part-banked"] ~= nil,
    "a check names which saved sets have gear sitting in the bank, and how much")
H.eq(byId["part-banked"] and byId["part-banked"].item, "VERIFY-3",
    "…and it names the item it answers")

-- VERIFY-13's two remaining LIVE questions, both about a frame this addon does not own. The tick
-- and the teardown are correct by construction in our code — but DropDownList1 is Blizzard's, so
-- "we call CloseDropDownMenus in OnHide" is a statement about our intent and not about what is left
-- on screen. The failure it guards is loud and orphaned: a menu floating over the game with the
-- window it belonged to already gone.
H.ok(byId["inherit-menu-state"] ~= nil,
    "a check proves the inherit menu ticks the real parent and does not outlive the window")
H.eq(byId["inherit-menu-state"] and byId["inherit-menu-state"].item, "VERIFY-13",
    "…and it names the item it answers")

-- VERIFY-14. The count is already pinned against Pobble's real ItemRack file by import_test, so the
-- interesting failure is the button showing a DIFFERENT number — that would mean the window is
-- reading a different world than the tests are. The rest is clipping and clearance, which are
-- measurements rather than opinions.
H.ok(byId["import-button"] ~= nil,
    "a check reads the import button's own label and measures whether it fits")
H.eq(byId["import-button"] and byId["import-button"].item, "VERIFY-14",
    "…and it names the item it answers")

-- VERIFY-16. The keybinding button (UI-12) took the right end of the inherit button's row rather
-- than growing the panel a row of its own, so "do these two overlap" is a real question with a
-- measurable answer — and it is asked on a row whose left half CHANGES WIDTH with the set name.
-- The label half matters as much: a button showing a key the set does not hold is the exact
-- symptom of a binding that lost an arbitration silently, which is what Bindings.Set was changed
-- to prevent.
H.ok(byId["key-button"] ~= nil,
    "a check measures the keybinding button against the inherit button it shares a row with")
H.eq(byId["key-button"] and byId["key-button"].item, "VERIFY-16",
    "…and it names the item it answers")

-- VERIFY-11's geometry half. "The bar clears the X on every row" has a specific failure the item
-- names: the bar landing on top of every row's X reads as a DEAD BUTTON, not as a layout bug, so it
-- gets reported as "delete doesn't work" and sends the next session into the wrong file entirely.
H.ok(byId["rule-list-layout"] ~= nil,
    "a check measures whether the rule list's scroll bar lands on the X it would disable")
H.eq(byId["rule-list-layout"] and byId["rule-list-layout"].item, "VERIFY-11",
    "…and it names the item it answers")

-- SHIP-6's lesson applied to a check rather than to a whitelist: an instrument must DERIVE what it
-- shows, not restate it. The overwrite check used to hand StaticPopup a sentence written by hand,
-- which proves the popup draws and says nothing whatever about VERIFY-12's actual question — whether
-- the text names the RIGHT SLOTS. A check that feeds its subject a fabricated answer can only ever
-- confirm that the subject can echo.
local source = assert(io.open("KitbagVerify.lua")):read("*a")
H.ok(not source:find("this is a verification run", 1, true),
    "the overwrite check does not fabricate the text it is supposed to be verifying")
H.ok(source:find("LossText", 1, true) ~= nil,
    "…it goes through Sets.LossText, the same pure function the window uses")

-- A SKIP has to say which situation it is in, because the reader's next action differs completely.
-- VERIFY-4 skipped three runs saying "trigger a `restore` rule first" — and the account holds no
-- restore rule at all, so it was asking for something that could not happen. "Go and do it" and
-- "there is nothing to do it with" are opposite instructions, and a skip that gives the first when
-- the second is true sends someone off to reproduce a thing that does not exist.
-- The same lesson one step further along. `KitbagNewSetButton` appearing in the file proves nothing —
-- the bottom-row check names it too, just to measure it. What has to be true is that something is
-- CLICKED: calling Sets.New directly would exercise the store and skip the wiring between the button
-- and the selection, which is the whole of what VERIFY-10 has left to ask.
H.ok(source:find(":Click()", 1, true) ~= nil,
    "the new-set check clicks a button, rather than calling the store the button would have called")

-- And it must clean up what APPEARED, not what it hoped would appear. The check types a name into a
-- real edit box and presses a real button, so the set it creates is named by the client and not by
-- the check — an edit box with a letter limit, or any future tidying of the typed name, would make a
-- set under a name the check is not holding. Deleting "the name I asked for" then removes nothing
-- and leaves a scratch set in someone's SavedVariables for good, which is the one outcome a
-- verification run must never produce: a check whose failure mode is permanent litter.
H.ok(source:find("added", 1, true) ~= nil,
    "the new-set check deletes whatever set actually appeared, not the name it hoped for")

-- BUG-13's discriminator, guarded the way BUG-9's and BUG-11's are: the check proves the RUNNING
-- build can record bag room, not merely that this repo can. The failure it prevents is one this ship
-- has already paid for once (UI-15's blank panel was the previous build still on disk) — a session
-- spent reproducing BUG-13 against a build that cannot answer the one question it is being
-- reproduced for reads exactly like the fault refusing to appear.
H.ok(source:find("bag room", 1, true) ~= nil,
    "a check proves the running build records bag room, so a BUG-13 repro cannot be wasted on a stale deploy")

H.ok(source:find("no `restore` rule", 1, true) ~= nil,
    "the restore-point skip distinguishes 'no rule exists' from 'a rule has not fired yet'")

-- VERIFY-17. The item says the likeliest failure is the ROW, not the menu: UI-20 put a third button
-- where the panel was built for two, and `UIPanelButtonTemplate` answers a label that no longer fits
-- by letting it run out under its own edge rather than by shrinking it — so an overflowed row reads
-- as a button with a slightly odd label rather than as a layout fault. That is arithmetic across
-- three widths and a panel edge: the class of question a person is worst at and the addon is best
-- at. Presence and absence both count, for VERIFY-14's reason — this button is hidden on a
-- single-character account, so on such an account nobody ever looks at this end of the row at all.
H.ok(byId["copy-button"] ~= nil,
    "a check measures the three-button action row UI-20 crowded, and whether Copy belongs on it")
H.eq(byId["copy-button"] and byId["copy-button"].item, "VERIFY-17",
    "…and it names the item it answers")

-- VERIFY-18's wake-up half, which the item itself says is the likelier failure. Holding a swap while
-- the player is dead is a `return` and is covered pure; waking depends on PLAYER_ALIVE/PLAYER_UNGHOST
-- ARRIVING, and Events.Enable registers inside pcall precisely because an event a flavour does not
-- have is a hard error — so an absent one is silent, and silence is indistinguishable from a rule
-- that never matched. The addon already records which events the client accepted; comparing that
-- against what it asked for is two readings agreeing, not a judgement, so nobody should be reading
-- fifteen lines of a dump by eye to do it.
H.ok(byId["watched-events"] ~= nil,
    "a check proves the client accepted every event the engine watches, not merely that it asked")
H.eq(byId["watched-events"] and byId["watched-events"].item, "VERIFY-18",
    "…and it names the item it answers")
-- VERIFY-15, whose own note says the likely failure is the REDRAW rather than the decision: the
-- greying is Core.CanSwap and covered, so a control that stays live while the player is dead is
-- most likely a window nobody told about the death. The telling is three events on a watcher of the
-- window's own, registered inside a pcall — so the two halves fail in opposite and equally quiet
-- ways. Without PLAYER_DEAD the controls stay live and offer a swap that cannot happen; without
-- PLAYER_ALIVE/PLAYER_UNGHOST they stay greyed after a release, with nothing on screen to press and
-- no error anywhere. Neither is visible from inside the addon's own code, and both are one question
-- asked of the client.
H.ok(byId["death-watch"] ~= nil,
    "a check proves the window is actually told about dying and coming back")
H.eq(byId["death-watch"] and byId["death-watch"].item, "VERIFY-15",
    "…and it names the item it answers")
-- VERIFY-17's other half. The mock proves the copy menu's initialiser runs and what it builds; what
-- it cannot prove is that Blizzard's list frame actually APPEARS when this button is clicked, or that
-- it appears in front. The inherit menu's check answers the strata question for `DropDownList1` — it
-- is the same frame — but "the same frame is used" is an assumption about our own code, and the
-- cheaper reading is to open this menu and look. The failure it catches is the one that makes a
-- feature look absent: a button that responds to a click by doing nothing visible at all.
H.ok(byId["copy-menu"] ~= nil,
    "a check opens the copy menu itself, rather than inferring it from the inherit menu's")
H.eq(byId["copy-menu"] and byId["copy-menu"].item, "VERIFY-17",
    "…and it names the item it answers")

-- No source-scan guard on "it measures the neighbours too", though the first draft had one. The file
-- already contains the word "Delete" for the delete-popup check, so a scan for it passes whatever
-- this check does — and a guard that cannot fail is the fabricated-sentence mistake above wearing
-- different clothes. What the check must cover is stated in KitbagVerify.lua where it can be read
-- beside the code it constrains.

H.done()
