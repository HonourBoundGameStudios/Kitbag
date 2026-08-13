-- KitbagInventory — read the world into the plain tables KitbagCore.Plan expects.
--
-- This file is all client API and no decisions. Everything it produces is inert data, which is what
-- lets the planner be tested without a game: Snapshot() here, Plan() there, Apply() in KitbagEquip.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Compat = Kitbag.Compat

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

-- The bank window's open/closed state is not readable on demand — there is no IsBankOpen() — so it
-- has to be tracked from the events. Getting this wrong in the optimistic direction is the costly
-- one: the planner would build actions against bank bags it cannot touch, spend the whole retry
-- budget, and report the set as stuck.
local bankOpen = false
local bankWatcher = CreateFrame("Frame")
bankWatcher:RegisterEvent("BANKFRAME_OPENED")
bankWatcher:RegisterEvent("BANKFRAME_CLOSED")
bankWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
bankWatcher:SetScript("OnEvent", function(_, event)
    bankOpen = event == "BANKFRAME_OPENED"
    -- A set's readiness changes the moment the bank opens, so the window must be told.
    if Kitbag.Refresh then Kitbag.Refresh() end
end)

--- Is the player standing at an open bank? Bank items are only equippable while this is true.
function Inventory.IsBankOpen()
    return bankOpen
end

local function scan(where, bag, bank)
    local size = Compat.GetContainerNumSlots(bag) or 0
    for slot = 1, size do
        local key = Core.ItemKey(Compat.GetContainerItemLink(bag, slot))
        if key and not where[key] then
            where[key] = { bag = bag, slot = slot, bank = bank }
        end
    end
end

--- Where every unworn item can be found: { [itemKey] = { bag = b, slot = s, bank = bool } }.
--
-- First copy wins, and the carried bags are scanned before the bank so that "first" means the copy
-- you can actually reach. Two identical copies are interchangeable by definition — the key carries
-- the enchant and the gems, so anything sharing a key really is the same item — and picking the
-- first deterministically beats picking whichever pairs() happened to reach last.
--
-- The bank is scanned even when it is shut: the client keeps the contents cached after the first
-- visit of the session, and a remembered "it's in your bank" is a far more useful answer than a
-- fresh "not found". Before that first visit the bank simply reads as empty, which is the same
-- answer Kitbag gave before this existed. The planner will not act on a bank location anyway unless
-- meta.bankOpen says it can.
function Inventory.Bagged()
    local where = {}
    for bag = 0, Compat.LAST_BAG do
        scan(where, bag, nil)
    end
    for _, bag in ipairs(Compat.BANK_BAGS) do
        scan(where, bag, true)
    end
    return where
end

--- How many bag slots an unequipped item could actually go into (CORE-5).
--
-- Only the carried bags, and only the general-purpose ones: a herb bag has free slots that will
-- never take a helmet, and counting them is how you promise a swap that then fails. The bank is not
-- counted either — the driver puts removed gear in the bags, not the bank.
function Inventory.FreeBagSlots()
    local free = 0
    for bag = 0, Compat.LAST_BAG do
        local slots, bagType = Compat.GetContainerNumFreeSlots(bag)
        -- bagType 0 is "anything goes". A nil bagType means the client didn't say, and the backpack
        -- is always general-purpose, so treat unknown as usable rather than losing real capacity.
        if slots and (not bagType or bagType == 0) then free = free + slots end
    end
    return free
end

--- The facts the pure planner can't derive: which of these items are two-handers.
--
-- Only asked about the keys a set actually names, because GetItemInfo returns nil for anything the
-- client hasn't cached yet and there is no reason to provoke that for the whole bank.
-- `freeBagSlots` is passed in when a whole list of sets is being planned at once, so the bags are
-- counted once for the list rather than once per row.
function Inventory.Meta(set, freeBagSlots)
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
    return {
        twoHand = twoHand,
        bankOpen = bankOpen,
        freeBagSlots = freeBagSlots or Inventory.FreeBagSlots(),
    }
end

--- Durability of everything currently worn: { [itemKey] = 0..1 }.
--
-- Only the worn items, because that is the whole of what the client will answer for — there is no
-- durability API for an item sitting in a bag. A set you are not wearing therefore reports unknown
-- durability, which is the honest answer and the one Core.Totals is built to take.
function Inventory.WornDurability()
    local dur = {}
    for _, s in ipairs(Core.SLOTS) do
        local key = Core.ItemKey(GetInventoryItemLink("player", s.id))
        if key then
            local fraction = Compat.SlotDurability(s.id)
            if fraction then dur[key] = fraction end
        end
    end
    return dur
end

--- The per-item facts Core.Totals needs: { [itemKey] = { level =, durability = } }.
-- `dur` is passed in so a whole list of sets can share one durability scan.
function Inventory.ItemInfo(set, dur)
    dur = dur or Inventory.WornDurability()
    local info = {}
    if set and set.slots then
        for _, key in pairs(set.slots) do
            if type(key) == "string" and not info[key] then
                info[key] = { level = Compat.ItemLevel(Core.ItemId(key)), durability = dur[key] }
            end
        end
    end
    return info
end

--- Everything Plan() needs, read once so the three views agree with each other.
function Inventory.Snapshot(set)
    return Inventory.Equipped(), Inventory.Bagged(), Inventory.Meta(set)
end

Kitbag.Inventory = Inventory
return Inventory
