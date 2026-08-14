-- KitbagRulesUI — the rule editor (RULE-2).
--
-- The rule engine has been evaluable since RULE-1 and unusable, because there was no way to write a
-- rule inside the game. This is that window, and it is deliberately thin: everything it decides —
-- what a condition is, what a rule reads as in English, what moving a rule does to the list — is in
-- KitbagRules, pure and tested. What is left here is widgets.
--
-- The design answer to ItemRack's worst feature: a rule list you can read as sentences, in the order
-- that decides ties, with the winner of the current world state marked. "Why am I wearing this" is
-- answerable by looking.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Rules = Kitbag.Rules
local Sets = Kitbag.Sets
local Events = Kitbag.Events
local Compat = Kitbag.Compat

local RulesUI = {}

local ROW_HEIGHT = 22
local MAX_ROWS = 8

local frame, rows, hint, scroll
local editor = nil      -- { index = n | nil, set = "…", priority = n, values = { … }, widgets = … }

local function rules() return Kitbag.char.rules end

-- Form names are per class and only the client knows them, so Describe is handed them rather than
-- guessing. Rebuilt on each redraw: a druid learns Flight Form mid-session.
local function labels()
    return { form = Compat.FormLabels() }
end

-- ---------------------------------------------------------------------------
-- The editor pane
-- ---------------------------------------------------------------------------

-- Every condition is a dropdown or a text box, and every one of them has an "Any" that means "this
-- rule does not care". A tick box could not express that: absent, true and false are three distinct
-- states — "out of combat" is a real condition, not the absence of "in combat" — and a two-state
-- widget would quietly turn every unused condition into a constraint.
local ANY = "|cff808080Any|r"

local function setDropdownValue(dropdown, value, text)
    dropdown.value = value
    UIDropDownMenu_SetText(dropdown, text)
end

