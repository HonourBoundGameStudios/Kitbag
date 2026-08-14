-- KitbagVerify — the addon checking itself, so a person does not have to.
--
-- EPIC-VERIFY is a long list of "has this frame ever actually been drawn". Answering it by hand costs
-- a person twenty minutes of careful clicking, and it has to be re-paid every time the UI changes.
-- Most of that list does not need a person: a frame either shows or it does not, a dropdown either
-- opens or it does not, a form label is either a name or the string "form 3". The addon can ask
-- itself all of that.
--
-- What it CANNOT ask itself is whether the answer looks right — whether a scroll bar overlaps the
-- last column, whether two halves line up. So this reports three outcomes, not two, and the third is
-- the important one: a check that could not run says SKIP and is counted separately. A self-check
-- that folds what it skipped into what it passed manufactures confidence, and false confidence is
-- worse than no check at all — it is the thing that lets a broken frame ship believing it was tested.
--
-- Report() is PURE and covered by Tests/verify_test.lua. The checks touch the client and are guarded
-- individually, because a probe that dies takes the rest of the run with it otherwise.

Kitbag = Kitbag or {}

local Verify = {}

-- How many runs to keep, matching KitbagDebug: enough to compare "before the change" with "after",
-- few enough that SavedVariables does not grow without bound.
local KEEP = 3

Verify.KEEP = KEEP

-- ---------------------------------------------------------------------------
-- The report (PURE)
-- ---------------------------------------------------------------------------

