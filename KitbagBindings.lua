-- KitbagBindings — per-set keybindings (COMPAT-5).
--
-- A set can carry a `key` (ItemRack stored one per set, and the import brings it across). Binding it
-- means a hidden secure button per set plus SetBindingClick, because a keybinding that equips gear
-- has to work in combat and only a secure button can.
--
-- The bindings are applied fresh at every login and deliberately NOT saved into the player's binding
-- set. Kitbag's own data is the source of truth, so deleting a set takes its binding with it, and
-- uninstalling Kitbag leaves nothing behind — where SaveBindings would permanently overwrite
-- whatever the key used to do.

Kitbag = Kitbag or {}

local Core = Kitbag.Core
local Import = Kitbag.Import
local Sets = Kitbag.Sets

local Bindings = {}

local buttons = {}

local function buttonFor(name, index)
    local button = buttons[index]
    if not button then
        button = CreateFrame("Button", "KitbagBindingButton" .. index, UIParent,
            "SecureActionButtonTemplate")
        button:Hide()
        button:SetAttribute("type", "macro")
        button:RegisterForClicks("AnyDown")
        buttons[index] = button
    end
    -- Rewritten per set rather than one button each: the attribute is only touched out of combat
    -- (Apply refuses in combat), and a pool of buttons keeps the frame count down.
    button:SetAttribute("macrotext", Core.MacroBody(name))
    return button
end

--- Apply every set's keybinding. Safe to call repeatedly; it rebuilds from scratch.
function Bindings.Apply()
    if InCombatLockdown() then return false end

    local sets = Kitbag.char.sets
    local plan = Import.BindingPlan(sets)

    -- Clear ours first. Only the keys Kitbag itself claimed are touched, so a key that used to be a
    -- set's and is not any more goes back to whatever the game had for it rather than staying ours.
    for _, button in ipairs(buttons) do
        button:SetAttribute("macrotext", "")
    end

    for index, entry in ipairs(plan.bind) do
        SetBindingClick(entry.key, buttonFor(entry.set, index):GetName())
    end

    for _, clash in ipairs(plan.conflicts) do
        Sets.Say("|cffff8080%s|r wanted %s, which |cffffd100another set|r already has.",
            clash.set, clash.key)
    end

    return true
end

--- Give a set a keybinding, or clear it with nil.
function Bindings.Set(name, key)
    local set = Kitbag.char.sets[name]
    if not set then return false end
    set.key = key
    Bindings.Apply()
    return true
end

Kitbag.Bindings = Bindings
return Bindings
