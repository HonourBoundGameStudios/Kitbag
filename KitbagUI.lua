-- KitbagUI — the main window.
--
-- The brief is "better UI", and the specific thing being fixed is legibility of *state*. ItemRack
-- told you a set existed; it did not tell you whether you could actually wear it. Every row here
-- carries its own readiness, computed from the same planner that would do the equipping — so what
-- the window says and what the button does can never disagree.
--
-- The window is two halves. On the left, the set list and the save box: which sets exist and how
-- ready each one is. On the right, the inspector: the selected set drawn as a paperdoll, one cell
-- per slot, so "what is actually in this set" is answered by looking rather than by hovering. The
-- cells come from Core.Doll and are therefore plan-derived — an off hand that a two-hander is about
-- to free shows as being emptied even though the set never mentions that slot.
--
-- Its neighbours own the rest: KitbagRulesUI the rule editor, KitbagFlyout the per-slot menus on
-- Blizzard's own character sheet, KitbagIcons the icon picker.

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets
local Equip = Kitbag.Equip
local Core = Kitbag.Core

local UI = {}

local ROW_HEIGHT = 26
local MAX_ROWS = 13

local CELL = 34            -- a doll cell, big enough to read an icon at a glance
local CELL_GAP = 3
local PITCH = CELL + CELL_GAP
local PANEL_WIDTH = 300

local frame, rows, status, scroll, doll
local selected = nil       -- the set the inspector is showing

-- How each slot state reads, in one place: the colour of the cell's border and the words the
-- tooltip uses. Keeping them together is what stops the colour and the caption drifting apart.
local STATE = {
    worn    = { 0.25, 0.85, 0.35, text = "already on" },
    swap    = { 1.00, 0.82, 0.00, text = "will be equipped" },
    clear   = { 0.45, 0.55, 0.70, text = "will be emptied" },
    bank    = { 1.00, 0.60, 0.10, text = "waiting in your bank" },
    missing = { 1.00, 0.30, 0.30, text = "not found" },
    unknown = { 0.60, 0.60, 0.60, text = "" },
    unset   = { 0.28, 0.28, 0.28, text = "not part of this set" },
}

-- Blizzard's empty-slot art, so an untouched cell looks like the character sheet rather than a hole.
-- Several slots share one texture — both fingers, both trinkets — and the back slot borrows the
-- chest's, which is what the paperdoll itself does. A path that turns out not to exist on some
-- flavour simply draws nothing and leaves the plain cell behind it, so a wrong guess here is
-- cosmetic and cannot break the window.
local SLOT_ART = {
    HEAD = "Head", NECK = "Neck", SHOULDER = "Shoulder", SHIRT = "Shirt", CHEST = "Chest",
    WAIST = "Waist", LEGS = "Legs", FEET = "Feet", WRIST = "Wrists", HANDS = "Hands",
    FINGER1 = "Finger", FINGER2 = "Finger", TRINKET1 = "Trinket", TRINKET2 = "Trinket",
    BACK = "Chest", MAINHAND = "MainHand", OFFHAND = "SecondaryHand", RANGED = "Ranged",
    TABARD = "Tabard",
}

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

-- The name of an item key, or an honest stand-in. GetItemInfo returns nil for anything the client
-- has not cached, which is routine for the first seconds after a login — so a line degrades rather
-- than collapsing to nothing.
local function itemName(key)
    return (key and GetItemInfo(Core.ItemId(key))) or "an item"
end

-- ---------------------------------------------------------------------------
-- The set list
-- ---------------------------------------------------------------------------

