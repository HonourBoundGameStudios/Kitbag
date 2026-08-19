-- KitbagOptions — the options panel (UI-9).
--
-- Every one of these settings already existed and worked; some of them could only be reached by
-- typing a slash command, and the rest could not be reached at all. That is the whole of this file's
-- purpose.
--
-- It is generated from KitbagDB.OPTIONS rather than laid out by hand, so a new option is added by
-- describing it next to its default — not by remembering to place a checkbox here, which is the step
-- that gets forgotten and leaves an option nobody can find.

Kitbag = Kitbag or {}

local DB = Kitbag.DB
local Sets = Kitbag.Sets

local Options = {}

local frame, checkboxes

-- Some options need something to happen the moment they change, not just to be stored. Keyed by
-- path so the generated checkbox stays generic.
local APPLY = {
    ["minimap.hide"] = function(value) Kitbag.Minimap.SetHidden(value) end,
    ["trinkets.hide"] = function(value) Kitbag.Trinkets.SetHidden(value) end,
}

local function onToggle(self)
    local option = self.option
    -- An inverted option's box is ticked when the stored flag is false ("Show the minimap button"
    -- against a stored `hide`), so the value has to be turned back over on the way in as well as out.
    -- Spelled out rather than `invert and not checked or checked`: that idiom collapses to `checked`
    -- whenever the inverted value is false, which is half the cases the inversion exists for.
    local value = self:GetChecked() and true or false
    if option.invert then value = not value end

    DB.Set(Kitbag.db, option.path, value)
    local apply = APPLY[option.path]
    if apply then apply(value) end
    Kitbag.Refresh()
end

local function build()
    frame = CreateFrame("Frame", "KitbagOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(420, 100 + #DB.OPTIONS * 34)
    frame:SetPoint("CENTER", UIParent, "CENTER", -60, 0)
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
    tinsert(UISpecialFrames, "KitbagOptionsFrame")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Kitbag — options")

    checkboxes = {}
    local previous = nil
    for i, option in ipairs(DB.OPTIONS) do
        local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        if previous then
            box:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -10)
        else
            box:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -36)
        end
        box.option = option

        box.label = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        box.label:SetPoint("LEFT", box, "RIGHT", 4, 0)
        box.label:SetText(option.label)

        if option.hint then
            box.hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            box.hint:SetPoint("TOPLEFT", box.label, "BOTTOMLEFT", 0, -1)
            box.hint:SetText(option.hint)
        end

        box:SetScript("OnClick", onToggle)
        checkboxes[i] = box
        previous = box
    end

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 16)
    note:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 16)
    note:SetJustifyH("LEFT")
    note:SetText("These apply to the whole account. Sets belong to each character.")

    return frame
end

--- Repaint every box from what is actually stored, so the panel can never disagree with the setting.
function Options.Refresh()
    if not frame or not frame:IsShown() then return end
    for _, box in ipairs(checkboxes) do
        local value = DB.Get(Kitbag.db, box.option.path) and true or false
        if box.option.invert then value = not value end
        box:SetChecked(value)
    end
end

function Options.Toggle()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        Options.Refresh()
    end
end

Kitbag.Options = Options
return Options
