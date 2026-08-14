-- KitbagPicker — choose the gear a set puts in one slot (UI-14).
--
-- The other half of ItemRack's best idea. KitbagFlyout puts the "what else fits here" menu on
-- Blizzard's character sheet, where clicking equips it *now*; this puts the same menu on the
-- inspector's paperdoll, where clicking writes it into the SET instead. That is how a set gets built
-- out of gear you are not wearing — which is the whole reason a second set exists.
--
-- It owns no decisions. What fits a slot is Core.Choices, what a slot may hold is Core.SetSlot, and
-- both are pure and tested outside the game; this file is the frame that calls them.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Sets = Kitbag.Sets
local Inventory = Kitbag.Inventory

local Picker = {}

local COLUMNS, ROWS = 6, 5
local CELL = 40
local PER_PAGE = COLUMNS * ROWS

local frame, buttons, scroll
local current                 -- { set =, slot = <record>, choices = , key = } while open

-- The item the set already names for this slot, so the panel can mark it. Read off the RESOLVED set
-- rather than the stored delta: a piece coming from a parent is still what the set will put on, and
-- showing it as unchosen would invite a click that changes nothing visible.
local function chosenKey()
    local set = current and Sets.Resolve(current.set)
    return set and set.slots and set.slots[current.slot.id]
end

local function onButtonEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. tostring(Core.ItemId(self.entry.key)))
    -- Where it is, in the words the rest of the window uses. An item in the bank can be named by a
    -- set perfectly well; it just cannot be put on until you are standing at one.
    if self.entry.bank then
        GameTooltip:AddLine("In your bank.", 1, 0.6, 0.1)
    elseif self.entry.worn then
        local slot = Core.SlotById(self.entry.worn)
        GameTooltip:AddLine("Worn — " .. (slot and slot.label or "somewhere"), 0.25, 0.85, 0.35)
    end
    GameTooltip:Show()
end

local function onButtonLeave()
    GameTooltip:Hide()
end

local function onButtonClick(self)
    Sets.SetSlot(current.set, current.slot.id, self.entry.key)
    frame:Hide()
end

local function build()
    frame = CreateFrame("Frame", "KitbagPickerFrame", UIParent, "BasicFrameTemplateWithInset")
    -- The width carries the grid plus a strip on the right for the scroll bar, which
    -- FauxScrollFrameTemplate hangs OUTSIDE the scroll frame's right edge. Without the strip the bar
    -- lands on the last column of icons, which reads as a dead column rather than as a layout bug.
    frame:SetSize(COLUMNS * CELL + 62, ROWS * CELL + 96)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    -- DIALOG, above the main window it is opened from, and toplevel so two Kitbag panels cannot get
    -- stuck the wrong way round. Same stack the icon picker and the rule editor are in.
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:Hide()
    tinsert(UISpecialFrames, "KitbagPickerFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)

    local grid = CreateFrame("Frame", nil, frame)
    grid:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -30)
    grid:SetSize(COLUMNS * CELL, ROWS * CELL)

    buttons = {}
    for i = 1, PER_PAGE do
        local button = CreateFrame("Button", nil, grid)
        button:SetSize(CELL - 4, CELL - 4)
        local column, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        button:SetPoint("TOPLEFT", grid, "TOPLEFT", column * CELL, -row * CELL)

        -- The set's current pick gets a gold plate a pixel proud of the icon — the same "the border
        -- IS the state" idiom the inspector's cells use, so the two panels read alike.
        button.mark = button:CreateTexture(nil, "BACKGROUND")
        button.mark:SetPoint("TOPLEFT", -2, 2)
        button.mark:SetPoint("BOTTOMRIGHT", 2, -2)
        button.mark:SetTexture("Interface\\Buttons\\WHITE8X8")
        button.mark:SetVertexColor(1, 0.82, 0, 1)
        button.mark:Hide()

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        button:SetScript("OnEnter", onButtonEnter)
        button:SetScript("OnLeave", onButtonLeave)
        button:SetScript("OnClick", onButtonClick)
        buttons[i] = button
    end

    -- One scroll row is one row of icons, not one icon: a six-wide grid that scrolls by a single
    -- cell moves its contents a sixth of a row and looks broken.
    scroll = CreateFrame("ScrollFrame", "KitbagPickerScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", grid, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CELL, Picker.Refresh)
    end)

    frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.note:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -8)
    frame.note:SetWidth(COLUMNS * CELL)
    frame.note:SetJustifyH("LEFT")

    -- The two answers that are not an item, and they are genuinely different answers. "Empty" is a
    -- deliberate instruction to take off whatever is there — a caster set that wants no shield. "Not
    -- in this set" is the absence of an instruction, so the slot keeps whatever you have on. Storing
    -- them the same way is the bug that makes a set saved bare-headed refuse to remove your helmet.
    frame.empty = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.empty:SetSize(COLUMNS * CELL / 2 - 3, 22)
    frame.empty:SetPoint("TOPLEFT", frame.note, "BOTTOMLEFT", 0, -6)
    frame.empty:SetText("Wear nothing")
    frame.empty:SetScript("OnClick", function()
        Sets.SetSlot(current.set, current.slot.id, false)
        frame:Hide()
    end)

    frame.drop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.drop:SetSize(COLUMNS * CELL / 2 - 3, 22)
    frame.drop:SetPoint("LEFT", frame.empty, "RIGHT", 6, 0)
    frame.drop:SetText("Leave alone")
    frame.drop:SetScript("OnClick", function()
        Sets.SetSlot(current.set, current.slot.id, nil)
        frame:Hide()
    end)

    return frame