-- The exact moves the Equip button would make, on hover (UI-6).
--
-- Read out of the plan itself rather than re-derived from the set, so the tooltip cannot promise
-- something different from what the driver does — it is the same list the driver is about to walk.
local function onRowEnter(self)
    local name = self.setName
    if not name then return end

    local plan, totals = self.data.plan, self.data.totals
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(name, 1, 0.82, 0)

    local stored = Kitbag.char.sets[name]
    if stored and stored.parent then
        GameTooltip:AddLine("inherits from " .. stored.parent, 0.6, 0.6, 0.6)
    end
    if totals and totals.level then
        GameTooltip:AddLine(string.format("%d items, average item level %s%d",
            totals.items, totals.complete and "" or "about ", math.floor(totals.level + 0.5)),
            0.6, 0.6, 0.6)
    end

    local lines = Core.Explain(plan)
    if #lines == 0 then
        GameTooltip:AddLine(plan and plan.empty and "Already worn." or "Nothing to do.", 0.4, 1, 0.4)
    else
        GameTooltip:AddLine(" ")
        for _, line in ipairs(lines) do
            local what = itemName(line.key)
            local text
            if line.missing then
                text = string.format("%s: %s — %s", line.slot, what, line.verb)
            elseif line.from then
                text = string.format("%s: move %s from %s", line.slot, what, line.from)
            else
                text = string.format("%s: %s %s", line.slot, line.verb, what)
            end
            if line.missing then
                GameTooltip:AddLine(text, 1, 0.5, 0.5)
            else
                GameTooltip:AddLine(text, 0.9, 0.9, 0.9)
            end
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to inspect it. Click the icon to change it, or drag it to a bar.",
        0.5, 0.5, 0.5)

    if plan and plan.blocked == "bags" then
        GameTooltip:AddLine(string.format("Bags full — needs %d free slot(s).", plan.needsBagSlots),
            1, 0.3, 0.3)
    end

    GameTooltip:Show()
end

local function onRowLeave()
    GameTooltip:Hide()
end

local function onRowClick(self)
    if not self.setName then return end
    selected = self.setName
    UI.Refresh()
end

