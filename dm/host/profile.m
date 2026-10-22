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
static int flag(pctx *c, const char *k) {
    NSNumber *v = get(c, k, NSNumber.class, 0);
    if (v && !is_bool(v)) bad(c, "game.json: %s must be true or false", k);
    return v.boolValue;
}
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
        p.program_id = strtoull(str_re(&c, "program_id", "[0-9A-F]{16}"), NULL, 16);
        NSArray *mods = get(&c, "modules", NSArray.class, 0);
        if (!c.err && (mods.count < 1 || mods.count > DM_PROFILE_MAX_MOD)) bad(&c, "game.json: modules must name 1 to %d modules", DM_PROFILE_MAX_MOD);
        for (id m in c.err ? @[] : mods) {
            if (![m isKindOfClass:NSString.class] || !matches([m UTF8String], "\\w{1,15}")) { bad(&c, "game.json: a module name must be 1 to 15 letters, digits or _"); break; }
            p.modules[p.nmod++] = strdup([m UTF8String]);
        }
        p.romfs_marker = str(&c, "romfs_marker");
        p.mem_reserve = num(&c, "mem_reserve", 1, UINT64_MAX >> 1);
        p.mem_alias = num(&c, "mem_alias", 1, UINT64_MAX >> 1);
        p.mem_stack = num(&c, "mem_stack", 1, UINT64_MAX >> 1);
        p.app_pool = num(&c, "app_pool", 1, UINT64_MAX >> 1);
        p.mem_used = num(&c, "mem_used", 0, UINT64_MAX >> 1);
        p.game_args = str(&c, "game_args");
        p.game_env = str(&c, "game_env");
        p.mem_map_limit = flag(&c, "mem_map_limit");
        NSArray *vers = get(&c, "display_versions", NSArray.class, 0);
        struct dm_profile_version *v = calloc(vers.count + 1, sizeof *v);
        for (NSArray *r in c.err ? @[] : vers) {
            if (![r isKindOfClass:NSArray.class] || r.count != 2 || ![r[0] isKindOfClass:NSString.class] || ![r[1] isKindOfClass:NSString.class])
                { bad(&c, "game.json: display_versions holds [main build ID, display version] pairs"); break; }
            v[p.nversions++] = (struct dm_profile_version){strdup([r[0] UTF8String]), strdup([r[1] UTF8String])};
        }
        p.versions = v;
        p.present_display = flag(&c, "present_display");
        p.core_preempt = flag(&c, "core_preempt");
        p.alloc_big_align = flag(&c, "alloc_big_align");
        p.fps_target = (int)num(&c, "fps_target", 0, 60);
        if (!c.err && p.fps_target % 30) bad(&c, "game.json: fps_target must be 0, 30 or 60");
        p.fps_hold = flag(&c, "fps_hold");
        p.pad_full = flag(&c, "pad_full");
        p.opmode_console = flag(&c, "opmode_console");
        p.perf_boost = flag(&c, "perf_boost");
        p.feedback_snap = str_re(&c, "feedback_snap", "([0-9a-f]{8,16}( [0-9a-f]{8,16})*)?");
        p.alpha_from_red = str_re(&c, "alpha_from_red", "([0-9a-f]{8,16}( [0-9a-f]{8,16})*)?");
        p.tex_flush_upload = (int)num(&c, "tex_flush_upload", 0, 2);
        p.render_cond = (int)num(&c, "render_cond", 0, 2);
        p.tex_dirty_upload = (int)num(&c, "tex_dirty_upload", 0, 2);
        p.tex_dyn_slots = flag(&c, "tex_dyn_slots");
        p.gpu_ts_segment = flag(&c, "gpu_ts_segment");
        p.vconv_range = flag(&c, "vconv_range");
        p.chain = str_re(&c, "chain", "([0-9a-f]{6,16})?");
        p.shared_font_ttf = -1;
        NSNumber *sf = get(&c, "shared_font_ttf", NSNumber.class, 1);
        if (sf && !is_bool(sf)) bad(&c, "game.json: shared_font_ttf must be true or false");
        else if (sf) p.shared_font_ttf = sf.boolValue;
        NSArray *api = get(&c, "nvn_api", NSArray.class, 1);
        if (api && (api.count != 2 || ![api[0] isKindOfClass:NSNumber.class] || ![api[1] isKindOfClass:NSNumber.class] || [api[0] intValue] <= 0 || [api[1] intValue] < 0))
            bad(&c, "game.json: nvn_api must be [major, minor]");
        else if (api) { p.nvn_api_major = [api[0] intValue]; p.nvn_api_minor = [api[1] intValue]; }
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
