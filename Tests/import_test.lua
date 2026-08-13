-- KitbagImport — reading someone's existing ItemRack sets into Kitbag.
--
-- PURE: it takes the `ItemRackUser` table the client has already loaded and returns plain Kitbag
-- sets. No client calls, so the whole conversion is cornered here rather than discovered by a
-- stranger losing their gear sets on the way in.
--
-- Every fixture below is copied from a REAL ItemRack SavedVariables file rather than invented,
-- which is the only reason the awkward cases are in here at all — `[0] = 0`, the `~` pseudo-sets and
-- the empty-field item strings are not things anyone would think to make up.
--
-- Usage: lua Tests/import_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")
local C = dofile("KitbagCore.lua")
local I = dofile("KitbagImport.lua")

H.start("KitbagImport")

-- Real strings, straight out of Whitemane/Pobble. Note the EMPTY fields, not zeros, and the
-- trailing ":60:" link level that identity deliberately ignores.
local HELM    = "16955::::::::60::::::::::"
local CLOAK   = "22196:1891:::::::60::::::::::"   -- enchanted: the enchant is part of identity
local GLOVES  = "16855:2544:::::::60::::::::::"

local function user(sets) return { Sets = sets } end

-- ---------------------------------------------------------------------------
-- The straightforward case
-- ---------------------------------------------------------------------------

local r = I.FromItemRack(user({
    HEAL = { equip = { [1] = HELM, [15] = CLOAK, [10] = GLOVES }, icon = 135019 },
}))

H.ok(r.sets.HEAL ~= nil, "a named ItemRack set arrives as a Kitbag set of the same name")
H.eq(r.sets.HEAL.name, "HEAL", "the set carries its own name")
H.eq(r.sets.HEAL.slots[1], C.ItemKey(HELM), "slot 1 holds the head item, reduced to a Kitbag key")
H.eq(r.sets.HEAL.slots[15], "22196:1891:0:0:0:0:0",
    "the cloak keeps its enchant — an enchanted copy is not interchangeable with a plain one")
H.eq(r.sets.HEAL.icon, 135019, "the set icon comes across, so the list looks familiar afterwards")
H.eq(r.imported, 1, "the report counts what was imported")

-- ItemRack's equip array only lists the slots the set manages. A slot it never mentions must stay
-- ABSENT rather than becoming `false`: absent means "don't touch", false means "strip it". Getting
-- this backwards would have every imported set undressing the wearer.
H.eq(r.sets.HEAL.slots[7], nil, "a slot ItemRack never mentioned is absent, not false")
H.eq(r.sets.HEAL.slots[17], nil, "…including the off hand, which must not be stripped on import")

-- ---------------------------------------------------------------------------
-- 0 means deliberately empty
-- ---------------------------------------------------------------------------
--
-- ItemRack writes 0 for a slot the set deliberately empties (its AllowEmpty option). That is
-- exactly Kitbag's `false`, and it is the one case where an import SHOULD strip a slot.

local r0 = I.FromItemRack(user({ Naked = { equip = { [1] = HELM, [4] = 0 } } }))
H.eq(r0.sets.Naked.slots[4], false, "ItemRack's 0 becomes Kitbag's false — deliberately empty")

-- ---------------------------------------------------------------------------
-- The traps in the real data
-- ---------------------------------------------------------------------------

-- Every character file has these two. They are ItemRack's internal scratch sets, not the user's, and
-- importing them would hand everyone two junk sets on their first run.
local rInternal = I.FromItemRack(user({
    ["~CombatQueue"] = { equip = {} },
    ["~Unequip"] = { equip = {} },
    Real = { equip = { [1] = HELM } },
}))
H.eq(rInternal.sets["~CombatQueue"], nil, "ItemRack's ~CombatQueue pseudo-set is not imported")
H.eq(rInternal.sets["~Unequip"], nil, "ItemRack's ~Unequip pseudo-set is not imported")
H.ok(rInternal.sets.Real ~= nil, "…while a real set beside them still comes through")
H.eq(rInternal.imported, 1, "the count reflects only the real sets")

-- The equip table really does carry `[0] = 0` in the wild. Index 0 is not an inventory slot, and
-- anything relying on # or ipairs over this table reads it wrong.
local rZero = I.FromItemRack(user({
    Odd = { equip = { [1] = HELM, [0] = 0, [23] = HELM } },
}))
H.eq(rZero.sets.Odd.slots[0], nil, "the [0] = 0 entry is ignored — 0 is not an inventory slot")
H.eq(rZero.sets.Odd.slots[23], nil, "a slot id beyond the 19 equippable slots is ignored")
H.eq(rZero.sets.Odd.slots[1], C.ItemKey(HELM), "…and the real slot beside them still imports")

