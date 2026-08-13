-- KitbagEvents — turn game events into a state snapshot and hand it to the rule engine.
--
-- The division of labour that ItemRack never had: this file knows about events and nothing about
-- which set should win; KitbagRules knows which set should win and nothing about events. So the
-- part that used to be untestable is now a table, and the part left here is a dozen lines of
-- wiring.

Kitbag = Kitbag or {}

local Rules = Kitbag.Rules
local Sets = Kitbag.Sets
local Core = Kitbag.Core
local Inventory = Kitbag.Inventory

local Events = {}

local WATCHED = {
    "PLAYER_ENTERING_WORLD",
    "UPDATE_SHAPESHIFT_FORM",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ZONE_CHANGED_NEW_AREA",
    "UPDATE_STEALTH",
    "PLAYER_UPDATE_RESTING",
    "PLAYER_MOUNT_DISPLAY_CHANGED",
}

local frame = CreateFrame("Frame")
local pending = nil   -- a Rules.Next step deferred until combat ends

-- The set the engine put on and has not undone yet. Deliberately NOT saved: after a reload the
-- engine has no idea whether the swap it remembers is still on, and re-deriving it from the first
-- event is both cheap and correct. The restore point IS saved (in Kitbag.char), because losing it
-- means the player never gets their own gear back.
local active = nil

--- A flat snapshot of everything a rule may condition on. Flat on purpose: the rule engine compares
--- state[k] to when[k] and needs no knowledge of what any key means.
function Events.State()
    return {
        form = GetShapeshiftForm() or 0,
        combat = InCombatLockdown() and true or false,
        stealth = IsStealthed() and true or false,
        mounted = IsMounted() and true or false,
        resting = IsResting() and true or false,
        zone = GetRealZoneText() or "",
    }
end

local function perform(step)
    local char = Kitbag.char

    if step.action == "equip" then
        -- Remember BEFORE swapping, obviously — but note it captures what is worn, not a named set.
        -- You were wearing whatever you were wearing, quite possibly no saved set at all, and
        -- restoring to the nearest named set would put on gear you never chose.
        if step.remember then
            char.restorePoint = Core.CaptureSet(Inventory.Equipped(), "restore")
        end
        active = step.set
        Sets.Equip(step.set, true)

    elseif step.action == "restore" then
        local point = char.restorePoint
        -- Cleared first: if the restore itself fails there is nothing useful left to retry, and a
        -- restore point that survives its own failure fires again on the next event forever.
        char.restorePoint, active = nil, nil
        if point then Sets.Apply(point, "what you were wearing", true) end
    end
end

local function apply()
    local db, char = Kitbag.db, Kitbag.char
    if not db.options.autoSwap then return end

    local winner = Rules.Match(char.rules, Events.State())
    local step = Rules.Next(active, winner, char.restorePoint ~= nil)
    if step.action == "none" then return end

    if db.options.deferInCombat and InCombatLockdown() then
        pending = step
        return
    end
    perform(step)
end

function frame:OnEvent(event)
    if event == "PLAYER_REGEN_ENABLED" and pending then
        local step = pending
        pending = nil
        perform(step)
        return
    end
    apply()
end

function Events.Enable()
    for _, e in ipairs(WATCHED) do
        -- Not every event exists on every flavour; registering an unknown one is a hard error.
        pcall(frame.RegisterEvent, frame, e)
    end
    frame:SetScript("OnEvent", frame.OnEvent)
end

--- Why is the current state producing the set it is? Backs `/kit why`.
function Events.Explain()
    return Rules.Explain(Kitbag.char.rules, Events.State())
end

Kitbag.Events = Events
return Events
