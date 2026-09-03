-- KitbagOptions — the options panel (UI-9), which is the main window's Settings tab (UI-32).
--
-- Every one of these settings already existed and worked; some of them could only be reached by
-- typing a slash command, and the rest could not be reached at all. That is the whole of this file's
-- purpose.
--
-- It is generated from KitbagDB.OPTIONS rather than laid out by hand, so a new option is added by
-- describing it next to its default — not by remembering to place a checkbox here, which is the step
-- that gets forgotten and leaves an option nobody can find.
--
-- It had a WINDOW of its own until UI-32: a second movable frame, with its own title bar and its own
-- place in the strata stack, reachable only through a wrench whose picture had to be learned. It is
-- a page of the main window now. This file still owns every checkbox on it — what changed is where
-- they are drawn and who opens them, not what generates them.

Kitbag = Kitbag or {}

local DB = Kitbag.DB
local Sets = Kitbag.Sets

local Options = {}

-- The panel this file fills in — the main window's Settings page, handed over by KitbagUI at build
-- time. Held because it is also the answer to "has this been built yet": Refresh is called from
-- Kitbag.Refresh on every stored change, long before anybody opens the window.
local panel, checkboxes

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

--- Fill `parent` in with a checkbox per stored option. Called once, by KitbagUI, with the window's
--- Settings page.
---
--- It takes the panel rather than making one so that there is exactly one window in the addon: the
--- second frame this used to create is the thing UI-32 removed, and a function that can still build
--- one is a function that will, the next time somebody wants options "quickly" from somewhere else.
function Options.Attach(parent)
    if panel then return panel end
    if not parent then return nil end
    panel = parent

    local heading = panel:CreateFontString("KitbagSettingsTitle", "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -40)
    heading:SetText("Settings")

    checkboxes = {}
    local previous = nil
    for i, option in ipairs(DB.OPTIONS) do
        local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        box:SetSize(24, 24)
        if previous then
            box:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -10)
        else
            box:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -14)
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

    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 24, 18)
    note:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 18)
    note:SetJustifyH("LEFT")
    note:SetText("These apply to the whole account. Sets belong to each character.")

    Options.Refresh()
    return panel
end

--- Repaint every box from what is actually stored, so the panel can never disagree with the setting.
function Options.Refresh()
    if not panel or not checkboxes then return end
    for _, box in ipairs(checkboxes) do
        local value = DB.Get(Kitbag.db, box.option.path) and true or false
        if box.option.invert then value = not value end
        box:SetChecked(value)
    end
end

--- Open the window on this page, or close it if it is already the page showing.
---
--- Kept as the door with the name it always had, because three surfaces reach for it — `/kit
--- options`, the minimap's right-click and the broker's — and none of them should have had to change
--- when the panel stopped being a window of its own.
function Options.Toggle()
    Kitbag.UI.ToggleTab("settings")
end

Kitbag.Options = Options
return Options
