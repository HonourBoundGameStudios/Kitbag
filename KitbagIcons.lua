-- KitbagIcons — the set icon picker (UI-4).
--
-- Small and self-contained: one grid of every icon a macro may use, a filter box, and a button that
-- puts the set back to borrowing an item's icon. It is a separate file from KitbagUI because the
-- icon list is a few thousand entries and the paging arithmetic is the only complicated thing in it.

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets
local Compat = Kitbag.Compat

local Icons = {}

local COLUMNS, ROWS = 10, 8
local CELL = 36
local PER_PAGE = COLUMNS * ROWS

local frame, buttons, scroll, filterBox, current, filtered

-- The icon list is thousands of entries and the filter has to walk all of them, so the result is
-- cached against the text that produced it. Retyping in the box otherwise rebuilds the whole list
-- on every keystroke.
local function rebuild(text)
    text = (text or ""):lower():match("^%s*(.-)%s*$")
    local all = Compat.MacroIcons()

    if text == "" then
        filtered = all
        return
    end

    filtered = {}
    for _, texture in ipairs(all) do
        -- Numeric file ids cannot be searched by name; they are kept so a filter never hides icons
        -- it simply cannot read. Better a few extra than a silently short list.
        if type(texture) ~= "string" or texture:lower():find(text, 1, true) then
            filtered[#filtered + 1] = texture
        end
    end
end

local function onIconClick(self)
    if current then Sets.SetIcon(current, self.texture) end
    frame:Hide()
end

local function build()
    frame = CreateFrame("Frame", "KitbagIconFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(COLUMNS * CELL + 46, ROWS * CELL + 96)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")   -- it is opened from the set list and must sit above it
    frame:SetToplevel(true)          -- and above the other DIALOG panels once clicked
    frame:Hide()
    tinsert(UISpecialFrames, "KitbagIconFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Choose an icon")

    filterBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    filterBox:SetSize(160, 20)
    filterBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -30)
    filterBox:SetAutoFocus(false)
    filterBox:SetScript("OnTextChanged", function(self)
        rebuild(self:GetText())
        FauxScrollFrame_SetOffset(scroll, 0)
        Icons.Refresh()
    end)

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(120, 20)
    clear:SetPoint("LEFT", filterBox, "RIGHT", 12, 0)
    clear:SetText("Use item icon")
    clear:SetScript("OnClick", function()
        -- nil, not the question mark: clearing means "go back to borrowing", and storing the
        -- question mark would freeze the set on it even once its items are known.
        if current then Sets.SetIcon(current, nil) end
        frame:Hide()
    end)

    -- Named like the slot picker's grid, so `/kit verify` can compare this list's stacking against the
    -- other three (VERIFY-11): the wheel question is one question about a construction shared by all
    -- four lists, and this is the list a person can spin a wheel over without building anything first.
    local grid = CreateFrame("Frame", "KitbagIconGrid", frame)
    grid:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -58)
    grid:SetSize(COLUMNS * CELL, ROWS * CELL)

    buttons = {}
    for i = 1, PER_PAGE do
        local button = CreateFrame("Button", nil, grid)
        button:SetSize(CELL - 4, CELL - 4)
        local column, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        button:SetPoint("TOPLEFT", grid, "TOPLEFT", column * CELL, -row * CELL)
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetAllPoints()
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        button:SetScript("OnClick", onIconClick)
        buttons[i] = button
    end

    -- One row of the scroll bar is one row of icons, not one icon: scrolling by a single cell in a
    -- ten-wide grid moves the contents a tenth of a row and looks broken.
    scroll = CreateFrame("ScrollFrame", "KitbagIconScroll", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", grid, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CELL, Icons.Refresh)
    end)

    return frame
end

function Icons.Refresh()
    if not frame or not frame:IsShown() then return end
    filtered = filtered or Compat.MacroIcons()

    local rowCount = math.ceil(#filtered / COLUMNS)
    FauxScrollFrame_Update(scroll, rowCount, ROWS, CELL)
    local first = FauxScrollFrame_GetOffset(scroll) * COLUMNS

    for i, button in ipairs(buttons) do
        local texture = filtered[first + i]
        if texture then
            button.texture = texture
            button.icon:SetTexture(texture)
            button:Show()
        else
            button:Hide()
        end
    end
end

--- Open the picker for a named set.
function Icons.Open(setName)
    if not frame then build() end
    current = setName
    frame.title:SetText("Icon for " .. tostring(setName))
    filterBox:SetText("")
    rebuild("")
    FauxScrollFrame_SetOffset(scroll, 0)
    frame:Show()
    Icons.Refresh()
end

Kitbag.Icons = Icons
return Icons
