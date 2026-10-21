# Documentation

The [README](../README.md) covers what AnySwitch is, how to pack an IPA and how to play.
These pages are for working on it.

| Page | Covers |
|---|---|
| [development.md](development.md) | How it is built, the packing script's options, building by hand on the Mac, adding a game, power and performance notes, per-game notes, the tools in `dm/tools` |
| [settings.md](settings.md) | The in-app settings screen: opening it, controller navigation, the settings registry, per-game sections, tests |
| [exefs-patches.md](exefs-patches.md) | Applying community ExeFS patches (IPS, IPS32, `.pchtxt`) at build time: formats, matching, conflict rules |
| [dev-control.md](dev-control.md) | Checkpoint saves and the dev input channel for driving a game frame by frame from the Mac |
| [agents/README.md](agents/README.md) | Guide to porting a new title: extraction, binary survey, host bring-up failure catalogue, graphics specifics, debugging recipes |

Documentation that lives next to the code:

| Page | Covers |
|---|---|
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Setup, repository layout, tests, adding a game profile, commit style, PR checklist |
| [../dm/games/README.md](../dm/games/README.md) | The game profile format: every `game.tsv` key and the generated tables |
| [../dm/gfx/README.md](../dm/gfx/README.md) | The graphics layer: NVN on Metal, the shader translation chain, run-time switches, letterbox, precompiled pipeline archives |
| [../dm/third_party/README.md](../dm/third_party/README.md) | Bundled third-party code, versions and local changes |
| [../THIRD_PARTY.md](../THIRD_PARTY.md) | Credits and licenses |

`images/` holds the screenshots the docs use.
