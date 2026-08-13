-- PanoplyRules — PURE: which set should be worn, given a snapshot of the world.
--
-- ItemRack's event system was its best idea and its worst-behaved code: two rules that both matched
-- fought each other, the winner depended on registration order, and there was no way to ask why a
-- set had been chosen. Panoply's answer is one total function of (rules, state) — no frames, no
-- events, no client — plus Explain(), so "why am I wearing this" has an answer you can read.
--
-- Tested by Tests/rules_test.lua, which runs under plain Lua 5.1 outside the game.

Panoply = Panoply or {}

local Rules = {}

-- A rule:
--   { set = "Tank", priority = 50, enabled = true, when = { form = 1, combat = true } }
-- The state is a flat snapshot built by PanoplyEvents:
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

Panoply.Rules = Rules
return Rules
