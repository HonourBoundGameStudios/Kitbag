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

--- The stored delta flattened against its ancestors — what every caller actually wants to wear.
--- Stored sets are only ever read through this, so a delta and a full outfit behave identically.
local function resolved(name)
    return Core.Resolve(char().sets, name)
end

Sets.Resolve = resolved

--- Save what is currently worn under `name`, overwriting any set of that name.
--
-- A set that declares a parent is re-saved as a delta: capture reads all nineteen slots, and
-- everything the parent already gets right is dropped. Keeping it would defeat the point — the
-- shared piece would be duplicated again the first time the child was re-saved.
function Sets.Save(name)
    if type(name) ~= "string" or name:match("^%s*$") then
        say("give the set a name — |cffffd100/kit save Tank|r")
        return nil
    end
    name = name:match("^%s*(.-)%s*$")

    local existing = char().sets[name]
    local set = Core.CaptureSet(Inventory.Equipped(), name)
    set.icon = existing and existing.icon or nil
    set.parent = existing and existing.parent or nil

    if set.parent then
        set = Core.Diff(set, resolved(set.parent))
        say("saved |cffffd100%s|r as a delta on |cffffd100%s|r.", name, set.parent)
    else
        say("saved |cffffd100%s|r.", name)
    end

    char().sets[name] = set
    Kitbag.Refresh()
    return set
end

--- Declare (or clear, with a nil parent) which set this one is a delta on.
--
-- Re-diffs immediately, so the shared pieces disappear from the child the moment the relationship is
-- declared rather than at the next save — otherwise the child keeps overriding the parent with
-- identical values and changing the parent appears to do nothing.
function Sets.Inherit(name, parentName)
    local set = char().sets[name]
    if not set then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end

    if not parentName then
        if not set.parent then
            say("|cffffd100%s|r does not inherit from anything.", name)
            return false
        end
        -- Flatten what it was inheriting back into itself. Dropping the parent must not silently
        -- drop the pieces that were coming from it.
        local flat = resolved(name)
        flat.parent = nil
        char().sets[name] = flat
        say("|cffffd100%s|r no longer inherits — its inherited pieces are now its own.", name)
        Kitbag.Refresh()
        return true
    end

    if not char().sets[parentName] then
        say("no set called |cffffd100%s|r to inherit from.", parentName)
        return false
    end
    if parentName == name then
        say("a set cannot inherit from itself.")
        return false
    end

    -- Walk the prospective ancestry before committing. A cycle would be resolvable (Core.Resolve
    -- terminates on one) but the outfit it produced would depend on where you started reading, which
    -- is exactly the unpredictability inheritance is meant to remove.
    -- Keyed by the table's own key, not by set.name: the two can drift apart (an import, a hand-
    -- edited SavedVariables) and the key is what `parent` actually points at.
    local cursor, hops = parentName, 0
    while cursor and hops <= 64 do
        if cursor == name then
            say("|cffff8080that would make a loop|r — |cffffd100%s|r already inherits from " ..
                "|cffffd100%s|r.", parentName, name)
            return false
        end
        local set_ = char().sets[cursor]
        cursor = set_ and set_.parent or nil
        hops = hops + 1
    end

    set.parent = parentName
    char().sets[name] = Core.Diff(set, resolved(parentName))
    say("|cffffd100%s|r now inherits from |cffffd100%s|r — shared pieces live in the parent.",
        name, parentName)
    Kitbag.Refresh()
    return true
end

