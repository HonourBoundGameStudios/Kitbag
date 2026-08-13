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
            -- Off by default (UI-7): an addon that puts unrequested frames on someone's screen is
            -- an addon they uninstall.
            trinkets = { hide = true, point = "CENTER", relative = "CENTER", x = 0, y = -160 },
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

-- ---------------------------------------------------------------------------
-- The options catalogue (UI-9)
-- ---------------------------------------------------------------------------
--
-- The options panel is generated from this rather than hand-laid-out, so adding an option means
-- adding it to the defaults and describing it here — not remembering to place a checkbox. It lives
-- beside the defaults because the invariant that matters is between the two: a described option
-- whose path is not in the defaults is a checkbox wired to nothing.
--
-- `invert` is for the flags stored as "hide": nobody wants a tick box labelled "hide the minimap
-- button" that is ticked when the button is visible.
DB.OPTIONS = {
    { path = "autoSwap",      label = "Let rules swap my gear",
      hint = "Turn this off to keep every rule without any of them firing." },
    { path = "deferInCombat", label = "Wait until combat ends before swapping",
      hint = "Most gear cannot be changed in combat anyway." },
    { path = "announce",      label = "Say in chat when a set is equipped" },
    { path = "flyouts",       label = "Show alternatives when I hover a paperdoll slot" },
    { path = "minimap.hide",  label = "Show the minimap button", invert = true },
    { path = "trinkets.hide", label = "Show the trinket quick-use bar", invert = true },
}

local function walk(db, path)
    local node = db.options
    local last = nil
    for part in string.gmatch(path, "[^%.]+") do
        if last then
            node = node[last]
            if type(node) ~= "table" then return nil, nil end
        end
        last = part
    end
    return node, last
end

--- Read an option by dotted path ("minimap.hide"). nil for a path that does not exist.
function DB.Get(db, path)
    local node, key = walk(db, path)
    -- Written out rather than `node and key and node[key] or nil`: most of these options are
    -- booleans, and that idiom turns a stored `false` into nil.
    if not node or not key then return nil end
    return node[key]
end

--- Write an option by dotted path. A path whose parent does not exist writes nothing: inventing the
-- branch would produce an option that appears to save and is then read by nobody.
function DB.Set(db, path, value)
    local node, key = walk(db, path)
    if not node or not key or node[key] == nil then return false end
    node[key] = value
    return true
end

DB.Defaults = defaults

Kitbag.DB = DB
return DB
