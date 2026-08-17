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
Kitbag.char = Kitbag.char or {}
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
    "Compat", "Core", "Rules", "Import", "DB", "Inventory", "Equip", "Sets", "Debug",
    "Events", "Icons", "Picker", "Flyout", "UI", "RulesUI", "Trinkets", "Minimap",
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
    "Compat", "Core", "Rules", "Import", "DB", "Inventory", "Equip", "Sets", "Debug",
    "Events", "Icons", "Picker", "Flyout", "UI", "RulesUI", "Trinkets", "Minimap",
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

H.done()
