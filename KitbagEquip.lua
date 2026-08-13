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

local Equip = {}

-- An equip is a server round-trip, not a local edit: 100-300ms on a good connection and worse on a
-- bad one. SETTLE is how long an attempt is given to land before it is retried, and it is the whole
-- reason this driver works — retrying on the next frame both wastes the retry and can undo the swap
-- that was still in flight. MAX_RETRIES * SETTLE is the real budget an action gets.
local MAX_RETRIES = 3
local SETTLE = 0.4

Equip.MAX_RETRIES = MAX_RETRIES
Equip.SETTLE = SETTLE

local queue = nil      -- { actions =, index =, tries =, waited =, onDone =, label = }
local driver = CreateFrame("Frame")

local function finish(ok, failedAction)
    local done, label = queue and queue.onDone, queue and queue.label
    queue = nil
    driver:SetScript("OnUpdate", nil)
    if done then done(ok, failedAction, label) end
end

local function perform(action)
    if action.kind == "unequip" then
        PickupInventoryItem(action.to)
        PutItemInBackpack()
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
    if s.busy then return "wait" end
    if s.tries == 0 then return "perform" end          -- nothing in flight to collide with
    if s.waited < SETTLE then return "wait" end        -- give the client time to answer
    if s.tries >= MAX_RETRIES then return "fail" end
    return "perform"
end

local function step(_, elapsed)
    queue.waited = queue.waited + (elapsed or 0)

    local action = queue.actions[queue.index]
    local decision = Equip.Decide({
        hasAction = action ~= nil,
        satisfied = action ~= nil and satisfied(action),
        busy = Compat.IsBusy(),
        tries = queue.tries,
        waited = queue.waited,
    })

    if decision == "done" then
        return finish(true)
    elseif decision == "advance" then
        queue.index, queue.tries, queue.waited = queue.index + 1, 0, 0
    elseif decision == "fail" then
        return finish(false, action)
    elseif decision == "perform" then
        queue.tries, queue.waited = queue.tries + 1, 0
        perform(action)
    end
    -- "wait": the client has not caught up yet. Doing nothing is the correct action.
end

--- Run a plan. `onDone(ok, failedAction, label)` fires once, whatever the outcome.
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
        onDone = onDone, label = label,
    }
    driver:SetScript("OnUpdate", step)
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
