-- PanoplyRules — pure auto-swap rule matching.
--
-- ItemRack's event system was its best idea and its worst-behaved code: rules fired in an order
-- nobody could predict, two rules that both matched fought each other, and there was no way to see
-- why a set had been chosen. Panoply's answer is a pure function — given the rules and a snapshot of
-- the world, which set wins, and why. No frames, no events, no client.
--
-- Usage: lua Tests/rules_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")
local R = dofile("PanoplyRules.lua")

H.start("PanoplyRules")

-- rule = { set = "<name>", priority = n, enabled = bool, when = { <condition> = <value>, … } }
-- state = a flat snapshot of the world: { form = 1, combat = false, stealth = false, … }

local function rule(set, priority, when, enabled)
    return { set = set, priority = priority, when = when, enabled = enabled ~= false }
end

-- 1. The simple case.
local rules = { rule("Bear", 10, { form = 1 }) }
H.eq(R.Match(rules, { form = 1 }).set, "Bear", "a rule whose condition holds selects its set")
H.eq(R.Match(rules, { form = 0 }), nil, "a rule whose condition fails selects nothing")

-- 2. Nothing to match against is nil, not an error. This runs on every event; it must be total.
H.eq(R.Match(nil, { form = 1 }), nil, "no rules table -> nil")
H.eq(R.Match({}, { form = 1 }), nil, "an empty rules table -> nil")
H.eq(R.Match(rules, nil), nil, "no state -> nil")

-- 3. Every condition in `when` must hold — conditions are AND, never OR. "Cat form AND stealthed"
--    is a different outfit from "Cat form".
rules = { rule("Prowl", 10, { form = 3, stealth = true }) }
H.eq(R.Match(rules, { form = 3, stealth = true }).set, "Prowl", "all conditions holding -> match")
H.eq(R.Match(rules, { form = 3, stealth = false }), nil, "one condition failing -> no match")
H.eq(R.Match(rules, { stealth = true }), nil, "a condition absent from the state -> no match")

-- 4. Priority decides between two rules that both match. This is the whole fix: the winner is
--    declared, not whichever rule happened to be registered first.
rules = {
    rule("Generic", 10, { combat = true }),
    rule("Specific", 50, { combat = true, form = 1 }),
}
H.eq(R.Match(rules, { combat = true, form = 1 }).set, "Specific", "the higher priority wins")
H.eq(R.Match(rules, { combat = true, form = 0 }).set, "Generic", "…and the loser still matches alone")

-- 5. A tie resolves to the earlier rule, deterministically. Two equal-priority matches must not
--    depend on table order, so the list order is the tiebreak and it is documented as such.
rules = { rule("First", 10, { combat = true }), rule("Second", 10, { combat = true }) }
H.eq(R.Match(rules, { combat = true }).set, "First", "a priority tie resolves to the earlier rule")

-- 6. A disabled rule never matches, whatever its priority. This is the "turn it off without
--    deleting it" affordance, and it has to beat priority or it is not an off switch.
rules = {
    rule("Off", 99, { combat = true }, false),
    rule("On", 1, { combat = true }),
}
H.eq(R.Match(rules, { combat = true }).set, "On", "a disabled rule is skipped even at higher priority")

-- 7. An empty `when` is an unconditional fallback — the "what I wear the rest of the time" set.
--    Give it the lowest priority and it is the floor under every other rule.
rules = {
    rule("Fallback", 0, {}),
    rule("Combat", 10, { combat = true }),
}
H.eq(R.Match(rules, { combat = false }).set, "Fallback", "an empty condition set always matches")
H.eq(R.Match(rules, { combat = true }).set, "Combat", "…but yields to any rule that actually fires")

-- 8. Explain — why did this set win? The missing feature that made ItemRack's rules unowned.
rules = {
    rule("Bear", 50, { form = 1 }),
    rule("Cat", 50, { form = 3 }),
    rule("Off", 99, { form = 1 }, false),
}
local why = R.Explain(rules, { form = 1 })
H.eq(why.chosen, "Bear", "Explain reports the winner")
H.eq(#why.considered, 3, "Explain accounts for every rule, not just the winner")
H.eq(why.considered[1].matched, true, "the winning rule is marked matched")
H.eq(why.considered[2].reason, "form", "a losing rule names the condition that failed")
H.eq(why.considered[3].reason, "disabled", "a disabled rule says so rather than looking unmatched")

-- 9. Guards.
H.errors(function() R.Match({ { priority = 1, when = {} } }, {}) end, "a rule without a set is rejected")

H.done()
