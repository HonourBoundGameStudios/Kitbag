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
    IsEnabled = true, IsUserPlaced = true, IsForbidden = true,
}

local newWidget

local widgetMeta
widgetMeta = {
    __index = function(widget, key)
        -- Fields the module set itself are found before __index runs, so anything reaching here is a
        -- client method. Manufactured on demand and cached, so `f:SetPoint` twice is the same
        -- function and a module storing a method reference still works.
        local method
        if NUMBER_GETTERS[key] then
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
G.UISpecialFrames = {}
G.SlashCmdList = {}
G.StaticPopupDialogs = {}
G.InterfaceOptions_AddCategory = function() end
G.UIDropDownMenu_Initialize = function() end
G.UIDropDownMenu_SetWidth = function() end
G.UIDropDownMenu_SetText = function() end
G.UIDropDownMenu_AddButton = function() end
G.UIDropDownMenu_CreateInfo = function() return {} end
G.ToggleDropDownMenu = function() end
G.CloseDropDownMenus = function() end

G.CreateFrame = function(_, name, _, _)
    local frame = newWidget(name)
    if name then G[name] = frame end
    return frame
end

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
G.SaveBindings = function() end
G.GetBindingKey = function() return nil end
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

local EXPECTED = {
    "Compat", "Core", "Rules", "Import", "DB", "Inventory", "Equip", "Sets", "Debug",
    "Events", "Icons", "Picker", "Flyout", "UI", "RulesUI", "Trinkets", "Minimap",
    "Options", "Bindings", "Broker",
}
for _, key in ipairs(EXPECTED) do
    H.ok(type(G.Kitbag[key]) == "table", "Kitbag." .. key .. " is registered on the namespace")
end

H.done()
