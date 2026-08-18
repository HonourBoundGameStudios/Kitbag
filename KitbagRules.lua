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
--
-- Most conditions are a plain equality against the state snapshot. A `membership` condition is the
-- exception the shape has to allow for: the player has thirty auras and the rule names one, so the
-- state holds a set and the condition tests for a member. Declaring that on the catalogue entry
-- rather than branching on the key keeps this one loop, and makes the next set-valued condition a
-- flag rather than a special case.
local function firstFailure(when, state)
    for _, k in ipairs(conditionKeys(when)) do
        -- Via Rules.Condition, not the file-local lookup table: that local is declared further down
        -- and would resolve as a global from here.
        local condition = Rules.Condition(k)
        if condition and condition.membership then
            local held = state[k]
            if type(held) ~= "table" or not held[when[k]] then return k end
        elseif state[k] ~= when[k] then
            return k
        end
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
--
-- `numeric` marks a choice whose values are numbers (a form index) rather than the client's own
-- string tokens; only the catalogue knows the difference and Coerce would otherwise turn "raid"
-- into nil. `options` supplies a fixed value list for choices the client cannot enumerate.
-- `membership` says the state holds a set and the condition names one member of it.
Rules.CONDITIONS = {
    { key = "form",    label = "Form",       kind = "choice",  prefix = "in ", numeric = true },
    { key = "combat",  label = "In combat",  kind = "boolean", yes = "in combat", no = "out of combat" },
    { key = "stealth", label = "Stealthed",  kind = "boolean", yes = "stealthed", no = "not stealthed" },
    { key = "mounted", label = "Mounted",    kind = "boolean", yes = "mounted",   no = "not mounted" },
    { key = "resting", label = "Resting",    kind = "boolean", yes = "resting",   no = "not resting" },
    { key = "zone",    label = "Zone",       kind = "text",    prefix = "in " },
    -- Typed rather than chosen: the list of castable spells is the whole spellbook, and the useful
    -- ones (Fishing, Mining, Herb Gathering) are three words the player already knows. The name must
    -- match exactly — Match compares with ==, so "Fish" does not govern "Fishing".
    { key = "spell",   label = "Casting",    kind = "text",    prefix = "when casting " },
    -- The player has thirty auras and the rule names one, so this is the membership case.
    { key = "buff",    label = "Buff",       kind = "text",    prefix = "while ", suffix = " is up",
      membership = true },
    -- The client's own tokens, which nobody would type correctly, so the list and the words for it
    -- live here rather than in the editor.
    { key = "instance", label = "Instance",  kind = "choice",  prefix = "in ", options = {
        { value = "none",     text = "the open world" },
        { value = "party",    text = "a dungeon" },
        { value = "raid",     text = "a raid" },
        { value = "pvp",      text = "a battleground" },
        { value = "arena",    text = "an arena" },
        { value = "scenario", text = "a scenario" },
    } },
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
                -- A catalogue-supplied option carries its own words ("a raid", not "raid").
                if not label and c.options then
                    for _, option in ipairs(c.options) do
                        if option.value == value then label = option.text end
                    end
                end
                -- An unlabelled choice names its condition too: "in 1" is meaningless, "in form 1"
                -- at least says what the 1 refers to. Text conditions are already self-describing.
                if not label and c.kind == "choice" then label = c.key .. " " .. tostring(value) end
                parts[#parts + 1] = (c.prefix or "") .. tostring(label or value) .. (c.suffix or "")
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
            elseif c.kind == "choice" and c.numeric then
                when[c.key] = tonumber(value)
            elseif c.kind == "choice" then
                when[c.key] = value
            else
                local text = tostring(value):match("^%s*(.-)%s*$")
                if text ~= "" then when[c.key] = text end
            end
        end
    end

    return when
end

-- ---------------------------------------------------------------------------
-- What to do next
-- ---------------------------------------------------------------------------

--- What the engine may go on claiming is on, given what wins now.
--
--   activeSet : the set the engine put on and has not let go of, or nil
--   winner    : the rule that matches now (Rules.Match), or nil
--
-- The set STAYS ON when a rule stops matching — that is RULE-4 and Next() is what says so. This is
-- the other half of the same sentence, and conflating the two is what produced BUG-14: the engine
-- stops CLAIMING it. Nothing here equips or unequips anything; it decides only what the engine is
-- still entitled to believe it is responsible for.
--
-- Without it, `activeSet` was released by exactly one thing — an equip that FAILED (see Held). So a
-- rule that fired once never fired again for the rest of the session: mount, change gear by hand,
-- dismount, mount, and Next() answered "none" because the winner's set was still the one claimed.
-- It read as a regression from RULE-4 because restore-previous had been releasing the claim as a
-- side effect of putting the old outfit back, and removing the feature removed the only path that
-- ever let go.
--
-- A DIFFERENT winner keeps the claim rather than clearing it: the handover is Next()'s decision, and
-- clearing here would re-equip a set the engine already put on every time a higher-priority rule
-- took over and stood down again.
function Rules.Claim(activeSet, winner)
    if not winner then return nil end
    return activeSet
end

--- What the engine should do, given what it last applied and what wins now.
--
--   activeSet : the set the engine put on and has not undone, or nil
--   winner    : the rule that matches now (Rules.Match), or nil
--
-- Returns { action = "none" | "equip", set = <name> }.
--
-- A rule applies its set and the set stays on. Restore-previous (RULE-4) used to live here — a rule
-- could put a set on while it matched and put back what you were wearing when it stopped — and it
-- was removed at the Admiral's request. A `restore` flag left on stored data is ignored rather than
-- obeyed: the migration takes it off, and this function never reads it, so the two cannot disagree.
function Rules.Next(activeSet, winner)
    if not winner then return { action = "none" } end
    if winner.set == activeSet then return { action = "none" } end
    return { action = "equip", set = winner.set }
end
--- What the engine may claim is on, once `step` has been attempted and answered `ok`.
--
--   previous : what it was holding before the attempt
--   step     : the step Rules.Next returned, or nil if none was taken
--   ok       : did that step actually happen?
--
-- Next() decides entirely from `activeSet`, so `activeSet` has to be earned. The engine used to set
-- it the moment it decided to swap and never revisit it, which meant a swap that failed left the
-- engine believing that set was on: Next() then answered "none" for as long as the rule kept
-- winning, and the rule never fired again until a /reload cleared the memory (BUG-10).
--
-- A failed equip holds NOTHING, not the set before it. A plan that gave up part way through left
-- neither outfit on the body, and claiming the older one would be a second guess on top of a known
-- unknown. Holding nothing means the next event re-decides from scratch, which is the honest
-- behaviour: if the reason it failed was a full bag, the swap should happen when that is fixed.
function Rules.Held(previous, step, ok)
    if not step then return previous end
    if step.action == "equip" then return ok and step.set or nil end
    return previous
end

--- Can `step` be attempted right now, or must it wait for the world to change? Returns "now", or
--- the reason it is being held: "dead" or "combat" (RULE-6).
--
-- The engine used to ask this question only of combat, and only because a setting asked it to.
-- Death was not asked at all, so a ghost with a restoring rule attempted the swap on every
-- qualifying event, spent the driver's whole BUSY_LIMIT discovering it was dead, and wrote a
-- failure into the swap history — over and over, for the length of the corpse run. Nothing was
-- broken by it; the history simply filled with entries describing the addon rather than the player.
--
-- Death is not behind `deferInCombat` and is not an option at all: no setting makes an equip
-- succeed while you are a ghost, so offering one would only be offering the failure back.
--
-- `casting` is deliberately NOT deferred, even though `Core.CanSwap` refuses it. CanSwap answers
-- for a control the player is about to press; this answers for the engine, and the engine's cast
-- rule works BY cancelling the cast (RULE-3) — deferring it would hold the fishing pole back until
-- the cast the pole was for had already finished. Same world, two different questions.
--
-- The reason strings key `Core.SWAP_BLOCKED`, so anything that wants to say why can.
function Rules.Defer(step, state, options)
    if not step or step.action == "none" then return "now" end
    if type(state) ~= "table" then return "now" end
    -- Death first, for the reason CanSwap orders it the same way: combat clears in seconds and
    -- being dead does not, so naming the transient one would point the player at the wrong wait.
    if state.dead then return "dead" end
    if options and options.deferInCombat and state.combat then return "combat" end
    return "now"
end

Kitbag.Rules = Rules
return Rules
