# In-app settings screen (iOS)

The settings screen is the player's way to change how the app presents and controls the game, without editing files.
It looks like the Switch's System Settings: categories on the left, the chosen category's rows on the right, rounded rows, a cyan border that pulses on the focused item, and the button hints at the bottom.
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
| `internalres` | The graphics layer can draw render targets above the Switch's resolution. No build has it yet, so the Internal resolution row stays hidden; `DM_INTERNAL_RES` is parsed and logged only. |

A value that is stored for a hidden row is kept and still applies; the row only is not offered.

### The built-in entries

| Category | Setting | Key | Values | Default | Applies |
| --- | --- | --- | --- | --- | --- |
| Display | Bars around the picture | `DM_LETTERBOX` | ambient, black | ambient | at once |
| Display | Ambient brightness | `DM_AMBIENT_LEVEL` | 20 to 100 percent | 50 percent | at once |
| Display | Render scale (`fstep`) | `DM_RENDER_SCALE` | 50 to 100 percent | 100 percent | restart |
| Display | Internal resolution (`internalres`) | `DM_INTERNAL_RES` | 1x (Switch), 1.5x, 2x | 1x | restart |
| Controls | Touch controls | `DM_CONTROLS_LAYOUT` | auto, overlay | auto | at once |
| Controls | Controls size | `DM_CONTROLS_SCALE` | 0.75 to 2.5 | 1 | at once |
| Controls | Controls opacity | `DM_CONTROLS_OPACITY` | 30 to 100 percent | 100 percent | at once |
| Controls | Shake sensitivity | `DM_SHAKE_G` | 0.5 to 4.0 G, a lower number reacts to a gentler shake | 1.5 G | at once |
| Controls | Vibration (`haptics`) | `DM_VIBRATION` | on, off | on | at once |
| Controls | Vibration strength (`haptics`) | `DM_VIBRATION_STRENGTH` | 0 to 100 percent | 100 percent | at once |
| Audio | Volume | `DM_VOLUME` | 0 to 100 percent | 100 percent | at once |
| Performance | Frame rate cap (`fpscap`) | `DM_FPS_TARGET` | game decides, 30, 60 | game decides | restart |
| Performance | Frame rate counter | `DM_SHOW_FPS` | on, off | off | at once |
| System | Game language | `DM_LANG` | the Switch languages | en-US | restart |
| System | Player name | `DM_NICK` | text, up to 32 characters | Player | restart |

Everything else that the host reads from a `DM_*` variable stays environment-only: logging, traces and dumps, test hooks, file paths, and the per-game compatibility switches that a game profile sets.

### Shake sensitivity (`DM_SHAKE_G`)

Shaking the device (iPhone or iPad) shakes the controller in games that read its motion.
The accelerometer in `DmGamepad.m` counts a flick as a shake when its acceleration, beyond a slowly followed gravity, exceeds the threshold.
The threshold is the **Shake sensitivity** slider on the Controls page, 0.5 to 4.0 G with 1.5 G as the default, and a change applies at once.
A lower value makes the shake easier to trigger and suits the heavier iPad; a higher one needs a sharper flick.
A line `DM_SHAKE_G=1.0` in `Documents/env.txt` overrides the slider (the row is then dimmed and locked), as for any setting.
The log says which threshold is in use at start (`front end: shaking the device (iPhone or iPad) shakes the controller (threshold ... G)`) and the peak of each detected shake.

### Per-game files

A game profile can ship `dm/games/<title id>/settings.json`, which `tools/build_ipa.sh` copies to `dm/settings.json` in the app.
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
2. The player's choice in `Documents/settings.json` (not the save folder, so a save restore never touches it).
3. The Info.plist default (`plistKey`, written by `project.yml` and `build_ipa.sh`).
4. The game's own default (`"defaults"` in `dm/settings.json`).
5. The registry default.

The file holds only what the player changed: `{"version": 1, "values": {"DM_CONTROLS_SCALE": "1.4"}}`.
The format has not changed; files written by earlier versions load as they are.
An unknown key or a value that does not parse is ignored and logged.
`dm_settings_boot()` (called from `main.m`, after `env.txt` is loaded) exports the player's, the Info.plist's and the game's default values as environment variables for the code that reads them itself; a registry default is the code's own default and is not exported.
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
`t_settings.m` checks the registry's parsing and validation, the precedence order, the persisted file, live notifications, reset and reset-all, the restart-pending state, per-game sections and defaults, capabilities, text limits and the slider display.
`t_haptics.c` checks the amplitude and frequency mapping.
`make -C dm/host/tests GAME=<title id> run` includes `t_vib` (the vibration mailbox and the hid answers) and the master volume checks of `t_audio`.
`python3 -I dm/games/tests/test_settings_defaults.py` checks the per-game files.
Check the screen itself on both an iPad and an iPhone, in light and dark appearance, with the focus on each kind of row, and drive it with a controller as well as by touch.
Check the player name editor with the touch keyboard and with a hardware keyboard, and the vibration rows with a controller attached and without.
