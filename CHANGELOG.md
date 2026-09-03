# Changelog

All notable changes to Kitbag. The version here is the one in `Kitbag.toc` — the number players
actually see — and `Tests/toc_test.lua` holds the two together.

## [0.1.0] — 2026-09-03

First release. Gear sets that actually apply.

### Sets

- Save what you're wearing as a named set, equip it in one click, delete it, and pick an icon.
- **Rename a set in the row it lives in.** The name turns into an edit box where it already sits,
  and a name that is taken is refused in the line under the list *while you are still typing it*,
  not in chat after you press. A rename carries everything that points at the set with it — its
  keybinding, the sets that inherit from it, and which set you last equipped.
- **The planner is a pure function**, covered by a test suite that runs outside the game
  (`Tests/run-all.ps1`). Swapping two worn rings is one move rather than two undoing each other; a
  two-hander frees the off hand *before* it goes on, which is the order the client will accept.
- **Nothing is assumed to have worked.** Actions go one per frame, each re-reads the slot it
  targeted, and a step that will not take is retried and then reported — never left silently
  half-done.
- **An item the swap moves out of the way is not reported as missing.** A piece the plan displaces
  from a slot into your bags is exactly where the plan put it, and the equip no longer ends by
  claiming it lost something it is holding.
- An item sitting in the bank is named, by slot, *before* the swap starts, and the set completes on
  a second Equip once you are at a banker.
- Sets can **inherit** from a parent set, so a variant is a delta rather than a copy.
- Copy a set to another character.

### Keybindings

- A key per set, bound from the window.
- **A change is shown and confirmed before it is committed**, so a key you pressed by accident does
  not silently take a binding away from something else.
- **Capture refuses keys you cannot afford to give away** — the movement keys, the modifiers and the
  rest of what the game itself is holding. A gear swap is not worth losing your strafe key to.

### The look of it

- Every region that holds a list, a grid or a model is **recessed the same way** — one edge colour
  and one ground, drawn from one place, so a window reads as panels rather than as controls floating
  on a plate.
- The paperdoll's **character preview sits in a frame** of its own, like the nineteen slot cells
  around it.
- The set list's actions **hang under the list they act on**, in one bar, rather than being scattered
  around the window.
- **Every button in the window is an icon with a tooltip** — Equip, Delete, Copy, Rename, Save, New
  set and Options. Most of them had no tooltip at all while they had a label. The set name box took
  the freed width and now lines up with the list above it.
- Equip is drawn larger than the tools beside it, because with no labels left, size is what says
  which control the window is for; it dims its own icon when you cannot swap.

### Around the edges

- Minimap button, LDB broker, a trinket quick-use bar, a slot flyout.
- **ItemRack import** — this character's sets, its options and its keybindings, in one press.
- `/kit verify` runs the addon's checks against itself and writes the results to SavedVariables;
  `/kit session` lists the acts only a person at a keyboard can perform.

### Not in this release

- **Auto-swap rules are shelved.** The rule engine, its editor, the event wiring and the Rules
  button are in `Icebox/` and nothing loads them, so **Kitbag changes gear only when you ask it
  to**. There is no `/kit rules` and no `/kit why`, and no auto-swap options. Rules you may have
  saved while following development are untouched in your SavedVariables — nothing was migrated
  away — and `Icebox/README.md` lists everything that has to come back with the engine.

### Flavours

Ships **Classic Era** (interface `11509`) and **Mists Classic** (`50504`). Retail and Cataclysm
Classic `.toc` files exist in the repository but are **deliberately not in this zip**: Retail has
never had a frame drawn on it, and Cataclysm Classic no longer exists as a client to run. A `.toc`
in the zip is a promise that the addon runs on that flavour.
