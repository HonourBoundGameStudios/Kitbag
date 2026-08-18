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

-- Set when Apply had to refuse, cleared when it finally runs. Without it, "it will work as soon as
-- you are out of combat" is a sentence nothing in the addon makes true: Apply is otherwise called
-- only at login and after an import, so a key assigned mid-fight would sit stored and unbound until
-- the next reload.
local deferred = false

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
    if deferred then Bindings.Apply() end
end)

--- Apply every set's keybinding. Safe to call repeatedly; it rebuilds from scratch.
function Bindings.Apply()
    if InCombatLockdown() then
        deferred = true
        return false
    end
    deferred = false

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

--- Give a set a keybinding, or clear it with nil. Returns whether it took, and the set it took the
--- key from — `false` and nil for a set that does not exist.
--
-- Taking the key off whoever else held it is the whole of the difference between this and a plain
-- `set.key = key` (UI-12). Keys are exclusive and `Import.BindingPlan` settles a contest by set
-- name, which is right for an import where nobody chose and wrong for a press where somebody did:
-- leaving the old holder's key in place would hand the binding straight back to it, and the player
-- would be looking at a window that says SHIFT-E while SHIFT-E does something else.
--
-- The player is told, in `Sets.Say`, rather than left to find out by pressing it. A binding that
-- silently moved is indistinguishable from one that never worked.
function Bindings.Set(name, key)
    local sets = Kitbag.char.sets
    local impact = Core.BindingImpact(sets, name, key)
    if not impact.ok then return false end

    for _, loser in ipairs(impact.takenFrom or {}) do
        sets[loser].key = nil
        Sets.Say("|cffffd100%s|r took %s from |cffffd100%s|r.", name, key, loser)
    end

    sets[name].key = key
    -- Apply refuses in combat — writing a secure attribute there is forbidden — and it refuses
    -- SILENTLY, which is the right call for the login and import paths that nobody is watching. It
    -- is the wrong one here: the player just pressed a key, the window now shows it, and pressing
    -- it would do nothing with no explanation. The store is kept either way; only the applying
    -- waits.
    if not Bindings.Apply() then
        Sets.Say("|cffffd100%s|r is saved, but keybindings cannot be changed in combat — " ..
            "it will work as soon as you are out.", key or "the change")
    end

    -- Stored state changed, so the redraw goes through the one entry point rather than being left
    -- to each caller. The window is not the only door: this also fires for the set that LOST the
    -- key, which no caller of this function knows it has to repaint.
    if Kitbag.Refresh then Kitbag.Refresh() end
    return true, impact.taken
end

Kitbag.Bindings = Bindings
return Bindings
