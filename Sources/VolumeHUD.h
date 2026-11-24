#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

enum { VolumeLevelCount = 16 };

@interface VolumeHUD : NSObject
- (void)showLevel:(NSUInteger)level previousLevel:(NSUInteger)previousLevel onDisplay:(CGDirectDisplayID)display;
- (void)hide;
@end
