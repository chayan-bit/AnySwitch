// Version contract between this engine and a game pack (dm/tools/pack_manifest.py writes the same numbers into the pack's manifest.json).
// Each number is bumped by hand in the commit that breaks compatibility; a pack whose number differs is refused before boot (boot.m dm_pack_check), naming what to rebuild.
#pragma once
#define DM_PACK_FORMAT 1      // the pack tree and the manifest.json keys (boot.m, dm/tools/pack_manifest.py)
#define DM_PROFILE_SCHEMA 1   // the keys and value types of profile/game.json (dm/games/game.py resolve, profile.m)
#define DM_CODE_ABI 1         // the rewritten-code image: gen_embed.py section layout, the fixups / gates / cuts / obs tables patch_nso.py writes, and the gate and key-page conventions loader.c expects
#define DM_SHADER_ABI 1       // what the host expects from the shader stages: reflection json and refl.bin format, shader pack index format, pipeline key size of the archives
