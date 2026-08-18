-- KitbagRules — pure auto-swap rule matching.
--
-- ItemRack's event system was its best idea and its worst-behaved code: rules fired in an order
-- nobody could predict, two rules that both matched fought each other, and there was no way to see
-- why a set had been chosen. Kitbag's answer is a pure function — given the rules and a snapshot of
-- the world, which set wins, and why. No frames, no events, no client.
--
-- Usage: lua Tests/rules_test.lua   (run from the project root)

local H = dofile("Tests/harness.lua")
local R = dofile("KitbagRules.lua")

H.start("KitbagRules")

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

-- ---------------------------------------------------------------------------
-- Authoring (RULE-2)
-- ---------------------------------------------------------------------------
--
-- The engine has been evaluable since RULE-1 and unusable, because there was no way to write a rule
-- in the game. The editor is a frame, but everything it *decides* — what a condition is, what a rule
-- reads as in English, what reordering does to the list — is plain data and belongs here, where it
-- can be tested. What is left in the frame is wiring.

-- The catalogue. The UI renders whatever is in it, so adding a condition later is a line here plus a
-- key in the state snapshot, not a new widget.
H.ok(#R.CONDITIONS > 0, "there is a catalogue of conditions the editor can offer")
local byKey = {}
for _, c in ipairs(R.CONDITIONS) do byKey[c.key] = c end
H.eq(byKey.combat.kind, "boolean", "combat is a yes/no condition")
H.eq(byKey.form.kind, "choice", "form is chosen from a list the client supplies")
H.eq(byKey.zone.kind, "text", "zone is typed in")
H.ok(byKey.combat.label ~= nil, "every condition carries a human label for the editor")

-- Every condition in the catalogue must exist in the state snapshot, or it can never match and the
-- editor cheerfully offers a rule that will never fire.
local STATE_KEYS = { form = true, combat = true, stealth = true, mounted = true, resting = true,
    zone = true, spell = true, buff = true, instance = true }
for _, c in ipairs(R.CONDITIONS) do
    H.ok(STATE_KEYS[c.key] == true, c.key .. " is a key KitbagEvents actually reports")
end

-- Describe — the rule as a sentence. This is what a list row shows, and the reason the editor does
-- not need to be read as a form to be understood.
H.eq(R.Describe({ set = "Bear", when = {} }), "always",
    "a rule with no conditions describes itself as always")
H.eq(R.Describe({ set = "Bear", when = { combat = true } }), "in combat",
    "a boolean condition reads as a phrase, not as combat=true")
H.eq(R.Describe({ set = "Bear", when = { combat = false } }), "out of combat",
    "…and its negative reads as the opposite phrase, not as 'not in combat'")
H.eq(R.Describe({ set = "X", when = { combat = true, stealth = true } }), "in combat and stealthed",
    "conditions join with 'and', because they are ANDed")
H.eq(R.Describe({ set = "X", when = { stealth = true, combat = true } }), "in combat and stealthed",
    "…in a fixed order, so the same rule reads the same way every time")
H.eq(R.Describe({ set = "X", when = { zone = "Orgrimmar" } }), "in Orgrimmar",
    "a zone reads as a place")
H.eq(R.Describe({ set = "X", when = { form = 1 } }, { form = { [1] = "Bear Form" } }), "in Bear Form",
    "a form uses the label the client gave it")
H.eq(R.Describe({ set = "X", when = { form = 1 } }), "in form 1",
    "…and falls back to the raw value rather than showing nothing")

-- Reordering. The list order IS the tiebreak (see Match above), so moving a rule is a real edit and
-- not a cosmetic one.
local list = { rule("A", 1, {}), rule("B", 1, {}), rule("C", 1, {}) }
H.eq(R.Move(list, 3, -1), 2, "moving a rule up returns its new index")
H.eq(list[2].set, "C", "…and it is where it was moved to")
H.eq(list[3].set, "B", "…having swapped with the one it passed")
H.eq(R.Move(list, 1, -1), 1, "moving the first rule up is a no-op, not an error")
H.eq(R.Move(list, 3, 1), 3, "…and so is moving the last one down")
H.eq(R.Move(list, 9, 1), nil, "an out-of-range index moves nothing")
H.eq(#list, 3, "…and does not disturb the list")

-- Coerce — the editor hands back strings from edit boxes and nils from unticked boxes. Turning that
-- into a typed condition table is where a rule silently becomes unmatchable: `form = "1"` never
-- equals the number the client reports, and the rule just never fires with no error to explain it.
local when = R.Coerce({ form = "1", combat = true, stealth = nil, zone = "  Orgrimmar  " })
H.eq(when.form, 1, "a numeric condition is stored as a number, not the string the box gave")
H.eq(when.combat, true, "a ticked box is stored as true")
H.eq(when.stealth, nil, "an unticked box is absent, not false — false is a real condition")
H.eq(when.zone, "Orgrimmar", "typed text is trimmed, so a stray space does not make it unmatchable")
H.eq(R.Coerce({ zone = "" }).zone, nil, "an empty box is no condition at all")
H.eq(R.Coerce({ form = "abc" }).form, nil, "unparseable input is dropped rather than stored as junk")
H.eq(R.Coerce({ nonsense = true }).nonsense, nil, "a key that is not a condition is not stored")
H.eq(next(R.Coerce(nil)), nil, "coercing nothing is an empty condition set, not an error")

-- ---------------------------------------------------------------------------
-- Spell-cast conditions (RULE-3)
-- ---------------------------------------------------------------------------
--
-- "The fishing pole when I cast Fishing, the pick when I mine." The spell is a condition like any
-- other — the work is in KitbagEvents putting the spell name into the snapshot while a cast is in
-- flight and taking it out again afterwards — but it must read as a sentence and match exactly.

H.eq(byKey.spell.kind, "text", "the spell is typed in, since the list of them is the whole spellbook")
H.eq(R.Describe({ set = "Fishing", when = { spell = "Fishing" } }), "when casting Fishing",
    "a spell condition reads as what it is")
H.eq(R.Describe({ set = "X", when = { spell = "Mining", combat = false } }),
    "out of combat and when casting Mining",
    "…and combines with the others in catalogue order like anything else")

-- Exact match, not a prefix: "Fish" must not fire on "Fishing", or a rule written for one spell
-- silently governs a dozen. Match already compares with ==; this pins it as intended, not incidental.
local castRules = { rule("Rod", 10, { spell = "Fishing" }) }
H.eq(R.Match(castRules, { spell = "Fishing" }).set, "Rod", "the named spell matches")
H.eq(R.Match(castRules, { spell = "Fish" }), nil, "a shorter name is a different spell")
H.eq(R.Match(castRules, { spell = false }), nil, "no cast in flight matches no spell rule")

-- ---------------------------------------------------------------------------
-- Buffs and instance type (RULE-5)
-- ---------------------------------------------------------------------------
--
-- A buff breaks the "state[k] == when[k]" shape every other condition has: the player has thirty
-- auras and the rule names one. Rather than special-case it in Match, the catalogue entry says the
-- state value is a set and the condition is a membership test — so the matcher stays one loop and a
-- future set-valued condition costs a flag rather than a branch.

H.eq(byKey.buff.membership, true, "a buff condition is a membership test, not an equality one")

local buffRules = { rule("Ony", 10, { buff = "Onyxia Scale Cloak" }) }
H.eq(R.Match(buffRules, { buff = { ["Onyxia Scale Cloak"] = true, ["Mark of the Wild"] = true } }).set,
    "Ony", "a rule fires when the named buff is among the ones you have")
H.eq(R.Match(buffRules, { buff = { ["Mark of the Wild"] = true } }), nil,
    "…and not when it is merely one you might have")
H.eq(R.Match(buffRules, { buff = {} }), nil, "no buffs at all matches no buff rule")
H.eq(R.Match(buffRules, { buff = false }), nil,
    "a state that is not a set of buffs fails the condition rather than erroring")

H.eq(R.Describe({ set = "X", when = { buff = "Mark of the Wild" } }), "while Mark of the Wild is up",
    "a buff condition reads as a state you are in")

-- Instance type is ordinary equality, but its values are strings the client uses rather than
-- anything a player would type, so the catalogue carries the list and the words for it.
H.eq(byKey.instance.kind, "choice", "instance type is chosen from a fixed list")
H.ok(#byKey.instance.options > 0, "…and the catalogue carries that list, not the client")
H.eq(R.Describe({ set = "X", when = { instance = "raid" } }), "in a raid",
    "an instance type reads as the place it is, not as its API token")
H.eq(R.Match({ rule("Raid", 10, { instance = "raid" }) }, { instance = "raid" }).set, "Raid",
    "an instance-type rule matches the client's own token")

-- Coerce must not put an instance token through tonumber the way it does a form index — the two are
-- both "choice" to the editor and only the catalogue knows one is a number.
H.eq(R.Coerce({ instance = "raid" }).instance, "raid", "a string choice survives coercion as a string")
H.eq(R.Coerce({ form = "2" }).form, 2, "…while a numeric choice is still made a number")
H.eq(R.Coerce({ buff = "  Mark of the Wild " }).buff, "Mark of the Wild",
    "a typed buff name is trimmed like any other text")

-- ---------------------------------------------------------------------------
-- A rule only ever equips (RULE-4 removed)
-- ---------------------------------------------------------------------------
--
-- Restore-previous was taken out: a rule used to put a set on while it matched and put back what
-- you were wearing when it stopped. It is gone at the Admiral's request, and this block is what
-- stops it returning by accident — a `restore` flag left on stored data must be inert, not dormant.
--
--   Next(activeSet, winner) -> { action = "none" | "equip", set = }

local stale = { set = "Bear", priority = 10, when = { form = 1 }, restore = true }
local permanent = { set = "Tank", priority = 10, when = { combat = true } }

local step = R.Next(nil, stale)
H.eq(step.action, "equip", "a rule that starts matching equips its set")
H.eq(step.set, "Bear", "…that set")
H.eq(step.remember, nil, "…and remembers nothing, whatever the stored rule still says")

H.eq(R.Next(nil, permanent).remember, nil, "a plain rule remembers nothing either")

H.eq(R.Next("Bear", stale).action, "none",
    "a rule that goes on matching does nothing — the swap already happened")

step = R.Next("Bear", { set = "Cat" })
H.eq(step.action, "equip", "a different winner takes over")
H.eq(step.set, "Cat", "…with its own set")

-- The whole of the behaviour change: nothing comes back when a rule stops matching.
H.eq(R.Next("Bear", nil).action, "none",
    "a rule that stops matching leaves the set it applied on — nothing is put back")
H.eq(R.Next(nil, nil).action, "none", "no rule at all is the quiet case")

-- ---------------------------------------------------------------------------
-- What the engine is entitled to believe afterwards (BUG-10)
-- ---------------------------------------------------------------------------
--
-- Next() decides from `activeSet`, so `activeSet` had better be true. The engine used to set it the
-- instant it decided to swap, before the equip was attempted and without ever revisiting it — so a
-- swap that FAILED left the engine believing that set was on, Next() answered "none" for as long as
-- that rule kept winning, and the rule never fired again. Reported from the client as "I mounted and
-- it did not trigger", the mount after a swap that had reported "stuck on Off hand". A /reload was
-- the only cure, because `active` does not survive one.
--
--   Held(previous, step, ok) -> the set the engine may claim is on, or nil

H.eq(R.Held(nil, { action = "equip", set = "Bear" }, true), "Bear",
    "a swap that worked is held — that is what stops the rule firing again every event")
H.eq(R.Held(nil, { action = "equip", set = "Bear" }, false), nil,
    "a swap that FAILED is not held, or its rule is dead until the next reload")
H.eq(R.Held("Tank", { action = "equip", set = "Bear" }, false), nil,
    "…and the set before it is not held either: a half-applied plan left neither of them on")

H.eq(R.Held("Bear", { action = "none" }, true), "Bear",
    "doing nothing changes nothing — the set that was on stays on")
H.eq(R.Held("Bear", nil, false), "Bear",
    "…and so does an attempt that was never made at all")

-- ---------------------------------------------------------------------------
-- Whether a step can be attempted at all, right now (RULE-6)
-- ---------------------------------------------------------------------------
--
-- The symptom: a ghost with a matching rule burns the whole of the driver's BUSY_LIMIT on every
-- qualifying event, fails, and writes a failure into the swap history — repeatedly, for the whole
-- corpse run. Nothing is broken afterwards; the history just fills with failures that describe the
-- addon rather than anything the player did.
--
--   Defer(step, state, options) -> "now" | "dead" | "combat"
--
-- The reason keys `Core.SWAP_BLOCKED`, deliberately: the engine holding off and the button greying
-- itself are the same fact about the world, and one wording for it is the whole point of UI-19.

local step = { action = "equip", set = "Fishing" }

H.eq(R.Defer(step, { dead = false }, {}), "now",
    "a live player attempts the swap")
H.eq(R.Defer(step, { dead = true }, {}), "dead",
    "a dead one waits instead of spending ten seconds finding out")

-- Death is not an option, unlike combat: no setting makes an equip succeed while you are a ghost,
-- so deferInCombat is not what decides this.
H.eq(R.Defer(step, { dead = true }, { deferInCombat = false }), "dead",
    "…with deferInCombat off, because death is a fact and not a preference")
H.eq(R.Defer(step, { dead = true, combat = true }, { deferInCombat = true }), "dead",
    "…and death outranks combat, which is the state that actually clears first")

H.eq(R.Defer(step, { combat = true }, { deferInCombat = true }), "combat",
    "the combat deferral is the same decision and stays here with it")
H.eq(R.Defer(step, { combat = true }, { deferInCombat = false }), "now",
    "…and is still the option it always was")

-- The one refusal that must NOT defer. Equipping cancels the cast that triggered it — that is how
-- the fishing-pole rule is supposed to work (RULE-3) — so treating `casting` the way CanSwap does
-- would hold the pole back until the cast the pole was for had finished.
H.eq(R.Defer(step, { casting = true }, {}), "now",
    "casting refuses a BUTTON, not the engine: the swap is what ends the cast")

H.eq(R.Defer({ action = "equip", set = "Bear" }, { dead = true }, {}), "dead",
    "…and the corpse run is what provokes it: a rule matching while dead must wait, not attempt")
H.eq(R.Defer({ action = "none" }, { dead = true }, {}), "now",
    "doing nothing is always allowed — there is nothing to hold back")

-- Total, like everything else on this path: it runs on every event, and a missing reading must not
-- be able to stop the engine for ever.
H.eq(R.Defer(step, nil, nil), "now", "an unreadable state acts rather than waiting for ever")
H.eq(R.Defer(nil, { dead = true }, {}), "now", "…and so does no step at all")

H.done()
