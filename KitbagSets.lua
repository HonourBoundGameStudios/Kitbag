-- KitbagSets — the service the UI, the slash commands and the rule engine all go through.
--
-- Thin by design: it reads the world (Inventory), decides (Core), and performs (Equip). It owns no
-- logic of its own beyond storage and the user-facing report, so there is exactly one code path
-- that equips a set and exactly one place a bug in that path can live.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Inventory = Kitbag.Inventory
local Equip = Kitbag.Equip

local Sets = {}

local function db() return Kitbag.db end

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
    set.icon = db().sets[name] and db().sets[name].icon or nil
    db().sets[name] = set
    say("saved |cffffd100%s|r.", name)
    Kitbag.Refresh()
    return set
end

function Sets.Delete(name)
    if not db().sets[name] then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    db().sets[name] = nil
    if db().lastSet == name then db().lastSet = nil end
    say("deleted |cffffd100%s|r.", name)
    Kitbag.Refresh()
    return true
end

--- Names, sorted, so the UI and /kit list agree and neither reshuffles between openings.
function Sets.Names()
    local names = {}
    for name in pairs(db().sets) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Build the plan for a set without performing it — what the UI previews on hover.
function Sets.Preview(name)
    local set = db().sets[name]
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
    for name, set in pairs(db().sets) do
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
        local slots = {}
        for _, m in ipairs(plan.missing) do
            local s = Core.SlotById(m.slot)
            slots[#slots + 1] = s and s.label or ("slot " .. m.slot)
        end
        say("|cffff8080%d item(s) not found|r for |cffffd100%s|r: %s.",
            #plan.missing, name, table.concat(slots, ", "))
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
        db().lastSet = ok and label or db().lastSet
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
