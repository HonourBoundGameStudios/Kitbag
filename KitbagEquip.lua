-- KitbagEquip — carry out a plan against the client, one action at a time.
--
-- The plan is already decided by the time it gets here (KitbagCore.Plan); this file's only job is
-- to perform it and to tell the truth about what happened. Two rules it exists to hold:
--
--   * ONE ACTION PER FRAME. The client processes an equip asynchronously, so firing a whole plan in
--     a single tick means later actions read a world that hasn't caught up. That is the mechanism
--     behind "it equipped my set in the wrong order".
--   * VERIFY, DON'T ASSUME. After each action the destination slot is re-read. If it doesn't hold
--     what was asked for, the action is retried a bounded number of times and then reported as a
--     failure — not left silently half-applied.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Compat = Kitbag.Compat
local Inventory = Kitbag.Inventory

local Equip = {}

-- An equip is a server round-trip, not a local edit: 100-300ms on a good connection and worse on a
-- bad one. SETTLE is how long an attempt is given to land before it is retried, and it is the whole
-- reason this driver works — retrying on the next frame both wastes the retry and can undo the swap
-- that was still in flight. MAX_RETRIES * SETTLE is the real budget an action gets.
local MAX_RETRIES = 3
local SETTLE = 0.4

-- How long the driver will wait for a player who cannot act before abandoning the plan. Waiting is
-- right for the state people actually hit — a cast ends by itself in a second or two — but IsBusy is
-- also true for DEAD, which does not clear until the player chooses to release, and might not clear
-- this hour. An unbounded wait is not patience, it is a wedge (BUG-11).
local BUSY_LIMIT = 10

-- How long the driver waits for a question the client has put on screen — the Bind-on-Equip
-- confirmation, and its siblings. Much longer than BUSY_LIMIT because it is denominated in HUMAN
-- time: a player reading a dialog is not a client that has failed to answer in 400ms. Bounded all
-- the same, because a dialog nobody answers must not wedge the driver (BUG-11's lesson, applied
-- rather than learned twice).
local BIND_LIMIT = 60

Equip.MAX_RETRIES = MAX_RETRIES
Equip.SETTLE = SETTLE
Equip.BUSY_LIMIT = BUSY_LIMIT
Equip.BIND_LIMIT = BIND_LIMIT

-- { actions =, index =, tries =, waited =, blockedFor =, bindWaited =, onDone =, label =,
--   lastError = }
local queue = nil
local driver = CreateFrame("Frame")

local function finish(ok, failedAction, blocked, found)
    local done, label = queue and queue.onDone, queue and queue.label
    -- Built here rather than by the caller: the client's wording and the reason the driver gave up
    -- both live in this file, and a caller reassembling them is a second copy of the rule. Reason is
    -- defined below with the other pure decisions; it is read off the table when this runs, never at
    -- load, so no forward declaration is needed.
    local reason = not ok
        and Equip.Reason(failedAction, queue and queue.lastError, blocked, found) or nil
    queue = nil
    driver:SetScript("OnUpdate", nil)
    driver:UnregisterEvent("UI_ERROR_MESSAGE")
    if done then done(ok, failedAction, label, reason) end
end

--- The message out of a UI_ERROR_MESSAGE payload, whichever way the client hands it over. PURE.
-- The modern engine fires (errorType, message); the older one fired the message alone. Getting this
-- wrong does not throw — it stores nil, which silently reverts the report to the one BUG-9 was
-- about, so it is worth pinning rather than eyeballing.
function Equip.ErrorText(a, b)
    if type(b) == "string" then return b end
    if type(a) == "string" then return a end
    return nil
end