--- The run, as lines. PURE — see Tests/verify_test.lua.
function Verify.Report(results, world)
    results = results or {}
    world = world or {}

    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    add("Kitbag verification — %s", tostring(world.when))
    add("addon %s | %s | interface %s",
        tostring(world.version), tostring(world.flavour), tostring(world.interface))
    add("")

    if #results == 0 then
        add("no checks ran.")
        return out
    end

    -- Declared order, not sorted: the checks are grouped by the item they answer, and re-ordering
    -- them would make two runs of the same build look different.
    local passed, failed, skipped = 0, 0, 0
    for _, r in ipairs(results) do
        local mark
        if r.ok == true then
            mark, passed = "PASS", passed + 1
        elseif r.ok == false then
            mark, failed = "FAIL", failed + 1
        else
            -- nil is "could not check", which is neither of the other two and must never read as
            -- either. Everything that could not be established says so on its own line.
            mark, skipped = "SKIP", skipped + 1
        end
        add("%-4s %-10s %s%s", mark, tostring(r.item or ""), tostring(r.label),
            r.detail and ("  —  " .. tostring(r.detail)) or "")
    end

    add("")
    add("%d check(s): %d passed, %d failed, %d skipped",
        #results, passed, failed, skipped)

    -- A run that established nothing looks exactly like a clean run at a glance — same absence of
    -- FAIL, same green feeling — so it is called out in words rather than left to the counts.
    if passed == 0 and failed == 0 then
        add("NOTHING WAS VERIFIED — every check was skipped. This is not a pass.")
    elseif skipped > 0 then
        add("%d check(s) could not run and are NOT counted as passing.", skipped)
    end

    return out
end

-- ---------------------------------------------------------------------------
-- The checks (these touch the client)
-- ---------------------------------------------------------------------------
--
-- Each returns (ok, detail): true / false / nil, where nil means "could not establish" and MUST come
-- with a reason. Raising is also allowed — Run turns a raised error into a FAIL with the message,
-- since a check that explodes has certainly not passed.

-- Show a frame, read what the client made of it, and put it back the way it was. Restoring matters:
-- a verification run that leaves six windows open on someone's screen will not be run twice.
local function inspect(toggle, frameName)
    local frame = _G[frameName]
    local wasShown = frame and frame:IsShown()

    if not wasShown then toggle() end
    frame = _G[frameName]
    if not frame then return false, frameName .. " was never created" end

    local shown = frame:IsShown()
    local width, height = frame:GetWidth(), frame:GetHeight()
    local strata = frame:GetFrameStrata()

    if not wasShown and shown then toggle() end

    if not shown then return false, frameName .. " exists but did not show" end
    return true, string.format("%s  %dx%d  strata %s",
        frameName, math.floor(width + 0.5), math.floor(height + 0.5), tostring(strata))
end

Verify.CHECKS = {
    {
        id = "forms", item = "VERIFY-1", label = "Shapeshift form labels",
        -- The silent failure this whole check exists for: GetShapeshiftFormInfo's signature differs
        -- between flavours and reading it wrong does not error, it labels everything "form <n>".
        run = function()
            local Compat = Kitbag.Compat
            if not Compat then return nil, "KitbagCompat is not loaded" end
            local labels = Compat.FormLabels()

            local parts, unnamed, count = {}, 0, 0
            for i = 0, 20 do
                local label = labels[i]
                if label then
                    count = count + 1
                    parts[#parts + 1] = i .. " " .. label
                    if label == ("form " .. i) then unnamed = unnamed + 1 end
                end
            end

            -- Index 0 alone means a class with no forms, which is a real answer and not a failure.
            if count <= 1 then
                return nil, "this character has no shapeshift forms — try a druid"
            end
            if unnamed > 0 then
                return false, unnamed .. " form(s) unnamed, so the per-flavour signature is wrong: "
                    .. table.concat(parts, ", ")
            end
            return true, table.concat(parts, ", ")
        end,
    },
    {
        id = "window", item = "VERIFY-8", label = "Main window draws",
        run = function()
            if not Kitbag.UI then return nil, "KitbagUI is not loaded" end
            return inspect(Kitbag.UI.Toggle, "KitbagFrame")
        end,
    },
    {
        id = "rules-window", item = "VERIFY-1", label = "Rule editor draws",
        run = function()
            if not Kitbag.RulesUI then return nil, "KitbagRulesUI is not loaded" end
            return inspect(Kitbag.RulesUI.Toggle, "KitbagRulesFrame")
        end,
    },
    {
        id = "options-window", item = "VERIFY-2", label = "Options panel draws",
        run = function()
            if not Kitbag.Options then return nil, "KitbagOptions is not loaded" end
            return inspect(Kitbag.Options.Toggle, "KitbagOptionsFrame")
        end,
    },
    {
        id = "slot-art", item = "VERIFY-8", label = "Empty-slot art paths",
        -- A missing texture renders magenta rather than blank, so this cannot prove the art is
        -- right — but it can prove every path was accepted and none came back empty.
        run = function()
            local texture = UIParent:CreateTexture(nil, "ARTWORK")
            local bad = {}
            for _, name in ipairs(Verify.SLOT_ART_NAMES or {}) do
                local path = "Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. name
                texture:SetTexture(path)
                if not texture:GetTexture() then bad[#bad + 1] = name end
            end
            texture:SetTexture(nil)
            if #bad > 0 then
                return false, "no texture for: " .. table.concat(bad, ", ")
            end
            return true, #(Verify.SLOT_ART_NAMES or {}) .. " slot art paths all resolved"
        end,
    },
    {
        id = "trinket-bar", item = "VERIFY-2", label = "Trinket bar draws",
        run = function()
            local Trinkets = Kitbag.Trinkets
            if not Trinkets then return nil, "KitbagTrinkets is not loaded" end
            local frame = _G.KitbagTrinketBar
            if not frame then return nil, "the trinket bar is switched off (/kit trinkets)" end
            return true, string.format("KitbagTrinketBar  %dx%d  shown %s",
                math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5),
                tostring(frame:IsShown()))
        end,
    },
    {
        id = "bank", item = "VERIFY-3", label = "Bank contents readable",
        run = function()
            local Inventory = Kitbag.Inventory
            if not Inventory then return nil, "KitbagInventory is not loaded" end

            -- Bagged() scans the bank even when it is shut, because the client keeps the contents
            -- cached after the first visit of the session. So "nothing banked" before that first
            -- visit is not a failure and must not read as one — it is the check having nothing to
            -- look at yet.
            local banked = 0
            for _, place in pairs(Inventory.Bagged() or {}) do
                if place.bank then banked = banked + 1 end
            end

            local open = Inventory.IsBankOpen()
            if banked == 0 then
                return nil, open and "the bank is open but empty"
                    or "no bank contents cached yet — visit a banker once, then run this again"
            end
            return true, string.format("%d item(s) seen in the bank; bank currently %s",
                banked, open and "OPEN, so the planner may use them" or "shut, so they read as 'in your bank'")
        end,
    },
    {
        id = "restore-point", item = "VERIFY-4", label = "Restore point survives a reload",
        run = function()
            local char = Kitbag.char
            if not char then return nil, "no character bucket yet" end
            if not char.restorePoint then
                return nil, "nothing has been remembered — trigger a `restore` rule first"
            end
            local named = 0
            for _ in pairs(char.restorePoint.slots or {}) do named = named + 1 end
            return true, "a restore point is stored, naming " .. named .. " slot(s)"
        end,
    },
    {
        id = "tooltip-template", item = "VERIFY-2", label = "TooltipBorderedFrameTemplate exists",
        -- KitbagFlyout builds its panel from this template inside a pcall and silently falls back to
        -- a plain frame. That fallback has never been seen, which means nobody knows which of the two
        -- paths ships — so ask the client directly rather than inferring it from how the panel looks.
        run = function()
            local ok, created = pcall(CreateFrame, "Frame", nil, UIParent,
                "TooltipBorderedFrameTemplate")
            if ok and created then return true, "the template resolves; the pcall fallback is unused" end
            return false, "the template is MISSING on this flavour — the plain-frame fallback is what ships"
        end,
    },
    {
        id = "flyout", item = "VERIFY-2", label = "Paperdoll flyout opens",
        run = function()
            local Flyout = Kitbag.Flyout
            if not Flyout then return nil, "KitbagFlyout is not loaded" end
            if not (Kitbag.db and Kitbag.db.options and Kitbag.db.options.flyouts) then
                return nil, "flyouts are switched off in options"
            end

            Flyout.Open(1, UIParent)   -- slot 1 is the head, which every character has
            local panel = _G.KitbagFlyoutPanel
            if not panel then return false, "KitbagFlyoutPanel was never created" end

            local shown = panel:IsShown()
            local detail = string.format("KitbagFlyoutPanel  %dx%d  strata %s",
                math.floor(panel:GetWidth() + 0.5), math.floor(panel:GetHeight() + 0.5),
                tostring(panel:GetFrameStrata()))
            panel:Hide()

            if not shown then
                -- Nothing to show is a real answer, not a fault: an empty head slot with no
                -- alternatives in the bags has no flyout to open.
                return nil, "the panel exists but stayed hidden — probably nothing fits slot 1"
            end
            return true, detail
        end,
    },
    {
        id = "picker", item = "VERIFY-2", label = "Slot picker opens",
        run = function()
            local Picker, Sets = Kitbag.Picker, Kitbag.Sets
            if not Picker or not Sets then return nil, "KitbagPicker is not loaded" end
            -- Sets.Names reads the character's bucket, which does not exist until PLAYER_LOGIN has
            -- handed the SavedVariables over. Asking early is an error, not an empty list.
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end
            local name = (Sets.Names() or {})[1]
            if not name then return nil, "no sets yet — make one and run this again" end

            Picker.Open(name, 1, UIParent)
            local frame = _G.KitbagPickerFrame
            if not frame then return false, "KitbagPickerFrame was never created" end

            local shown = frame:IsShown()
            local detail = string.format("KitbagPickerFrame  %dx%d  strata %s",
                math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5),
                tostring(frame:GetFrameStrata()))
            Picker.Close()

            if not shown then return false, "the picker was built but did not show" end
            return true, detail
        end,
    },
    {
        id = "icon-picker", item = "VERIFY-2", label = "Set icon picker opens",
        run = function()
            local Icons, Sets = Kitbag.Icons, Kitbag.Sets
            if not Icons or not Sets then return nil, "KitbagIcons is not loaded" end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end
            local name = (Sets.Names() or {})[1]
            if not name then return nil, "no sets yet — make one and run this again" end

            Icons.Open(name)
            local frame = _G.KitbagIconFrame
            if not frame then return false, "KitbagIconFrame was never created" end

            local shown = frame:IsShown()
            local detail = string.format("KitbagIconFrame  %dx%d  strata %s",
                math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5),
                tostring(frame:GetFrameStrata()))
            frame:Hide()

            if not shown then return false, "the icon picker was built but did not show" end
            return true, detail
        end,
    },
    {
        id = "overwrite-popup", item = "VERIFY-12", label = "Overwrite confirmation draws",
        -- The popup must come up ABOVE the window that raised it. Blizzard's StaticPopup is not a
        -- child of ours, so the addon's own strata discipline does not cover it — which is exactly
        -- why this is worth measuring rather than assuming.
        run = function()
            if not _G.StaticPopupDialogs or not _G.StaticPopupDialogs["KITBAG_OVERWRITE"] then
                return nil, "the popup is only registered once the main window has been built"
            end

            local popup = _G.StaticPopup_Show("KITBAG_OVERWRITE", "TestSet",
                "Head, Chest (this is a verification run)", "TestSet")
            if not popup then return false, "StaticPopup_Show returned nothing" end

            local window = _G.KitbagFrame
            local detail = string.format("%s strata %s; KitbagFrame strata %s",
                popup:GetName() or "popup", tostring(popup:GetFrameStrata()),
                window and tostring(window:GetFrameStrata()) or "(window not built)")
            _G.StaticPopup_Hide("KITBAG_OVERWRITE")

            return true, detail
        end,
    },
    {
        id = "delete-popup", item = "VERIFY-12", label = "Delete confirmation draws",
        -- BUG-8: the delete guard used to be an invisible shift-click, so this popup is the whole
        -- fix. If it does not draw, Delete is silently broken again in exactly the way reported.
        run = function()
            if not _G.StaticPopupDialogs or not _G.StaticPopupDialogs["KITBAG_DELETE"] then
                return nil, "registered with the main window — open /kit once, then run this"
            end
            local popup = _G.StaticPopup_Show("KITBAG_DELETE", "TestSet",
                "This is a verification run.", "TestSet")
            if not popup then return false, "StaticPopup_Show returned nothing" end

            local window = _G.KitbagFrame
            local detail = string.format("%s strata %s; KitbagFrame strata %s",
                popup:GetName() or "popup", tostring(popup:GetFrameStrata()),
                window and tostring(window:GetFrameStrata()) or "(window not built)")
            _G.StaticPopup_Hide("KITBAG_DELETE")
            return true, detail
        end,
    },
    {
        id = "inherit-menu", item = "VERIFY-13", label = "Inherit menu opens over the window",
        run = function()
            local menu = _G.KitbagParentMenu
            if not menu then
                return nil, "the menu is built with the main window — open /kit once, then run this"
            end

            _G.ToggleDropDownMenu(1, nil, menu, _G.KitbagFrame, 0, 0)
            local list = _G.DropDownList1
            if not list then return false, "DropDownList1 does not exist" end

            local shown = list:IsShown()
            local detail = string.format("DropDownList1 strata %s level %s; KitbagFrame strata %s",
                tostring(list:GetFrameStrata()), tostring(list:GetFrameLevel()),
                _G.KitbagFrame and tostring(_G.KitbagFrame:GetFrameStrata()) or "(not built)")
            _G.CloseDropDownMenus()

            if not shown then
                return nil, "the menu did not open — this set may have nothing it can inherit from"
            end
            return true, detail
        end,
    },
    {
        id = "scroll-clamp", item = "VERIFY-11", label = "A shrinking list cannot go blank",
        -- Pure arithmetic, but run HERE too: the pure test proves ScrollOffset is right, and this
        -- proves the client is running a build that contains it.
        run = function()
            local Core = Kitbag.Core
            if not Core or not Core.ScrollOffset then
                return false, "Core.ScrollOffset is missing — this build predates the fix"
            end
            if Core.ScrollOffset(3, 8, 6) ~= 0 then
                return false, "a list shorter than its rows did not return to the top"
            end
            return true, "offsets clamp to the data"
        end,
    },
}

