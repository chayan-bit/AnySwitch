// The pack version contract (boot.m): a scratch pack with each number off by one in turn (pack format, profile schema, code ABI, shader ABI, the code dylib's own stamp), a missing part,
// a foreign title and a broken profile are each refused with the expected reason, and dm_pack_require exits with 78; the correct pack passes. Then the environment contract (dm_boot_env, dm_boot_game).
// The parts a caller may supply itself (DM_ROMFS, DM_CODE) and, built with EMBED_TITLE (t_pack_embedded), a pack without a code dylib booted from the code this executable embeds.
// Run: make -C dm/host/tests pack-check (t_pack <folder with a valid game.json> <its title id>)
#import <Foundation/Foundation.h>
#include <sys/wait.h>
#include "dm.h"
#include "dm_abi.h"
#include "boot.h"

#ifdef EMBED_TITLE   // the stamp gen_embed.py links into the per-game IPA's executable
#define STR_(x) #x
#define STR(x) STR_(x)
__attribute__((used, section("__DATA,__dminfo"))) static const char embedded_stamp[] = "code_abi " STR(DM_CODE_ABI) "\ntitle " EMBED_TITLE "\nmodule main 00\n";
#endif

static char root[1024], tmp[1024], profile[1024], title[17];
static int fails, n;

