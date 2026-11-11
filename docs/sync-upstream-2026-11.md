# Upstream sync, 2026-11

This merge brings seedds/nxnative `main` at `a77c0ee8` into AnySwitch, on branch `sync/upstream-2026-11`.
The fork point was `23a11da7`; upstream had moved on by several hundred commits, so 112 files conflicted and many more needed our features replayed on top of upstream's rewrites.
The rule was: where upstream superseded one of our features, take upstream's version; keep the features only AnySwitch has (Hearth, game packs, the runtime game profile, the RomFS chunk store, community ExeFS patches, the ambient letterbox, the FSR 1 sharp upscale, multi-user saves).
A product decision was never made here: those are listed under [Decisions for the user](#decisions-for-the-user), with our behaviour kept until then.
How to run the next sync: [development.md, Syncing with upstream](development.md#syncing-with-upstream).

## The runtime profile

Upstream compiles one host per game from a generated `game_profile.h`; AnySwitch runs one host for every game and reads the profile at boot from `game.json`.
The merge keeps ours and makes upstream's code compile unchanged on it:

- `dm/games/game.py json` writes every key of upstream's header, with upstream's validation and defaults, so a new upstream profile key reaches `game.json` with no change in game.py.
- `dm/host/profile.h` / `profile.m` hold and parse every key; `dm/host/game_profile.h` maps each `DM_GAME_*` name onto `g_profile`.
- What cannot be a run-time value was changed to a run-time check: `#if DM_GAME_*` blocks, the display-version list, the cheats lookup.
- `DM_PROFILE_SCHEMA` went from 1 to 2, so game packs made before this merge must be built again.

## Decisions by file

| File | Decision | Why |
| --- | --- | --- |
| .github/ISSUE_TEMPLATE/*.yml | ours | issue templates belong to our repository, not upstream's tracker |
| CONTRIBUTING.md, README.md | ours | AnySwitch's own identity and rules; upstream's text describes seedds/nxnative |
| .gitignore | union | both sides only added ignore rules |
| AGENTS.md | upstream, plus our commit-style line and a game.json step in the chain procedure | upstream's agent notes are current; the host reads the chain version from game.json in AnySwitch |
| dm/games/*/dmsh_chain.h (per-title) | upstream (deleted) | superseded: upstream has one chain version for every game in dm/gfx/nvn/dmsh_chain.h |
| dm/games/*/c1_full.tsv, cb_extent.tsv | upstream (untracked, gitignored) | upstream makes them from each shader build and no longer commits them |
| dm/games/0100ABF008968000/{game.tsv,shader_map,shader_facts,pso_manifest}.tsv | upstream | upstream ported Pokemon Sword independently (0045c1df); its profile is newer (pad_layout full, sys_resource 0) |
| dm/games/0100ABF008968000/game.tsv shader_groups | upstream (2 groups) | ours split /bin/archive into 7 groups only to make partial shader rebuilds faster; not needed for correctness |
| dm/games/0100ABF008968000/shader_facts_manual.tsv | ours (kept) | 260 integer-output (fout uint) rows that upstream's Sword facts do not carry; shader_split.py still merges this file |
| docs/agents (our rename to docs/internals) | upstream path restored, docs/internals dropped, links repointed | the rename only reworded upstream's notes; keeping upstream's paths keeps every future sync of those docs conflict-free |
| docs/settings.md | upstream's; ours moved to docs/hearth-settings.md | both sides added a settings page: upstream's documents settings.tsv / launcher.json, ours the Hearth (DmSettings) screen |
| docs/development.md, dm/gfx/README.md, dm/games/README.md | upstream, plus our sections (setup, game packs, RomFS chunk store, pso_user path in Hearth) | upstream's reference text is newer; per-game notes moved to dm/games/<id>/README.md upstream |
| dm/games/game.py | upstream, plus `json` (resolve / json_text / write_if_changed) built from header_one's macros | game.json now carries every key of upstream's header with upstream's validation and defaults, so new upstream profile keys flow in without edits here |
| dm/host/profile.h, profile.m, game_profile.h | ours, extended: struct holds every upstream DM_GAME_* key, DM_GAME_* macros read g_profile, game_profile.h includes profile.h | keeps one host for every game (game packs, Hearth) while upstream code that uses DM_GAME_* compiles unchanged; DM_PROFILE_SCHEMA 1 -> 2 (packs must be rebuilt) |
| profile keys feedback_snap, alpha_from_red, gpu_timestamps; render_cond / tex_*_upload `auto` | dropped (upstream) | upstream removed the first three since the fork point; `auto` and its [auto] counters (2257f44e, nvn_autostat.h) were a diagnostic no profile used |
| dm/games/tests/test_auto_defaults.py, test_gpu_timestamps_default.py | deleted | test keys that no longer exist |
| multi-program profiles (programs key, Super Mario 3D All-Stars) | not supported by game.json | the run-time profile holds one program; game.py json refuses such a profile with a reason |
| dm/host/Makefile | upstream, without GAME / game_profile.h; plus romstore.c profile.m boot.m, zstd, DEVCTL and the build stamp | one generic host; upstream's dav1d, MSL header, -O2 and frameworks taken |
| dm/host/hle.c, front_mac.m, hle_time.c, tests/t_time.c | upstream | hle_find hash; window title from DM_GAME_NAME; snapshot arithmetic superseded ours (time snapshot fix) |
| dm/host/hle.h, dm.h, front.h, hle_oe.c | union | our Home suspend reasons, capabilities, volume, notices/errors/user picker/album hooks next to upstream's applet focus, web, GPU-lost and program hand-off hooks |
| dm/host/hle_account.c | ours (Hearth user picker, per-user JPEG) + upstream DM_APPLET focus and its built-in 256x256 JPEG as the fallback | upstream found games decode the image unchecked (#1118): a user with no picture now gets the plain JPEG instead of a failure |
| dm/host/hle_err.c, hle_offline.c, hle_misc.c | ours (Hearth error dialog in hle_err.c, album in hle_album.c) + upstream DM_APPLET and the hooks we lacked (ShowNetworkServiceError, pdm play statistics, two album overloads, GetSharePostedLastUrl) | no duplicate hook symbols; upstream's hle_misc ShowError(Result) dropped in favour of hle_err.c's |
| dm/host/hle_fpslock.c | upstream; dm_fps_lock_present() now returns dm_fps_lock_engine() | upstream's engine limiters (NieR, Frostbite, Unity, Unreal) superset our build-row check |
| dm/host/hle_sdk16.c | upstream logic, runtime profile fields | display versions from g_profile; shared font choice keeps upstream's Decode import test |
| dm/host/main.c | upstream + ours | profile_modules (build_modules rows) reads g_profile; pack boot (dm_is_pack / dm_boot_game) and DM_PSO_PREBUILD=tool both kept; loading reads the rewriter tables folder |
| dm/host/loader.c | upstream + ours | upstream's NRO packing, back patch area, jit layout and dm_set_game_image_header taken; our code dylib (DM_CODE, pack code/<platform>.dylib, <dir>/code/macos.dylib) sets that image; the section path is compiled on the Mac too and falls back to upstream's file reader when a rewriter folder has no code dylib; dm_capability kept |
| dm/host/hle_svc.c | upstream | memory layout, map lock and system resource from upstream (DM_GAME_* now read g_profile) |
| dm/host/hle_audio.c | union | upstream's 6-to-2 downmix, watchdog mailbox and hold_device; our master volume gain applied after the downmix, and our per-reason suspend (Home) |
| dm/host/hle_hid.c | upstream + our DEVCTL poll | multiplayer pads, vibration routing and Palma stubs from upstream supersede ours |
| dm/host/hle_vibration.c, tests/t_vib.c, dm_input.h dm_vib_* | dropped (upstream) | superseded: upstream's hle_hid.c vibration + hle_haptics.c / haptics_apple.m (rumble mailbox) |
| dm/host/hle_thread.c | upstream | upstream rewrote the wait paths (handoffs, poll waits, sync objects, hitch detection); our per-address buckets with os_sync parking (4519e967, 4651bf15) and per-frame gate counts (477f749e) are not ported, see Decisions for the user |
| dm/host/tests/t_gate_stats.c, hle.c thr_tick_note | dropped | belonged to the gate counts above |
| dm/host/tests/Makefile | theirs + AnySwitch tail | Generic host: GAME_H points at the runtime profile header; tests that read the profile load GAME's game.json before main (PROFILE, t_profile_boot.m), so GAME= is required as upstream requires it; the memory tests force-include their synthetic memory_profile/game_profile.h; hle_fs tests link romstore.c + zstd; our t_err/t_account/t_album/t_devctl/t_romstore/profile-schema/pack-check in run_anyswitch, a prerequisite of run (one target has one recipe); t_vib, t_gate_stats removed with their features (superseded rumble mailbox, gate counts); t_sync, t_gate_cost not run (sync parking not ported) |
| dm/gfx/nvn/nvn_dirty.c, nvn_dirty.h | theirs | Upstream reworked the dirty tracker (slot mutex, sparse tiles, nvn_dirty_since_except); our page-run compare (9924efb5) was a perf tweak of the texture re-upload path that upstream replaced |
| dm/gfx/nvn/hle_nvn.c | theirs + ours (suspend reasons) | Upstream throughout (compact command records, NVN2 API, present interval, vpool); autostat key modes, record-time kick and gate stats dropped with their superseded features; device_api read at run time (if instead of #ifdef); per-reason graphics suspend (Home menu) kept on top of upstream's GL drain and archive save |
| dm/gfx/nvn/nvn_mtl.m | theirs, our features replayed | Built from upstream's file with our commits replayed 3-way: ambient letterbox (30658a50, hooked into upstream's present_encode_m4 through present_uv_slot), FSR sharp upscale (fa7dbff0, after upstream's MetalFX present upscale: FSR runs only where MetalFX did not scale), rounded present size (fd3664ae, into upstream's present_viewport), DM_INTERNAL_RES parsed and logged (39a5f80b). Dropped as superseded: RT heaps, flexible pipelines, binary archives, packed libraries (b2d85927 notice), GPU timing, autostat, page-run dirty compare, record-time kick. Internal resolution rendering (ccdac657, 89a8239d, 714a28ad, 352c3f3c, 8476e8e5, e4dca1f7) NOT ported: see Decisions for the user. Game profile hooks (594835d1) not needed: upstream reads DM_GAME_ID and the chain at run time already |
| dm/third_party/README.md | union | Upstream's list (dav1d) plus our FSR 1 port (nvn_upscale.h) in the outside-this-directory pieces (five) |
| dm/gfx/nvn/nvn_obj.h | theirs | Record-time kick (flexible pipelines) superseded; upstream's program prefetch/forget hooks |
| dm/gfx/nvn/nvn_refl.h | theirs | Upstream's binding fields; our rscale reflection fields (sidx/sfl/frag_coord) go with the unported internal-resolution renderer |
| dm/gfx/tex/nvn_deswizzle.c, tex/tests/t_tex.c | theirs | Linear-texture upload superseded by upstream (triage); upstream's pick test kept |
| dm/gfx/tests/.gitignore | theirs | Upstream ignores every t_* binary by pattern, which covers our tests |
| dm/gfx/tools/dmsh_chain.lock | theirs | Upstream's translator fingerprints (tool_lock.py); the chain version is upstream's |
| dm/gfx/tests/t_dirty_slots.c, t_mip_extent.m, t_refl.m, t_rt_range*.m | theirs | Tests follow upstream code (page-run and rscale reflection tests go with the dropped/unported features) |
| dm/gfx/tests/t_present_crop.m | theirs + ours | Upstream fixtures plus our mtl_letterbox_set(0) (the crop test pins black bars; t_present_ambient covers the fill) |
| dm/gfx/tests/Makefile | theirs + AnySwitch tail | Upstream rules; the profile comes from build/game.json (game.py json, loaded by t_profile_boot.m) instead of a generated header; our t_present_ambient, t_present_scale, t_pool_release, t_rscale kept; tests of superseded features removed (t_autostat, t_flexpso, t_pack, t_passgpu, t_psoarch, t_rtheap, t_rscale_gpu, test_flexarch/pack/psoarch/psoexpand/shader_split_zlib/chain_headers/pairs/rscale) |
| dm/gfx/vk/hle_vk.m, tests/t_clear_msaa.m, t_vk_dontcare.m, docs/agents/symptoms.md, docs/reference/rendering.md | theirs | Upstream 01de04fd and ced36121 had not come through the merge; restored from upstream |
| dm/gfx/tools/dmsh_build.py, dmsh_chain.py, shader_split.py | theirs | One chain for every game (dm/gfx/nvn/dmsh_chain.h) supersedes per-title headers; upstream GFPAK and tfxo stream scanning supersede our GFLXPACK/zlib split; rscale facts go with the unported internal resolution |
| dm/games/profile_guess.py | theirs | Upstream guesses (Unreal regions, nso loader errors) |
| .github/workflows/ci.yml | ours, trimmed | Upstream tests.yml supersedes our CI for the host and CPU gfx tests (the host run target now includes our tests); ci.yml keeps only AnySwitch-only checks (lint, our Python tests, dm/ios/tests) |
| scripts/compat_run.py (+ test), scripts/tests/test_pack_shaders.py, dm/gfx/tests/pso_flexbench.plist | deleted | Compat runner superseded by upstream smoke runs (dm/games/<id>/smoke.tsv); shader packs and flexible pipeline bench dropped with their features |
| dm/gfx/nvn/nvn_obj.h, nvn_refl.h/.m, tex/*, tests/t_nvn.c, t_pfv.m, t_mip_extent.m | theirs | Remnants of dropped features (packaged-texture snapshots da5cfb1d, rscale reflection, linear upload) removed: exactly upstream |
| dm/tools/patch_nso.py | theirs + ExeFS patches ported | Upstream rewriter; our community ExeFS patches (ef2ca9a9) re-applied on top |
| scripts/build_ipa_from_nsp.py | upstream's file, our commits replayed: ExeFS patches (ca133401), org.anyswitch bundle prefix (dde64110), generic host without GAME (b632a0fc), RomFS chunk-store notes (356bf559), runtime game.json via profile_json/DM_PROFILE_DIR for every Mac boot, mac_run and the Mac app (594835d1), Mac code dylib link_code (fe7d40fb), --pack (1914969c, refuses multi-program games) | our features on top of upstream's restructured builder (Mac platform, Xcode project, separate RomFS, region check, multi-program) |
| scripts/build_ipa_from_nsp.py | dropped --mac-only / MAC_ONLY, the DEVCTL Mac dev host, mac_run.json and record_pack (728457c7, c725bd23) | superseded by upstream's --platform mac / mac-app and its own run command; the compat runner that read mac_run.json is superseded too |
| dm/mac/pack_app.py | MODULE_FILES takes game.json, which mac_app writes beside the rewritten modules | our generic host reads the profile at boot (main.c falls back to game.json beside the modules); upstream's Mac app would not boot without it |
| dm/ios/tools/gen_build.py | upstream (iOS host_msl with MSL_SDK=iphoneos), without the game_profile make target | our generic host has no per-game header |
| dm/ios/tools/gen_embed.py | merged: our argparse form (--title, __dminfo, --dylib/--target code dylibs) plus upstream back patch area x2, packed NRO sections, --tag and --jit; tagged programs carry no __dminfo | both sides added features; one _dm_code_info per image avoids a duplicate symbol in a multi-program app |
| dm/ios/tools/pack_ipa.py | upstream; our --skip-list dropped | it only listed the loose libraries a shader pack replaced; upstream's packed shader library supersedes shader packs |
| dm/ios/project.yml | ours (Hearth sources, libAppleArchive, landscape only, UIRequiresFullScreen) plus upstream's Gen/Info.plist, UILaunchScreen and -mcpu=apple-m1; upstream's Swift launcher files excluded, no TV scene, no per-game Xcode settings/scheme, no stage_resources phase | Hearth is the iOS front end; upstream's per-game Xcode project (--prepare-xcode) and single-game launcher do not apply to it |
| dm/ios/Sources/main.m, front_ios.m, DmGamepad.m | ours (Hearth) plus the 59753a8 capture hand-over fix; rumble now through upstream haptics_apple.m | upstream rewrote these for its single-game app and SwiftUI launcher; Hearth replaces that front end |
| dm/ios/Sources/DmHaptics.* | rewritten as a thin adapter: Vibration -> dm_haptics_set_enabled, strength -> new dm_haptics_apple_set_gain; DmHapticMap.h and t_haptics.c removed | upstream's rumble (hle_haptics.c, haptics_apple.m) supersedes our vibration mailbox and Core Haptics player |
| dm/host/haptics_apple.[hm] | added dm_haptics_apple_set_gain (live gain) | keeps Hearth's live Vibration strength setting |
| dm/host/hle_hid.c, dm/ios/Sources/front_ios.m | upstream hle_hid.c; Hearth's front_ios.m defines front_ctrl_support returning -1 | Hearth has no controller-applet prompt yet (upstream's Mac front end has one): the applet cancels at once, as before the merge |
| dm/tools/romstore/* | chunk store builds from a RomFS image too (romstore_tool scan takes image ranges; romstore.py walk_image); test_romstore.py checks image and folder give the same store | upstream NSP extraction now writes RomFS.img, not a folder; our default IPA_ROMFS=store must keep working |
| .github/pull_request_template.md | dropped; ours (.github/PULL_REQUEST_TEMPLATE.md) kept | the two names are one file on macOS (case-insensitive), so both cannot live in one checkout; ours carries AnySwitch rules |
| dm/ios/tests (upstream test_aoc_startup, test_ipa_unsigned, test_orientation_policy, test_profile_pack, test_romfs_startup, test_xcode_workflow) | removed | they test upstream main.m / build_ipa.sh of the single-game app (RomFS and DLC locators, --prepare-xcode, DM_COPY_ROMFS=NO, launcher.json tables), which Hearth does not have |
| dm/ios/tests/test_build_defaults.py | flex-archive checks replaced by the offline pipeline archive and DM_PSO_BUNDLE checks | our flexible archives are superseded |
| dm/ios/tools/build_smoke.py | builds the Hearth project (Hearth sources, Gen/pack, --title), no resource staging | upstream CI runs it; it is also our no-game-data iOS build check |
| dm/host/boot.m, t_pack.m | pack pso/<platform> is DM_PSO_BUNDLE (pso_offline.py folder); DM_PSO_ARCHIVE / DM_PSO_FLEX_ARCHIVE defaults and for_this_gpu dropped | upstream DM_PSO_ARCHIVE now names the learned-archive folder; our flexible archives are superseded |
| dm/ios/tools/build_ipa.sh | ours (Hearth pack layout, chunk store, PACK, CODE_DYLIB) with upstream checks (shader_lib images, chain stamp, gl), nro.tsv and shader pair tables, jit image, offline pipeline archive (pso_offline.py), DMCommit/DMChain, DM_METAL_CAPTURE, DM_SHADER_FILES; --prepare-xcode, DM_COPY_ROMFS=NO and PROGRAMS_TSV refused; DM_ENTITLEMENTS opt-in | Hearth keeps one app for every game; superseded shader packs, pair scan, harvest and flexible archives dropped |
| dm/gfx/nvn/nvn_ambient.h | ambient GPU timing ticks via [g_dev queryTimestampFrequency] | our g_pg_ns lived in the passgpu block upstream replaced; same conversion as upstream's gpuprof |
| dm/host/hle_cheats.c | upstream file; display version lookup reads g_profile.versions at run time | our profile is runtime (game.json), the compile-time DM_GAME_DISPLAY_VERSIONS list does not exist |
| dm/gfx/tests/t_cpu_tex.m | upstream's #if DM_GAME_TEX_DIRTY_UPLOAD tests became a run-time check | same reason: the profile switch is a g_profile field |
| dm/host/main.c, dm/host/hle_oe.c | DM_GAME_MULTI paths left compiled out | multi-program apps are not ported (decision for the user) |
| dm/host/Makefile | host link adds -I. so ../gfx sources find dm/host/game_profile.h | upstream took it from gen/<GAME>/; ours lives in dm/host |
| dm/host/Makefile | an empty game_profile target | upstream's compile_check.py, lint_c.py and regress.py run `make game_profile`; there is nothing to generate in one generic host |
| dm/ios/Sources/front_ios.m | front_web_attach / front_web_detach, ported from upstream's front_ios.m onto DmGameVC | upstream's offline HTML pages (web_apple.m) need them; without them the app does not link |
| dm/ios/tools/compile_check.py | also compiles dm/ios/Hearth | the app builds Hearth (project.yml), and Sources imports its headers |
| dm/gfx/tests/t_pool_release.m, t_present_ambient.m, t_present_scale.m | g_mod as a pointer; present_encode_m4 given the slot's UV buffer and no scaler | upstream's module list and present signature |
| dm/gfx/tests/t_present_ambient.m | sets DM_NVN_PASSGPU=1 | upstream's pg_on times passes only when that is set (ours also with the performance overlay), so the ambient letterbox's GPU-time log line now needs it too |
| dm/host/tests/t_profile.m | bad fps_hold case is now 2 (out of 0..1), not 1 | game.json carries on/off keys as 0/1 after the merge (game.py emits upstream's header values), so 1 is valid |
| dm/host/tests/t_account.c | no-image checks expect upstream's built-in 670-byte JPEG | upstream's hle_account.c returns a plain JPEG instead of failing (their #1118: games decode it unchecked); upstream supersedes |
| dm/host/game_profile.h | each DM_GAME_* name defined only when not already defined | upstream's memory tests pin synthetic values (tests/memory_profile/game_profile.h, now -include'd); dm.h's quoted include always finds dm/host/game_profile.h first |
| dm/host/hle_svc.c | RESERVE and I_ProgramId use DM_GAME_MEM_RESERVE / DM_GAME_PROGRAM_ID, as upstream's file does | the direct g_profile reads bypassed the memory tests' pinned values |
| dm/host/tests: t_err.c, t_account.c, t_notify_sched.c, t_nro.c, t_symbols.c, t_resolution.c, t_audio_spsc.c | link stubs for symbols the other side added (dm_applet_enter/leave, dm_audio_suspend_for, dm_gfx_suspend_for, dm_err_show_result, dm_fps_lock_present, nvn_fps_high_now); pull() takes the device flag | upstream's DM_APPLET in hle_err/hle_account, our Home suspend and capabilities, and run-time profile reads reach code those unit tests link |
| dm/host/tests/t_fs.c | our section 7 (another user's save) sets DM_SAVE again first | upstream's new section 9 runs before it and points DM_SAVE at its own save |
| dm/host/tests/t_pack.m | the profile schema + 1 message is computed from DM_PROFILE_SCHEMA | the schema went 1 -> 2 in this merge |
| docs/development.md, docs/hearth-settings.md, CONTRIBUTING.md, docs/dev-control.md | pack pso/<platform> and DM_PSO_BUNDLE rows; vibration section describes upstream's rumble under Hearth's settings; host test commands take GAME=; "Building selected Mac shaders" back under "Build by hand (Mac)"; "Weekly re-sign" no longer splits the Disk hygiene list (that split predates the merge); new "Syncing with upstream" section | docs follow the merged code |
| .github/workflows/upstream-sync.yml | new: weekly and manual upstream check, one sync/upstream-<date> PR (clean merge or a conflict list), issue fallback when the default token may not push | keeps the fork in sync with only the default GITHUB_TOKEN |
| dm/games/<id>/settings.json (34 upstream-added profiles) | new Hearth per-game defaults: DM_FPS_TARGET from fps_target, DM_OPMODE 0 for op_mode handheld | our settings test requires the in-app defaults to match each profile; generated from the profiles, nothing else |
| README.md | names Xcode 27.2 for building | upstream's test_ci_toolchain checks the README names CI's Xcode; the shader chain lock pins its Metal compiler |
| dm/tools/tests/test_host_msl.py | the game_profile.h change case removed from the decoder-key test | our generic host compiles no profile; a header change is not a host input |
| .github/ISSUE_TEMPLATE/bug_report.yml, feature_request.yml | field labels What happened / What is missing (old wording moved to the description) | upstream's issue-areas workflow tells an issue's kind by these form headings |

## Hearth P3 merged on top

Branch `worktree-agent-a47f1a7e301912ec1` (Hearth P3: the Gallery, the Controllers page and keyboard play, import progress and the signing reminder, the VoiceOver fixes for full-screen layers, and 59753a8's hand-back of the controller when the game's screen is made) is what the iPad runs; it was merged into this branch after the upstream merge, as a merge commit of its own.
Every P3 feature is kept on top of upstream's code:

| File | Decision | Why |
| --- | --- | --- |
| dm/gfx/nvn/nvn_mtl.m | upstream's tex_desc, without P3's mip-level `return nil` | upstream (e72991d8) clamps a description with more levels than its size holds, the same case (Sword's 8x8 texture with 8 levels) |
| dm/gfx/tests/t_rtheap.m | stays deleted | the render-target heap test went with the upstream merge; P3 only added the mip-level case, which upstream's clamp now covers |
| dm/host/front_mac.m | upstream's front end (controller players, prompt, focus, fullscreen, Cheats menu, text box rules) with P3's key table: keymap.h rows and DM_MAP_KEY_*, modifier keys through flagsChanged, Space's shake only while no row uses it, and the UTF-8 text box info | keyboard play is one table for the Mac and iPadOS; upstream's Shift+arrow right stick is kept on top of the map's P ; L ' right stick |
| dm/host/Makefile | upstream's link line plus keymap.c / keymap.h | the Mac host's keyboard reads the shared table |
| dm/host/tests/Makefile | t_keymap added to the AnySwitch tail (run_anyswitch) | P3's key table test |
| dm/ios/Hearth/HearthLibrary.h | P3's HEARTH_IMPORTING with the split HEARTH_UID | both are needed; the split keeps docs_patches.py from reading the UID as a build ID |
| dm/ios/Sources/DmGamepad.m | P3's remappable read (DmControlMap) plus upstream's rumble routing to the controller in use | Controllers page remaps buttons by position; rumble follows the controller |
| dm/ios/tests/Makefile | P3's t_settings (DmControlMap, keymap), t_controls and t_notify; no t_haptics | t_haptics and DmHapticMap.h went with the upstream rumble (hle_haptics.c) |

## Decisions for the user

Each of these keeps AnySwitch's behaviour for now; none was decided here.

1. **Internal-resolution rendering** (`DM_INTERNAL_RES`; ccdac657, 89a8239d, 714a28ad, 352c3f3c, 8476e8e5, e4dca1f7) is not ported: upstream rewrote the renderer it hooked into. The switch is still parsed and logged, and the game draws at 1x. Port it onto upstream's renderer, or drop it?
2. **Wait paths**: our per-address buckets with `os_sync` parking (4519e967, 4651bf15) and the per-frame gate counts (477f749e) are not ported, since upstream rewrote `hle_thread.c`'s waits. Re-measure on upstream's version before porting anything back?
3. **Upstream's iOS front end is not in Hearth**: TV output, the backwards-compatibility device check screen, controller players and press-to-join, gyro routing, picture shape and portrait layouts, the in-game menu, the SwiftUI launcher and its cloud-save screen, the controller applet prompt (Hearth cancels the applet at once, as before), multi-program games (`PROGRAMS_TSV`), the per-game Xcode project (`--prepare-xcode`), a separately installed RomFS image (`DM_COPY_ROMFS=NO`) and the Increased Memory Limit entitlement by default (`DM_ENTITLEMENTS` stays opt-in). Which of these should Hearth gain?
4. **Hearth's "Flexible pipelines" toggle** (`DM_PSO_FLEX`) no longer does anything: upstream's pipeline handling superseded flexible pipelines, and the host stopped reading the switch. Remove the toggle (and its `t_settings.m` checks and docs row)?
5. **Vibration strength** stays a live Hearth setting through a new `dm_haptics_apple_set_gain`, on top of upstream's rumble; upstream's own launcher has its own rumble strength and cutoff settings. Keep Hearth's two settings, or adopt upstream's?
6. **Pokemon Sword's profile** is upstream's (it ported the game independently, 0045c1df): `pad_layout full`, `sys_resource 0`, and 2 shader groups instead of our 7 (ours only sped up partial shader rebuilds). Our `shader_facts_manual.tsv` (260 integer-output rows upstream lacks) is kept. Confirm on the iPad.
7. **Game packs must be rebuilt** (profile schema 2, upstream's chain version `bc8830d4ba5a`), and a pack's Mac shader libraries are absent when only an iOS build made them.

## Test results

Run on an M4 Mac (macOS 27, Xcode with the iPhoneOS 27.0 SDK), Pokemon Sword's profile (`GAME=0100ABF008968000`), heavy runs through `mac-heavy`.

| Suite | Command | Result |
| --- | --- | --- |
| Host unit tests | `make -k -C dm/host/tests GAME=0100ABF008968000 run` | 53 suites, 2573 checks, 0 failed (exit 0) |
| Metal (gfx) tests | `make -k -C dm/gfx/tests GAME=0100ABF008968000 run` | 163 suites, 75341 checks, 0 failed (exit 0) |
| iOS unit tests | `make -C dm/ios/tests run` | t_settings 740, t_library 87, t_import 49, t_home_focus 98, t_users 42, t_gallery 11 checks, 0 failed; DEVICE_GPU and BUILD_DEFAULTS OK |
| iOS compile check | `GAME=0100ABF008968000 python3 dm/ios/tools/compile_check.py` | 304 files, 0 failed |
| iOS device build | `GAME=0100ABF008968000 python3 dm/ios/tools/build_smoke.py` | BUILD SUCCEEDED (Release, generic iOS device, unsigned; not installed) |
| Python tests | `python -m unittest <file>` from the repo root, each file of dm/*/tests and scripts/tests, with lz4, capstone, fonttools, zstandard and spirv-val as upstream's CI installs | 183 files: 176 pass, 7 fail |

The 7 Python files that fail fail the same way on a clean checkout of upstream `a77c0ee8` on this Mac, so they are environmental, not this merge: test_coverage_report, test_dmsh_pool_arrays, test_nsp_mac_app, test_pfs0_storage, test_romfs_read, test_triage_report, test_usage (dotnet absent, the local Metal toolchain 32023.921 against the locked 32023.922, and `xcrun` not finding the iPhone SDK inside nix-shell).
Four of the 176 (test_device_gpu, test_gen_embed, test_pack_manifest, test_romstore) are scripts rather than unittest cases: `python -m unittest` reports "no tests ran" for them, and run directly they pass.

The shader chain header is current: `dmsh_chain.py` prints `bc8830d4ba5a`, as `dm/gfx/nvn/dmsh_chain.h` holds.

### After the Hearth P3 merge

| Suite | Result |
| --- | --- |
| Mac host build | builds (`make -C dm/host`) |
| Host unit tests | 54 suites, 2608 checks, 0 failed (t_keymap 35 checks included) |
| Metal (gfx) tests | 163 suites, 75341 checks, 1 failed: t_feedback's "with nothing running: a commit", a timing check in upstream's unchanged t_feedback.m (this merge changes nothing under dm/gfx); run alone 8 times it failed once |
| iOS unit tests | t_settings 2798, t_library 88, t_import 53, t_home_focus 98, t_users 42, t_gallery 16, t_controls 50, t_notify 10 checks, 0 failed; DEVICE_GPU and BUILD_DEFAULTS OK |
| iOS compile check | 310 files, 0 failed |
| iOS device build | BUILD SUCCEEDED (Release, generic iOS device, unsigned; not installed) |
