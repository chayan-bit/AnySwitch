# Dev control: checkpoint saves and the dev input channel

Two game-agnostic test tools, so agents stop navigating games by screenshot and tap.
Checkpoint saves start a run at a known place in the game.
The dev input channel drives the game frame by frame from the Mac, on the Mac host and in the iOS app.
Checkpoints are the game's own save data: they live only under `data/checkpoints/`, which is gitignored, and are never committed or uploaded.

## Checkpoint saves (`scripts/checkpoint.py`)

The Mac host and the iOS app keep a save the same way, in `dm/host/hle_fs.c`.
`DM_SAVE` is the committed save directory; a mount clones it to `<dir>.work`, and every Commit swaps the whole work tree back in atomically.
On the iPad the app sets `DM_SAVE` to `Documents/save` (`dm/ios/Sources/main.m`).
So a checkpoint is that committed directory, byte for byte, plus a manifest with the size and SHA-256 of every file.
A checkpoint lives at `data/checkpoints/<title id>/<name>/` with `save/` and `checkpoint.json`; anything else there (proof screenshots) is ignored by the tool.

```sh
# Mac: export the committed save of a run (not <dir>.work), install one before a launch
python3 scripts/checkpoint.py export 0100ABF008968000 bedroom --mac data/run/save --note "saved in the bedroom"
python3 scripts/checkpoint.py import 0100ABF008968000 bedroom --mac data/run/save
DM_SAVE=data/run/save ... dm/host/dmhost <patched dir>

# iPad: copy Documents/save out of the app, or install a checkpoint (stops the app first) and launch it
python3 scripts/checkpoint.py export 0100ABF008968000 ipad-bridge --device <udid> --bundle com.example.app
python3 scripts/checkpoint.py import 0100ABF008968000 bedroom --device <udid> --bundle com.example.app --launch

python3 scripts/checkpoint.py list
python3 scripts/checkpoint.py verify 0100ABF008968000 bedroom
```

Import on the Mac deletes the target directory and its `.work` and `.new` leftovers, then copies the checkpoint in.
Import on the iPad finds the app's running process through `devicectl device info apps` and `info processes`, terminates it, and copies the checkpoint over `Documents/save` with `--remove-existing-content true`, so no stale file survives.
A running app is stopped first because it would commit its own save over the checkpoint.
Export refuses `.work` directories, empty saves and an existing name without `--force`, and checks the copy against the source manifest.
Import refuses a checkpoint whose files no longer match its manifest.
One difference between the platforms is handled explicitly.
A guest file name that collides on the case-insensitive host file system is kept in the extended attribute `org.d2rmobile.guest-name`, and `devicectl` does not carry extended attributes.
Export records such files in `guest_name_xattrs`, and import to a device refuses that checkpoint instead of installing it wrong.
Sword's save is one file, `main` (1,603,146 bytes), with no extended attributes.

## Dev input channel

### Build

The channel exists only in dev builds.
`make -C dm/host GAME=<id> DEVCTL=1 dmhost` defines `DM_DEVCTL` and adds `dm/host/devctl.c`; `dm/host/hle_devctl.c` compiles to nothing without the flag.
The Makefile records the dev flag in `gen/game.stamp`, so switching between a dev and a product build always relinks.
A product build has no channel: `strings dm/host/dmhost | grep -c devctl` gives 0 for a product build and 13 for a dev build.
The iOS project takes the flag from the same compile command: run `dm/ios/tools/gen_build.py` (or `build_ipa.sh`) with `DEVCTL=1` in the environment, and `Gen/dm.xcconfig` gets `OTHER_CFLAGS = $(inherited) -DDM_DEVCTL`.

### Security

