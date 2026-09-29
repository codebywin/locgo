#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#include <signal.h>
#include <execinfo.h>

static void writeCrashReport(NSString *report) {
    NSLog(@"[CRASH] %@", report);
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *docCrash = [paths.firstObject stringByAppendingPathComponent:@"crash.txt"];
        [report writeToFile:docCrash atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    
    [report writeToFile:@"/tmp/crash.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [report writeToFile:@"/var/tmp/crash.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [report writeToFile:@"/var/mobile/crash.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void uncaughtExceptionHandler(NSException *exception) {
    NSString *report = [NSString stringWithFormat:@"CRASH-EXCEPTION:\nName: %@\nReason: %@\nCallStack:\n%@",
                        exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    writeCrashReport(report);
}

void signalHandler(int sig) {
    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **strs = backtrace_symbols(callstack, frames);
    
    NSMutableString *stackStr = [NSMutableString string];
    for (int i = 0; i < frames; ++i) {
        [stackStr appendFormat:@"%s\n", strs[i]];
    }
    free(strs);
    
    NSString *report = [NSString stringWithFormat:@"CRASH-SIGNAL: %d\nCallStack:\n%@", sig, stackStr];
    writeCrashReport(report);
    
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char * argv[]) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
        signal(SIGABRT, signalHandler);
        signal(SIGSEGV, signalHandler);
        signal(SIGBUS, signalHandler);
        signal(SIGILL, signalHandler);
        signal(SIGFPE, signalHandler);
        
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
