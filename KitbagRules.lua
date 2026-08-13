-- KitbagRules — PURE: which set should be worn, given a snapshot of the world.
--
-- ItemRack's event system was its best idea and its worst-behaved code: two rules that both matched
-- fought each other, the winner depended on registration order, and there was no way to ask why a
-- set had been chosen. Kitbag's answer is one total function of (rules, state) — no frames, no
-- events, no client — plus Explain(), so "why am I wearing this" has an answer you can read.
--
-- Tested by Tests/rules_test.lua, which runs under plain Lua 5.1 outside the game.

Kitbag = Kitbag or {}

local Rules = {}

-- A rule:
--   { set = "Tank", priority = 50, enabled = true, when = { form = 1, combat = true } }
-- The state is a flat snapshot built by KitbagEvents:
--   { form = 1, combat = false, stealth = false, mounted = false, resting = true, zone = "…" }
--
-- Conditions are AND, always. "Cat form AND stealthed" is a different outfit from "Cat form", and
-- an OR would make the rule that fires unpredictable again.

-- Sorted condition keys, so a rule that fails on two conditions always blames the same one.
-- Determinism matters more than which one it picks: an explanation that changes between two runs of
-- the same state is worse than no explanation.
local function conditionKeys(when)
    local keys = {}
    for k in pairs(when) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- nil = the rule matches; otherwise the name of the first condition that failed.
local function firstFailure(when, state)
    for _, k in ipairs(conditionKeys(when)) do
        if state[k] ~= when[k] then return k end
    end
    return nil
end

local function validate(rule, index)
    assert(type(rule) == "table", "Rules: rule " .. index .. " is not a table")
    assert(type(rule.set) == "string" and rule.set ~= "",
        "Rules: rule " .. index .. " has no set name")
end

--- The winning rule for this state, or nil if nothing applies.
--
-- Highest priority wins. A tie goes to the earlier rule in the list, deliberately and documented:
-- the list is the tiebreak, so reordering rules in the UI is how you resolve a tie. A disabled rule
-- never wins whatever its priority — otherwise it is not an off switch.
function Rules.Match(rules, state)
    if type(rules) ~= "table" or type(state) ~= "table" then return nil end

    local best, bestPriority
    for i, rule in ipairs(rules) do
        validate(rule, i)
        if rule.enabled ~= false then
            local when = rule.when or {}
            if firstFailure(when, state) == nil then
                local priority = rule.priority or 0
                if not best or priority > bestPriority then
                    best, bestPriority = rule, priority
                end
            end
        end
    end
    return best
end

