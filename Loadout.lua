-- Loadout — a gear-set manager for World of Warcraft Classic.
--
-- Bootstrap only: load order, SavedVariables handoff, and the slash commands. Everything that makes
-- a decision lives in a module beside this one, and the ones that decide anything interesting
-- (LoadoutCore, LoadoutRules) are pure and tested under plain Lua — see Tests/ and CLAUDE.md.

local ADDON = ...

Loadout = Loadout or {}

local Sets = Loadout.Sets
local UI = Loadout.UI
local Events = Loadout.Events
local Minimap_ = Loadout.Minimap
local DB = Loadout.DB

--- Anything that changes stored state calls this. One redraw entry point means a new surface (the
--- rule editor, a broker plugin) gets kept in step by existing code rather than by remembering to.
function Loadout.Refresh()
    UI.Refresh()
end

local function help()
    local say = Sets.Say
    say("commands:")
    say("  |cffffd100/lo|r — open the window")
    say("  |cffffd100/lo save <name>|r — save what you're wearing")
    say("  |cffffd100/lo equip <name>|r — wear a set")
    say("  |cffffd100/lo delete <name>|r — remove a set")
    say("  |cffffd100/lo list|r — what's saved")
    say("  |cffffd100/lo why|r — which rule is choosing your set, and why")
    say("  |cffffd100/lo minimap|r — toggle the minimap button")
end

local function why()
    local report = Events.Explain()
    Sets.Say("auto-swap would choose: %s",
        report.chosen and ("|cffffd100" .. report.chosen .. "|r") or "|cff808080nothing|r")
    for _, entry in ipairs(report.considered) do
        if entry.matched then
            Sets.Say("  |cff40ff40match|r  %s (priority %d)", entry.set, entry.priority)
        else
            Sets.Say("  |cff808080no|r     %s — %s", entry.set, entry.reason)
        end
    end
    if #report.considered == 0 then
        Sets.Say("  no rules yet. The rule editor is on the backlog (RULE-1); rules load from saved data.")
    end
end

local function command(input)
    local cmd, rest = string.match(input or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")

    if cmd == "" then UI.Toggle()
    elseif cmd == "save" then Sets.Save(rest)
    elseif cmd == "equip" or cmd == "wear" then Sets.Equip(rest)
    elseif cmd == "delete" or cmd == "remove" then Sets.Delete(rest)
    elseif cmd == "list" then
        local names = Sets.Names()
        if #names == 0 then
            Sets.Say("no sets yet — |cffffd100/lo save <name>|r saves what you're wearing.")
        else
            Sets.Say("%d set(s): %s", #names, table.concat(names, ", "))
        end
    elseif cmd == "why" then why()
    elseif cmd == "minimap" then Minimap_.SetHidden(not Loadout.db.options.minimap.hide)
    else help()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        -- LoadoutDB is where the old-data question is answered; nothing else reads the raw global.
        LoadoutDB = DB.Load(LoadoutDB)
        Loadout.db = LoadoutDB
    elseif event == "PLAYER_LOGIN" then
        Minimap_.Create()
        Events.Enable()
        Sets.Say("loaded. |cffffd100/lo|r to open, |cffffd100/lo help|r for commands.")
    end
end)

SLASH_LOADOUT1 = "/loadout"
SLASH_LOADOUT2 = "/lo"
SlashCmdList["LOADOUT"] = command
