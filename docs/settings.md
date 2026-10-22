# In-app settings screen (iOS)

The settings screen is the player's way to change how the app presents and controls the game, without editing files.
It looks like the Switch's System Settings: categories on the left, the chosen category's rows on the right, rounded rows, an amber ring with a slowly breathing glow on the focused item, and the button hints at the bottom.
It follows the system's light or dark appearance and works on the iPad and the iPhone.

## Opening and closing

- Touch: the gear button at the top, right of the frame-rate counter's place.
- Controller: hold the + and - buttons together for 0.8 seconds.
- Hardware keyboard: Cmd and comma.
- Closing: B on the category list, the X button, the gear again, or the + and - chord again.
- On a hardware keyboard the arrows, Return, Escape, and the square brackets act as the D-pad, A, B, and L / R.
The button hints at the bottom show only what the focused row does (a slider has no A, a text row has no left / right, a row the environment locks has neither).

While the screen is open the game is out of focus (the same hook the app uses when it loses focus, `dm_focus_set(2)`) and receives no input.
The physical controller belongs to the screen (`dm_gamepad_set_capture` in `DmGamepad.m`); touches are covered by the screen itself.
The + and - buttons reach the game for the first 0.8 seconds of the chord, because the game cannot know a chord is coming.

## Controller navigation

| Input | On the category list | On the rows |
| --- | --- | --- |
| D-pad or left stick up / down | previous / next category | previous / next row |
| D-pad or left stick right | move into the rows | next value, slider step up, toggle on |
| D-pad or left stick left | nothing | previous value, slider step down, toggle off (on the reset, restore-all and restart rows: back to the list) |
| A | move into the rows | toggle, next value, open the editor of a text row, or press the reset, restore-all or restart row (restore-all asks for a second press) |
| B | close the screen | back to the category list |
| L / R (also ZL / ZR) | previous / next category | previous / next category |

Holding a direction repeats it after 0.4 seconds.
A button that is already held when the screen opens does nothing until it is released.


## The registry

Every setting is one entry in `DmSettings.m` (`builtinSections`), so the screen and the apply code never name a setting by hand.
Adding a setting is one table entry plus, for a live setting, one line in `settingChanged:` of `front_ios.m` that hands the value to the code that uses it.
An entry has a key, a label, a detail line, a type, its range or options, a default, when it applies, and optionally a capability it requires.

| Field | Meaning |
| --- | --- |
| `key` | The environment variable the rest of the app reads, for example `DM_LETTERBOX`. |
| `label`, `detail` | The row's title and its one-line description. |
| `plistKey` | The Info.plist key that sets the default for a build, or none. |
| `type` | `toggle`, `choice`, `slider` or `text`; see below. |
| `default` | The value as a string. |
| `defaultAtFps` | Optional, live entries only: `{"30": "sharp"}` replaces `default` while the game's frame rate target is that many fps (see "Frame rate dependent defaults"). A value that does not parse, or a restart entry, is skipped and logged. |
| `exportDefault` | Optional: the default is exported to the environment like a player's value. For a key whose code has another default of its own (the flexible pipelines are off in the host and on in the app); without it a registry default is not exported. |
| `apply` | `restart` when a change needs a new launch (the row says "Applies after a restart"); absent means it applies at once. |
| `requires` | A capability the build must have for the row to be shown; see below. Absent means always shown. |

Types and their fields:

| Type | Fields | Shown as |
| --- | --- | --- |
| `toggle` | none | an on / off switch |
| `choice` | `options`, each `{value, label, aliases}` | a selector that steps through the options |
| `slider` | `min`, `max`, `step`, optional `scale` and `suffix` for the display, optional `decimals` | a slider; the value is clamped to the range and snapped to the step, and shown as value times `scale` followed by `suffix` (0.5 with scale 100 and suffix `%` is 50%); `decimals` defaults to what the step times the scale needs |
| `text` | optional `maxLength` (default 64) and `maxBytes` | a row that opens an editor panel in the screen's own style (a live n/limit counter, a visible refusal at the limit and for an empty text; Return or Save stores it, Escape, B or Cancel drops it, and the controller and the key commands pause meanwhile); the value is trimmed, may not hold control characters, and is cut at a whole character to both limits |

