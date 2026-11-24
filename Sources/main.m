#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/log.h>
#include <math.h>
#include <signal.h>
#include <sys/sysctl.h>
#import "Monitor.h"
#import "VolumeHUD.h"

static NSString *const Domain = @"io.waylon.display-volume";
static NSString *const Mapping = @"UserKeyMapping";
static NSString *const Source = @"HIDKeyboardModifierMappingSrc";
static NSString *const Destination = @"HIDKeyboardModifierMappingDst";
static const OSType HotKeySignature = 'DVOL';

enum VolumeKey { MuteKey, DownKey, UpKey, KeyCount };

static void makeVolumeSteps(uint16_t maximum, uint16_t steps[VolumeLevelCount + 1]) {
    const double curve = 4.5;
    const double scale = maximum / expm1(curve);
    const uint16_t minimumGap = maximum >= VolumeLevelCount ? 1 : 0;
    steps[0] = 0;
    steps[VolumeLevelCount] = maximum;
    for (NSUInteger level = 1; level < VolumeLevelCount; level++) {
        double position = (double)level / VolumeLevelCount;
        long target = lround(scale * expm1(curve * position));
        // Reserve one hardware value per remaining step when the display can represent it.
        uint16_t lower = steps[level - 1] + minimumGap;
        uint16_t upper = maximum - (VolumeLevelCount - level) * minimumGap;
        steps[level] = (uint16_t)MAX(lower, MIN(upper, target));
    }
}

static NSUInteger nearestVolumeLevel(uint16_t value, const uint16_t steps[VolumeLevelCount + 1]) {
    if (!value) return 0;

    NSUInteger upper = 1;
    while (upper < VolumeLevelCount && steps[upper] < value) upper++;
    // Keep the zero step for mute and favor the quieter step on a tie.
    if (upper > 1 && value - steps[upper - 1] <= steps[upper] - value) return upper - 1;
    return upper;
}

static NSNumber *usage(uint16_t page, uint16_t key) {
    return @(((uint64_t)page << 32) | key);
}

static NSArray<NSDictionary *> *volumeMappings(void) {
    return @[
        @{Source: usage(kHIDPage_Consumer, kHIDUsage_Csmr_Mute), Destination: usage(7, kHIDUsage_KeyboardF16)},
        @{Source: usage(kHIDPage_Consumer, kHIDUsage_Csmr_VolumeDecrement), Destination: usage(7, kHIDUsage_KeyboardF17)},
        @{Source: usage(kHIDPage_Consumer, kHIDUsage_Csmr_VolumeIncrement), Destination: usage(7, kHIDUsage_KeyboardF18)},
        @{Source: usage(7, kHIDUsage_KeyboardMute), Destination: usage(7, kHIDUsage_KeyboardF16)},
        @{Source: usage(7, kHIDUsage_KeyboardVolumeDown), Destination: usage(7, kHIDUsage_KeyboardF17)},
        @{Source: usage(7, kHIDUsage_KeyboardVolumeUp), Destination: usage(7, kHIDUsage_KeyboardF18)},
    ];
}

static NSArray *serviceMappings(IOHIDServiceClientRef service) {
    id data = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, (__bridge CFStringRef)Mapping));
    return [data isKindOfClass:NSArray.class] ? data : @[];
}

static BOOL setMappings(IOHIDServiceClientRef service, NSArray *newMappings) {
    return IOHIDServiceClientSetProperty(service, (__bridge CFStringRef)Mapping,
                                         (__bridge CFArrayRef)newMappings);
}

static NSString *bootIdentifier(void) {
    char value[128] = {0};
    size_t length = sizeof(value);
    if (sysctlbyname("kern.bootsessionuuid", value, &length, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:value];
}

@interface DisplayVolume : NSObject <NSApplicationDelegate>
- (void)refresh;
- (void)handleVolumeKey:(enum VolumeKey)key pressed:(BOOL)pressed;
@end

static OSStatus volumeKeyEvent(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID key;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(key), NULL, &key) != noErr ||
        key.signature != HotKeySignature || key.id >= KeyCount) {
        return eventNotHandledErr;
    }
    [(__bridge DisplayVolume *)context handleVolumeKey:key.id
                                               pressed:GetEventKind(event) == kEventHotKeyPressed];
    return noErr;
}

