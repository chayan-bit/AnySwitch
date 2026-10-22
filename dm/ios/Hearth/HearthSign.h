// Who signed a Mach-O file, read from the file itself (iOS has no SecStaticCode): the code signing identifier, the team, and a fingerprint of the signing certificates.
// Foundation and CommonCrypto only, so dm/ios/tests/t_library.m runs it on the Mac.
// Why it matters (notes/hearth-p2.md, E1): iPadOS loads a game's code from the data container only when it is signed by the identity that signed Hearth, with Hearth's bundle ID as its identifier.
#import <Foundation/Foundation.h>

@interface HearthSigner : NSObject
@property (nonatomic, copy) NSString *identifier;   // the CodeDirectory identifier
@property (nonatomic, copy) NSString *team;         // the CodeDirectory team ID, nil for ad hoc and platform code
@property (nonatomic, copy) NSString *certs;        // SHA-256 (hex) of the CMS certificate set, nil when the signature has none (ad hoc)
+ (instancetype)signerOf:(NSString *)path;          // nil: not a 64-bit arm64 Mach-O (thin or the arm64 slice of a fat file), or not signed
@end

// nil when code can load from the data container of the app that app signed: identifier equal to the bundle ID, same team, same certificates; else a short reason for the log
NSString *hearth_code_mismatch(HearthSigner *app, NSString *bundleId, HearthSigner *code);
