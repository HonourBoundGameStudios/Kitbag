-- KitbagFlyout — per-slot alternatives on the paperdoll (UI-5).
--
-- ItemRack's best feature and the one most worth beating: hover a slot on the character sheet and
-- every item you own that fits it appears beside it, one click from being worn.
--
-- What makes this Kitbag's version rather than a copy is that the click goes through the same
-- planner and the same driver as everything else (Sets.EquipItem). Swapping to a two-hander from the
-- flyout frees the off hand, and a full bag refuses up front, because it is not a second code path —
-- it is the one code path with a different button on the front of it.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Sets = Kitbag.Sets
local Inventory = Kitbag.Inventory

local Flyout = {}

local BUTTON_SIZE = 32
local MAX_BUTTONS = 12

-- Blizzard's own names for the paperdoll slot buttons. Two of them do not follow from the slot name
-- — the fingers and trinkets are numbered from zero, and the off hand is "SecondaryHand" — which is
-- exactly the sort of thing that is silently wrong until someone hovers that slot.
local PAPERDOLL = {
    [1] = "CharacterHeadSlot",      [2] = "CharacterNeckSlot",
    [3] = "CharacterShoulderSlot",  [4] = "CharacterShirtSlot",
    [5] = "CharacterChestSlot",     [6] = "CharacterWaistSlot",
    [7] = "CharacterLegsSlot",      [8] = "CharacterFeetSlot",
    [9] = "CharacterWristSlot",     [10] = "CharacterHandsSlot",
    [11] = "CharacterFinger0Slot",  [12] = "CharacterFinger1Slot",
    [13] = "CharacterTrinket0Slot", [14] = "CharacterTrinket1Slot",
    [15] = "CharacterBackSlot",     [16] = "CharacterMainHandSlot",
    [17] = "CharacterSecondaryHandSlot", [18] = "CharacterRangedSlot",
    [19] = "CharacterTabardSlot",
}

local panel, buttons
local openSlot = nil

local function hide()
    if panel then panel:Hide() end
    openSlot = nil
end

local function onButtonEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(Core.ItemLink(self.key))
    -- UI-19. The flyout still opens while you are dead — seeing which rings you own costs nothing
    -- and is worth doing while running back — but it must not look clickable when it is not. The
    -- sentence is Core's, so the window, the trinket bar and this frame explain the same refusal
    -- the same way.
    if panel and panel.blocked then
        GameTooltip:AddLine(Core.SWAP_BLOCKED[panel.blocked], 1, 0.5, 0.5, true)
    end
    GameTooltip:Show()
end

local function onButtonLeave()
    GameTooltip:Hide()
end

local function onButtonClick(self)
    -- Refused here rather than left to the driver: clicking a dimmed button and getting a chat line
    -- ten seconds later is the whole of UI-19, and the flyout is the surface where it is easiest to
    -- click by reflex.
    if panel and panel.blocked then return end
    Sets.EquipItem(self.key, self.slotId)
    hide()
end

local function build()
    -- TooltipBorderedFrameTemplate gives the panel the game's own tooltip frame for free, but it is
    -- not present on every flavour and CreateFrame with an unknown template is a hard error at load.
    -- A plain frame is a perfectly usable fallback; a broken addon is not.
    local ok, created = pcall(CreateFrame, "Frame", "KitbagFlyoutPanel", UIParent,
        "TooltipBorderedFrameTemplate")
    panel = ok and created or CreateFrame("Frame", "KitbagFlyoutPanel", UIParent)
    panel:SetFrameStrata("DIALOG")
    panel:Hide()

    -- The panel keeps itself open while the mouse is over it, and closes when the mouse is over
    -- neither it nor the slot that opened it. Closing on the slot's OnLeave alone would shut it in
    -- the gap between the two frames, before anything could be clicked.
    panel:SetScript("OnUpdate", function(self)
        if not self:IsMouseOver() and not (self.anchor and self.anchor:IsMouseOver()) then hide() end
    end)

    buttons = {}
    for i = 1, MAX_BUTTONS do
        local button = CreateFrame("Button", nil, panel)
        button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", 6 + (i - 1) * (BUTTON_SIZE + 2), -6)
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        button:SetScript("OnEnter", onButtonEnter)
        button:SetScript("OnLeave", onButtonLeave)
        button:SetScript("OnClick", onButtonClick)
        buttons[i] = button
    end

    return panel
end

--- Show the alternatives for one inventory slot, anchored to its paperdoll button.
function Flyout.Open(slotId, anchor)
    if not Kitbag.db.options.flyouts then return end
    if openSlot == slotId and panel and panel:IsShown() then return end
    if not panel then build() end

    local alternatives = Inventory.AlternativesFor(slotId)
    if #alternatives == 0 then
        hide()
        return
    end

    -- Asked once per open rather than once per button, and re-asked on every open, so the panel
    -- cannot keep offering clicks after you have died with it up.
    local canSwap, why = Core.CanSwap(Kitbag.Compat.ActionState())
    panel.blocked = (not canSwap) and why or nil

    -- More than the panel holds is a real possibility for rings on a well-travelled character. Show
    -- what fits and say nothing clever about the rest: the set list is the tool for a big wardrobe,
    -- and a flyout that paginates is a flyout nobody can use quickly.
    local shown = math.min(#alternatives, MAX_BUTTONS)
    for i, button in ipairs(buttons) do
        local entry = alternatives[i]
        if i <= shown and entry then
            button.key, button.slotId = entry.key, slotId
            button.icon:SetTexture(Kitbag.Compat.ItemIcon(Core.ItemId(entry.key)) or
                Sets.QUESTION_MARK)
            -- An item already worn elsewhere is dimmed: clicking it is a swap between two slots
            -- rather than putting something new on, and that is worth seeing before the click.
            local shade = entry.worn and 0.55 or 1
            -- Dimmer still when nothing can be equipped at all, so "you cannot use this right now"
            -- reads at a glance and not only from the tooltip.
            if panel.blocked then shade = shade * 0.5 end
            button.icon:SetVertexColor(shade, shade, shade)
            button:Show()
        else
            button:Hide()
        end
    end

    panel:SetSize(12 + shown * (BUTTON_SIZE + 2), BUTTON_SIZE + 12)
    panel:ClearAllPoints()
    panel:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
    panel.anchor = anchor
    panel:Show()
    openSlot = slotId
end

--- Attach to the character sheet. Called once, after the paperdoll exists.
function Flyout.Enable()
    for slotId, name in pairs(PAPERDOLL) do
        local button = _G[name]
        -- HookScript rather than SetScript: the paperdoll buttons already have an OnEnter that
        -- shows the item tooltip, and replacing it would break the character sheet for everyone.
        if button and button.HookScript then
            button:HookScript("OnEnter", function(self) Flyout.Open(slotId, self) end)
        end
    end
end

Kitbag.Flyout = Flyout
return Flyout
