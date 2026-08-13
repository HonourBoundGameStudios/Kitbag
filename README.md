# Kitbag

**Gear sets that actually apply.** A gear-set manager for World of Warcraft Classic.

Save what you're wearing as a named set. Put it back on in one click. Let rules put it back on for
you when you shift into bear form, or enter combat, or start fishing.

## Why another one

ItemRack was the right idea, and for a long time the only one. What people report about it now is
almost always the same shape of problem: **the set half-applied.** A ring went to the wrong finger.
The shield stayed on under the two-hander. Two rules both matched and the one that won changed
between sessions. The set looked applied and wasn't.

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

And when a rule fires, `/kit why` tells you which rule won, and which condition every other rule
failed on.

## Install

Copy the `Kitbag` folder into `World of Warcraft\_classic_era_\Interface\AddOns\`, or run:

```powershell
.\deploy.ps1                                        # default Classic Era install path
.\deploy.ps1 -WowPath "D:\World of Warcraft\_classic_era_"
```

Supports **Classic Era** and **Mists Classic** from the same folder.

## Use

| Command | What it does |
|---|---|
| `/kit` | Open the window |
| `/kit save <name>` | Save what you're wearing |
| `/kit equip <name>` | Wear a set |
| `/kit delete <name>` | Remove a set |
| `/kit list` | What's saved |
| `/kit why` | Which rule is choosing your set, and why |
| `/kit minimap` | Toggle the minimap button |

## Status

**0.1.0 — early.** The planner, the rule engine, sets, the window, slash commands and the minimap
button work. The rule *editor*, per-slot flyout menus, trinket quick-use and set icons are next —
see `Process/Backlog.md`.

## Licence

MIT. Not affiliated with Blizzard Entertainment. World of Warcraft is a trademark of Blizzard
Entertainment, Inc.