local function createRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    -- Per-row DATA lives in its own table, never as loose fields on the frame. A frame is a live
    -- namespace of widgets and Blizzard methods, and `row.totals = <the totals table>` silently
    -- replaced the FontString of the same name — the crash reads as "SetText is nil", ten lines
    -- from the assignment that caused it. One subtable makes that collision impossible.
    row.data = {}
    row:SetScript("OnEnter", onRowEnter)
    row:SetScript("OnLeave", onRowLeave)
    row:SetScript("OnClick", onRowClick)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    -- Which row the inspector is showing. A highlight rather than a separate "selected" column: the
    -- list is narrow and one more glyph per row would cost more than it says.
    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints()
    row.selection:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.selection:SetVertexColor(1, 0.82, 0, 0.18)
    row.selection:Hide()

    row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
    local hl = row:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.07) end

    -- The icon doubles as the picker button. A separate "change icon" control would need a column
    -- of its own on a row that has none to spare, and clicking the icon is where anyone would try.
    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon.texture = row.icon:CreateTexture(nil, "ARTWORK")
    row.icon.texture:SetAllPoints()
    row.icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    row.icon:SetScript("OnClick", function(self) Kitbag.Icons.Open(self:GetParent().setName) end)
    -- Drag the icon to the action bar (UI-8). Click still opens the picker; the client distinguishes
    -- the two, so the icon can be both without either getting in the way.
    row.icon:RegisterForDrag("LeftButton")
    row.icon:SetScript("OnDragStart", function(self)
        Sets.PickupMacro(self:GetParent().setName)
    end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(130)

    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.state:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    row.state:SetJustifyH("LEFT")
    row.state:SetWidth(76)

    row.totals = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.totals:SetPoint("LEFT", row.state, "RIGHT", 6, 0)
    row.totals:SetJustifyH("LEFT")
    row.totals:SetWidth(56)

    return row
end

-- ---------------------------------------------------------------------------
-- The inspector — one set as a paperdoll (UI-13)
-- ---------------------------------------------------------------------------

local function onCellEnter(self)
    local cell = self.data.cell
    if not cell then return end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if cell.key then
        -- The real item tooltip where there is a real item, so stats and enchants read exactly as
        -- they do everywhere else in the game.
        GameTooltip:SetHyperlink("item:" .. tostring(Core.ItemId(cell.key)))
        GameTooltip:AddLine(" ")
    else
        GameTooltip:AddLine(cell.slot.label, 1, 0.82, 0)
    end

    local state = STATE[cell.state] or STATE.unset
    GameTooltip:AddLine(string.format("%s — %s", cell.slot.label, state.text),
        state[1], state[2], state[3])
    GameTooltip:Show()
end

local function onCellLeave()
    GameTooltip:Hide()
end

local function createCell(parent, x, y)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(CELL, CELL)
    cell:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cell:EnableMouse(true)
    cell.data = {}

    -- The border IS the state: a tinted plate one pixel proud of the cell, with the cell's own dark
    -- ground over it. Cheaper than a backdrop and identical on every flavour.
    cell.border = cell:CreateTexture(nil, "BACKGROUND")
    cell.border:SetPoint("TOPLEFT", -1, 1)
    cell.border:SetPoint("BOTTOMRIGHT", 1, -1)
    cell.border:SetTexture("Interface\\Buttons\\WHITE8X8")

    cell.ground = cell:CreateTexture(nil, "BORDER")
    cell.ground:SetAllPoints()
    cell.ground:SetTexture("Interface\\Buttons\\WHITE8X8")
    cell.ground:SetVertexColor(0.06, 0.06, 0.06, 1)

    cell.empty = cell:CreateTexture(nil, "ARTWORK")
    cell.empty:SetAllPoints()
    cell.empty:SetAlpha(0.45)

    cell.icon = cell:CreateTexture(nil, "OVERLAY")
    cell.icon:SetAllPoints()

    cell:SetScript("OnEnter", onCellEnter)
    cell:SetScript("OnLeave", onCellLeave)
    return cell
end

local function buildDoll(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 344, -34)
    panel:SetSize(PANEL_WIDTH, 392)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOP", panel, "TOP", 0, 0)
    panel.title:SetWidth(PANEL_WIDTH)

    local cells = {}
    local right = PANEL_WIDTH - 4 - CELL

    -- The layout is Core's, not this file's, so the one place that could lose a slot is the one
    -- place with a test asserting all nineteen are present exactly once.
    for i, slotId in ipairs(Core.DOLL_LAYOUT.left) do
        cells[slotId] = createCell(panel, 4, -24 - (i - 1) * PITCH)
    end
    for i, slotId in ipairs(Core.DOLL_LAYOUT.right) do
        cells[slotId] = createCell(panel, right, -24 - (i - 1) * PITCH)
    end

    -- The weapons in a row of their own beneath, centred, as the character sheet has them. Its
    -- position is measured off the columns rather than off a hardcoded eight — the layout is data,
    -- so nothing here should quietly disagree with it if it ever changes.
    local columnRows = math.max(#Core.DOLL_LAYOUT.left, #Core.DOLL_LAYOUT.right)
    local weaponsWidth = #Core.DOLL_LAYOUT.bottom * PITCH - CELL_GAP
    local weaponsX = math.floor((PANEL_WIDTH - weaponsWidth) / 2)
    local weaponsY = -24 - columnRows * PITCH
    for i, slotId in ipairs(Core.DOLL_LAYOUT.bottom) do
        cells[slotId] = createCell(panel, weaponsX + (i - 1) * PITCH, weaponsY)
    end

    -- The gap between the two columns is the only real space the window has; the set's headline
    -- numbers go there, where the eye already is, with the character beneath them.
    local gapWidth = PANEL_WIDTH - 2 * (8 + CELL)

    panel.summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.summary:SetPoint("TOP", panel, "TOP", 0, -24)
    panel.summary:SetWidth(gapWidth)
    panel.summary:SetJustifyH("CENTER")

    panel.note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.note:SetPoint("TOP", panel.summary, "BOTTOM", 0, -6)
    panel.note:SetWidth(gapWidth)
    panel.note:SetJustifyH("CENTER")

    -- The character itself, filling what is left of the gap: the icons say WHICH items, the model
    -- says what wearing them looks like, and neither answer was available before without equipping
    -- the set to find out. It is a preview, so it dresses the player in the set's items over what
    -- they already have on rather than undressing them — a slot the set does not name keeps showing
    -- the piece that will still be there afterwards. A slot the plan will EMPTY still shows its old
    -- piece, since the model can only add: the cell beside it already says "will be emptied", and a
    -- naked preview would be the more misleading of the two answers.
    --
    -- Guarded: `DressUpModel` and `TryOn` are ancient, but a flavour that lacks either would take
    -- the whole window down at build time, and the panel reads perfectly well without a model.
    local modelTop = -70
    local ok, model = pcall(CreateFrame, "DressUpModel", nil, panel)
    if ok and model and model.TryOn then
        model:SetSize(gapWidth, modelTop - weaponsY - 8)
        model:SetPoint("TOP", panel, "TOP", 0, modelTop)
        model:EnableMouse(true)
        model:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
        model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
        -- Drag to turn them around, as the dressing-room does. Kept on the frame rather than in a
        -- file-local so a redress can restore the angle the player chose.
        model:SetScript("OnUpdate", function(self)
            if not self.dragX then return end
            local x = GetCursorPosition()
            self.facing = (self.facing or 0) + (x - self.dragX) * 0.012
            self.dragX = x
            self:SetFacing(self.facing)
        end)
        panel.model = model
    end

    panel.equip = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.equip:SetSize(140, 24)
    panel.equip:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, weaponsY - CELL - 12)
    panel.equip:SetText("Equip")
    panel.equip:SetScript("OnClick", function() if selected then Sets.Equip(selected) end end)

    panel.delete = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.delete:SetSize(140, 24)
    panel.delete:SetPoint("LEFT", panel.equip, "RIGHT", 4, 0)
    panel.delete:SetText("Delete")
    panel.delete:SetScript("OnClick", function()
        if not selected then return end
        if IsShiftKeyDown() then
            Sets.Delete(selected)
        else
            Sets.Say("shift-click to delete |cffffd100%s|r.", selected)
        end
    end)

    panel.cells = cells
    return panel
end

--- Dress the preview in what the set would leave the player wearing.
---
--- Redressing is skipped when the items have not changed, because `SetUnit` restarts the model: an
--- unconditional redress on every Refresh would snap the angle the player dragged to back to the
--- front, and Refresh runs on bag and equipment events.
local function dressModel(cells)
    local model = doll.model
    if not model then return end

    local layout = Core.DOLL_LAYOUT
    local ids, n = {}, 0
    for _, list in ipairs({ layout.left, layout.right, layout.bottom }) do
        for _, slotId in ipairs(list) do
            local entry = cells[slotId]
            if entry and entry.key then
                n = n + 1
                ids[n] = Core.ItemId(entry.key)
            end
        end
    end

    local signature = table.concat(ids, ",", 1, n)
    if model.dressed == signature then return end
    model.dressed = signature

    -- SetUnit is the reset: it puts the player back in what they are actually wearing, which is the
    -- right starting point since equipping a set only replaces the slots the set names.
    model:SetUnit("player")
    model:SetFacing(model.facing or 0)
    for i = 1, n do
        pcall(model.TryOn, model, "item:" .. tostring(ids[i]))
    end
end

--- Draw the selected set into the doll. `plan` and `totals` come from the same Overview reading the
--- list used, so the panel and the row beside it cannot disagree.
local function refreshDoll(name, plan, totals)
    local shown = name ~= nil
    for _, cell in pairs(doll.cells) do
        if shown then cell:Show() else cell:Hide() end
    end
    -- Show/Hide and Enable/Disable rather than SetShown/SetEnabled throughout: the newer pair is
    -- almost certainly present on every flavour Kitbag targets, but "almost certainly" is how the
    -- last three load-time failures were described, and the old pair has existed since 1.0.
    if shown then doll.equip:Show() else doll.equip:Hide() end
    if shown then doll.delete:Show() else doll.delete:Hide() end
    if doll.model then
        if shown then doll.model:Show() else doll.model:Hide() end
    end

    if not shown then
        doll.title:SetText("")
        doll.summary:SetText("")
        doll.note:SetText("Select a set on the left to see what is in it.")
        return
    end

    doll.title:SetText(name)
    if Equip.IsRunning() then doll.equip:Disable() else doll.equip:Enable() end

    local cells = Core.Doll(Sets.Resolve(name), plan)
    dressModel(cells)
    for slotId, cell in pairs(doll.cells) do
        local entry = cells[slotId]
        local state = STATE[entry.state] or STATE.unset
        cell.data.cell = entry

        cell.border:SetVertexColor(state[1], state[2], state[3], 1)

        if entry.key then
            cell.icon:SetTexture(Kitbag.Compat.ItemIcon(Core.ItemId(entry.key)) or
                Sets.QUESTION_MARK)
            -- Something you cannot put on right now is drawn dim: the cell still tells you WHICH
            -- item you are missing, which is the useful half of the answer.
            local dim = (entry.state == "missing" or entry.state == "bank") and 0.4 or 1
            cell.icon:SetVertexColor(dim, dim, dim)
            cell.icon:Show()
            cell.empty:Hide()
        else
            cell.icon:Hide()
            cell.empty:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-" ..
                (SLOT_ART[entry.slot.key] or "Chest"))
            cell.empty:Show()
        end
    end

    if totals and totals.level then
        doll.summary:SetText(string.format("%silvl %d", totals.complete and "" or "≈",
            math.floor(totals.level + 0.5)))
    else
        doll.summary:SetText("")
    end

    -- One line for what stands between you and wearing this, in the words the row uses.
    if plan and plan.blocked == "bags" then
        doll.note:SetText(string.format("|cffff5050Bags full — needs %d free slot(s).|r",
            plan.needsBagSlots))
    elseif plan and plan.empty then
        doll.note:SetText("|cff40ff40You are wearing this.|r")
    elseif plan and #plan.missing > 0 then
        doll.note:SetText(string.format("|cffff8080%d piece%s not to hand.|r",
            #plan.missing, #plan.missing == 1 and "" or "s"))
    elseif plan then
        doll.note:SetText(string.format("%d swap%s to go.",
            #plan.actions, #plan.actions == 1 and "" or "s"))
    else
        doll.note:SetText("")
    end
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local function build()
    frame = CreateFrame("Frame", "KitbagFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(660, 480)
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
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -34)
    -- Room on the right for the scroll bar. Overlapping it would eat the rightmost few pixels of
    -- every row, which reads as a dead strip rather than as a layout bug.
    list:SetSize(316, MAX_ROWS * ROW_HEIGHT)

    rows = {}
    for i = 1, MAX_ROWS do rows[i] = createRow(list, i) end

    -- FauxScrollFrame rather than a real scrolling child: the rows stay put and the *data* moves
    -- through them, so thirteen frames serve a hundred sets. It is also the one scrolling widget
    -- that has existed unchanged in every flavour Kitbag targets.
    scroll = CreateFrame("ScrollFrame", "KitbagScrollFrame", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UI.Refresh)
    end)

    status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -10)
    status:SetWidth(316)
    status:SetJustifyH("LEFT")

    doll = buildDoll(frame)

    local rulesButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    rulesButton:SetSize(90, 22)
    rulesButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
    rulesButton:SetText("Rules")
    rulesButton:SetScript("OnClick", function() Kitbag.RulesUI.Toggle() end)

    local optionsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    optionsButton:SetSize(90, 22)
    optionsButton:SetPoint("RIGHT", rulesButton, "LEFT", -6, 0)
    optionsButton:SetText("Options")
    optionsButton:SetScript("OnClick", function() Kitbag.Options.Toggle() end)

    local nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    nameBox:SetSize(180, 20)
    nameBox:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 15)
    nameBox:SetAutoFocus(false)

    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetSize(150, 22)
    save:SetPoint("LEFT", nameBox, "RIGHT", 10, 0)
    save:SetText("Save what I'm wearing")
    save:SetScript("OnClick", function()
        local name = nameBox:GetText()
        if name == "" then
            Sets.Say("type a name in the box first.")
            return
        end
        Sets.Save(name)
        -- Show what was just saved: it is the set the player is thinking about.
        selected = name
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
    local overview = Sets.Overview()   -- one reading of the world for every row and the inspector

    -- A deleted (or renamed) set must not leave the inspector showing something that is gone, and
    -- opening on nothing selected wastes half the window. Falling back to the first set means the
    -- panel always has something in it.
    local exists = selected and overview[selected] ~= nil
    if not exists then selected = names[1] end

    FauxScrollFrame_Update(scroll, #names, MAX_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    for i, row in ipairs(rows) do
        local name = names[i + offset]
        if name then
            local entry = overview[name] or {}
            row.setName = name
            row.data.plan, row.data.totals = entry.plan, entry.totals
            row.icon.texture:SetTexture(Sets.Icon(name))
            row.name:SetText(name)
            row.state:SetText(rowReadiness(entry.plan))
            row.totals:SetText(rowTotals(entry.totals))
            if name == selected then row.selection:Show() else row.selection:Hide() end
            row:Show()
        else
            row.setName = nil
            row:Hide()
        end
    end

    local chosen = selected and overview[selected] or nil
    refreshDoll(selected, chosen and chosen.plan, chosen and chosen.totals)

    if #names == 0 then
        status:SetText("No sets yet. Put on what you want to save, name it below, and press Save.")
    else
        status:SetText(string.format("%d set%s. Click one to inspect it.",
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
