# PorterPacker (Linktri build)

A Windower 4 addon that automates storing and retrieving gear with the Porter Moogle
using Storage Slips. This build merges Gimlic's continuous-mode fork (v0.0.1.02) onto
Ivaar's base (v0.0.0.8) with Linktri's debug instrumentation, keypress-based store
confirmation, keybinds, and timing/behavior fixes.

**Current version:** 0.0.1.07

## Lineage

- **Base:** Ivaar's PorterPacker v0.0.0.8
- **Merged in:** Gimlic's fork v0.0.1.02 — continuous ("all") mode
- **Linktri modifications:** debug system, Odyssey Lobby support (zones 279/298),
  0x0D keypress store confirmation, continuous-mode retiming, keybinds,
  `STOW_RETRIEVED` setting, run guard and trade watchdog, `pack everything`, and multiple
  bug fixes (see Changelog)

All non-obvious changes are tagged inline with `LINKTRI MODIFICATION` comments.

## Installation

1. Copy `PorterPacker.lua` into `Windower4/addons/porterpacker/`.
2. Load with `//lua load porterpacker` or add `lua load porterpacker` to your
   `init.txt` / `NEXTGames` load block.
3. Create job data files in `Windower4/addons/porterpacker/data/` (see Data Files).

## Commands

Aliases: `//porterpacker`, `//packer`, `//po`

| Command | Aliases | Description |
|---|---|---|
| `pack [file] [all]` | `store`, `p` | Store inventory items with the Porter Moogle. With a file, only items in the file are stored. |
| `unpack [file] [all]` | `retrieve`, `u` | Retrieve items listed in the file. File defaults to `Name_JOB.lua`, then `JOB.lua`. |
| `repack [file] [all]` | `swap`, `r` | Store inventory items *not* in the file, then retrieve items that *are*. The "swap to this job's kit" command. |
| `pack everything` | `p ev` | Continuous store of **every** storable item from inventory, Wardrobes, and Satchel/Sack/Case. No data file needed. |
| `export [file] [all]` | `exp` | Export storable items to a data file (one line per item). With `all`, scans every accessible bag instead of just inventory. |
| `reset` | | Clear a stuck "busy" state and stop a running continuous pass. |
| `debug` / `debugon` / `debugoff` | | Debug info dump / enable / disable debug logging. |
| `help` | | Command summary. |

### Continuous ("all") mode

Appending `all` (or `a` / `continuous`) to pack/unpack/repack enables continuous mode:

- Storage Slips are pulled from **Satchel, Sack, and Case** as needed, traded, and
  returned to the bag they came from — slips do not need to start in inventory.
- Storable items are pulled from **Wardrobes 1–8** through inventory automatically.
- Runs slip-by-slip until nothing matching remains. A pass that makes no progress ends
  the run (with an 80-pass safety valve behind that).
- Anything still stored at the end is listed by name, so a slip sitting in the Mog Safe
  or a full inventory never fails silently.
- If 3+ storable items are found with no matching slip owned, a "Consider getting
  Storage Slip N" advisory is printed. If you own the slip but it's in a bag the addon
  can't reach, it says that instead.
- Only one run at a time: a second command or keybind press while a run is going is
  refused with a "busy" message.
- If a trade gets no response, you zone, or you use `//po reset`, the run stops,
  reports "Stopped early", and still puts any slips it pulled back where they came from.

**Not scanned:** Mog Safe, Storage, and Locker. The game client cannot move items out
of those bags outside your Mog House, so slips or gear living there are unreachable at
a field Porter Moogle.

## Keybinds

Registered on addon load, released on unload. Edit the `KEYBINDS` table at the top of
the file to change them.

| Key | Command |
|---|---|
| `Ctrl+Alt+P` | `po pack all` |
| `Ctrl+Alt+U` | `po unpack all` |
| `Ctrl+Alt+R` | `po repack all` |

All three use the default job data file and will abort with an error if none exists
for the current job. You must be within ~6 yalms of a Porter Moogle.

## Settings

At the top of `PorterPacker.lua`:

- **`DEBUG_MODE`** (default `false`) — verbose logging of the packet state machine,
  zone/menu discovery, and continuous-mode progress. Toggle live with
  `//po debugon` / `//po debugoff`.