-- An item string the client wrote that we cannot read must not silently become "strip this slot".
-- Absent (don't touch) is the safe reading, and the count is surfaced rather than swallowed.
local rBad = I.FromItemRack(user({
    Broken = { equip = { [1] = HELM, [5] = "not-an-item" } },
}))
H.eq(rBad.sets.Broken.slots[5], nil, "an unreadable item leaves the slot untouched, never stripped")
H.eq(rBad.unreadable, 1, "unreadable items are counted, not swallowed")

-- ---------------------------------------------------------------------------
-- Skipping, and saying so
-- ---------------------------------------------------------------------------

local function whyFor(report, name)
    for _, s in ipairs(report.skipped) do
        if s.name == name then return s.why end
    end
    return nil
end

H.eq(whyFor(rInternal, "~Unequip"), "internal", "a skipped pseudo-set is reported with a reason")

-- A set with nothing usable in it is not worth creating, but the user should hear that it existed.
local rEmpty = I.FromItemRack(user({ Hollow = { equip = {} } }))
H.eq(rEmpty.sets.Hollow, nil, "a set with no usable slots is not imported")
H.eq(whyFor(rEmpty, "Hollow"), "empty", "…and is reported as empty rather than vanishing")

-- Import is non-destructive: someone's existing Kitbag set is never overwritten by a same-named
-- ItemRack one. Their gear, their call — the collision is reported so they can rename and retry.
local existing = { HEAL = { name = "HEAL", slots = {} } }
local rClash = I.FromItemRack(user({ HEAL = { equip = { [1] = HELM } } }), existing)
H.eq(rClash.sets.HEAL, nil, "a name that already exists in Kitbag is not overwritten")
H.eq(whyFor(rClash, "HEAL"), "exists", "…and the collision is reported")
H.eq(rClash.imported, 0, "nothing was imported")

-- ---------------------------------------------------------------------------
-- Rubbish in
-- ---------------------------------------------------------------------------
--
-- The importer reads a global written by another addon that may be absent, half-written, or from a
-- version that predates any of this. It reports nothing rather than erroring — a failed import must
-- not take the addon down at login.

H.eq(I.FromItemRack(nil).imported, 0, "no ItemRack data at all -> nothing imported, no error")
H.eq(#I.FromItemRack(nil).skipped, 0, "…and nothing skipped")
H.eq(I.FromItemRack({}).imported, 0, "an ItemRackUser with no Sets table -> nothing imported")
H.eq(I.FromItemRack("nonsense").imported, 0, "a non-table -> nothing imported")
H.eq(I.FromItemRack(user({ Bad = "not a set table" })).imported, 0, "a malformed set is skipped")
H.eq(I.FromItemRack(user({ Bad = { equip = "not a table" } })).imported, 0,
    "a set whose equip is not a table is skipped")

-- Determinism: two runs over the same data give the same report, so the skipped list can be shown
-- to a user without reshuffling between openings.
local a = I.FromItemRack(user({ B = { equip = {} }, A = { equip = {} } }))
H.eq(a.skipped[1].name, "A", "the skipped list is sorted by name, not by pairs() order")
H.eq(a.skipped[2].name, "B", "…so the report reads the same every time")

-- ---------------------------------------------------------------------------
-- Options and keybindings (COMPAT-5)
-- ---------------------------------------------------------------------------
--
-- COMPAT-1 brought the sets. The rest of what someone switching had configured is in a second
-- global, ItemRackSettings, plus a `key` on each set. Most of ItemRack's options have no Kitbag
-- equivalent, so the deliberate rule is that only a mapped option is imported and everything else
-- is left alone rather than approximated — a setting that half-transfers is worse than one that
-- plainly did not.

local settings = I.OptionsFromItemRack({
    EnableEvents = "OFF",
    ShowMinimap = "ON",
    EnableTrinketMenu = "OFF",
    ButtonSpacing = 4,          -- no Kitbag equivalent
})
H.eq(settings["autoSwap"], false, "ItemRack's OFF becomes false, not the string")
H.eq(settings["minimap.hide"], false, "a shown minimap button becomes a not-hidden one")
H.eq(settings["trinkets.hide"], true, "…and the inversion holds the other way too")
H.eq(settings["ButtonSpacing"], nil, "an option with no Kitbag equivalent is not imported")

-- Absent is not "off". ItemRack omits a setting that is at its own default, and reading that as OFF
-- would silently turn auto-swap off for anyone who never touched it.
H.eq(I.OptionsFromItemRack({})["autoSwap"], nil, "an option ItemRack never stored is left alone")
H.eq(next(I.OptionsFromItemRack(nil)), nil, "no settings table at all imports nothing")
H.eq(next(I.OptionsFromItemRack("nonsense")), nil, "…and neither does a malformed one")

-- Keybindings. ItemRack stores one per set; Kitbag keeps it on the set and binds it at login.
local withKeys = I.FromItemRack(user({
    Tank = { equip = { [1] = "16963:0:0:0:0:0:0:0" }, key = "CTRL-F1" },
    Heal = { equip = { [1] = "16963:0:0:0:0:0:0:0" } },
}))
H.eq(withKeys.sets.Tank.key, "CTRL-F1", "a set's keybinding comes across with it")
H.eq(withKeys.sets.Heal.key, nil, "a set with no binding gets none invented")

-- Two sets bound to the same key is authorable in ItemRack and cannot be honoured. The conflict is
-- resolved by name so the outcome is the same every time, and reported rather than silently dropped.
local plan = I.BindingPlan({
    Tank = { name = "Tank", key = "CTRL-F1" },
    Heal = { name = "Heal", key = "CTRL-F1" },
    Dps  = { name = "Dps",  key = "CTRL-F2" },
    None = { name = "None" },
})
H.eq(#plan.bind, 2, "each key is bound once")
H.eq(plan.bind[1].key, "CTRL-F1", "the plan is ordered by key, not by pairs()")
H.eq(plan.bind[1].set, "Heal", "…and a contested key goes to the first set by name")
H.eq(#plan.conflicts, 1, "the loser is reported")
H.eq(plan.conflicts[1].set, "Tank", "…by name")

H.done()
