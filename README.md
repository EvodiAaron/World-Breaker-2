# World Breaker 2

Automated quarrying for ComputerCraft mining turtles (FTB Revelation / MC 1.12.2).
**No external server required** — everything runs in-game. The v1 Node.js
"Repository API" is gone; the master computer and turtles talk over rednet
(wireless modems), and code is installed via the in-game `http`/pastebin APIs
or by hand.

The old code is preserved untouched in `World-Breaker-v1-legacy/`.

## The levels

Adopt as much or as little as you like:

| Level | What you need | What you get |
|-------|---------------|--------------|
| 0 | 1 mining turtle + fuel | `wb2 quarry 16 16` or `wb2 strip 64`, fully standalone |
| 1 | + chest behind the turtle | Automatic haul-home unloading, refuel waiting point |
| 2 | + wireless modem on the turtle | Status broadcasts, remote control |
| 3 | + a computer with a wireless modem | `wb2master` dashboard: monitor, start/stop, goto, reconfigure a whole fleet |
| 4 | + GPS constellation (4 computers up high) | World-coordinate positions and `goto` across the map |

Optional extras at any level: torch placement, chest/ender-chest unloading,
and automatic torch & chest crafting (see below — no crafty turtle upgrade
needed if the turtle carries a plain crafting table).

Advanced (gold) turtles and computers are auto-detected: the master console
becomes touch-enabled (tap a row to select, tap the buttons, scroll to move)
and turtles color-code their status output. Nothing to configure.

## Installing on a turtle

You only need two files on the turtle: `turtle/wb2.lua` (as `wb2`) and
`turtle/startup.lua` (as `startup`, optional but recommended — it makes the
turtle resume its job after a server restart or chunk reload).

**Option A — GitHub (easiest, needs the in-game http API):**
1. Push this repo to GitHub and edit `BASE` at the top of `install.lua`.
2. Upload the installer once: `pastebin put install.lua` (from a computer that
   has it), or paste it via Option B.
3. On each turtle: `pastebin get <code> install` then `install turtle`.

**Option B — pastebin per file:**
Put `turtle/wb2.lua` on pastebin (from the pastebin website), then in-game:

```
pastebin get <paste-code> wb2.lua
pastebin get <paste-code-2> startup.lua
```