@implementation DisplayVolume {
    MonitorConnection *_monitor;
    AudioDeviceID _discoveryOutput;
    NSTimeInterval _discoverAfter;
    IOHIDEventSystemClientRef _hid;
    EventHotKeyRef _hotkeys[KeyCount];
    BOOL _listening, _suspended, _refreshing;
    NSMutableDictionary<NSString *, NSNumber *> *_lastAudibleLevels;
    VolumeHUD *_hud;
    os_log_t _log;
    NSTimer *_timer;
    NSTimer *_repeatTimer;
    enum VolumeKey _repeatKey;
    NSUInteger _heldKeys;
    NSArray<dispatch_source_t> *_terminationSignals;
    NSString *_boot;
    NSURL *_journalURL;
    NSMutableDictionary<NSString *, NSArray *> *_journal;
}

- (BOOL)saveJournal {
    return _boot && _journalURL &&
           [@{@"boot": _boot, @"services": _journal} writeToURL:_journalURL error:nil];
}

- (void)updateMappings:(BOOL)install {
    if (!_hid || (!install && _journal.count == 0)) return;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(_hid);
    if (!services) return;
    NSArray *additions = volumeMappings();
    const NSSet *usedSources = [NSSet setWithArray:[additions valueForKey:Source]];
    const NSSet *usedDestinations = [NSSet setWithArray:[additions valueForKey:Destination]];
    NSMutableSet *present = [NSMutableSet set];
    NSUInteger installed = 0;

    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        id registryID = (__bridge id)IOHIDServiceClientGetRegistryID(service);
        if (![registryID isKindOfClass:NSNumber.class]) continue;
        NSString *identifier = [registryID stringValue];
        [present addObject:identifier];

        NSArray *owned = _journal[identifier];
        if (owned) {
            NSArray *current = serviceMappings(service);
            if (install && [[NSSet setWithArray:owned] isSubsetOfSet:[NSSet setWithArray:current]]) {
                continue;
            }
            NSMutableArray *restored = [current mutableCopy];
            [restored removeObjectsInArray:owned];
            if (![restored isEqualToArray:current] && !setMappings(service, restored)) continue;
            [_journal removeObjectForKey:identifier];
            [self saveJournal];
        }
        if (!install ||
            !(IOHIDServiceClientConformsTo(service, kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard) ||
              IOHIDServiceClientConformsTo(service, kHIDPage_Consumer, kHIDUsage_Csmr_ConsumerControl))) {
            continue;
        }

        NSArray *current = serviceMappings(service);
        BOOL conflict = NO;
        for (NSDictionary *pair in current) {
            if ([usedSources containsObject:pair[Source]] ||
                [usedDestinations containsObject:pair[Source]] ||
                [usedDestinations containsObject:pair[Destination]]) {
                conflict = YES;
                break;
            }
        }
        if (conflict) continue;

        // Persist the exact additions before changing the service so they can be
        // removed after a crash without replacing another tool's mappings.
        _journal[identifier] = additions;
        if (![self saveJournal] ||
            !setMappings(service, [current arrayByAddingObjectsFromArray:additions])) {
            [_journal removeObjectForKey:identifier];
            [self saveJournal];
            continue;
        }
        installed++;
    }
    CFRelease(services);
    for (NSString *identifier in _journal.allKeys) {
        if (![present containsObject:identifier]) {
            [_journal removeObjectForKey:identifier];
            [self saveJournal];
        }
    }
    if (installed) os_log(_log, "Volume keys configured on %lu keyboard services", (unsigned long)installed);
}

- (void)deactivate {
    [self stopKeyRepeat];
    _heldKeys = 0;
    [_hud hide];
    [self updateMappings:NO];
    for (NSUInteger index = 0; index < KeyCount; index++) {
        if (_hotkeys[index]) UnregisterEventHotKey(_hotkeys[index]);
        _hotkeys[index] = NULL;
    }
    _monitor = nil;
    if (_listening) os_log(_log, "Volume keys returned to macOS");
    _listening = NO;
}

