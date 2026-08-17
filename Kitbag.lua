-- Kitbag — a gear-set manager for World of Warcraft Classic.
--
-- Bootstrap only: load order, SavedVariables handoff, and the slash commands. Everything that makes
-- a decision lives in a module beside this one, and the ones that decide anything interesting
-- (KitbagCore, KitbagRules) are pure and tested under plain Lua — see Tests/.

local ADDON = ...

Kitbag = Kitbag or {}

local Sets = Kitbag.Sets
local UI = Kitbag.UI
local RulesUI = Kitbag.RulesUI
local Events = Kitbag.Events
local Minimap_ = Kitbag.Minimap
local DB = Kitbag.DB
local Compat = Kitbag.Compat

--- Anything that changes stored state calls this. One redraw entry point means a new surface (the
--- rule editor, a broker plugin) gets kept in step by existing code rather than by remembering to.
function Kitbag.Refresh()
    UI.Refresh()
    RulesUI.Refresh()
    Kitbag.Options.Refresh()
    Kitbag.Broker.Refresh()
end

local function help()
    local say = Sets.Say
    say("commands:")
    say("  |cffffd100/kit|r — open the window")
    say("  |cffffd100/kit save <name>|r — save what you're wearing")
    say("  |cffffd100/kit new <name>|r — start an empty set, to fill in from the window")
    say("  |cffffd100/kit equip <name>|r — wear a set")
    say("  |cffffd100/kit delete <name>|r — remove a set")
    say("  |cffffd100/kit list|r — what's saved")
    say("  |cffffd100/kit inherit <set> from <parent>|r — make a set a delta on another")
    say("  |cffffd100/kit inherit <set> none|r — stop inheriting, keeping the pieces")
    say("  |cffffd100/kit copy <set> to <character>|r — give an alt a copy of a set")
    say("  |cffffd100/kit copy|r — which characters you can copy to")
    say("  |cffffd100/kit rules|r — the auto-swap rule editor")
    say("  |cffffd100/kit options|r — auto-swap, announcements, minimap, trinket bar")
    say("  |cffffd100/kit why|r — which rule is choosing your set, and why")
    say("  |cffffd100/kit import|r — bring this character's ItemRack sets across")
    say("  |cffffd100/kit minimap|r — toggle the minimap button")
    say("  |cffffd100/kit trinkets|r — toggle the trinket quick-use bar")
    say("  |cffffd100/kit debug|r — dump gear, bags, sets, rules and plans for a bug report")
    say("  |cffffd100/kit verify|r — check the addon's own frames and report what could not be checked")
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
        Sets.Say("  no rules yet — |cffffd100/kit rules|r to write one.")
    end
end

