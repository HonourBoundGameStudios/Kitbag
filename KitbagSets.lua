-- KitbagSets — the service the UI, the slash commands and the rule engine all go through.
--
-- Thin by design: it reads the world (Inventory), decides (Core), and performs (Equip). It owns no
-- logic of its own beyond storage and the user-facing report, so there is exactly one code path
-- that equips a set and exactly one place a bug in that path can live.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Inventory = Kitbag.Inventory
local Equip = Kitbag.Equip
local Import = Kitbag.Import

local Sets = {}

local function db() return Kitbag.db end

-- Sets and lastSet belong to this character (CORE-6); options belong to the account.
local function char() return Kitbag.char end

local function say(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff8fd3ffKitbag|r: " .. string.format(fmt, ...))
end

Sets.Say = say

--- Save what is currently worn under `name`, overwriting any set of that name.
function Sets.Save(name)
    if type(name) ~= "string" or name:match("^%s*$") then
        say("give the set a name — |cffffd100/kit save Tank|r")
        return nil
    end
    name = name:match("^%s*(.-)%s*$")

    local set = Core.CaptureSet(Inventory.Equipped(), name)
    set.icon = char().sets[name] and char().sets[name].icon or nil
    char().sets[name] = set
    say("saved |cffffd100%s|r.", name)
    Kitbag.Refresh()
    return set
end

function Sets.Delete(name)
    if not char().sets[name] then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    char().sets[name] = nil
    if char().lastSet == name then char().lastSet = nil end
    say("deleted |cffffd100%s|r.", name)
    Kitbag.Refresh()
    return true
end

--- Names, sorted, so the UI and /kit list agree and neither reshuffles between openings.
function Sets.Names()
    local names = {}
    for name in pairs(char().sets) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Bring this character's ItemRack sets across, if that addon left any behind.
--
-- The conversion and every judgement call in it live in KitbagImport, which is pure and tested; this
-- reads the global ItemRack wrote and reports. Existing Kitbag sets are never overwritten — the
-- clash is named so it can be renamed and retried, because silently replacing curated gear sets is
-- unrecoverable and refusing is not.
function Sets.ImportItemRack()
    local result = Import.FromItemRack(_G.ItemRackUser, char().sets)

    if result.imported == 0 and #result.skipped == 0 then
        say("no ItemRack sets found for this character. |cff808080ItemRack stores sets per " ..
            "character, so log in as the one that has them.|r")
        return result
    end

    local names = {}
    for name, set in pairs(result.sets) do
        char().sets[name] = set
        names[#names + 1] = name
    end
    table.sort(names)

    if #names > 0 then
        say("imported |cffffd100%d|r set(s) from ItemRack: %s.", #names, table.concat(names, ", "))
    else
        say("nothing new to import from ItemRack.")
    end

    -- Only the actionable skips are worth a line. ItemRack's ~CombatQueue/~Unequip are on every
    -- character and are nobody's sets, so naming them every time is noise.
    local clashed = {}
    for _, s in ipairs(result.skipped) do
        if s.why == "exists" then clashed[#clashed + 1] = s.name end
    end
    if #clashed > 0 then
        say("|cffff8080kept your existing|r %s — rename yours and import again to get ItemRack's.",
            table.concat(clashed, ", "))
    end
    if result.unreadable > 0 then
        say("|cffff8080%d item(s)|r could not be read and were left out; those slots are untouched " ..
            "rather than emptied.", result.unreadable)
    end

    Kitbag.Refresh()
    return result
end

--- Build the plan for a set without performing it — what the UI previews on hover.
function Sets.Preview(name)
    local set = char().sets[name]
    if not set then return nil end
    local equipped, where, meta = Inventory.Snapshot(set)
    return Core.Plan(equipped, set, where, meta), set
end

--- Plan every set against ONE reading of the world: { [name] = plan }.
--
-- The window shows per-row readiness, and asking Preview() per row would rescan all five bags once
-- per row. Worse than slow: the rows would be answering slightly different questions, since the
-- bags can change between two scans. One snapshot means every row agrees.
function Sets.PreviewAll()
    local equipped, where = Inventory.Equipped(), Inventory.Bagged()
    local plans = {}
    for name, set in pairs(char().sets) do
        plans[name] = Core.Plan(equipped, set, where, Inventory.Meta(set))
    end
    return plans
end

--- Equip a set. `silent` suppresses the chat report for rule-driven swaps, which would otherwise
--- narrate every shapeshift.
function Sets.Equip(name, silent)
    local plan, set = Sets.Preview(name)
    if not set then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end

    -- Report what can't be done BEFORE doing the rest. Half a set is a legitimate outcome — the
    -- other half may be in the bank — but it must never be a silent one.
    if #plan.missing > 0 then
        -- "In your bank" and "nowhere to be found" are separate lines because they ask for separate
        -- things from the player: one is a walk, the other is a lost item.
        local lost, atBank = {}, {}
        for _, m in ipairs(plan.missing) do
            local s = Core.SlotById(m.slot)
            local label = s and s.label or ("slot " .. m.slot)
            local into = m.where == "bank" and atBank or lost
            into[#into + 1] = label
        end
        if #lost > 0 then
            say("|cffff8080%d item(s) not found|r for |cffffd100%s|r: %s.",
                #lost, name, table.concat(lost, ", "))
        end
        if #atBank > 0 then
            say("|cffffd100%d item(s) are in your bank|r for |cffffd100%s|r: %s. " ..
                "|cff808080Open the bank and equip again to finish the set.|r",
                #atBank, name, table.concat(atBank, ", "))
        end
    end

    if plan.empty then
        if not silent then say("already wearing |cffffd100%s|r.", name) end
        return true
    end

    if Equip.IsRunning() then
        say("|cffff8080busy|r — a swap is already in progress.")
        return false
    end

    return Equip.Run(plan, name, function(ok, failed, label)
        char().lastSet = ok and label or char().lastSet
        if ok then
            if not silent and db().options.announce then say("equipped |cffffd100%s|r.", label) end
        else
            local s = failed and Core.SlotById(failed.to)
            say("|cffff8080could not finish|r |cffffd100%s|r — stuck on %s.",
                tostring(label), s and s.label or "an unknown slot")
        end
        Kitbag.Refresh()
    end)
end

Kitbag.Sets = Sets
return Sets
