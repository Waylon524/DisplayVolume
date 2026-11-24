#import "Monitor.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <unistd.h>

NS_ASSUME_NONNULL_BEGIN

// DDC/CI framing and Apple Silicon transport adapted from m1ddc (MIT).
// See ThirdPartyNotices.txt.
static const uint8_t SpeakerVolume = 0x62;
static const uint32_t Chip = 0x37;
static const uint32_t Host = 0x51;
enum { MaximumOnlineDisplays = 32 };

typedef CFTypeRef _Nullable (*AVOpen)(CFAllocatorRef _Nullable, io_service_t);
typedef IOReturn (*AVTransfer)(CFTypeRef _Nonnull, uint32_t, uint32_t, void * _Nonnull, uint32_t);

static AVOpen _Nullable openAV;
static AVTransfer _Nullable readAV, writeAV;

static BOOL loadTransport(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        openAV = (AVOpen)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        readAV = (AVTransfer)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        writeAV = (AVTransfer)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    });
    return openAV && readAV && writeAV;
}

static OSStatus audioProperty(AudioObjectID device, AudioObjectPropertySelector selector,
                              uint32_t size, void *value) {
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, value);
}

static BOOL isDisplayAudio(AudioDeviceID device) {
    UInt32 transport = 0;
    return device != kAudioObjectUnknown &&
           audioProperty(device, kAudioDevicePropertyTransportType, sizeof(transport), &transport) == noErr &&
           (transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI);
}

AudioDeviceID MonitorSelectedOutput(void) {
    AudioDeviceID output = kAudioObjectUnknown;
    if (audioProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                      sizeof(output), &output) != noErr || !isDisplayAudio(output)) {
        return kAudioObjectUnknown;
    }
    return output;
}

static NSString * _Nullable audioString(AudioDeviceID output, AudioObjectPropertySelector selector) {
    CFStringRef result = NULL;
    if (audioProperty(output, selector, sizeof(result), &result) != noErr) return nil;
    return CFBridgingRelease(result);
}

static NSString * _Nullable nameKey(NSString * _Nullable name) {
    NSArray<NSString *> *words = [name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words componentsJoinedByString:@""] stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch
                                                                    locale:nil];
}

static void countDisplayAudioOutputs(NSString *selectedName, NSUInteger *total, NSUInteger *sameName) {
    *total = 0;
    *sameName = 0;
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || !size) return;

    NSMutableData *storage = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, storage.mutableBytes) != noErr) return;
    const AudioDeviceID *devices = storage.bytes;
    for (NSUInteger i = 0; i < size / sizeof(*devices); i++) {
        if (!isDisplayAudio(devices[i])) continue;
        (*total)++;
        if ([nameKey(audioString(devices[i], kAudioObjectPropertyName)) isEqualToString:selectedName]) (*sameName)++;
    }
}

typedef struct {
    CGDirectDisplayID id;
    uint32_t vendor;
    uint32_t model;
    uint32_t serial;
} DisplayIdentity;

static BOOL validEDID(const uint8_t *edid) {
    const uint8_t header[] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
    if (memcmp(edid, header, sizeof(header)) != 0) return NO;
    uint8_t sum = 0;
    for (int i = 0; i < 128; i++) sum += edid[i];
    return sum == 0;
}

static NSString * _Nullable edidProductName(const uint8_t *edid) {
    for (NSUInteger offset = 54; offset <= 108; offset += 18) {
        const uint8_t *descriptor = edid + offset;
        if (descriptor[0] || descriptor[1] || descriptor[2] || descriptor[3] != 0xfc) continue;
        const uint8_t *name = descriptor + 5;
        NSUInteger length = 0;
        while (length < 13 && name[length] && name[length] != '\n') length++;
        return [[NSString alloc] initWithBytes:name length:length encoding:NSASCIIStringEncoding];
    }
    return nil;
}

static CGDirectDisplayID matchEDID(const uint8_t *edid, const DisplayIdentity *displays, NSUInteger count) {
    uint32_t vendor = (edid[8] << 8) | edid[9];
    uint32_t model = edid[10] | (edid[11] << 8);
    uint32_t serial = edid[12] | (edid[13] << 8) | (edid[14] << 16) | ((uint32_t)edid[15] << 24);
    CGDirectDisplayID exact = kCGNullDirectDisplay, partial = kCGNullDirectDisplay;
    NSUInteger exactCount = 0, partialCount = 0;
    for (NSUInteger index = 0; index < count; index++) {
        const DisplayIdentity entry = displays[index];
        if (entry.vendor != vendor || entry.model != model) continue;
        if (entry.serial && serial) {
            if (entry.serial == serial) {
                exact = entry.id;
                exactCount++;
            }
        } else {
            partial = entry.id;
            partialCount++;
        }
    }
    if (exactCount == 1) return exact;
    return exactCount == 0 && partialCount == 1 ? partial : kCGNullDirectDisplay;
}

static NSUInteger onlineDisplays(DisplayIdentity *displays) {
    CGDirectDisplayID identifiers[MaximumOnlineDisplays];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(MaximumOnlineDisplays, identifiers, &count) != kCGErrorSuccess ||
        count == MaximumOnlineDisplays) return 0;
    NSUInteger externalCount = 0;
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID display = identifiers[index];
        if (CGDisplayIsBuiltin(display)) continue;
        displays[externalCount++] = (DisplayIdentity){
            display, CGDisplayVendorNumber(display), CGDisplayModelNumber(display), CGDisplaySerialNumber(display)
        };
    }
    return externalCount;
}