Sections that share an `id` are merged into one page, so a game's entries can join a built-in page.
A page with no available entry is not listed.

### Capabilities

A row with `requires` appears only when the running build has that capability, so a setting that would do nothing is never offered.
The capability comes from what the build actually has, not from a title.
`front_ios.m` answers for the screen:

| Capability | True when |
| --- | --- |
| `fstep` | The game's modules carry the rewriter's frame-step stubs (`dm_fps_state` is set by the loader). |
| `fpscap` | Either the frame-step stubs, or an engine frame limit that the host keeps in game memory (`hle_fpslock.c`). |
| `haptics` | The device has a haptic engine, or a controller with haptics is connected. |
| `internalres` | The game draws with NVN (a module references `nvnBootstrapLoader`), whose Metal layer can draw render targets above the Switch's resolution. A Vulkan game does not have it. |
| `nvn` | The same test, for what only the NVN layer does that is not about resolution: the flexible pipelines. |

A value that is stored for a hidden row is kept and still applies; the row only is not offered.

### The built-in entries

| Category | Setting | Key | Values | Default | Applies | Scope |
| --- | --- | --- | --- | --- | --- | --- |
| Display | Bars around the picture | `DM_LETTERBOX` | ambient, black | ambient | at once | both |
| Display | Ambient brightness | `DM_AMBIENT_LEVEL` | 20 to 100 percent | 50 percent | at once | system |
| Display | Upscaling | `DM_UPSCALE` | bilinear, sharp | sharp at 30 fps, bilinear at 60 fps (see below) | at once | both |
| Display | Sharpening (only under Sharp) | `DM_UPSCALE_SHARPNESS` | 0 to 100 percent | 80 percent | at once | both |
| Display | Render scale (`fstep`) | `DM_RENDER_SCALE` | 50 to 100 percent | 100 percent | restart | game |
| Display | Internal resolution (`internalres`) | `DM_INTERNAL_RES` | 1x (original), 1.5x, 2x | 1x | restart | game |
| Display | Console mode | `DM_OPMODE` | auto, handheld (0), docked (1) | docked (a game that needs Handheld sets it in its pack defaults) | restart | both |
| Controls | Touch controls | `DM_CONTROLS_LAYOUT` | auto, overlay | auto | at once | both |
| Controls | Controls size | `DM_CONTROLS_SCALE` | 0.75 to 2.5 | 1 | at once | system |
| Controls | Controls opacity | `DM_CONTROLS_OPACITY` | 30 to 100 percent | 100 percent | at once | system |
| Controls | Fade when idle | `DM_CONTROLS_IDLE_FADE` | on, off | on | at once | system |
| Controls | Touch layout | `DM_PAD_LAYOUT` | game's choice, 2D, 3D | game's choice | at once | game |
| Controls | Shake sensitivity | `DM_SHAKE_G` | 0.5 to 4.0 G, a lower number reacts to a gentler shake | 1.5 G | at once | system |
| Controls | Vibration (`haptics`) | `DM_VIBRATION` | on, off | on | at once | both |
| Controls | Vibration strength (`haptics`) | `DM_VIBRATION_STRENGTH` | 0 to 100 percent | 100 percent | at once | system |
| Audio | Volume | `DM_VOLUME` | 0 to 100 percent | 100 percent | at once | system |
| Performance | Frame rate cap (`fpscap`) | `DM_FPS_TARGET` | game decides, 30, 60 | game decides | restart | game |
| Performance | Flexible pipelines (`nvn`) | `DM_PSO_FLEX` | on, off | on | restart | game |
| Performance | Frame rate counter | `DM_SHOW_FPS` | on, off | off | at once | system |
| System | Game language | `DM_LANG` | the Switch languages | en-US | restart | both |
| System | Player name | `DM_NICK` | text, up to 32 characters | Player | restart | system |

