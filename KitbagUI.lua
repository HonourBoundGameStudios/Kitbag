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
-- Its neighbours own the rest: KitbagFlyout the per-slot menus on Blizzard's own character sheet,
-- KitbagIcons the icon picker.

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets
local Equip = Kitbag.Equip
local Core = Kitbag.Core
local Compat = Kitbag.Compat
local Skin = Kitbag.Skin

local UI = {}

local ROW_HEIGHT = 26
-- Twelve rather than thirteen: the action bar moved under the list (UI-28) and it had to be paid for
-- out of somewhere. The window's height is spent to the pixel between the list, the status line, the
-- import button and the name box, and this is the one of the four that can give a row up without
-- losing anything — the list scrolls, and a thirteenth set was never invisible, only one row further
-- down. Growing the window instead would have left a band of empty space under the paperdoll, which
-- is a worse trade for a row nobody on this account has ever reached.
local MAX_ROWS = 12

-- The two tools on the action row (UI-23). Both are Blizzard art that has shipped in every flavour
-- since 1.0 rather than an expansion's icon, and both are chosen for what they mean at 24 pixels:
-- the loot-pass X is the game's own "no" and reads as destructive without being a skull, and the
-- group-looking icon is people, which is what a copy TO ANOTHER CHARACTER is about.
--
-- A path that turns out not to exist does not draw nothing — it renders as missing-texture magenta,
-- which is about as loud as a UI fault gets. That is the useful property, and it is the same reason
-- SLOT_ART below is written as paths rather than guarded.
-- Equip is the addon's own icon, the one in every `.toc`'s `## IconTexture` (UI-26). It is the
-- picture a player already associates with Kitbag by the time they reach this button, and "put
-- armour on" is the thing it depicts — which is a better answer than a generic tick, because a tick
-- means "confirm" and this button does not confirm anything.
local EQUIP_ICON = "Interface\\Icons\\INV_Chest_Plate06"

local DELETE_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
-- Rename (UI-29). The guild frame's public-note glyph: Blizzard's own "edit the words attached
-- to this" picture, which is exactly the act, and UI art rather than an expansion icon for the
-- reason the two above are. "Rename" has no universal symbol — a pencil would be inventing one —
-- so the tooltip carries the word and the picture only has to not mean something else.
local RENAME_ICON = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up"
local COPY_ICON = "Interface\\Icons\\INV_Misc_GroupLooking"

-- The two acts on the bottom row (UI-27). A parchment for writing down what you have on, and
-- Blizzard's own plus glyph — the one in the quest log and the tradeskill list — for making an empty
-- one. The plus is the only genuinely universal symbol in this whole set and it is spent on the
-- control that most needed it, since "New set" and "Save" are otherwise the pair a player is likeliest
-- to confuse.
local SAVE_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local NEW_ICON = "Interface\\Buttons\\UI-PlusButton-Up"

-- The door on the bottom row (UI-24): the engineering wrench for settings, which is the closest
-- thing this client has to a cog.
local OPTIONS_ICON = "Interface\\Icons\\Trade_Engineering"

local CELL = 34            -- a doll cell, big enough to read an icon at a glance
local CELL_GAP = 3
local PITCH = CELL + CELL_GAP
local PANEL_WIDTH = 300
local PARENT_Y = -70       -- the inherit button, between the set's headline and the character model
local KEY_WIDTH = 82       -- the keybinding button, sharing that row rather than taking one of its own

local frame, rows, status, scroll, doll, importButton, renameBox
local selected = nil       -- the set the inspector is showing

-- The set the rename box was OPENED on, or nil. Held rather than re-read from `selected` when Enter
-- is pressed, for Delete's reason (BUG-8): the list underneath stays live while the box is up, and a
-- row clicked in between must not change which set moves. A rename is not unrecoverable the way a
-- delete is, but renaming the wrong set is discovered exactly as late.
local renaming = nil

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
-- flavour does NOT draw nothing — it renders as missing-texture magenta, which is about as loud as
-- a UI fault gets. That is the useful property: a wrong path here cannot break the window and cannot
-- hide either, so it is caught the first time the window is opened rather than shipping unnoticed.
local SLOT_ART = {
    HEAD = "Head", NECK = "Neck", SHOULDER = "Shoulder", SHIRT = "Shirt", CHEST = "Chest",
    WAIST = "Waist", LEGS = "Legs", FEET = "Feet", WRIST = "Wrists", HANDS = "Hands",
    FINGER1 = "Finger", FINGER2 = "Finger", TRINKET1 = "Trinket", TRINKET2 = "Trinket",
    BACK = "Chest", MAINHAND = "MainHand", OFFHAND = "SecondaryHand", RANGED = "Ranged",
    TABARD = "Tabard",
}

-- The three lines the window uses to say how ready a set is, each keyed on the ONE verdict in
-- `Core.Readiness`. The precedence lives there — most sharply that a blank set is asked about before
-- "already worn", since both have nothing to do and only one of them is green (UI-16). What stays
-- here is the phrasing, which is deliberately different in each: a row column has room for a word, a
-- tooltip for a sentence, and the note under the doll for a sentence that says what to do next.
--
-- Module functions rather than file-locals so they can be exercised outside the game: the wording is
-- the whole of what these are, and a wrong word here is not a broken window — it is a confident
-- sentence about the wrong thing, which is exactly the failure nobody reports.

--- The readiness column on a set's row.
function UI.RowText(plan)
    local verdict = Core.Readiness(plan)
    local state, count = verdict.state, verdict.count

    if state == "unknown" then return "|cff808080—|r" end
    if state == "blank"   then return "|cff808080empty|r" end
    if state == "worn"    then return "|cff40ff40worn|r" end
    if state == "bags"    then return "|cffff8080bags full|r" end
    if state == "bank"    then return string.format("|cffffd100%d at bank|r", count) end
    if state == "missing" then return string.format("|cffff8080%d missing|r", count) end
    return string.format("|cffffd100%d swap%s|r", count, count == 1 and "" or "s")
end

--- The line the row tooltip falls back to when the plan has no moves to list.
---
--- Only ever reached when `Core.Explain` produced nothing, which is the case for all three no-op
--- states at once — and they are three different answers.
function UI.TooltipNote(plan)
    local state = Core.Readiness(plan).state
    if state == "blank" then return "Empty — nothing in it yet.", 0.6, 0.6, 0.6 end
    if state == "worn"  then return "Already worn.", 0.4, 1, 0.4 end
    return "Nothing to do.", 0.4, 1, 0.4
end

--- One line under the inspector's doll for what stands between you and wearing this.
function UI.InspectorNote(plan)
    local verdict = Core.Readiness(plan)
    local state, count = verdict.state, verdict.count

    if state == "unknown" then return "" end
    if state == "blank"   then return "|cff808080Empty — click a slot to say what goes there.|r" end
    if state == "worn"    then return "|cff40ff40You are wearing this.|r" end
    if state == "bags" then
        return string.format("|cffff5050Bags full — needs %d free slot(s).|r", count)
    end
    if state == "bank" or state == "missing" then
        return string.format("|cffff8080%d piece%s not to hand.|r", count, count == 1 and "" or "s")
    end
    return string.format("%d swap%s to go.", count, count == 1 and "" or "s")
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

    local inherits = Sets.ParentOf(name)
    if inherits then
        GameTooltip:AddLine("inherits from " .. inherits, 0.6, 0.6, 0.6)
    end
    if totals and totals.level then
        GameTooltip:AddLine(string.format("%d items, average item level %s%d",
            totals.items, totals.complete and "" or "about ", math.floor(totals.level + 0.5)),
            0.6, 0.6, 0.6)
    end

    local lines = Core.Explain(plan)
    if #lines == 0 then
        GameTooltip:AddLine(UI.TooltipNote(plan))
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