static NSUInteger matchingScreens(NSString *audioName, CGDirectDisplayID *display) {
    NSUInteger count = 0;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID identifier = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (!identifier || CGDisplayIsBuiltin(identifier) ||
            ![nameKey(screen.localizedName) isEqualToString:audioName]) continue;
        *display = identifier;
        count++;
    }
    return count;
}

static uint8_t checksum(uint8_t seed, const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) seed ^= bytes[i];
    return seed;
}

@implementation MonitorConnection {
    id _service;
}

+ (nullable instancetype)connectToOutput:(AudioDeviceID)output
                                  reason:(NSString * _Nullable * _Nullable)reason {
    if (reason) *reason = nil;
    NSString *name = audioString(output, kAudioObjectPropertyName);
    NSString *key = nameKey(name);
    if (!key.length || output != MonitorSelectedOutput() || !loadTransport()) {
        if (reason) *reason = @"The selected display audio output or Apple silicon DDC transport is unavailable.";
        return nil;
    }

    DisplayIdentity displays[MaximumOnlineDisplays];
    NSUInteger count = onlineDisplays(displays);
    NSUInteger audioCount = 0, sameNameCount = 0;
    countDisplayAudioOutputs(key, &audioCount, &sameNameCount);
    CGDirectDisplayID namedDisplay = kCGNullDirectDisplay;
    if (sameNameCount != 1 || matchingScreens(key, &namedDisplay) > 1) {
        if (reason) *reason = @"The selected sound output does not identify a unique external display.";
        return nil;
    }
    BOOL soleDisplay = count == 1 && audioCount == 1;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (!count || IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                              &iterator) != KERN_SUCCESS) {
        if (reason) *reason = @"No online external display with an accessible DDC/CI transport was found.";
        return nil;
    }

    id matched = nil;
    CGDirectDisplayID matchedDisplay = kCGNullDirectDisplay;
    io_service_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(entry, CFSTR("Location"),
                                                            kCFAllocatorDefault, 0);
        BOOL external = location && CFEqual(location, CFSTR("External"));
        if (location) CFRelease(location);
        CFTypeRef service = external ? openAV(kCFAllocatorDefault, entry) : NULL;
        IOObjectRelease(entry);
        if (!service) continue;

        uint8_t edid[128] = {0};
        CGDirectDisplayID display = kCGNullDirectDisplay;
        if (readAV(service, 0x50, 0, edid, sizeof(edid)) == kIOReturnSuccess && validEDID(edid)) {
            display = matchEDID(edid, displays, count);
        }
        BOOL matches = display && (namedDisplay ? display == namedDisplay :
                                   soleDisplay || [nameKey(edidProductName(edid)) isEqualToString:key]);
        id ownedService = CFBridgingRelease(service);
        if (!matches) continue;
        if (matched) {
            matched = nil;
            if (reason) *reason = @"Multiple DDC/CI endpoints match the selected display.";
            break;
        }
        matched = ownedService;
        matchedDisplay = display;
    }
    IOObjectRelease(iterator);
    if (!matched || output != MonitorSelectedOutput() || !CGDisplayIsOnline(matchedDisplay)) {
        if (reason && !*reason) *reason = @"The selected audio output could not be matched to an external display with DDC/CI.";
        return nil;
    }

    MonitorConnection *connection = [self new];
    connection->_service = matched;
    connection->_output = output;
    connection->_display = matchedDisplay;
    connection->_name = [name copy];
    connection->_volumeMemoryKey = [audioString(output, kAudioDevicePropertyDeviceUID) copy] ?:
                                  [NSString stringWithFormat:@"%u:%u", output, matchedDisplay];
    return connection;
}

- (BOOL)isCurrent {
    return _output == MonitorSelectedOutput() && CGDisplayIsOnline(_display);
}

- (BOOL)readVolume:(uint16_t * _Nonnull)value maximum:(uint16_t * _Nonnull)maximum {
    CFTypeRef service = (__bridge CFTypeRef)_service;
    uint8_t request[] = {0x82, 0x01, SpeakerVolume, 0};
    request[3] = checksum(0x6e ^ Host, request, 3);
    for (int attempt = 0; attempt < 2; attempt++) {
        usleep(10000);
        if (writeAV(service, Chip, Host, request, sizeof(request)) != kIOReturnSuccess) continue;
        usleep(50000);
        uint8_t reply[12] = {0};
        if (readAV(service, Chip, Host, reply, sizeof(reply)) != kIOReturnSuccess ||
            reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 0x02 ||
            reply[3] != 0 || reply[4] != SpeakerVolume ||
            checksum(0x50, reply, 10) != reply[10]) {
            continue;
        }
        *maximum = (reply[6] << 8) | reply[7];
        *value = (reply[8] << 8) | reply[9];
        return *maximum > 0 && *value <= *maximum;
    }
    return NO;
}

- (BOOL)writeVolume:(uint16_t)value {
    CFTypeRef service = (__bridge CFTypeRef)_service;
    uint8_t request[] = {0x84, 0x03, SpeakerVolume, value >> 8, value & 0xff, 0};
    request[5] = checksum(0x6e ^ Host, request, 5);
    usleep(10000);
    return writeAV(service, Chip, Host, request, sizeof(request)) == kIOReturnSuccess;
}
@end

NS_ASSUME_NONNULL_END