--- How to report a plan that could not be finished. PURE.
--
-- The slot alone was the whole report until BUG-9, and it is not enough: it names WHERE the driver
-- gave up and never WHY, so "your bags cannot take the shield" and "you cannot change weapons right
-- now" arrive as the same sentence — one a Kitbag bug and one a game rule. The client's wording is
-- quoted rather than interpreted; guessing at its meaning is how a message becomes wrong after a
-- patch.
-- `found` is what the destination slot actually held at the moment the driver gave up, and it is the
-- one fact that separates the two mechanisms a silent failure leaves behind: the item never arrived,
-- or it arrived and `satisfied` refused to recognise it. Those want opposite fixes and are one
-- string apart, and the driver had that string in its hand and dropped it (BUG-9, Amoondi's "stuck
-- on Chest" with nothing blocking and no client message at all).
-- `blocked` names what the driver was waiting on when it gave up: nil, "busy" (the player could
-- never act — our own reading of our own IsBusy, the one interpretation this function is entitled to
-- make) or "bind" (the client asked a question nobody answered). An unanswered question is not a
-- failure of the addon and must not read like one — the sentence should send the player back to the
-- dialog, not to a bug report. The client's own words still win over both.
function Equip.Reason(failedAction, lastError, blocked, found)
    local slot = failedAction and Core.SlotById(failedAction.to)
    local where = "stuck on " .. (slot and slot.label or "an unknown slot")

    -- The message arrives as an event payload, so blank is a real possibility — and "the game said:"
    -- with nothing after it reads as the addon losing the answer, which is worse than not asking.
    if type(lastError) == "string" and not lastError:match("^%s*$") then
        where = where .. " — the game said: " .. lastError
    elseif blocked == "bind" then
        where = where .. " — the bind confirmation was not answered"
    elseif blocked then
        where = where .. " — you were dead or casting the whole time"
    end

    -- Kept alongside the client's message rather than instead of it: the message explains, the keys
    -- describe, and a silent refusal has only the keys. Both sides are stated even when one is empty
    -- — an unequip wanted nothing, and an untouched slot holds nothing, and printing a nil for
    -- either would read as the addon having failed to look.
    -- Only when at least one side is known. With neither, "slot holds nothing, wanted nothing" is
    -- not a finding — it is the addon reporting that it did not look, dressed up as evidence.
    local wanted = failedAction and failedAction.key
    if found or wanted then
        where = where .. string.format(" (slot holds %s, wanted %s%s)",
            found and tostring(found) or "nothing", wanted and tostring(wanted) or "nothing",
            Equip.Source(failedAction))
    end
    return where
end

--- Where the driver was reaching for the item, as a clause to hang off the failure. PURE.
--
-- A bank source is shouted rather than merely stated. The planner is supposed to refuse one while
-- the bank is shut, precisely because PickupContainerItem on a bank bag does nothing and says
-- nothing — which is indistinguishable from every other silent failure until someone names it.
function Equip.Source(action)
    local from = action and action.from
    if not from then return "" end
    if from.equipped then
        local slot = Core.SlotById(from.equipped)
        return " from " .. (slot and slot.label or ("slot " .. tostring(from.equipped)))
    end
    if from.bag == nil then return "" end
    if from.bank then
        return string.format(" from the BANK, bag %s slot %s", tostring(from.bag), tostring(from.slot))
    end
    return string.format(" from bag %s slot %s", tostring(from.bag), tostring(from.slot))
end

-- The client says why it refused exactly once, in UI_ERROR_MESSAGE, and the driver used to let it
-- scroll past. Only listened to while a plan is in flight (see Run), and cleared whenever an action
-- lands, so a message can only be attributed to the action being attempted when it arrived.
driver:SetScript("OnEvent", function(_, _, a, b)
    if queue then queue.lastError = Equip.ErrorText(a, b) or queue.lastError end
end)

-- Put whatever is on the cursor down in the first bag that will take it.
--
-- PutItemInBackpack() alone only ever tries bag 0, so a full backpack failed the unequip even with
-- three empty bags hanging off it — and the failure looked identical to genuinely having nowhere to
-- put the item. The planner refuses the plan up front when there is truly no room (CORE-5); this is
-- the other half of the same bug.
--
-- Which bags to ask is Core.StowBags, not "all of them in turn": asking a bag that cannot take the
-- item is not a free miss, it is a "That bag is full" in the chat frame. A swap that worked
-- perfectly still read as a string of errors, one per bag passed on the way to the one with room —
-- and nothing distinguished that spam from a swap that genuinely failed.
local function stow()
    for _, bag in ipairs(Core.StowBags(Inventory.Bags())) do
        -- The backpack has no inventory id to hand PutItemInBag; it has its own call.
        if bag.id == 0 then
            PutItemInBackpack()
        else
            PutItemInBag(Compat.ContainerToInventory(bag.id))
        end
        if not CursorHasItem() then return end
    end
end

local function perform(action)
    if action.kind == "unequip" then
        PickupInventoryItem(action.to)
        stow()
        ClearCursor()
    elseif action.from.equipped then
        PickupInventoryItem(action.from.equipped)
        PickupInventoryItem(action.to)
        ClearCursor()
    else
        Compat.PickupContainerItem(action.from.bag, action.from.slot)
        PickupInventoryItem(action.to)
        ClearCursor()
    end
end

local function satisfied(action)
    local worn = Core.ItemKey(GetInventoryItemLink("player", action.to))
    if action.kind == "unequip" then return worn == nil end
    return worn == action.key
end

--- What to do with this frame. PURE — no client calls, no mutation — so the whole policy is
--- testable outside the game; see Tests/equip_test.lua.
--
-- Order is the substance of it: an arrived item is accepted before anything else can veto it, being
-- unable to act is never counted as failing, and an attempt is always given its settle time — the
-- last one included, or the retry budget is really MAX_RETRIES-1 and the final swap gets reported
-- as failed while it is still in flight.
function Equip.Decide(s)
    if not s.hasAction then return "done" end
    if s.satisfied then return "advance" end
    -- Before `busy`, and before the retry budget: a question on screen is not a refusal, and every
    -- instrument the driver has reads "fine" while one is up. This is what BUG-9 turned out to be —
    -- three retries spent in 1.2 seconds against a dialog nobody had answered yet.
    if s.pendingBind then
        if (s.bindWaited or 0) >= BIND_LIMIT then return "fail" end
        return "wait"
    end
    if s.busy then
        -- Both orderings above still hold: a plan that finished is finished and an item that
        -- arrived is accepted, however long the player has been unable to act.
        if (s.blockedFor or 0) >= BUSY_LIMIT then return "fail" end
        return "wait"
    end
    if s.tries == 0 then return "perform" end          -- nothing in flight to collide with
    if s.waited < SETTLE then return "wait" end        -- give the client time to answer
    if s.tries >= MAX_RETRIES then return "fail" end
    return "perform"
end

local function step(_, elapsed)
    elapsed = elapsed or 0
    queue.waited = queue.waited + elapsed

    -- Counted only while the client is refusing to let us act, and reset the moment it stops, so a
    -- player who is dead for eight seconds and then alive does not carry those eight seconds into
    -- the next thing that blocks. It is the plan's patience, not a stopwatch on the plan.
    local busy = Compat.IsBusy()
    queue.blockedFor = busy and (queue.blockedFor + elapsed) or 0

    -- Counted separately from `blockedFor`, and reset when the dialog goes away, so answering one
    -- question does not eat the budget for the next item's.
    local pendingBind = Compat.PendingBind()
    queue.bindWaited = pendingBind and (queue.bindWaited + elapsed) or 0

    local action = queue.actions[queue.index]
    local decision = Equip.Decide({
        hasAction = action ~= nil,
        satisfied = action ~= nil and satisfied(action),
        busy = busy,
        blockedFor = queue.blockedFor,
        pendingBind = pendingBind,
        bindWaited = queue.bindWaited,
        tries = queue.tries,
        waited = queue.waited,
    })

    if decision == "done" then
        return finish(true)
    elseif decision == "advance" then
        queue.index, queue.tries, queue.waited = queue.index + 1, 0, 0
        -- An action that landed answers whatever the client complained about on the way, so the
        -- message must not follow the queue to a later slot and be reported against it.
        queue.lastError = nil
    elseif decision == "fail" then
        -- Read the slot one last time, for the report rather than for the decision. `satisfied` has
        -- already said no; what it does not say is WHAT is in there, and that is the whole difference
        -- between "the item never arrived" and "it arrived and we did not recognise it".
        return finish(false, action, pendingBind and "bind" or (busy and "busy" or nil),
            Core.ItemKey(GetInventoryItemLink("player", action.to)))
    elseif decision == "perform" then
        queue.tries, queue.waited = queue.tries + 1, 0
        perform(action)
    end
    -- "wait": the client has not caught up yet. Doing nothing is the correct action.
end

--- Run a plan. `onDone(ok, failedAction, label, reason)` fires once, whatever the outcome; `reason`
-- is the finished sentence on a failure and nil on a success.
-- Returns false if a plan is already running — a second set click must not interleave with the
-- first, which is how gear ends up in a state neither set asked for.
function Equip.Run(plan, label, onDone)
    if queue then return false end
    if plan.empty then
        if onDone then onDone(true, nil, label) end
        return true
    end

    queue = {
        actions = plan.actions, index = 1, tries = 0, waited = 0,
        blockedFor = 0, bindWaited = 0,
        onDone = onDone, label = label,
    }
    driver:SetScript("OnUpdate", step)
    -- Registered here rather than at load, and dropped again in finish: an error that arrives while
    -- no plan is in flight belongs to something else entirely and must never be quoted as ours.
    driver:RegisterEvent("UI_ERROR_MESSAGE")
    return true
end

--- Is a swap in flight? The UI greys its buttons on this.
function Equip.IsRunning()
    return queue ~= nil
end

--- Abandon the plan in flight. The gear already moved stays moved — there is no undo in the client
-- — so this reports as a failure rather than pretending nothing happened.
function Equip.Cancel()
    if queue then finish(false, queue.actions[queue.index]) end
end

Kitbag.Equip = Equip
return Equip
