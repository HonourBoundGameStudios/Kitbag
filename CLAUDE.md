# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.
**Only always-on rules live here.** Evidence, measurements and decision reasoning go in `Research/`
and are referenced by path, never `@import`ed.

## Project Overview

**Kitbag** is a gear-set manager for **World of Warcraft Classic** — the job ItemRack used to do,
rebuilt. Save what you're wearing as a named set, swap it back in one click, and let rules swap it
for you on form/combat/stealth/zone.

- **Stack:** Lua 5.1 (the WoW runtime), Blizzard FrameXML. No XML files, no libraries, no build step
  — the client compiles the Lua at load and you iterate with `/reload`.
- **Flavours:** Classic Era (`Kitbag.toc`) and Mists Classic (`Kitbag_Mists.toc`) from one file
  list. Retail is a backlog item, not a second repo.
- **SavedVariables:** `KitbagDB`, schema-versioned — see `KitbagDB.lua`.

**The design premise, and the reason this rewrite exists:** the parts that decide anything are
**pure** and are tested outside the game. Every "it half-applied my set / equipped the wrong ring /
dropped my offhand" report is a *planning* bug, and a planner that only exists inside the client can
only be tested by wearing the bug.

| File | Role |
|---|---|
| `KitbagCore.lua` | **PURE.** Item identity, set capture, the equip planner. No WoW API. |
| `KitbagRules.lua` | **PURE.** Which set wins for a given world state, and `Explain()` for why. |
| `KitbagCompat.lua` | **The only file allowed to branch on the game flavour.** |
| `KitbagDB.lua` | SavedVariables schema, defaults, migrations. |
| `KitbagInventory.lua` | Reads the client into the plain tables the planner takes. No decisions. |
| `KitbagEquip.lua` | Performs a plan: one action per frame, verify each, bounded retries. |
| `KitbagSets.lua` | The one code path that equips a set. UI, slash and rules all go through it. |
| `KitbagEvents.lua` | Events in, state snapshot out, hands it to `KitbagRules`. |
| `KitbagUI.lua` / `KitbagMinimap.lua` | The window and its launcher. |
| `Kitbag.lua` | Bootstrap: load order, SavedVariables handoff, slash commands. Loads last. |

## The Process — NON-NEGOTIABLE

**RED → GREEN → REVIEW (repeat until clean) → COMMIT → propose next → repeat.** One item, one commit.

1. **RED** — write the failing test *first*, and confirm it fails.
   - Pure logic (planner, rules, parsing, migrations) → a `Tests/*_test.lua` case. **This is the
     default, and the seam is worth extracting for.**
   - Client behaviour with no pure seam → state the expected in-game behaviour and confirm it does
     **not** happen yet (`/reload` and observe the absence).
2. **GREEN** — the minimum code to pass. `Tests\run-all.ps1` must be green.
3. **REVIEW** — read the diff for correctness, style, and simplification. Fix, re-verify, repeat
   until the review is clean.
4. **COMMIT** — immediately, one behaviour per commit.
5. **Propose the next item and wait** for a go-ahead.

**Hard rules:** never implement before the failure is confirmed; never skip the review; never batch
two items into one commit; never commit with `run-all.ps1` red.

**Extract the testable seam.** Pull decisions out of the frame/event code into plain functions that
take tables and return tables, and test *those* exhaustively. The wiring left behind is thin enough
to eye-verify. This is the single highest-leverage habit in this codebase.

## Common Commands

```bash
pwsh -File Tests/run-all.ps1                    # the gate — every pure test
lua Tests/core_test.lua                         # one file (run from the project root)
pwsh -File deploy.ps1                           # copy into the WoW AddOns folder
pwsh -File deploy.ps1 -WowPath "D:\WoW\_classic_era_"
```

In-game: `/reload` to pick up changes, `/kit` to open, `/kit why` to see which rule is choosing.
Enable Lua errors while developing: `/console scriptErrors 1` (or run BugSack).

`Tests/` is **not** shipped — `deploy.ps1` copies only `*.lua` at the root and `*.toc`.

## Code Style

- **Locals over globals.** The single sanctioned global is the `Kitbag` namespace table (plus the
  `KitbagDB` SavedVariables and the `SLASH_*` pairs the client requires by name).
- Each module ends `Kitbag.X = X; return X` — the `return` is what lets `Tests/` load it with
  `dofile()` outside the game, where the addon-private `...` table does not exist.
- **4 spaces**, no tabs. Functions small. `PascalCase` for module functions, `localCamelCase` for
  file-locals.
- **English** for all strings, comments and docs. **UTF-8**, **LF** line endings.
- Comments explain **why**, not what.

## Gotchas

- **Load order is load-bearing.** Every module reads its dependencies out of `Kitbag` at load time,
  so a module must appear in the `.toc` *after* everything it uses. `Kitbag.lua` is last.
- **Both `.toc` files must list the same files.** Adding a module and forgetting `Kitbag_Mists.toc`
  breaks that flavour only, and only at runtime.
- **`## Interface` numbers go stale every patch** and a stale one can refuse to load. Verify against
  the live client.
- **`GetItemInfo` returns nil for an uncached item.** Never treat nil as "not a two-hander" — that is
  the path that silently reintroduces the half-applied swap. `KitbagInventory.Meta` only asks about
  keys a set actually names, to keep the window for this small.