local function makeDropdown(parent, name, width, build)
    local dropdown = CreateFrame("Frame", "KitbagRulesDD" .. name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dropdown, width)
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, option in ipairs(build()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.text
            info.checked = dropdown.value == option.value
            info.func = function()
                setDropdownValue(dropdown, option.value, option.text)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    return dropdown
end

-- The set a rule wears. Listed from the character's own sets rather than typed, because a rule
-- naming a set that does not exist is dead and gives no sign of it.
local function setOptions()
    local options = {}
    for _, name in ipairs(Sets.Names()) do
        options[#options + 1] = { value = name, text = name }
    end
    if #options == 0 then
        options[1] = { value = nil, text = "|cff808080no sets saved yet|r" }
    end
    return options
end

-- A choice either carries its own fixed list (instance type: the client's tokens, which nobody would
-- type correctly) or is filled from the client (forms, which are per class). The catalogue says
-- which, so a new condition needs no change here.
local function conditionOptions(condition)
    local options = { { value = nil, text = ANY } }

    if condition.kind == "boolean" then
        options[2] = { value = true, text = "Yes" }
        options[3] = { value = false, text = "No" }
        return options
    end

    if condition.options then
        for _, option in ipairs(condition.options) do options[#options + 1] = option end
        return options
    end

    for index, label in pairs(Compat.FormLabels()) do
        options[#options + 1] = { value = index, text = label }
    end
    -- pairs() over a table with a [0] key is not ordered; the form list must not reshuffle itself
    -- between two openings of the same dropdown.
    table.sort(options, function(a, b)
        if a.value == nil then return true end
        if b.value == nil then return false end
        return a.value < b.value
    end)
    return options
end

local function conditionText(condition, value)
    if value == nil then return ANY end
    if condition.kind == "boolean" then return value and "Yes" or "No" end
    for _, option in ipairs(conditionOptions(condition)) do
        if option.value == value then return option.text end
    end
    return tostring(value)
end

--- Load a rule (or nil, for a new one) into the editor pane.
local function edit(index)
    local rule = index and rules()[index] or nil
    editor.index = index
    setDropdownValue(editor.setDrop, rule and rule.set or nil,
        rule and rule.set or "|cff808080choose a set|r")
    editor.priority:SetText(tostring(rule and rule.priority or 50))
    editor.restore:SetChecked(rule and rule.restore == true)

    for key, widget in pairs(editor.conditions) do
        local condition = Rules.Condition(key)
        local value = rule and rule.when and rule.when[key] or nil
        if condition.kind == "text" then
            widget:SetText(value or "")
        else
            setDropdownValue(widget, value, conditionText(condition, value))
        end
    end

    editor.save:SetText(index and "Save changes" or "Add rule")
    RulesUI.Refresh()
end

local function collect()
    local input = {}
    for key, widget in pairs(editor.conditions) do
        local condition = Rules.Condition(key)
        input[key] = condition.kind == "text" and widget:GetText() or widget.value
    end
    return Rules.Coerce(input)
end

local function commit()
    local set = editor.setDrop.value
    if not set then
        Sets.Say("choose a set for the rule to wear.")
        return
    end

    -- A priority the player cannot see the effect of is worse than no priority: default rather than
    -- refuse, but never store a string, which would compare unpredictably against a number.
    local priority = tonumber(editor.priority:GetText()) or 50
    local rule = {
        set = set,
        priority = priority,
        enabled = true,
        restore = editor.restore:GetChecked() and true or nil,
        when = collect(),
    }

    if editor.index then
        -- Keep the enabled flag: editing a rule's conditions should not silently switch it back on.
        rule.enabled = rules()[editor.index].enabled ~= false
        rules()[editor.index] = rule
    else
        rules()[#rules() + 1] = rule
    end

    Sets.Say("rule saved: wear |cffffd100%s|r %s.", set, Rules.Describe(rule, labels()))
    edit(nil)
end

-- ---------------------------------------------------------------------------
-- The rule list
-- ---------------------------------------------------------------------------

local function createRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    row.enabled = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.enabled:SetSize(20, 20)
    row.enabled:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.enabled:SetScript("OnClick", function(self)
        local rule = rules()[self:GetParent().ruleIndex]
        if rule then rule.enabled = self:GetChecked() and true or false end
        RulesUI.Refresh()
    end)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.enabled, "RIGHT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -96, 0)
    row.text:SetJustifyH("LEFT")

    local function tinyButton(label, offset, delta)
        local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        button:SetSize(24, 18)
        button:SetPoint("RIGHT", row, "RIGHT", offset, 0)
        button:SetText(label)
        button:SetScript("OnClick", function(self)
            local index = self:GetParent().ruleIndex
            if delta == 0 then
                table.remove(rules(), index)
                -- The rule being edited may have just moved or vanished under the editor; dropping
                -- back to a new rule is the only state that is certainly still true.
                edit(nil)
            else
                Rules.Move(rules(), index, delta)
                RulesUI.Refresh()
            end
        end)
        return button
    end

    row.up = tinyButton("^", -70, -1)
    row.down = tinyButton("v", -44, 1)
    row.remove = tinyButton("X", -4, 0)

    row:SetScript("OnClick", function(self) edit(self.ruleIndex) end)
    return row
end

local function build()
    frame = CreateFrame("Frame", "KitbagRulesFrame", UIParent, "BasicFrameTemplateWithInset")
    -- Tall enough for the whole condition catalogue in two columns; it grew with RULE-3 and RULE-5.
    frame:SetSize(520, 520)
    frame:SetPoint("CENTER", UIParent, "CENTER", 60, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    -- Above the main window, which is what opens it. See the strata note in KitbagUI.
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:Hide()
    tinsert(UISpecialFrames, "KitbagRulesFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Kitbag — auto-swap rules")

    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
    -- Short of the frame's right edge, to leave the scroll bar its own room. An overlap would put
    -- the bar on top of every row's X, which reads as a dead button rather than as a layout bug.
    list:SetSize(476, MAX_ROWS * ROW_HEIGHT)

    rows = {}
    for i = 1, MAX_ROWS do rows[i] = createRow(list, i) end

    -- The same FauxScrollFrame the set list uses: the rows stay put and the rules move through them,
    -- so eight frames serve any number of rules. See the note in KitbagUI.
    scroll = CreateFrame("ScrollFrame", "KitbagRulesScrollFrame", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RulesUI.Refresh)
    end)

    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 2, -6)
    hint:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", -2, -6)
    hint:SetJustifyH("LEFT")

    -- The editor pane, below the list.
    local pane = CreateFrame("Frame", nil, frame)
    pane:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -28)
    pane:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)

    editor = { conditions = {} }

    local wear = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wear:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -6)
    wear:SetText("Wear")

    editor.setDrop = makeDropdown(pane, "Set", 140, setOptions)
    editor.setDrop:SetPoint("LEFT", wear, "RIGHT", -8, -2)

    local at = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    at:SetPoint("LEFT", editor.setDrop, "RIGHT", -6, 2)
    at:SetText("at priority")

    editor.priority = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    editor.priority:SetSize(40, 20)
    editor.priority:SetPoint("LEFT", at, "RIGHT", 10, 0)
    editor.priority:SetAutoFocus(false)
    editor.priority:SetNumeric(true)

    -- Conditions, two columns. The catalogue drives the layout, so a condition added to KitbagRules
    -- appears here without touching this file.
    local previous = { nil, nil }
    for i, condition in ipairs(Rules.CONDITIONS) do
        local column = (i - 1) % 2
        local label = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetWidth(70)
        label:SetJustifyH("RIGHT")
        if previous[column + 1] then
            label:SetPoint("TOPRIGHT", previous[column + 1], "BOTTOMRIGHT", 0, -8)
        else
            label:SetPoint("TOPLEFT", pane, "TOPLEFT", 4 + column * 248, -36)
        end
        label:SetText(condition.label)
        previous[column + 1] = label

        local widget
        if condition.kind == "text" then
            widget = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
            widget:SetSize(150, 20)
            widget:SetPoint("LEFT", label, "RIGHT", 10, 0)
            widget:SetAutoFocus(false)
        else
            widget = makeDropdown(pane, condition.key, 110,
                function() return conditionOptions(condition) end)
            widget:SetPoint("LEFT", label, "RIGHT", -8, -2)
        end
        editor.conditions[condition.key] = widget
    end

    -- A genuine two-state choice, unlike the conditions: a rule either puts your gear back or it
    -- does not, so a tick box is the honest widget here.
    editor.restore = CreateFrame("CheckButton", nil, pane, "UICheckButtonTemplate")
    editor.restore:SetSize(22, 22)
    editor.restore:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 4, 4)
    editor.restore.text = editor.restore:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    editor.restore.text:SetPoint("LEFT", editor.restore, "RIGHT", 2, 0)
    editor.restore.text:SetText("Put back what I was wearing when this stops applying")

    editor.save = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    editor.save:SetSize(110, 22)
    editor.save:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -4, 4)
    editor.save:SetText("Add rule")
    editor.save:SetScript("OnClick", commit)

    editor.clear = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    editor.clear:SetSize(90, 22)
    editor.clear:SetPoint("RIGHT", editor.save, "LEFT", -6, 0)
    editor.clear:SetText("New rule")
    editor.clear:SetScript("OnClick", function() edit(nil) end)

    edit(nil)
    return frame
