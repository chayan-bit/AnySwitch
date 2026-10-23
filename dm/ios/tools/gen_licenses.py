"""The licences of everything the app ships, as one text file (DmIOS.app/licenses.txt, shown by Hearth's About > Licences).
The list follows THIRD_PARTY.md's "Code shipped in this repository", limited to what is linked into the app (the shader translator, the Vulkan headers and FLIP are build or test tools).
Run: python3 dm/ios/tools/gen_licenses.py <repo root> <out file> (build_ipa.sh does)."""
import re
import sys
from pathlib import Path

# (component, path, how): "file" = the whole licence file, "block" = the file's leading /* */ comment, "notice" = the '//   ' lines after "Its notice:", a str = a credit line for a licence with no binary clause
COMPONENTS = [
    ('AnySwitch and the projects it comes from (nxnative, d2r-mobile)', 'LICENSE', 'file'),
    ('libvpx VP9 decoder', 'dm/third_party/libvpx/LICENSE', 'file'),
    ('libvpx patent grant', 'dm/third_party/libvpx/PATENTS', 'file'),
    ('Zstandard (zstd)', 'dm/third_party/zstd/LICENSE', 'file'),
    ('stb_vorbis', 'dm/third_party/stb_vorbis/LICENSE', 'file'),
    ('MacNativeGames', 'dm/third_party/macnativegames/LICENSE', 'file'),
    ('NVN C header by h1k421', 'dm/gfx/nvn/include/nvn.h', 'block'),
    ('AMD FidelityFX Super Resolution 1', 'dm/gfx/nvn/nvn_upscale.h', 'notice'),
    ('deko3d texture layout algorithm', 'dm/gfx/nvn/nvn_tex.c', 'The texture layout size algorithm is ported from deko3d, Copyright (C) 2018-2020 fincs, under the zlib license.'),
]


def licence_text(root, path, how):
    text = (Path(root) / path).read_text(encoding='utf-8')
    if how == 'file':
        return text.strip()
    if how == 'block':
        m = re.match(r'\s*/\*(.*?)\*/', text, re.S)
        if not m: raise SystemExit(f'{path}: no leading comment block')
        return '\n'.join(re.sub(r'^\s*\* ?', '', ln) for ln in m.group(1).strip().splitlines()).strip()
    if how == 'notice':
        out = []
        for ln in text.split('Its notice:', 1)[-1].splitlines()[1:]:
            if not ln.startswith('//   '): break
            out.append(ln[5:])
        if not out: raise SystemExit(f'{path}: no notice lines')
        return '\n'.join(out)
    (Path(root) / path).stat()   # a credit line: the file it credits must still be there
    return how


def render(root):
    parts = ['Hearth includes the following software. Each part keeps its own licence.']
    for name, path, how in COMPONENTS:
        parts.append(f'{name}\n{"=" * len(name)}\n\n{licence_text(root, path, how)}')
    return '\n\n\n'.join(parts) + '\n'


if __name__ == '__main__':
    if len(sys.argv) != 3: raise SystemExit(__doc__)
    Path(sys.argv[2]).write_text(render(sys.argv[1]), encoding='utf-8')
