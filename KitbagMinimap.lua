-- KitbagMinimap — the minimap button.
--
-- Hand-rolled rather than pulled from LibDBIcon, deliberately: Kitbag ships no vendored libraries,
-- and a 60-line button is cheaper to own than a dependency. Displays that host a LibDataBroker
-- launcher are served by KitbagBroker instead, which registers only if something else already
-- provided the library.

Kitbag = Kitbag or {}

local UI = Kitbag.UI

local Minimap_ = {}

local button

local function position(self)
    local angle = math.rad(Kitbag.db.options.minimap.angle or 200)
    self:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

local function onDragUpdate(self)
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    Kitbag.db.options.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    position(self)
end

function Minimap_.Create()
    if button then return button end

    button = CreateFrame("Button", "KitbagMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")

    -- 17x17 centred on (0, 1), not 20x20 on (-1, 1). The hole in MiniMap-TrackingBorder is round and
    -- about 20px across at this size, so a 20px *square* cannot fit in it — it needs 28px of
    -- diagonal, and the corners it could not fit spilled outside the ring as a black box. These are
    -- the numbers LibDBIcon uses against the same 31px button and 53px border.
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(17, 17)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Chest_Plate06")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Without this the frame only hears LeftButtonUp, so the right-click below would never fire.
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button:SetScript("OnClick", function(_, click)
        if click == "RightButton" then
            -- Looked up at call time, not captured at load: KitbagOptions loads *after* this file
            -- (it drives the button through APPLY), so the two cannot both hold a load-time local.
            Kitbag.Options.Toggle()
        else
            UI.Toggle()
        end
    end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Kitbag")
        GameTooltip:AddLine("Left-click to open. Drag to move.", 1, 1, 1)
        -- The hide switch lives in that panel, and a button nobody knows is togglable is a button
        -- people uninstall the addon over.
        GameTooltip:AddLine("Right-click for options.", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    position(button)
    if Kitbag.db.options.minimap.hide then button:Hide() end
    return button
end

function Minimap_.SetHidden(hide)
    Kitbag.db.options.minimap.hide = hide and true or false
    if button then
        if hide then button:Hide() else button:Show() end
    end
end

Kitbag.Minimap = Minimap_
return Minimap_
