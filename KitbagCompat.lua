-- KitbagCompat — the ONLY file allowed to branch on the game flavour.
--
-- Every other file gets one shape of API and never asks which client it is running on. Keeping the
-- branch in one place is what lets the pure core stay pure and what makes a Retail port a change to
-- this file rather than a change to all of them.
--
-- The container API is the live example: Blizzard moved GetContainerNumSlots and friends into the
-- C_Container namespace, backporting it to Classic Era along the way, but the loose globals still
-- exist on older clients. Prefer the namespace, fall back to the global, expose one name.

Kitbag = Kitbag or {}

local Compat = {}

local projectId = _G.WOW_PROJECT_ID
Compat.IS_ERA = projectId == _G.WOW_PROJECT_CLASSIC
Compat.IS_MAINLINE = projectId == _G.WOW_PROJECT_MAINLINE
-- Anything that is not Retail is a Classic flavour of some vintage.
Compat.IS_CLASSIC = not Compat.IS_MAINLINE

local container = _G.C_Container

Compat.GetContainerNumSlots = (container and container.GetContainerNumSlots) or _G.GetContainerNumSlots
Compat.GetContainerItemLink = (container and container.GetContainerItemLink) or _G.GetContainerItemLink
Compat.PickupContainerItem = (container and container.PickupContainerItem) or _G.PickupContainerItem
Compat.GetContainerNumFreeSlots =
    (container and container.GetContainerNumFreeSlots) or _G.GetContainerNumFreeSlots

--- The inventory slot id a bag itself occupies, for putting an item into that bag.
Compat.ContainerToInventory = _G.ContainerIDToInventoryID or function(bag) return 19 + bag end

--- The highest bag index to scan. Retail added the reagent bag at index 5.
Compat.LAST_BAG = Compat.IS_MAINLINE and 5 or 4

--- The bank containers, in the order a player would think of them (CORE-2).
--
-- Read from Blizzard's own constants rather than hard-coded, because the count of purchasable bank
-- bag slots differs by flavour and has changed within a flavour. A wrong upper bound here is
-- invisible: the extra bags simply never get scanned and their contents report as "missing".
local BANK_CONTAINER = _G.BANK_CONTAINER or -1
local firstBankBag = (_G.NUM_BAG_SLOTS or 4) + 1
local lastBankBag = firstBankBag + (_G.NUM_BANKBAGSLOTS or 7) - 1

