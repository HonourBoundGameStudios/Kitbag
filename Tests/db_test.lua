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

H.done()
