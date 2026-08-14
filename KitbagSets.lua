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
local Compat = Kitbag.Compat

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
--
-- Refuses, and returns `nil, lost`, when the save would drop gear that is not on the player (BUG-3):
-- a set built by hand out of bank items names things a capture cannot see, and overwriting it
-- destroys work nothing can rebuild. `force` is the caller's answer once it has asked. The check is
-- against the RESOLVED set, because what the player stands to lose is what the set wears, not what
-- this particular delta happens to store.
function Sets.Save(name, force)
    name = Core.CleanName(name)
    if not name then
        say("give the set a name — |cffffd100/kit save Tank|r")
        return nil
    end

    local existing = char().sets[name]
    local equipped = Inventory.Equipped()

    if existing and not force then
        local lost = Core.SaveLoss(resolved(name), equipped)
        if #lost > 0 then return nil, lost end
    end

    local set = Core.CaptureSet(equipped, name)
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

--- The slots a refused save would have dropped, as one readable line (BUG-3).
--
-- Named per slot, with the item where the client can name it. The slot is what the player recognises
-- — they put it there — and it is also the half that is always available, since the items most
-- likely to be listed here are the uncached ones sitting in the bank.
function Sets.LossText(lost)
    local parts = {}
    for _, entry in ipairs(lost or {}) do
        local slot = Core.SlotById(entry.slot)
        local item = Compat.ItemName(Core.ItemId(entry.key))
        parts[#parts + 1] = item and string.format("%s (%s)", slot.label, item) or slot.label
    end
    return table.concat(parts, ", ")
end

--- Start an empty set, to be filled in slot by slot from the inspector (UI-16).
--
-- Until now the only door into creating a set was wearing it first, which is precisely the awkward
-- part of making a second set: half of it is in the bank. An empty set has no opinion about any
-- slot, so equipping it is a no-op until the picker puts something in it — which means it can be
-- built out of gear you never take off the shelf.
--
-- Never overwrites. Save deliberately does, because re-saving a set you are wearing is the whole
-- gesture; replacing a curated set with an empty one is unrecoverable, and refusing is not.
function Sets.New(name)
    name = Core.CleanName(name)
    if not name then
        say("give the set a name — |cffffd100/kit new Tank|r")
        return nil
    end
    if char().sets[name] then
        say("|cffffd100%s|r already exists. |cff808080Pick another name, or use Save to " ..
            "overwrite it with what you are wearing.|r", name)
        return nil
    end

    local set = { name = name, slots = {} }
    char().sets[name] = set
    say("started |cffffd100%s|r — empty. |cff808080Click a slot in the window to fill it in.|r",
        name)
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

    -- Walk the prospective ancestry before committing. The same walk the window's menu filters with,
    -- so the two doors into inheritance cannot disagree about what a loop is.
    if Core.Descends(char().sets, parentName, name) then
        say("|cffff8080that would make a loop|r — |cffffd100%s|r already inherits from " ..
            "|cffffd100%s|r.", parentName, name)
        return false
    end

    set.parent = parentName
    char().sets[name] = Core.Diff(set, resolved(parentName))
    say("|cffffd100%s|r now inherits from |cffffd100%s|r — shared pieces live in the parent.",
        name, parentName)
    Kitbag.Refresh()
    return true
end

--- What the confirmation says under "Delete <name>?" — the consequences, in a sentence (BUG-8).
--
-- Empty when there are none, so the prompt does not pad itself with reassurance nobody needs; a
-- dialog that always has a paragraph in it is a dialog people stop reading.
function Sets.DeleteWarning(name)
    local impact = Core.DeleteImpact(char().sets, name)
    if #impact.orphans == 0 then return "This cannot be undone." end
    return string.format("%s inherited from it and will keep only their own slots.\n" ..
        "This cannot be undone.", table.concat(impact.orphans, ", "))
end

function Sets.Delete(name)
    if not char().sets[name] then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    -- Children keep working — Core.Resolve treats a vanished parent as contributing nothing — but
    -- they quietly become smaller sets than they were, so say so rather than let it be discovered
    -- by equipping one. Read through the same pure answer the confirmation used, so the prompt and
    -- the deletion cannot name different sets.
    local orphans = Core.DeleteImpact(char().sets, name).orphans

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

--- Which set this one is a delta on, or nil.
function Sets.ParentOf(name)
    local set = char().sets[name]
    return set and set.parent or nil
end

--- The sets the window may offer as this one's parent, sorted (UI-11).
function Sets.ParentChoices(name)
    return Core.ParentChoices(char().sets, name)
end

--- Is there anything to import for this character? (UI-18)
--
-- The window asks before drawing its Import button; nil means don't. The judgement is `Import.Offer`
-- and the reading of the world is here, so KitbagUI never touches a global another addon wrote.
function Sets.ImportOffer()
    return Import.Offer(_G.ItemRackUser, char().sets)
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
    -- The options and the keybindings (COMPAT-5). Only mapped options come across, and only for
    -- someone who is importing anyway — this never runs on its own.
    local options = Import.OptionsFromItemRack(_G.ItemRackSettings)
    local changed = 0
    for path, value in pairs(options) do
        if Kitbag.DB.Set(db(), path, value) then changed = changed + 1 end
    end
    if changed > 0 then
        say("brought %d ItemRack option(s) across. |cff808080The rest configure a UI Kitbag does " ..
            "not have and were left alone.|r", changed)
        Kitbag.Minimap.SetHidden(db().options.minimap.hide)
        Kitbag.Trinkets.SetHidden(db().options.trinkets.hide)
    end

    local bound = 0
    for _, set in pairs(result.sets) do
        if set.key then bound = bound + 1 end
    end
    if bound > 0 then
        Kitbag.Bindings.Apply()
        say("bound |cffffd100%d|r set(s) to the keys ItemRack had them on. |cff808080Kitbag " ..
            "re-applies these each login and never writes them into your saved bindings.|r", bound)
    end

    if result.unreadable > 0 then
        say("|cffff8080%d item(s)|r could not be read and were left out; those slots are untouched " ..
            "rather than emptied.", result.unreadable)
    end

    Kitbag.Refresh()
    return result
end

--- Make (or refresh) the macro for a set and put it on the cursor, ready to drop on a bar (UI-8).
--
-- The client will not let an addon place a button on the action bar; a macro on the cursor is the
-- sanctioned way, and it is also what the player ends up owning afterwards — the button keeps
-- working whether or not Kitbag is loaded, it just says so in chat when it is not.
function Sets.PickupMacro(name)
    if not char().sets[name] then return false end

    -- Macros cannot be created or edited in combat. Saying so beats a silent no-op that looks like
    -- the drag simply not working.
    if InCombatLockdown() then
        say("|cffff8080not in combat|r — drop a set on your bar afterwards.")
        return false
    end

    -- Every macro name this character's OTHER sets already own, so a truncated name cannot land on
    -- one of theirs and repoint it.
    local taken = {}
    for other in pairs(char().sets) do
        if other ~= name then taken[Core.MacroName(other, {})] = true end
    end

    local macroName = Core.MacroName(name, taken)
    local index = GetMacroIndexByName(macroName)
    local icon = Sets.Icon(name)

    if index and index > 0 then
        EditMacro(index, macroName, icon, Core.MacroBody(name))
    else
        -- Per-character rather than account-wide: sets are per character, so an account macro would
        -- appear on alts that have no such set. The last argument is the per-character flag.
        index = CreateMacro(macroName, icon, Core.MacroBody(name), true)
    end

    if not index or index == 0 then
        say("|cffff8080no free macro slots|r — delete one and try again.")
        return false
    end

    PickupMacro(index)
    return true
end

--- Put one item in one slot, through the same planner and driver everything else uses (UI-5).
--
-- Deliberately not a shortcut straight to PickupInventoryItem: the flyout's click has to free the
-- off hand for a two-hander and refuse when the bags are full exactly like equipping a set does, and
-- the only way to be sure of that is for it to be the same code.
function Sets.EquipItem(key, slotId)
    local slot = Core.SlotById(slotId)
    if not slot then return false end
    return Sets.Apply({ slots = { [slotId] = key } }, slot.label, true)
end

--- Put one item in one slot of a stored set, or take the slot out of it (UI-14).
--
-- Writes to the STORED set, not the resolved one: a set that inherits stores only what differs, and
-- flattening it here would silently sever it from its parent the first time a slot was edited.
-- Core.SetSlot owns what the three values mean and refuses anything it cannot store.
function Sets.SetSlot(name, slotId, key)
    local set = char().sets[name]
    if not set then
        say("no set called |cffffd100%s|r.", tostring(name))
        return false
    end
    if not Core.SetSlot(set, slotId, key) then return false end
    Kitbag.Refresh()
    return true
end

--- The texture to show for a set (UI-4).
--
-- A chosen icon wins. Otherwise the set borrows one from the item that best identifies it, because
-- a list of identical question marks is no better than a list of names. The question mark is the
-- last resort, and is also what shows while the client has not cached the item yet — briefly, on a
-- fresh login, and then it resolves.
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

function Sets.Icon(name)
    local stored = char().sets[name]
    if stored and stored.icon then return stored.icon end

    local set = resolved(name)
    local key = set and Core.IconItem(set)
    return (key and Compat.ItemIcon(Core.ItemId(key))) or QUESTION_MARK
end

Sets.QUESTION_MARK = QUESTION_MARK

--- Give a set an icon, or clear it back to the borrowed one with nil.
function Sets.SetIcon(name, texture)
    local set = char().sets[name]
    if not set then return false end
    set.icon = texture
    Kitbag.Refresh()
    return true
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

    -- Ahead of the "already wearing it" line, which a blank set would otherwise get: it has nothing
    -- to do for the opposite reason, and saying you are wearing a set that names nothing is how a
    -- half-built set looks finished (UI-16).
    if plan.nothing then
        if not silent then
            say("|cffffd100%s|r is empty — |cff808080click a slot in the window to fill it in.|r",
                label)
        end
        return true
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