Compat.BANK_BAGS = { BANK_CONTAINER }
for bag = firstBankBag, lastBankBag do
    Compat.BANK_BAGS[#Compat.BANK_BAGS + 1] = bag
end
-- The reagent bank is a Warlords-and-later container, so it exists on Retail and not on any Classic
-- flavour Kitbag currently ships for. Detected, never assumed.
if _G.REAGENTBANK_CONTAINER then
    Compat.BANK_BAGS[#Compat.BANK_BAGS + 1] = _G.REAGENTBANK_CONTAINER
end

-- Retail 11.0 moved a pile of loose globals into C_ namespaces and, in some cases, changed what they
-- return. Both shapes are resolved once here, at load, so nothing downstream has to ask which client
-- it is on. Preferring the namespace and falling back to the global is the same pattern as the
-- container API above, and for the same reason: the fallback is what keeps Classic working.
local itemInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo

--- The spell name for a spell id, across the 11.0 signature change.
--
-- The old GetSpellInfo returned the name first; C_Spell.GetSpellInfo returns a table. Returning the
-- first value of the wrong one would give a table where a string is expected, and every spell rule
-- would compare unequal forever with nothing to show for it.
function Compat.SpellName(spellId)
    if not spellId then return nil end

    local modern = _G.C_Spell and _G.C_Spell.GetSpellInfo
    if modern then
        local info = modern(spellId)
        return info and info.name or nil
    end

    return _G.GetSpellInfo and _G.GetSpellInfo(spellId) or nil
end

--- Item family/equip-location facts the pure planner can't know. Returns the equip location token
-- (e.g. "INVTYPE_2HWEAPON") for an item id, or nil if the client hasn't cached the item yet.
function Compat.EquipLocation(itemId)
    if not itemId then return nil end
    local _, _, _, _, _, _, _, _, equipSlot = itemInfo(itemId)
    return equipSlot
end

--- An item's name, or nil if the client hasn't cached the item yet.
--
-- nil is the common answer for exactly the items this is asked about: gear sitting in the bank on a
-- fresh login. Callers name the slot instead rather than printing a stand-in, because "an item" in a
-- warning about what is going to be destroyed tells the player nothing they can act on.
function Compat.ItemName(itemId)
    if not itemId then return nil end
    return (itemInfo(itemId))
end

--- An item's level, or nil if the client hasn't cached the item yet.
--
-- nil is a real answer and callers must keep it as one: on a fresh login GetItemInfo returns nil for
-- most of a set, and a 0 substituted here would read as "this raid gear is worthless".
function Compat.ItemLevel(itemId)
    if not itemId then return nil end
    local _, _, _, level = itemInfo(itemId)
    return level
end

--- How worn an equipped slot is, as 0..1, or nil where the client has no answer. Items with no
-- durability at all (rings, trinkets) report max 0 and are correctly nil rather than "broken".
function Compat.SlotDurability(slotId)
    local getter = _G.GetInventoryItemDurability
    if not getter then return nil end
    local current, maximum = getter(slotId)
    if not current or not maximum or maximum <= 0 then return nil end
    return current / maximum
end

--- The shapeshift forms this character has, as { [formIndex] = "Bear Form" }.
--
-- Index 0 is "no form" and always exists; GetShapeshiftForm() returns it for everyone, including
-- classes that have no forms at all. The signature of GetShapeshiftFormInfo differs between
-- flavours — Classic returns the name second, later clients return a spell id fourth — so both are
-- handled rather than assuming, since guessing wrong here silently labels every form "form 3".
function Compat.FormLabels()
    local labels = { [0] = "no form" }
    local count = _G.GetNumShapeshiftForms and _G.GetNumShapeshiftForms() or 0
    for i = 1, count do
        local _, second, _, fourth = _G.GetShapeshiftFormInfo(i)
        local name = type(second) == "string" and second or nil
        if not name then name = Compat.SpellName(fourth) end
        labels[i] = name or ("form " .. i)
    end
    return labels
end

--- The spell name out of a UNIT_SPELLCAST_* event's payload, or nil.
--
-- The payload changed shape between flavours: modern clients send (unit, target, castGUID, spellID)
-- and the oldest Classic builds sent (unit, spellName, rank, target). A numeric fourth argument is
-- the discriminator — it is a spell id and nothing else ever is. Guessing wrong would not error, it
-- would just make every spell rule silently dead, which is the failure mode worth spending a branch
-- to avoid.
function Compat.CastSpellName(_, second, _, fourth)
    local spellId = tonumber(fourth)
    if spellId then return Compat.SpellName(spellId) end
    if type(second) == "string" then return second end
    return nil
end

--- Every buff currently on the player, as a set: { ["Mark of the Wild"] = true, … }.
--
-- A set rather than a list because that is what a membership condition tests against, and building
-- it here means the rule engine never has to walk anything. C_UnitAuras is the modern reader and
-- UnitBuff the old one; both exist on some flavours and neither on all.
function Compat.PlayerBuffs()
    local buffs = {}
    local forEach = _G.AuraUtil and _G.AuraUtil.ForEachAura
    if forEach then
        forEach("player", "HELPFUL", nil, function(name)
            if name then buffs[name] = true end
            return false    -- keep going; returning true stops the walk
        end, true)
        return buffs
    end

    local unitBuff = _G.UnitBuff
    if unitBuff then
        for i = 1, 40 do
            local name = unitBuff("player", i)
            if not name then break end
            buffs[name] = true
        end
    end
    return buffs
end

--- Which kind of instance the player is in: the client's own token, or "none" outdoors.
function Compat.InstanceType()
    if not _G.IsInInstance then return "none" end
    local _, kind = _G.IsInInstance()
    return kind or "none"
end

--- An item's icon texture, or nil if the client hasn't cached the item yet.
function Compat.ItemIcon(itemId)
    if not itemId then return nil end
    local _, _, _, _, _, _, _, _, _, texture = itemInfo(itemId)
    return texture
end

--- Every icon the game will let a macro use, as an array of textures — the icon picker's source.
--
-- Built once and kept: it is a few thousand entries and the list cannot change during a session.
-- Two APIs to cover, and neither exists everywhere: the older clients count and index, the newer
-- ones fill a table you hand them.
local macroIcons = nil
function Compat.MacroIcons()
    if macroIcons then return macroIcons end
    macroIcons = {}

    if _G.GetNumMacroIcons and _G.GetMacroIconInfo then
        for i = 1, _G.GetNumMacroIcons() do
            macroIcons[#macroIcons + 1] = _G.GetMacroIconInfo(i)
        end
    elseif _G.GetMacroIcons then
        _G.GetMacroIcons(macroIcons)
        if _G.GetMacroItemIcons then _G.GetMacroItemIcons(macroIcons) end
    end

    return macroIcons
end

--- The key this character's sets are stored under: "Name - Realm".
--
-- The realm has to be in it. Two characters can share a name across realms on one account, and a
-- collision here would merge their gear sets into one list.
function Compat.CharacterKey()
    local name = _G.UnitName("player")
    if not name or name == "" then return nil end
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    return name .. " - " .. realm
end

--- The conditions that plausibly explain the client refusing an equip, read all at once.
--
-- Deliberately NOT the same question as IsBusy: this one reports, it does not decide. Combat and
-- mounted are in here precisely BECAUSE we do not yet know whether they block a swap — ItemRack
-- queues every slot while `UnitAffectingCombat` is true, which is suggestive and is not proof, and
-- guessing wrong in IsBusy would refuse swaps the client would have accepted. Recording them costs
-- nothing and settles the question the next time a swap fails (BUG-9).
--
-- Feature-detected rather than branched on flavour: a condition this client cannot answer comes back
-- nil, which the dump renders as "no" — the honest reading, since an unasked question is not a yes.
function Compat.ActionState()
    return {
        combat = _G.UnitAffectingCombat and _G.UnitAffectingCombat("player") or false,
        mounted = _G.IsMounted and _G.IsMounted() or false,
        dead = _G.UnitIsDeadOrGhost and _G.UnitIsDeadOrGhost("player") or false,
        casting = (_G.UnitCastingInfo and _G.UnitCastingInfo("player")) ~= nil
            or (_G.UnitChannelInfo and _G.UnitChannelInfo("player")) ~= nil,
    }
end

--- Is the player currently in a state where swapping gear will be refused or wasted?
-- Casting is the one people notice: a swap mid-cast cancels it.
function Compat.IsBusy()
    if _G.UnitIsDeadOrGhost("player") then return true end
    if _G.UnitCastingInfo("player") or _G.UnitChannelInfo("player") then return true end
    return false
end

Kitbag.Compat = Compat
return Compat
