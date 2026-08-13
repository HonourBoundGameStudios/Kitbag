-- PanoplyCompat — the ONLY file allowed to branch on the game flavour.
--
-- Every other file gets one shape of API and never asks which client it is running on. Keeping the
-- branch in one place is what lets the pure core stay pure and what makes a later Retail port a
-- change to this file rather than a change to all of them (see the fleet's `wow-retail-port` skill).
--
-- The container API is the live example: Blizzard moved GetContainerNumSlots and friends into the
-- C_Container namespace, backporting it to Classic Era along the way, but the loose globals still
-- exist on older clients. Prefer the namespace, fall back to the global, expose one name.

Panoply = Panoply or {}

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

--- Item family/equip-location facts the pure planner can't know. Returns the equip location token
-- (e.g. "INVTYPE_2HWEAPON") for an item id, or nil if the client hasn't cached the item yet.
function Compat.EquipLocation(itemId)
    if not itemId then return nil end
    local _, _, _, _, _, _, _, _, equipSlot = _G.GetItemInfo(itemId)
    return equipSlot
end

--- Is the player currently in a state where swapping gear will be refused or wasted?
-- Casting is the one people notice: a swap mid-cast cancels it.
function Compat.IsBusy()
    if _G.UnitIsDeadOrGhost("player") then return true end
    if _G.UnitCastingInfo("player") or _G.UnitChannelInfo("player") then return true end
    return false
end

Panoply.Compat = Compat
return Compat