end

--- Redraw the current page. Kept separate from Open because the scroll bar calls it.
function Picker.Refresh()
    if not frame or not frame:IsShown() or not current then return end

    local choices = current.choices
    local chosen = chosenKey()

    FauxScrollFrame_Update(scroll, math.ceil(#choices / COLUMNS), ROWS, CELL)
    local first = FauxScrollFrame_GetOffset(scroll) * COLUMNS

    for i, button in ipairs(buttons) do
        local entry = choices[first + i]
        if entry then
            button.entry = entry
            button.icon:SetTexture(Kitbag.Compat.ItemIcon(Core.ItemId(entry.key)) or
                Sets.QUESTION_MARK)
            -- Dimmed for something not to hand: it is a perfectly good choice for a set, but the
            -- set will not be wearable until you have walked to the bank, and that is worth seeing
            -- before the click rather than afterwards in the inspector's note.
            local shade = entry.bank and 0.45 or 1
            button.icon:SetVertexColor(shade, shade, shade)
            if entry.key == chosen then button.mark:Show() else button.mark:Hide() end
            button:Show()
        else
            button.entry = nil
            button:Hide()
        end
    end

    if #choices == 0 then
        frame.note:SetText("|cff808080You own nothing else that fits this slot.|r")
    else
        frame.note:SetText(string.format("%d item%s fit this slot.",
            #choices, #choices == 1 and "" or "s"))
    end
end

--- Open the picker for one slot of one set, anchored to the doll cell that was clicked.
function Picker.Open(setName, slotId, anchor)
    local slot = Core.SlotById(slotId)
    if not setName or not slot then return end
    if not frame then build() end

    current = {
        set = setName,
        slot = slot,
        -- Read once, on open. The panel is a momentary thing and rescanning every bag on each
        -- redraw would make scrolling it cost more than opening it.
        choices = Inventory.ChoicesFor(slotId),
    }

    frame.title:SetText(string.format("%s — %s", slot.label, setName))

    -- Beside the cell that was clicked, so the doll stays visible and the eye does not have to
    -- travel. Clamped to the screen, so a cell near the edge does not open the panel off it.
    frame:ClearAllPoints()
    if anchor then
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 8)
    else
        frame:SetPoint("CENTER")
    end

    FauxScrollFrame_SetOffset(scroll, 0)
    frame:Show()
    Picker.Refresh()
end

--- Close it, if it is open. Called when the window it belongs to goes away.
function Picker.Close()
    if frame then frame:Hide() end
end

Kitbag.Picker = Picker
return Picker