Everything else that the host reads from a `DM_*` variable stays environment-only: logging, traces and dumps, test hooks, file paths, and the per-game compatibility switches that a game profile sets.

### Shake sensitivity (`DM_SHAKE_G`)

Shaking the device (iPhone or iPad) shakes the controller in games that read its motion.
The accelerometer in `DmGamepad.m` counts a flick as a shake when its acceleration, beyond a slowly followed gravity, exceeds the threshold.
The threshold is the **Shake sensitivity** slider on the Controls page, 0.5 to 4.0 G with 1.5 G as the default, and a change applies at once.
A lower value makes the shake easier to trigger and suits the heavier iPad; a higher one needs a sharper flick.
A line `DM_SHAKE_G=1.0` in `Documents/env.txt` overrides the slider (the row is then dimmed and locked), as for any setting.
The log says which threshold is in use at start (`front end: shaking the device (iPhone or iPad) shakes the controller (threshold ... G)`) and the peak of each detected shake.

### Internal resolution (`DM_INTERNAL_RES`)

The game draws its render targets at 1x, 1.5x or 2x the Switch's resolution, and the frame is presented from the larger picture.
The row appears only for a game that draws with NVN (the `internalres` capability), 1x is the default on every device, and a change applies on the next start.
A scaled target takes S² times the memory of the 1x one: 2.25 times at 1.5x and 4 times at 2x.
When the memory left to the app drops below 768 MB (`RS_MEM_GUARD_MB` in `nvn_mtl.m`), new targets stay at 1x, so the game keeps running with part of the picture at 1x instead of being closed by the system.
On a device with 8 GB of memory or less, the row's description adds a note to that effect; 2x stays selectable there.
The log names the scale at start (`internal resolution: 2x (DM_INTERNAL_RES)`), each target demoted to 1x and the reason, and with the perf report the live scaled targets and their memory (`internal resolution memory: ...`).

### Upscaling (`DM_UPSCALE`)

