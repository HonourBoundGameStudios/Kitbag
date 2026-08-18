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
local Skin = Kitbag.Skin

local Picker = {}

-- Sized to sit BESIDE the doll rather than over it. The panel is a momentary thing you open, click
-- once and dismiss, so every pixel it spends on itself is one it takes from the window it is
-- explaining. Four rows of five at the inspector's own cell pitch is a page of twenty, which covers
-- every slot but the rings on a well-travelled character — and those scroll.
local COLUMNS, ROWS = 5, 4
local CELL = 32
local PER_PAGE = COLUMNS * ROWS

local PAD = 6
local GRID_WIDTH = COLUMNS * CELL
-- FauxScrollFrameTemplate hangs its bar OUTSIDE the scroll frame's right edge, so the strip is not
-- optional: without it the bar lands on the last column of icons.
local BAR_STRIP = 20

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
    GameTooltip:SetHyperlink(Core.ItemLink(self.entry.key))
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
    -- A plain frame with a one-pixel border, NOT BasicFrameTemplateWithInset. That template spends
    -- roughly twenty pixels a side on stone and a header bar this panel has no use for, which on
    -- something the size of twenty icons is more chrome than content. The border here is the idiom
    -- the inspector's own cells already use — a tinted plate a pixel proud of a dark ground — so it
    -- is thin by construction, costs two textures, and cannot fail to load on any flavour.
    frame = CreateFrame("Frame", "KitbagPickerFrame", UIParent)
    -- Height is the sum of what is actually in it: the title strip, the grid, the count line and the
    -- row of buttons, plus the padding. Measured rather than rounded up, because slack at the bottom
    -- of a small panel reads as a missing control.
    frame:SetSize(PAD + GRID_WIDTH + BAR_STRIP + PAD, ROWS * CELL + 66)
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

    -- The border this panel is built around, now drawn by the shared skin rather than by ten lines
    -- of its own (UI-22). It was a neutral grey against the brass every other Kitbag region uses,
    -- which is the exact drift a hand-written recess produces: nobody chose the difference, it was
    -- simply typed twice.
    Skin.Inset(frame)

    -- Left-aligned and width-limited rather than centred: a long set name should run out of room
    -- against the close button instead of sliding out from under it.
    -- The title, the close button and the grid are NAMED so `/kit verify` can measure the three
    -- questions VERIFY-10 asks about this panel: does the bar clear the last column, does the close
    -- button clear the bar, and does a long name run out against the close button. All three are
    -- relationships between edges, which is precisely what an eye cannot settle to a pixel.
    frame.title = frame:CreateFontString("KitbagPickerTitle", "OVERLAY", "GameFontNormalSmall")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    frame.title:SetWidth(GRID_WIDTH + BAR_STRIP - 16)
    frame.title:SetJustifyH("LEFT")
    -- Set names are whatever the player typed. Wrapping is the wrong answer for a one-line strip —
    -- a second line would land on the first row of icons — so a long one is clipped instead.
    if frame.title.SetWordWrap then frame.title:SetWordWrap(false) end

    -- Esc closes it and so does picking anything, but a panel with no visible way out reads as
    -- stuck. Scaled well down from the template's default, which is itself the size of four icons.
    local close = CreateFrame("Button", "KitbagPickerClose", frame, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() frame:Hide() end)

    local grid = Skin.Inset(CreateFrame("Frame", "KitbagPickerGrid", frame))
    grid:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -20)
    grid:SetSize(GRID_WIDTH, ROWS * CELL)

    buttons = {}
    for i = 1, PER_PAGE do
        local button = CreateFrame("Button", nil, grid)
        button:SetSize(CELL - 4, CELL - 4)
        local column, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        button:SetPoint("TOPLEFT", grid, "TOPLEFT", column * CELL, -row * CELL)

        -- The set's current pick gets a gold plate a pixel proud of the icon — the same "the border
        -- IS the state" idiom the inspector's cells use, so the two panels read alike. One pixel and
        -- not two: at this pitch a two-pixel plate touches its neighbour and the marked icon reads
        -- as a gap in the grid rather than as a selection.
        button.mark = button:CreateTexture(nil, "BACKGROUND")
        button.mark:SetPoint("TOPLEFT", -1, 1)
        button.mark:SetPoint("BOTTOMRIGHT", 1, -1)
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

    -- One scroll row is one row of icons, not one icon: a five-wide grid that scrolls by a single
    -- cell moves its contents a fifth of a row and looks broken.
    scroll = CreateFrame("ScrollFrame", "KitbagPickerScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", grid, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CELL, Picker.Refresh)
    end)

    frame.note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.note:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -4)
    frame.note:SetWidth(GRID_WIDTH)
    frame.note:SetJustifyH("LEFT")

    -- The two answers that are not an item, and they are genuinely different answers. "Empty" is a
    -- deliberate instruction to take off whatever is there — a caster set that wants no shield.
    -- "Ignore" is the absence of an instruction, so the slot keeps whatever you have on. Storing
    -- them the same way is the bug that makes a set saved bare-headed refuse to remove your helmet.
    --
    -- One word each, because the panel is narrower than the sentence — so the sentence goes in a
    -- tooltip, where it can say the whole thing rather than a truncated half of it.
    local function bottomButton(text, tip, key)
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize((GRID_WIDTH - 4) / 2, 20)
        button:SetText(text)
        button:SetScript("OnClick", function()
            Sets.SetSlot(current.set, current.slot.id, key)
            frame:Hide()
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text, 1, 0.82, 0)
            GameTooltip:AddLine(tip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", onButtonLeave)
        return button
    end

    frame.empty = bottomButton("Empty",
        "The set takes off whatever is in this slot.", false)
    frame.empty:SetPoint("TOPLEFT", frame.note, "BOTTOMLEFT", 0, -4)

    frame.drop = bottomButton("Ignore",
        "The set has no opinion about this slot, so you keep wearing whatever you have on. " ..
        "For a set that inherits, this hands the slot back to its parent.", nil)
    frame.drop:SetPoint("LEFT", frame.empty, "RIGHT", 4, 0)

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

    -- Short by necessity: the line is one grid wide, and anything longer wraps onto the buttons
    -- beneath it rather than being truncated.
    if #choices == 0 then
        frame.note:SetText("|cff808080Nothing you own fits here.|r")
    else
        frame.note:SetText(string.format("%d item%s fit.", #choices, #choices == 1 and "" or "s"))
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
