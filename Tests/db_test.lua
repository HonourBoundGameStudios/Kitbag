-- Tests for KitbagDB — defaults, the per-character split (CORE-6), and the migration into it.
--
-- The migration is the part worth testing hardest: it runs exactly once, on data nobody can
-- regenerate, in a client nobody is watching.

local H = dofile("Tests/harness.lua")
local DB = dofile("KitbagDB.lua")

H.start("KitbagDB")

-- A fresh install: sets live under a character, never at the top level.
local fresh = DB.Load(nil)
H.eq(fresh.schema, DB.SCHEMA, "a fresh db carries the current schema")
H.eq(type(fresh.chars), "table", "a fresh db has a character table")
H.eq(fresh.sets, nil, "sets are not stored account-wide")
H.eq(fresh.options.announce, true, "options keep their defaults")

local alice = DB.Character(fresh, "Alice - Whitemane")
H.eq(type(alice.sets), "table", "a character starts with an empty set list")
H.eq(type(alice.rules), "table", "a character starts with an empty rule list")
H.ok(DB.Character(fresh, "Alice - Whitemane") == alice, "the same character gets the same bucket")

-- The COMPAT-1 case that raised CORE-6: the same set name on two characters is two sets.
alice.sets["HEAL"] = { name = "HEAL", slots = { [5] = "i:1" } }
local bob = DB.Character(fresh, "Bob - Whitemane")
H.eq(bob.sets["HEAL"], nil, "another character does not see the first one's sets")
bob.sets["HEAL"] = { name = "HEAL", slots = { [5] = "i:2" } }
H.eq(alice.sets["HEAL"].slots[5], "i:1", "and saving it there leaves the first one alone")

-- Options stay account-wide: the minimap button's angle is not worth re-dragging per alt.
fresh.options.announce = false
H.eq(fresh.options.announce, false, "options are shared, so there is one copy to change")

-- Schema 1 stored one account-wide set list. Nobody's sets may vanish, and one character's gear
-- must not be copied onto every alt, so the first character to log in adopts the old list.
local old = DB.Load({
    schema = 1,
    sets = { HEAL = { name = "HEAL", slots = { [5] = "i:1" } } },
    rules = { { set = "HEAL", priority = 10 } },
    lastSet = "HEAL",
    options = { announce = false },
})
H.eq(old.schema, DB.SCHEMA, "old data is walked up to the current schema")
H.eq(old.sets, nil, "the account-wide set list is gone from the top level")
H.eq(old.options.announce, false, "the migration keeps what the player had set")

local first = DB.Character(old, "Alice - Whitemane")
H.eq(first.sets["HEAL"].slots[5], "i:1", "the first character to log in adopts the old sets")
H.eq(#first.rules, 1, "and the old rules with them")
H.eq(first.lastSet, "HEAL", "and what was last worn")

local second = DB.Character(old, "Bob - Whitemane")
H.eq(second.sets["HEAL"], nil, "the next character starts empty rather than inheriting a copy")
H.eq(old.legacy, nil, "the adopted data is not left behind to be adopted twice")

-- Loading an already-migrated table again must be a no-op, because it happens every login.
local again = DB.Load(old)
H.eq(again.chars["Alice - Whitemane"].sets["HEAL"].slots[5], "i:1", "reloading keeps the buckets")
H.eq(again.schema, DB.SCHEMA, "and does not re-run the migration")

-- An unnamed bucket would silently merge two characters' gear, which is unrecoverable.
H.errors(function() DB.Character(fresh, nil) end, "a character key is required")
H.errors(function() DB.Character(fresh, "") end, "an empty character key is refused")

-- ---------------------------------------------------------------------------
-- The options catalogue (UI-9)
-- ---------------------------------------------------------------------------
--
-- Every option existed and only a slash command could reach some of them. The panel is generated
-- from a catalogue rather than hand-laid-out, so an option added to the defaults appears in the
-- window by being described rather than by someone remembering to add a checkbox.

-- A table of its own: `fresh` has had its options written to by the sharing test above, and an
-- options test that reads whatever an earlier test happened to leave behind proves nothing.
local opts = DB.Load(nil)

H.ok(#DB.OPTIONS > 0, "there is a catalogue of the options a panel can show")
for _, option in ipairs(DB.OPTIONS) do
    H.ok(option.label ~= nil and option.label ~= "", option.path .. " has a label to show")
    -- The invariant that matters: a described option whose path is not in the defaults is a
    -- checkbox wired to nothing, which reads as an option that does not work.
    H.ok(DB.Get(opts, option.path) ~= nil, option.path .. " is a real option in the defaults")
end

-- Dotted paths, because the options are nested and a flat table would put minimap.hide next to
-- announce and lose the grouping the defaults already express.
H.eq(DB.Get(opts, "announce"), true, "a top-level option reads back")
H.eq(DB.Get(opts, "minimap.hide"), false, "…and so does a nested one")
H.eq(DB.Get(opts, "nothing.here"), nil, "a path that does not exist is nil, not an error")

DB.Set(opts, "minimap.hide", true)
H.eq(opts.options.minimap.hide, true, "setting a nested option writes where the defaults put it")
DB.Set(opts, "announce", false)
H.eq(opts.options.announce, false, "…and a top-level one likewise")

-- Never invent structure. Writing to a path whose parent is absent would create a branch nothing
-- reads, and the option would appear to save and then do nothing.
DB.Set(opts, "nowhere.deep.thing", true)
H.eq(opts.options.nowhere, nil, "a write to a path that does not exist creates nothing")

-- Inverted options: the stored flag is `hide`, and nobody wants a checkbox labelled "hide the
-- minimap button" that is ticked when the button is visible.
local shown = nil
for _, option in ipairs(DB.OPTIONS) do
    if option.path == "minimap.hide" then shown = option end
end
H.eq(shown.invert, true, "the minimap option is shown the way round a player thinks about it")

H.done()
