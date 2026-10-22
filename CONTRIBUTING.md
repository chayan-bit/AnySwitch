# Contributing to AnySwitch

Thanks for helping.
AnySwitch keeps its internals mergeable with the upstream project it grew from (see the [credits](README.md#credits-and-acknowledgements)), so a few rules below are stricter than usual.
By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ground rules

- **Never commit game data.**
  `data/` is gitignored and holds game dumps, `prod.keys`, firmware and everything derived from them: extracted NCAs, NSOs and RomFS files, recompiled code, translated shaders, pipeline archives, IPAs, save files and screenshots of game content you do not want to publish.
  Do not paste any of it into an issue, a pull request or a log excerpt either.
  Do not ask others for keys, firmware or game files.
- **Keep the code game-agnostic.**
  Everything specific to one title (constants, shader tables, memory split, tuning keys) lives only in `dm/games/<title id>/`.
  Prefer a general fix that holds for every game (Horizon, NVN or Vulkan semantics, or what the game's binary, SDK version or imports show) over a title-specific rule.
  A profile key, a rewriter cut or a build-ID gate is for what no general rule can do.
- **Keep merges from upstream easy.**
  Do not rename internal identifiers, files or directories (`dm/`, `dmhost`, `dmsh_*`).
  User-facing names say AnySwitch, internals keep their upstream names.
- **Measure, then change.**
  Put the evidence for a fix (a crash address, a census, a measurement) in the code comment next to it.

## Development setup

You need a Mac with Apple silicon, [Xcode](https://apps.apple.com/app/xcode/id497799835) (the Metal and iOS toolchains), and Python 3.
The command line tools come either from Nix or from Homebrew.
The same steps are in the README's [Setup](README.md#setup).

```
git clone https://github.com/chayan-bit/AnySwitch.git
cd AnySwitch
```

With Nix:

```
nix-shell -p xcodegen zstd spirv-cross dotnet-sdk_10 'python3.withPackages (p: [p.lz4 p.capstone p.fonttools])'
```

Inside that shell, make Xcode's own `xcrun` win over the one Nix puts first, so the Metal compiler is found:

```
unset DEVELOPER_DIR SDKROOT
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v xcrun | paste -sd: -)
```

With Homebrew:

```
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools "backports.zstd; python_version < '3.14'"
```

Build and test with plain `make`, for example `make -C dm/host/tests run`.
Wrappers that queue heavy jobs on a particular machine are a personal convenience and are not part of the project.

The packing script, its options, building by hand and per-game notes are in [docs/development.md](docs/development.md).

## Repository layout

| Path | What is there |
|---|---|
| `scripts/` | Scripts you run: `build_ipa_from_nsp.py` (NSP to IPA), `checkpoint.py` and `dmctl` (dev control, [docs/dev-control.md](docs/dev-control.md)), `compat_table.py` (the README table) |
| `dm/tools/` | The rewriter `patch_nso.py`, ExeFS patches, NSO analysis tools, `nx_extract` (NSP extraction) |
| `dm/host/` | The Horizon stand-in: kernel, services, loader, Mac window front end. Unit tests in `dm/host/tests` |
| `dm/gfx/` | Graphics: NVN on Metal (`nvn/`), Vulkan on Metal (`vk/`), texture layouts (`tex/`), shader tools and the translation chain (`tools/`). See [dm/gfx/README.md](dm/gfx/README.md) |
| `dm/ios/` | The iOS app shell, the settings screen, `tools/build_ipa.sh` |
| `dm/games/` | One game profile per title: `game.tsv` plus generated shader tables. See [dm/games/README.md](dm/games/README.md) |
| `dm/third_party/` | Code from other projects with its licenses. See [THIRD_PARTY.md](THIRD_PARTY.md) |
| `docs/` | Documentation, indexed in [docs/README.md](docs/README.md). `docs/internals` holds the porting and debugging notes |

## Running the tests

CI runs everything marked "CI" below.
The rest needs a Metal device or the iOS toolchain and runs locally.

| Suite | Command | CI |
|---|---|---|
| Host unit tests (no game files, a profile only) | `make -C dm/host/tests run` | yes |
| Python: profiles | `python3 -I dm/games/tests/test_gpu_timestamps_default.py` | yes |
| Python: ExeFS patches (needs `lz4`, `capstone`) | `python3 -I dm/tools/tests/test_exefs_patches.py` | yes |
| Python: checkpoints | `python3 -I scripts/tests/test_checkpoint.py` | yes |
| Python: shader tools | `DM_GAME=0100F43008C44000 python3 -I dm/gfx/tests/test_psoexpand.py` (also `test_shader_split_zlib.py`, `test_tbdr_budget.py`) | yes |
| Lint | `python3 -m compileall -q dm scripts` and `shellcheck -S error dm/ios/tools/build_ipa.sh` | yes |
| Graphics layer (needs a Metal GPU) | `make -C dm/gfx/tests GAME=0100F43008C44000 run` | local only |
| Texture sub-module | `make -C dm/gfx/tex/tests run` | local only |
| Metal example | `make -C dm/gfx/metal run` | local only |
| iOS front end (Foundation parts, Mac) | `make -C dm/ios/tests run` | local only |
| Pipeline archive (`test_psoarch.py`, needs the `t_psoarch` binary and `metal-tt`) | `make -C dm/gfx/tests GAME=0100F43008C44000 t_psoarch`, then `python3 dm/gfx/tests/test_psoarch.py` | local only |

`GAME` and `DM_GAME` take a game profile's title ID and have no default.
The profile named above is only an example; any profile works for suites that read its tracked tables.
Add a test with every fix or feature, and fix a failing or flaky test you meet even if it is not yours.

## Adding a game profile

1. Run `scripts/build_ipa_from_nsp.py` on the game's NSP folder with your own keys.
   With no matching profile it writes a survey (`<title ID>_survey/survey.md`) and a provisional profile outside the repository, then packs a best-effort IPA.
2. Bring the game up with the [internals and porting notes](docs/internals/README.md): extraction, binary survey, host bring-up failures, graphics, debugging.
3. Move the profile into `dm/games/<base game title ID>/` as described in [dm/games/README.md](dm/games/README.md): `game.tsv` (with a `name` row, which the README table and the Mac window title use) and the generated tables (`shader_map.tsv`, `shader_facts.tsv`, `shader_pairs.tsv`, `c1_full.tsv`, `cb_extent.tsv`, `pso_manifest.tsv`, `dmsh_chain.h`).
   The tables hold hashes, shader keys and file paths inside the game, never game bytes.
4. Check `python3 dm/games/game.py list` shows it, and that the host tests still pass.
5. Run `python3 scripts/compat_table.py` and update the table in [README.md](README.md).
6. In the pull request, say which build you tested and on which device class, and attach a short video or screenshots that show no game files.

## Commit style

[Conventional commits](https://www.conventionalcommits.org): `<type>: <description>`, with the type one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`.
Write the description in the imperative and say what changed and why in the body when it is not obvious.
Keep commits small and focused.

## Pull request checklist

- [ ] The change is game-agnostic, or the title-specific part sits in `dm/games/<id>/`.
- [ ] No game files, keys, firmware or derived data, and no `data/` content.
- [ ] Tests added or updated; the CI suites pass locally, and the local-only suites you touched pass too.
- [ ] No internal identifier, file or directory renamed.
- [ ] Docs updated (README, `docs/`, the profile README) when behaviour or options change.
- [ ] A screenshot or a short video for any visible change (UI, rendering, controls).
- [ ] Commit messages follow the style above.

Use the pull request template; it carries the same list.
