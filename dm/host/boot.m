// Game pack check (boot.h): the pack's manifest.json against this engine's numbers (dm_abi.h), the code dylib's own __dminfo stamp, the profile, and the parts this platform boots from.
// Pack tree and manifest keys: docs/development.md "Game packs" (written by dm/tools/pack_manifest.py)
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <unistd.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include "dm.h"
#include "dm_abi.h"
#include "boot.h"

#define PLATFORM (TARGET_OS_IPHONE ? "ios" : "macos")
#define REBUILD "re-run build_ipa_from_nsp.py --pack"

static int fail(int reason, char *why, size_t n, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static int fail(int reason, char *why, size_t n, const char *fmt, ...) {   // reason: boot.h DM_PACK_*
    va_list a; va_start(a, fmt); vsnprintf(why, n, fmt, a); va_end(a);
    return reason;
}

static int whole(id v) {   // a JSON whole number, else -1
    if (![v isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID() || CFNumberIsFloatType((__bridge CFNumberRef)v)) return -1;
    return [v intValue];
}

// The __DATA,__dminfo text of a code dylib (gen_embed.py), read from the file: the check maps nothing. 1 = found
static int dylib_info(const char *path, char *out, size_t n) {
    int fd = open(path, O_RDONLY), found = 0;
    if (fd < 0) return 0;
    struct mach_header_64 h;
    uint8_t *lc = NULL;
    if (pread(fd, &h, sizeof h, 0) != sizeof h || h.magic != MH_MAGIC_64 || h.sizeofcmds > (1u << 24) || !(lc = malloc(h.sizeofcmds)) ||
        pread(fd, lc, h.sizeofcmds, sizeof h) != (ssize_t)h.sizeofcmds) goto out;
    for (uint32_t i = 0, o = 0; i < h.ncmds && !found; i++) {
        const struct load_command *c = (const void *)(lc + o);
        if (o + sizeof *c > h.sizeofcmds || c->cmdsize < sizeof *c || o + c->cmdsize > h.sizeofcmds) break;
        if (c->cmd == LC_SEGMENT_64 && c->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *s = (const void *)c;
            const struct section_64 *x = (const void *)(s + 1);
            for (uint32_t j = 0; j < s->nsects && (const uint8_t *)(x + j + 1) <= (const uint8_t *)c + c->cmdsize; j++) {
                if (strncmp(x[j].segname, "__DATA", 16) || strncmp(x[j].sectname, "__dminfo", 16)) continue;
                size_t z = x[j].size < n - 1 ? x[j].size : n - 1;
                found = pread(fd, out, z, x[j].offset) == (ssize_t)z;
                out[found ? z : 0] = 0;
                break;
            }
        }
        o += c->cmdsize;
    }
out:
    free(lc); close(fd);
    return found;
}

// The same stamp in this executable (the per-game IPA links the code in: gen_embed.py without --dylib). 1 = found
static int embedded_info(char *out, size_t n) {
    unsigned long z = 0;
    const uint8_t *d = getsectiondata(&_mh_execute_header, "__DATA", "__dminfo", &z);
    if (!d || !z) return 0;
    if (z > n - 1) z = n - 1;
    memcpy(out, d, z); out[z] = 0;
    return 1;
}

static int check(NSString *r, char *why, size_t n) {
    NSData *d = [NSData dataWithContentsOfFile:[r stringByAppendingPathComponent:@"manifest.json"]];
    if (!d) return fail(DM_PACK_NOT_PACK, why, n, "pack %s: no manifest.json, not a game pack: %s", r.UTF8String, REBUILD);
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![m isKindOfClass:NSDictionary.class]) return fail(DM_PACK_NOT_PACK, why, n, "pack %s: manifest.json is not a JSON object: %s", r.UTF8String, REBUILD);
    NSString *tid = m[@"title_id"];
    if (![tid isKindOfClass:NSString.class] || [tid rangeOfString:@"^[0-9A-F]{16}$" options:NSRegularExpressionSearch].location == NSNotFound)
        return fail(DM_PACK_NOT_PACK, why, n, "pack %s: manifest.json has no title_id (16 uppercase hex digits): %s", r.UTF8String, REBUILD);
    const char *id = tid.UTF8String;
    // The four numbers, the pack format first: it decides how the rest of the manifest reads
    int fmt = whole(m[@"format"]);
    if (fmt != DM_PACK_FORMAT) return fail(DM_PACK_REBUILD, why, n, "pack %s: pack format %d, this engine %d: %s", id, fmt, DM_PACK_FORMAT, REBUILD);
    NSDictionary *abi = m[@"abi"];
    if (![abi isKindOfClass:NSDictionary.class]) return fail(DM_PACK_REBUILD, why, n, "pack %s: manifest.json has no abi object: %s", id, REBUILD);
    static const struct { const char *key, *what, *stage; int want; } nums[] = {
        {"profile_schema", "profile schema", "profile", DM_PROFILE_SCHEMA}, {"code", "code ABI", "rewrite stage", DM_CODE_ABI}, {"shader", "shader ABI", "shader stages", DM_SHADER_ABI}};
    for (size_t i = 0; i < sizeof nums / sizeof *nums; i++) {
        int v = whole(abi[@(nums[i].key)]);
        if (v != nums[i].want) return fail(DM_PACK_REBUILD, why, n, "pack %s: %s %d, this engine %d: %s (%s)", id, nums[i].what, v, nums[i].want, REBUILD, nums[i].stage);
    }
    // This platform's parts. The game files: the pack's chunk store, or DM_ROMFS when the caller set it (the app's Documents/romfs.dmstore, installed beside an IPA)
    NSFileManager *fm = NSFileManager.defaultManager;
    char code[32], msl[32]; snprintf(code, sizeof code, "code/%s.dylib", PLATFORM); snprintf(msl, sizeof msl, "msl/%s", PLATFORM);
    const char *parts[] = {"profile/game.json", msl, getenv("DM_ROMFS") ? NULL : "romfs.dmstore"};
    for (size_t i = 0; i < sizeof parts / sizeof *parts; i++)
        if (parts[i] && ![fm fileExistsAtPath:[r stringByAppendingPathComponent:@(parts[i])]]) return fail(DM_PACK_MISSING, why, n, "pack %s: no %s (this platform's part): %s", id, parts[i], REBUILD);
    // The code and its own stamp (the manifest can go stale, the signed binary cannot): DM_CODE when the caller set it, else the pack's code/<platform>.dylib, else the code this
    // executable embeds (a pack bundled in the per-game IPA)
    char info[1024], cname[1100]; int cabi = -1; char ctitle[17] = "";
    NSString *cpath = getenv("DM_CODE") ? @(getenv("DM_CODE")) : [r stringByAppendingPathComponent:@(code)];
    snprintf(cname, sizeof cname, "%s", getenv("DM_CODE") ?: code);
    if (getenv("DM_CODE") || [fm fileExistsAtPath:cpath]) {
        if (!dylib_info(cpath.fileSystemRepresentation, info, sizeof info))
            return fail(DM_PACK_REBUILD, why, n, "pack %s: %s has no __dminfo, not a code dylib from gen_embed.py: %s (rewrite stage)", id, cname, REBUILD);
    } else if (embedded_info(info, sizeof info)) snprintf(cname, sizeof cname, "the code in this executable");
    else return fail(DM_PACK_REBUILD, why, n, "pack %s: no %s (this platform's part) and this executable embeds no code: %s", id, code, REBUILD);
    for (char *l = info; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) { sscanf(l, "code_abi %d", &cabi); sscanf(l, "title %16[0-9A-Fa-f]", ctitle); }
    if (cabi != DM_CODE_ABI) return fail(DM_PACK_REBUILD, why, n, "pack %s: %s code ABI %d, this engine %d: %s (rewrite stage)", id, cname, cabi, DM_CODE_ABI, REBUILD);
    if (strcasecmp(ctitle, id)) return fail(DM_PACK_REBUILD, why, n, "pack %s: %s is for title %s: %s", id, cname, ctitle, REBUILD);
    // The profile parses (every key checked) and is this title's
    struct dm_profile p = {0}; char pw[512];   // ponytail: the parsed strings are not freed (a few hundred bytes per check), free them if a menu ever checks packs in a loop
    if (dm_profile_parse([r stringByAppendingPathComponent:@"profile"].fileSystemRepresentation, &p, pw, sizeof pw)) return fail(DM_PACK_REBUILD, why, n, "pack %s: profile: %s: %s (profile)", id, pw, REBUILD);
    if (strcasecmp(p.id, id)) return fail(DM_PACK_REBUILD, why, n, "pack %s: profile/game.json is for title %s: %s", id, p.id, REBUILD);
    return 0;
}

int dm_is_pack(const char *dir) {
    char p[1024]; snprintf(p, sizeof p, "%s/manifest.json", dir);
    return !access(p, F_OK);
}

int dm_pack_check(const char *root, char *why, size_t n) {
    @autoreleasepool { return check(@(root), why, n); }
}

// The environment contract (docs/development.md "Game packs"): each default below applies only where the caller has not set the variable; optional parts that are absent are named in the log
int dm_boot_env(const char *root) {
    @autoreleasepool {
        NSString *r = @(root);
        NSString *code = [NSString stringWithFormat:@"code/%s.dylib", PLATFORM], *msl = [NSString stringWithFormat:@"msl/%s", PLATFORM], *pso = [NSString stringWithFormat:@"pso/%s", PLATFORM];
        static const int REQUIRED = 1, OPTIONAL = 0;
        struct { const char *env; NSString *rel; int required; const char *without; } d[] = {
            {"DM_PROFILE_DIR", @"profile", REQUIRED, NULL}, {"DM_CODE", code, OPTIONAL, "the code this executable embeds"}, {"DM_ROMFS", @"romfs.dmstore", REQUIRED, NULL},
            {"DM_NVN_SHMAP", @"profile/shader_map.tsv", REQUIRED, NULL}, {"DM_MSL_DIR", msl, REQUIRED, NULL},
            {"DM_PSO_ARCHIVE", [pso stringByAppendingPathComponent:@"pso_archive.metallib"], OPTIONAL, "pipelines compile on first use"},
            {"DM_PSO_FLEX_ARCHIVE", [pso stringByAppendingPathComponent:@"pso_flex.metallib"], OPTIONAL, "flexible pipelines compile on workers"},
            {"DM_FONT_DIR", @"font", OPTIONAL, "the system's shared-font stand-ins"}, {"DM_AOC_DIR", @"aoc", OPTIONAL, "no add-on content"}};
        int missing = 0;
        for (size_t i = 0; i < sizeof d / sizeof *d; i++) {
            if (getenv(d[i].env)) { LOG("pack: %s=%s (set by the caller)", d[i].env, getenv(d[i].env)); continue; }
            NSString *p = [r stringByAppendingPathComponent:d[i].rel];
            if (d[i].required || [NSFileManager.defaultManager fileExistsAtPath:p]) { setenv(d[i].env, p.fileSystemRepresentation, 0); continue; }
            LOG("pack: no %s: %s", d[i].rel.UTF8String, d[i].without); missing++;
        }
        return missing;
    }
}

int dm_boot_game(const char *root) {
    static _Atomic int booted;
    char why[1024];
    if (dm_pack_check(root, why, sizeof why)) { LOG("[RED] %s", why); return 1; }   // a refused pack leaves the process free to boot another
    if (atomic_exchange(&booted, 1)) { LOG("[RED] dm_boot_game runs once per process: %s ignored", root); return -1; }
    dm_boot_env(root);
    dm_profile_load(getenv("DM_PROFILE_DIR"));
    static char *argv[3]; argv[0] = "dmhost"; argv[1] = strdup(root);
    void dm_host_preload_start(int argc, char **argv);
    dm_host_preload_start(2, argv);
    return 0;
}

void dm_pack_require(const char *root) {
    char why[1024];
    if (!dm_pack_check(root, why, sizeof why)) return;
    LOG("[RED] %s", why);
    exit(DM_EXIT_PACK);
}
