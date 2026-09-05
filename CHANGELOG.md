# Changelog

All notable changes to Kitbag. The version here is the one in `Kitbag.toc` — the number players
actually see — and `Tests/toc_test.lua` holds the two together.

## [0.2.2] — 2026-09-05

Kitbag's icon is clearer at a glance.

### Changed

- **The icon is now an armoured pack.** The first custom icon looked like a polished leather
  satchel; its replacement has a darker, broader silhouette with a helmet strapped to it, so the
  picture reads as gear rather than luggage in the AddOns list, on the minimap, on the broker and on
  the Equip button.

If you are updating from 0.2.1 there is no other change, and your sets are untouched.

## [0.2.1] — 2026-09-03

Kitbag has its own icon.

### Changed

- **The addon wears its own picture instead of a borrowed one.** Kitbag has shown a Blizzard
  breastplate icon since the first window — in the AddOns list, on the minimap button, on the
  LibDataBroker launcher and on the Equip button. All four now show a kit bag drawn for this addon
  and shipped with it. Nothing else moved: the same four controls do the same four things.

If you are updating from 0.2.0 there is no other change, and your sets are untouched.

## [0.2.0] — 2026-09-03

The window grew tabs, and the flavour list shrank to the one that has actually been played.

### The window has tabs

- **Main, Settings and About**, along the bottom in the game's own tab art — the same idiom as the
  character sheet and the spellbook. Main is everything the window already did.
- **Settings is no longer a second window.** The options used to open a separate frame reached
  through a wrench icon; they are a page of the main window now. `/kit options`, the minimap's
  right-click and the LDB broker's right-click all open that page instead. The wrench is gone.
- **About is new.** Honour Bound Game Studios, what Kitbag is, the version you are running, and
  three copyable links — the studio at <https://honourbound.games>, its games on Steam, and this
  repository. Pick a link and it lands in a box, already selected, ready for Ctrl-C; the client has
  no clipboard of its own, so that is the only way a URL gets out of the game.
- The version on that page is read from the addon rather than typed into it, and says `unknown`
  rather than going blank in the first seconds after a login, while the client is still indexing.

### Fixed

- **A refused keybinding no longer writes across the window.** Pressing a key Kitbag will not take —
  one already bound to a player action — put the whole explanatory sentence on an 82-pixel button,
  which does not clip its text: it spilled across the inspector and landed on the Inherit button.
  The button now says `Try again…` and the reason goes to the status line under the set list, where
  the rename refusal already goes.

### Flavours

Ships **Classic Era** only (interface `11509`), and the repository now contains no other `.toc`.
Mists Classic, Cataclysm Classic and Retail were dropped: none of the three had ever had a frame
drawn on it, and a `.toc` is a promise that the addon runs there. **If you installed 0.1.0 on Mists
Classic, this release does not support it.** Nothing about your saved sets changes.

### Still true from 0.1.0

Auto-swap rules remain shelved in `Icebox/` — Kitbag changes gear only when you ask it to. Rules
saved while following development are untouched in your SavedVariables.

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
