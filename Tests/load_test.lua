-- KitbagLoad — execute every shipped file against a mock client.
--
-- Tests/toc_test.lua compiles each file with loadfile(), which catches a missing `end` and nothing
-- else: loadfile does not run a single line. So a typo'd global, a wrong load order, or a method
-- called on a nil widget survives the whole suite and is found by a human doing /reload.
--
-- That gap is the whole of EPIC-VERIFY's risk. The frames in this addon have never been drawn, and
-- the failure mode for an unexecuted frame is not a subtle misbehaviour — it is a nil-index error at
-- load that takes the module out entirely and silently.
--
-- So this file stubs enough of the WoW API to let every module RUN its load path, in .toc order,
-- and asserts that none of them error. What it can prove: the module executes, its globals resolve,
-- and it reads its dependencies out of Kitbag successfully in the order the .toc declares. What it
-- CANNOT prove: that anything looks right, that a Blizzard template exists, or that a texture path
-- resolves. Those still want eyes — see EPIC-VERIFY.
--
-- The stubs are deliberately NOT a catch-all metatable over _G. An unknown global returning a
-- silent no-op would hide exactly the typo this file exists to catch, so an unstubbed API stays nil
-- and errors on use, and the fix is to add it here — which makes this list a by-product worth
-- having: the complete set of client APIs Kitbag touches at load.
--
-- Usage: lua Tests/load_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")

H.start("Kitbag load")

-- ---------------------------------------------------------------------------
-- The mock client
-- ---------------------------------------------------------------------------

-- Getters whose return value is USED in arithmetic or string work at load time. A generic stub
-- returning a table would fail on the first `width / 2`, and returning 0 for everything would fail
-- on the first `:GetName() .. "Suffix"`. Typed by name, which is the only signal available.
local NUMBER_GETTERS = {
    GetWidth = true, GetHeight = true, GetScale = true, GetEffectiveScale = true,
    GetLeft = true, GetRight = true, GetTop = true, GetBottom = true,
    GetNumPoints = true, GetStringWidth = true, GetTextWidth = true, GetID = true,
    GetFrameLevel = true, GetAlpha = true, GetValue = true,
}
local STRING_GETTERS = { GetName = true, GetText = true, GetFrameStrata = true, GetObjectType = true }
local BOOL_GETTERS = {
    IsShown = true, IsVisible = true, IsMouseOver = true, GetChecked = true,
    IsUserPlaced = true, IsForbidden = true,
}
-- Scripts and shown-state are REMEMBERED for the reason event registration is: they are answers this
-- suite asks questions of. A generic SetScript that discards its handler makes every button in the
-- addon undrivable from here, which leaves the wiring between a click and the index it acts on — the
-- one part of the UI that pure tests cannot reach and the one part EPIC-VERIFY keeps asking about —
-- checkable only by a person clicking it in the client.
--
-- Click() runs OnClick the way the client does, with the widget as self, so a handler reading
-- `self:GetParent().ruleIndex` is exercised rather than simulated.
-- Forward-declared here rather than beside its definition: the widget method tables below close over
-- it, and a local declared after them is a different variable that reads nil at call time.
local newWidget

-- Parenting is recorded in both directions. Upwards because every row button reads
-- `self:GetParent().ruleIndex`; downwards because hiding a frame in the client hides its children and
-- runs their OnHide, which is how the keybinding capture releases the keyboard (VERIFY-16).
local function adopt(parent, child)
    if not parent then return child end
    rawset(child, "_parent", parent)
    local children = rawget(parent, "_children")
    if not children then children = {}; rawset(parent, "_children", children) end
    children[#children + 1] = child
    return child
end


-- Declared in two steps so the table can call its own members: Hide recurses through children.
local SCRIPT_METHODS
SCRIPT_METHODS = {
    SetScript = function(self, name, fn)
        local scripts = rawget(self, "_scripts")
        if not scripts then scripts = {}; rawset(self, "_scripts", scripts) end
        scripts[name] = fn
    end,
    GetScript = function(self, name)
        local scripts = rawget(self, "_scripts")
        return scripts and scripts[name] or nil
    end,
    HasScript = function() return true end,
    -- Parenting is real, not manufactured. Every row button in the addon reads
    -- `self:GetParent().ruleIndex` — a GetParent handing back a fresh widget answers nil to
    -- that and the handler quietly does nothing, which is a test that clicks a button and
    -- asserts against the silence that follows.
    GetParent = function(self) return rawget(self, "_parent") end,
    -- Text is remembered too, and for a sharper reason than convenience: STRING_GETTERS makes
    -- GetText hand back the widget's NAME, which is a string, so an assertion about what a row
    -- says passes or fails on an accident of naming rather than on what was drawn. What a row
    -- says is the other half of VERIFY-11's offset question — the `[editing]` tag has to land on
    -- the line the editor actually opened.
    -- Named font strings and textures are published to _G the way CreateFrame publishes named
    -- frames. The client does this and the mock did not, so `KitbagInspectorTitle` — the addon's
    -- own evidence of WHICH set the inspector drew, named for exactly that reason — did not exist
    -- outside the game, and the one question worth asking of the inspector could not be asked.
    CreateFontString = function(self, name)
        local child = newWidget(name)
        adopt(self, child)
        if name then _G[name] = child end
        return child
    end,
    CreateTexture = function(self, name)
        local child = newWidget(name)
        adopt(self, child)
        if name then _G[name] = child end
        return child
    end,
    SetText = function(self, text) rawset(self, "_text", text) end,
    GetText = function(self) return rawget(self, "_text") or rawget(self, "_name") or "" end,
    -- Anchors are remembered for the reason scripts and parents are: they are an answer this suite
    -- asks a question OF. The mock cannot lay a window out — GetLeft and GetRight answer 0 for
    -- everything, and always will — so "is this control centred under that one" is not a sum that can
    -- be done here. It is a question about what the frame was ANCHORED TO, and a SetPoint that
    -- discards its arguments is a client that cannot be asked it.
    SetPoint = function(self, point, relativeTo, relativePoint, x, y)
        -- Blizzard's own short forms: SetPoint("CENTER"), SetPoint("TOP", parent). Normalised on the
        -- way in rather than at every read, so an assertion never has to know which form was used.
        if type(relativeTo) == "string" then
            relativeTo, relativePoint, x, y = nil, relativeTo, relativePoint, x
        end
        local points = rawget(self, "_points")
        if not points then points = {}; rawset(self, "_points", points) end
        points[#points + 1] = {
            point = point, relativeTo = relativeTo, relativePoint = relativePoint or point,
            x = x or 0, y = y or 0,
        }
    end,
    ClearAllPoints = function(self) rawset(self, "_points", {}) end,
    GetNumPoints = function(self) return #(rawget(self, "_points") or {}) end,
    GetPoint = function(self, index)
        local anchor = (rawget(self, "_points") or {})[index or 1]
        if not anchor then return nil end
        return anchor.point, anchor.relativeTo, anchor.relativePoint, anchor.x, anchor.y
    end,
    Click = function(self, ...)
        local scripts = rawget(self, "_scripts")
        local fn = scripts and scripts.OnClick
        if fn then return fn(self, ...) end
    end,
    -- Show/Hide track, because several modules return early when their frame is hidden — KitbagUI's
    -- refresh does, and a check that ran against a hidden window once reported a FAIL naming two real
    -- sets for no reason at all (VERIFY-8). A mock that always answers "hidden" reproduces that.
    --
    -- Hiding also reaches DOWN, the way the client does: a frame going away takes its children with
    -- it and their OnHide scripts run. Kitbag depends on that in one place where the failure is
    -- severe — the keybinding capture releases the keyboard from the button's OnHide, and a mock that
    -- only hides the frame it was asked about would show that teardown passing while a real client
    -- was left deaf (VERIFY-16).
    Show = function(self)
        rawset(self, "_shown", true)
        local script = SCRIPT_METHODS.GetScript(self, "OnShow")
        if script then script(self) end
    end,
    Hide = function(self)
        rawset(self, "_shown", false)
        local script = SCRIPT_METHODS.GetScript(self, "OnHide")
        if script then script(self) end
        for _, child in ipairs(rawget(self, "_children") or {}) do
            SCRIPT_METHODS.Hide(child)
        end
    end,
    -- Enabled-state is tracked, and DEFAULTS TO TRUE the way a real widget does. It used to sit in
    -- BOOL_GETTERS answering false to everything, which is worse than useless for UI-19's question:
    -- "is Equip greyed while you are dead" would have passed against a window that greys every
    -- control it owns, and greying everything is precisely the easy, wrong version of that feature.
    Enable = function(self) rawset(self, "_enabled", true) end,
    Disable = function(self) rawset(self, "_enabled", false) end,
    SetEnabled = function(self, on) rawset(self, "_enabled", on and true or false) end,
    IsEnabled = function(self) return rawget(self, "_enabled") ~= false end,
    SetShown = function(self, shown) rawset(self, "_shown", shown and true or false) end,
    IsShown = function(self) return rawget(self, "_shown") and true or false end,
    IsVisible = function(self) return rawget(self, "_shown") and true or false end,
}

-- Event registration is REMEMBERED rather than stubbed, because it is the one client answer this
-- suite asks a question OF. Every other method here may return a plausible nothing; a generic
-- IsEventRegistered returning a truthy widget would make "the client accepted PLAYER_UNGHOST" pass
-- against a frame that never asked for it, which is the exact silence the assertion exists to break.
local EVENT_METHODS = {
    RegisterEvent = function(self, event)
        local events = rawget(self, "_events")
        if not events then events = {}; rawset(self, "_events", events) end
        events[event] = true
    end,
    UnregisterEvent = function(self, event)
        local events = rawget(self, "_events")
        if events then events[event] = nil end
    end,
    UnregisterAllEvents = function(self) rawset(self, "_events", {}) end,
    IsEventRegistered = function(self, event)
        local events = rawget(self, "_events")
        return (events and events[event]) and true or false
    end,
}



local widgetMeta
widgetMeta = {
    __index = function(widget, key)
        -- Fields the module set itself are found before __index runs, so anything reaching here is a
        -- client method. Manufactured on demand and cached, so `f:SetPoint` twice is the same
        -- function and a module storing a method reference still works.
        local method
        if SCRIPT_METHODS[key] then
            method = SCRIPT_METHODS[key]
        elseif EVENT_METHODS[key] then
            method = EVENT_METHODS[key]
        elseif NUMBER_GETTERS[key] then
            method = function() return 0 end
        elseif STRING_GETTERS[key] then
            method = function(self) return rawget(self, "_name") or "MockWidget" end
        elseif BOOL_GETTERS[key] then
            method = function() return false end
        else
            -- Everything else returns a fresh widget, so CreateTexture/CreateFontString chains work
            -- and a setter's return value is harmless if used.
            method = function() return newWidget() end
        end
        rawset(widget, key, method)
        return method
    end,
    -- A last-resort net: a widget that reaches arithmetic means a getter was not typed above. 0
    -- keeps the load running so the run reports every module rather than stopping at the first.
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __unm = function() return 0 end,
    __concat = function() return "" end,
    __lt = function() return false end, __le = function() return false end,
}

newWidget = function(name)
    local widget = setmetatable({ _name = name }, widgetMeta)
    return widget
end

local G = _G

G.UIParent = newWidget("UIParent")
G.WorldFrame = newWidget("WorldFrame")
G.GameTooltip = newWidget("GameTooltip")
-- Where the addon says things. Not needed by any module's LOAD path — it is here because exercising
-- a function that reports to the player reaches it, and swallowing the line is right for a test: what
-- matters is that saying it does not error, not what was said.
G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
G.UISpecialFrames = {}
G.SlashCmdList = {}
G.StaticPopupDialogs = {}
G.StaticPopup_Show = function() return newWidget("StaticPopup1") end
G.StaticPopup_Hide = function() end
G.DropDownList1 = newWidget("DropDownList1")
G.InterfaceOptions_AddCategory = function() end
-- The initialiser is KEPT and run when the menu is opened, which is what the client does with it.
-- Discarding it made every dropdown in the addon a black box from here: the entries — their text,
-- what is greyed, and what each one DOES when picked — are built inside these callbacks, and the
-- menus are where two of the addon's subtler rules live (a greyed entry carries its reason, and a
-- menu acts on the set it was OPENED on rather than on whatever is selected when it is clicked).
G.UIDropDownMenu_Initialize = function(frame, init) rawset(frame, "_init", init) end
G.UIDropDownMenu_SetWidth = function() end
G.UIDropDownMenu_SetText = function() end
G.UIDropDownMenu_AddButton = function() end
G.UIDropDownMenu_CreateInfo = function() return {} end
G.ToggleDropDownMenu = function(level, value, frame)
    local init = frame and rawget(frame, "_init")
    if init then init(frame, level or 1) end
