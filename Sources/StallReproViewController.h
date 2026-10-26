#import <UIKit/UIKit.h>

/// Single-screen repro. Every AVAudioSession call is timed with
/// CACurrentMediaTime(), logged with NSLog and an os_signpost interval,
/// and appended to Documents/stall_repro.log.
@interface StallReproViewController : UIViewController
@end
