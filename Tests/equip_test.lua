-- KitbagEquip — the per-frame policy that drives a plan against the client.
--
-- The plan is already decided by the time the driver sees it (that is KitbagCore's job, covered in
-- core_test.lua). What is decided *here*, every frame, is: perform the action, wait for the one in
-- flight to land, move to the next, or give up. That decision is pure, so it is cornered here
-- rather than by wearing the bug.
--
-- The case that forced this file into existence: equipping a set applied ONE item and then reported
-- "could not finish — stuck on Feet". The driver retried on consecutive frames, spending all three
-- retries in ~50ms, while a real equip needs a server round-trip of 100-300ms. It declared failure
-- before the client could possibly have answered — and re-issuing a cursor swap that is still in
-- flight can undo the one that was working.
--
-- Usage: lua Tests/equip_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

-- KitbagEquip builds its OnUpdate frame at load. Stub the one client call it makes at file scope so
-- the module can be loaded outside the game; nothing else here touches the client.
_G.CreateFrame = function()
    return { SetScript = function() end }
end

dofile("KitbagCompat.lua")
dofile("KitbagCore.lua")
local E = dofile("KitbagEquip.lua")

H.start("KitbagEquip")

-- ---------------------------------------------------------------------------
-- Decide — what the driver does with this frame
-- ---------------------------------------------------------------------------
--
-- Decide(state) -> "done" | "advance" | "perform" | "wait" | "fail"
--   hasAction : is there still an action at the current index
--   satisfied : the destination slot already holds what was asked for
--   busy      : casting/dead — a swap now would be refused or would cancel the cast
--   tries     : attempts already spent on THIS action
--   waited    : seconds since the last attempt

local function decide(s) return E.Decide(s) end

H.ok(E.SETTLE and E.SETTLE > 0, "there is a settle time — the driver waits for the client to answer")
H.ok(E.MAX_RETRIES and E.MAX_RETRIES > 0, "there is a bounded retry count")

-- The plan is finished when the index runs off the end. Nothing else can report success.
H.eq(decide({ hasAction = false, tries = 0, waited = 0 }), "done",
    "no action left -> done")

-- The happy path: an untouched action is attempted at once. Waiting first would add a settle time's
-- delay to every single slot, and the first attempt has nothing in flight to collide with.
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 0, waited = 0 }), "perform",
    "a fresh action is performed immediately — no settle delay on the first attempt")

-- Verification is what makes the report trustworthy: the slot is re-read, not assumed.
H.eq(decide({ hasAction = true, satisfied = true, busy = false, tries = 1, waited = 0 }), "advance",
    "the slot now holds what was asked -> advance")
H.eq(decide({ hasAction = true, satisfied = true, busy = false, tries = 0, waited = 0 }), "advance",
    "already satisfied before any attempt (someone else moved it) -> advance, not perform")
H.eq(decide({ hasAction = true, satisfied = true, busy = true, tries = 1, waited = 0 }), "advance",
    "advancing costs nothing and is safe even while busy")

-- THE BUG. After an attempt, the client has not answered yet. Retrying on the very next frame both
-- burns a retry for nothing and can undo the swap that was already in flight.
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 1, waited = 0 }), "wait",
    "an attempt just fired and has not landed -> wait, NOT retry on the next frame")
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 1, waited = E.SETTLE / 2 }), "wait",
    "still inside the settle window -> keep waiting")
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 1, waited = E.SETTLE }), "perform",
    "the settle window elapsed with nothing equipped -> now a retry is warranted")

-- A swap mid-cast cancels the cast, so being busy defers the work rather than spending a retry.
H.eq(decide({ hasAction = true, satisfied = false, busy = true, tries = 0, waited = 0 }), "wait",
    "busy (casting or dead) -> wait rather than spend an attempt")
H.eq(decide({ hasAction = true, satisfied = false, busy = true, tries = 9, waited = 99 }), "wait",
    "busy outranks the retry limit — being unable to act is not the same as failing")

-- Giving up is bounded, and honest: the caller names the slot it stuck on.
H.eq(decide({ hasAction = true, satisfied = false, busy = false,
              tries = E.MAX_RETRIES, waited = E.SETTLE }), "fail",
    "retries exhausted and the last one had its full settle -> fail")

-- The subtle one. The final attempt must be given the same chance to land as every attempt before
-- it, or the retry budget is really MAX_RETRIES-1 and the last swap is reported failed while it is
-- still in flight — which is precisely the bug in miniature.
H.eq(decide({ hasAction = true, satisfied = false, busy = false,
              tries = E.MAX_RETRIES, waited = 0 }), "wait",
    "retries exhausted but the last attempt has not settled -> wait before declaring failure")

-- Total budget: with the settle honoured, an action gets MAX_RETRIES attempts spread over at least
-- MAX_RETRIES * SETTLE seconds. That is the number that has to exceed a bad connection's latency.
H.ok(E.MAX_RETRIES * E.SETTLE >= 1.0,
    "the retry budget spans at least a second of real latency, not three frames")

-- ---------------------------------------------------------------------------
-- Reason — WHY the driver gave up (BUG-9)
-- ---------------------------------------------------------------------------
--
-- Reason(failedAction, lastError) -> the tail of "could not finish <set> — <reason>."
--
-- "stuck on Off hand" is what the addon has always said, and it is the same sentence whether the
-- bags had nowhere to put the shield or the client refused the unequip outright because the player
-- was mounted. Those are a Kitbag bug and a game rule respectively, and telling them apart was
-- costing a client session each time. The client says which — in UI_ERROR_MESSAGE — and the driver
-- was throwing it away.

H.eq(E.Reason({ to = 17 }, nil), "stuck on Off hand",
    "with nothing from the client, the report is what it always was — the slot it stuck on")
H.eq(E.Reason(nil, nil), "stuck on an unknown slot",
    "no action to name (a cancel before the first one) still reports honestly")

H.eq(E.Reason({ to = 17 }, "You are mounted."),
    "stuck on Off hand — the game said: You are mounted.",
    "the client's own refusal is quoted, so a game rule no longer reads as a Kitbag bug")
H.eq(E.Reason(nil, "Your bags are full."),
    "stuck on an unknown slot — the game said: Your bags are full.",
    "the client's reason survives even when the slot cannot be named")

-- An error is only worth reporting if it says something. The client's message arrives as an event
-- payload, so an empty or blank string is a real possibility and must not produce "the game said: ".
H.eq(E.Reason({ to = 8 }, ""), "stuck on Feet",
    "an empty message is no message")
H.eq(E.Reason({ to = 8 }, "   "), "stuck on Feet",
    "a blank message is no message either")

-- The slot id comes off the plan and the plan comes off saved data, so an id that is not an
-- equippable slot must be survivable rather than fatal — Core.SlotById returns nil for it.
H.eq(E.Reason({ to = 99 }, nil), "stuck on an unknown slot",
    "an unrecognised slot id degrades to the honest phrase rather than erroring")

-- Reading the event payload. The modern engine fires (errorType, message); the older one fired the
-- message alone. Reading it wrong stores nil and silently puts the report back to what BUG-9 was
-- about, so both shapes are pinned here rather than trusted.
H.eq(E.ErrorText(50, "You are mounted."), "You are mounted.",
    "(errorType, message) -> the message, not the number")
H.eq(E.ErrorText("You are mounted."), "You are mounted.",
    "the message alone -> the message")
H.eq(E.ErrorText(nil, nil), nil,
    "no message in the payload is nil, not an empty report")

H.done()