static void sh(const char *fmt, ...) {
    char cmd[4096]; va_list a; va_start(a, fmt); vsnprintf(cmd, sizeof cmd, fmt, a); va_end(a);
    if (system(cmd)) { printf("command failed: %s\n", cmd); exit(1); }
}
// A code dylib holding only the __dminfo stamp gen_embed.py writes
static void dylib(const char *out, int abi, const char *tid) {
    sh("printf '.section __DATA,__dminfo\\n.globl _dm_code_info\\n_dm_code_info:\\n.asciz \"code_abi %d\\\\ntitle %s\\\\nmodule main 00\\\\n\"\\n' > '%s/info.S' && "
       "xcrun clang -dynamiclib -arch arm64 -o '%s' '%s/info.S'", abi, tid, tmp, out, tmp);
}
static void manifest(int fmt, int schema, int code, int shader, const char *tid) {
    NSDictionary *m = @{@"format": @(fmt), @"title_id": @(tid), @"platforms": @[@"macos"], @"abi": @{@"profile_schema": @(schema), @"code": @(code), @"shader": @(shader)}};
    [[NSJSONSerialization dataWithJSONObject:m options:0 error:nil] writeToFile:[@(root) stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
}
static void valid_pack(void) {
    sh("rm -rf '%s' && mkdir -p '%s/profile' '%s/code' '%s/msl/macos' && cp '%s/game.json' '%s/profile/' && : > '%s/romfs.dmstore' && cp '%s/ok.dylib' '%s/code/macos.dylib'",
       root, root, root, root, profile, root, root, tmp, root);
    manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI, title);
}
static int require_status(void) {   // dm_pack_require in a child: its exit status
    fflush(stdout); pid_t p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); dm_pack_require(root); _exit(0); }
    int st; waitpid(p, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
static void expect(const char *name, const char *want) {   // want NULL: bootable
    char why[1024] = ""; n++;
    int rc = dm_pack_check(root, why, sizeof why), st = require_status();
    int ok = want ? rc == 1 && strstr(why, want) && st == DM_EXIT_PACK : rc == 0 && st == 0;
    if (!ok) fails++;
    printf("%s %s: rc %d, exit %d, \"%s\"\n", ok ? "✓" : "✗", name, rc, st, why);
}

// dm_boot_game's last step, recorded instead of loading anything
static int preload_argc; static char *preload_argv[2];
void dm_host_preload_start(int argc, char **argv) { preload_argc = argc; preload_argv[0] = argv[0]; preload_argv[1] = argv[1]; }

static const char *ENVS[] = {"DM_PROFILE_DIR", "DM_CODE", "DM_ROMFS", "DM_NVN_SHMAP", "DM_MSL_DIR", "DM_PSO_ARCHIVE", "DM_PSO_FLEX_ARCHIVE", "DM_FONT_DIR", "DM_AOC_DIR"};
static void check(const char *name, int ok, const char *detail) {
    n++; if (!ok) fails++;
    printf("%s %s%s%s\n", ok ? "✓" : "✗", name, detail ? ": " : "", detail ?: "");
}
static int env_is(const char *k, const char *rel) {   // rel NULL: unset; else <root>/<rel>
    const char *v = getenv(k); char want[1200];
    if (!rel) return !v;
    snprintf(want, sizeof want, "%s/%s", root, rel);
    return v && !strcmp(v, want);
}
// The environment contract: defaults only where the caller has not set a variable, absent optional parts counted (and named in the log), then dm_boot_game once per process
static void boot_cases(void) {
    for (size_t i = 0; i < sizeof ENVS / sizeof *ENVS; i++) unsetenv(ENVS[i]);
    valid_pack(); setenv("DM_ROMFS", "/caller/romfs.dmstore", 1);
    int missing = dm_boot_env(root);
    check("defaults: required parts", env_is("DM_PROFILE_DIR", "profile") && env_is("DM_CODE", "code/macos.dylib") && env_is("DM_NVN_SHMAP", "profile/shader_map.tsv") && env_is("DM_MSL_DIR", "msl/macos"), NULL);
    check("defaults: the caller's value wins", !strcmp(getenv("DM_ROMFS"), "/caller/romfs.dmstore"), getenv("DM_ROMFS"));
    check("defaults: 4 absent optional parts left unset", missing == 4 && env_is("DM_PSO_ARCHIVE", NULL) && env_is("DM_PSO_FLEX_ARCHIVE", NULL) && env_is("DM_FONT_DIR", NULL) && env_is("DM_AOC_DIR", NULL), NULL);
    for (size_t i = 0; i < sizeof ENVS / sizeof *ENVS; i++) unsetenv(ENVS[i]);
    sh("mkdir -p '%s/aoc/1' '%s/font' '%s/pso/macos' && : > '%s/pso/macos/pso_archive.metallib'", root, root, root, root);
    missing = dm_boot_env(root);
    check("defaults: present optional parts", missing == 1 && env_is("DM_ROMFS", "romfs.dmstore") && env_is("DM_AOC_DIR", "aoc") && env_is("DM_FONT_DIR", "font") && env_is("DM_PSO_ARCHIVE", "pso/macos/pso_archive.metallib") && env_is("DM_PSO_FLEX_ARCHIVE", NULL), NULL);
    for (size_t i = 0; i < sizeof ENVS / sizeof *ENVS; i++) unsetenv(ENVS[i]);
    manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI + 1, DM_SHADER_ABI, title);
    check("dm_boot_game refuses a stale pack and boots nothing", dm_boot_game(root) == 1 && !preload_argc && env_is("DM_CODE", NULL), NULL);
    manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI, title);
    check("dm_boot_game boots a good pack", dm_boot_game(root) == 0 && preload_argc == 2 && !strcmp(preload_argv[0], "dmhost") && !strcmp(preload_argv[1], root) && env_is("DM_CODE", "code/macos.dylib") && g_profile.id && !strcmp(g_profile.id, title), NULL);
    check("dm_boot_game runs once per process", dm_boot_game(root) == -1, NULL);
    check("dm_is_pack", dm_is_pack(root) && !dm_is_pack(tmp), NULL);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: t_pack <folder with game.json> <title id>\n"); return 2; }
    snprintf(profile, sizeof profile, "%s", argv[1]); snprintf(title, sizeof title, "%s", argv[2]);
    snprintf(tmp, sizeof tmp, "%s/t_pack.%d", getenv("TMPDIR") ?: "/tmp", getpid()); snprintf(root, sizeof root, "%s/pack", tmp);
    sh("mkdir -p '%s'", tmp);
    for (size_t i = 0; i < sizeof ENVS / sizeof *ENVS; i++) unsetenv(ENVS[i]);   // the caller's shell must not supply parts
    char p[1100];
    snprintf(p, sizeof p, "%s/ok.dylib", tmp); dylib(p, DM_CODE_ABI, title);
    snprintf(p, sizeof p, "%s/abi.dylib", tmp); dylib(p, DM_CODE_ABI + 1, title);
    snprintf(p, sizeof p, "%s/other.dylib", tmp); dylib(p, DM_CODE_ABI, "0100000000000000");

    valid_pack(); expect("correct pack", NULL);
    valid_pack(); manifest(DM_PACK_FORMAT + 1, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI, title); expect("pack format + 1", "pack format 2, this engine 1");
    valid_pack(); manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA + 1, DM_CODE_ABI, DM_SHADER_ABI, title); expect("profile schema + 1", "profile schema 2, this engine 1: re-run build_ipa_from_nsp.py --pack (profile)");
    valid_pack(); manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI + 1, DM_SHADER_ABI, title); expect("code ABI + 1", "code ABI 2, this engine 1: re-run build_ipa_from_nsp.py --pack (rewrite stage)");
    valid_pack(); manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI + 1, title); expect("shader ABI + 1", "shader ABI 2, this engine 1: re-run build_ipa_from_nsp.py --pack (shader stages)");
    valid_pack(); manifest(DM_PACK_FORMAT - 1, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI, title); expect("pack format - 1", "pack format 0, this engine 1");
    valid_pack(); sh("cp '%s/abi.dylib' '%s/code/macos.dylib'", tmp, root); expect("dylib code ABI + 1", "code/macos.dylib code ABI 2, this engine 1");
    valid_pack(); sh("cp '%s/other.dylib' '%s/code/macos.dylib'", tmp, root); expect("dylib of another title", "code/macos.dylib is for title 0100000000000000");
    valid_pack(); sh(": > '%s/code/macos.dylib'", root); expect("empty dylib", "has no __dminfo");