The picture is enlarged from the game's resolution to the screen either by the plain bilinear stretch or by AMD FidelityFX Super Resolution 1 (Sharp), with `DM_UPSCALE_SHARPNESS` as the strength of its sharpening pass.
Sharp costs a few milliseconds of GPU time per frame (about 4 ms at a tablet's screen size): an eighth of a 30 fps frame, a quarter of a 60 fps one.
So the default depends on the frame rate: **Sharp for a game that runs at 30 fps, Bilinear for one that runs at 60** (see below).
Either way the row stays on the Display page and the player can pick the other one at any time.
It has no effect at 1.5x and 2x internal resolution, where the picture is not enlarged.

### Frame rate dependent defaults

An entry with `defaultAtFps` has a default that follows the game's frame rate target, `DmSettings.frameTarget` (30 or 60; 0 while unknown).
The app takes it from the host (`mtl_fps_target()`: the frame cap of the profile or the player when there is one, else the present interval the game itself asks for, where an interval of 2 held for a second means 30), reads it at start and again every second, so it is also right for a game that starts at 60 and settles at 30 after its first second.
The effective default is then, after the earlier sources of "Where values come from": the entry's `defaultAtFps` value for the current target, else its `default`.
When the target moves, the entries whose effective default changes with it are announced like a change made in the screen, so the picture switches at once and the row shows the new value.
The Mac host does not read the target: with no `DM_UPSCALE` set it keeps the bilinear stretch.

A choice the player made is stored even when it equals the default of that moment (other entries drop a value that equals the default), because the default moves: Bilinear picked in a 60 fps game must not turn into Sharp when a later start finds 30 fps.
"Restore defaults" drops the choice, so the default of the moment applies again.
A `settings.json` of the player from an older build loads unchanged: a stored Sharp stays Sharp.
One thing an older build cannot tell: a player who had explicitly picked Bilinear while it was the default has nothing stored, and so gets the new Sharp default at 30 fps; picking Bilinear again keeps it.
A game can still pin it with `"defaults": {"DM_UPSCALE": "bilinear"}` in its `settings.json`, which beats the frame rate default.

### Flexible pipelines (`DM_PSO_FLEX`)

The flexible pipelines (`dm/gfx/nvn/nvn_flexpso.m`, `dm/gfx/README.md`) make the game's graphics pipelines on background threads from a pipeline archive shipped in the app, and skip a draw for a moment instead of stalling the frame.
The row is on the Performance page for a game that draws with NVN (the `nvn` capability), is **on by default**, and a change applies on the next start.
The row's detail says what it costs: it can make the first launch slightly slower, and it avoids hitches while playing.
The host itself defaults to off (the Mac host, its tests and tools), so the entry has `exportDefault`: the app hands its default over to the environment.
`build_ipa.sh` builds the pipeline archive by default (`PSO_FLEX=0` leaves it out).

### Per-game files

A game profile can ship `dm/games/<title id>/settings.json`, which `tools/build_ipa.sh` copies to `pack/profile/settings.json` in the app.
It holds two optional keys:

- `"defaults": {"DM_KEY": "value"}` replaces the registry default for that game, for any registered key.
  A game default is not the player's choice: the screen shows it as the default, "Restore defaults" returns to it, and it is exported to the environment like a player's value so the host sees it.
  A value that does not parse, or a key that is not registered, is ignored and logged.
- `"sections": [...]` adds categories of its own, each `{"id", "title", "icon" (an SF Symbol name), "settings": [...]}` with entries in the form above.
  A section whose `id` matches a built-in one adds its entries to that page.

Invalid entries are skipped and logged, never fatal; a key that is already registered is skipped too.
The frame rate cap's default must follow the profile's `fps_target`, so a game with an `fps_target` ships `{"defaults": {"DM_FPS_TARGET": "<fps_target>"}}`; `dm/games/tests/test_settings_defaults.py` checks that.

## Where values come from

From highest to lowest priority:

1. The environment: `Documents/env.txt` (turned into environment variables by `main.m`), or a real environment variable.
   This is the developer's override, so the screen shows the row dimmed with "Set in env.txt" and refuses changes.
2. The player's choice for this game (entries of scope game or both), then the player's system choice, both in `Documents/settings.json` (not the save folder, so a save restore never touches it).
3. The Info.plist default (`plistKey`, written by `project.yml` and `build_ipa.sh`).
4. The game's own default (`"defaults"` in `pack/profile/settings.json`).
5. The default for the game's frame rate target (`defaultAtFps`, only the entries that have one).
6. The registry default.

The file holds only what the player changed: `{"version": 2, "system": {"DM_CONTROLS_SCALE": "1.4"}, "games": {"<title id>": {"DM_LETTERBOX": "black"}}}`.
A version 1 file (`{"version": 1, "values": {...}}`) is read as the system layer, so the single game's old choices still apply, and it is written as version 2 on the first change.
Every change merges into the file on disk key by key, so a store of the system settings and a store of a game over the same file do not undo each other's changes.

## Scopes

Each entry names where the player's choice lives with `"scope"`.
`system` (the default) is one value for every game: Volume, Controls size, Player name.
`game` is per game only and is not shown in the system settings: Render scale, Frame rate cap, Touch layout.
`both` is a system value that a game may override: Bars around the picture, Upscaling, Console mode, Game language.
A pack's own entries (`profile/settings.json`) are `game` unless they name a scope.
The Scope column of the table above is the built-in list (`DmSettings.builtinScopes`), and `t_settings.m` checks it.
In a game's settings, a `both` row says "System setting" until the player changes it for that game; the row then says it is for this game only, and holding it (Use system setting) drops the game's choice.
Choosing the system value again also drops it, so a later system change still reaches the game.
"Restore defaults" in a game's settings drops that game's choices and the system-only values of the page; the system values of `both` rows stay.
Console mode Auto is resolved when the game starts: Docked while an external display is connected, else Handheld.
An unknown key or a value that does not parse is ignored and logged.
`dm_settings_boot()` (called from `main.m`, after `env.txt` is loaded) exports the player's, the Info.plist's and the game's default values as environment variables for the code that reads them itself; a registry default is the code's own default and is not exported (unless the entry has `exportDefault`), and neither is a frame rate dependent default (the front end hands that one to the graphics layer itself).
"Restore defaults" on a page removes the player's values for that page.
"Restore all defaults" removes them for every page; it asks for a second press so one stray tap does not do it.
Keys that the environment sets are left alone by both.

## Applying changes

Live settings apply as soon as they change (`settingChanged:` in `front_ios.m`):

- `DM_LETTERBOX` calls `mtl_letterbox_set` and lays the screen out again.
- `DM_AMBIENT_LEVEL` calls `mtl_ambient_level_set`, a small hook in `dm/gfx/nvn/nvn_ambient.h` that replaces the fixed `AMB_DARK` in the present stage.
- `DM_CONTROLS_LAYOUT`, `DM_CONTROLS_SCALE` and `DM_CONTROLS_OPACITY` go to `DmGamepad.m`.
- `DM_SHAKE_G` goes to `dm_gamepad_shake_g`; the accelerometer handler reads the threshold on every sample.
- `DM_VOLUME` goes to `dm_audio_volume`: a gain the sound card callback reads, with no allocation and no lock.
  The slider is a loudness curve (the gain is the square of the slider, so half way is 12 dB down) and a change ramps across one block so it does not click.
- `DM_VIBRATION` and `DM_VIBRATION_STRENGTH` go to `dm_haptics_enable` and `dm_haptics_strength`.
- `DM_SHOW_FPS` adds or removes the counter.

A restart-only setting is stored at once and shows a "Restart now" row at the top of its page, because the running game cannot change it.
The row closes the game; progress that was not saved in the game is lost, which the row says.
The settings are kept, so the next start applies them.

## Vibration

The game's HD rumble reaches the screen's two settings through three small pieces:

- `dm/host/hle_vibration.c` answers the game's `nn::hid` vibration calls.
  With haptic hardware the game sees vibration devices: left and right for handheld or dual Joy-Con, one otherwise.
  The latest value of each device is kept in a lock-free mailbox, so the game thread only stores and never waits, and a burst of values collapses to what the engine can play.
  Without hardware the game sees no devices, as before.
- `DmHapticMap.h` turns a value into Core Haptics terms.
  A Switch value is two bands, each an amplitude from 0 to 1 and a frequency in Hz.
  The intensity is the energy of the two amplitudes, `sqrt(low^2 + high^2)` capped at 1, times the strength setting; an amplitude under 2 percent is not played.
  The sharpness is where the amplitude-weighted mean frequency sits between 40 Hz (0) and 1252 Hz (1) on a log scale, so the idle 160 Hz band is 0.40 and the idle 320 Hz band 0.60.
  A value that the game stopped sending for half a second counts as silence, so a game that never sends a closing zero does not leave the device buzzing.
- `DmHaptics.m` plays it.
  A controller with haptics plays the left and right devices on its left and right actuators (a game that asked for one device drives both); with no controller the device's own haptic engine plays, which an iPad does not have.
  One poll thread at 60 Hz reads the mailbox and moves the intensity and sharpness of a looping continuous event with dynamic parameters.

## Tests and checks

`make -C dm/ios/tests run` builds and runs `t_settings.m` and `t_haptics.c` on the Mac.
`t_settings.m` checks the registry's parsing and validation, the precedence order, the persisted file, live notifications, reset and reset-all, the restart-pending state, per-game sections and defaults, capabilities, text limits, the slider display, the frame rate dependent defaults (Upscaling at 30 and 60 fps, a stored choice winning over them) and the flexible pipelines row.
`t_haptics.c` checks the amplitude and frequency mapping.
`make -C dm/host/tests run` includes `t_vib` (the vibration mailbox and the hid answers) and the master volume checks of `t_audio`.
`python3 -I dm/games/tests/test_settings_defaults.py` checks the per-game files.
Check the screen itself on both an iPad and an iPhone, in light and dark appearance, with the focus on each kind of row, and drive it with a controller as well as by touch.
Check the player name editor with the touch keyboard and with a hardware keyboard, and the vibration rows with a controller attached and without.
