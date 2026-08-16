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

-- ...but only for as long as the state can plausibly clear. Casting ends by itself in seconds;
-- being DEAD does not, and `UnitIsDeadOrGhost` is one of the two things IsBusy answers true to. A
-- wait with no bound is not a wait, it is a wedge: OnUpdate spins for ever, onDone never fires, so
-- IsRunning() stays true and every later swap is refused with "a swap is already in progress", and
-- the rule engine's claim on the set is never settled (BUG-10) so no rule fires again until a
-- /reload. Dying mid-swap must end the swap, not the session. (BUG-11)
H.ok(E.BUSY_LIMIT and E.BUSY_LIMIT > E.SETTLE,
    "there is a bound on being blocked, and it is longer than a single settle")
H.eq(decide({ hasAction = true, satisfied = false, busy = true, tries = 1, waited = 0,
              blockedFor = E.BUSY_LIMIT }), "fail",
    "blocked for the whole budget -> fail, rather than waiting for a state that never clears")
H.eq(decide({ hasAction = true, satisfied = false, busy = true, tries = 1, waited = 0,
              blockedFor = E.BUSY_LIMIT - 0.1 }), "wait",
    "inside the budget it still waits — a cast really does end by itself")
H.eq(decide({ hasAction = true, satisfied = true, busy = true, tries = 1, waited = 0,
              blockedFor = E.BUSY_LIMIT * 2 }), "advance",
    "an action that landed is accepted even after the block budget is spent — arrival beats the clock")
H.eq(decide({ hasAction = false, busy = true, tries = 0, waited = 0,
              blockedFor = E.BUSY_LIMIT * 2 }), "done",
    "a finished plan finishes, however long the player has been dead")
H.eq(decide({ hasAction = true, satisfied = false, busy = true, tries = 0, waited = 0 }), "wait",
    "a caller that says nothing about being blocked is treated as not yet blocked, not as an error")

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

-- What the slot actually held when the driver gave up. Amoondi's "stuck on Chest" arrived with no
-- client message and nothing blocking — combat, mounted, dead and casting all false — which rules
-- out both of BUG-9's candidates and leaves two mechanisms that need opposite fixes: the item never
-- arrived, or it arrived and `satisfied` refused to recognise it. Those are one string apart and the
-- driver was throwing that string away, so the question cost a dump every time it was asked.
H.eq(E.Reason({ to = 5, key = "14175:0:0:0:0:0:174" }, nil, false, "6569:0:0:0:0:0:1808"),
    "stuck on Chest (slot holds 6569:0:0:0:0:0:1808, wanted 14175:0:0:0:0:0:174)",
    "the failure names what the slot holds against what was asked — the two mechanisms differ here")
H.eq(E.Reason({ to = 5, key = "14175:0:0:0:0:0:174" }, nil, false, "14175:0:0:0:0:0:174"),
    "stuck on Chest (slot holds 14175:0:0:0:0:0:174, wanted 14175:0:0:0:0:0:174)",
    "…and an equal pair is the LOUD case: the item is on and the check refused to see it")
H.eq(E.Reason({ to = 5, key = "14175:0:0:0:0:0:174" }, nil, false, nil),
    "stuck on Chest (slot holds nothing, wanted 14175:0:0:0:0:0:174)",
    "an empty slot is stated as nothing rather than omitted — it means the pickup never landed")
H.eq(E.Reason({ kind = "unequip", to = 17 }, nil, false, "21610:0:0:0:0:0:0"),
    "stuck on Off hand (slot holds 21610:0:0:0:0:0:0, wanted nothing)",
    "an unequip wanted nothing, and says so rather than printing a nil")

-- WHERE the driver was reaching for it. Amoondi's second failure named two different item ids, so
-- `satisfied` is exonerated — item 6584 simply never arrived, silently, three times. What separates
-- the surviving explanations is the source: a carried bag that has moved under the plan, or a BANK
-- location the plan should never have accepted, which KitbagCore.lua's own comment predicts fails in
-- exactly this way ("PickupContainerItem on a bank bag simply does nothing then").
H.eq(E.Reason({ to = 5, key = "6584:0:0:0:0:0:1997", from = { bag = 3, slot = 7 } },
        nil, false, "14175:0:0:0:0:0:174"),
    "stuck on Chest (slot holds 14175:0:0:0:0:0:174, wanted 6584:0:0:0:0:0:1997 from bag 3 slot 7)",
    "an equip from a bag names the bag and slot it was reaching into")
