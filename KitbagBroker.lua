-- KitbagBroker — a LibDataBroker source, so Titan/Bazooka/Sigil can host a Kitbag launcher
-- (COMPAT-4).
--
-- Nothing is vendored. LibDataBroker is a library that a broker DISPLAY ships; if the player has
-- one, LibStub already has it registered by the time Kitbag loads, and this file hands it a data
-- object. If they have none, there is nothing to display it and this file does nothing at all.
--
-- That is the whole reason this can exist under a no-dependency policy: Kitbag never needs LDB, it
-- only cooperates with it when something else has already paid for it.
-- The minimap button (KitbagMinimap) stays hand-rolled and remains the default surface.

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets

local Broker = {}

local object = nil

local function onClick(_, button)
    if button == "RightButton" then
        Kitbag.Options.Toggle()
    else
        Kitbag.UI.Toggle()
    end
end

local function onTooltipShow(tooltip)
    if not tooltip or not tooltip.AddLine then return end
    tooltip:AddLine("Kitbag")

    local worn = Kitbag.char and Kitbag.char.lastSet
    tooltip:AddLine(worn and ("Wearing: " .. worn) or "No set applied yet", 1, 1, 1)

    -- The line that named the rule the engine would pick went with the engine (Icebox/). Nothing
    -- changes gear on its own now, so "wearing X" is the whole story this tooltip has to tell.
    tooltip:AddLine("Left-click to open, right-click for options.", 0.6, 0.6, 0.6)
end

--- Update the broker text. Called from Kitbag.Refresh, so a text display keeps up with the set list.
function Broker.Refresh()
    if not object then return end
    object.text = (Kitbag.char and Kitbag.char.lastSet) or "Kitbag"
end

--- Register with LibDataBroker if the player has a display that provides it.
function Broker.Enable()
    if object then return object end

    local libStub = _G.LibStub
    -- The `true` is "silent": LibStub raises an error for a missing library otherwise, and a player
    -- with no broker display has done nothing wrong.
    local ldb = libStub and libStub:GetLibrary("LibDataBroker-1.1", true)
    if not ldb then return nil end

    -- "data source" rather than "launcher" so displays that show text have something to show; every
    -- display that honours a launcher's OnClick honours a data source's too.
    object = ldb:NewDataObject("Kitbag", {
        type = "data source",
        text = "Kitbag",
        icon = "Interface\\Icons\\INV_Chest_Plate06",
        label = "Kitbag",
        OnClick = onClick,
        OnTooltipShow = onTooltipShow,
    })

    Broker.Refresh()
    return object
end

Kitbag.Broker = Broker
return Broker
