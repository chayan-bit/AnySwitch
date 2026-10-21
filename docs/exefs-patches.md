# ExeFS patches

The build can apply community ExeFS patches (60 FPS, resolution and quality mods) to any title.
It is generic: there is no per-title code, and the patch must exist for the exact build ID of the module.
Implementation: `dm/tools/exefs_patches.py` (parsers, matching, conflict rules) and the hook in `dm/tools/patch_nso.py`.
Tests: `python3 -I dm/tools/tests/test_exefs_patches.py` (needs `lz4` and `capstone` for the rewriter cases, for example `nix-shell -p 'python3.withPackages (p: [p.lz4 p.capstone])'`).

## Formats

- IPS: `PATCH` header, 24-bit offset, 16-bit size, RLE record when the size is 0 (16-bit count, one fill byte), `EOF` trailer.
- IPS32: `IPS32` header, 32-bit offsets, `EEOF` trailer.
- `.pchtxt` (IPSwitch): first line `@nsobid-<build ID>`, then `@enabled` / `@disabled` sections of `<hex offset> <hex bytes>` or `<hex offset> "string"` lines.
- `.pchtxt` details: `@flag offset_shift <n>` is added to every offset after it, `//` starts a comment, a blank line ends an `@enabled` section, `@stop` ends the file, other `@` lines are ignored.
- Disabled sections (and everything before the first `@enabled`) are not applied.
- The parsers are ported from Ryujinx (MIT, `IPSPatcher.cs`, `IPSwitchPatcher.cs`, `MemPatch.cs`) with attribution in the file header.

Offsets count the 0x100-byte NSO header, so the image offset is the file offset minus 0x100.
For `.pchtxt` the image offset is the written offset plus `offset_shift` minus 0x100, so module-relative addresses need `@flag offset_shift 0x100`.

## Matching

- An IPS file matches by its name: the text before the first dot is the build ID, compared with trailing zeros removed (Atmosphere names carry all 32 bytes).
- A `.pchtxt` file matches by its `@nsobid-` line, compared the same way.
- The module's build ID is the one printed in the rewrite log and written to `<module>.fixups.tsv`.
- Every module of the game (`main`, `subsdk0`, ...) is matched on its own, so one folder can hold patches for several modules.

## Use

Put the patches in a local folder, for example `data/patches/` (gitignored), in the Atmosphere layout `<name>/<build ID>.ips`.
Any depth works, the folder is walked recursively.
Patch files are never fetched by the build and never belong in the repository.
Most community patch repositories carry no license, so keep them in your own clone.

```
python3 scripts/build_ipa_from_nsp.py ~/Games/Title -k ~/keys/prod.keys --exefs-patches data/patches
```

The `EXEFS_PATCHES` setting at the top of the script does the same (the option wins).
Without either, nothing changes: builds, cache keys and output are as before.
The build prints one line per applied file, for example `exefs patch 60fps/<build ID>.ips: main build <build ID>, 3 records, 12 bytes`, or says that no patch matches a module.
Each module also gets `<module>.exefs_patches.tsv` beside the other rewriter tables, listing the files and every record's image offset and length.
The rewrite is cached by the patch files' content, so editing a patch rebuilds.

## Order and conflict rules

1. Registered cuts (`CUTS` in `patch_nso.py`) are applied first and asserted against their original bytes.
2. The community patches are applied next, then the rewriter scans the patched image.
3. The rewriter therefore sees every patched word: an `x18` use, `svc`, `mrs`/`msr` of `tpidr_el0` or `tpidrro_el0`, or a counter read that a patch writes is rewritten like the game's own.
   The test builds the same bytes into an NSO and checks the output is identical.

The build stops with an error (nothing is skipped silently) when:
- a record starts inside the 0x100-byte NSO header or ends past the data segment;
- a record overlaps a registered cut or an observation gate of the same build;
- two records, from the same or different files, overlap and write different bytes (identical overlaps are fine);
- a malformed IPS or `.pchtxt` file matches the module (truncated record, bad hex, bad offset);
- a patched word reads as a rewrite site (`x18`, `svc`, system register) but lies where the rewriter does not sweep, that is in the read-only or data segment or in a data block of the text, because it would run unrewritten on the host.

Frame-step stubs (`FRAME_STEP`) assert their original instructions, so a patch that changes those words aborts the build there.

## Frame-rate patches can change game speed

A 60 FPS patch usually changes the frame limiter or vsync interval and leaves the game's time step alone.
Games that step logic per frame then run at double speed.
The audit reports exactly this for the community 60 FPS patch for Pokemon Sword and Shield 1.3.2 ([perf-audit.md](perf-audit.md), section 2.2).
Treat every patch as unverified on a new title: check game speed, audio, animations and cutscenes on the device before relying on it.
Correct 60 FPS for such a title needs a per-build frame-step stub, as done for Breath of the Wild and Tears of the Kingdom.
Resolution and quality patches can raise GPU cost or break effects, so validate those the same way.
