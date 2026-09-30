#import <Foundation/Foundation.h>

static inline void ACBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[ACBFace] %@", msg);
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *timeStr = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timeStr, msg];
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *tempLog = [NSTemporaryDirectory() stringByAppendingPathComponent:@"acb_face.log"];
    NSArray *paths = @[tempLog, @"/tmp/acb_debug.log", @"/private/var/tmp/acb_face.log"];
    for (NSString *logPath in paths) {
        @try {
            if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
                [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:lineData];
                [handle closeFile];
            }
        } @catch (NSException *ex) {}
    }
}

