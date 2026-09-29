#import <UIKit/UIKit.h>
#import "AppDelegate.h"

void uncaughtExceptionHandler(NSException *exception) {
    NSString *report = [NSString stringWithFormat:@"CRASH-EXCEPTION:\nName: %@\nReason: %@\nCallStack:\n%@",
                        exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    NSLog(@"%@", report);
    [report writeToFile:@"/var/mobile/Documents/crash.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [report writeToFile:@"/tmp/crash.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char * argv[]) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
