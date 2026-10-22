# Third-party code and credits

AnySwitch is released under the MIT License (see [LICENSE](LICENSE), kept as inherited from the projects below).
It stands on other people's work, and every component keeps its own license.
The license files sit next to the code they cover and must stay there.
[dm/third_party/README.md](dm/third_party/README.md) records, per component, the version, the local changes and where it is used.

## Lineage

| Project | License | What AnySwitch took |
|---|---|---|
| [seedds/nxnative](https://github.com/seedds/nxnative) | MIT | AnySwitch is a fork of it. The rewriter, the Horizon host, the NVN-on-Metal layer, the shader tools, the iOS app shell and the build scripts come from nxnative. Its history is kept and the `upstream` remote tracks it. |
| [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile) | MIT | The native-execution approach, developed for Diablo II: Resurrected. nxnative started as a copy of its generic parts. The copyright line in [LICENSE](LICENSE) is d2r-mobile's. |

## Code shipped in this repository

| Path | Component | License | License file |
|---|---|---|---|
| `dm/third_party/ryujinx/` | Ryujinx shader translator (`Ryujinx.Graphics.Shader`, `Ryujinx.Common`, `Spv.Generator`), with the local changes listed in its README | MIT | `dm/third_party/ryujinx/LICENSE.txt`, `dm/third_party/ryujinx/src/Spv.Generator/LICENSE` |
| `dm/third_party/libvpx/` | libvpx VP9 decoder | BSD 3-Clause, with a patent grant | `dm/third_party/libvpx/LICENSE`, `dm/third_party/libvpx/PATENTS` |
| `dm/third_party/stb_vorbis/` | stb_vorbis Ogg Vorbis decoder | MIT or public domain | `dm/third_party/stb_vorbis/LICENSE` |
| `dm/third_party/vulkan-headers/` | Khronos Vulkan headers | Apache-2.0 or MIT | `dm/third_party/vulkan-headers/LICENSE.md` |
| `dm/third_party/flip/` | NVIDIA FLIP image difference metric (verification only) | BSD 3-Clause | `dm/third_party/flip/LICENSE` |
| `dm/third_party/macnativegames/` | Code adapted from MacNativeGames: the GPU widening of 8-bit indices and the in-pass clear triangles in `dm/gfx/nvn/nvn_mtl.m` | MIT | `dm/third_party/macnativegames/LICENSE` |
| `dm/gfx/nvn/include/nvn.h` | NVN C header by h1k421 | MIT | the header of the file |
| `dm/gfx/nvn/nvn_tex.c` | Texture layout size algorithm ported from deko3d | zlib | the header of the file |
| `dm/gfx/nvn/nvn_upscale.h` | AMD FidelityFX Super Resolution 1 (EASU and RCAS from `ffx_fsr1.h` v1.20210629), ported to Metal from the copy Ryujinx vendors | MIT | the header of the file |

## References and tools (not shipped here)

These are used while building or consulted as references, and are not part of the repository.

- [Atmosphère](https://github.com/Atmosphere-NX/Atmosphere): its kernel, mesosphère, is the reference for Horizon's synchronization semantics.
- yuzu: Maxwell instruction encodings for the shader reference tool, and a cross-check for kernel behaviour.
- [LibHac](https://github.com/Thealexbarney/LibHac): reads NSPs and layers updates in `dm/tools/nx_extract`. hactool did the first extractions.
- [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross): SPIR-V to Metal Shading Language.
- Capstone, lz4, fontTools and XcodeGen are used by the build.

Nintendo, Switch and the names of the games are trademarks of their owners.
AnySwitch is not affiliated with or endorsed by Nintendo or any game publisher.
