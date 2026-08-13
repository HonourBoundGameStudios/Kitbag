-- KitbagDB — the SavedVariables schema, its defaults, and its migrations.
--
-- Saved data outlives the code that wrote it. Every stored table therefore carries a `schema`
-- number, and every change to the shape adds a migration step rather than silently reinterpreting
-- old data — a set list that quietly empties itself after an update is the worst bug a gear manager
-- can have, because the data is gone before anyone notices.

Kitbag = Kitbag or {}

local DB = {}

DB.SCHEMA = 1

local function defaults()
    return {
        schema = DB.SCHEMA,
        sets = {},          -- [name] = { name =, icon =, slots = { [slotId] = key | false } }
        rules = {},         -- ordered list; see KitbagRules
        options = {
            autoSwap = true,        -- obey the rules at all
            deferInCombat = false,  -- queue swaps until combat ends instead of attempting them
            announce = true,        -- print the set name on a successful swap
            minimap = { hide = false, angle = 200 },
        },
        lastSet = nil,
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
    -- [1] = function(db) … end,   -- 1 -> 2, when there is a 2
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

DB.Defaults = defaults

Kitbag.DB = DB
return DB