function Sets.Delete(name)
    if not char().sets[name] then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    -- Children keep working — Core.Resolve treats a vanished parent as contributing nothing — but
    -- they quietly become smaller sets than they were, so say so rather than let it be discovered
    -- by equipping one.
    local orphans = {}
    for other, set in pairs(char().sets) do
        if set.parent == name then orphans[#orphans + 1] = other end
    end
    table.sort(orphans)

    char().sets[name] = nil
    if char().lastSet == name then char().lastSet = nil end
    say("deleted |cffffd100%s|r.", name)
    if #orphans > 0 then
        say("|cffff8080%s inherited from it|r and now covers only its own slots.",
            table.concat(orphans, ", "))
    end
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
    local set = resolved(name)
    if not set then return nil end
    local equipped, where, meta = Inventory.Snapshot(set)
    return Core.Plan(equipped, set, where, meta), set
end

--- Everything the window needs about every set, from ONE reading of the world:
--- { [name] = { plan = …, totals = … } }.
--
-- Per row, this would rescan all five bags, the bank and the durability of every worn slot. Worse
-- than slow: the rows would be answering slightly different questions, since the bags can change
-- between two scans. One snapshot means every row agrees with every other row and with the button.
function Sets.Overview()
    local equipped, where = Inventory.Equipped(), Inventory.Bagged()
    local dur = Inventory.WornDurability()
    local free = Inventory.FreeBagSlots()
    local out = {}
    for name in pairs(char().sets) do
        local set = resolved(name)
        out[name] = {
            plan = Core.Plan(equipped, set, where, Inventory.Meta(set, free)),
            totals = Core.Totals(set, Inventory.ItemInfo(set, dur)),
        }
    end
    return out
end

--- Equip a set. `silent` suppresses the chat report for rule-driven swaps, which would otherwise
--- narrate every shapeshift.
function Sets.Equip(name, silent)
    local set = resolved(name)
    if not set then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    return Sets.Apply(set, name, silent)
end

--- Equip an outfit that is not necessarily a saved set.
--
-- The restore points RULE-4 remembers are exactly this: a snapshot of what you happened to be
-- wearing, which may match no saved set at all. Everything below used to live in Sets.Equip; it is
-- split out rather than duplicated so there stays exactly one code path that equips anything.
function Sets.Apply(set, label, silent)
    local equipped, where, meta = Inventory.Snapshot(set)
    local plan = Core.Plan(equipped, set, where, meta)

    -- Report what can't be done BEFORE doing the rest. Half a set is a legitimate outcome — the
    -- other half may be in the bank — but it must never be a silent one.
    if #plan.missing > 0 then
        -- "In your bank" and "nowhere to be found" are separate lines because they ask for separate
        -- things from the player: one is a walk, the other is a lost item.
        local lost, atBank = {}, {}
        for _, m in ipairs(plan.missing) do
            local s = Core.SlotById(m.slot)
            local slotLabel = s and s.label or ("slot " .. m.slot)
            local into = m.where == "bank" and atBank or lost
            into[#into + 1] = slotLabel
        end
        if #lost > 0 then
            say("|cffff8080%d item(s) not found|r for |cffffd100%s|r: %s.",
                #lost, label, table.concat(lost, ", "))
        end
        if #atBank > 0 then
            say("|cffffd100%d item(s) are in your bank|r for |cffffd100%s|r: %s. " ..
                "|cff808080Open the bank and equip again to finish the set.|r",
                #atBank, label, table.concat(atBank, ", "))
        end
    end

    if plan.empty then
        if not silent then say("already wearing |cffffd100%s|r.", label) end
        return true
    end

    -- Refuse before moving anything. The alternative is the driver spending its full retry budget on
    -- an unequip the client will never accept and then reporting "stuck on Off hand", which reads as
    -- a Kitbag bug rather than as a full bag.
    if plan.blocked == "bags" then
        say("|cffff8080your bags are full|r — |cffffd100%s|r needs %d free slot(s) to put what " ..
            "it takes off.", label, plan.needsBagSlots)
        return false
    end

    if Equip.IsRunning() then
        say("|cffff8080busy|r — a swap is already in progress.")
        return false
    end

    return Equip.Run(plan, label, function(ok, failed, applied)
        -- Only a real set becomes `lastSet`. A restore point is an outfit, not a set, and recording
        -- it would leave the rule engine comparing against a name no set list contains.
        if ok and char().sets[applied] then char().lastSet = applied end
        if ok then
            if not silent and db().options.announce then say("equipped |cffffd100%s|r.", applied) end
        else
            local s = failed and Core.SlotById(failed.to)
            say("|cffff8080could not finish|r |cffffd100%s|r — stuck on %s.",
                tostring(applied), s and s.label or "an unknown slot")
        end
        Kitbag.Refresh()
    end)
end

Kitbag.Sets = Sets
return Sets