end

--- Redraw. Rules are stored per character, so this reads Kitbag.char every time rather than caching.
function RulesUI.Refresh()
    if not frame or not frame:IsShown() then return end

    local list = rules()
    -- Which rule the current world state would actually pick. Marking it turns the list into the
    -- answer to "why am I wearing this" without anyone having to run /kit why.
    local report = Events.Explain()
    local names = labels()

    FauxScrollFrame_Update(scroll, #list, MAX_ROWS, ROW_HEIGHT)
    -- Clamped against the list as it is NOW: deleting rules while scrolled down leaves the bar
    -- reporting an offset the shortened list cannot support, and every row would index past the end
    -- and draw nothing. A blank rule list reads as "my rules are gone", not as "scrolled too far".
    local offset = Core.ScrollOffset(#list, MAX_ROWS, FauxScrollFrame_GetOffset(scroll))

    for i, row in ipairs(rows) do
        -- Every index below is the rule's own, not the row's: the marker, the [editing] tag and the
        -- ^ v X buttons all address the list, and off-by-an-offset here would move the wrong rule.
        local index = i + offset
        local rule = list[index]
        if rule then
            row.ruleIndex = index
            row.enabled:SetChecked(rule.enabled ~= false)
            local entry = report.considered[index]
            local marker = ""
            if entry and entry.matched and report.chosen == rule.set then
                marker = "|cff40ff40>|r "
            end
            local text = string.format("%swear |cffffd100%s|r %s%s |cff808080(%d)|r",
                marker, rule.set, Rules.Describe(rule, names),
                rule.restore and ", then put it back" or "", rule.priority or 0)
            if editor.index == index then text = "|cff8fd3ff[editing]|r " .. text end
            if rule.enabled == false then text = "|cff808080" .. text .. "|r" end
            row.text:SetText(text)
            row:Show()
        else
            row:Hide()
        end
    end

    if #list == 0 then
        hint:SetText("No rules yet. Pick a set below, choose when to wear it, and press Add rule.")
    else
        hint:SetText("Higher priority wins; ties go to the rule nearer the top. " ..
            "Click a rule to edit it, |cff40ff40>|r marks the one that applies now.")
    end
end

function RulesUI.Toggle()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        RulesUI.Refresh()
    end
end

Kitbag.RulesUI = RulesUI
return RulesUI
