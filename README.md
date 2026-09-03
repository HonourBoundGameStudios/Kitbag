# Kitbag

**Gear sets that actually apply.** A gear-set manager for World of Warcraft Classic.

Save what you're wearing as a named set. Put it back on in one click.

> **Auto-swap rules are shelved for now.** The rule engine, its editor and the event wiring live in
> `Icebox/` and nothing loads them, so Kitbag currently changes gear only when you ask it to. Rules
> you already saved are untouched in your SavedVariables and will be there if the engine comes back.

## Why another one

ItemRack was the right idea, and for a long time the only one. What people report about it now is
almost always the same shape of problem: **the set half-applied.** A ring went to the wrong finger.
The shield stayed on under the two-hander. The set looked applied and wasn't.

Every one of those is a bug in *deciding what to move*, not in moving it. So in Kitbag the deciding
is a pure function — no frames, no events, no client — and it is covered by a test suite that runs
under plain Lua outside the game. `Tests/run-all.ps1` is the gate.

That buys three concrete behaviours:

- **Swapping two worn rings is one move, not two.** Moving the ring you want onto the other finger
  swaps both at once; the planner simulates its own effects as it walks the slots, so it knows the
  second slot is already correct instead of emitting a move that undoes the first.
- **A two-hander frees the off hand first.** In the other order the client silently refuses and the
  shield stays on.
- **Nothing is assumed to have worked.** Actions go one per frame, each one re-reads the slot it
  targeted, and a step that won't take is retried and then *reported* — never left silently
  half-done. If an item is in the bank, it says so, by slot name, before it starts.

## Install

Copy the `Kitbag` folder into `World of Warcraft\_classic_era_\Interface\AddOns\`, or run:

```powershell
.\deploy.ps1                                        # default Classic Era install path
.\deploy.ps1 -WowPath "D:\World of Warcraft\_classic_era_"
```

Supports **Classic Era**. That is the only flavour Kitbag ships for.

## Use

| Command | What it does |
|---|---|
| `/kit` | Open the window |
| `/kit save <name>` | Save what you're wearing |
| `/kit equip <name>` | Wear a set |
| `/kit delete <name>` | Remove a set |
| `/kit list` | What's saved |
| `/kit options` | Open the window on its **Settings** tab |
| `/kit inherit <set> from <parent>` | Make a set a delta on another |
| `/kit import` | Bring this character's ItemRack sets across |
| `/kit minimap` | Toggle the minimap button |
| `/kit trinkets` | Toggle the trinket quick-use bar |

## Status

**0.1.0 — early.** The planner, sets and set inheritance, the window with per-row readiness and
move-by-move tooltips, paperdoll flyouts, set icons, the trinket bar, the settings and the ItemRack
importer all work. Auto-swap rules are shelved in `Icebox/` — see the note at the top.

The window has **three tabs** along the bottom: **Main** (the set list and the paperdoll),
**Settings** (what used to be a second window) and **About**.

**Verified in the client on Classic Era only.** The window, the options panel, the paperdoll
flyouts, the slot picker, the set icon picker, the trinket bar and the confirmation popups have all
been seen drawing in a running game.

**The tab strip has NOT been seen in a running client yet.** It passes the suite and `/kit verify`
has a check for it, but the three panels were rearranged after the last in-client pass, so the one
thing no test can answer — whether it looks right — is still open.

**Classic Era is the only flavour.** Mists Classic, Cataclysm and Retail `.toc` files were dropped
on 2026-09-03: none of the three had ever had a frame drawn on it, and a `.toc` file is a promise
that the addon runs there. Treat this as a preview and report what breaks.

## Licence

[MIT](LICENSE). Not affiliated with Blizzard Entertainment. World of Warcraft is a trademark of
Blizzard Entertainment, Inc.
