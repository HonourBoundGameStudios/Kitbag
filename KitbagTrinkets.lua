-- KitbagTrinkets — quick-use buttons for the two trinket slots (UI-7).
--
-- A standalone, movable pair of buttons rather than a panel inside the Kitbag window, because
-- "quick-use" and "open a window first" are contradictory. Off by default: an addon that puts
-- unrequested frames on someone's screen is an addon they uninstall.
--
-- The one real constraint is that using an item is a protected action. The buttons are therefore
-- SecureActionButtonTemplate with their attributes fixed at creation — the slot ids never change, so
-- nothing needs to be written to them in combat, which is the thing the client forbids.

Kitbag = Kitbag or {}

local Trinkets = {}

local SLOTS = { 13, 14 }
local SIZE = 36

local frame, buttons

local function options()
    return Kitbag.db.options.trinkets
end

local function onEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if GameTooltip:SetInventoryItem("player", self.slotId) then
        GameTooltip:AddLine("Drag the frame to move it.", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine("No trinket equipped")
        GameTooltip:AddLine("Drag the frame to move it.", 0.6, 0.6, 0.6)
    end
    -- UI-19. Set by Refresh, which is polling anyway, so the reason is never staler than a fifth of
    -- a second. Same sentence as the window and the flyouts, from Core.SWAP_BLOCKED — the two
    -- conditions it names are both real here: the client refuses to USE an item while you are dead
    -- or mid-cast exactly as it refuses to equip one.
    if frame and frame.blocked then
        GameTooltip:AddLine(Kitbag.Core.SWAP_BLOCKED[frame.blocked], 1, 0.5, 0.5, true)
    end
    GameTooltip:Show()
end

local function build()
    frame = CreateFrame("Frame", "KitbagTrinketBar", UIParent)
    frame:SetSize(SIZE * 2 + 6, SIZE)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relative, x, y = self:GetPoint()
        options().point, options().relative, options().x, options().y = point, relative, x, y
    end)

    buttons = {}
    for i, slotId in ipairs(SLOTS) do
        local button = CreateFrame("Button", "KitbagTrinket" .. i, frame,
            "SecureActionButtonTemplate")
        button:SetSize(SIZE, SIZE)
        button:SetPoint("LEFT", frame, "LEFT", (i - 1) * (SIZE + 6), 0)
        button.slotId = slotId

        -- Fixed at creation and never touched again: writing a secure attribute during combat is
        -- refused, and "/use 13" is true for the whole session whatever is in the slot.
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", "/use " .. slotId)
        button:RegisterForClicks("AnyUp")

        button.icon = button:CreateTexture(nil, "BACKGROUND")
        button.icon:SetAllPoints()
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        button:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")

        button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.cooldown:SetAllPoints()

        button:SetScript("OnEnter", onEnter)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        buttons[i] = button
    end

    local saved = options()
    frame:SetPoint(saved.point or "CENTER", UIParent, saved.relative or "CENTER",
        saved.x or 0, saved.y or -160)

    -- Polled rather than event-driven: there is no event for "a trinket came off cooldown". Five
    -- times a second is far finer than a player can see and costs two API calls, where doing it per
    -- frame would be a hundred and eighty for no visible difference.
    local since = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since < 0.2 then return end
        since = 0
        Trinkets.Refresh()
    end)
    return frame
end

--- Repaint the icons and the cooldown swipes.
function Trinkets.Refresh()
    if not frame or not frame:IsShown() then return end

    -- Dimmed, never Disabled: these are SecureActionButtonTemplate buttons and the whole point of
    -- fixing their attributes at creation is that this file touches nothing protected once combat
    -- starts. A greyed-out look is the honest signal; taking the click away is not worth reaching
    -- into secure state for.
    local canSwap, why = Kitbag.Core.CanSwap(Kitbag.Compat.ActionState())
    frame.blocked = (not canSwap) and why or nil

    for _, button in ipairs(buttons) do
        local texture = GetInventoryItemTexture("player", button.slotId)
        button.icon:SetTexture(texture or "Interface\\Buttons\\UI-EmptySlot")
        -- An empty slot shows the socket rather than being hidden: a bar with one button on Tuesday
        -- and two on Wednesday moves under the cursor, and a button that moves is a button misclicked.
        button.icon:SetAlpha(texture and (frame.blocked and 0.4 or 1) or 0.35)

        -- Only when it actually changes. SetCooldown restarts the swipe animation, so calling it
        -- every tick with the same numbers gives a swipe that never advances.
        local start, duration, enable = GetInventoryItemCooldown("player", button.slotId)
        if start ~= button.cdStart or duration ~= button.cdDuration then
            button.cdStart, button.cdDuration = start, duration
            button.cooldown:SetCooldown(start or 0, duration or 0)
        end
        button.cooldown:SetAlpha(enable == 0 and 0 or 1)
    end
end

--- Show or hide the bar, remembering the choice.
function Trinkets.SetHidden(hide)
    options().hide = hide and true or false
    if not frame and not hide then build() end
    if frame then
        if hide then frame:Hide() else frame:Show() end
    end
    if not hide then Trinkets.Refresh() end
end

function Trinkets.Create()
    if options().hide then return end
    if not frame then build() end
    frame:Show()
    Trinkets.Refresh()
end

Kitbag.Trinkets = Trinkets
return Trinkets
