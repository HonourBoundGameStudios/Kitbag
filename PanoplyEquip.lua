-- PanoplyEquip — carry out a plan against the client, one action at a time.
--
-- The plan is already decided by the time it gets here (PanoplyCore.Plan); this file's only job is
-- to perform it and to tell the truth about what happened. Two rules it exists to hold:
--
--   * ONE ACTION PER FRAME. The client processes an equip asynchronously, so firing a whole plan in
--     a single tick means later actions read a world that hasn't caught up. That is the mechanism
--     behind "it equipped my set in the wrong order".
--   * VERIFY, DON'T ASSUME. After each action the destination slot is re-read. If it doesn't hold
--     what was asked for, the action is retried a bounded number of times and then reported as a
--     failure — not left silently half-applied.

Panoply = Panoply or {}

local Core = Panoply.Core
local Compat = Panoply.Compat

local Equip = {}

local MAX_RETRIES = 3

local queue = nil      -- { actions =, index =, tries =, onDone =, label = }
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

local function step()
    if Compat.IsBusy() then return end   -- wait; a swap mid-cast cancels the cast

    local action = queue.actions[queue.index]
    if not action then return finish(true) end

    if satisfied(action) then
        queue.index, queue.tries = queue.index + 1, 0
        return
    end

    if queue.tries >= MAX_RETRIES then
        return finish(false, action)
    end

    queue.tries = queue.tries + 1
    perform(action)
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

    queue = { actions = plan.actions, index = 1, tries = 0, onDone = onDone, label = label }
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

Panoply.Equip = Equip
return Equip
