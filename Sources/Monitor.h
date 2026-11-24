#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the online RV200 Ultra selected as the default audio output, or zero.
CGDirectDisplayID MonitorSelectedDisplay(void);
CFTypeRef _Nullable MonitorOpen(void) CF_RETURNS_RETAINED;
BOOL MonitorRead(CFTypeRef service, uint16_t *value, uint16_t *maximum);
BOOL MonitorWrite(CFTypeRef service, uint16_t value);

NS_ASSUME_NONNULL_END