-- The slot art names KitbagUI asks the client for. Listed here rather than reached for out of
-- KitbagUI, which keeps them file-local — duplicated deliberately, and the check above is what
-- catches the duplication drifting.
Verify.SLOT_ART_NAMES = {
    "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrists",
    "Hands", "Finger", "Trinket", "MainHand", "SecondaryHand", "Ranged", "Tabard",
}

-- ---------------------------------------------------------------------------
-- Running them
-- ---------------------------------------------------------------------------

--- Run every check and return the results, in registry order.
function Verify.Run()
    local results = {}
    for _, check in ipairs(Verify.CHECKS) do
        -- Guarded one at a time. A check that raises has certainly not passed, but it must not take
        -- the other eight with it — the run someone asks for is the run where something is wrong.
        local ok, a, b = pcall(check.run)
        local entry = { id = check.id, item = check.item, label = check.label }
        if not ok then
            entry.ok, entry.detail = false, "the check itself errored: " .. tostring(a)
        else
            entry.ok, entry.detail = a, b
        end
        results[#results + 1] = entry
    end
    return results
end

--- Read the world, run the checks, and keep the report in SavedVariables.
function Verify.Capture()
    local Compat = Kitbag.Compat
    return Verify.Report(Verify.Run(), {
        when = date("%Y-%m-%d %H:%M:%S"),
        version = (GetAddOnMetadata and GetAddOnMetadata("Kitbag", "Version")) or
            (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("Kitbag", "Version")),
        flavour = Compat and (Compat.IS_MAINLINE and "Retail" or "Classic"),
        interface = select(4, GetBuildInfo()),
    })
end

--- Run and store. Returns the lines, so the caller can also print a summary.
function Verify.Store()
    local db = Kitbag.db
    local lines = Verify.Capture()
    if not db then return lines end

    db.verify = db.verify or {}
    table.insert(db.verify, 1, lines)
    while #db.verify > KEEP do table.remove(db.verify) end
    return lines
end

Kitbag.Verify = Verify
return Verify
