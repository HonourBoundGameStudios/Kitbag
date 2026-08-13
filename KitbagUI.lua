-- KitbagUI — the main window.
--
-- The brief is "better UI", and the specific thing being fixed is legibility of *state*. ItemRack
-- told you a set existed; it did not tell you whether you could actually wear it. Every row here
-- carries its own readiness, computed from the same planner that would do the equipping — so what
-- the window says and what the button does can never disagree.
--
-- This is a scaffold: the window is real and usable, but the rule editor, the per-slot flyouts and
-- the set icon picker are backlog items (Process/Backlog.md, EPIC-UI).

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets
local Equip = Kitbag.Equip

local UI = {}

local ROW_HEIGHT = 26
local MAX_ROWS = 10

local frame, rows, status, scroll

local function rowReadiness(plan)
    if not plan then return "|cff808080—|r" end
    if plan.empty then return "|cff40ff40worn|r" end
    -- Ahead of "missing": a full bag stops the whole swap, so it is the thing to fix first.
    if plan.blocked == "bags" then return "|cffff8080bags full|r" end
    if #plan.missing > 0 then
        -- Say "at bank" only when the bank explains ALL of it. A set that is part banked and part
        -- genuinely lost would otherwise send the player on a trip that cannot finish the set.
        if plan.atBank == #plan.missing then
            return string.format("|cffffd100%d at bank|r", plan.atBank)
        end
        return string.format("|cffff8080%d missing|r", #plan.missing)
    end
    return string.format("|cffffd100%d swap%s|r", #plan.actions, #plan.actions == 1 and "" or "s")
end

-- Item level and the weakest piece, in the little space a row has (CORE-4).
--
-- "≈" when the client has not cached every item yet: the number is real but computed over part of
-- the set, and quietly showing a partial average as a firm one is how a raid set reads as green
-- trash for the first ten seconds after a login. Durability is only shown once it is worth acting
-- on — a bar at 96% is noise, one at 15% is a trip to the vendor.
local function rowTotals(totals)
    if not totals or not totals.level then return "" end

    local text = string.format("%silvl %d",
        totals.complete and "" or "≈", math.floor(totals.level + 0.5))
    if totals.broken > 0 then
        text = text .. " |cffff4040broken|r"
    elseif totals.durability and totals.durability < 0.25 then
        text = text .. string.format(" |cffff8080%d%%|r", math.floor(totals.durability * 100))
    end
    return text
end

local function onEquipClick(self)
    Sets.Equip(self.setName)
end

local function onDeleteClick(self)
    if IsShiftKeyDown() then
        Sets.Delete(self.setName)
    else
        Sets.Say("shift-click to delete |cffffd100%s|r.", self.setName)
    end
end

local function createRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(140)

    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.state:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    row.state:SetJustifyH("LEFT")
    row.state:SetWidth(80)

    row.totals = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.totals:SetPoint("LEFT", row.state, "RIGHT", 6, 0)
    row.totals:SetJustifyH("LEFT")
    row.totals:SetWidth(62)

    row.equip = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.equip:SetSize(64, 20)
    row.equip:SetPoint("RIGHT", row, "RIGHT", -70, 0)
    row.equip:SetText("Equip")
    row.equip:SetScript("OnClick", onEquipClick)

    row.delete = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.delete:SetSize(60, 20)
    row.delete:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.delete:SetText("Delete")
    row.delete:SetScript("OnClick", onDeleteClick)

    return row
end

local function build()
    frame = CreateFrame("Frame", "KitbagFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 340)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    -- Esc closes it, like every other panel in the game.
    tinsert(UISpecialFrames, "KitbagFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Kitbag")

    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
    -- Room on the right for the scroll bar. Overlapping it would make the Delete button of every
    -- row unclickable in its rightmost few pixels, which reads as a dead button, not as a layout bug.
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 66)

    rows = {}
    for i = 1, MAX_ROWS do rows[i] = createRow(list, i) end

    -- FauxScrollFrame rather than a real scrolling child: the rows stay put and the *data* moves
    -- through them, so ten frames serve a hundred sets. It is also the one scrolling widget that
    -- has existed unchanged in every flavour Kitbag targets.
    scroll = CreateFrame("ScrollFrame", "KitbagScrollFrame", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UI.Refresh)
    end)

    status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 40)
    -- Stops short of the Rules button, which shares this line.
    status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -112, 40)
    status:SetJustifyH("LEFT")

    local rulesButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rulesButton:SetSize(90, 20)
    rulesButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 38)
    rulesButton:SetText("Rules")
    rulesButton:SetScript("OnClick", function() Kitbag.RulesUI.Toggle() end)

    local nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    nameBox:SetSize(200, 20)
    nameBox:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 14)
    nameBox:SetAutoFocus(false)

    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetSize(140, 22)
    save:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 13)
    save:SetText("Save what I'm wearing")
    save:SetScript("OnClick", function()
        local name = nameBox:GetText()
        if name == "" then
            Sets.Say("type a name in the box first.")
            return
        end
        Sets.Save(name)
        nameBox:SetText("")
        nameBox:ClearFocus()
    end)

    return frame
end

--- Redraw. Called after anything that could change what a row should say — which is why every
--- mutating path in KitbagSets ends in Kitbag.Refresh().
function UI.Refresh()
    if not frame or not frame:IsShown() then return end

    local names = Sets.Names()
    local overview = Sets.Overview()   -- one reading of the world for every row

    FauxScrollFrame_Update(scroll, #names, MAX_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    for i, row in ipairs(rows) do
        local name = names[i + offset]
        if name then
            local entry = overview[name] or {}
            row.name:SetText(name)
            row.state:SetText(rowReadiness(entry.plan))
            row.totals:SetText(rowTotals(entry.totals))
            row.equip.setName, row.delete.setName = name, name
            row.equip:SetEnabled(not Equip.IsRunning())
            row:Show()
        else
            row:Hide()
        end
    end

    if #names == 0 then
        status:SetText("No sets yet. Put on what you want to save, name it below, and press Save.")
    else
        status:SetText(string.format("%d set%s. Shift-click Delete to remove one.",
            #names, #names == 1 and "" or "s"))
    end
end

function UI.Toggle()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        UI.Refresh()
    end
end

Kitbag.UI = UI
return UI
