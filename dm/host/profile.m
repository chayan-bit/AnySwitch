// Game profile loader (profile.h): <dir>/game.json → struct dm_profile. Every key is checked for presence, type and range, and an unknown key is an error too:
// a profile written by another game.py version must fail here with its reason, not boot with a default the game never had.
#import <Foundation/Foundation.h>
#include "dm.h"
#include "dm_abi.h"

struct dm_profile g_profile;

// The parse state: the first error stops everything after it (later checks see err set and return defaults)
typedef struct { NSDictionary *j; NSMutableSet *seen; char *why; size_t n; int err; } pctx;
static void bad(pctx *c, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void bad(pctx *c, const char *fmt, ...) {
    if (c->err++) return;
    va_list a; va_start(a, fmt); vsnprintf(c->why, c->n, fmt, a); va_end(a);
}
static id get(pctx *c, const char *k, Class cls, int optional) {
    if (c->err) return nil;
    NSString *key = @(k); [c->seen addObject:key]; id v = c->j[key];
    if (!v) { if (!optional) bad(c, "game.json: missing key %s", k); return nil; }
    if (![v isKindOfClass:cls]) { bad(c, "game.json: %s has the wrong type", k); return nil; }
    return v;
}
static int is_bool(id v) { return [v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID(); }
static const char *str(pctx *c, const char *k) { NSString *v = get(c, k, NSString.class, 0); return v ? strdup(v.UTF8String) : ""; }
static uint64_t num(pctx *c, const char *k, uint64_t lo, uint64_t hi) {   // a whole number in [lo, hi]
    NSNumber *v = get(c, k, NSNumber.class, 0);
    if (!v) return 0;
    if (is_bool(v) || CFNumberIsFloatType((__bridge CFNumberRef)v) || v.longLongValue < 0 || v.unsignedLongLongValue < lo || v.unsignedLongLongValue > hi)
        { bad(c, "game.json: %s must be a whole number from %#llx to %#llx", k, (unsigned long long)lo, (unsigned long long)hi); return 0; }
    return v.unsignedLongLongValue;
}
static int matches(const char *s, const char *pattern) {   // the whole string matches
    return [@(s) rangeOfString:[NSString stringWithFormat:@"^(?:%s)$", pattern] options:NSRegularExpressionSearch].location != NSNotFound;
}
static const char *str_re(pctx *c, const char *k, const char *pattern) {
    const char *s = str(c, k);
    if (!c->err && !matches(s, pattern)) bad(c, "game.json: %s does not match %s: %s", k, pattern, s);
    return s;
}

// [[main build ID, value], ...] (display_versions: the display version; build_modules: that build's modules, space-separated), terminated by a zero pair
static const struct dm_profile_pair *pairs(pctx *c, const char *k, int *n) {
    NSArray *rows = get(c, k, NSArray.class, 0);
    struct dm_profile_pair *v = calloc(rows.count + 1, sizeof *v); *n = 0;
    for (NSArray *r in c->err ? @[] : rows) {
        if (![r isKindOfClass:NSArray.class] || r.count != 2 || ![r[0] isKindOfClass:NSString.class] || ![r[1] isKindOfClass:NSString.class])
            { bad(c, "game.json: %s holds [main build ID, value] pairs", k); break; }
        v[(*n)++] = (struct dm_profile_pair){strdup([r[0] UTF8String]), strdup([r[1] UTF8String])};
    }
    return v;
}

int dm_profile_parse(const char *dir, struct dm_profile *out, char *why, size_t n) {
    @autoreleasepool {
        NSString *path = [@(dir) stringByAppendingPathComponent:@"game.json"];
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (!d) { snprintf(why, n, "no game profile %s (write it with dm/games/game.py json <id> <dir>)", path.fileSystemRepresentation); return -1; }
        NSError *e = nil; id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
        if (![j isKindOfClass:NSDictionary.class]) { snprintf(why, n, "%s is not a JSON object: %s", path.fileSystemRepresentation, e ? e.localizedDescription.UTF8String : "wrong type"); return -1; }
        pctx c = {j, [NSMutableSet set], why, n, 0};
        struct dm_profile p = {0};
        uint64_t schema = num(&c, "schema", 0, 1u << 30);
        if (!c.err && schema != DM_PROFILE_SCHEMA) bad(&c, "game.json schema %llu, this engine reads %d: write it again with this tree's dm/games/game.py json", (unsigned long long)schema, DM_PROFILE_SCHEMA);
        p.id = str_re(&c, "id", "[0-9A-F]{16}");
        p.name = str(&c, "name");
        p.program_id = num(&c, "program_id", 1, UINT64_MAX);
        NSArray *mods = get(&c, "modules", NSArray.class, 0);
        if (!c.err && (mods.count < 1 || mods.count > DM_PROFILE_MAX_MOD)) bad(&c, "game.json: modules must name 1 to %d modules", DM_PROFILE_MAX_MOD);
        for (id m in c.err ? @[] : mods) {
            if (![m isKindOfClass:NSString.class] || !matches([m UTF8String], "\\w{1,15}")) { bad(&c, "game.json: a module name must be 1 to 15 letters, digits or _"); break; }
            p.modules[p.nmod++] = strdup([m UTF8String]);
        }
        p.build_modules = pairs(&c, "build_modules", &p.nbuild_modules);
        p.romfs_marker = str(&c, "romfs_marker");
        p.mem_reserve = num(&c, "mem_reserve", 1, UINT64_MAX >> 1);
        p.mem_alias = num(&c, "mem_alias", 1, UINT64_MAX >> 1);
        p.mem_stack = num(&c, "mem_stack", 1, UINT64_MAX >> 1);
        p.app_pool = num(&c, "app_pool", 1, UINT64_MAX >> 1);
        p.mem_used = num(&c, "mem_used", 0, UINT64_MAX >> 1);
        p.sys_resource = num(&c, "sys_resource", 0, UINT64_MAX >> 1);
        p.args = str(&c, "args");
        p.env = str(&c, "env");
        p.launch_param = str(&c, "launch_param");
        p.mem_map_limit = (int)num(&c, "mem_map_limit", 0, 1);
        p.stdalloc_cap = num(&c, "stdalloc_cap", 0, UINT64_MAX >> 1);
        p.screen_aspect = (int)num(&c, "screen_aspect", 0, 1);
        p.versions = pairs(&c, "display_versions", &p.nversions);
        p.present_display = (int)num(&c, "present_display", 0, 1);
        p.core_preempt = (int)num(&c, "core_preempt", 0, 1);
        p.alloc_big_align = (int)num(&c, "alloc_big_align", 0, 1);
        p.fps_target = (int)num(&c, "fps_target", 0, 60);
        if (!c.err && p.fps_target % 30) bad(&c, "game.json: fps_target must be 0, 30 or 60");
        p.fps_max = (int)num(&c, "fps_max", 60, 120);
        p.fps_hold = (int)num(&c, "fps_hold", 0, 1);
        p.ue_texture_pool = (int)num(&c, "ue_texture_pool", 0, 1 << 20);
        p.ue_fps_cvar = str_re(&c, "ue_fps_cvar", "[A-Za-z][A-Za-z0-9_.]{0,30}");
        p.present_snap = (int)num(&c, "present_snap", 0, 1);
        p.pso_mtl4 = (int)num(&c, "pso_mtl4", 0, 1);
        p.enc_thread = (int)num(&c, "enc_thread", 0, 1);
        p.pad_layout = (int)num(&c, "pad_layout", 0, 2);
        p.opmode = (int)num(&c, "opmode", 0, 1);
        p.perf_boost = (int)num(&c, "perf_boost", 0, 1);
        p.tex_flush_upload = (int)num(&c, "tex_flush_upload", 0, 1);
        p.shader_key_skip_off = (uint32_t)num(&c, "shader_key_skip_off", 0, 0x880);
        p.shader_key_skip_len = (uint32_t)num(&c, "shader_key_skip_len", 0, 0x880);
        p.render_cond = (int)num(&c, "render_cond", 0, 1);
        p.tex_dirty_upload = (int)num(&c, "tex_dirty_upload", 0, 1);
        p.tex_dyn_slots = (int)num(&c, "tex_dyn_slots", 0, 1);
        p.draw_barriers_game = (int)num(&c, "draw_barriers_game", 0, 1);
        p.upscaler_keys = str_re(&c, "upscaler_keys", "([0-9a-f]{16}(,[0-9a-f]{16})*)?");
        p.upscaler_n = (int)num(&c, "upscaler_n", 0, 4096);
        p.vconv_range = (int)num(&c, "vconv_range", 0, 1);
        p.chain = str_re(&c, "chain", "([0-9a-f]{6,16})?");
        p.shared_font_ttf = -1;
        NSNumber *sf = get(&c, "shared_font_ttf", NSNumber.class, 1);
        if (sf) p.shared_font_ttf = (int)num(&c, "shared_font_ttf", 0, 1);
        if (get(&c, "nvn_api_major", NSNumber.class, 1)) { p.nvn_api_major = (int)num(&c, "nvn_api_major", 1, 1000); p.nvn_api_minor = (int)num(&c, "nvn_api_minor", 0, 1000); }
        for (NSString *k in j) if (!c.err && ![c.seen containsObject:k]) bad(&c, "game.json: unknown key %s (written by another game.py version?)", k.UTF8String);
        if (c.err) return -1;   // ponytail: the strings of a refused profile are not freed (one parse per boot or per shell check)
        *out = p;
        return 0;
    }
}

void dm_profile_load(const char *dir) {
    char why[512];
    if (dm_profile_parse(dir, &g_profile, why, sizeof why)) die("[RED] game profile: %s", why);
    LOG("game profile %s (%s) from %s/game.json", g_profile.id, g_profile.name, dir);
}
