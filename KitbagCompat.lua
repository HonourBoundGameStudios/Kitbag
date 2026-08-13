-- KitbagCompat — the ONLY file allowed to branch on the game flavour.
--
-- Every other file gets one shape of API and never asks which client it is running on. Keeping the
-- branch in one place is what lets the pure core stay pure and what makes a later Retail port a
-- change to this file rather than a change to all of them (see the fleet's `wow-retail-port` skill).
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

--- Item family/equip-location facts the pure planner can't know. Returns the equip location token
-- (e.g. "INVTYPE_2HWEAPON") for an item id, or nil if the client hasn't cached the item yet.
function Compat.EquipLocation(itemId)
    if not itemId then return nil end
    local _, _, _, _, _, _, _, _, equipSlot = _G.GetItemInfo(itemId)
    return equipSlot
end

--- An item's level, or nil if the client hasn't cached the item yet.
--
-- nil is a real answer and callers must keep it as one: on a fresh login GetItemInfo returns nil for
-- most of a set, and a 0 substituted here would read as "this raid gear is worthless".
function Compat.ItemLevel(itemId)
    if not itemId then return nil end
    local _, _, _, level = _G.GetItemInfo(itemId)
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

--- Is the player currently in a state where swapping gear will be refused or wasted?
-- Casting is the one people notice: a swap mid-cast cancels it.
function Compat.IsBusy()
    if _G.UnitIsDeadOrGhost("player") then return true end
    if _G.UnitCastingInfo("player") or _G.UnitChannelInfo("player") then return true end
    return false
end

Kitbag.Compat = Compat
return Compat
