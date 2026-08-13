-- KitbagEvents — turn game events into a state snapshot and hand it to the rule engine.
--
-- The division of labour that ItemRack never had: this file knows about events and nothing about
-- which set should win; KitbagRules knows which set should win and nothing about events. So the
-- part that used to be untestable is now a table, and the part left here is a dozen lines of
-- wiring.

Kitbag = Kitbag or {}

local Rules = Kitbag.Rules
local Sets = Kitbag.Sets

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
local pending = nil   -- set name deferred until combat ends

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

local function apply()
    local db = Kitbag.db
    if not db.options.autoSwap then return end

    local winner = Rules.Match(db.rules, Events.State())
    if not winner then return end
    if winner.set == db.lastSet then return end   -- already there; don't churn

    if db.options.deferInCombat and InCombatLockdown() then
        pending = winner.set
        return
    end
    Sets.Equip(winner.set, true)
end

function frame:OnEvent(event)
    if event == "PLAYER_REGEN_ENABLED" and pending then
        local set = pending
        pending = nil
        Sets.Equip(set, true)
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
    return Rules.Explain(Kitbag.db.rules, Events.State())
end

Kitbag.Events = Events
return Events
