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
-- without anyone re-deriving which check was standing in for which item.
for _, check in ipairs(V.CHECKS) do
    H.ok(type(check.item) == "string" and check.item:match("^VERIFY%-%d+$"),
        "check " .. tostring(check.id) .. " names the VERIFY item it answers")
end

H.done()
