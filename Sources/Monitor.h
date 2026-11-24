#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the selected DisplayPort or HDMI audio device, or kAudioObjectUnknown.
AudioDeviceID MonitorSelectedOutput(void);

@interface MonitorConnection : NSObject
@property (nonatomic, readonly) AudioDeviceID output;
@property (nonatomic, readonly) CGDirectDisplayID display;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *volumeMemoryKey;

+ (nullable instancetype)connectToOutput:(AudioDeviceID)output
                                  reason:(NSString * _Nullable * _Nullable)reason;
- (BOOL)isCurrent;
- (BOOL)readVolume:(uint16_t *)value maximum:(uint16_t *)maximum;
- (BOOL)writeVolume:(uint16_t)value;
@end

NS_ASSUME_NONNULL_END
