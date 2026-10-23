// The errors games asked Hearth to show (HearthErrors.h)
#import "HearthErrors.h"

static NSString *file(NSString *doc) { return [doc stringByAppendingPathComponent:@"Logs/errors.txt"]; }
static NSString *clean(NSString *s) {   // one field: no tab, no line break
    NSMutableCharacterSet *cut = [NSMutableCharacterSet newlineCharacterSet]; [cut addCharactersInString:@"\t"];
    return [[(s ?: @"") componentsSeparatedByCharactersInSet:cut] componentsJoinedByString:@" "];
}

NSString *hearth_error_message(NSString *code, BOOL network) {
    NSString *s = network ? @"Online features are not available in Hearth. The game can still be played offline."
                          : @"The game reported a problem. If it keeps happening, share the log from System Settings, About.";
    return code.length ? [NSString stringWithFormat:@"%@\n\nError code %@", s, code] : s;
}

void hearth_error_record(NSString *doc, NSString *titleId, NSString *name, NSString *code, BOOL network, NSDate *when) {
    NSString *line = [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\n", [[NSISO8601DateFormatter new] stringFromDate:when], clean(titleId), clean(name), clean(code), network ? @"online" : @""];
    NSString *p = file(doc);
    [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

NSArray<NSDictionary *> *hearth_error_history(NSString *doc, NSUInteger limit) {
    NSString *txt = [NSString stringWithContentsOfFile:file(doc) encoding:NSUTF8StringEncoding error:nil];
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new]; NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [[txt componentsSeparatedByString:@"\n"] reverseObjectEnumerator]) {
        if (out.count >= limit) break;
        NSArray<NSString *> *c = [l componentsSeparatedByString:@"\t"]; NSDate *d = c.count == 5 ? [f dateFromString:c[0]] : nil;
        if (!d) continue;   // a blank or damaged line
        [out addObject:@{@"when": d, @"titleId": c[1], @"name": c[2], @"code": c[3], @"network": @([c[4] isEqual:@"online"])}];
    }
    return out;
}