Name the files **with the `.lua` extension**, exactly as above. An
extensionless `/wb2` *shadows* `/wb2.lua` on the shell path — the OTA
update writes `wb2.lua`, so a turtle with a stale `/wb2` will ack every
push and keep booting the old code anyway. (If you have such a fleet:
`delete wb2` + `reboot` on each turtle; v1.3+ turtles also warn at boot
and update whichever file they're actually running from.)

**Option C — no http at all:** craft a disk drive + floppy, `edit` the files
onto the floppy from any computer (or copy from another turtle with
`copy /disk/wb2 /wb2`), and sneakernet them around. Painful for the first
machine, easy for the rest.

## Using a turtle standalone (Level 0–2)

Place the turtle facing the area to mine, give it fuel (put coal in its
inventory — it refuels itself), then:

```
wb2                    -- interactive wizard
wb2 quarry 16 16       -- 16 forward x 16 to-the-right, down to bedrock
wb2 quarry 16 16 20    -- same but only 20 layers deep
wb2 quarry 16 16 left  -- width extends to the turtle's LEFT instead
wb2 quarry 16 16 30 up -- mine UPWARD (30 layers into the sky/ceiling)
wb2 strip 64           -- 64-block 1x2 tunnel, chasing every ore vein it passes
wb2 strip 64 4         -- same, then snakes back and forth 4 more times,
                       --   parallel rows with a 2-block gap between them
wb2 strip 64 4 left    -- snaked rows extend to the LEFT instead
wb2 resume             -- continue a saved task (startup does this for you)
wb2 listen             -- idle, await master commands (needs a modem)
```

The turtle sits **inside the corner block** of the quarry: place it at a
corner of the area you want gone, and its own layer counts as layer 1 of
the requested depth. The volume extends `length` forward, `width` to the
right (or left), and `depth` down (or up) from the block it occupies.

Conventions at the starting position ("home"):
- The turtle's starting block is home; it returns there when full, out of
  fuel, told to return, or finished.
- Loot is unloaded into a chest in the block space **directly behind** home.
  You can place one there yourself, **or just give the turtle chests in its
  inventory** — it places one behind home on its first haul-back. (Or avoid
  home trips entirely with `UNLOAD_MODE chest` / `ender`.) **Any mod's
  chest counts**, placed or carried — Quark spruce chests, iron chests,
  barrels, crates — the turtle uses whatever chest-like thing it has or
  finds (armour "chestplates" and ender chests are excluded; ender chests
  have their own unload mode).
- A **second chest to its left** enables crafting (used as a private buffer,
  because `turtle.craft` needs every non-recipe slot empty). Keep it for the
  turtle only. If there's a spare chest in the turtle's inventory it places
  the buffer chest itself, digging out the spot if it's only rock.
- At startup and whenever a task finishes, the turtle prints a **restock
  list** — the items its current config would use that it isn't carrying
  (fuel, bucket, torches, crafting table, wood, coal, chests, scanner...).
- Refuelling never needs a chest: the turtle eats coal from its own
  inventory, and parks at home to wait if it has none.

### Crafting without giving up the modem

A "crafty mining turtle" (pickaxe + workbench) exists, but turtles have only
**two** equipment slots — so it can't also wear a wireless modem. wb2 works
around this: keep pickaxe + modem equipped and put a **plain crafting table
in the turtle's inventory**. At home, it temporarily swaps the pickaxe for
the crafting table, crafts (logs → planks → sticks → torches, and chests),
then swaps the pickaxe back. A true crafty turtle (no modem) works too.

Modded wood is supported: any log/planks naming scheme is recognised
(`log`, `log2`, `log_0`, `logs.0`, `plank_greatwood`, ...), and each recipe
is filled with a single wood type — the most plentiful one aboard — since
recipes can't mix planks from different mods in one grid.

### Stopping a turtle mid-job

- At its own terminal: hold **Ctrl+T** for a second (terminates any CC
  program). Hold Ctrl+R to reboot, Ctrl+S to shut down.
- From the master: `x` stop in place, `r` return home first, `a` abort the
  task, `e` resume a stopped one. Stops take effect at the next block move.
- If `startup` auto-resumes a job you no longer want: press any key during
  the 3-second startup window, then `wb2 reset` to clear the saved task.

Configuration (persists across reboots):

Everything beyond "dig the hole" is an independent toggle:

```
wb2 config                      -- list everything
wb2 set PLACE_TORCHES true      -- strip mode: torch every TORCH_INTERVAL blocks
wb2 set STRIP_VEIN false        -- ore-vein chasing on/off
wb2 set ORE_SCAN true           -- strip mode: Plethora block-scanner ore homing
wb2 set DROP_JUNK false         -- keep cobble/dirt/decorative stone (one toggle)
wb2 set UNLOAD_MODE ender       -- home | chest | ender
wb2 set CRAFT_TORCHES true      -- craft torches at home (buffer chest needed)
wb2 set CRAFT_CHESTS true       -- craft chests at home (from planks OR logs)
wb2 set AUTO_REFUEL false       -- don't eat mined coal
wb2 set AUTO_RETURN false       -- on critical fuel: wait in place, don't retreat
wb2 set LAVA_REFUEL false       -- don't scoop lava into a carried bucket
wb2 set VEIN_DEPTH 16           -- how far to chase ore veins
```

**Junk is one category, one toggle.** `DROP_JUNK` covers the exact-name
`JUNK` list (cobble, stone, dirt, gravel, sand, ...) *plus* decorative
stones from any mod matched by name (`JUNK_MATCH`: andesite, diorite,
granite, basalt, marble, limestone, tuff, slate). Anything ore-like is
never discarded, whatever it's called.

Notable behaviors, all automatic: gravel/sand columns, mobs in the way,
and full task resume after reboot/chunk-unload via `/wb2data/state`.
**Turtles never dig each other**: a fellow turtle in the dig path is
waited out (~15 s, status shows "another turtle is in my way"); if it
stays parked, the spot is treated like bedrock — routed around or
skipped — so crossing paths in a tiled multi-quarry can't destroy a
fleetmate and spill its inventory.
**Bedrock is tolerated**, not fatal: a bedrock column poking into a quarry
is skipped, cells shadowed behind it are retried from another angle on a
second sweep, and the quarry finishes cleanly around whatever it truly
can't reach. Fuel is watched continuously: the turtle always knows its
distance home, and the moment its fuel is only just enough to make the trip
(plus `FUEL_RESERVE`), it retreats to the start position, unloads, and waits
for you to drop fuel in its inventory — then resumes the job by itself. Set
`AUTO_RETURN false` if you'd rather it held position and waited where it is.

**Free fuel from lava:** give the turtle an **empty bucket** and any lava
source it meets while digging gets scooped and burned on the spot — 1,000
fuel per bucket, and the empty bucket is kept for the next one. Deep
quarries often pay for their own fuel this way. `wb2 set LAVA_REFUEL false`
to turn it off (the bucket only fills when fuel is below `REFUEL_TARGET`).

### Ore homing with a block scanner (Plethora)

With `ORE_SCAN true` and a **Plethora block scanner module in the
inventory** (not equipped — the turtle tool-swaps it onto the pickaxe side
for each scan, exactly like the crafting table trick), a strip mine scans
its surroundings every `SCAN_INTERVAL` blocks, walks to every ore within
the scanner's 8-block radius — including ores plain vein-chasing would
never see through the wall — vein-mines each one, and returns to the
tunnel. The scanner reports world-aligned offsets, so this **needs GPS**
to know which way it's facing; without a GPS fix the turtle says so once
and keeps strip-mining normally.

### When do I use the startup script?

You don't run it — ComputerCraft runs any file named `startup` automatically
every time the turtle boots (placed in the world, chunk re-loaded, server
restarted). Install it once alongside `wb2` and forget it: on boot it waits
3 seconds (press any key to get a shell instead), then resumes an unfinished
job if one is saved, or sits in `listen` mode for master commands otherwise.
Without it, a server restart mid-quarry leaves the turtle idle until you
manually run `wb2 resume`.

## Master computer (Level 3)

Any computer with a wireless modem:

```
wb2master
```

Every turtle running `wb2` (any mode, including `listen`) with a modem
broadcasts its status every few seconds and appears on the dashboard —
no enrolment, no pairing. Every button shows its hotkey as the
capitalised, highlighted letter in its label (`x:Stop` when the label
doesn't contain the key). Select with up/down, then:

- `m` **modes menu** — Quarry / Strip / Multi-quarry / Goto on one screen
  (the direct hotkeys below still work from the dashboard)
- `q`/`s` start a quarry/strip **where the turtle currently stands** (its
  position becomes the new home). Both accept the same trailing options as
  the turtle CLI: `32 32 20 left up` for quarries, `64 4 left` for strips.
- `g` send it to coordinates (world coords with GPS, or `r x y z` relative)
- `x` stop in place, `e` resume, `r` return home & unload, `a` abort task
- `c` **config menu**: every optional feature of the selected turtle on one
  screen — torches, vein chasing, scanner homing, junk, unload mode,
  crafting, auto-refuel/return, lava scooping, thresholds. Booleans toggle
  with enter (or a tap), numbers prompt for a value, changes apply live —
  **mid-run too**: a turtle told `PLACE_TORCHES true` halfway down a tunnel
  starts torching from that block onward.
- `t` toggle torches, `u` cycle unload mode, `i` info screen, `p` ping

Every turtle's row shows an approximate **% complete** for its current task
(blank for to-bedrock quarries, whose total depth is unknown), plus a live
progress bar for the selection. The `i` info screen **updates live** as the
turtle phones home: state, fuel, distance, haul (blocks dug, ores by type),
and a plan-view map of the current quarry layer redraw as fresh statuses
arrive. Turtles announce `ALERT_BLOCKS` finds (diamonds/emeralds by
default) as they happen.

The header shows this modem's **estimated wireless range**, factoring in
height and modem type: 64 blocks at ground level, scaled up by the
master's altitude when GPS can supply it (a trailing `+` means no GPS fix
yet — the real range is *at least* the shown floor, and the master keeps
retrying in the background in case the constellation comes up late).
Wired-only setups show `wired`. **Ender modems are detected
automatically**: the API can't distinguish one, so the first time a
turtle reports from beyond the 384-block standard-modem maximum the
header switches to `range: ender (no limit)` and proximity warnings turn
off. Otherwise, a turtle that reports from within 15% of the limit turns
**orange** in the list — it's about to walk out of contact.

Fleet controls (keyboard only):

- **Shift+X / Shift+R / Shift+E** — stop / recall home / resume **every**
  turtle in range at once.
- **Shift+C** — the same config menu, but every change is broadcast to
  **all** turtles at once (the values shown are the selected turtle's).
- **Multi-quarry** (in the `m` modes menu) — splits one big quarry across
  several turtles as side-by-side tiles. Pick a **leader** (defaults to
  the selection); it anchors the quarry at its own corner block. Then:
  - **With GPS**: the master reads the leader's position + facing and the
    followers **walk to their tile corners themselves**, digging through
    whatever is in the way — they can start scattered anywhere in range.
  - **Without GPS (line mode)**: place the turtles in one row first — each
    directly beside the previous, in the order the plan screen lists, all
    facing the same way as the leader — and they shift themselves apart
    by counting blocks.
  Either way **nothing is mined until every follower reports "in
  position"**; only then does the master fire all the quarries together
  (with your chosen depth, left/right and up/down). Each tile corner is
  that turtle's own home, so give each one chests aboard (or a chest
  behind it). `q` cancels a stuck muster.
- **`l`** — lock the selected turtle to this master. On a multiplayer server
  anyone can send rednet commands; a locked turtle ignores control commands
  from other computers (status stays public, `ping` still works). Press `l`
  again to unlock; or on the turtle itself: `wb2 set MASTER_ID 0`.
- **`v`** — push this computer's copy of `/wb2.lua` to every turtle
  over the air. Turtles sanity-compile the code, install it, reboot, and
  resume their saved task on the new version. **`v` sends the master's
  LOCAL copy** — run `install master` first to fetch the latest from
  GitHub. The push then reports a tally (`wb2 v1.2 push: 5 updated,
  2 REFUSED, 0 silent`), and turtles running unstamped old code show a
  `!` after their state in the fleet list. REFUSED almost always means
  the turtle is **locked to a different master ID** (e.g. the master
  computer was replaced, changing its ID) — a lock can't be cleared
  remotely by a master it doesn't trust, so run `wb2 set MASTER_ID 0`
  at each affected turtle.

Optional peripherals, auto-detected on the master:

- **Speaker** (attach anywhere): a bright *pling* when a turtle reports an
  ore find, a low *bass* note the moment one needs attention (out of fuel,
  chest full, blocked, error).
- **Monitor** (any size, place it against the computer or connect with
  wired modems): a wall dashboard mirroring the whole fleet — one row plus
  progress bar per turtle, recent alerts, and a row of command buttons at
  the bottom. On an **advanced** (gold) monitor, tap a row to select that
  turtle and tap **Return / Resume / Stop / Abort / Ping** to command it
  directly from the wall. Actions that need typing (modes, config, quarry
  sizes) stay on the master's own screen — monitors have no keyboard.

Range note: normal wireless modems reach ~64 blocks at ground level, up to
~384 when both ends are high in the sky, and less during storms. For serious
multiplayer distances use **ender modems** (wireless modem + eye of ender) —
infinite range, cross-dimension, storm-proof. Upgrading is a swap, no code
changes: on the master, replace the modem block; on a turtle, put the ender
modem in slot 1 and run `equip 1 left` (or `right`, whichever side the old
modem is on — the old one pops back into the inventory). Server admins can
also raise `modem_range` in the ComputerCraft config.

**Pocket computers work too**: install `wb2master` on a *wireless* pocket
computer and you have a handheld fleet remote. The UI auto-switches to a
condensed layout on the small screen, and an advanced (gold) pocket keeps
the tap-to-select/tap-button controls. Same rednet range rules apply.

## GPS (Level 4, optional)

Everything works without GPS using dead reckoning (positions shown as
`~x,y,z` relative to each turtle's home). If you set up a standard CC GPS
constellation (4 computers with modems, high in the sky, each running
`gps host x y z`), turtles calibrate themselves when they start a task and
report true world coordinates, and the master's `g`oto accepts world coords.
Calibration digs/steps one block forward and back at task start.

## Files

```
turtle/wb2.lua        the whole turtle brain (quarry, strip, comms, crafting)
turtle/startup.lua    auto-resume after reboot
master/wb2master.lua  fleet dashboard
master/startup.lua    auto-launch console
install.lua           in-game downloader (edit BASE first)
test/sim.lua          headless mock-turtle test suite (run: lua test/sim.lua)
```

## Development

`test/sim.lua` mocks the ComputerCraft turtle/fs/rednet/GPS/peripheral APIs
and runs real quarry and strip jobs against an in-memory world — bounds,
bedrock intrusions, vein chasing, scanner ore-homing, torch placement,
unload trips, mid-run config changes over rednet, mustering (both GPS and
line mode), and reboot-resume are all asserted. Run it with any desktop
Lua 5.3+ after changing `wb2.lua`.
