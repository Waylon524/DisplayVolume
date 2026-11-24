#import "Monitor.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <unistd.h>

// DDC/CI framing and Apple Silicon transport adapted from m1ddc (MIT).
// See ThirdPartyNotices.txt.
static const uint16_t Vendor = 0x4acd;
static const uint16_t Model = 0x2740;
static const uint8_t SpeakerVolume = 0x62;
static const uint32_t Chip = 0x37;
static const uint32_t Host = 0x51;

typedef CFTypeRef (*AVOpen)(CFAllocatorRef, io_service_t);
typedef IOReturn (*AVTransfer)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static AVOpen openAV;
static AVTransfer readAV, writeAV;

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

CGDirectDisplayID MonitorSelectedDisplay(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 transport = 0;
    CFStringRef name = NULL;
    if (audioProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                      sizeof(device), &device) != noErr ||
        audioProperty(device, kAudioDevicePropertyTransportType, sizeof(transport), &transport) != noErr ||
        (transport != 'dprt' && transport != 'hdmi') ||
        audioProperty(device, kAudioObjectPropertyName, sizeof(name), &name) != noErr || !name) {
        return kCGNullDirectDisplay;
    }
    BOOL matches = CFEqual(name, CFSTR("RV200 Ultra"));
    CFRelease(name);
    if (!matches) return kCGNullDirectDisplay;

    CGDirectDisplayID displays[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) return kCGNullDirectDisplay;
    CGDirectDisplayID matched = kCGNullDirectDisplay;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displays[i];
        if (!CGDisplayIsBuiltin(display) && CGDisplayVendorNumber(display) == Vendor &&
            CGDisplayModelNumber(display) == Model) {
            if (matched) return kCGNullDirectDisplay;
            matched = display;
        }
    }
    return matched;
}

static BOOL matchingEDID(const uint8_t *edid) {
    const uint8_t header[] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
    if (memcmp(edid, header, sizeof(header)) != 0) return NO;
    uint8_t sum = 0;
    for (int i = 0; i < 128; i++) sum += edid[i];
    return sum == 0 && ((edid[8] << 8) | edid[9]) == Vendor &&
           (edid[10] | (edid[11] << 8)) == Model;
}

CFTypeRef MonitorOpen(void) {
    if (!MonitorSelectedDisplay() || !loadTransport()) return NULL;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                    &iterator) != KERN_SUCCESS) {
        return NULL;
    }

    CFTypeRef matched = NULL;
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
        if (readAV(service, 0x50, 0, edid, sizeof(edid)) != kIOReturnSuccess ||
            !matchingEDID(edid)) {
            CFRelease(service);
            continue;
        }
        if (matched) {
            // Two indistinguishable displays are deliberately left to macOS.
            CFRelease(service);
            CFRelease(matched);
            matched = NULL;
            break;
        }
        matched = service;
    }
    IOObjectRelease(iterator);
    return matched;
}

static uint8_t checksum(uint8_t seed, const uint8_t *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) seed ^= bytes[i];
    return seed;
}

BOOL MonitorRead(CFTypeRef service, uint16_t *value, uint16_t *maximum) {
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

BOOL MonitorWrite(CFTypeRef service, uint16_t value) {
    uint8_t request[] = {0x84, 0x03, SpeakerVolume, value >> 8, value & 0xff, 0};
    request[5] = checksum(0x6e ^ Host, request, 5);
    usleep(10000);
    return writeAV(service, Chip, Host, request, sizeof(request)) == kIOReturnSuccess;
}