end
G.CloseDropDownMenus = function() end

G.CreateFrame = function(_, name, parent, _)
    local frame = newWidget(name)
    adopt(parent, frame)
    if name then G[name] = frame end
    return frame
end

-- Blizzard's FauxScrollFrame, which is the mechanism behind both scrolling lists in the addon: the
-- rows stay put and the data moves through them. The offset is kept ON the frame the way the real one
-- keeps it, so a test can scroll a list by calling the same function the client's scroll bar calls
-- and then drive the rows at that offset — which is the whole of what VERIFY-11 has never been able
-- to exercise outside the game.
G.FauxScrollFrame_SetOffset = function(frame, offset) rawset(frame, "_offset", offset or 0) end
G.FauxScrollFrame_GetOffset = function(frame) return rawget(frame, "_offset") or 0 end
G.FauxScrollFrame_Update = function() end
G.FauxScrollFrame_OnVerticalScroll = function() end

G.hooksecurefunc = function() end
G.tinsert = table.insert
G.tremove = table.remove
G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
G.strsplit = function(_, s) return s end
G.strtrim = function(s) return (tostring(s):match("^%s*(.-)%s*$")) end
G.format = string.format
G.date = function() return "mock-date" end
G.time = function() return 0 end
G.GetTime = function() return 0 end
-- print is NOT stubbed here: the harness reports through it, and silencing it globally makes a
-- failing run look like an empty one. It is muted around the load loop below instead.
local realPrint = print

-- Client queries. Values are chosen to be the LEAST convenient plausible answer where there is a
-- choice — nil from GetItemInfo especially, since "uncached item" is the state this addon must
-- never mistake for "not a two-hander".
G.GetBuildInfo = function() return "1.15.9", "69109", "mock", 11509 end
G.GetAddOnMetadata = function() return "0.1.0" end
G.GetLocale = function() return "enUS" end
G.UnitName = function() return "Mock" end
G.UnitClass = function() return "Druid", "DRUID" end
G.UnitLevel = function() return 60 end
G.GetRealmName = function() return "Mockrealm" end
G.GetRealZoneText = function() return "Mockzone" end
G.GetInventoryItemLink = function() return nil end
G.GetInventoryItemTexture = function() return nil end
G.GetInventoryItemCooldown = function() return 0, 0, 0 end
G.GetInventoryItemDurability = function() return nil end
G.GetInventorySlotInfo = function() return 1, "Interface\\Mock" end
G.GetItemInfo = function() return nil end
G.GetItemInfoInstant = function() return nil end
G.GetContainerNumSlots = function() return 0 end
G.GetContainerItemLink = function() return nil end
G.GetContainerNumFreeSlots = function() return 0, 0 end
G.GetNumShapeshiftForms = function() return 0 end
G.GetShapeshiftFormInfo = function() return nil end
G.GetShapeshiftForm = function() return 0 end
G.InCombatLockdown = function() return false end
G.IsStealthed = function() return false end
G.IsMounted = function() return false end
G.IsResting = function() return false end
G.IsShiftKeyDown = function() return false end
-- The other two modifiers, reached only by the keybinding capture (UI-12): Core.BindingKey is handed
-- all three at once, so a missing one is a hard error the moment a key is pressed in capture mode.
G.IsControlKeyDown = function() return false end
G.IsAltKeyDown = function() return false end
G.IsInInstance = function() return false, "none" end
G.UnitBuff = function() return nil end
G.GetSpellInfo = function() return nil end
G.PickupInventoryItem = function() end
G.PutItemInBackpack = function() end
G.PutItemInBag = function() end
G.EquipCursorItem = function() end
G.ClearCursor = function() end
G.CursorHasItem = function() return false end
G.ReloadUI = function() end
G.Screenshot = function() end
G.PlaySound = function() end
G.SetBinding = function() return true end
-- Reached only by exercising Bindings.Apply, not by any module's load path — added when the import
-- test below first called it. Worth the note: a per-set binding points a key at a hidden click
-- button rather than at a binding name, so this and SetBinding are different APIs doing similar work.
G.SetBindingClick = function() return true end
G.SaveBindings = function() end
G.GetBindingKey = function() return nil end
G.GetBindingAction = function() return "" end
G.CreateMacro = function() end
G.GetMacroIndexByName = function() return 0 end
G.EditMacro = function() end
G.Minimap = newWidget("Minimap")
-- LibStub is deliberately left absent, which is the majority case: most players do not run a
-- LibDataBroker display. KitbagBroker must register on the namespace anyway and degrade quietly, so
-- leaving this nil exercises the path that ships to most people rather than the lucky one.

G.WOW_PROJECT_ID = 2
G.WOW_PROJECT_CLASSIC = 2
G.WOW_PROJECT_MAINLINE = 1
G.WOW_PROJECT_CATACLYSM_CLASSIC = 14
G.WOW_PROJECT_MISTS_CLASSIC = 19

G.NORMAL_FONT_COLOR = { r = 1, g = 0.82, b = 0 }
G.HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1 }
G.RED_FONT_COLOR = { r = 1, g = 0.1, b = 0.1 }
G.GREEN_FONT_COLOR = { r = 0.1, g = 1, b = 0.1 }
G.INVSLOT_FIRST_EQUIPPED = 1
G.INVSLOT_LAST_EQUIPPED = 19
G.NUM_BAG_SLOTS = 4
G.BACKPACK_CONTAINER = 0
G.BANK_CONTAINER = -1
G.NUM_BANKBAGSLOTS = 6

-- ---------------------------------------------------------------------------
-- Run every module, in .toc order
-- ---------------------------------------------------------------------------
--
-- Order is read from Kitbag.toc rather than hardcoded, so this test cannot drift from the manifest
-- it is meant to be checking. Every module reads its dependencies out of Kitbag at load time, which
-- makes a wrong order a nil-index error — exactly what running them catches and compiling them does
-- not.

