-- KitbagDB — the SavedVariables schema, its defaults, and its migrations.
--
-- Saved data outlives the code that wrote it. Every stored table therefore carries a `schema`
-- number, and every change to the shape adds a migration step rather than silently reinterpreting
-- old data — a set list that quietly empties itself after an update is the worst bug a gear manager
-- can have, because the data is gone before anyone notices.

Kitbag = Kitbag or {}

local DB = {}

DB.SCHEMA = 2

-- Sets and rules are per-character (CORE-6): gear is, so a set naming items this character does not
-- own is noise, and a rule naming a set it does not have is dead. They live in one account-wide file
-- rather than `## SavedVariablesPerCharacter` so that options stay shared, the schema-1 data can be
-- migrated instead of stranded, and copying a set to an alt stays possible later.
local function characterDefaults()
    return {
        sets = {},          -- [name] = { name =, icon =, slots = { [slotId] = key | false } }
        rules = {},         -- ordered list; see KitbagRules
        lastSet = nil,
        -- What was worn before a `restore` rule took over (RULE-4). Saved rather than kept in
        -- memory: a reload mid-shapeshift would otherwise strand the player in the rule's set with
        -- no way back to their own gear.
        restorePoint = nil,
    }
end

local function defaults()
    return {
        schema = DB.SCHEMA,
        chars = {},         -- ["Name - Realm"] = characterDefaults()
        options = {
            autoSwap = true,        -- obey the rules at all
            deferInCombat = false,  -- queue swaps until combat ends instead of attempting them
            announce = true,        -- print the set name on a successful swap
            flyouts = true,         -- per-slot alternatives on the character sheet (UI-5)
            minimap = { hide = false, angle = 200 },
        },
    }
end

-- Fill in anything a new version added without touching what the player already set.
local function applyDefaults(target, source)
    for k, v in pairs(source) do
        if target[k] == nil then
            target[k] = type(v) == "table" and applyDefaults({}, v) or v
        elseif type(target[k]) == "table" and type(v) == "table" then
            applyDefaults(target[k], v)
        end
    end
    return target
end

-- Migrations run in order from the stored schema up to DB.SCHEMA. Each entry takes the whole table
-- and moves it forward exactly one version. Add, never rewrite: an old client's data has to be able
-- to walk the whole chain.
local migrations = {
    -- 1 -> 2: the account-wide set list becomes per-character. The old list is set aside rather
    -- than assigned here, because a migration does not know who is logging in — and copying one
    -- character's gear onto every alt would be worse than losing it. DB.Character hands it to the
    -- first character that asks for a bucket.
    [1] = function(db)
        db.legacy = { sets = db.sets, rules = db.rules, lastSet = db.lastSet }
        db.sets, db.rules, db.lastSet = nil, nil, nil
    end,
}

--- Normalise the loaded SavedVariables table in place and return it.
function DB.Load(saved)
    local db = type(saved) == "table" and saved or {}
    db.schema = db.schema or DB.SCHEMA

    for v = db.schema, DB.SCHEMA - 1 do
        local step = migrations[v]
        if step then step(db) end
        db.schema = v + 1
    end

    return applyDefaults(db, defaults())
end

--- The sets, rules and lastSet belonging to one character, created on first use.
--
-- `key` must identify the character uniquely ("Name - Realm"); an empty one would quietly merge two
-- characters' gear into one bucket, and there is no undoing that once they have both saved a set.
function DB.Character(db, key)
    if type(key) ~= "string" or key:match("^%s*$") then
        error("KitbagDB.Character: a character key is required, got " .. tostring(key), 2)
    end

    db.chars = db.chars or {}
    local char = db.chars[key]
    if not char then
        -- Whoever logs in first after the schema-1 upgrade keeps the old account-wide sets.
        char = db.legacy or {}
        db.legacy = nil
        db.chars[key] = applyDefaults(char, characterDefaults())
    end
    return char
end

DB.Defaults = defaults

Kitbag.DB = DB
return DB