- **`STOW_RETRIEVED`** (default `false`) — when `false`, retrieved gear stays in
  inventory; unpacking stops with a warning if inventory fills (free space and run it
  again to continue). When `true`, retrieved gear is stowed into Wardrobes in
  `bag_priority` order (7 → 6 → 5 → 4 → 3 → 2 → 1 → 8), Gimlic's original behavior.
- **`KEYBINDS`** — key-to-command map, see above.
- **`TRADE_TIMEOUT`** (default `5`) — seconds to wait for the Porter's menu after a
  trade before resetting.
- **`TRADE_STALL_TIMEOUT`** (default `15`) — continuous mode stops if a trade cycle makes
  no progress for this long (long enough to confirm a prompt by hand).
- **`bag_priority`** — Wardrobe stow order used when `STOW_RETRIEVED` is `true`.

## Data files

Data files live in `Windower4/addons/porterpacker/data/` and return a Lua table of
item names:

```lua
return {
    "Wicce Coat +3",
    "Agwu's Robe",
}
```

Lookup order is `Name_JOB.lua` (e.g. `Linktri_BLM.lua`) then `JOB.lua`. Generate a
starting file with `//po export` (inventory only) or `//po export all` (all bags).

## Design notes

- **Store confirmation** uses confirmation-byte detection at offset 0x0D plus a
  simulated Enter keypress. If your chat line is open, it waits up to 5s for it to
  close rather than sending Enter into chat; otherwise confirm the prompt yourself. Unlike packet-rewrite approaches, this preserves the
  game's original messages (correct item names and counts) and drives the state
  machine with a genuine menu-selection packet.
- All continuous-mode delays are gated on work actually happening; the only fixed
  pacing is a 2s settle after items are pulled from other bags into inventory.

## Rolling back

Version 0.0.1.06 is preserved on the
[`v0.0.1.06-backup`](https://github.com/linktri3363/PorterPacker/tree/v0.0.1.06-backup)
branch. Download `PorterPacker.lua` from there to roll back.

## Changelog

- **0.0.1.07** — Code-review fixes. Re-entrancy guard (a double keybind press could start
  two parallel runs). Trade watchdog plus zone-change reset (a trade with no menu
  response left the addon stuck at "busy state: 1" until reload); new `reset` command.
  Every continuous-mode exit now clears `original_retrieve` (a stale list made the next
  normal `pack` skip items) and reports "Stopped early" instead of "Completed Movements";
  aborted runs still return slips to their bags. Data file lookup now really tries
  `Name_JOB.lua` before `JOB.lua`. Continuous mode rescans after every trade, stops when
  a pass makes no progress, won't pull a slip into the last open inventory slot, and lists
  anything left in storage. Slip-return logic consolidated; `retrieve_items` no longer
  sends duplicate moves. Store auto-confirm no longer presses Enter into an open chat
  line. `export` dedupes. Added `pack everything`. `last_update` made local; dead code
  removed. Fixed four misspelled names in the DRG/RDM/SCH/WHM data files, and renamed
  `gitignore` to `.gitignore`.

- **0.0.1.06** — Added `STOW_RETRIEVED` setting (default off): retrieved gear stays
  in inventory; clean stop with warning when inventory fills mid-retrieve.
- **0.0.1.05** — Added addon-managed keybinds (Ctrl+Alt+P/U/R), bound on load and
  released on unload; help text updated.
- **0.0.1.04** — Retimed continuous mode: all sleeps gated on actual work;
  `put_away_items` exits immediately when idle instead of retrying 4×1s (pack runs
  previously wasted ~6–10s of sleeps per slip).
- **0.0.1.03** — Merged Gimlic's continuous mode onto the Linktri/Ivaar base. Kept
  the 0x0D keypress store confirmation; did not port the 0x0C packet rewrite. Fixed
  in the ported code: `original_retrieve` local-shadowing bug (the don't-restore
  filter was permanently inert), global `i` leak in the retrieve loop, file-level
  `slip_used` moved into its loop, nil guard before slip `retrieve_items` call.
- **Earlier (Linktri base)** — Debug system, Odyssey Lobby zone support
  ([279]/[298] = 13), keypress-based auto-confirmation for stores.