local function tocOrder(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local order = {}
    for line in f:lines() do
        line = line:gsub("^\239\187\191", ""):gsub("\r$", ""):match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:match("%.lua$") then
            order[#order + 1] = line
        end
    end
    f:close()
    return order
end

-- The addon-private (..., table) pair the client passes each file. Absent under plain Lua, which is
-- why every module ends `Kitbag.X = X; return X` rather than relying on it.
G.Kitbag = nil

local results = {}
G.print = function() end   -- muted only while the addon runs, so its chatter is not test output
for _, name in ipairs(tocOrder("Kitbag.toc")) do
    local ok, err = pcall(dofile, name)
    results[#results + 1] = { name = name, ok = ok, err = err }
end
G.print = realPrint

for _, r in ipairs(results) do
    H.ok(r.ok, r.name .. " executes its load path against a mock client" ..
        (r.ok and "" or ": " .. tostring(r.err)))
end

-- The namespace is the addon's one sanctioned global, and every module hangs itself off it. A module
-- that ran but registered nothing is a module the next one will fail to find.
H.ok(type(G.Kitbag) == "table", "the Kitbag namespace exists after every module has run")

-- ---------------------------------------------------------------------------
-- The self-check's own checks actually run
-- ---------------------------------------------------------------------------
--
-- KitbagVerify's checks are the one part of the addon whose whole job is to run in the client, and
-- they are each wrapped in pcall — which makes them the easiest place in the codebase for a typo to
-- hide, because a check that calls a function that does not exist reports a tidy FAIL and looks like
-- it did its job. That is exactly what happened writing them: a call to a non-existent
-- Inventory.Locations reported "the check itself errored" and would have shipped as a red line
-- somebody believed.
--
-- So they are run here against the mock. The outcomes are meaningless — a stubbed client passes and
-- fails arbitrarily — but "this check referenced something that does not exist" is not meaningless,
-- and that is all this asserts.

-- Given a character that has a failed swap on record, so the swap-record check has something real to
-- report rather than falling straight into its "nothing attempted yet" branch. Set BEFORE the run,
-- because the check reads it at call time.
-- A db and a character bucket, built with the shipped DB.Load rather than by hand. The checks reach
-- much further into the addon now that the mock remembers Show/Hide — a frame that answers "hidden"
-- to everything sends most of them down their early-return path, where they touch nothing and prove
-- nothing — and several of them read the db as soon as they get past that. This is what they would
-- find on a real login, minus the gear.
Kitbag.db = Kitbag.DB.Load({})
Kitbag.char = Kitbag.DB.Character(Kitbag.db, "Mock - Mockrealm")
Kitbag.char.sets = { Mock = { slots = { [1] = "444:0:0:0:0:0:0" } } }
Kitbag.char.rules = {}
Kitbag.char.swaps = { {
    set = "FASTHOJ+TRAVEL", ok = false, reason = "stuck on Off hand",
    when = "2026-08-16 12:04:31",
    state = { combat = true, mounted = true, dead = false, casting = false },
} }

G.print = function() end
local verifyResults = Kitbag.Verify.Run()
G.print = realPrint

H.eq(#verifyResults, #Kitbag.Verify.CHECKS, "every registered check produced a result")

-- The swap-record check has to be self-sufficient IN THE CLIENT. /kit verify is the instrument the
-- Admiral runs without leaving the game, and a line naming the set and the reason but not the
-- conditions sends them for a dump to learn the one fact that decides BUG-9 (b) — which is a whole
-- extra reload to answer a question the check already had in its hand.
local swapDetail
for _, r in ipairs(verifyResults) do
    if r.id == "swap-record" then swapDetail = tostring(r.detail or "") end
end
H.ok(swapDetail and swapDetail:find("FASTHOJ+TRAVEL", 1, true),
    "the swap-record check names the set that was attempted")
H.ok(swapDetail and swapDetail:find("stuck on Off hand", 1, true), "…and why it ended")
H.ok(swapDetail and swapDetail:find("combat yes", 1, true),
    "…and the conditions it ended in, so /kit verify alone can settle BUG-9")
H.ok(swapDetail and swapDetail:find("dead no", 1, true),
    "…including the ones that were false, which are what rule a suspect OUT")

for _, r in ipairs(verifyResults) do
    local detail = tostring(r.detail or "")
    -- A nil-value error is a name that does not exist: a typo, or an API that was renamed. Any other
    -- error against a stub client is expected and says nothing.
    local missing = detail:find("a nil value", 1, true)
    H.ok(not missing, "check '" .. tostring(r.id) .. "' does not call something nonexistent" ..
        (missing and (": " .. detail) or ""))
end

-- ---------------------------------------------------------------------------
-- Every module used is a module bound
-- ---------------------------------------------------------------------------
--
-- Running the files catches a bad reference on a line that RUNS at load. Almost none of the UI does:
-- the frames build lazily inside Toggle/Refresh, so `Core.ScrollOffset(...)` inside a Refresh body of
-- a file that never wrote `local Core = Kitbag.Core` executes cleanly here and dies in the client the
-- first time the panel redraws. That exact mistake was made adding ScrollOffset, and passed the load
-- run above — which is what this check exists to close.
--
-- Source-scanned rather than executed, because the whole point is code that does not run at load.

local MODULES = {
    "Compat", "Core", "Import", "DB", "Inventory", "Equip", "Sets", "Debug",
    "Skin", "Icons", "Picker", "Flyout", "UI", "Trinkets", "Minimap",
    "Options", "Bindings", "Broker", "Verify",
}

local function sourceOf(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local text = f:read("*a")
    f:close()
    -- Comments are stripped first: this file's own prose is full of `Core.Plan` references, and a
    -- lint that fires on its own documentation gets switched off within a week.
    return (text:gsub("%-%-[^\n]*", ""))
end

-- Every name this file declares as a local. Collected from the whole `local a, b, c =` name list
-- rather than matched per-module: KitbagDebug binds three at once inside Capture, deliberately, and a
-- lint that only understands one-name declarations reports that correct code as broken. A checker
-- that cries wolf on the codebase's own idioms is one that gets deleted.
local function localsOf(src)
    local names = {}
    for list in src:gmatch("local%s+([%w_%s,]+)=") do
        for token in list:gmatch("[%w_]+") do names[token] = true end
    end
    return names
end

for _, name in ipairs(tocOrder("Kitbag.toc")) do
    local src = sourceOf(name)
    local bound = localsOf(src)
    for _, mod in ipairs(MODULES) do
        -- `Kitbag.Core.x` is already fully qualified and needs no local, so it is not a use.
        if src:find("[^%w_%.]" .. mod .. "%.") then
            H.ok(bound[mod], name .. " binds " .. mod .. " before using " .. mod .. ".something")
        end
    end
end

local EXPECTED = {
    "Compat", "Core", "Import", "DB", "Inventory", "Equip", "Sets", "Debug",
    "Skin", "Icons", "Picker", "Flyout", "UI", "Trinkets", "Minimap",
    "Options", "Bindings", "Broker", "Verify",
}
for _, key in ipairs(EXPECTED) do
    H.ok(type(G.Kitbag[key]) == "table", "Kitbag." .. key .. " is registered on the namespace")
end

-- Compat.ActionState — the conditions recorded when a swap fails (BUG-9). Exercised HERE because it
-- is the one function whose whole job is asking the client four questions, and the mock client is
-- the only place outside the game those can be asked at all.
local state = G.Kitbag.Compat.ActionState()
for _, key in ipairs({ "combat", "mounted", "dead", "casting" }) do
    H.ok(state[key] ~= nil, "ActionState answers '" .. key .. "' rather than leaving it absent")
    H.ok(type(state[key]) == "boolean",
        "…as a boolean, so the dump renders it rather than printing a cast's spell name")
end

-- The feature-detection promise. UnitAffectingCombat is NOT among the stubs above, so this asserts
-- the real behaviour on a client that does not have it: false, not a crash. A dump is asked for when
-- something is already wrong, and a diagnostic that throws hides the bug behind its own.
H.eq(state.combat, false,
    "a condition this client cannot answer reads as false rather than erroring")
H.eq(state.mounted, false, "…and one it can answer is answered — IsMounted is stubbed false")

-- Compat.IsBusy delegating to Core.CanSwap (UI-19). Asserted against a LIVE client reading rather
-- than by calling CanSwap with a hand-made table, because the delegation is the whole claim: the
-- driver's decision and the greying of the button it sits behind must be one answer. Two copies of
-- this rule would drift in exactly one direction — a control offering what the driver refuses — and
-- that direction is the bug UI-19 exists to close.
H.eq(G.Kitbag.Compat.IsBusy(), false, "a live, idle mock client is not busy")
G.UnitIsDeadOrGhost = function() return true end
H.eq(G.Kitbag.Compat.IsBusy(), true, "…and a dead one is")
H.eq(G.Kitbag.Core.CanSwap(G.Kitbag.Compat.ActionState()), false,
    "IsBusy and CanSwap are the same answer read from the same client, not two rules")
G.UnitIsDeadOrGhost = nil

-- Sets.Inherit clearing a parent (VERIFY-13), exercised here for exactly the reason ActionState is:
-- Sets reads the character bucket and the client, so the mock is the only place outside the game it
-- can be called at all — and it had NO coverage, despite being a gear-loss path. "Nothing" on the
-- inherit menu drops the parent, and the pieces that were arriving through it have to become the
-- set's own. A plain `set.parent = nil` would be the obvious implementation and would silently empty
-- half the set; the fix is to flatten the RESOLVED set back into it, and nothing was checking that.
local Sets = G.Kitbag.Sets
G.Kitbag.char = {
    sets = {
        Base  = { slots = { [1] = "111:0:0:0:0:0:0", [5] = "222:0:0:0:0:0:0" } },
        Child = { slots = { [16] = "333:0:0:0:0:0:0" }, parent = "Base" },
    },
    rules = {},
}

H.eq(Sets.Inherit("Child", nil), true, "clearing a parent that exists succeeds")
local child = G.Kitbag.char.sets.Child
H.eq(child.parent, nil, "…and the set no longer inherits from anything")
H.eq(child.slots[1], "111:0:0:0:0:0:0", "…the piece it was inheriting is now its OWN, not lost")
H.eq(child.slots[5], "222:0:0:0:0:0:0", "…every one of them")
H.eq(child.slots[16], "333:0:0:0:0:0:0", "…and what it already had is still there")

-- The parent is untouched: flattening copies down, it does not move.
H.eq(G.Kitbag.char.sets.Base.slots[1], "111:0:0:0:0:0:0",
    "the parent keeps its own slots — a child leaving does not strip it")

-- Asking again is refused rather than silently re-flattening. This is the branch that makes the
-- menu's "only when it would change something" guard correct rather than merely tidy.
H.eq(Sets.Inherit("Child", nil), false, "a set that inherits from nothing cannot stop inheriting")

-- ---------------------------------------------------------------------------
-- Sets.Rename — the move, and everything that has to travel with it (UI-29)
-- ---------------------------------------------------------------------------
--
-- Exercised here for the reason Sets.Inherit is: this writes the character bucket and then reaches
-- the client through Bindings.Apply, so the mock is the only place outside the game it can run at
-- all. `Core.RenameImpact` already decides — what is untested without this is whether the four
-- things the impact NAMES are actually carried, and every one of them fails silently:
-- a forgotten binding leaves a key bound to a set that no longer exists, a forgotten child resolves
-- against a missing parent and quietly becomes half a set, a forgotten rule points at nothing, and a
-- forgotten `lastSet` loses the window's selection.
G.Kitbag.char = {
    sets = {
        Base  = { name = "Base", slots = { [1] = "111:0:0:0:0:0:0" }, key = "CTRL-9" },
        Child = { name = "Child", slots = { [16] = "333:0:0:0:0:0:0" }, parent = "Base" },
        Other = { name = "Other", slots = {} },
    },
    rules = { { set = "Base" }, { set = "Other" }, { set = "Base" } },
    lastSet = "Base",
}

local renameKeys = {}
local beforeRename = G.SetBindingClick
G.SetBindingClick = function(key, ...)
    renameKeys[#renameKeys + 1] = key
    return beforeRename(key, ...)
end

H.eq(Sets.Rename("Base", "  Tank  "), true, "renaming a set succeeds, trimming the name given")
G.SetBindingClick = beforeRename

local sets = G.Kitbag.char.sets
H.eq(sets.Base, nil, "…the old name is gone rather than left as a duplicate")
H.ok(sets.Tank ~= nil, "…and the set is under the new one")
H.eq(sets.Tank.name, "Tank", "…with its own `name` field rewritten, not left naming the old key")
H.eq(sets.Tank.slots[1], "111:0:0:0:0:0:0", "…carrying its gear")
H.eq(sets.Tank.key, "CTRL-9", "…and its keybinding")
H.eq(sets.Child.parent, "Tank", "the child now inherits from the new name, not from nothing")
H.eq(G.Kitbag.char.rules[1].set, "Tank", "a stored rule naming the set is re-pointed")
H.eq(G.Kitbag.char.rules[3].set, "Tank", "…every one of them")
H.eq(G.Kitbag.char.rules[2].set, "Other", "…and a rule naming another set is left alone")
H.eq(G.Kitbag.char.lastSet, "Tank", "the window's last selection follows the set it selected")
H.eq(table.concat(renameKeys, ", "), "CTRL-9",
    "…and the key is re-bound, so it equips the set under its new name rather than a vanished one")

-- The refusals. Read through the same pure answer the window greys the button with, so a rename the
-- UI would have blocked cannot succeed by another door.
H.eq(Sets.Rename("Nobody", "Tank"), false, "a set that does not exist cannot be renamed")
H.eq(Sets.Rename("Tank", "Other"), false, "…and neither can one be renamed onto a name in use")
H.ok(sets.Other ~= nil and next(sets.Other.slots) == nil, "…leaving the set it would have replaced")
H.eq(Sets.Rename("Tank", "   "), false, "a name that is only whitespace is refused")
H.eq(Sets.Rename("Tank", "Tank"), false, "…and renaming a set to the name it already has is a no-op")
H.ok(sets.Tank ~= nil, "…with the set still there after every refusal")

-- The `/kit save` → refuse → `/kit resave` sequence (VERIFY-12). Worth stating plainly, because the
-- backlog item assumed otherwise: the SLASH path never raises the confirmation popup. Only the
-- window does. `/kit save` over a set that names gear you are not wearing REFUSES and says what it
-- would have dropped, and `/kit resave` is that question already answered — a separate word rather
-- than a flag, because a flag is indistinguishable from part of a set's name.
--
-- Nothing is equipped in the mock client, so every slot the stored set names counts as a loss, which
-- is exactly the condition this branch exists for.
G.Kitbag.char = { sets = { Tank = { slots = { [1] = "444:0:0:0:0:0:0" } } }, rules = {} }

local saved, lost = Sets.Save("Tank")
H.eq(saved, nil, "saving over a set that names gear you are not wearing is REFUSED")
H.ok(type(lost) == "table" and #lost > 0, "…and it hands back what would have been dropped")
H.ok(Sets.LossText(lost):find("Head") ~= nil,
    "…named by SLOT, so the warning is readable when the item is not cached")

-- The set on disk must be untouched by a refusal. A refusal that had already half-written is worse
-- than no confirmation at all, since the popup would then be asking about something already done.
H.eq(G.Kitbag.char.sets.Tank.slots[1], "444:0:0:0:0:0:0",
    "a refused save changes nothing — the stored set is exactly as it was")

H.ok(Sets.Save("Tank", true) ~= nil, "`/kit resave` is the same save with the question answered")
H.eq(G.Kitbag.char.sets.Tank.slots[1], false,
    "…and it really did overwrite: the slot is now 'deliberately empty', not the old item")

-- A blank set reads as EMPTY on every surface that describes it (VERIFY-10, UI-16).
--
-- Four places say how ready a set is, and `Core.Readiness` is now the one chain they agree through —
-- but agreeing on a verdict is not the same as SPELLING it right, and the spelling is per-surface by
-- design. So each is asked directly. The failure this guards against is specific and quiet: a blank
-- set has no actions and nothing missing, so it satisfies `plan.empty` exactly as a set you are
-- already wearing does, and any surface that reaches for green first announces "you are wearing this"
-- about a set that names nothing at all. A half-built set then looks finished, and the slot picker —
-- the entire reason an empty set exists — never gets opened.
--
-- Exercised here rather than in core_test because these are the window's own words, and KitbagUI only
-- loads against a client.
local UI = G.Kitbag.UI
local blank = G.Kitbag.Core.Plan({ [1] = "444:0:0:0:0:0:0" }, { slots = {} }, {})
local wearing = G.Kitbag.Core.Plan({ [1] = "444:0:0:0:0:0:0" },
    { slots = { [1] = "444:0:0:0:0:0:0" } }, {})

local SURFACES = {
    { name = "the list row",        fn = "RowText" },
    { name = "the row tooltip",     fn = "TooltipNote" },
    { name = "the inspector note",  fn = "InspectorNote" },
}

-- Both spellings, because the three surfaces do not agree on one: the row says "worn", the inspector
-- says "You are wearing this." A probe that knew only the first passed the inspector for the wrong
-- reason — it was not that the sentence was absent, it was that the test could not see it.
local function claimsWorn(text)
    local lower = text:lower()
    return lower:find("worn", 1, true) ~= nil or lower:find("wearing", 1, true) ~= nil
end

for _, s in ipairs(SURFACES) do
    local text = UI[s.fn](blank)
    H.ok(text:lower():find("empty", 1, true) ~= nil,
        s.name .. " calls a blank set empty")
    H.ok(not claimsWorn(text),
        "…and never says worn or wearing about it, which is UI-16's original bug")

    -- The other half of the pair, so the assertion above cannot be satisfied by a surface that has
    -- simply stopped saying "worn" at all.
    H.ok(claimsWorn(UI[s.fn](wearing)),
        "…while " .. s.name .. " still says worn about a set you are actually in")
end

-- `/kit equip` is the fourth surface, and the only one that also has to decide an OUTCOME. A blank
-- set can never "go on", so reporting it as a failure would have the rule engine retry it on every
-- qualifying event for ever — it counts as done, with a reason that says which kind of done.
G.Kitbag.char = { sets = { Blank = { slots = {} } }, rules = {}, swaps = {} }
H.eq(Sets.Equip("Blank"), true, "equipping a blank set succeeds — there is nothing it failed to do")
H.eq(G.Kitbag.char.swaps[1].reason, "the set names no slots",
    "…and it is recorded as blank, not as 'already wearing it' — opposite answers, same no-op")

-- ---------------------------------------------------------------------------
-- A failed swap records how much bag room there was (BUG-13)
-- ---------------------------------------------------------------------------
--
-- Two instances of BUG-13 now read "picked up, but the bag move had not completed", and the number
-- that separates its two candidate causes was never written down: the room at the moment it failed.
-- The planner counts free slots before it starts and refuses outright when there are too few, so a
-- failure that got as far as picking the item up is one the planner BELIEVED it had room for —
-- either the bags filled underneath it, or the room it counted was not room that item could use.
--
-- Run here rather than in core_test because it is the wiring that was missing, not the arithmetic:
-- Core.StateWords could render the number for a year without anything ever putting one in the
-- record. This harness stubs the client at zero free slots, which is what lets an unequip fail on a
-- real code path rather than a mocked one.
-- Something has to BE on your head for taking it off to need a bag slot. The harness wears nothing
-- by default, and against an empty head the set below is a no-op that reports "already wearing it" —
-- which is the same `true` a real success returns and would have made this test pass by not running.
local worn = G.GetInventoryItemLink
G.GetInventoryItemLink = function(_, slotId)
    return slotId == 1 and "|cffffffff|Hitem:444:0:0:0:0:0:0|h[Helm]|h|r" or nil
end

G.Kitbag.char = { sets = { Bare = { slots = { [1] = false } } }, rules = {}, swaps = {} }
H.eq(Sets.Equip("Bare"), false, "taking the helmet off with no bag room fails rather than half-acting")

local failed = G.Kitbag.char.swaps[1]
H.ok(failed and failed.state ~= nil, "a failed swap records the conditions it failed in")
H.eq(failed.state and failed.state.room, 0, "…including how much bag room there was at the time")
H.eq(failed.state and failed.state.need, 1, "…and how much the plan needed, which is what makes 0 mean anything")

-- The line a human actually reads, through the one vocabulary both the dump and /kit verify use.
-- Pinned end to end: the record and the rendering have to agree, and they are written in different
-- files by different modules.
H.eq(G.Kitbag.Core.StateWords(failed.state),
    "combat no, mounted no, dead no, casting no, bag room 0 of 1 needed",
    "…and it reaches the reader as one line, in the vocabulary the dump and /kit verify share")

-- The other direction, and the reason `state` is only captured on failure: a successful swap's
-- conditions explain nothing and would double the size of the record for every ordinary equip.
G.GetInventoryItemLink = worn
H.eq(G.Kitbag.char.swaps[2] and G.Kitbag.char.swaps[2].state, nil,
    "a swap that succeeded records no conditions at all")

-- ---------------------------------------------------------------------------
-- Copying a set to another character (CORE-7)
-- ---------------------------------------------------------------------------
--
-- Exercised here for the reason Sets.Inherit is: this reaches across the account-wide file into a
-- bucket belonging to somebody who is not logged in, so `Kitbag.db` and `Kitbag.char` both have to
-- exist for it to be callable at all. Core.CopySet owns the judgement and is covered in core_test;
-- what is asserted here is the wiring — that the copy lands in the RIGHT bucket, that a target the
-- account has never seen is refused rather than invented, and that the source is untouched.

G.Kitbag.db = {
    chars = {
        ["Deller - Whitemane"] = { sets = {}, rules = {} },
        ["Rinanella - Whitemane"] = { sets = { Raid = { slots = { [1] = "999:0:0:0:0:0:0" } } },
            rules = {} },
    },
    options = {},
}
G.Kitbag.db.chars["Pobble - Whitemane"] = {
    sets = {
        Base  = { slots = { [1] = "111:0:0:0:0:0:0" } },
        Raid  = { slots = { [16] = "333:0:0:0:0:0:0" }, parent = "Base" },
    },
    rules = {},
}
G.Kitbag.char = G.Kitbag.db.chars["Pobble - Whitemane"]

-- The menu's list. Yourself is not on it — you already have the set, and Core would refuse anyway,
-- so offering the choice would only produce a refusal after the click (the UI-11 rule).
local targets = Sets.CopyTargets()
H.eq(table.concat(targets, ", "), "Deller - Whitemane, Rinanella - Whitemane",
    "the copy targets are the other characters the account has seen, in name order")

-- The same list, marked with the clash the window has to show BEFORE the click (UI-20). Core.CopyChoices
-- decides it and is covered there; what this asserts is that Sets asks it about the right two tables —
-- the account's roster and THIS character's bucket. Getting either wrong gives a list that looks
-- entirely plausible and marks the wrong people.
local choices = Sets.CopyChoices("Raid")
H.eq(#choices, 2, "the marked list covers the same characters as the plain one")
H.eq(choices[1].key .. "=" .. tostring(choices[1].taken), "Deller - Whitemane=false",
    "a character with no set of that name is offered")
H.eq(choices[2].key .. "=" .. tostring(choices[2].taken), "Rinanella - Whitemane=true",
    "…and one who already has that name is marked, so the menu can say so instead of refusing later")

H.eq(Sets.CopyTo("Raid", "Deller - Whitemane"), true, "copying to another character succeeds")
local landed = G.Kitbag.db.chars["Deller - Whitemane"].sets.Raid
H.ok(landed ~= nil, "…and the set lands in THAT character's bucket")
H.eq(landed and landed.slots[16], "333:0:0:0:0:0:0", "…carrying its own slots")
H.eq(landed and landed.slots[1], "111:0:0:0:0:0:0",
    "…and the slot it was inheriting, which the alt has no parent set to supply")
H.eq(landed and landed.parent, nil, "…while inheriting from nothing on the far side")

-- The source is a delta still. Copying is a read of this character's list, not a rewrite of it.
H.eq(G.Kitbag.char.sets.Raid.parent, "Base", "the source set still inherits — copying did not flatten it")
H.eq(G.Kitbag.char.sets.Raid.slots[1], nil, "…and did not gain the parent's slot on the way past")

-- A clash refuses and leaves the target's own set exactly as it was. This is the unrecoverable one:
-- Rinanella's Raid is hers, and a silent overwrite is gear work that nothing can rebuild.
H.eq(Sets.CopyTo("Raid", "Rinanella - Whitemane"), false,
    "a name the target already uses is refused rather than overwritten")
H.eq(G.Kitbag.db.chars["Rinanella - Whitemane"].sets.Raid.slots[1], "999:0:0:0:0:0:0",
    "…and their set is untouched by the refusal")

-- A character the account has never seen is refused rather than created. DB.Character makes a bucket
-- on demand, so the naive implementation would happily invent one for a typo'd name — and the copy
-- would succeed, report success, and be invisible for ever.
H.eq(Sets.CopyTo("Raid", "Typo - Whitemane"), false, "an unknown character is refused")
H.eq(G.Kitbag.db.chars["Typo - Whitemane"], nil, "…and no bucket is invented for them")

H.eq(Sets.CopyTo("Raid", "Pobble - Whitemane"), false, "copying to yourself is refused")
H.eq(Sets.CopyTo("Nope", "Deller - Whitemane"), false, "copying a set that does not exist is refused")

-- The slash door. Asserted through SlashCmdList rather than by calling Sets.CopyTo again, because
-- the only thing left to get wrong is the parse — and both halves of it can contain spaces. A set is
-- called "Raid Fire" and a character key is "Name - Realm", so a positional split makes either one
-- unaddressable. " to " is the separator for the same reason "inherit … from …" has one.
local slash = G.SlashCmdList.KITBAG
H.ok(type(slash) == "function", "the slash handler is registered")

G.Kitbag.char.sets["Raid Fire"] = { slots = { [5] = "555:0:0:0:0:0:0" } }
slash("copy Raid Fire to Deller - Whitemane")
local viaSlash = G.Kitbag.db.chars["Deller - Whitemane"].sets["Raid Fire"]
H.ok(viaSlash ~= nil, "a set name with a space in it survives the parse")
H.eq(viaSlash and viaSlash.slots[5], "555:0:0:0:0:0:0", "…and arrives with its gear")

-- The realm half of the key contains " - ", which is what a lazy separator would split on first.
H.ok(G.Kitbag.db.chars["Deller - Whitemane"].sets["Raid Fire"] ~= nil,
    "…and the ' - ' in the character key is not mistaken for the separator")

-- A set whose own name contains the separator. The character key is the half with a fixed shape —
-- one name, one realm, no " to " in it — so the LAST separator is the real one and the set name is
-- whatever came before it. A non-greedy left-hand match splits on the FIRST one instead and tries to
-- copy a set called "Raid" to a character called "Ruin to Deller - Whitemane", which refuses with a
-- message naming a character nobody typed.
G.Kitbag.char.sets["Raid to Ruin"] = { slots = { [7] = "777:0:0:0:0:0:0" } }
slash("copy Raid to Ruin to Deller - Whitemane")
H.ok(G.Kitbag.db.chars["Deller - Whitemane"].sets["Raid to Ruin"] ~= nil,
    "a set name containing ' to ' splits on the LAST separator, not the first")

-- `copy` with nothing to copy to says who IS available rather than printing usage at someone who
-- already typed it correctly. Nothing to assert but that it does not error — the message is chat.
slash("copy")
H.ok(true, "a bare `copy` reports rather than erroring")

-- ---------------------------------------------------------------------------
-- Pressing Import (UI-18 / VERIFY-14)
-- ---------------------------------------------------------------------------
--
-- `Import.FromItemRack` is pure and covered exhaustively in import_test; what had NO coverage is the
-- half that writes — the sets landing in the character's bucket, the options being applied to the
-- account, and the keybindings being re-bound. That is exactly what VERIFY-14 still holds open as
-- "pressing it brings the five across", and it is testable here for the reason Sets.Inherit and
-- Sets.CopyTo are: it reads two globals another addon wrote and writes into Kitbag.db.
--
-- The db is built with the shipped DB.Load rather than a hand-written table, so the option paths
-- KitbagImport maps to are checked against the real defaults. A path Kitbag does not have writes
-- nothing and returns false (DB.Set refuses to invent a branch), so a drift between OPTION_MAP and
-- the defaults would show up here as options that silently never arrive.

local DB = G.Kitbag.DB
G.Kitbag.db = DB.Load({})
G.Kitbag.char = DB.Character(G.Kitbag.db, "Pobble - Whitemane")

-- Real strings from a real ItemRack file, same fixtures as import_test.
local IR_HELM   = "16955::::::::60::::::::::"
local IR_GLOVES = "16855:2544:::::::60::::::::::"

G.ItemRackUser = {
    Sets = {
        HEAL = { equip = { [1] = IR_HELM }, icon = 135019, key = "CTRL-1" },
        DPS  = { equip = { [10] = IR_GLOVES } },
        ["~Unequip"] = { equip = {} },   -- ItemRack's own scratch set, on every character
    },
}
-- ItemRack's settings are the OPPOSITE of Kitbag's defaults on all three mapped options, so an
-- option that failed to transfer cannot be mistaken for one that transferred to the same value.
G.ItemRackSettings = { EnableEvents = "OFF", ShowMinimap = "OFF", EnableTrinketMenu = "ON" }

-- The button's tooltip promises the keybindings come across too, and storing `key` on the set is only
-- half of that — something has to tell the client. Recorded rather than assumed: this is the one part
-- of the import that reaches an API no module's load path touches, which is how the missing
-- SetBindingClick stub above was found in the first place.
local boundKeys = {}
local stubSetBindingClick = G.SetBindingClick
G.SetBindingClick = function(key, ...)
    boundKeys[#boundKeys + 1] = key
    return stubSetBindingClick(key, ...)
end

local imported = Sets.ImportItemRack()
H.eq(imported.imported, 2, "pressing Import brings across every set that is really a set")
H.ok(G.Kitbag.char.sets.HEAL ~= nil, "…and they land in THIS character's bucket")
H.eq(G.Kitbag.char.sets.HEAL.slots[1], G.Kitbag.Core.ItemKey(IR_HELM), "…carrying their gear")
H.eq(G.Kitbag.char.sets.HEAL.key, "CTRL-1", "…and the key ItemRack had them on")
H.eq(G.Kitbag.char.sets["~Unequip"], nil, "ItemRack's scratch sets are not stored as sets")

H.eq(table.concat(boundKeys, ", "), "CTRL-1",
    "…and that key is actually bound in the client, not merely stored on the set")

G.SetBindingClick = stubSetBindingClick

-- The options, through the shipped paths. All three are inverted from the defaults above.
H.eq(DB.Get(G.Kitbag.db, "autoSwap"), false, "a mapped ItemRack option reaches the account options")
H.eq(DB.Get(G.Kitbag.db, "minimap.hide"), true, "…including the ones stored the opposite way up")
H.eq(DB.Get(G.Kitbag.db, "trinkets.hide"), false, "…in both directions")

-- Once everything is across there is nothing to offer, which is what takes the button away.
H.eq(Sets.ImportOffer(), nil, "with the sets across, the window has nothing left to offer")

-- The re-import. `/kit import` is still reachable after the button has gone, and a second run brings
-- NOTHING across — every set clashes with the one it created the first time. The options must not
-- move on that run: they are the player's now, and ItemRack's copy of them is older than every
-- change made since. Re-applying them silently turns auto-swap back on for someone who deliberately
-- turned it off, and gear that starts swapping again by itself is not traceable to a command that
-- said "nothing new to import".
DB.Set(G.Kitbag.db, "autoSwap", true)
DB.Set(G.Kitbag.db, "minimap.hide", false)

local again = Sets.ImportItemRack()
H.eq(again.imported, 0, "a second import brings nothing across — every set is already here")
H.eq(DB.Get(G.Kitbag.db, "autoSwap"), true,
    "…and it leaves the options alone rather than re-applying ItemRack's over the player's")
H.eq(DB.Get(G.Kitbag.db, "minimap.hide"), false, "…every one of them")

-- ---------------------------------------------------------------------------
-- Bindings.Set — assigning a key from the window (UI-12)
-- ---------------------------------------------------------------------------
--
-- Exercised here for the reason the import above is: this is a WRITE path, it touches the client,
-- and the pure half (Core.BindingImpact) can be cornered in core_test while the half that stores and
-- binds cannot be reached anywhere else outside the game. The import's own lesson was that testing
-- the pleasant half and calling the feature done is exactly how the sharp bug survives.
--
-- The behaviour that is not obvious: keys are EXCLUSIVE, and the arbiter that already existed
-- settles a contest by set name because it was written for an import where nobody chose. Assigning
-- CTRL-1 to DPS while HEAL holds it must take it, not queue a claim that loses.
local Bindings = G.Kitbag.Bindings
H.eq(G.Kitbag.char.sets.HEAL.key, "CTRL-1", "HEAL came out of the import holding CTRL-1")

local ok, taken = Bindings.Set("DPS", "CTRL-1")
H.eq(ok, true, "a key another set holds is still assignable — a deliberate press wins")
H.eq(taken, "HEAL", "…and the set it was taken from is named, so the player can be told")
H.eq(G.Kitbag.char.sets.DPS.key, "CTRL-1", "the key lands on the set that asked for it")
H.eq(G.Kitbag.char.sets.HEAL.key, nil,
    "…and is CLEARED off the old holder, or BindingPlan hands it straight back and the new "
    .. "binding silently does nothing")

-- What actually reaches the client, not merely what is stored. One binding, on the set that won it:
-- a stale claim left behind would show up here as CTRL-1 being bound twice.
local rebound = {}
local realSetBindingClick = G.SetBindingClick
G.SetBindingClick = function(key, ...)
    rebound[#rebound + 1] = key
    return realSetBindingClick(key, ...)
end
Bindings.Apply()
H.eq(table.concat(rebound, ", "), "CTRL-1", "exactly one set is bound to the key afterwards")

-- Clearing, which is the right-click on the button.
H.eq(Bindings.Set("DPS", nil), true, "a key can be cleared")
H.eq(G.Kitbag.char.sets.DPS.key, nil, "…and the set stops holding one")

H.eq(Bindings.Set("Nope", "CTRL-9"), false, "a set that does not exist cannot be given a key")
H.eq(G.Kitbag.char.sets.Nope, nil,
    "…and asking does not invent the set, the way a get-or-create accessor would")

G.SetBindingClick = realSetBindingClick

-- No ItemRack at all is the majority case and reaches this at login. It must report rather than error.
G.ItemRackUser, G.ItemRackSettings = nil, nil
H.eq(Sets.ImportItemRack().imported, 0, "no ItemRack installed imports nothing rather than erroring")

-- ---------------------------------------------------------------------------
-- Equip and Delete act on the SELECTED set, with the list scrolled (VERIFY-8)
-- ---------------------------------------------------------------------------
--
-- UI-13 moved these two buttons out of the rows, so they read a file-local `selected` rather than the
-- row they were pressed on. That is the addon's one unrecoverable act pointed at a variable, and from
-- outside a stale selection is indistinguishable from a correct one: Delete removes a set that is not
-- the one on screen, and it looks right until you count what is left. `/kit verify` has a check for
-- it in the client; this drives the same journey outside the game, and at an OFFSET, which the client
-- check does not do.
--
-- The delete goes through the popup rather than the shift-click shortcut on purpose. The name is
-- handed to StaticPopup_Show as `data` and read back in OnAccept precisely so the answer applies to
-- the set the question NAMED (BUG-8) — the list underneath stays live while the popup is up — and
-- that hand-off is the part no pure test has ever exercised.
local sets = {}
for i = 1, 20 do
    sets[string.format("Set%02d", i)] = { slots = { [1] = "444:0:0:0:0:0:0" } }
end
G.Kitbag.char = { sets = sets, rules = {}, swaps = {} }

UI.Toggle()
H.ok(G.KitbagFrame and G.KitbagFrame:IsShown(), "the main window opens, so its list is drawn")

FauxScrollFrame_SetOffset(G.KitbagScrollFrame, 4)
UI.Refresh()

-- Sets are listed alphabetically, so row 1 at an offset of four is Set05. Asserted rather than
-- assumed: if the sort ever changes, this test must fail loudly instead of quietly checking nothing.
G.KitbagSetRow1:Click()
H.eq(UI.Selected(), "Set05", "clicking a scrolled row selects the set that row is SHOWING")
H.eq(G.KitbagInspectorTitle:GetText(), "Set05", "…and the inspector is headed with the same set")

local asked = {}
local realStaticPopupShow = G.StaticPopup_Show
G.StaticPopup_Show = function(which, arg1, arg2, data)
    asked = { which = which, arg1 = arg1, data = data }
    return newWidget("StaticPopup1")
end

G.KitbagInspector.delete:Click()
H.eq(asked.which, "KITBAG_DELETE", "Delete asks first rather than acting")
H.eq(asked.data, "Set05", "…and the question carries the selected set as its own data")

-- The set list stays live while the popup is up, so a row clicked in between must not change the
-- answer. This is the whole reason the name travels as `data` instead of being re-read.
G.KitbagSetRow2:Click()
G.StaticPopupDialogs.KITBAG_DELETE.OnAccept({}, asked.data)
G.StaticPopup_Show = realStaticPopupShow

H.ok(G.Kitbag.char.sets.Set05 == nil, "answering yes deletes the set the popup named")
H.ok(G.Kitbag.char.sets.Set06 ~= nil,
    "…and not the set selected while the question was up, which is the quiet way to lose the wrong one")
H.ok(G.Kitbag.char.sets.Set01 ~= nil,
    "…nor the set at the clicked row's own position, which is VERIFY-8's fear exactly")

-- ---------------------------------------------------------------------------
-- Keybinding capture proposes before it changes, and cannot outlive the window (UI-30, VERIFY-16)
-- ---------------------------------------------------------------------------
--
-- While capturing, the key button is the ONLY thing in the game receiving keystrokes: propagation is
-- deliberately off, which is what stops binding "B" from also opening the bags. That makes leaving
-- the mode the load-bearing half. A build that stays clamped after the window goes away does not look
-- like an addon bug — it looks exactly like the client having locked up, and the player's next move
-- is to kill the process, not to report anything useful.
--
-- The two client calls are watched by shadowing them on the button itself rather than by teaching the
-- whole mock to record them: they are what this test is ABOUT, and a reader should be able to see
-- what is being watched without going hunting in the mock.
UI.Select("Set07")
local key = G.KitbagKeyButton
local keyboard, propagate = {}, {}
rawset(key, "EnableKeyboard", function(_, on) keyboard[#keyboard + 1] = on end)
rawset(key, "SetPropagateKeyboardInput", function(_, on) propagate[#propagate + 1] = on end)

key:Click("LeftButton")
H.eq(key:GetText(), "Press…", "clicking the key button enters capture mode and says so on the button")
H.eq(keyboard[#keyboard], true, "…the button takes the keyboard")
H.eq(propagate[#propagate], false, "…and stops the keystroke reaching the game behind it")

-- A player's current action wins over a new gear binding. The refusal must be visible and must
-- discard any prior proposal, because Enter after an ignored press must not commit a key the button
-- is no longer showing.
G.BINDING_NAME_MOVEFORWARD = "Move Forward"
local normalBindingAction = G.GetBindingAction
G.GetBindingAction = function(binding)
    return binding == "W" and "MOVEFORWARD" or ""
end
key:GetScript("OnKeyDown")(key, "W")
H.eq(G.Kitbag.char.sets.Set07.key, nil, "a player-bound key never changes the selected set")
H.eq(key:GetText(), "W is bound to Move Forward — hold a modifier",
    "the capture button names the player action it refuses to take")
key:GetScript("OnKeyDown")(key, "ENTER")
H.eq(G.Kitbag.char.sets.Set07.key, nil, "Enter cannot commit an earlier proposal after a refusal")
G.GetBindingAction = normalBindingAction

-- The first chord is a proposal, not a destructive write. Re-pressing replaces it, so a mis-hit
-- costs nothing until Enter says this is the one to keep.
G.Kitbag.char.sets.Set06.key = "F8"
key:GetScript("OnKeyDown")(key, "F8")
H.eq(G.Kitbag.char.sets.Set07.key, nil, "capturing a key does not replace the committed binding")
H.eq(G.Kitbag.char.sets.Set06.key, "F8", "…or take the proposed key from another set")
H.eq(key:GetText(), "F8 — Enter to keep, Escape to cancel (takes it from Set06)",
    "the proposal tells the player how to commit and what it would cost")
key:GetScript("OnKeyDown")(key, "F9")
H.eq(key:GetText(), "F9 — Enter to keep, Escape to cancel",
    "a second key replaces the proposal rather than committing the first one")
key:GetScript("OnKeyDown")(key, "ENTER")
H.eq(G.Kitbag.char.sets.Set07.key, "F9", "Enter commits the currently proposed key")
H.eq(keyboard[#keyboard], false, "committing gives the keyboard back")

-- Closing the window mid-capture. Not by calling the handler directly: the whole question is whether
-- hiding the WINDOW reaches a button several frames down, which is what OnHide is registered for.
G.KitbagFrame:Hide()
H.eq(keyboard[#keyboard], false, "closing the window gives the keyboard back")
H.eq(propagate[#propagate], true,
    "…and un-clamps propagation, which is the difference between an ended mode and a dead client")

-- Escape is the other way out, and it must NOT be turned into a binding. It reaches the button at all
-- only because propagation is off, so this is the one key whose handling is a property of the mode.
G.KitbagFrame:Show()
UI.Refresh()
key:Click("LeftButton")
H.eq(keyboard[#keyboard], true, "capture can be entered again after the window was closed on it")
key:GetScript("OnKeyDown")(key, "F10")
key:GetScript("OnKeyDown")(key, "ESCAPE")
H.eq(keyboard[#keyboard], false, "Escape leaves capture mode")
H.eq(G.Kitbag.char.sets.Set07.key, "F9", "…without committing the proposed key")

-- ---------------------------------------------------------------------------
-- Renaming a set from the window (UI-29)
-- ---------------------------------------------------------------------------
--
-- The clash is the whole of the risk, and it is the reason this is an edit box rather than a popup
-- with an OK button: `Sets.Rename` refuses a taken name, but a refusal that arrives in chat AFTER
-- the press is a control that appeared to work. `Core.RenameLabel` answers on every keystroke, so
-- the answer is on screen while the name is still being typed.
--
-- Driven through the box's own scripts rather than by calling the service, because the wiring
-- between a keystroke, the live line and the set that actually moves is precisely the part pure
-- tests cannot reach — and the set that moves must be the one the box was OPENED on, not whatever
-- the list has selected by the time Enter is pressed.
UI.Select("Set07")
local renameButton = G.KitbagRenameButton
H.ok(renameButton ~= nil, "the action row has a Rename control, named so a check can measure it")

renameButton:Click()
local box = G.KitbagRenameBox
H.ok(box ~= nil and box:IsShown(), "pressing it opens an edit box rather than a chat prompt")
H.eq(box:GetText(), "Set07", "…prefilled with the set's current name, so a typo is a small edit")
H.eq(G.KitbagStatusLine:GetText(), "Set07 is already its name.",
    "…and the line under the list explains the box rather than leaving it unlabelled")

-- A taken name, refused BEFORE the press. This is the assertion the whole control exists for.
box:SetText("Set06")
box:GetScript("OnTextChanged")(box, true)
H.eq(G.KitbagStatusLine:GetText(), "Another set is already called Set06.",
    "a taken name is refused while it is being typed")
box:GetScript("OnEnterPressed")(box)
H.ok(box:IsShown(), "…and pressing Enter on it does nothing rather than closing on a failure")
H.ok(G.Kitbag.char.sets.Set07 ~= nil, "…the set keeps its name")
H.ok(G.Kitbag.char.sets.Set06 ~= nil, "…and the set it would have collided with is untouched")

-- An empty box is not an error yet — nobody has done anything wrong by clearing it.
box:SetText("   ")
box:GetScript("OnTextChanged")(box, true)
H.eq(G.KitbagStatusLine:GetText(), "Type a name for this set.",
    "an emptied box asks for a name rather than reporting a failure")

box:SetText("  Raid Two  ")
box:GetScript("OnTextChanged")(box, true)
H.eq(G.KitbagStatusLine:GetText(), "Press Enter to rename Set07 to Raid Two.",
    "a free name says what pressing Enter will do, in the trimmed form it will be stored under")

-- The list stays live while the box is open, so a row clicked in between must not change which set
-- moves. Delete's popup carries its name as `data` for this reason (BUG-8); the box has to hold the
-- same discipline, and it is the same quiet way to rename the wrong set.
G.KitbagSetRow2:Click()
box:GetScript("OnEnterPressed")(box)
H.ok(G.Kitbag.char.sets["Raid Two"] ~= nil, "Enter renames the set the box was OPENED on")
H.ok(G.Kitbag.char.sets.Set07 == nil, "…so the old name is gone")
H.ok(G.Kitbag.char.sets.Set02 ~= nil, "…and not the set selected while the box was up")
H.ok(not box:IsShown(), "…and the box closes once the rename has happened")

-- Escape is the way out, and it must leave the set alone. Same property the key capture has: a mode
-- with no exit is indistinguishable from a frozen client.
UI.Select("Set08")
renameButton:Click()
box:SetText("Something Else")
box:GetScript("OnTextChanged")(box, true)
box:GetScript("OnEscapePressed")(box)
H.ok(not box:IsShown(), "Escape closes the box")
H.ok(G.Kitbag.char.sets.Set08 ~= nil, "…without renaming anything")

-- Closing the window mid-rename. Not by calling the handler: the question is whether hiding the
-- WINDOW reaches a box several frames down, which is the whole point of registering OnHide.
renameButton:Click()
H.ok(box:IsShown(), "the box opens again after an Escape")
G.KitbagFrame:Hide()
H.ok(not box:IsShown(), "closing the window takes the open rename box with it")
G.KitbagFrame:Show()
UI.Refresh()

-- Nothing selected is the one press that must do nothing rather than open a box over no set. It is
-- reached the only way it can be — `UI.Select` refuses nil on purpose (UI-13), so the state exists
-- only when there are no sets to select.
local keptSets = G.Kitbag.char.sets
G.Kitbag.char.sets = {}
UI.Refresh()
renameButton:Click()
H.ok(not box:IsShown(), "with no set selected the control opens nothing")
G.Kitbag.char.sets = keptSets
UI.Refresh()

-- Scrolled out of sight, which is the one case that cannot be reached by clicking a row: `UI.Select`
-- is also how `/kit verify` and a freshly created set choose one, and a box anchored to a row that
-- is not drawn would open over the wrong set entirely.
FauxScrollFrame_SetOffset(G.KitbagScrollFrame, 0)
UI.Refresh()
UI.Select("Set19")
renameButton:Click()
H.ok(box:IsShown(), "renaming a set scrolled out of view brings it into view rather than refusing")
H.eq(box:GetText(), "Set19", "…and the box opens on that set, not on the row that was there before")
box:GetScript("OnEscapePressed")(box)

-- ---------------------------------------------------------------------------
-- The Import button takes itself away on the same refresh (VERIFY-14)
-- ---------------------------------------------------------------------------
--
-- The one control in the window whose ABSENCE is as load-bearing as its presence. Its count and its
-- fit are `/kit verify` checks already; the import itself is covered above. What was left is the
-- join: pressing it must bring the sets across AND the button must be gone on the redraw the import
-- itself triggers, rather than lingering until some unrelated event refreshes the window. A button
-- still offering an import that has already happened invites a second press, and a second press is
-- the case that used to re-apply ItemRack's options over choices made since.
G.Kitbag.char = { sets = {}, rules = {}, swaps = {} }
G.ItemRackUser = {
    Sets = {
        HEAL = { equip = { [1] = IR_HELM }, icon = 135019, key = "CTRL-1" },
        DPS  = { equip = { [10] = IR_GLOVES } },
        ["~Unequip"] = { equip = {} },
    },
}

UI.Refresh()
local importButton = G.KitbagImportButton
H.ok(importButton:IsShown(), "the button offers the import while there is one to make")
H.eq(importButton:GetText(), "Import 2 sets from ItemRack",
    "…naming the count the tests pin, so a different number means the window reads another world")

importButton:Click()
H.ok(G.Kitbag.char.sets.HEAL ~= nil, "pressing it brings the sets across")
H.ok(G.Kitbag.char.sets.DPS ~= nil, "…all of them")
H.ok(not importButton:IsShown(),
    "…and the button is gone on the import's OWN refresh, not at the next unrelated one")

-- ---------------------------------------------------------------------------
-- The copy menu greys the clash instead of refusing after the click (VERIFY-17)
-- ---------------------------------------------------------------------------
--
-- `Sets.CopyTo` refuses a name the target already uses and says so in chat. That is the right answer
-- to something TYPED and the wrong one to something CLICKED: the player picks a character off a list
-- the program drew and is then told no. So the entries are greyed with the reason ON them, and this
-- drives the real menu builder to prove it — the info tables Blizzard would draw are captured as they
-- are handed over, which is as close to the drawn menu as anything outside the client can get.
--
-- Also proved here: the menu is about the set it was OPENED on. The list on the left stays live while
-- a menu is up, so a row clicked in between must not change where the copy goes (BUG-8's lesson,
-- quieter here — a copy destroys nothing, so the wrong set is found on another character days later).
G.Kitbag.db = DB.Load({})
G.Kitbag.db.chars["Mock - Mockrealm"] = { sets = { Tank = { slots = { [1] = "444:0:0:0:0:0:0" } },
    Healer = { slots = { [2] = "555:0:0:0:0:0:0" } } }, rules = {}, swaps = {} }
G.Kitbag.db.chars["Alt - Mockrealm"] = { sets = {}, rules = {}, swaps = {} }
G.Kitbag.db.chars["Twin - Mockrealm"] = { sets = { Tank = { slots = {} } }, rules = {}, swaps = {} }
G.Kitbag.char = G.Kitbag.db.chars["Mock - Mockrealm"]

UI.Select("Tank")

local entries = {}
local realAddButton = G.UIDropDownMenu_AddButton
G.UIDropDownMenu_AddButton = function(info, level)
    entries[#entries + 1] = info
    return realAddButton(info, level)
end
G.KitbagCopyButton:Click()
G.UIDropDownMenu_AddButton = realAddButton

local byName = {}
for _, info in ipairs(entries) do byName[tostring(info.text)] = info end

H.ok(byName["Copy Tank to"] ~= nil, "the menu is headed with the set it was opened on")
H.ok(byName["Alt - Mockrealm"] ~= nil, "a character with no set of that name is offered")
H.ok(not byName["Alt - Mockrealm"].disabled, "…and is live")

local clash
for text, info in pairs(byName) do
    if text:find("Twin - Mockrealm", 1, true) then clash = info end
end
H.ok(clash ~= nil, "the character who already has a set called Tank is on the menu")
H.ok(clash and clash.disabled == true, "…greyed, so the refusal never arrives after the click")
H.ok(clash and tostring(clash.text):find("has a set called Tank", 1, true) ~= nil,
    "…with the reason ON the line, not left as a name with no explanation")

-- Clicking a live entry copies, and copies the set the menu was opened on even though the selection
-- moved underneath it in the meantime.
UI.Select("Healer")
byName["Alt - Mockrealm"].func()
H.ok(G.Kitbag.db.chars["Alt - Mockrealm"].sets.Tank ~= nil,
    "picking a live character copies the set the menu was HEADED with")
H.ok(G.Kitbag.db.chars["Alt - Mockrealm"].sets.Healer == nil,
    "…and not whatever was selected while the menu was open")

-- ---------------------------------------------------------------------------
-- Dead greys what MOVES GEAR, and nothing else (VERIFY-15, UI-19)
-- ---------------------------------------------------------------------------
--
-- The decision is `Core.CanSwap` and is covered pure; what has never been exercised is the window
-- acting on it. Both directions matter and the second is the one the item says is easy to forget:
-- running back as a corpse is exactly when someone has time to tidy their gear sets, and editing one
-- touches no gear at all. Disabling the whole window would have been easier and wrong.
local panel = G.KitbagInspector
G.KitbagFrame:Show()
UI.Select("Tank")

H.ok(panel.equip:IsEnabled(), "alive, Equip is live")

G.UnitIsDeadOrGhost = function() return true end
UI.Refresh()
H.ok(not panel.equip:IsEnabled(), "dead, Equip greys rather than offering a swap that cannot happen")
-- rawget, not `panel.blocked`: the mock manufactures a method for any key a widget does not have,
-- so a plain read of an absent field hands back a function and is never nil. That is the one
-- place this test double lies convincingly, and it lies in the direction of passing.
H.ok(Kitbag.Core.SWAP_BLOCKED[rawget(panel, "blocked")] ~= nil,
    "…and the window is holding the REASON, so the grey can explain itself")
-- Equip has no label to grey any more (UI-26), so Disable() on its own changes nothing a player can
-- see: the picture keeps its colours and the button goes on looking pressable. Disabled-and-bright
-- is worse than the bug UI-19 fixed, because the click now silently does nothing instead of
-- explaining itself ten seconds later.
H.ok(rawget(panel.equip, "kitbagDimmed") == true,
    "…and the DIMMING reaches the picture, which is the only thing left to grey")

-- The half that is easy to forget. None of these move an item.
H.ok(panel.delete:IsEnabled(), "…while Delete stays live, because deleting a set moves no gear")
H.ok(panel.copy:IsEnabled(), "…and Copy to…, which writes into another character's list")
H.ok(panel.key:IsEnabled(), "…and the keybinding button")

G.UnitIsDeadOrGhost = nil
UI.Refresh()
H.ok(panel.equip:IsEnabled(), "coming back to life gives Equip back")
H.ok(rawget(panel, "blocked") == nil, "…and the window stops holding a reason it no longer has")
H.ok(rawget(panel.equip, "kitbagDimmed") == false,
    "…and the picture comes back with it, rather than staying grey on a button that now works")

-- ---------------------------------------------------------------------------
-- The inherit menu ticks the real parent, and picking one redraws (VERIFY-13)
-- ---------------------------------------------------------------------------
--
-- `/kit verify` counts the check textures on Blizzard's list frame in the client. This asks the other
-- side of the same question — the info tables the menu is BUILT from — and adds the two halves a
-- drawn menu cannot show: that a child is never offered as its own parent (the loop `Sets.Inherit`
-- would refuse, so the menu must not offer it in the first place), and that picking an entry actually
-- changes the set and repaints the doll with the inherited pieces in it.
G.Kitbag.char = { sets = {
    Base   = { slots = { [1] = "444:0:0:0:0:0:0" } },
    Child  = { slots = { [2] = "555:0:0:0:0:0:0" } },
}, rules = {}, swaps = {} }
G.KitbagFrame:Show()
UI.Select("Child")

local function openInheritMenu()
    local captured = {}
    local realAdd = G.UIDropDownMenu_AddButton
    G.UIDropDownMenu_AddButton = function(info, level)
        captured[#captured + 1] = info
        return realAdd(info, level)
    end
    G.KitbagInheritButton:Click()
    G.UIDropDownMenu_AddButton = realAdd
    local byText = {}
    for _, info in ipairs(captured) do byText[tostring(info.text)] = info end
    return byText
end

local menu = openInheritMenu()
H.ok(menu["Nothing"] ~= nil, "the menu offers Nothing, which is how the pieces are given back")
H.ok(menu["Nothing"].checked == true, "…ticked, because a set inheriting from nothing HAS a parent: nil")
H.ok(menu["Base"] ~= nil, "…and the other set is offered as a parent")
H.ok(menu["Base"].checked == false, "…unticked, since it is not the parent yet")
H.ok(menu["Child"] == nil, "…while the set itself is never offered as its own parent")

-- Picking Base must both inherit and redraw. The doll's slot 1 cell has nothing of its own in it, so
-- the inherited piece arriving is exactly the difference between the two states.
local cell1
for slotId, cell in pairs(G.KitbagInspector.cells) do
    if slotId == 1 then cell1 = cell end
end
H.ok(cell1 ~= nil, "the doll has a cell for the slot the parent supplies")
H.ok(not cell1.icon:IsShown(), "…and it is empty before the set inherits anything")

menu["Base"].func()
H.eq(Kitbag.Sets.ParentOf("Child"), "Base", "picking a set really does set the parent")
H.ok(cell1.icon:IsShown(),
    "…and the doll is redrawn with the inherited piece in it, rather than at the next unrelated refresh")

local after = openInheritMenu()
H.ok(after["Base"].checked == true, "reopening the menu ticks the parent it now has")
H.ok(after["Nothing"].checked == false, "…and Nothing is no longer the answer")

after["Nothing"].func()
H.eq(Kitbag.Sets.ParentOf("Child"), nil, "Nothing clears the parent")
H.ok(cell1.icon:IsShown(),
    "…and the pieces that were arriving through it are KEPT, flattened into the set itself")
-- `/kit session` — the acts EPIC-VERIFY is waiting on, printed where the person performing them is
-- (VERIFY-1 through 18). The list is pure and covered in verify_test; what is asserted here is the
-- DOOR, because a command nobody can type is a checklist nobody reads: the addon's help must offer
-- it, and the handler must actually print something.
local said = {}
local realAddMessage = G.DEFAULT_CHAT_FRAME.AddMessage
G.DEFAULT_CHAT_FRAME.AddMessage = function(_, text) said[#said + 1] = tostring(text) end
G.SlashCmdList["KITBAG"]("session")
G.DEFAULT_CHAT_FRAME.AddMessage = realAddMessage

local transcript = table.concat(said, "\n")
H.ok(transcript:find("needs a person", 1, true) ~= nil, "/kit session prints what is still owed")
H.ok(transcript:find("scriptErrors", 1, true) ~= nil,
    "…starting with the one that makes every other answer worth having")

local helped = {}
G.DEFAULT_CHAT_FRAME.AddMessage = function(_, text) helped[#helped + 1] = tostring(text) end
G.SlashCmdList["KITBAG"]("help")
G.DEFAULT_CHAT_FRAME.AddMessage = realAddMessage
H.ok(table.concat(helped, "\n"):find("/kit session", 1, true) ~= nil,
    "…and /kit help offers it, or the command exists for nobody")


-- ---------------------------------------------------------------------------
-- The bottom row is icons (UI-24, UI-27)
-- ---------------------------------------------------------------------------
--
-- Four controls, and they divide cleanly: Options and Rules are DOORS to other windows, Save and New
-- set are things this window DOES. A door is the control an icon is unambiguously right for. The
-- other two are the interesting half, because their labels were carrying real meaning — "Save what
-- I'm wearing" is a whole sentence, and it is the sentence that stops the button being read as "save
-- the set I have selected", which is a different and destructive thing.
--
-- So the tooltip is asserted here as the load-bearing part rather than as a formality. Two of these
-- four had no tooltip at all before, on the grounds that the label was the explanation; that trade
-- only works while there is a label.
for _, entry in ipairs({
    { button = G.KitbagOptionsButton, what = "Options",
      why = "a door to another window, which is what an icon is unambiguously right for" },
    { button = G.KitbagSaveButton,    what = "Save",
      why = "the label was a sentence, and a sentence is exactly what a tooltip is for" },
    { button = G.KitbagNewSetButton,  what = "New set",
      why = "the label was a sentence, and a sentence is exactly what a tooltip is for" },
}) do
    H.ok(rawget(entry.button, "kitbagIcon") ~= nil,
        entry.what .. " is an icon button — " .. entry.why)
    H.ok(entry.button:GetScript("OnEnter") ~= nil,
        "…and it explains itself on hover, which is the only thing left that can")
end

-- ---------------------------------------------------------------------------
-- The action row's secondary buttons are icons (UI-23)
-- ---------------------------------------------------------------------------
--
-- Three text buttons on a row built for two is UI-20's known-sharp edge, and the shape of the row
-- said the wrong thing about it besides: Equip, Delete and "Copy to…" were three peers, when one of
-- them is what the window is FOR and the other two are things you do to a set occasionally. Delete
-- and Copy are icons now, Equip takes the width they give up, and the row reads as one action with
-- two tools beside it.
--
-- What icons cost is the label, and that is the whole risk: an icon button with no texture is an
-- empty square, and an icon button with no tooltip is a square nobody can identify. Both are
-- asserted, because both look like a deliberate design from a screenshot and neither can be read.
local actionPanel = G.KitbagInspector
for _, entry in ipairs({
    { button = actionPanel.equip, what = "Equip" },
    { button = actionPanel.delete, what = "Delete" },
    { button = G.KitbagCopyButton, what = "Copy" },
}) do
    H.ok(rawget(entry.button, "kitbagIcon") ~= nil,
        entry.what .. " is an icon button, so the row is one action with tools beside it")
    H.ok(entry.button:GetScript("OnEnter") ~= nil,
        "…and it says what it is on hover, which is the only name an icon has")
end

H.ok(type(G.Kitbag.Skin.IconButton) == "function",
    "icon buttons come from the same place the panels do, so a third cannot arrive looking different")

-- ---------------------------------------------------------------------------
-- The action bar belongs to the set list (UI-28)
-- ---------------------------------------------------------------------------
--
-- The three sat in the bottom corner of the inspector, which is a 300-wide panel — and once all
-- three became icons (UI-23, UI-26) the row was 90 wide inside it. A huddle of three small squares
-- in the corner of a panel reads as a layout that came apart, and it puts the controls a whole
-- column away from the list of sets they act on.
--
-- What is asserted is the ANCHOR, not the arithmetic. The mock cannot lay a window out and never
-- will — every edge here is 0 — so "centred" cannot be a sum done in this file. It does not need to
-- be: centring is expressed by anchoring the row's TOP to the list's BOTTOM at an x offset of zero,
-- which is a structural claim rather than a measured one, and a structural claim is the kind a
-- window cannot drift away from silently. The measurement belongs in the client, where there are
-- real edges — `/kit verify`'s `copy-button` check does it there.
local actionRow = G.KitbagActionRow
H.ok(actionRow ~= nil, "the set list has an action bar of its own rather than three loose buttons")
if actionRow then
    local point, relativeTo, relativePoint, x = actionRow:GetPoint(1)
    H.ok(relativeTo == G.KitbagSetList,
        "…anchored to the set list, so the controls belong to the thing they act on")
    H.ok(point == "TOP" and relativePoint == "BOTTOM",
        "…hanging BELOW it rather than beside it")
    H.ok(x == 0,
        "…and centred on it: a zero offset from TOP to BOTTOM is what centring IS, so the row " ..
        "re-centres itself if the list or any button changes width")
    H.ok(G.KitbagCopyButton:GetParent() == actionRow,
        "…and the three are children of the row, so the row is what moves them, not three anchors")
end

-- The inspector keeps the handles, because the refresh reaches the three through the panel it draws
-- (Equip greys while dead, Copy hides with nobody to copy to). Reparenting a control and losing the
-- handle to it is a window that draws correctly and stops responding to anything.
local inspector = G.KitbagInspector
H.ok(inspector ~= nil, "the inspector panel is named, so a check can ask about it by name")
H.ok(inspector and rawget(inspector, "equip") ~= nil and rawget(inspector, "delete") ~= nil,
    "…and still holds the action row's controls, which is how the refresh greys and hides them")

-- ---------------------------------------------------------------------------
-- One recessed panel, drawn the same way in every window (UI-22)
-- ---------------------------------------------------------------------------
--
-- Kitbag draws six regions that hold a list or a grid, and before this each of them sat directly on
-- whatever `BasicFrameTemplateWithInset` had painted behind it � so a window was a heading, some
-- controls, and content floating on an empty plate with no edge to say where the content began. The
-- addon already knew how to draw a recess: every doll cell has one. It was written out by hand each
-- time and therefore only existed in the two places somebody remembered.
--
-- `Skin.Inset` is that recess in one function. The point of the module is not the two textures � it
-- is that a seventh region cannot arrive looking like none of the other six.
--
-- Asserted with rawget throughout. An absent field on a mock widget is manufactured into a METHOD by
-- __index, so `rawget` is the only honest read here and the lie would be in the direction of passing.
local Skin = G.Kitbag.Skin
H.ok(type(Skin) == "table" and type(Skin.Inset) == "function",
    "the addon has one way to recess a panel rather than a hand-drawn one per window")

local sample = newWidget("SkinSample")
H.ok(Skin.Inset(sample) == sample, "�and it hands the frame back, so it can wrap a CreateFrame call")
H.ok(rawget(sample, "kitbagEdge") ~= nil, "�drawing an edge")
H.ok(rawget(sample, "kitbagGround") ~= nil, "�and a ground inside it")

-- The regions themselves. Named frames, all six, because a region nobody can name is a region
-- nobody can measure � and the whole failure this guards against is one of them being missed, which
-- looks like nothing at all until the window is open beside another one.
for _, name in ipairs({
    "KitbagSetList", "KitbagPreviewFrame",
    "KitbagIconGrid", "KitbagPickerGrid", "KitbagPickerFrame",
}) do
    local region = G[name]
    H.ok(region ~= nil and rawget(region, "kitbagGround") ~= nil,
        name .. " is recessed by the shared skin rather than sitting on a bare plate")
end

-- ---------------------------------------------------------------------------
-- The paperdoll's model well (UI-21)
-- ---------------------------------------------------------------------------
--
-- Every other thing the inspector draws sits in something: each of the nineteen cells has a tinted
-- border and a dark ground, and the panel itself lives inside the window's frame. The character
-- preview had neither — a lit model floating on the window's inset with no edge — so the one part of
-- the paperdoll that is not made of squares read as an unfinished hole between two columns of them.
--
-- The frame is asserted as the model's PARENT rather than as a frame that happens to overlap it. A
-- decorative sibling would look identical in a screenshot and behave differently in every way that
-- matters: it would not hide with the model, it would not clip it, and its border would draw
-- underneath or above depending on creation order. Parenting is the claim worth pinning.
local previewFrame = G.KitbagPreviewFrame
H.ok(previewFrame ~= nil, "the paperdoll's character preview is set in a frame of its own")
H.ok(G.KitbagPreviewModel and G.KitbagPreviewModel:GetParent() == previewFrame,
    "…and the model is INSIDE it, so it hides, clips and moves with the well rather than beside it")
H.ok(previewFrame and previewFrame:GetParent() == G.KitbagInspector,
    "…and the well belongs to the inspector panel that owns the cells around it")

H.done()
