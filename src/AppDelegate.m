#import "AppDelegate.h"
#import "CardInputViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.10 alpha:1.0];
    
    CardInputViewController *inputVC = [[CardInputViewController alloc] init];
    self.window.rootViewController = inputVC;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