--- Show `name` in the inspector. The one path by which anything CHOOSES a set.
---
--- Equip and Delete read `selected` rather than a set named on the row they sit in (UI-13 moved them
--- out of the rows), so "which set is selected" decides what a destructive button destroys. That
--- makes a second place that chooses a set a real hazard rather than a tidiness question, and it is
--- why the row click, a freshly created set and `/kit verify` all come through here.
---
--- `UI.Refresh` also assigns `selected`, and deliberately does not come through here: it is repairing
--- a selection whose set has been deleted or renamed, not choosing one, and routing a repair through
--- a function that refreshes would recurse.
function UI.Select(name)
    if not name then return end
    selected = name
    -- The picker is bound to one slot of one set. Leaving it open over a different set would offer
    -- a click that edits the set you just navigated away from.
    Kitbag.Picker.Close()
    UI.Refresh()
end

--- Which set the inspector is showing, or nil. Exposed so the addon can check itself (VERIFY-8):
--- from outside, a file-local selection is indistinguishable from the buttons reading a stale one.
function UI.Selected()
    return selected
end

local function onRowClick(self)
    if not self.setName then return end
    UI.Select(self.setName)
end

local function createRow(parent, index)
    -- Named, so a check can measure them. Thirteen rows serve any number of sets, so a row is only
    -- meaningful together with the `setName` it is currently showing — and the pair is what the
    -- Equip and Delete buttons ultimately act through, which is the one unrecoverable act in the
    -- addon pointed at a variable (VERIFY-8). A handle is what lets that be driven in a test.
    local row = CreateFrame("Button", "KitbagSetRow" .. index, parent)
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
        GameTooltip:SetHyperlink(Core.ItemLink(cell.key))
        GameTooltip:AddLine(" ")
    else
        GameTooltip:AddLine(cell.slot.label, 1, 0.82, 0)
    end

    local state = STATE[cell.state] or STATE.unset
    GameTooltip:AddLine(string.format("%s — %s", cell.slot.label, state.text),
        state[1], state[2], state[3])

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to choose what this set puts here.", 0.5, 0.5, 0.5)
    if cell.state ~= "unset" then
        GameTooltip:AddLine("Shift-click to drop the slot from the set.", 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end

local function onCellLeave()
    GameTooltip:Hide()
end

-- Click a slot to say what the set should put in it (UI-14).
--
-- Shift-click is the shortcut for the one choice worth reaching in a single gesture: dropping the
-- slot out of the set entirely, so it keeps whatever you happen to be wearing. It is also the only
-- destructive one, which is why it is behind a modifier — and why an untouched slot does not offer
-- it, since there is nothing there to drop.
local function onCellClick(self)
    local cell = self.data.cell
    if not selected or not cell then return end

    if IsShiftKeyDown() then
        if cell.state ~= "unset" then Sets.SetSlot(selected, cell.slot.id, nil) end
        return
    end
    Kitbag.Picker.Open(selected, cell.slot.id, self)
end

local function createCell(parent, x, y)
    -- A Button rather than a Frame: the cells were read-only when the inspector was built (UI-13)
    -- and this is the pass that makes them the way a set is edited.
    local cell = CreateFrame("Button", nil, parent)
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

    -- Something clickable has to look clickable. The highlight is the only affordance a bare cell
    -- has, and without it the doll reads as a picture of the set rather than as the way to edit it.
    cell:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    cell:SetScript("OnEnter", onCellEnter)
    cell:SetScript("OnLeave", onCellLeave)
    cell:SetScript("OnClick", onCellClick)
    return cell
end

-- Light a model frame.
--
-- `SetLight` is one of the few WoW API calls whose *signature* changed rather than its name: modern
-- clients take (enabled, lightTable), older ones take thirteen positional numbers. Getting it wrong
-- is not a visible error — it is an invisible model — so both are tried and the first that does not
-- throw wins. The table form goes first because every flavour Kitbag targets is built on the modern
-- code base; the positional form is the belt-and-braces.
local function lightModel(model)
    if not model.SetLight then return end

    local ok = pcall(model.SetLight, model, true, {
        omnidirectional  = false,
        point            = CreateVector3D and CreateVector3D(0, 0, 0) or nil,
        ambientIntensity = 1.0,
        ambientColor     = CreateColor and CreateColor(1, 1, 1) or nil,
        diffuseIntensity = 1.0,
        diffuseColor     = CreateColor and CreateColor(1, 1, 1) or nil,
    })
    if not ok then
        pcall(model.SetLight, model, true, false, 0, 0, -1, 1.0, 1, 1, 1, 1.0, 1, 1, 1)
    end
end

-- Which set this one is a delta on (UI-11).
--
-- Inheritance has existed since CORE-3, but `/kit inherit Raid Fire from Raid` was the only way to
-- declare it and the row tooltip the only place it showed — so the feature was invisible to anyone
-- who had not read the slash-command help. It belongs in the inspector because that is where the
-- consequence is visible: the pieces coming from the parent are already drawn in the doll.
--
-- The list comes from Core.ParentChoices, so the menu never offers a set that Sets.Inherit would then
-- refuse. A menu that has to apologise after the click is worse than a shorter menu.
local function initParentMenu(self, level)
    if not selected then return end

    local current = Sets.ParentOf(selected)

    local info = UIDropDownMenu_CreateInfo()
    info.text = "Inherit from"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Nothing"
    info.checked = current == nil
    info.func = function()
        -- Only when it would change something: Sets.Inherit(name, nil) on a set that inherits from
        -- nothing prints a correction, and picking the option already ticked should be silent.
        if current then Sets.Inherit(selected, nil) end
        CloseDropDownMenus()
    end
    UIDropDownMenu_AddButton(info, level)

    for _, name in ipairs(Sets.ParentChoices(selected)) do
        info = UIDropDownMenu_CreateInfo()
        info.text = name
        info.checked = current == name
        info.func = function()
            if current ~= name then Sets.Inherit(selected, name) end
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function onParentEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Inheritance", 1, 0.82, 0)
    GameTooltip:AddLine("A set with a parent stores only what differs from it, so a shared piece " ..
        "lives in one place and re-enchanting it updates every set that wears it.", 1, 1, 1, true)
    GameTooltip:AddLine("A slot this set does not name is taken from its parent.", 0.6, 0.6, 0.6,
        true)
    GameTooltip:Show()
end

-- Send this set to another character (UI-20).
--
-- CORE-7 shipped the whole mechanism and `/kit copy Tank to Alt - Realm` was the only door to it,
-- which is UI-11's problem again: a feature nobody finds is a feature nobody has. The menu is built
-- from Sets.CopyChoices for the same reason the inherit menu comes from Core.ParentChoices — the
-- window must not form its own opinion of who can be copied to and then be corrected by Sets.
--
-- The clash is the part a menu has to do that the command does not. `CopyTo` refuses a name the
-- target already uses and says so in chat, which is right for something typed and wrong for
-- something clicked: the player picks a character and is told no afterwards. Here they are greyed,
-- with the reason on the entry, so the refusal never arrives.
local function initCopyMenu(self, level)
    if not selected then return end

    -- The name the menu is ABOUT, captured rather than re-read on click. The list on the left stays
    -- live while a menu is up, so a row clicked in between would otherwise send a different set than
    -- the one the menu is headed with — the same reason the delete popup carries its name as `data`
    -- (BUG-8). A copy is not unrecoverable the way a delete is, but "I copied the wrong set" is
    -- discovered on another character, days later.
    local name = selected

    local info = UIDropDownMenu_CreateInfo()
    info.text = "Copy " .. name .. " to"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    for _, choice in ipairs(Sets.CopyChoices(name)) do
        info = UIDropDownMenu_CreateInfo()
        -- The reason rides on the entry rather than only in a tooltip: a greyed line with no
        -- explanation is the puzzle UI-11 was written about, and this one is easily mistaken for
        -- "that character cannot take sets at all".
        info.text = choice.taken
            and (choice.key .. " |cff808080(has a set called " .. name .. ")|r")
            or choice.key
        info.notCheckable = true
        info.disabled = choice.taken
        info.func = function()
            Sets.CopyTo(name, choice.key)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function onCopyEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Copy to another character", 1, 0.82, 0)
    GameTooltip:AddLine("The set is written into that character's own list. They keep it after " ..
        "you log out — nothing of theirs is touched, and nothing here changes.", 1, 1, 1, true)
    -- Said before the copy rather than discovered after it: the alt has no parent set to inherit
    -- from, so what travels is the whole outfit. Re-saving it over there will not behave the way
    -- re-saving this one does.
    GameTooltip:AddLine("The copy arrives flat: a set that inherits here is one whole outfit " ..
        "there.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- The keybinding button (UI-12)
-- ---------------------------------------------------------------------------
--
-- `Bindings.Set` and `Bindings.Apply` have existed since COMPAT-5 and the ItemRack import has been
-- filling `set.key` all along; there was simply no way to assign one without importing. This is the
-- door.
--
-- Capturing is a mode rather than a dialog: the button says what it is waiting for, and the next
-- keystroke either becomes the binding or leaves the mode. A dialog would need its own frame, its
-- own escape handling and its own answer to "what if the window closes while it is up", all to ask
-- a question that fits on the button already there.

--- True while the button is swallowing keystrokes. File-local rather than on the frame so the
--- refresh path can see it without reaching through a widget that may not exist yet.
local capturing = false
local pendingBinding = nil
local pendingRefusal = nil

local function keyLabel()
    if pendingRefusal then
        return Core.BindingRefusalLabel(pendingRefusal.key, pendingRefusal)
    end
    local current = selected and Sets.KeyOf(selected) or nil
    local impact
    if pendingBinding and selected then
        impact = Core.BindingImpact(Kitbag.char.sets, selected, pendingBinding)
    end
    return Core.BindingLabel(current, pendingBinding, impact)
end

local function stopCapture(button)
    capturing = false
    pendingBinding = nil
    pendingRefusal = nil
    button:EnableKeyboard(false)
    -- Restored, not merely turned off. While capturing, this frame is the only thing in the game
    -- receiving keys — including the ones that open the menu and the ones that close this window —
    -- so leaving it clamped would be indistinguishable from the client having locked up.
    pcall(button.SetPropagateKeyboardInput, button, true)
    UI.Refresh()
end

local function onKeyCaptured(button, key)
    -- Escape always cancels, whether there is a proposal already or the player has only just
    -- entered capture. It reaches here rather than closing the window because propagation is off.
    if key == "ESCAPE" then
        stopCapture(button)
        return
    end

    -- Enter is deliberately handled before BindingKey: once a chord is proposed it is the second
    -- act that changes stored state, rather than another chord that silently replaces the proposal.
    if key == "ENTER" and pendingBinding then
        if selected then Kitbag.Bindings.Set(selected, pendingBinding) end
        stopCapture(button)
        return
    end

    -- Core owns which raw keystrokes can form chords; Compat then asks the client whether the
    -- completed chord already belongs to the player. A capture that cannot prove the key is free
    -- must not take it — the button names the action rather than silently appearing to ignore it.
    local binding, why = Core.BindingKey(key, IsShiftKeyDown(), IsControlKeyDown(), IsAltKeyDown())
    if not binding then
        pendingBinding = nil
        pendingRefusal = { why = why, key = key }
        button:SetText(keyLabel())
        return
    end

    local candidate = Core.BindingCandidate(binding, Compat.BindingAction(binding))
    if not candidate.ok then
        pendingBinding = nil
        pendingRefusal = candidate
        button:SetText(keyLabel())
        return
    end

    -- The press is only a proposal. Replacing it costs nothing; only Enter reaches Bindings.Set.
    pendingBinding = binding
    pendingRefusal = nil
    button:SetText(keyLabel())
end

local function onKeyEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Keybinding", 1, 0.82, 0)
    if capturing then
        GameTooltip:AddLine(pendingBinding
            and "Press Enter to keep this key, or Escape to cancel."
            or (pendingRefusal and "Choose an unbound key. Escape cancels."
                or "Press the key you want. Escape cancels."), 1, 1, 1, true)
    else
        GameTooltip:AddLine("Click, then press a key to bind this set. " ..
            "Right-click to clear it.", 1, 1, 1, true)
    end
    -- Both halves of the promise, because both surprise people. A key another set holds is taken
    -- from it — the alternative is a binding that silently loses an arbitration it never mentioned
    -- — and none of this is written into the player's own bindings, so uninstalling Kitbag gives
    -- every key back rather than leaving a set of dead ones behind.
    GameTooltip:AddLine("A key another set already uses is taken from it.", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Kitbag re-applies these each login and never writes them into your " ..
        "saved bindings.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function buildKeyButton(panel, gapWidth)
    panel.key = CreateFrame("Button", "KitbagKeyButton", panel, "UIPanelButtonTemplate")
    panel.key:SetSize(KEY_WIDTH, 20)
    panel.key:SetPoint("TOPRIGHT", panel, "TOP", gapWidth / 2, PARENT_Y)
    panel.key:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    panel.key:SetScript("OnClick", function(self, button)
        if not selected then return end
        if capturing then
            stopCapture(self)
            return
        end
        -- No redraw here: Bindings.Set changes stored state and goes through Kitbag.Refresh itself,
        -- which is what repaints the set that lost the key as well as the one that gained it.
        if button == "RightButton" then
            Kitbag.Bindings.Set(selected, nil)
            return
        end

        capturing = true
        pendingBinding = nil
        pendingRefusal = nil
        self:SetText("Press…")
        self:EnableKeyboard(true)
        -- Without this the keystroke reaches the game as well as this button, so binding "B" would
        -- also open the bags and binding Escape would close the window out from under the mode.
        -- Feature-detected: it is not on every flavour, and CreateFrame gives no warning for a
        -- method that is simply absent.
        pcall(self.SetPropagateKeyboardInput, self, false)
    end)

    panel.key:SetScript("OnKeyDown", onKeyCaptured)
    panel.key:SetScript("OnEnter", onKeyEnter)
    panel.key:SetScript("OnLeave", onCellLeave)
    -- Nothing should be able to leave the game deaf. If the window goes away mid-capture — Escape
    -- on a different frame, /reload, the close button — the mode has to end with it.
    panel.key:SetScript("OnHide", function(self)
        if capturing then stopCapture(self) end
    end)
end

local function buildDoll(parent)
    -- Named, like every other region the addon draws (UI-22): a panel nobody can name is a panel no
    -- check and no test can ask about. It went unnamed while the copy button stood in for it — a
    -- check reached the panel through `KitbagCopyButton:GetParent()` — and UI-28 moved that button
    -- into a row of its own, which is exactly how a stand-in stops standing for the thing.
    local panel = CreateFrame("Frame", "KitbagInspector", parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 344, -34)
    panel:SetSize(PANEL_WIDTH, 392)

    -- Named, unlike the panel's other strings, because it is the one piece of the inspector that says
    -- WHICH set is being shown — so it is the evidence that the doll followed the selection rather
    -- than merely that both exist (VERIFY-8).
    panel.title = panel:CreateFontString("KitbagInspectorTitle", "OVERLAY", "GameFontNormalLarge")
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

    -- The parent, and the way to change it (UI-11). Anchored to the panel at a fixed height rather
    -- than under the note, because the note is one line or two depending on what the plan says and a
    -- control that moves is a control you have to look for.
    --
    -- "MENU" is what makes UIDropDownMenuTemplate act as a bare pop-up menu: Blizzard's own
    -- initialiser hides the template's dropdown art in that mode, so the frame is only a host for the
    -- list and nothing of it is drawn in the panel.
    local menu = CreateFrame("Frame", "KitbagParentMenu", panel, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(menu, initParentMenu, "MENU")

    -- The inherit button gives up the right end of its row to the keybinding button (UI-12) rather
    -- than the panel growing a row: the gap between the doll's two columns is the only real space
    -- the window has, and everything below this line is the character model. Both are named so
    -- `/kit verify` can measure the clearance between them — a measurement needs both edges, and
    -- this one varies, because the left button's label is a set name.
    panel.inherit = CreateFrame("Button", "KitbagInheritButton", panel, "UIPanelButtonTemplate")
    panel.inherit:SetSize(gapWidth - KEY_WIDTH - 4, 20)
    panel.inherit:SetPoint("TOPLEFT", panel, "TOP", -gapWidth / 2, PARENT_Y)
    panel.inherit:SetScript("OnClick", function(self)
        ToggleDropDownMenu(1, nil, menu, self, 0, 0)
    end)
    panel.inherit:SetScript("OnEnter", onParentEnter)
    panel.inherit:SetScript("OnLeave", onCellLeave)

    -- A set name is as long as the player made it. With a width and no wrapping the client truncates
    -- it for us; without them a long name runs out over the doll's icons on both sides.
    local label = panel.inherit:GetFontString()
    if label then
        label:SetWidth(gapWidth - KEY_WIDTH - 16)
        pcall(label.SetWordWrap, label, false)
    end

    buildKeyButton(panel, gapWidth)

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
    local modelTop = PARENT_Y - 26

    -- The well the preview sits in. Every other thing this panel draws sits in something — each of
    -- the nineteen cells has a tinted edge over a dark ground — and the model had neither, so the one
    -- region of the paperdoll that is not made of squares read as a hole between two columns of them.
    -- Recessed by the shared skin, which is the same recess every doll cell around it has and the
    -- same one the set list opposite has — the region is a panel, and it now says so in the words
    -- the rest of the window uses.
    --
    -- It is the model's PARENT rather than a plate behind it. A decorative sibling looks the same in
    -- a screenshot and behaves differently in every way that matters — it would not hide with the
    -- model and would draw over or under it depending on creation order.
    local well = Skin.Inset(CreateFrame("Frame", "KitbagPreviewFrame", panel))
    well:SetSize(gapWidth, modelTop - weaponsY - 8)
    well:SetPoint("TOP", panel, "TOP", 0, modelTop)

    panel.well = well

    -- Named, unlike every other frame here: a model that renders nothing looks identical to a model
    -- that was never created, and a name is the only way to tell the two apart from a `/run` line.
    local ok, model = pcall(CreateFrame, "DressUpModel", "KitbagPreviewModel", well)
    if ok and model and model.TryOn then
        model:SetPoint("TOPLEFT", well, "TOPLEFT", 1, -1)
        model:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -1, 1)
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
        -- A model frame built in Lua has no lighting and no camera of its own — the dressing room
        -- gets both from XML this addon does not have — and an unlit model draws as nothing at all
        -- against a dark panel. Re-applied on every show because a model can also come back blank
        -- after the frame has been hidden.
        model:SetScript("OnShow", function(self)
            lightModel(self)
            -- Clearing the signature is enough to force a redress: OnShow fires from inside
            -- refreshDoll, before the pass reaches dressModel.
            self.dressed = nil
        end)
        panel.model = model
    else
        -- A bordered box with nothing in it is worse than no box: on a flavour without DressUpModel
        -- the well would read as a preview that failed rather than as a panel that never offered one.
        well:Hide()
    end

    panel.cells = cells
    return panel
end

-- ---------------------------------------------------------------------------
-- Renaming a set in place (UI-29)
-- ---------------------------------------------------------------------------
--
-- An edit box over the row rather than a popup with an OK button, because the clash is the whole of
-- the risk here. `Sets.Rename` refuses a name another set already holds, but a refusal that arrives
-- in chat AFTER the press is a control that appeared to work — the same failure BUG-8 fixed for
-- Delete from the other direction. `Core.RenameLabel` answers on every keystroke, so "that name is
-- taken" is on screen while the name is still being typed.
--
-- The box is one widget moved onto whichever row is being renamed, for the reason there are twelve
-- rows and not one per set: a per-row control would cost a column the 316-wide list does not have,
-- and a control that only exists while it is being used costs none.

--- Close the box without redrawing. The half that is safe to call from inside `UI.Refresh`.
local function closeRenameBox()
    if not renaming then return end
    -- Cleared first: ClearFocus fires OnEditFocusLost, which comes back through here.
    renaming = nil
    renameBox:ClearFocus()
    renameBox:Hide()
end

--- Close the box and put the window back the way it was.
local function stopRename()
    if not renaming then return end
    closeRenameBox()
    UI.Refresh()
end

--- What the box currently proposes, and the line that says so. Returns the impact so the commit and
--- the line cannot form two opinions of whether the name is allowed.
local function renameProposal()
    if not renaming then return nil end
    local impact = Core.RenameImpact(Kitbag.char.sets, Kitbag.char.rules, renaming,
        renameBox:GetText())
    status:SetText(Core.RenameLabel(renaming, impact))
    return impact
end

--- Open the box on `name`.
--
-- Brings the set into view first. Selection does not only come from clicking a row — `/kit verify`
-- and a freshly created set both go through `UI.Select` — so the set being renamed can be scrolled
-- out of sight, and a box anchored to a row that is not drawing it would open over another set
-- entirely. Scrolling is the honest answer: refusing would make the control unreliable for reasons
-- the player cannot see.
local function startRename(name)
    if not name or not Kitbag.char.sets[name] then return end

    local names = Sets.Names()
    local index
    for i, candidate in ipairs(names) do
        if candidate == name then index = i break end
    end
    if not index then return end

    local offset = Core.ScrollOffset(#names, MAX_ROWS, FauxScrollFrame_GetOffset(scroll))
    if index <= offset or index > offset + MAX_ROWS then
        FauxScrollFrame_SetOffset(scroll, Core.ScrollOffset(#names, MAX_ROWS, index - 1))
    end

    -- Both set before the redraw. The refresh blanks the row's name so the box is not typed over a
    -- FontString still showing the old one, and it also re-asks for the line under the list — which
    -- would otherwise be answered about whatever the box still held from the last rename.
    renaming = name
    renameBox:SetText(name)
    UI.Refresh()

    local target
    for _, row in ipairs(rows) do
        if row.setName == name then target = row end
    end
    if not target then
        closeRenameBox()
        return
    end

    -- Over the name column only. The readiness and item level beside it stay readable, which is
    -- worth keeping: renaming a set is one of the moments you are looking at the list to tell two
    -- of them apart.
    renameBox:ClearAllPoints()
    renameBox:SetPoint("LEFT", target.icon, "RIGHT", 2, 0)
    renameBox:SetSize(130, ROW_HEIGHT - 6)
    renameBox:Show()
    renameBox:SetFocus()
    -- Selected, so the commonest rename — a different name entirely — is one gesture rather than a
    -- press, a select-all and then the typing.
    renameBox:HighlightText()
end

--- The action bar: one action and two tools (UI-23), all three drawn rather than spelled (UI-26).
---
--- It belongs to the SET LIST and hangs under it (UI-28). It used to sit in the bottom corner of the
--- inspector, and once all three became icons the row was 90 wide inside a 300-wide panel — a huddle
--- of small squares in the corner of a big panel, a whole column away from the list of sets it acts
--- on. Under the list it reads as that list's action bar, which is what it is.
---
--- The three are children of a row frame rather than three controls anchored individually, and that
--- is what makes "centred" structural rather than arithmetic: the row is anchored TOP-to-BOTTOM at an
--- x offset of zero, so it re-centres itself if the list changes width or any button changes size.
--- A hand-computed offset is the version that goes quietly wrong the day one of those moves.
---
--- The handles stay on the inspector `panel`, because that is what the refresh draws through — Equip
--- greys while you are dead and Copy hides with nobody to copy to. They are on the row as well, for
--- `/kit verify`: a check reaching a control through `GetParent()` finds the row now.
local function buildActionRow(parent, anchor, panel)
    -- Equip is DELIBERATELY the odd one out at 34 against the tools' 24. It is the only control here
    -- anybody presses twice, and an icon-only row of three identical squares would say the three are
    -- peers — which is precisely the thing UI-23 changed the row to stop saying. With no labels left
    -- to carry the hierarchy, size is the only thing that can.
    local narrow = 24
    local wide = 34
    -- Derived rather than typed, so a fourth tool (UI-29) widens the row instead of pushing the last
    -- one off a row that stayed the width three needed.
    local tools = 3
    local rowWidth = wide + tools * (4 + narrow)

    local row = CreateFrame("Frame", "KitbagActionRow", parent)
    row:SetSize(rowWidth, wide)
    row:SetPoint("TOP", anchor, "BOTTOM", 0, -8)

    -- Unnamed, like Delete beside it: `/kit verify` reaches both through the row that owns them, and
    -- a global exists forever. Copy has one only because it appears on some accounts and not others,
    -- which is a question a check has to be able to ask by name.
    panel.equip = Skin.IconButton(row, nil, EQUIP_ICON, wide)
    panel.equip:SetPoint("LEFT", row, "LEFT", 0, 0)
    panel.equip:SetScript("OnClick", function() if selected then Sets.Equip(selected) end end)

    -- A permanently greyed control with no explanation is a puzzle rather than an affordance
    -- (UI-11), and greying Equip without saying why would trade one bad experience for another. The
    -- sentence comes from Core.SWAP_BLOCKED so this frame, the trinket bar and the flyouts cannot
    -- word the same refusal three different ways.
    panel.equip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- Named rather than "the selected set" now that the button has no words of its own: this is
        -- the last thing read before the one control here that moves gear, and "Equip" was never the
        -- part in doubt — WHICH set was.
        GameTooltip:AddLine(selected and ("Wear " .. selected) or "Wear the selected set", 1, 0.82, 0)
        if panel.blocked then
            GameTooltip:AddLine(Core.SWAP_BLOCKED[panel.blocked], 1, 0.5, 0.5, true)
        elseif Equip.IsRunning() then
            GameTooltip:AddLine("A swap is already running.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    panel.equip:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Named, unlike Delete beside it, for Copy's reason: this control opens a box that only exists
    -- while it is in use, so a check cannot reach it through anything it leaves behind.
    --
    -- Between Equip and Delete rather than on the end, and the position is structural: Copy HIDES on
    -- an account with one character, so anything anchored to it would move on some accounts and not
    -- others. It also puts a pixel of distance between the biggest button and the destructive one.
    panel.rename = Skin.IconButton(row, "KitbagRenameButton", RENAME_ICON, narrow)
    panel.rename:SetPoint("LEFT", panel.equip, "RIGHT", 4, 0)
    panel.rename:SetScript("OnClick", function()
        if renaming then
            stopRename()
            return
        end
        startRename(selected)
    end)
    panel.rename:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(selected and ("Rename " .. selected) or "Rename the selected set",
            1, 0.82, 0)
        GameTooltip:AddLine("Everything that points at the set comes with it — its keybinding, " ..
            "any set that inherits from it, and the selection.", 0.9, 0.9, 0.9, true)
        -- The one consequence a rename cannot carry, said before the press rather than after it: a
        -- macro the player dragged onto an action bar names the set in its body, and that lives in
        -- the client's own data rather than in Kitbag's.
        GameTooltip:AddLine("A macro you dragged to an action bar still names the old set — drag " ..
            "it again.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    panel.rename:SetScript("OnLeave", function() GameTooltip:Hide() end)

    panel.delete = Skin.IconButton(row, nil, DELETE_ICON, narrow)
    panel.delete:SetPoint("LEFT", panel.rename, "RIGHT", 4, 0)
    -- Deleting asks first, in a popup, rather than demanding a modifier nobody can see (BUG-8). The
    -- guard itself was right — this is the only unrecoverable thing the window does — but it lived
    -- entirely in a chat line printed AFTER a click that appeared to do nothing, so the button read
    -- as broken. Shift-click still skips the prompt, for anyone clearing out several at once.
    panel.delete:SetScript("OnClick", function()
        if not selected then return end
        if IsShiftKeyDown() then
            Sets.Delete(selected)
            return
        end
        -- The name goes through as `data` for the same reason the overwrite popup does it: the list
        -- underneath stays live while the question is up, and the answer must apply to the set the
        -- question NAMED.
        StaticPopup_Show("KITBAG_DELETE", selected,
            Sets.DeleteWarning(selected), selected)
    end)

    panel.delete:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Delete the selected set")
        GameTooltip:AddLine("Asks first. Shift-click to skip the question.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    panel.delete:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Copy to another character (UI-20). Named, as the inherit and key buttons are, so `/kit verify`
    -- can measure it: this button appears only on an account with more than one character, so on a
    -- single-character account nobody ever looks at this end of the row.
    local copyMenu = CreateFrame("Frame", "KitbagCopyMenu", row, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(copyMenu, initCopyMenu, "MENU")

    panel.copy = Skin.IconButton(row, "KitbagCopyButton", COPY_ICON, narrow)
    panel.copy:SetPoint("LEFT", panel.delete, "RIGHT", 4, 0)
    panel.copy:SetScript("OnClick", function(self)
        ToggleDropDownMenu(1, nil, copyMenu, self, 0, 0)
    end)
    panel.copy:SetScript("OnEnter", onCopyEnter)
    panel.copy:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- The same three, on the row itself. `/kit verify` reaches a control's neighbours through
    -- `GetParent()` rather than through globals of their own, and the parent is the row now.
    row.equip, row.delete, row.copy = panel.equip, panel.delete, panel.copy
    row.rename = panel.rename
    return row
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
    lightModel(model)
    pcall(model.SetPosition, model, 0, 0, 0)
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

    -- Copy appears only when there is somebody to copy TO (UI-20), the same rule the inherit button
    -- follows: on a one-character account the menu would be empty, and an empty menu is a worse
    -- answer than no button. Unlike Equip it stays live while dead — copying moves no gear (UI-19).
    if shown and #Sets.CopyChoices(name) > 0 then doll.copy:Show() else doll.copy:Hide() end

    -- Unlike the inherit button beside it, this one shows even with nothing bound: "no keybinding"
    -- is a state the player wants to be able to see and act on, where "nothing to inherit from" is
    -- a fact about the list that no click could change (UI-11). Left alone while capturing, so a
    -- refresh landing mid-mode does not wipe the prompt off the button the player is looking at.
    if shown then doll.key:Show() else doll.key:Hide() end
    if shown and not capturing then
        doll.key:SetText(Core.BindingLabel(Sets.KeyOf(name)))
    end

    -- The inherit button appears only when it can do something: with one set saved there is nothing
    -- to inherit from, and a permanently greyed control reading "inherits: nothing" is a puzzle
    -- rather than an affordance.
    local parentName = shown and Sets.ParentOf(name) or nil
    if shown and (parentName or #Sets.ParentChoices(name) > 0) then
        doll.inherit:SetText(parentName and ("Inherits: " .. parentName) or "Inherits: nothing")
        doll.inherit:Show()
    else
        doll.inherit:Hide()
    end
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
    -- UI-19. A control that cannot work says so BEFORE it is pressed. Equip used to look live while
    -- you ran back as a ghost; the click then spent the driver's whole BUSY_LIMIT before reporting
    -- that you had been dead the entire time — honest, and ten seconds too late.
    --
    -- Only the controls that move items go quiet. The list, the inspector, the picker and the
    -- options panel stay live, because running back as a ghost is exactly when someone has time to
    -- tidy their sets, and editing one touches no gear at all.
    local canSwap, why = Core.CanSwap(Kitbag.Compat.ActionState())
    doll.blocked = (not canSwap) and why or nil
    -- SetIconEnabled rather than Enable/Disable: with no label on the button, the picture is the only
    -- thing there is to grey, and a disabled-but-bright icon looks pressable and then does nothing.
    doll.equip:SetIconEnabled(not (Equip.IsRunning() or not canSwap))

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

    -- One line for what stands between you and wearing this, through the verdict the row uses.
    doll.note:SetText(UI.InspectorNote(plan))
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
    -- Kitbag's windows were all in the default MEDIUM strata with no level of their own, which is
    -- the same shelf Blizzard's character sheet and bags sit on: they interleaved with the game's
    -- UI and with each other by creation order, which is not an order anyone can predict. One
    -- deliberate stack instead — the main window above the game's frames, the panels it opens
    -- (options, icon picker) in DIALOG above that. `SetToplevel` is what raises a window when it is
    -- clicked, so two Kitbag windows in the same strata cannot get stuck the wrong way round. This also matters for the character preview: a 3D model is drawn in its strata's own
    -- pass, and anything sitting above it hides it completely rather than partially.
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:Hide()

    -- Esc closes it, like every other panel in the game.
    tinsert(UISpecialFrames, "KitbagFrame")

    -- The slot picker and the inherit menu belong to this window and must not outlive it. OnHide
    -- rather than the Toggle path, because Esc and the close button never go through Toggle. The
    -- menu is Blizzard's own list frame rather than a child of ours, so hiding the window does not
    -- take it with it — it would be left floating over the game with nothing behind it.
    frame:SetScript("OnHide", function()
        Kitbag.Picker.Close()
        CloseDropDownMenus()
        -- The rename box is a child of the list and hides with it, but `renaming` is a file-local
        -- and would survive — the next press would then read as a second press and close a box that
        -- was never open.
        closeRenameBox()
    end)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.title:SetText("Kitbag")

    -- Named and recessed like every other region in the addon (UI-22). The rows are children of it,
    -- so the ground draws behind them however their own selection and highlight textures are layered.
    local list = Skin.Inset(CreateFrame("Frame", "KitbagSetList", frame))
    list:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -34)
    -- Room on the right for the scroll bar. Overlapping it would eat the rightmost few pixels of
    -- every row, which reads as a dead strip rather than as a layout bug.
    list:SetSize(316, MAX_ROWS * ROW_HEIGHT)

    rows = {}
    for i = 1, MAX_ROWS do rows[i] = createRow(list, i) end

    -- One box for twelve rows (UI-29), created after them so it draws over the row it sits on.
    -- `autoFocus` off: an InputBoxTemplate grabs the keyboard the moment it is shown otherwise, and
    -- this one is shown by a press that has already decided when focus should move.
    renameBox = CreateFrame("EditBox", "KitbagRenameBox", list, "InputBoxTemplate")
    renameBox:SetAutoFocus(false)
    renameBox:Hide()
    renameBox:SetScript("OnTextChanged", function() renameProposal() end)
    renameBox:SetScript("OnEscapePressed", function() stopRename() end)
    -- Clicking away is a cancel rather than a commit. A box left floating over a list that has since
    -- scrolled is the version that renames a set nobody was looking at.
    renameBox:SetScript("OnEditFocusLost", function() stopRename() end)
    renameBox:SetScript("OnEnterPressed", function(self)
        local impact = renameProposal()
        if not impact then return end
        -- A name that did not change closes the box quietly: nothing went wrong, and an error
        -- message for pressing Enter on an unedited name is a control scolding the player.
        if impact.why == "same" then
            stopRename()
            return
        end
        -- Refused names leave the box open with the reason already on screen. There is nothing to
        -- say that the line has not been saying since the keystroke that caused it.
        if not impact.ok then return end

        local from, to = renaming, impact.name
        closeRenameBox()
        -- Selection follows the set rather than the name: `Sets.Rename` carries `lastSet`, but the
        -- window's own selection is a file-local and would be left naming a set that is gone, which
        -- Refresh would silently repair by jumping to the first set in the list.
        if Sets.Rename(from, to) then UI.Select(to) else UI.Refresh() end
    end)

    -- FauxScrollFrame rather than a real scrolling child: the rows stay put and the *data* moves
    -- through them, so thirteen frames serve a hundred sets. It is also the one scrolling widget
    -- that has existed unchanged in every flavour Kitbag targets.
    scroll = CreateFrame("ScrollFrame", "KitbagScrollFrame", frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UI.Refresh)
    end)

    doll = buildDoll(frame)

    -- Under the list, centred on it (UI-28). Built here rather than with the paperdoll because it is
    -- anchored to the LIST — the controls act on whichever set is selected there, and a row of them
    -- in the far corner of the next panel along said otherwise.
    local actionRow = buildActionRow(frame, list, doll)

    -- Named so `/kit verify` can measure that the import button clears this line rather than sitting
    -- on it (VERIFY-14). The button appears between the two and only on some characters, which is
    -- exactly the layout nobody looks at on the characters where it is absent.
    --
    -- Below the action bar rather than directly below the list, because the bar is what has to touch
    -- the list: this line is prose about the column, and prose reads perfectly well as its footer.
    status = frame:CreateFontString("KitbagStatusLine", "OVERLAY", "GameFontDisableSmall")
    -- Still anchored to the LIST, so it keeps the left edge it shares with the rows above it — a
    -- left-justified line hung off a centred row would follow the row's edge instead. The drop is
    -- measured off the bar rather than typed, so a taller bar pushes this down with it.
    status:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -(8 + actionRow:GetHeight() + 6))
    status:SetWidth(316)
    status:SetJustifyH("LEFT")

    -- The bottom row's controls are NAMED so /kit verify can measure them (VERIFY-10). The row is
    -- full at 660 wide and UIPanelButtonTemplate does not shrink a label that no longer fits — it
    -- lets it run out under the button's edge — so an overflow reads as an oddly-worded button rather
    -- than as a layout fault, and nobody files it.
    -- Options is a door to another window rather than something this window does, which is the one
    -- kind of control an icon is unambiguously right for — and it was spending 90 pixels of a row
    -- VERIFY-10 exists because it was full (UI-24).
    --
    -- It had no tooltip while it had a label. That was survivable then and is not now, so the hover
    -- arrives with the picture; `/kit verify` asserts the pair rather than trusting it.
    --
    -- The Rules button stood to its right until the engine was shelved (see Icebox/). Options simply
    -- inherits that corner rather than sitting where it did with a gap beside it: a control anchored
    -- to a button that no longer exists is a layout that breaks silently, and a hole in the row reads
    -- as something failing to draw.
    local optionsButton = Skin.IconButton(frame, "KitbagOptionsButton", OPTIONS_ICON, 22)
    optionsButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
    optionsButton:SetScript("OnClick", function() Kitbag.Options.Toggle() end)
    optionsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("Options", 1, 0.82, 0)
        GameTooltip:AddLine("The minimap button, the trinket bar and what Kitbag says in chat.",
            0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    optionsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- It was cut to 150 to buy the Options button its room; UI-24 and UI-27 turned the row's buttons
    -- into icons and handed back nearly 300 pixels between them. An edit box scrolls, so a long name
    -- always typed fine — but a box that shows the whole name is the difference between reading what
    -- you are about to save and trusting it.
    --
    -- 306 lines its right edge up with the list above it. It sits at 20 where the list sits at 14
    -- because InputBoxTemplate insets its own border by about five pixels a side, which is the same
    -- correction the import button applies with its -6.
    local nameBox = CreateFrame("EditBox", "KitbagNameBox", frame, "InputBoxTemplate")
    nameBox:SetSize(306, 20)
    nameBox:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 15)
    nameBox:SetAutoFocus(false)

    -- Both buttons take the name from the same box, so they read it the same way — through the same
    -- function the store uses. Selecting the RAW text would leave the inspector pointing at " Tank "
    -- when the set went in as "Tank", and the panel would silently fall back to the first set.
    local function nameFromBox()
        local name = Core.CleanName(nameBox:GetText())
        if not name then Sets.Say("type a name in the box first.") end
        return name
    end

    local function created(set)
        if not set then return end
        -- Show what was just made: it is the set the player is thinking about, and for a new empty
        -- one it is also the set they are about to start clicking slots on.
        nameBox:SetText("")
        nameBox:ClearFocus()
        -- Through UI.Select, which redraws — the store already refreshed, but before the selection
        -- moved. Without the redraw the inspector keeps showing the previous set until some unrelated
        -- event refreshes the window, which on a live character is soon enough to hide the bug and
        -- not soon enough to look deliberate.
        UI.Select(set.name)
    end

    -- The one destructive thing this window does without a shift held (BUG-3). Delete gets away with
    -- shift-click because its label says what it does; this button's label says "save", and no
    -- gesture on a button called Save is going to read as "and lose the four pieces you picked by
    -- hand". So it asks, in words, and only when there is something to lose.
    StaticPopupDialogs["KITBAG_OVERWRITE"] = {
        text = "%s already names gear you are not wearing:\n\n|cffff8080%s|r\n\n" ..
               "Saving what you are wearing over it will drop those pieces.",
        button1 = "Save anyway",
        button2 = CANCEL,
        OnAccept = function(self, name) created(Sets.Save(name, true)) end,
        hideOnEscape = true,
        whileDead = true,
        timeout = 0,
        -- The conventional slot for an addon's popup: the first two are what Blizzard's own code
        -- reaches for, and sharing one is how a confirmation ends up answering for a dialog the
        -- player never saw.
        preferredIndex = 3,
    }

    -- Deleting a set cannot be undone and there is no other copy of it, so this one asks. Unlike the
    -- overwrite prompt it fires every time rather than only when something would be lost: there is no
    -- "harmless delete" the way there is a harmless re-save.
    StaticPopupDialogs["KITBAG_DELETE"] = {
        text = "Delete %s?\n\n%s",
        button1 = DELETE or "Delete",
        button2 = CANCEL,
        OnAccept = function(self, name) Sets.Delete(name) end,
        hideOnEscape = true,
        whileDead = true,
        timeout = 0,
        preferredIndex = 3,
    }

    -- An icon since UI-27, and this is the one on the row where that trade costs something real.
    -- "Save what I'm wearing" was a whole sentence, and it was the sentence that stopped this being
    -- read as "save the set I have selected" — a different act, and a destructive one, since it is
    -- the selected set that would be overwritten. The tooltip has to carry that, so it says what is
    -- captured, from where, and under what name, in that order.
    local save = Skin.IconButton(frame, "KitbagSaveButton", SAVE_ICON, 22)
    save:SetPoint("LEFT", nameBox, "RIGHT", 10, 0)
    save:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("Save what you are wearing", 1, 0.82, 0)
        GameTooltip:AddLine("Captures every slot you have equipped right now, under the name in " ..
            "the box beside this.", 0.9, 0.9, 0.9, true)
        -- Said before the press, because it is a reassurance and a reassurance that arrives after
        -- the fact is no use to somebody deciding whether to press. Same reasoning as the import
        -- button's tooltip.
        GameTooltip:AddLine("Re-saving over a set asks first if it would drop pieces you picked " ..
            "by hand.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    save:SetScript("OnLeave", function() GameTooltip:Hide() end)
    save:SetScript("OnClick", function()
        local name = nameFromBox()
        if not name then return end
        local set, lost = Sets.Save(name)
        if set then
            created(set)
        elseif lost then
            -- The name goes through as `data` rather than being read back off the box on accept:
            -- the box is still editable while the popup is up, and answering "Save anyway" must
            -- overwrite the set the question named.
            StaticPopup_Show("KITBAG_OVERWRITE", name, Sets.LossText(lost), name)
        end
    end)

    -- The other way in (UI-16). Saving what you are wearing cannot make a set out of gear that is
    -- still in the bank; an empty set plus the slot picker can.
    local blank = Skin.IconButton(frame, "KitbagNewSetButton", NEW_ICON, 22)
    blank:SetPoint("LEFT", save, "RIGHT", 6, 0)
    blank:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("New empty set", 1, 0.82, 0)
        GameTooltip:AddLine("Makes a set with nothing in it, under the name in the box beside " ..
            "this, and selects it.", 0.9, 0.9, 0.9, true)
        -- The reason this button exists at all, and it is not obvious from the act: saving what you
        -- are wearing cannot build a set out of gear that is sitting in the bank.
        GameTooltip:AddLine("This is how a set gets built out of gear you are not wearing — click " ..
            "the paperdoll slots to fill it in.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    blank:SetScript("OnLeave", function() GameTooltip:Hide() end)
    blank:SetScript("OnClick", function()
        local name = nameFromBox()
        if name then created(Sets.New(name)) end
    end)

    -- The migration door (UI-18). `/kit import` existed from the start and was reachable only from
    -- `/kit help`, which is UI-17's lesson in the worst possible place: someone arriving from
    -- ItemRack sees an empty set list and concludes their kits did not come across. It sits above
    -- the name box rather than in the button row because that row is already full at 660 wide.
    --
    -- It hides itself when there is nothing to import, so it is absent for everyone who never used
    -- ItemRack and disappears for good once the sets are across — this is a one-time migration, not
    -- a control anyone needs permanently. Same reasoning as the Inherits button (UI-11): a
    -- permanently dead control is a puzzle rather than an affordance.
    importButton = CreateFrame("Button", "KitbagImportButton", frame, "UIPanelButtonTemplate")
    -- Wide enough for a two-digit count: "Import 12 sets from ItemRack" is the longest this says,
    -- and nothing else shares the row, so the room is free.
    importButton:SetSize(220, 22)
    -- -6 against the name box's own inset lines it up with the list above it.
    importButton:SetPoint("BOTTOMLEFT", nameBox, "TOPLEFT", -6, 10)
    importButton:SetScript("OnClick", function() Sets.ImportItemRack() end)
    importButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import from ItemRack", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Brings this character's ItemRack sets across, with their icons and " ..
            "keybindings.", 0.9, 0.9, 0.9, true)
        -- Said before the click, because both are reassurances and a reassurance that arrives after
        -- the fact is no use to someone deciding whether to press.
        GameTooltip:AddLine("Your existing sets are never overwritten. ItemRack stores sets per " ..
            "character, so this imports only the one you are on.", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    importButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    importButton:Hide()

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
    -- Clamped against the list as it is NOW — deleting sets while scrolled down would otherwise
    -- leave every row indexing past the end of a shortened list, and the panel would draw empty.
    local offset = Core.ScrollOffset(#names, MAX_ROWS, FauxScrollFrame_GetOffset(scroll))

    for i, row in ipairs(rows) do
        local name = names[i + offset]
        if name then
            local entry = overview[name] or {}
            row.setName = name
            row.data.plan, row.data.totals = entry.plan, entry.totals
            row.icon.texture:SetTexture(Sets.Icon(name))
            -- Blank while the box is over it, or the old name reads through from underneath.
            row.name:SetText(name ~= renaming and name or "")
            row.state:SetText(UI.RowText(entry.plan))
            row.totals:SetText(rowTotals(entry.totals))
            if name == selected then row.selection:Show() else row.selection:Hide() end
            row:Show()
        else
            row.setName = nil
            row:Hide()
        end
    end

    -- A set that scrolled away, or was deleted, under an open box. Closed rather than re-anchored:
    -- the box is only ever opened by a press, and one that reappears somewhere else on its own is
    -- worse than one that goes away.
    if renaming then
        local visible = false
        for _, row in ipairs(rows) do
            if row.setName == renaming then visible = true end
        end
        if not visible then closeRenameBox() end
    end

    local chosen = selected and overview[selected] or nil
    refreshDoll(selected, chosen and chosen.plan, chosen and chosen.totals)

    if #names == 0 then
        status:SetText("No sets yet. Put on what you want to save, name it below, and press Save.")
    else
        status:SetText(string.format("%d set%s. Click one to inspect it.",
            #names, #names == 1 and "" or "s"))
    end

    -- Last, so the line describes the box rather than being overwritten by the count behind it. A
    -- redraw can arrive mid-rename from anywhere — the death watcher is enough on its own.
    if renaming then renameProposal() end

    -- Re-asked on every redraw rather than once at build: the import itself ends in a refresh, so
    -- this is what makes the button take itself away the moment its job is done.
    local offer = Sets.ImportOffer()
    if offer then
        importButton:SetText(string.format("Import %d set%s from ItemRack",
            offer.count, offer.count == 1 and "" or "s"))
        importButton:Show()
    else
        importButton:Hide()
    end
end

-- Dying and coming back changes whether Equip may be pressed, and nothing else in the addon redraws
-- the window for it (UI-19). A watcher of its own, and now the only one in the addon: the rule
-- engine that used to keep its own event list is shelved in Icebox/.
--
-- Death only. A cast also blocks a swap, but it clears itself in a second or two and the driver
-- simply waits it out and then succeeds — which is correct behaviour, not the bug. Registering the
-- seven spellcast events to grey a button for the length of a Frostbolt would put this frame in the
-- middle of every combat log for no outcome anyone would notice.
--
-- Named, and for a reason: a watcher with no handle on it from outside can only be checked by dying,
-- and dying is the one act `/kit verify` cannot perform. The name is what lets a check ask whether
-- the client ACCEPTED these three — the registration is inside a
-- pcall, so an event a flavour lacks is silent, and silent in the worst direction: PLAYER_ALIVE and
-- PLAYER_UNGHOST are what bring the window back by itself on release (VERIFY-15).
local deathWatcher = CreateFrame("Frame", "KitbagDeathWatcher")
for _, event in ipairs({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
    pcall(deathWatcher.RegisterEvent, deathWatcher, event)
end
deathWatcher:SetScript("OnEvent", function() UI.Refresh() end)

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