- **Equipping is asynchronous.** Firing a whole plan in one frame means later actions read a world
  that hasn't caught up. `KitbagEquip` does one action per frame and verifies each; don't "optimise"
  that away.
- **PowerShell writes CRLF.** Use the editor (or the agent's write tool) for tracked files; if
  PowerShell wrote one, `git add --renormalize <file>`.

## Project Document Layout

`Process/` (Backlog.md, Bugs.md, Archive.md, Tasks.md) · `Research/` · `Design/` · `Tests/`.
The addon's `.lua` and `.toc` live at the root so the game can load the folder directly.

**Read `Process/Backlog.md` and `Process/Bugs.md` at the start of a session; update them as part of
the work.**

**⚠️ `Process/`, `Research/` and `Design/` are gitignored — they are NOT in the repository.** They
live on disk only. That is what keeps the working notes off a public repo (see the Commit Format
section), and it has one consequence worth stating out loud, because it removes a safety net this
project used to rely on:

- **The notes cannot be updated "in the same commit as the work", because they are in no commit at
  all.** The old rule said exactly that and it is now impossible to follow.
- **So nothing catches drift between the docs and the code.** `git status` stays clean however stale
  `Backlog.md` gets, a diff review will never show a doc that should have changed, and there is no
  history to ask when a claim stopped being true. Under the old arrangement a wrong backlog was at
  least *visible* in the diff.
- **The discipline therefore has to be deliberate: update the notes in the same working session as
  the change, before moving on.** Treat "the tests are green and the notes still describe the old
  behaviour" as unfinished work, not as a tidy-up for later — because there is no later signal.
- **Back them up separately if they matter.** They are not in the repo, so they are not on GitHub and
  not in any clone; a lost working tree loses them outright.

## Commit Format

```
type(scope): short imperative summary

Body explaining WHY, not what. Wrap ~72 cols.

Co-Authored-By: <Agent name> <noreply@anthropic.com>
```

`type` ∈ `feat | fix | chore | docs | refactor | test | style`.

**The Admiral always pushes.** The agent commits, never pushes. Never `--no-verify`.

**One repo, and the working notes are simply not in it.** `upstream` is the public GitHub repo and
`master` is pushed to it directly — same as every other ship in the fleet. `Process/`, `Research/`
and `Design/` are **gitignored**, so they live on disk and have never been part of the repository.
That is the entire guard, and it is the reason there is nothing else to remember: a file git does
not track cannot be leaked by a push, by an IDE, or by a forgotten step. `CLAUDE.md` **is** tracked
and public, deliberately — it is guidance, not notes.

Kitbag previously ran a two-repo whitelist arrangement with a publish script and a pre-push hook.
It leaked anyway, twice, and the second time was an IDE pushing on commit. It is gone; do not
reintroduce it. **Nothing here needs a special publish step — just commit.**

## Standing orders

- **Re-read this `CLAUDE.md` periodically.** Don't rely on the session-start read alone — in a long
  session (or after a context compaction), re-read this file at regular intervals so the Process, the
  gotchas, and the standing rules don't drift out of context.

- **Anything the Admiral has to DO goes last, under its own heading.** Findings first, then the ask.
  Never interleave the two: a request buried in the middle of an explanation is a request that gets
  missed, and the Admiral then re-reads the whole report to find out what was wanted. This matters
  most in exactly the situation that produces the longest reports — an in-client debugging round trip,
  where the agent cannot act and every step forward is something only the Admiral can do. State what
  the evidence says, then say what would settle it, in that order. One clearly-marked ask beats three
  scattered ones; if there are genuinely several, number them.

## Fleet Comms 📡 — you are part of a fleet

**Kitbag** is one ship in a fleet of projects coordinated by the **Orchestrai** flagship. Ships
talk to each other through **Subspace**: file-based messages (Markdown + YAML frontmatter) dropped
into a recipient's `Process/subspace/inbox/`. All repos share the local filesystem, so this needs no
network — the flagship's `tools/fleet-comms.ps1` resolves each ship's path from its registry.

- **At session start, read `Process/subspace/inbox/`** and report any unread messages before starting
  work. Act on each, then move it to `inbox/archive/`.
- **Update `Process/ship-log.json`** when you ship something notable (a feature, a release, a fixed
  bug) — it's how the fleet sees this ship's status and how `Muster` reads a sitrep.
- **`Hail <ship>: <msg>`** sends a message to another ship; **`Muster`** reads every ship's log for a
  fleet sitrep. These are flagship-orchestrated — the Admiral runs them from Orchestrai.
- **Fleetcast 📡** — when the Admiral broadcasts a process/guidance change to the whole fleet,
  apply it here too (this `CLAUDE.md` first, then any affected docs) in the same commit.
- **Crew stays central.** The fleet's shared skills/agents live in the private flagship + user-level
  `~/.claude`, and an agent running here inherits them from there. **Never vendor shared crew into
  this repo.** This ship's own **domain** skills/agents may live here — and, **in a private repo
  only**, be committed via the explicit `.gitignore` whitelist; in a public repo they stay
  uncommitted.

> Security: keep the fleet roster need-to-know. Don't broadcast every ship's presence or location.