- (void)refresh {
    if (_refreshing) return;
    _refreshing = YES;
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    BOOL active = !_suspended && session && ![session[@"CGSSessionScreenIsLocked"] boolValue] &&
                  [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue];
    AudioDeviceID output = active ? MonitorSelectedOutput() : kAudioObjectUnknown;
    if (output == kAudioObjectUnknown ||
        (_monitor && (output != _monitor.output || !CGDisplayIsOnline(_monitor.display)))) {
        [self deactivate];
    }
    if (output != _discoveryOutput) {
        _discoveryOutput = output;
        _discoverAfter = 0;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (output != kAudioObjectUnknown && !_listening && _hid && _boot && _journalURL &&
        now >= _discoverAfter) {
        uint16_t value, maximum;
        _discoverAfter = now + 8;
        _monitor = [MonitorConnection connectToOutput:output reason:NULL];
        if ([_monitor readVolume:&value maximum:&maximum] && [_monitor isCurrent]) {
            const UInt32 codes[KeyCount] = {kVK_F16, kVK_F17, kVK_F18};
            for (UInt32 index = 0; index < KeyCount; index++) {
                EventHotKeyID key = {HotKeySignature, index};
                if (RegisterEventHotKey(codes[index], 0, key, GetApplicationEventTarget(),
                                        kEventHotKeyExclusive, &_hotkeys[index]) != noErr) {
                    break;
                }
            }
            _listening = _hotkeys[KeyCount - 1] != NULL;
        }
        if (_listening) {
            os_log(_log, "Display audio selected: %{public}@, hardware volume %u/%u", _monitor.name, value, maximum);
        } else {
            [self deactivate];
        }
    }
    if (_listening) [self updateMappings:YES];
    _refreshing = NO;
}

- (void)stopKeyRepeat {
    [_repeatTimer invalidate];
    _repeatTimer = nil;
}

- (void)repeatVolumeKey:(NSTimer *)timer {
    if (![self adjustAndCanRepeat:_repeatKey]) [self stopKeyRepeat];
}

- (void)handleVolumeKey:(enum VolumeKey)key pressed:(BOOL)pressed {
    NSUInteger keyBit = 1UL << key;
    if (!pressed) {
        _heldKeys &= ~keyBit;
        if (_repeatTimer && _repeatKey == key) [self stopKeyRepeat];
        return;
    }
    if (_heldKeys & keyBit) return;
    _heldKeys |= keyBit;
    [self stopKeyRepeat];
    if (![self adjustAndCanRepeat:key]) return;

    _repeatKey = key;
    _repeatTimer = [NSTimer timerWithTimeInterval:0.12 target:self
                                         selector:@selector(repeatVolumeKey:) userInfo:nil repeats:YES];
    _repeatTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.28];
    [NSRunLoop.mainRunLoop addTimer:_repeatTimer forMode:NSRunLoopCommonModes];
}

- (BOOL)adjustAndCanRepeat:(enum VolumeKey)key {
    MonitorConnection *monitor = _monitor;
    if (!_listening || ![monitor isCurrent]) {
        [self deactivate];
        return NO;
    }
    uint16_t value, maximum;
    if (![monitor readVolume:&value maximum:&maximum]) {
        [self deactivate];
        return NO;
    }
    uint16_t steps[VolumeLevelCount + 1];
    makeVolumeSteps(maximum, steps);
    NSString *memoryKey = monitor.volumeMemoryKey;
    NSUInteger previousLevel = nearestVolumeLevel(value, steps);
    if (previousLevel) _lastAudibleLevels[memoryKey] = @(previousLevel);
    NSUInteger level = 0;
    switch (key) {
        case DownKey:
            level = VolumeLevelCount;
            while (level > 0 && steps[level] >= value) level--;
            break;
        case UpKey:
            while (level < VolumeLevelCount && steps[level] <= value) level++;
            break;
        case MuteKey:
            level = value ? 0 : (_lastAudibleLevels[memoryKey].unsignedIntegerValue ?: 4);
            break;
        case KeyCount: return NO;
    }
    uint16_t next = steps[level];
    if (![monitor isCurrent] || (next != value && ![monitor writeVolume:next])) {
        [self deactivate];
        return NO;
    }
    if (next) _lastAudibleLevels[memoryKey] = @(level);
    if (next != value) os_log(_log, "Display audio %{public}@ volume %u -> %u", monitor.name, value, next);
    if (!_hud) _hud = [VolumeHUD new];
    CGDirectDisplayID mirroredTo = CGDisplayMirrorsDisplay(monitor.display);
    [_hud showLevel:level previousLevel:previousLevel onDisplay:mirroredTo ?: monitor.display];
    return (key == DownKey && level > 0) || (key == UpKey && level < VolumeLevelCount);
}

- (void)suspend:(NSNotification *)notification {
    _suspended = YES;
    [self deactivate];
}

- (void)resume:(NSNotification *)notification {
    _suspended = NO;
    _discoverAfter = 0;
    [self refresh];
}

