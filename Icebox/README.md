# Icebox

Code that is **shelved, not deleted**. Nothing in here is loaded: no `.toc` lists it, `deploy.ps1`
and `package.ps1` copy only `*.lua` at the project ROOT, and `Tests/run-all.ps1` globs only
`Tests/*_test.lua`. Being in this folder is what makes all three true at once.

## What is here, and why

**The auto-swap rule engine**, shelved 2026-08-18.

| File | Was |
|---|---|
| `KitbagRules.lua` | **PURE.** Which set wins for a given world state, and `Explain()` for why. |
| `KitbagEvents.lua` | Events in, state snapshot out, handed to `KitbagRules`. |
| `KitbagRulesUI.lua` | The rule editor window. |
| `Tests/rules_test.lua` | The pure test suite for `KitbagRules`. |

Rules and their conditions are **still in the SavedVariables** — `KitbagDB` keeps `rules = {}` per
character and the schema is untouched, so shelving the engine costs nobody the rules they wrote.
`autoSwap` and `deferInCombat` likewise still exist as stored options; they simply have no checkbox
while nothing reads them, because a control that does nothing reads as a feature that is switched
off rather than one that is absent.

## What came out of the shipped addon with it

Restoring the engine means restoring these too — `git log` has all of them at their last working
form, and this list exists so none of them is discovered later by a reader wondering why the dump
suddenly says less than it used to.

- `Kitbag.lua` — `/kit rules`, `/kit why`, `Events.Enable()` at login, `RulesUI.Refresh()` in
  `Kitbag.Refresh`.
- `KitbagUI.lua` — the Rules icon button; Options took over its corner of the bottom row.
- `KitbagBroker.lua` — the "Rules would choose: …" tooltip line.
- `KitbagDebug.lua` — the `RULES`, `ENGINE` and `EVENTS` sections of the dump. `STATE` survived but
  now reads `Compat.ActionState()` rather than `Events.State()`, so it is four booleans rather than
  the full condition snapshot.
- `KitbagVerify.lua` — the `rules-window`, `watched-events` and `rule-list-layout` checks, the Rules
  entry in the bottom-row measurement, the rule list in the wheel-layering equivalence, and the
  VERIFY-18 session act.
- `KitbagDB.lua` — the `autoSwap` and `deferInCombat` entries in `DB.OPTIONS`.
- `Tests/` — the engine and rule-editor sections of `load_test.lua`, and the rule sections of
  `debug_test.lua` and `verify_test.lua`.

## Bringing it back

1. `git mv` the files back to the root (and `Tests/rules_test.lua` back to `Tests/`).
2. List them in **all four** `.toc` files, in the load order they had: `KitbagRules.lua` after
   `KitbagCore.lua`; `KitbagEvents.lua` after `KitbagSets.lua`; `KitbagRulesUI.lua` after
   `KitbagUI.lua`.
3. Restore the call sites above.
4. Delete the icebox section at the end of `Tests/toc_test.lua` — it asserts this shelving, and it
   is the test that will tell you if you have missed step 2.