The socket binds to `127.0.0.1` port 47800 by default.
`DM_DEVCTL_ADDR` may name another numeric local address (for example the device tunnel's), and `DM_DEVCTL_PORT` another port; the wildcard addresses `0.0.0.0` and `::` are refused.
At start the host draws a random 128-bit token and prints it in the log: `devctl: dev input channel listening on 127.0.0.1 port 47800, token <32 hex digits>`.
On the iPad that log is `Documents/log.txt`.
The first line of every connection must be `auth <token>` within 10 seconds; anything else gets `err auth`, a one-second delay and a closed connection.
One client at a time.
The only commands are `frame`, `run` and `quit`: no file access, no memory access, nothing else.

### Protocol

Plain text lines over TCP.

| Client sends | Host answers |
|---|---|
| `auth <token>` | `ok frame <N>` |
| `frame` | `frame <N>` |
| `run <sequence>` | `done start <S> end <E> frame <N>` once the game has presented frame E, or `err <reason>` |
| `quit` | closes the connection |

`<N>` is the number of frames presented so far (`dm_guest_frame`).
A `run` starts at the next frame (S = N + 1) and the reply comes when the whole sequence has played.

### Where the input goes

Events go through `dm_pad_set`, the same path as `DM_KEYS`: ORed with the keyboard, touch and physical controller path, with press edges latched until the game's next read.
The game reads its controller through `hle_hid.c`, which calls `devctl_poll` on every controller and touch read.
`devctl_poll` applies every event due by the current frame number, one `dm_pad_set` per event, so a press and a release due together still reach the game as a press.
Because events are keyed to presented frames and applied at the game's own reads, a sequence lands on the same frames on a busy machine.
Do not combine the channel with `DM_KEYS` in one run: both write the scripted controller slot.

### Sequence grammar

Steps are separated by commas, semicolons, spaces or new lines; everything is counted in frames.

| Step | Meaning |
|---|---|
| `KEYS` | tap: KEYS down for 5 frames, then up for 5 frames before the next step |
| `KEYS~h` | tap held for h frames |
| `KEYS~h*n/every` | the tap n times, one every `every` frames (default h + 5) |
| `hold(KEYS)` | KEYS down until released |
| `release(KEYS)` | KEYS up; a stick name or vector centres that stick |
| `release` | everything up and centred |
| `wait(N)` | N frames pass |
| `fN:step` | the step at absolute frame N (it may not go back in time) |

KEYS joins key names with `+`.
Buttons use the `DM_KEYS` names: `A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down`.
Full stick deflections: `LLeft LUp LRight LDown RLeft RUp RRight RDown`.
Stick vectors: `L(x,y)` and `R(x,y)`, with x and y from -1 to 1 (up is +y), so `L(0.5,-1)~60` pushes the left stick half right and fully down for 60 frames.
`T<x>x<y>` is a touch at normalized picture coordinates (origin top left), and `Shake` shakes the controller.
Names are case-insensitive.
The `DM_KEYS` seconds stamps (`8:A`) are refused, because the channel counts frames only; use `fN:` or `wait(N)`.
Examples: `f1200:A`, `A*13/45`, `hold(ZL+LUp) wait(60) release`, `L(-0.25,-1)~90`, `T0.31x0.62`.
The parser is `dm/host/devctl.c`; its unit test is `dm/host/tests/t_devctl.c` (27 checks, `make -C dm/host/tests GAME=<id> run`).

### Client (`scripts/dmctl`)

```sh
scripts/dmctl --log data/run/host.log frame
scripts/dmctl --log data/run/host.log run 'f1200:A wait(240) L(0,1)~3 A'
scripts/dmctl --log data/run/host.log run -f route.txt      # one step list per file, # starts a comment
scripts/dmctl --token <hex> --port 47800 frame             # or DMCTL_TOKEN=<hex>
```

`--log` takes the token from the last token line of a host log or a copied `Documents/log.txt`.
It prints the host's reply and exits 0 for `ok`, `frame` and `done`, 1 for `err`, and 2 when it cannot connect or is refused.
`--timeout` (default 600 s) bounds the wait for a `run` reply.

## Mac recipe

```sh
make -C dm/host GAME=0100ABF008968000 DEVCTL=1 dmhost
python3 scripts/checkpoint.py import 0100ABF008968000 bedroom --mac data/devctl/run/save
W=data/nsp/0100ABF008968000_build
DM_ROMFS=$W/extract/v458752/RomFS DM_MSL_DIR=$W/shader/cache DM_AOC_DIR=$W/aoc \
DM_NVN_SHMAP=dm/games/0100ABF008968000/shader_map.tsv DM_FONT_DIR=data/stageA/run/font \
DM_SAVE=data/devctl/run/save DM_TEMP=data/devctl/run/temp DM_KBD=Player \
DM_FIXED_TIME=1790000000 DM_NVN_SHOT="$(seq -s, 30 30 9000):data/devctl/run/shots/f_%d.png" \
dm/host/dmhost $W/patched_v458752 > data/devctl/run/host.log 2>&1 &
scripts/dmctl --log data/devctl/run/host.log run -f walkout.txt
```

The screenshots are the renderer's own frame dumps (`DM_NVN_SHOT`), named by frame number, so the frame numbers `dmctl` prints map straight to files.
Send a sequence with absolute `fN:` stamps right after the token line appears, before frame N passes.

## Sword checkpoints made on the Mac

All three were made with the channel only, from a fresh save, then each was installed into a fresh run and loaded with `f1200:A wait(400)` (A on the title screen).

| Name | Place | Load proof (frame dump) |
|---|---|---|
| `setup-done` | the living room right after language, photo, naming and the opening | `setup-done/proof/loaded_f1500.png` |
| `bedroom` | the player's bedroom, bag not yet picked up | `bedroom/proof/loaded_f1650.png` |
| `postwick-outside` | the front garden in Postwick, bag and cap on, before Hop | `postwick-outside/proof/loaded_f1500.png` |

Route 1 was not made: past the front garden the story runs through Hop, his house, Leon and the starter choice before the route opens, which is not cheap to script blind.

## Determinism check on the Mac

The `bedroom` checkpoint was driven twice with this sequence and nothing else: title, pick up the bag, the cap cutscene, out through the kitchen and the hall to the front garden.

```
f1200:A wait(240)
L(0,1)~3 A wait(60) A*13/45 wait(60)
L(0,-1)~20 L(-1,0)~100 wait(30)
L(1,0.3)~40 wait(30)
L(-0.25,-1)~90 wait(150)
```

Both runs replied `done start 1 end 2618 frame 2618` and ended in the front garden at the same spot.
Frame dumps every 30 frames: 79 of 89 are identical pixel for pixel, including every frame from 30 to 2400, through the bag, the cutscene and the walk through the house.
Frame 1980 differs in 0.01 % of its pixels; from frame 2430 on, outdoors, frames differ in 4 to 38 % of pixels because ambient animation (foliage, sky) follows the wall clock.
Those runs used the wall clock, because `DM_DETCLOCK` hangs Sword (next section).

## Open items

1. `DM_DETCLOCK` hangs Sword about 130 frames after a save loads into the field, with or without the channel (reproduced with `DM_KEYS=f1200:A` alone).
   The watchdog dump shows the main thread spinning in `SleepThread` (svc 0xb, 703,280 calls) under `main+0x1860344`, waiting on guest time, which advances only per present while it presents nothing.
   A fix belongs in the deterministic clock (advance it when the presenting thread sleeps instead of presenting), not in the channel.
2. Device reachability: the app binds the channel to the iPad's loopback address; reaching it from the Mac relies on a usbmux or tunnel port forward (`ios forward --udid <udid> 47800 47800`), to be confirmed in the device step.
3. The device JSON fields the import uses (`result.apps[].url`, `result.runningProcesses[].executable`, `processIdentifier`) are checked by unit tests against a fake device only, until the device step.