--- Every rule, why it did or didn't fire, and which one won.
--
-- Returns { chosen = "<set>" | nil, considered = { { set =, matched =, reason = }, … } } in the
-- original rule order, so the UI can render the list the player authored rather than a re-sort.
-- `reason` is "disabled", or the name of the condition that failed, or nil for the ones that matched.
function Rules.Explain(rules, state)
    local considered = {}
    if type(rules) ~= "table" or type(state) ~= "table" then
        return { chosen = nil, considered = considered }
    end

    for i, rule in ipairs(rules) do
        validate(rule, i)
        local entry = { set = rule.set, priority = rule.priority or 0 }
        if rule.enabled == false then
            entry.matched, entry.reason = false, "disabled"
        else
            local failed = firstFailure(rule.when or {}, state)
            entry.matched = failed == nil
            entry.reason = failed
        end
        considered[#considered + 1] = entry
    end

    local winner = Rules.Match(rules, state)
    return { chosen = winner and winner.set or nil, considered = considered }
end

-- ---------------------------------------------------------------------------
-- Authoring (RULE-2)
-- ---------------------------------------------------------------------------
--
-- Everything the rule editor *decides* lives here rather than in the frame: what a condition is,
-- what a rule reads as in English, what reordering does to the list. The editor is then wiring, and
-- the part that can be got wrong is testable outside the game.

--- The conditions a rule can be built from.
--
-- `kind` tells the editor which widget to draw: a tick box, a dropdown the client fills, or a text
-- field. Adding a condition later is a line here plus a key in the KitbagEvents snapshot — every key
-- below MUST exist in that snapshot, or the editor cheerfully offers a rule that can never fire.
-- `yes`/`no` are the phrases Describe uses, because "not in combat" is worse English than "out of
-- combat" and this text is the whole of what a rule list row says.
Rules.CONDITIONS = {
    { key = "form",    label = "Form",       kind = "choice",  prefix = "in " },
    { key = "combat",  label = "In combat",  kind = "boolean", yes = "in combat", no = "out of combat" },
    { key = "stealth", label = "Stealthed",  kind = "boolean", yes = "stealthed", no = "not stealthed" },
    { key = "mounted", label = "Mounted",    kind = "boolean", yes = "mounted",   no = "not mounted" },
    { key = "resting", label = "Resting",    kind = "boolean", yes = "resting",   no = "not resting" },
    { key = "zone",    label = "Zone",       kind = "text",    prefix = "in " },
    -- Typed rather than chosen: the list of castable spells is the whole spellbook, and the useful
    -- ones (Fishing, Mining, Herb Gathering) are three words the player already knows. The name must
    -- match exactly — Match compares with ==, so "Fish" does not govern "Fishing".
    { key = "spell",   label = "Casting",    kind = "text",    prefix = "when casting " },
}

local conditionByKey = {}
for _, c in ipairs(Rules.CONDITIONS) do conditionByKey[c.key] = c end

Rules.Condition = function(key) return conditionByKey[key] end

--- A rule's conditions as a sentence: "in combat and stealthed".
--
-- The catalogue order is used, not pairs() order, so the same rule reads identically every time —
-- a list whose rows reshuffle their own wording between two openings is unreadable.
--
-- `labels` supplies display names for `choice` values ({ form = { [1] = "Bear Form" } }); they come
-- from the client and are per class, so they cannot live in a pure file. A value with no label falls
-- back to the raw one rather than showing nothing, because "in form 1" is at least true.
function Rules.Describe(rule, labels)
    local when = (type(rule) == "table" and rule.when) or {}
    labels = labels or {}

    local parts = {}
    for _, c in ipairs(Rules.CONDITIONS) do
        local value = when[c.key]
        if value ~= nil then
            if c.kind == "boolean" then
                parts[#parts + 1] = value and c.yes or c.no
            else
                local label = labels[c.key] and labels[c.key][value]
                -- An unlabelled choice names its condition too: "in 1" is meaningless, "in form 1"
                -- at least says what the 1 refers to. Text conditions are already self-describing.
                if not label and c.kind == "choice" then label = c.key .. " " .. tostring(value) end
                parts[#parts + 1] = (c.prefix or "") .. tostring(label or value)
            end
        end
    end

    if #parts == 0 then return "always" end
    return table.concat(parts, " and ")
end

--- Move a rule within the list, returning its new index (nil if there was nothing to move).
--
-- The list order is the documented tiebreak between equal priorities, so this is a real edit. Moving
-- off either end is a no-op rather than an error: the buttons on the first and last rows would
-- otherwise have to be disabled to stay safe, and a disabled button explains nothing.
function Rules.Move(rules, index, delta)
    if type(rules) ~= "table" then return nil end
    local rule = rules[index]
    if not rule then return nil end

    local target = index + (delta or 0)
    if target < 1 or target > #rules then return index end

    table.remove(rules, index)
    table.insert(rules, target, rule)
    return target
end

--- Turn what the editor's widgets hand back into a condition table the engine can match.
--
-- This is where a rule silently becomes unmatchable: an edit box gives "1" and the client reports
-- the number 1, so `form = "1"` never matches and the rule simply never fires with nothing to
-- explain why. Unparseable input is dropped for the same reason — a stored condition nobody can
-- satisfy is worse than a condition that was not added.
--
-- An absent key and `false` are deliberately different: `false` is a real condition ("out of
-- combat"), so an unticked box must be absent rather than false, or every unused condition would
-- start constraining the rule.
function Rules.Coerce(input)
    local when = {}
    if type(input) ~= "table" then return when end

    for _, c in ipairs(Rules.CONDITIONS) do
        local value = input[c.key]
        if value ~= nil then
            if c.kind == "boolean" then
                when[c.key] = value and true or false
            elseif c.kind == "choice" then
                when[c.key] = tonumber(value)
            else
                local text = tostring(value):match("^%s*(.-)%s*$")
                if text ~= "" then when[c.key] = text end
            end
        end
    end

    return when
end

-- ---------------------------------------------------------------------------
-- Restore-previous (RULE-4)
-- ---------------------------------------------------------------------------

--- What the engine should do, given what it last applied and what wins now.
--
--   activeSet : the set the engine put on and has not undone, or nil
--   winner    : the rule that matches now (Rules.Match), or nil
--   hasSaved  : is there a remembered outfit to go back to?
--
-- Returns { action = "none" | "equip" | "restore", set = <name>, remember = bool }.
--
-- A rule marked `restore` is a temporary swap: it puts a set on while it matches and puts back what
-- you were wearing when it stops. Restoring to a *named* set would be the easy implementation and
-- the wrong one — you were wearing whatever you were wearing, quite possibly no saved set at all.
--
-- `remember` is only true when nothing has been saved yet. The trap is a second temporary rule
-- taking over from the first: remembering again would overwrite the outfit you actually started in
-- with the one the first rule put on, and you would never get your own gear back.
function Rules.Next(activeSet, winner, hasSaved)
    if winner then
        if winner.set == activeSet then return { action = "none" } end
        return {
            action = "equip",
            set = winner.set,
            remember = (winner.restore == true) and not hasSaved,
        }
    end

    -- Nothing matches. Go back only if there is somewhere to go back to: with nothing saved,
    -- leaving the player in the last set is honest, and guessing a set to "return" to is not.
    if hasSaved then return { action = "restore" } end
    return { action = "none" }
end

Kitbag.Rules = Rules
return Rules
