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
        id = "part-banked", item = "VERIFY-3", label = "A part-banked set is named, with what is at the bank",
        -- VERIFY-3's last half — "a part-banked set completes on a second Equip" — needs a set that
        -- is actually part-banked, and FINDING one is a reading rather than a judgement. Asking a
        -- person to open the bank and squint at set rows is the exact shape this epic keeps
        -- converting into checks.
        --
        -- It also answers a question the pure tests structurally cannot: Core.Explain's `in your
        -- bank` branch is covered and so is atBank counting, but whether a REAL bank full of REAL
        -- gear makes a REAL saved set report atBank has never once been observed. That join is where
        -- an item key stored by one path and read by another would come apart, and it would look
        -- like "Kitbag can't find my gear" rather than like a parsing fault.
        run = function()
            local Sets, Inventory = Kitbag.Sets, Kitbag.Inventory
            if not (Sets and Inventory and Sets.Overview) then
                return nil, "KitbagSets is not loaded"
            end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end
            if #(Sets.Names() or {}) == 0 then return nil, "no sets yet — make one and run this again" end

            -- How much bank there is to see at all, which decides WHICH of the two skips below is
            -- honest. "Go and build a part-banked set" and "the addon cannot see your bank yet" send
            -- a reader in completely different directions, and VERIFY-4 sat skipped for three runs on
            -- exactly that confusion.
            local banked = 0
            for _, place in pairs(Inventory.Bagged() or {}) do
                if place.bank then banked = banked + 1 end
            end
            if banked == 0 then
                return nil, "no bank contents cached yet — visit a banker once, then run this again"
            end

            -- Through Sets.Overview, which is what the window itself reads. A second computation
            -- here could disagree with the rows on screen, and then the check and the window would
            -- be two witnesses telling different stories about the same set.
            local parts = {}
            for name, entry in pairs(Sets.Overview() or {}) do
                local plan = entry and entry.plan
                if plan and (plan.atBank or 0) > 0 then
                    local slots = {}
                    for _, miss in ipairs(plan.missing or {}) do
                        if miss.where == "bank" then
                            local slot = Kitbag.Core.SlotById(miss.slot)
                            slots[#slots + 1] = slot and slot.label or ("slot " .. tostring(miss.slot))
                        end
                    end
                    parts[#parts + 1] = { name = name, count = plan.atBank, slots = slots }
                end
            end

            if #parts == 0 then
                return nil, string.format(
                    "%d item(s) readable in the bank, but no saved set names any of them — build a "
                    .. "set out of bank gear before this item can be answered", banked)
            end

            -- Sorted, so two runs of the same character are diffable rather than merely both green.
            table.sort(parts, function(a, b) return a.name < b.name end)
            local lines = {}
            for _, part in ipairs(parts) do
                lines[#lines + 1] = string.format("%s (%d: %s)", part.name, part.count,
                    table.concat(part.slots, ", "))
            end

            -- The open/shut state belongs on this line: it is the difference between a second Equip
            -- being able to finish the set and it being unable to, and the reader is about to try
            -- exactly that.
            return true, string.format("%s — bank is %s. Equip %s at an OPEN bank to finish VERIFY-3",
                table.concat(lines, "; "),
                Inventory.IsBankOpen() and "OPEN, so a second Equip can complete these" or "shut",
                parts[1].name)
        end,
    },
    {
        id = "restore-point", item = "VERIFY-4", label = "Restore point survives a reload",
        run = function()
            local char = Kitbag.char
            if not char then return nil, "no character bucket yet" end
            if not char.restorePoint then
                -- Which of the two situations this is decides what the reader should do next, and
                -- they are opposite. "Go and trigger one" is useless advice when there is no restore
                -- rule to trigger — it sends someone off to reproduce something that cannot happen,
                -- which is how this item sat skipped for three runs.
                local restoreRules = 0
                for _, rule in ipairs(char.rules or {}) do
                    if rule.restore then restoreRules = restoreRules + 1 end
                end
                if restoreRules == 0 then
                    return nil, "no `restore` rule exists on this character — author one before this "
                        .. "item can be answered at all"
                end
                return nil, string.format(
                    "%d `restore` rule(s) exist but none has fired yet — trigger one", restoreRules)
            end
            local named = 0
            for _ in pairs(char.restorePoint.slots or {}) do named = named + 1 end
            return true, "a restore point is stored, naming " .. named .. " slot(s)"
        end,
    },
    {
        id = "watched-events", item = "VERIFY-18", label = "The client accepted every watched event",
        -- The engine ASKS for fifteen events inside a pcall, because an event a flavour does not have
        -- is a hard error rather than a no. What it gets is a separate question, and the gap between
        -- the two is silent: a rule conditioning on an event the client never sends looks exactly
        -- like a rule that never matched, which is BUG-9's shape and cost a session once already.
        --
        -- Events.Enable already records the answer per event; this only compares the record against
        -- what was asked for, which is why it is a check and not a person reading fifteen lines of a
        -- dump. PLAYER_ALIVE and PLAYER_UNGHOST are called out by name because their failure is a
        -- different and worse thing than a condition that never matches: they are what WAKES a swap
        -- held off through a corpse run (RULE-6), so losing them does not mean a rule never fires —
        -- it means gear that was deliberately held is never given back.
        run = function()
            local Events = Kitbag.Events
            if not Events or not Events.Diagnostics then return nil, "KitbagEvents is not loaded" end

            local watched = Events.Diagnostics().events or {}
            if #watched == 0 then
                -- Enable() runs unconditionally at PLAYER_LOGIN — it is not behind the auto-swap
                -- option, which gates whether a matched rule ACTS and not whether the client is
                -- listened to. So an empty record means the login handler did not reach here at
                -- all, which is a much larger fault than a switched-off feature.
                return nil, "the engine has never registered anything — Events.Enable() did not "
                    .. "run, which happens at PLAYER_LOGIN and is not optional"
            end

            local WAKE = { PLAYER_ALIVE = true, PLAYER_UNGHOST = true }
            local missing, wake = {}, {}
            for _, e in ipairs(watched) do
                if not e.registered then
                    missing[#missing + 1] = tostring(e.name)
                    if WAKE[e.name] then wake[#wake + 1] = tostring(e.name) end
                end
            end

            if #wake > 0 then
                return false, string.format(
                    "%s did not register — a swap held while dead (RULE-6) would never be woken, "
                    .. "and the gear would simply stay off", table.concat(wake, " and "))
            end
            if #missing > 0 then
                return false, string.format(
                    "%d of %d events did not register: %s — any rule conditioning on one of those "
                    .. "will silently never match", #missing, #watched, table.concat(missing, ", "))
            end
            return true, string.format("all %d watched events registered, including the "
                .. "PLAYER_ALIVE/PLAYER_UNGHOST pair the corpse-run wake-up needs", #watched)
        end,
    },
    {
        id = "tooltip-template", item = "VERIFY-2", label = "TooltipBorderedFrameTemplate exists",
        -- KitbagFlyout builds its panel from this template inside a pcall and silently falls back to
        -- a plain frame. Classic Era answered this on 2026-08-14: the template resolves, so the
        -- fallback is unused there — "never been seen" meant it never runs, not that nobody looked.
        -- The check still earns its place because the answer is per-flavour, and a silent fallback
        -- is exactly the kind that ships unnoticed. Ask the client rather than infer it from looks.
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
        id = "selection", item = "VERIFY-8", label = "Inspector follows the selected set",
        -- UI-13 moved Equip and Delete out of the rows, so they act on "the selected set" rather than
        -- on a set named where they sit. Two things therefore have to hold and neither is visible
        -- from outside the addon: that clicking a row moves the selection, and that the inspector
        -- redraws for the set that is now selected. If they come apart, Delete removes a set other
        -- than the one on screen — which looks correct right up until you count what is left.
        run = function()
            local UI, Sets = Kitbag.UI, Kitbag.Sets
            if not UI or not Sets then return nil, "KitbagUI is not loaded" end
            if not UI.Select then return false, "UI.Select is missing, so selection has no one path" end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end

            -- Two sets, because selecting the set that is already selected proves nothing.
            local names = Sets.Names() or {}
            if #names < 2 then return nil, "needs two sets to prove the selection MOVED — make another" end

            -- The window MUST be showing, and this check's first live run is why it says so. UI.Refresh
            -- returns immediately when the window is hidden, so UI.Select moves the selection and the
            -- doll is never redrawn — and the title still reads whatever set was last inspected. That
            -- reported a FAIL naming two real sets, which is the most convincing possible way to be
            -- wrong. It is not a bug in the window: with the window shut there is nothing to redraw,
            -- and reopening refreshes. A check must put the addon in the state the question is ABOUT.
            local window = _G.KitbagFrame
            if not window then return nil, "the window has not been built — open /kit once, then run this" end
            local wasShown = window:IsShown()
            if not wasShown then
                window:Show()
                UI.Refresh()
            end

            local restore = UI.Selected()
            -- Whichever is not already showing, so the check always asks for a change.
            local target = (restore == names[1]) and names[2] or names[1]

            UI.Select(target)
            local landed = UI.Selected()
            local title = _G.KitbagInspectorTitle and _G.KitbagInspectorTitle:GetText()

            if restore then UI.Select(restore) end
            if not wasShown then window:Hide() end

            if landed ~= target then
                return false, string.format("asked for %s, selection reads %s",
                    tostring(target), tostring(landed))
            end
            if title ~= target then
                -- The selection moved and the doll did not follow it. This is the dangerous half:
                -- the buttons would act on `target` while the player is looking at `title`.
                return false, string.format(
                    "selection is %s but the inspector is headed %s — Equip/Delete would act on the "
                    .. "set NOT on screen", tostring(target), tostring(title))
            end
            return true, string.format("selection moved to %s and the inspector followed", target)
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
        id = "picker-layout", item = "VERIFY-10", label = "Picker layout clears itself",
        -- Three edge relationships, all of which VERIFY-10 asks a person to judge by eye. The first
        -- is the one that cannot be reasoned from our side at all: FauxScrollFrameTemplate hangs its
        -- bar OUTSIDE the scroll frame by an amount Blizzard chooses, and BAR_STRIP is this addon's
        -- guess at that amount. A guess about someone else's layout is exactly what measuring is for.
        run = function()
            local Picker, Sets = Kitbag.Picker, Kitbag.Sets
            if not Picker or not Sets then return nil, "KitbagPicker is not loaded" end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end
            local name = (Sets.Names() or {})[1]
            if not name then return nil, "no sets yet — make one and run this again" end

            Picker.Open(name, 1, UIParent)
            local frame = _G.KitbagPickerFrame
            if not frame or not frame:IsShown() then
                Picker.Close()
                return nil, "the picker did not open, so there was nothing to measure"
            end

            local grid  = _G.KitbagPickerGrid
            local close = _G.KitbagPickerClose
            local title = _G.KitbagPickerTitle
            local bar   = _G.KitbagPickerScrollScrollBar
            if not (grid and close and title and bar) then
                Picker.Close()
                -- Naming these is what makes the measurement possible, so a missing name is a broken
                -- check rather than a skippable condition — say so instead of quietly passing.
                return false, "a named piece of the picker is missing, so nothing could be measured"
            end

            local faults, notes = {}, {}
            local function edge(a, b) return a and b and (a - b) or nil end

            -- 1. The bar must start at or right of the grid's right edge, or it sits on the icons.
            local clearance = edge(bar:GetLeft(), grid:GetRight())
            if clearance then
                notes[#notes + 1] = string.format("bar clears the last column by %d", clearance)
                if clearance < 0 then
                    faults[#faults + 1] = string.format(
                        "the scroll bar overlaps the last column of icons by %d", -clearance)
                end
            end

            -- 2. The close button must sit above the bar, not on its top end.
            local gap = edge(close:GetBottom(), bar:GetTop())
            if gap then
                notes[#notes + 1] = string.format("close clears the bar by %d", gap)
                if gap < 0 then
                    faults[#faults + 1] = string.format(
                        "the close button overlaps the top of the scroll bar by %d", -gap)
                end
            end

            -- 3. A long set name must run out of room against the close button rather than under it —
            -- and must not wrap, because a second line lands on the first row of icons.
            local room = edge(close:GetLeft(), title:GetRight())
            if room then
                notes[#notes + 1] = string.format("title stops %d short of close", room)
                if room < 0 then
                    faults[#faults + 1] = string.format(
                        "a long set name runs under the close button by %d", -room)
                end
            end
            if title.GetNumLines and title:GetNumLines() > 1 then
                faults[#faults + 1] = "the title wrapped onto a second line, which lands on the icons"
            end

            Picker.Close()

            if #notes == 0 then return nil, "no edges could be read — the panel may not be laid out yet" end
            if #faults > 0 then return false, table.concat(faults, "; ") end
            return true, table.concat(notes, ", ")
        end,
    },
    {
        id = "bottom-row", item = "VERIFY-10", label = "The bottom row still fits at 660 wide",
        -- UI-16 put a second button ("New set") into a row that was already full, and paid for it by
        -- narrowing the name box. Whether that was enough is arithmetic across five frames at a fixed
        -- window width — and the failure does NOT present as a layout fault, because
        -- UIPanelButtonTemplate never shrinks a label that no longer fits: it lets the text run out
        -- under the button's own edge. So an overflowed row reads as a button with a strangely
        -- clipped word on it, which nobody reports as "the window is too narrow".
        run = function()
            if not Kitbag.UI then return nil, "KitbagUI is not loaded" end
            local frame = _G.KitbagFrame
            if not frame then
                return nil, "the window has not been built — open /kit once, then run this"
            end

            -- Left to right, which is the order the row is anchored in and therefore the order a
            -- reader wants the numbers in.
            local row = {
                { name = "the name box", frame = _G.KitbagNameBox },
                { name = "Save",         frame = _G.KitbagSaveButton },
                { name = "New set",      frame = _G.KitbagNewSetButton },
                { name = "Options",      frame = _G.KitbagOptionsButton },
                { name = "Rules",        frame = _G.KitbagRulesButton },
            }
            for _, piece in ipairs(row) do
                if not piece.frame then
                    -- A missing name means the check cannot see the row at all, which is a broken
                    -- check rather than a condition to skip past.
                    return false, piece.name .. " has no global name, so the row cannot be measured"
                end
            end

            local faults, notes = {}, {}

            -- 1. The row against itself. Every neighbour must clear the one before it; the pair that
            -- actually decides this is New set against Options, because that is the seam the second
            -- button was squeezed into.
            -- Most of these gaps are anchor constants and can only change if someone re-anchors the
            -- row; New set→Options is the real one, since those two are anchored from OPPOSITE edges
            -- of the window and nothing but the window's width holds them apart.
            for i = 2, #row do
                local before, after = row[i - 1], row[i]
                local gap = before.frame:GetRight() and after.frame:GetLeft()
                    and (after.frame:GetLeft() - before.frame:GetRight())
                if gap then
                    notes[#notes + 1] = string.format("%s→%s %d", before.name, after.name, gap)
                    if gap < 0 then
                        faults[#faults + 1] = string.format("%s overlaps %s by %d",
                            after.name, before.name, -gap)
                    end
                end
            end

            -- 2. The row against the window. Anchored to both edges, so this can only fail if the
            -- window is narrower than the row needs — which is the question the item actually asks.
            local inLeft = row[1].frame:GetLeft() and frame:GetLeft()
                and (row[1].frame:GetLeft() - frame:GetLeft())
            local inRight = row[#row].frame:GetRight() and frame:GetRight()
                and (frame:GetRight() - row[#row].frame:GetRight())
            if inLeft and inLeft < 0 then faults[#faults + 1] = "the name box runs off the left edge" end
            if inRight and inRight < 0 then faults[#faults + 1] = "Rules runs off the right edge" end

            -- 3. Each label inside its own button. The silent one: the text is not clipped by the
            -- frame, it simply draws past it, so a label that no longer fits looks like a label
            -- somebody typed badly.
            for i = 2, #row do
                local piece = row[i]
                local label = piece.frame.GetFontString and piece.frame:GetFontString()
                local strWidth = label and label.GetStringWidth and label:GetStringWidth()
                local width = piece.frame:GetWidth()
                if strWidth and width and strWidth > width - 8 then
                    faults[#faults + 1] = string.format("%q is %d wide in a %d button, so it clips",
                        tostring(piece.frame:GetText()), math.floor(strWidth + 0.5),
                        math.floor(width + 0.5))
                end
            end

            if #notes == 0 then
                return nil, "no edges could be read — the window may not be laid out yet"
            end
            if #faults > 0 then return false, table.concat(faults, "; ") end
            -- The numbers on a PASS, not just "ok": a 2-pixel gap and a 20-pixel gap are both passes
            -- and mean very different things to whoever adds the next control to this row.
            return true, string.format("window %d wide; gaps %s",
                math.floor(frame:GetWidth() + 0.5), table.concat(notes, ", "))
        end,
    },
    {
        id = "new-set-selected", item = "VERIFY-10",
        label = "A new set is selected the moment it is made",
        -- The one check here that CHANGES something, and it is worth the cost. UI-16's "New set"
        -- button makes an empty set, and the next thing the player does is click slots to fill it in
        -- — which they will do to whichever set the inspector is showing. If the selection does not
        -- move at once, those clicks land on the PREVIOUS set: the gear goes somewhere real, so
        -- nothing errors and nothing looks broken, and the damage is found later in a set that
        -- quietly grew pieces nobody put there.
        --
        -- It presses the button rather than calling Sets.New, because Sets.New working is not the
        -- question — the wiring between the button and the selection is, and calling the store
        -- directly steps straight over it. The scratch set is deleted again before this returns.
        run = function()
            local UI, Sets = Kitbag.UI, Kitbag.Sets
            if not UI or not Sets then return nil, "KitbagUI is not loaded" end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end
            if not (UI.Select and UI.Selected) then
                return false, "UI.Selected is missing, so the selection cannot be read"
            end

            local window = _G.KitbagFrame
            local button = _G.KitbagNewSetButton
            local box    = _G.KitbagNameBox
            if not (window and button and box) then
                return nil, "the window has not been built — open /kit once, then run this"
            end

            -- Never a name a player would choose, and refused outright if it somehow exists: this
            -- check deletes what it made, and deleting someone's real set to answer a layout
            -- question is not a trade worth making.
            local scratch = "KitbagVerifyScratch"
            if (Kitbag.char.sets or {})[scratch] then
                return nil, string.format("a set called %q already exists — delete it, since this "
                    .. "check would otherwise destroy it on the way out", scratch)
            end

            -- Shown, for VERIFY-8's reason: UI.Refresh returns immediately while the window is
            -- hidden, so the inspector would be reporting whatever it drew last and the check would
            -- fail naming two real sets. A check must put the addon in the state its question is about.
            local wasShown = window:IsShown()
            if not wasShown then
                window:Show()
                UI.Refresh()
            end

            local restore, typed = UI.Selected(), box:GetText()

            -- What existed BEFORE, so the cleanup can delete what appeared rather than what this
            -- check hoped would appear. The set is named by the client, not by us: the name goes
            -- through a real edit box and Core.CleanName, so an edit box letter limit or any future
            -- tidying of the typed name would produce a set under a name we are not holding.
            -- Deleting `scratch` would then delete nothing and leave litter in someone's
            -- SavedVariables permanently, which is the one failure a verification run must not have.
            local before = {}
            for name in pairs(Kitbag.char.sets or {}) do before[name] = true end

            box:SetText(scratch)

            -- Guarded so the cleanup below runs even if the click raises. Verify.Run would catch the
            -- error, but by then the scratch set is in SavedVariables for good.
            local clicked, err = pcall(function() button:Click() end)

            local added = {}
            for name in pairs(Kitbag.char.sets or {}) do
                if not before[name] then added[#added + 1] = name end
            end
            local landed = UI.Selected()
            local title  = _G.KitbagInspectorTitle and _G.KitbagInspectorTitle:GetText()

            for _, name in ipairs(added) do Sets.Delete(name) end
            local made = added[1]
            box:SetText(typed or "")
            box:ClearFocus()
            if restore then UI.Select(restore) end
            if not wasShown then window:Hide() end

            if not clicked then return false, "clicking New set errored: " .. tostring(err) end
            if not made then
                return false, "pressing New set with a name typed in the box made no set at all"
            end
            if #added > 1 then
                return false, "one click made " .. #added .. " sets: " .. table.concat(added, ", ")
            end
            -- Reported rather than judged. The set is the one that appeared either way, so the
            -- check still answers its question — but a name that came back different means the box
            -- or CleanName is altering what the player typed, which is worth knowing on its own.
            local renamed = (made ~= scratch)
                and string.format(" (typed %q, stored as %q)", scratch, made) or ""
            if landed ~= made then
                return false, string.format(
                    "the set was made but the selection stayed on %s — the next slot clicked would "
                    .. "land on the wrong set%s", tostring(landed), renamed)
            end
            if title ~= made then
                return false, string.format(
                    "the selection moved to %s but the inspector is still headed %s%s",
                    made, tostring(title), renamed)
            end
            -- Said plainly, because the check's own two chat lines arrive with it and otherwise read
            -- as something having happened to the character's sets.
            return true, string.format(
                "made, selected and drawn at once; the scratch set was deleted again%s "
                .. "(the two set messages above are this check's)", renamed)
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
            local Core, Sets, Inventory = Kitbag.Core, Kitbag.Sets, Kitbag.Inventory
            if not (Core and Sets and Inventory) then return nil, "the set modules are not loaded" end
            if not Kitbag.char then return nil, "no character bucket yet — not logged in" end

            -- Derived, never fabricated. The old version of this check handed the popup a sentence
            -- written by hand, which proved the popup DRAWS and said nothing at all about VERIFY-12's
            -- actual question — whether it names the right slots. A check that feeds its subject the
            -- answer can only confirm that the subject can echo.
            local equipped = Inventory.Equipped()
            local name, lost
            for _, candidate in ipairs(Sets.Names() or {}) do
                local dropped = Core.SaveLoss(Sets.Resolve(candidate), equipped)
                if dropped and #dropped > 0 then
                    name, lost = candidate, dropped
                    break
                end
            end
            if not name then
                return nil, "every set matches what you are wearing, so no save would drop anything"
            end

            local text = Sets.LossText(lost)
            local popup = _G.StaticPopup_Show("KITBAG_OVERWRITE", name, text, name)
            if not popup then return false, "StaticPopup_Show returned nothing" end

            -- What the player actually reads. The slot names come from Sets.LossText, which is pure
            -- and covered; this is the join nobody had checked — that the rendered dialog contains
            -- them rather than a truncated or differently-formatted line.
            local rendered = _G.StaticPopup1Text and _G.StaticPopup1Text:GetText()
            local window = _G.KitbagFrame
            local strata = string.format("%s strata %s; KitbagFrame strata %s",
                popup:GetName() or "popup", tostring(popup:GetFrameStrata()),
                window and tostring(window:GetFrameStrata()) or "(window not built)")
            _G.StaticPopup_Hide("KITBAG_OVERWRITE")

            if rendered and not rendered:find(text, 1, true) then
                return false, string.format(
                    "the popup does not show the slots it should: wanted %q in the dialog", text)
            end
            if rendered and not rendered:find(name, 1, true) then
                return false, string.format("the popup does not name the set %q it would overwrite", name)
            end
            return true, string.format("%s names %q losing: %s", strata, name, text)
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
        id = "inherit-menu-state", item = "VERIFY-13", label = "Inherit menu ticks right, and dies with the window",
        -- Two questions our own code answers by construction and cannot actually settle. The tick is
        -- `current == name`, so exactly one entry is ticked and it is the real parent — but that is a
        -- claim about the info table we hand Blizzard, not about the list frame it builds from it.
        -- And the window's OnHide calls CloseDropDownMenus, which is our INTENT; DropDownList1 is not
        -- a child of ours, so whether it actually goes is Blizzard's answer to give. A menu that
        -- outlives its window is left floating over the game with nothing behind it.
        run = function()
            local UI, Sets = Kitbag.UI, Kitbag.Sets
            if not UI or not Sets then return nil, "KitbagUI is not loaded" end
            local menu, window = _G.KitbagParentMenu, _G.KitbagFrame
            if not menu or not window then
                return nil, "the menu is built with the main window — open /kit once, then run this"
            end
            if not UI.Selected then return false, "UI.Selected is missing, so the parent is unreadable" end

            local selected = UI.Selected()
            if not selected then return nil, "no set is selected, so the menu has no parent to tick" end
            local parent = Sets.ParentOf(selected)

            local wasShown = window:IsShown()
            if not wasShown then window:Show() end

            _G.ToggleDropDownMenu(1, nil, menu, window, 0, 0)
            local list = _G.DropDownList1
            if not list or not list:IsShown() then
                _G.CloseDropDownMenus()
                if not wasShown then window:Hide() end
                return nil, "the menu did not open — this set may have nothing it can inherit from"
            end

            -- Exactly one tick, and on the right entry. "Nothing" carries it when there is no parent,
            -- which is the case most likely to be got wrong: a set inheriting from nothing still has
            -- a current parent, and it is spelled nil.
            local wanted = parent or "Nothing"
            local ticked, checkedCount = nil, 0
            for i = 1, (_G.UIDROPDOWNMENU_MAXBUTTONS or 8) do
                local button = _G["DropDownList1Button" .. i]
                if button and button:IsShown() then
                    local check = _G["DropDownList1Button" .. i .. "Check"]
                    -- notCheckable entries (the "Inherit from" title) hide their check texture.
                    if check and check:IsShown() then
                        checkedCount = checkedCount + 1
                        ticked = button:GetText()
                    end
                end
            end

            _G.CloseDropDownMenus()

            -- The teardown, which is the half that has actually never been observed: hide the window
            -- and the menu must go with it. Reopened first, because CloseDropDownMenus above would
            -- otherwise make this pass for the wrong reason.
            _G.ToggleDropDownMenu(1, nil, menu, window, 0, 0)
            local reopened = list:IsShown()
            window:Hide()
            local orphaned = reopened and list:IsShown()
            -- Put the window back the way it was found, and REFRESH it: Show alone is not the inverse
            -- of Hide here, because the window is normally raised through UI.Toggle, which redraws.
            -- A check that leaves the window showing a stale list has caused the next bug report.
            if wasShown then
                window:Show()
                if UI.Refresh then UI.Refresh() end
            end

            local faults = {}
            if checkedCount ~= 1 then
                faults[#faults + 1] = string.format("%d entries ticked, expected exactly 1", checkedCount)
            elseif ticked ~= wanted then
                faults[#faults + 1] = string.format("the tick is on %q but the parent is %q",
                    tostring(ticked), tostring(wanted))
            end
            if orphaned then
                faults[#faults + 1] = "the menu outlived the window — it is left floating over the game"
            end

            if #faults > 0 then return false, table.concat(faults, "; ") end
            return true, string.format("tick on %q (parent %s); the menu closes with the window",
                tostring(ticked), parent and ("\"" .. parent .. "\"") or "none")
        end,
    },
    {
        id = "import-button", item = "VERIFY-14", label = "Import button reads and fits",
        -- The one control in the window whose ABSENCE is as load-bearing as its presence. Its count
        -- is pinned against a real ItemRack file by Tests/import_test.lua, so a DIFFERENT number on
        -- screen is the interesting failure: it means the window is reading a different world than
        -- the tests are. The rest is clipping and clearance, which are measurements, not opinions.
        run = function()
            local Sets = Kitbag.Sets
            if not Sets or not Sets.ImportOffer then return nil, "KitbagSets is not loaded" end
            local button = _G.KitbagImportButton
            if not button then
                return nil, "the button is built with the main window — open /kit once, then run this"
            end

            local offer = Sets.ImportOffer()
            local shown = button:IsShown()

            -- Presence and absence must agree with the offer. Both directions matter: a button that
            -- lingers after the import is done invites a second one, and a missing button on a
            -- character with sets to bring across is a feature nobody can find.
            if not offer then
                if shown then
                    return false, "there is nothing to import, but the button is still showing"
                end
                return nil, "nothing to import on this character — the button is correctly absent"
            end
            if not shown then
                return false, string.format("%d set(s) to import, but the button is hidden", offer.count)
            end

            local faults = {}
            local wanted = string.format("Import %d set%s from ItemRack",
                offer.count, offer.count == 1 and "" or "s")
            local text = button:GetText()
            if text ~= wanted then
                faults[#faults + 1] = string.format("label reads %q, expected %q",
                    tostring(text), wanted)
            end

            -- Does it CLIP? UIPanelButtonTemplate does not shrink its text, it lets it run under the
            -- button's own edge, so the string width against the button width is the whole question.
            local label = button.GetFontString and button:GetFontString()
            local strWidth = label and label.GetStringWidth and label:GetStringWidth()
            local width = button:GetWidth()
            if strWidth and width then
                if strWidth > width - 8 then
                    faults[#faults + 1] = string.format(
                        "the label is %d wide in a %d button, so it clips",
                        math.floor(strWidth + 0.5), math.floor(width + 0.5))
                end
            end

            -- And does it clear its neighbours? It appears BETWEEN the status line and the name box,
            -- and only on some characters — which is precisely the layout nobody looks at on the
            -- characters where it never shows up.
            local notes = {}
            local status, nameBox = _G.KitbagStatusLine, _G.KitbagNameBox
            if status and status:GetBottom() and button:GetTop() then
                local gap = status:GetBottom() - button:GetTop()
                notes[#notes + 1] = string.format("clears the status line by %d", gap)
                if gap < 0 then faults[#faults + 1] = "it overlaps the status line above it" end
            end
            if nameBox and nameBox:GetTop() and button:GetBottom() then
                local gap = button:GetBottom() - nameBox:GetTop()
                notes[#notes + 1] = string.format("clears the name box by %d", gap)
                if gap < 0 then faults[#faults + 1] = "it overlaps the name box below it" end
            end

            if #faults > 0 then return false, table.concat(faults, "; ") end
            return true, string.format("%q, label %d wide in %d%s", wanted,
                math.floor((strWidth or 0) + 0.5), math.floor(width + 0.5),
                #notes > 0 and (", " .. table.concat(notes, ", ")) or "")
        end,
    },
    {
        id = "key-button", item = "VERIFY-16", label = "Keybinding button reads and fits",
        -- Two questions, and the cheap one is the more valuable. GEOMETRY: the button took the right
        -- end of the inherit button's row instead of the panel growing a row, and the left half of
        -- that row carries a set NAME — so the clearance between them is real, variable, and only
        -- wrong on the characters with long names, which is nobody's test character. LABEL: a button
        -- reading a key the set does not hold is the visible symptom of a binding that lost an
        -- arbitration in silence, which is precisely what Bindings.Set was rewritten to stop.
        run = function()
            local Sets = Kitbag.Sets
            if not Sets or not Sets.KeyOf then return nil, "KitbagSets is not loaded" end
            local button, inherit = _G.KitbagKeyButton, _G.KitbagInheritButton
            if not button then
                return nil, "the button is built with the main window — open /kit once, then run this"
            end
            if not button:IsShown() then
                return nil, "no set is selected, so there is nothing for it to bind — select one"
            end

            local faults, notes = {}, {}

            -- The label against the stored key, read through the same accessor the window uses. A
            -- separate reading of Kitbag.char.sets here would be a second reader of the schema and
            -- could agree with the button while both disagreed with the truth.
            local heading = _G.KitbagInspectorTitle
            local title = heading and heading:GetText()
            local stored = title and title ~= "" and Sets.KeyOf(title) or nil
            local text = button:GetText()
            local wanted = stored or "Key…"
            if text ~= wanted then
                faults[#faults + 1] = string.format("label reads %q but the set's key is %s",
                    tostring(text), stored and ("\"" .. stored .. "\"") or "unset")
            end
            notes[#notes + 1] = string.format("reads %q", tostring(text))

            -- Clipping. UIPanelButtonTemplate lets its text run under its own edge rather than
            -- shrinking, so a long chord — ALT-CTRL-SHIFT-F12 is bindable — simply spills.
            local label = button.GetFontString and button:GetFontString()
            local strWidth = label and label.GetStringWidth and label:GetStringWidth()
            local width = button:GetWidth()
            if strWidth and width then
                notes[#notes + 1] = string.format("%d wide in %d",
                    math.floor(strWidth + 0.5), math.floor(width + 0.5))
                if strWidth > width - 8 then
                    faults[#faults + 1] = "the label clips its own button"
                end
            end

            -- And the neighbour. The inherit button hides itself when there is nothing to inherit
            -- from, so a gap can only be measured when it is actually up — and "it was hidden" is a
            -- note rather than a pass, because a check that quietly measures nothing reads green.
            if inherit and inherit:IsShown() and inherit:GetRight() and button:GetLeft() then
                local gap = button:GetLeft() - inherit:GetRight()
                notes[#notes + 1] = string.format("clears the inherit button by %d",
                    math.floor(gap + 0.5))
                if gap < 0 then
                    faults[#faults + 1] = "it overlaps the inherit button beside it"
                end
            else
                notes[#notes + 1] = "the inherit button is hidden, so the gap was not measured"
            end

            if #faults > 0 then return false, table.concat(faults, "; ") end
            return true, table.concat(notes, ", ")
        end,
    },
    {
        id = "copy-button", item = "VERIFY-17", label = "The action row fits its third button",
        -- UI-20 put a third button on a row built for two, and the item is right that the row is the
        -- likelier failure than the menu: Equip kept its width, so Delete is what paid for Copy. The
        -- whole row is measured rather than the new button alone, because a check that looked only at
        -- what arrived would report a tidy pass over the control the change actually put at risk.
        --
        -- Two failures, neither of which presents as a layout fault. A button running past the
        -- panel's edge is clipped by the panel and simply looks short; a label too wide for its
        -- button is let out under the button's own edge by UIPanelButtonTemplate rather than being
        -- shrunk, so it reads as an odd label. Both are arithmetic, and both are invisible to the
        -- eye that is looking for a gap.
        run = function()
            local Sets = Kitbag.Sets
            if not Sets or not Sets.CopyChoices then return nil, "KitbagSets is not loaded" end
            local copy = _G.KitbagCopyButton
            if not copy then
                return nil, "the button is built with the main window — open /kit once, then run this"
            end

            -- The row's other two are unnamed, and are reached through the panel that owns them
            -- rather than by being given globals of their own: they are neighbours in this
            -- measurement, not subjects of it, and a global exists forever.
            local panel = copy:GetParent()
            local equip, delete = panel and panel.equip, panel and panel.delete
            if not (equip and delete) then
                return nil, "the action row is not built — open /kit once, then run this"
            end

            -- The set the doll is actually headed with, for the key-button check's reason: reading
            -- the selection a second way here would be a second reader that could agree with the
            -- button while both disagreed with what is on screen.
            local heading = _G.KitbagInspectorTitle
            local title = heading and heading:GetText()
            if not title or title == "" then
                return nil, "no set is selected, so the action row is not drawn — select one"
            end

            -- Presence and absence are both assertions. The button hides itself on a
            -- single-character account, which is exactly the account on which nobody would ever
            -- notice it lingering — so "correctly absent" is reported as a SKIP with its reason
            -- rather than as a pass, since nothing about the ROW was measured in that case.
            local choices = Sets.CopyChoices(title)
            local shown = copy:IsShown()
            if #choices == 0 then
                if shown then
                    return false, "there is nobody to copy to, but the button is showing anyway"
                end
                return nil, "no other character has been seen on this account — the button is "
                    .. "correctly absent, and the row was not measured"
            end
            if not shown then
                return false, string.format(
                    "%d character(s) could take a copy, but the button is hidden", #choices)
            end

            local faults, notes = {}, {}
            local function round(n) return math.floor(n + 0.5) end

            -- Does each label fit its own button? Copy's is fixed text, but Equip and Delete share
            -- the row and a client with a different font would spill any of the three.
            local function fits(button, name)
                local label = button.GetFontString and button:GetFontString()
                local strWidth = label and label.GetStringWidth and label:GetStringWidth()
                local width = button:GetWidth()
                if not (strWidth and width) then return end
                notes[#notes + 1] = string.format("%s %d in %d", name, round(strWidth), round(width))
                if strWidth > width - 8 then
                    faults[#faults + 1] = string.format(
                        "%s's label is %d wide in a %d button, so it clips",
                        name, round(strWidth), round(width))
                end
            end
            fits(equip, "Equip")
            fits(delete, "Delete")
            fits(copy, "Copy to…")

            -- And do the three clear each other and the panel they sit in? The row is anchored
            -- left-to-right, so an overflow lands on the panel's right edge and nowhere else.
            local function gap(left, right, what)
                if not (left:GetRight() and right:GetLeft()) then return end
                local d = right:GetLeft() - left:GetRight()
                notes[#notes + 1] = string.format("%s %d", what, round(d))
                if d < 0 then
                    faults[#faults + 1] = what .. " overlap by " .. round(-d)
                end
            end
            gap(equip, delete, "Equip|Delete")
            gap(delete, copy, "Delete|Copy")

            if panel:GetRight() and copy:GetRight() then
                local edge = panel:GetRight() - copy:GetRight()
                notes[#notes + 1] = string.format("clears the panel edge by %d", round(edge))
                if edge < 0 then
                    faults[#faults + 1] = string.format(
                        "the row runs %d past the panel's right edge", round(-edge))
                end
            end

            if #faults > 0 then return false, table.concat(faults, "; ") end
            return true, string.format("%d target(s); %s", #choices, table.concat(notes, ", "))
        end,
    },
    {
        id = "rule-list-layout", item = "VERIFY-11", label = "The rule list's bar clears its X buttons",
        -- The failure this measures is not cosmetic and does not read as a layout fault. A scroll bar
        -- sitting on every row's X makes delete look BROKEN, so it gets reported as "the X does
        -- nothing" and the next session goes hunting in the click handler, which is fine.
        run = function()
            local RulesUI = Kitbag.RulesUI
            if not RulesUI then return nil, "KitbagRulesUI is not loaded" end
            local list = _G.KitbagRulesList
            local x    = _G.KitbagRuleRow1Remove
            local bar  = _G.KitbagRulesScrollFrameScrollBar
            if not (list and x) then
                return nil, "the rule list is built with the editor — open /kit rules once, then run this"
            end
            if not bar then return false, "the rule list has no scroll bar frame to measure" end

            local rules = Kitbag.char and Kitbag.char.rules or {}
            local count = #rules

            local clearance = bar:GetLeft() and x:GetRight() and (bar:GetLeft() - x:GetRight())
            if not clearance then
                return nil, "the rule editor has not been laid out yet — open /kit rules, then run this"
            end

            -- Whether the bar is SHOWN depends on the rule count, but its position does not, so the
            -- clearance is worth measuring either way. Reporting the count with it is what lets a
            -- reader tell "measured with the bar up" from "measured with it hidden".
            local shown = bar:IsShown()
            local detail = string.format("bar clears row 1's X by %d (%d rule(s), bar %s)",
                clearance, count, shown and "showing" or "hidden")

            if clearance < 0 then
                return false, string.format(
                    "the scroll bar overlaps row 1's X by %d — delete will read as a dead button "
                    .. "(%d rule(s), bar %s)", -clearance, count, shown and "showing" or "hidden")
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
    {
        id = "swap-record", item = "BUG-9", label = "A failed swap records why",
        -- Diagnostic rather than cosmetic, which is what makes it worth a check: a session spent
        -- reproducing the mount failure against a build that cannot record the answer reads exactly
        -- like the fault refusing to reproduce. UI-15's blank panel was the previous build still
        -- deployed; this is that lesson pre-empted rather than learned again.
        run = function()
            local Equip = Kitbag.Equip
            if not Equip or not Equip.Reason then
                return false, "Equip.Reason is missing — this build cannot say why a swap failed"
            end
            if not Equip.Reason({ to = 17 }, "You are mounted."):find("You are mounted.", 1, true) then
                return false, "the client's own wording is not being carried into the report"
            end
            if not Equip.BUSY_LIMIT then
                return false, "Equip.BUSY_LIMIT is missing — this build can still wedge (BUG-11)"
            end
            -- BUG-13. Two instances have now said "picked up, but the bag move had not completed",
            -- and the number that separates its candidate causes is the bag room at the moment it
            -- failed. Asked of the RUNNING build, because a session spent reproducing BUG-13 against
            -- a build that cannot record the answer reads exactly like the fault not reproducing —
            -- UI-15's blank panel was that lesson the expensive way, and it was a stale deploy.
            local Core = Kitbag.Core
            local words = Core and Core.StateWords({ room = 0, need = 1 })
            if not (words and words:find("bag room 0 of 1 needed", 1, true)) then
                return false, "this build does not record bag room — a BUG-13 repro against it "
                    .. "cannot answer the question it is being run for"
            end
            -- Reported, not judged: whether an attempt has happened yet is the reader's business,
            -- and "nothing attempted" is the honest answer at the start of a session.
            local swaps = (Kitbag.char and Kitbag.char.swaps) or {}
            local last = swaps[1]
            if not last then return true, "ready; nothing attempted yet this character" end
            -- The conditions come through too, and through Core.StateWords rather than a second copy
            -- of the wording: this line is read in the client, and sending someone for a dump to
            -- learn the one fact that decides BUG-9 costs a reload the check already had in hand.
            local words = Kitbag.Core and Kitbag.Core.StateWords(last.state)
            return true, string.format("last: %s %s%s%s", tostring(last.set),
                last.ok and "succeeded" or "FAILED",
                last.reason and (" — " .. tostring(last.reason)) or "",
                words and (" [" .. words .. "]") or "")
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