H.eq(E.Reason({ to = 5, key = "6584:0:0:0:0:0:1997", from = { bag = 6, slot = 2, bank = true } },
        nil, false, nil),
    "stuck on Chest (slot holds nothing, wanted 6584:0:0:0:0:0:1997 from the BANK, bag 6 slot 2)",
    "a bank source is shouted, because a plan should never have accepted one with the bank shut")
H.eq(E.Reason({ to = 11, key = "1076:0:0:0:0:0:0", from = { equipped = 12 } },
        nil, false, "1319:0:0:0:0:0:0"),
    "stuck on Ring 1 (slot holds 1319:0:0:0:0:0:0, wanted 1076:0:0:0:0:0:0 from Ring 2)",
    "a slot-to-slot move names the slot it was moving from, by label rather than by number")

-- The client's words still come first when there are any: they explain, where the keys only describe.
H.eq(E.Reason({ to = 5, key = "14175:0:0:0:0:0:174" }, "You are mounted.", false, "6569:0:0:0:0:0:1808"),
    "stuck on Chest — the game said: You are mounted. (slot holds 6569:0:0:0:0:0:1808, wanted 14175:0:0:0:0:0:174)",
    "the client's message and the slot evidence are both kept — they answer different questions")

-- ---------------------------------------------------------------------------
-- A question on screen is not a failure (BUG-9, the actual cause)
-- ---------------------------------------------------------------------------
--
-- The whole hunt ended here: item 6584 was Bind-on-Equip, so the client put up its EQUIP_BIND
-- confirmation and waited for a human. That is not an error — no UI_ERROR_MESSAGE fires, nothing is
-- blocking, the item is present, reachable and wearable — so every instrument the driver had said
-- "fine" while it burned three retries in 1.2 seconds against a dialog nobody had answered yet, and
-- then reported "stuck on Chest".
--
-- A pending question must therefore suspend the driver rather than spend it. The budget is its own
-- and it is long, because it is denominated in HUMAN time: a player reading a dialog is not a client
-- that has failed to answer in 400ms.

H.ok(E.BIND_LIMIT and E.BIND_LIMIT > E.BUSY_LIMIT,
    "waiting on a person gets a longer budget than waiting on the client")

H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 1, waited = 99,
              pendingBind = true, bindWaited = 0 }), "wait",
    "a bind confirmation on screen suspends the driver — the retry budget must not run against it")
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = E.MAX_RETRIES,
              waited = E.SETTLE, pendingBind = true, bindWaited = 5 }), "wait",
    "…even with the retries already spent, because they were spent on a question, not a refusal")
H.eq(decide({ hasAction = true, satisfied = true, busy = false, tries = 1, waited = 0,
              pendingBind = true, bindWaited = 5 }), "advance",
    "an item that arrived is accepted even with a dialog still up — arrival beats the question")

-- Bounded, like every other wait here. A dialog nobody answers must not wedge the driver for ever,
-- which is BUG-11's lesson applied before it can be learned twice.
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 1, waited = 0,
              pendingBind = true, bindWaited = E.BIND_LIMIT }), "fail",
    "an unanswered dialog eventually gives up rather than waiting for ever")
H.eq(decide({ hasAction = true, satisfied = false, busy = false, tries = 0, waited = 0 }), "perform",
    "no dialog and no block is the ordinary path, unchanged")

-- Giving up because the client never let the driver act at all is a different report from giving up
-- after three refused attempts, and it has a different fix. Saying so is our own reading of our own
-- IsBusy, not a guess at what the client meant — the one thing this seam refuses to invent (BUG-11).
H.eq(E.Reason({ to = 17 }, nil, "busy"),
    "stuck on Off hand — you were dead or casting the whole time",
    "a swap abandoned because the player never became able to act says that, not 'stuck'")
H.eq(E.Reason({ to = 17 }, "You are dead.", "busy"),
    "stuck on Off hand — the game said: You are dead.",
    "…but the client's own words still win when there are any, since they are the better answer")

-- An unanswered question is not a failure of the addon and must not read like one. The player is the
-- one who did not act, the dialog told them so, and the sentence should send them back to it rather
-- than to a bug report.
H.eq(E.Reason({ to = 5, key = "6584:0:0:0:0:0:1997" }, nil, "bind", nil),
    "stuck on Chest — the bind confirmation was not answered " ..
    "(slot holds nothing, wanted 6584:0:0:0:0:0:1997)",
    "an unanswered bind dialog says so — it is the player's move, not the addon's fault")

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
