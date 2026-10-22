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

While the screen is open the game is out of focus (the same hook the app uses when it loses focus, `dm_focus_set(2)`) and receives no input.
The physical controller belongs to the screen (`dm_gamepad_set_capture` in `DmGamepad.m`); touches are covered by the screen itself.
The + and - buttons reach the game for the first 0.8 seconds of the chord, because the game cannot know a chord is coming.

## Controller navigation

| Input | On the category list | On the rows |
| --- | --- | --- |
| D-pad or left stick up / down | previous / next category | previous / next row |
| D-pad or left stick right | move into the rows | next value, slider step up, toggle on |
| D-pad or left stick left | nothing | previous value, slider step down, toggle off (on the reset and restart rows: back to the list) |
| A | move into the rows | toggle, next value, or press the reset or restart row |
| B | close the screen | back to the category list |
| L / R (also ZL / ZR) | previous / next category | previous / next category |

Holding a direction repeats it after 0.4 seconds.
A button that is already held when the screen opens does nothing until it is released.

## The registry

Every setting is one entry in `DmSettings.m` (`builtinSections`), so the screen and the apply code never name a setting by hand.
An entry has a key, a label, a detail line, a type, its range or options, a default, and when it applies.

| Field | Meaning |
| --- | --- |
| `key` | The environment variable the rest of the app reads, for example `DM_LETTERBOX`. |
| `plistKey` | The Info.plist key that sets the default for a build, or none. |
| `type` | `toggle`, `choice` (with `options`, each `{value, label, aliases}`) or `slider` (with `min`, `max`, `step`, and optional `scale` and `suffix` for the display). |
| `default` | The value as a string. |
| `apply` | `restart` when a change needs a new launch; absent means it applies at once. |

The built-in entries are:

| Category | Setting | Key | Values | Default |
| --- | --- | --- | --- | --- |
| Display | Bars around the picture | `DM_LETTERBOX` | ambient, black | ambient |
| Display | Ambient brightness | `DM_AMBIENT_LEVEL` | 20 to 100 percent | 50 percent |
| Controls | Touch controls | `DM_CONTROLS_LAYOUT` | auto, overlay | auto |
| Controls | Controls size | `DM_CONTROLS_SCALE` | 0.75 to 2.5 | 1 |
| Controls | Controls opacity | `DM_CONTROLS_OPACITY` | 30 to 100 percent | 100 percent |
| Performance | Frame rate counter | `DM_SHOW_FPS` | on, off | off |

### Per-game sections

A game profile can add its own categories with a `dm/games/<title id>/settings.json` file, which `tools/build_ipa.sh` copies to `dm/settings.json` in the app.
The file holds `{"sections": [...]}`, each section `{"id", "title", "icon" (an SF Symbol name), "settings": [...]}` with settings in the form above.
Invalid entries are skipped and logged, never fatal; a key that is already registered is skipped too.
No game ships such a file yet, because no title has a setting that is not already covered by the built-in ones.
The screenshots of the Game category use a fixture that exists only in the test harness.

## Where values come from

From highest to lowest priority:

1. The environment: `Documents/env.txt` (turned into environment variables by `main.m`), or a real environment variable.
   This is the developer's override, so the screen shows the row dimmed with "Set in env.txt" and refuses changes.
2. The player's choice in `Documents/settings.json` (not the save folder, so a save restore never touches it).
3. The Info.plist default (`plistKey`, written by `project.yml` and `build_ipa.sh`).
4. The registry default.

The file holds only what the player changed: `{"version": 1, "values": {"DM_CONTROLS_SCALE": "1.4"}}`.
An unknown key or a value that does not parse is ignored and logged.
`dm_settings_boot()` (called from `main.m`, after `env.txt` is loaded) exports the user's and the plist's values as environment variables for the code that reads them itself.
"Restore defaults" on a page removes the player's values for that page.

## Applying changes

Live settings apply as soon as they change (`settingChanged:` in `front_ios.m`):

- `DM_LETTERBOX` calls `mtl_letterbox_set` and lays the screen out again.
- `DM_AMBIENT_LEVEL` calls `mtl_ambient_level_set`, a small hook in `dm/gfx/nvn/nvn_ambient.h` that replaces the fixed `AMB_DARK` in the present stage.
- `DM_CONTROLS_LAYOUT`, `DM_CONTROLS_SCALE` and `DM_CONTROLS_OPACITY` go to `DmGamepad.m`.
- `DM_SHOW_FPS` adds or removes the counter.

A restart-only setting is stored at once and shows a "Restart now" row at the top of its page, because the running game cannot change it.
The row closes the game; progress that was not saved in the game is lost, which the row says.
The settings are kept, so the next start applies them.

## Tests and checks

`make -C dm/ios/tests run` builds and runs `t_settings.m` on the Mac.
It checks the registry's parsing and validation, the precedence order, the persisted file, live notifications, reset, the restart-pending state and the per-game sections.
Check the screen itself on both an iPad and an iPhone, in light and dark appearance, with the focus on each kind of row, and drive it with a controller as well as by touch.
