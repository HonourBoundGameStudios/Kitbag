-- LoadoutMinimap — the minimap button.
--
-- Hand-rolled rather than pulled from LibDBIcon, deliberately: the fleet's dependency policy is
-- offline-first and zero-cost, and a 60-line button is cheaper to own than a vendored library.
-- If Loadout later wants a full LibDataBroker surface (so Titan/Bazooka/Sigil can host it), that is
-- a backlog item, not a reason to take the dependency now.

Loadout = Loadout or {}

local UI = Loadout.UI

local Minimap_ = {}

local button

local function position(self)
    local angle = math.rad(Loadout.db.options.minimap.angle or 200)
    self:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

local function onDragUpdate(self)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    Loadout.db.options.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    position(self)
end

function Minimap_.Create()
    if button then return button end

    button = CreateFrame("Button", "LoadoutMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", -1, 1)
    icon:SetTexture("Interface\\Icons\\INV_Chest_Plate06")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function() UI.Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Loadout")
        GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    position(button)
    if Loadout.db.options.minimap.hide then button:Hide() end
    return button
end

function Minimap_.SetHidden(hide)
    Loadout.db.options.minimap.hide = hide and true or false
    if button then
        if hide then button:Hide() else button:Show() end
    end
end

Loadout.Minimap = Minimap_
return Minimap_
