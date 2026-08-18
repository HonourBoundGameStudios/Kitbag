# Changelog

All notable changes to Kitbag. The version here is the one in `Kitbag.toc` — the number players
actually see — and `Tests/toc_test.lua` holds the two together.

## [0.1.0] — 2026-08-18

First release. Gear sets that actually apply.

### Sets

- Save what you're wearing as a named set, equip it in one click, rename, delete, and pick an icon.
- **The planner is a pure function**, covered by a test suite that runs outside the game
  (`Tests/run-all.ps1`). Swapping two worn rings is one move rather than two undoing each other; a
  two-hander frees the off hand *before* it goes on, which is the order the client will accept.
- **Nothing is assumed to have worked.** Actions go one per frame, each re-reads the slot it
  targeted, and a step that will not take is retried and then reported — never left silently
  half-done.
- An item sitting in the bank is named, by slot, *before* the swap starts, and the set completes on
  a second Equip once you are at a banker.
- Sets can **inherit** from a parent set, so a variant is a delta rather than a copy.
- Copy a set to another character.

### Rules

- Auto-swap on shapeshift form, combat, stealth, mounted, resting and zone.
- `/kit why` names the rule that won **and the condition every other rule failed on**.
- A `restore` rule puts your own gear back rather than a named set, and the restore point survives a
  `/reload`.

### The look of it

- Every region that holds a list, a grid or a model is **recessed the same way** — one edge colour
  and one ground, drawn from one place, so a window reads as panels rather than as controls floating
  on a plate.
- The paperdoll's **character preview sits in a frame** of its own, like the nineteen slot cells
  around it.
- **Every button in the window is an icon with a tooltip** — Equip, Delete, Copy, Save, New set,
  Options, Rules and the rule list's move and remove controls. Most of them had no tooltip at all
  while they had a label. The set name box took the freed width and now lines up with the list above
  it.
- Equip is drawn larger than the tools beside it, because with no labels left, size is what says
  which control the window is for; it dims its own icon when you cannot swap.

### Around the edges

- Minimap button, LDB broker, a trinket quick-use bar, a slot flyout, keybindings per set.
- **ItemRack import** — this character's sets, its options and its keybindings, in one press.
- `/kit verify` runs the addon's checks against itself and writes the results to SavedVariables;
  `/kit session` lists the acts only a person at a keyboard can perform.

### Flavours

Ships **Classic Era** (interface `11509`) and **Mists Classic** (`50504`). Retail and Cataclysm
Classic `.toc` files exist in the repository but are **deliberately not in this zip**: Retail has
never had a frame drawn on it, and Cataclysm Classic no longer exists as a client to run. A `.toc`
in the zip is a promise that the addon runs on that flavour.