local function command(input)
    local cmd, rest = string.match(input or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")

    if cmd == "" then UI.Toggle()
    elseif cmd == "save" or cmd == "resave" then
        -- `resave` is `save` having already answered the "this would drop gear you are not
        -- wearing" question. A separate word rather than a flag on `save`, because a flag would be
        -- indistinguishable from part of a set's name.
        local set, lost = Sets.Save(rest, cmd == "resave")
        if not set and lost then
            Sets.Say("|cffff8080%s|r names gear you are not wearing: %s.", rest, Sets.LossText(lost))
            Sets.Say("saving over it would drop those. |cffffd100/kit resave %s|r to do it anyway.",
                rest)
        end
    elseif cmd == "new" then Sets.New(rest)
    elseif cmd == "equip" or cmd == "wear" then Sets.Equip(rest)
    elseif cmd == "delete" or cmd == "remove" then Sets.Delete(rest)
    elseif cmd == "list" then
        local names = Sets.Names()
        if #names == 0 then
            Sets.Say("no sets yet — |cffffd100/kit save <name>|r saves what you're wearing.")
        else
            Sets.Say("%d set(s): %s", #names, table.concat(names, ", "))
        end
    elseif cmd == "inherit" then
        -- "from" is the separator because set names contain spaces and a positional split would
        -- make "Raid Fire" unaddressable.
        local child, parent = string.match(rest, "^(.-)%s+from%s+(.+)$")
        if child then
            Sets.Inherit(child, parent)
        else
            local lone = string.match(rest, "^(.-)%s+none$")
            if lone then
                Sets.Inherit(lone, nil)
            else
                Sets.Say("|cffffd100/kit inherit Raid Fire from Raid|r, or " ..
                    "|cffffd100/kit inherit Raid Fire none|r.")
            end
        end
    elseif cmd == "copy" then
        -- " to " is the separator for the reason "inherit … from …" has one, and here BOTH halves
        -- can contain spaces: sets are called "Raid Fire" and character keys are "Name - Realm".
        --
        -- GREEDY on the left, which is the opposite of the obvious `(.-)`. The character key is the
        -- half with a fixed shape — one name, one realm, and no " to " in either — so the LAST
        -- separator is always the real one. Splitting on the first would try to copy "Raid" to a
        -- character called "Ruin to Deller - Whitemane" and refuse, naming someone nobody typed.
        local set, who = string.match(rest, "^(.+)%s+to%s+(.+)$")
        if set then
            Sets.CopyTo(set, who)
        else
            -- Naming the characters beats printing usage: the hard half of this command is
            -- remembering exactly how a character key is spelled, and only Kitbag knows.
            local targets = Sets.CopyTargets()
            if #targets == 0 then
                Sets.Say("no other characters yet — |cff808080Kitbag can copy to any character it " ..
                    "has seen log in.|r")
            else
                Sets.Say("|cffffd100/kit copy <set> to <character>|r — %s", table.concat(targets, ", "))
            end
        end
    elseif cmd == "rules" then RulesUI.Toggle()
    elseif cmd == "options" or cmd == "config" then Kitbag.Options.Toggle()
    elseif cmd == "why" then why()
    elseif cmd == "import" then Sets.ImportItemRack()
    elseif cmd == "minimap" then Minimap_.SetHidden(not Kitbag.db.options.minimap.hide)
    elseif cmd == "trinkets" then Kitbag.Trinkets.SetHidden(not Kitbag.db.options.trinkets.hide)
    elseif cmd == "debug" then Kitbag.Debug.Toggle()
    elseif cmd == "verify" then
        -- The summary goes to chat so the player knows it ran and whether anything failed; the
        -- detail goes to SavedVariables, because the interesting part is longer than the chat frame
        -- keeps and needs to be readable by someone who is not sitting at this machine.
        local lines = Kitbag.Verify.Store()
        Sets.Say("self-check done — %s", tostring(lines[#lines]))
        Sets.Say("|cffffd100/reload|r to write the full report to disk.")
    else help()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        -- KitbagDB is where the old-data question is answered; nothing else reads the raw global.
        KitbagDB = DB.Load(KitbagDB)
        Kitbag.db = KitbagDB
    elseif event == "PLAYER_LOGIN" then
        -- Sets and rules are this character's; options are the account's. The name and realm are
        -- only guaranteed to be readable from PLAYER_LOGIN on, so the bucket is bound here rather
        -- than at ADDON_LOADED — nothing can ask for a set before then.
        Kitbag.char = DB.Character(KitbagDB, Compat.CharacterKey())
        Minimap_.Create()
        Events.Enable()
        Kitbag.Flyout.Enable()
        Kitbag.Trinkets.Create()
        Kitbag.Bindings.Apply()
        -- No-op unless the player has a broker display that already provides LibDataBroker.
        Kitbag.Broker.Enable()
        Sets.Say("loaded. |cffffd100/kit|r to open, |cffffd100/kit help|r for commands.")
    end
end)

SLASH_KITBAG1 = "/kitbag"
SLASH_KITBAG2 = "/kit"
SlashCmdList["KITBAG"] = command