#ifdef EMBED_TITLE
    valid_pack(); sh("rm '%s/code/macos.dylib'", root); expect("no dylib: the code this executable embeds", NULL);
    for (size_t i = 0; i < sizeof ENVS / sizeof *ENVS; i++) unsetenv(ENVS[i]);
    setenv("DM_ROMFS", "/caller/romfs.dmstore", 1); dm_boot_env(root);
    check("defaults: no DM_CODE without a dylib (the loader maps this executable)", env_is("DM_CODE", NULL), NULL);
    unsetenv("DM_ROMFS");
    sh("rm -rf '%s'", tmp);
    printf("t_pack (embedded code): %d cases, %d failed\n", n, fails);
    return fails != 0;
#endif
    valid_pack(); sh("rm '%s/code/macos.dylib'", root); expect("no dylib, nothing embedded", "no code/macos.dylib (this platform's part) and this executable embeds no code");
    char other[1100]; snprintf(other, sizeof other, "%s/other.dylib", tmp);
    valid_pack(); setenv("DM_CODE", other, 1); expect("DM_CODE set by the caller is the code checked", "other.dylib is for title 0100000000000000"); unsetenv("DM_CODE");
    valid_pack(); sh("rm -r '%s/msl/macos'", root); expect("no shaders", "no msl/macos");
    valid_pack(); sh("rm '%s/romfs.dmstore'", root); expect("no RomFS store", "no romfs.dmstore");
    valid_pack(); sh("rm '%s/romfs.dmstore'", root); setenv("DM_ROMFS", "/caller/romfs.dmstore", 1); expect("no RomFS store, DM_ROMFS set by the caller", NULL); unsetenv("DM_ROMFS");
    valid_pack(); sh("rm '%s/manifest.json'", root); expect("no manifest", "no manifest.json");
    valid_pack(); manifest(DM_PACK_FORMAT, DM_PROFILE_SCHEMA, DM_CODE_ABI, DM_SHADER_ABI, "0100000000000000"); sh("cp '%s/other.dylib' '%s/code/macos.dylib'", tmp, root);
    expect("profile of another title", "profile/game.json is for title");
    valid_pack(); sh("sed -i '' 's/\"schema\": *[0-9]*/\"schema\": 999/' '%s/profile/game.json'", root); expect("broken profile", "profile: game.json schema 999");
    boot_cases();
    sh("rm -rf '%s'", tmp);
    printf("t_pack: %d cases, %d failed\n", n, fails);
    return fails != 0;
}
