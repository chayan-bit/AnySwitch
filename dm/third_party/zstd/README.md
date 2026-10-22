# zstd (Zstandard)

- Upstream: https://github.com/facebook/zstd, release tag `v1.5.7` (the release archive `v1.5.7.tar.gz`, taken through nixpkgs' `zstd.src`, NAR hash `sha256-tNFWIT9ydfozB8dWcmTMuZLCQmQudTFJIkSr0aG7S44=`).
- License: zstd is dual-licensed BSD or GPLv2; AnySwitch uses it under the BSD license in `LICENSE`.
- What is here: `lib/zstd.h`, `lib/zstd_errors.h`, and `lib/common`, `lib/decompress`, `lib/compress` unmodified, except that `lib/decompress/huf_decompress_amd64.S` (x86-64 only) is left out.
  The dictionary builder (`lib/dictBuilder`), `lib/legacy`, `lib/deprecated` and the command-line programs are not shipped.
- Where it is used:
  - The host's chunk store reader (`dm/host/romstore.c`) decompresses game data with `lib/common` and `lib/decompress`; `dm/host/Makefile` builds them into `gen/zstd/libzstd.a` with `ZSTD_DISABLE_ASM`, and the iOS build compiles the same files.
  - `lib/compress` is used only by the host unit test `dm/host/tests/t_romstore.c`, which writes a small synthetic store.
  - The store tool `dm/tools/romstore/romstore_tool.c` (scan and verify) links the same reader and decompressor.
  - The store builder `dm/tools/romstore/romstore.py` compresses with python-zstandard, which bundles its own copy of zstd.
