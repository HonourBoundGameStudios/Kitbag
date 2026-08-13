-- PanoplyInventory — read the world into the plain tables PanoplyCore.Plan expects.
--
-- This file is all client API and no decisions. Everything it produces is inert data, which is what
-- lets the planner be tested without a game: Snapshot() here, Plan() there, Apply() in PanoplyEquip.

Panoply = Panoply or {}

local Core = Panoply.Core
local Compat = Panoply.Compat

local Inventory = {}

--- What is worn right now: { [slotId] = itemKey }. Empty slots are simply absent.
function Inventory.Equipped()
    local worn = {}
    for _, s in ipairs(Core.SLOTS) do
        local key = Core.ItemKey(GetInventoryItemLink("player", s.id))
        if key then worn[s.id] = key end
    end
    return worn
end

--- Where every bagged item can be found: { [itemKey] = { bag = b, slot = s } }.
--
-- First copy wins. Two identical copies are interchangeable by definition — the key carries the
-- enchant and the gems, so anything sharing a key really is the same item — and picking the first
-- deterministically beats picking whichever pairs() happened to reach last.
function Inventory.Bagged()
    local where = {}
    for bag = 0, Compat.LAST_BAG do
        local size = Compat.GetContainerNumSlots(bag) or 0
        for slot = 1, size do
            local key = Core.ItemKey(Compat.GetContainerItemLink(bag, slot))
            if key and not where[key] then
                where[key] = { bag = bag, slot = slot }
            end
        end
    end
    return where
end

--- The facts the pure planner can't derive: which of these items are two-handers.
--
-- Only asked about the keys a set actually names, because GetItemInfo returns nil for anything the
-- client hasn't cached yet and there is no reason to provoke that for the whole bank.
function Inventory.Meta(set)
    local twoHand = {}
    if set and set.slots then
        for _, key in pairs(set.slots) do
            if type(key) == "string" then
                local loc = Compat.EquipLocation(Core.ItemId(key))
                if loc == "INVTYPE_2HWEAPON" or loc == "INVTYPE_RANGEDRIGHT" then
                    twoHand[key] = true
                end
            end
        end
    end
    return { twoHand = twoHand }
end

--- Everything Plan() needs, read once so the three views agree with each other.
function Inventory.Snapshot(set)
    return Inventory.Equipped(), Inventory.Bagged(), Inventory.Meta(set)
end

Panoply.Inventory = Inventory
return Inventory
