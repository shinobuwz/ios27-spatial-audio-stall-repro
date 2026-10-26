//
//  main.m
//  SpatialAudioStallRepro
//
//  Minimal reproduction for:
//  AVAudioSession calls take seconds when switching A2DP -> HFP while another
//  AudioUnit is playing, iOS 27.0.1, spatial audio + head tracking enabled.
//
//  No third-party SDK. AVFoundation only.
//

#import <UIKit/UIKit.h>
#import "StallReproViewController.h"

@interface StallReproAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation StallReproAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[StallReproViewController alloc] init];
    [self.window makeKeyAndVisible];
    // A run takes tens of seconds; keep the screen on so the system does not
    // suspend the app in the middle of a measurement.
    application.idleTimerDisabled = YES;
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([StallReproAppDelegate class]));
    }
}
