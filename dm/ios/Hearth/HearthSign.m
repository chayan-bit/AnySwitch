// Code signature reader (HearthSign.h): LC_CODE_SIGNATURE -> SuperBlob -> CodeDirectory (identifier, team) and the CMS blob (certificate set)
#import "HearthSign.h"
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <fcntl.h>
#include <unistd.h>

enum { CS_SUPERBLOB = 0xfade0cc0, CS_CODEDIRECTORY = 0xfade0c02, CS_CMS = 0xfade0b01, SLOT_CODEDIRECTORY = 0, SLOT_CMS = 0x10000, MAX_SIG = 16 << 20 };
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// The total size of the BER element at p (header, content, and the end marker of an indefinite length, which Apple's CMS signatures use); 0 when malformed
static size_t ber_size(const uint8_t *p, const uint8_t *end, int depth) {
    if (depth > 32 || end - p < 2) return 0;
    size_t len = p[1], h = 2;
    if (len == 0x80) {
        const uint8_t *q = p + 2;
        while (end - q >= 2 && (q[0] || q[1])) { size_t n = ber_size(q, end, depth + 1); if (!n) return 0; q += n; }
        return end - q >= 2 ? (size_t)(q + 2 - p) : 0;
    }
    if (len & 0x80) {
        int k = len & 0x7f; if (k > 4 || end - p < 2 + k) return 0;
        len = 0; for (int i = 0; i < k; i++) len = len << 8 | p[2 + i];
        h += (size_t)k;
    }
    return (size_t)(end - p) >= h + len ? h + len : 0;
}
static const uint8_t *ber_enter(const uint8_t *p, const uint8_t *end) {   // the first element inside a constructed one
    if (!p || end - p < 2) return NULL;
    size_t h = 2 + (p[1] > 0x80 ? (size_t)(p[1] & 0x7f) : 0);
    return p + h < end ? p + h : NULL;
}
static const uint8_t *ber_next(const uint8_t *p, const uint8_t *end) { size_t n = p ? ber_size(p, end, 0) : 0; return n && p + n < end ? p + n : NULL; }

// ContentInfo { contentType, [0] SignedData { version, digestAlgorithms, encapContentInfo, [0] certificates, ... } }: the SHA-256 of the certificates element
static NSString *certs_hash(const uint8_t *p, const uint8_t *end) {
    if (end - p < 2 || p[0] != 0x30) return nil;
    const uint8_t *q = ber_enter(p, end);                  // contentType
    if (!q || *q != 0x06 || !(q = ber_next(q, end)) || *q != 0xA0) return nil;
    if (!(q = ber_enter(q, end)) || *q != 0x30 || !(q = ber_enter(q, end))) return nil;   // SignedData, its version
    for (int i = 0; i < 3 && q; i++) q = ber_next(q, end);   // past version, digestAlgorithms, encapContentInfo
    size_t n = q && *q == 0xA0 ? ber_size(q, end, 0) : 0;
    if (!n) return nil;
    uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(q, (CC_LONG)n, d);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

static void read_blobs(HearthSigner *s, const uint8_t *sig, uint32_t size) {
    if (size < 12 || be32(sig) != CS_SUPERBLOB) return;
    uint32_t count = be32(sig + 8);
    for (uint32_t i = 0; i < count && 12 + (i + 1) * 8 <= size; i++) {
        uint32_t type = be32(sig + 12 + i * 8), off = be32(sig + 16 + i * 8);
        if (off > size - 8) continue;
        const uint8_t *b = sig + off; uint32_t len = be32(b + 4);
        if (len < 8 || len > size - off) continue;
        if (type == SLOT_CODEDIRECTORY && be32(b) == CS_CODEDIRECTORY && len >= 52) {
            uint32_t version = be32(b + 8), ident = be32(b + 20), team = version >= 0x20200 ? be32(b + 48) : 0;
            if (ident && ident < len) s.identifier = [[NSString alloc] initWithBytes:b + ident length:strnlen((const char *)b + ident, len - ident) encoding:NSUTF8StringEncoding];
            if (team && team < len) s.team = [[NSString alloc] initWithBytes:b + team length:strnlen((const char *)b + team, len - team) encoding:NSUTF8StringEncoding];
        } else if (type == SLOT_CMS && be32(b) == CS_CMS) s.certs = certs_hash(b + 8, b + len);
    }
}

@implementation HearthSigner
+ (instancetype)signerOf:(NSString *)path {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    HearthSigner *s = nil; uint8_t *lc = NULL, *sig = NULL, head[1024]; off_t base = 0;
    ssize_t got = pread(fd, head, sizeof head, 0);
    if (got >= 8 && be32(head) == FAT_MAGIC) {   // a fat file: its arm64 slice
        uint32_t n = be32(head + 4); base = -1;
        for (uint32_t i = 0; i < n && 8 + (i + 1) * 20 <= (uint32_t)got; i++)
            if ((int32_t)be32(head + 8 + i * 20) == CPU_TYPE_ARM64) { base = be32(head + 16 + i * 20); break; }
        if (base < 0) goto out;
    }
    struct mach_header_64 h;
    if (pread(fd, &h, sizeof h, base) != sizeof h || h.magic != MH_MAGIC_64 || h.sizeofcmds > (1u << 24) || !(lc = malloc(h.sizeofcmds)) ||
        pread(fd, lc, h.sizeofcmds, base + (off_t)sizeof h) != (ssize_t)h.sizeofcmds) goto out;
    for (uint32_t i = 0, o = 0; i < h.ncmds; i++) {
        const struct load_command *c = (const void *)(lc + o);
        if (o + sizeof *c > h.sizeofcmds || c->cmdsize < sizeof *c || o + c->cmdsize > h.sizeofcmds) break;
        if (c->cmd == LC_CODE_SIGNATURE && c->cmdsize >= sizeof(struct linkedit_data_command)) {
            const struct linkedit_data_command *l = (const void *)c;
            if (l->datasize > MAX_SIG || !(sig = malloc(l->datasize)) || pread(fd, sig, l->datasize, base + l->dataoff) != (ssize_t)l->datasize) break;
            HearthSigner *r = [HearthSigner new]; read_blobs(r, sig, l->datasize);
            if (r.identifier) s = r;
            break;
        }
        o += c->cmdsize;
    }
out:
    free(lc); free(sig); close(fd);
    return s;
}
@end

NSString *hearth_code_mismatch(HearthSigner *app, NSString *bundleId, HearthSigner *code) {
    if (!code) return @"the code is not signed";
    if (!app) return @"this app's own signature cannot be read";
    if (![code.identifier isEqualToString:bundleId]) return [NSString stringWithFormat:@"the code is signed as %@, not as this app (%@)", code.identifier, bundleId];
    if (!code.team || ![code.team isEqualToString:app.team]) return [NSString stringWithFormat:@"the code is signed by team %@, this app by %@", code.team ?: @"none", app.team ?: @"none"];
    if (!code.certs || ![code.certs isEqualToString:app.certs]) return @"the code is signed with another certificate than this app";
    return nil;
}