- (void)displayChanged:(NSNotification *)notification {
    [self deactivate];
    _discoverAfter = 0;
    [self refresh];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _log = os_log_create(Domain.UTF8String, "volume");
    _lastAudibleLevels = [NSMutableDictionary dictionary];
    _hid = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    _boot = bootIdentifier();

    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [[files URLsForDirectory:NSApplicationSupportDirectory
                                    inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [support URLByAppendingPathComponent:Domain isDirectory:YES];
    if ([files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
        _journalURL = [directory URLByAppendingPathComponent:@"keyboard.plist"];
    }
    NSDictionary *saved = _journalURL ? [NSDictionary dictionaryWithContentsOfURL:_journalURL error:nil] : nil;
    _journal = [saved[@"boot"] isEqualToString:_boot] ? [saved[@"services"] mutableCopy] : nil;
    if (!_journal) _journal = [NSMutableDictionary dictionary];
    [self updateMappings:NO];

    const EventTypeSpec events[] = {
        {kEventClassKeyboard, kEventHotKeyPressed},
        {kEventClassKeyboard, kEventHotKeyReleased}
    };
    if (InstallApplicationEventHandler(volumeKeyEvent, 2, events, (__bridge void *)self, NULL) != noErr) {
        os_log_error(_log, "Could not register volume hotkey handler");
        [NSApp terminate:nil];
        return;
    }

    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceWillSleepNotification, NSWorkspaceSessionDidResignActiveNotification]) {
        [workspace addObserver:self selector:@selector(suspend:) name:name object:nil];
    }
    for (NSNotificationName name in @[NSWorkspaceDidWakeNotification, NSWorkspaceSessionDidBecomeActiveNotification]) {
        [workspace addObserver:self selector:@selector(resume:) name:name object:nil];
    }
    NSDistributedNotificationCenter *distributed = NSDistributedNotificationCenter.defaultCenter;
    [distributed addObserver:self selector:@selector(suspend:) name:@"com.apple.screenIsLocked" object:nil];
    [distributed addObserver:self selector:@selector(resume:) name:@"com.apple.screenIsUnlocked" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayChanged:)
                                              name:NSApplicationDidChangeScreenParametersNotification object:nil];

    AudioObjectPropertyAddress output = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    __weak DisplayVolume *weakSelf = self;
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &output, dispatch_get_main_queue(),
                                       ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        [weakSelf refresh];
    });
    // A low-frequency check also handles newly connected keyboards, which may
    // have a different HID service from the one present at application launch.
    _timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh];
    }];
    _timer.tolerance = 0.5;

    NSMutableArray *signals = [NSMutableArray array];
    for (NSNumber *signo in @[@(SIGTERM), @(SIGINT)]) {
        signal(signo.intValue, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signo.intValue, 0,
                                                           dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{ [NSApp terminate:nil]; });
        dispatch_resume(source);
        [signals addObject:source];
    }
    _terminationSignals = signals;
    [self refresh];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_timer invalidate];
    [self deactivate];
    if (_hid) CFRelease(_hid);
}
@end

static int loginItem(NSString *action) {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL success = YES;
    if ([action isEqualToString:@"--enable-login"] && service.status != SMAppServiceStatusEnabled) {
        success = [service registerAndReturnError:&error];
    } else if ([action isEqualToString:@"--disable-login"] &&
               (service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval)) {
        success = [service unregisterAndReturnError:&error];
    }
    if (!success) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    const char *status = "not-found";
    switch (service.status) {
        case SMAppServiceStatusEnabled: status = "enabled"; break;
        case SMAppServiceStatusNotRegistered: status = "disabled"; break;
        case SMAppServiceStatusRequiresApproval: status = "requires-approval"; break;
        case SMAppServiceStatusNotFound: break;
    }
    printf("Login item: %s\n", status);
    return success ? EXIT_SUCCESS : EXIT_FAILURE;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2) {
            NSString *action = @(argv[1]);
            if ([@[@"--enable-login", @"--disable-login", @"--login-status"] containsObject:action]) {
                return loginItem(action);
            }
            if ([action isEqualToString:@"--probe"]) {
                AudioDeviceID output = MonitorSelectedOutput();
                if (output == kAudioObjectUnknown) {
                    puts("Select a DisplayPort or HDMI display as the macOS sound output.");
                    return EXIT_FAILURE;
                }
                NSString *reason = nil;
                MonitorConnection *monitor = [MonitorConnection connectToOutput:output reason:&reason];
                if (!monitor) {
                    puts(reason.UTF8String);
                    return EXIT_FAILURE;
                }
                uint16_t volume, maximum;
                if (![monitor readVolume:&volume maximum:&maximum] || ![monitor isCurrent]) {
                    printf("%s did not return readable DDC/CI speaker volume (VCP 0x62).\n", monitor.name.UTF8String);
                    return EXIT_FAILURE;
                }
                printf("%s: %u/%u\n", monitor.name.UTF8String, volume, maximum);
                return EXIT_SUCCESS;
            }
        }

        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        DisplayVolume *delegate = [DisplayVolume new];
        app.delegate = delegate;
        [app run];
    }
    return EXIT_SUCCESS;
}
