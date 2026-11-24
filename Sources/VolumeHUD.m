#import "VolumeHUD.h"
#import <QuartzCore/QuartzCore.h>

enum { SpeakerWaveCount = 3 };

static void animateLayer(CALayer *layer, NSString *property, id from, id to, CFTimeInterval duration) {
    if (!from) return;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:property];
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = duration;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:animation forKey:property];
}

static void setStrokeVisible(CAShapeLayer *stroke, BOOL visible, BOOL animated) {
    const float target = visible ? 1 : 0;
    if (!animated) [stroke removeAnimationForKey:@"opacity"];
    if (stroke.opacity == target) return;

    CALayer *presentation = stroke.presentationLayer;
    float current = presentation ? presentation.opacity : stroke.opacity;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    stroke.opacity = target;
    [CATransaction commit];

    if (animated) animateLayer(stroke, @"opacity", @(current), @(target), 0.16);
}

@interface VolumeSpeaker : NSView
- (void)showLevel:(NSUInteger)level animated:(BOOL)animated;
@end

@implementation VolumeSpeaker {
    CAShapeLayer *_waves[SpeakerWaveCount];
    CAShapeLayer *_muteMark;
    CAShapeLayer *_bodyMask;
    CGPoint _slashStart;
    CGPoint _slashEnd;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;

    NSView *bodyContainer = [[NSView alloc] initWithFrame:self.bounds];
    bodyContainer.wantsLayer = YES;
    _bodyMask = [CAShapeLayer layer];
    _bodyMask.frame = bodyContainer.bounds;
    _bodyMask.fillColor = NSColor.whiteColor.CGColor;
    _bodyMask.fillRule = kCAFillRuleEvenOdd;
    bodyContainer.layer.mask = _bodyMask;
    [self addSubview:bodyContainer];

    NSImageView *body = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 1.5, 23.5, 31)];
    body.image = [NSImage imageWithSystemSymbolName:@"speaker.fill" accessibilityDescription:nil];
    body.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:24
                                                                                weight:NSFontWeightMedium];
    body.contentTintColor = NSColor.whiteColor;
    [bodyContainer addSubview:body];

    CGFloat midY = NSMidY(self.bounds);
    const CGFloat arcAngle = 32 * M_PI / 180;
    for (NSUInteger index = 0; index < SpeakerWaveCount; index++) {
        CGFloat radius = 12 + 4.4 * index;
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathAddArc(path, NULL, 12, midY, radius, -arcAngle, arcAngle, false);
        _waves[index] = [self addStrokeWithPath:path];
        CGPathRelease(path);
    }

    _slashStart = CGPointMake(1, midY + 12.5);
    _slashEnd = CGPointMake(25, midY - 12.5);
    CGMutablePathRef slash = CGPathCreateMutable();
    CGPathMoveToPoint(slash, NULL, _slashStart.x, _slashStart.y);
    CGPathAddLineToPoint(slash, NULL, _slashEnd.x, _slashEnd.y);
    _muteMark = [self addStrokeWithPath:slash];
    _muteMark.opacity = 1;
    CGPathRelease(slash);
    [self setMuted:NO animated:NO];
    return self;
}

- (CAShapeLayer *)addStrokeWithPath:(CGPathRef)path {
    CAShapeLayer *stroke = [CAShapeLayer layer];
    stroke.frame = self.bounds;
    stroke.path = path;
    stroke.fillColor = NULL;
    stroke.strokeColor = NSColor.whiteColor.CGColor;
    stroke.lineWidth = 1.9;
    stroke.lineCap = kCALineCapRound;
    stroke.opacity = 0;
    [self.layer addSublayer:stroke];
    return stroke;
}

- (void)setMuted:(BOOL)muted animated:(BOOL)animated {
    CGFloat target = muted ? 1 : 0;
    if (!animated) {
        [_muteMark removeAnimationForKey:@"strokeEnd"];
        [_bodyMask removeAnimationForKey:@"path"];
    }
    if (_muteMark.strokeEnd == target && _bodyMask.path) return;

    CAShapeLayer *visibleMark = _muteMark.presentationLayer ?: _muteMark;
    CAShapeLayer *visibleMask = _bodyMask.presentationLayer ?: _bodyMask;
    CGFloat current = visibleMark.strokeEnd;
    id oldMask = (__bridge id)visibleMask.path;

    // Open a transparent strip around the line as it is drawn over the speaker.
    // Both paths use the same points so Core Animation can interpolate them.
    CGFloat dx = _slashEnd.x - _slashStart.x;
    CGFloat dy = _slashEnd.y - _slashStart.y;
    CGFloat scale = 2.6 / hypot(dx, dy);
    CGPoint normal = CGPointMake(-dy * scale, dx * scale);
    CGPoint tip = muted ? _slashEnd : _slashStart;
    CGMutablePathRef mask = CGPathCreateMutable();
    CGPathAddRect(mask, NULL, self.bounds);
    CGPathMoveToPoint(mask, NULL, _slashStart.x + normal.x, _slashStart.y + normal.y);
    CGPathAddLineToPoint(mask, NULL, tip.x + normal.x, tip.y + normal.y);
    CGPathAddLineToPoint(mask, NULL, tip.x - normal.x, tip.y - normal.y);
    CGPathAddLineToPoint(mask, NULL, _slashStart.x - normal.x, _slashStart.y - normal.y);
    CGPathCloseSubpath(mask);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _muteMark.strokeEnd = target;
    _bodyMask.path = mask;
    [CATransaction commit];
    if (animated) {
        animateLayer(_muteMark, @"strokeEnd", @(current), @(target), 0.20);
        animateLayer(_bodyMask, @"path", oldMask, (__bridge id)mask, 0.20);
    }
    CGPathRelease(mask);
}

- (void)showLevel:(NSUInteger)level animated:(BOOL)animated {
    NSUInteger waveCount = (level * SpeakerWaveCount + VolumeLevelCount - 1) / VolumeLevelCount;
    for (NSUInteger index = 0; index < SpeakerWaveCount; index++) {
        setStrokeVisible(_waves[index], index < waveCount, animated);
    }
    [self setMuted:level == 0 animated:animated];
}
@end

@interface VolumeTicks : NSView
- (void)showLevel:(NSUInteger)level animated:(BOOL)animated;
@end

@implementation VolumeTicks {
    CALayer *_track;
    CAShapeLayer *_segments;
    CALayer *_fill;
    CGFloat _scale;
    CGFloat _gap;
    NSUInteger _level;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    _track = [CALayer layer];
    _track.masksToBounds = YES;
    _track.backgroundColor = [NSColor.whiteColor colorWithAlphaComponent:0.25].CGColor;
    _segments = [CAShapeLayer layer];
    _segments.fillColor = NSColor.whiteColor.CGColor;
    _track.mask = _segments;

    _fill = [CALayer layer];
    _fill.anchorPoint = CGPointZero;
    _fill.position = CGPointZero;
    _fill.backgroundColor = NSColor.whiteColor.CGColor;
    [_track addSublayer:_fill];
    [self.layer addSublayer:_track];
    [self updateTrackGeometry];
    return self;
}

- (CGFloat)boundary:(NSUInteger)index {
    CGFloat step = (NSWidth(self.bounds) + _gap) / VolumeLevelCount;
    return round(index * step * _scale) / _scale;
}

- (void)updateTrackGeometry {
    CGFloat scale = self.window.backingScaleFactor ?: 1;
    if (_scale == scale && CGRectEqualToRect(_track.frame, self.bounds)) return;
    _scale = scale;
    _gap = MAX(1, round(0.85 * scale)) / scale;
    CGFloat height = NSHeight(self.bounds);
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger index = 0; index < VolumeLevelCount; index++) {
        CGFloat left = [self boundary:index];
        CGFloat right = [self boundary:index + 1] - _gap;
        CGPathAddRect(path, NULL, CGRectMake(left, 0, right - left, height));
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = self.bounds;
    _track.cornerRadius = height / 2;
    _segments.frame = _track.bounds;
    _segments.path = path;
    [CATransaction commit];
    CGPathRelease(path);
    [self showLevel:_level animated:NO];
}

- (void)layout {
    [super layout];
    [self updateTrackGeometry];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateTrackGeometry];
}

- (void)showLevel:(NSUInteger)level animated:(BOOL)animated {
    if (!animated) [_fill removeAnimationForKey:@"bounds.size.width"];
    _level = level;
    [self setAccessibilityValue:@(level)];
    CGFloat width = level ? [self boundary:level] - _gap : 0;
    CGRect target = CGRectMake(0, 0, width, NSHeight(self.bounds));
    if (CGRectEqualToRect(_fill.bounds, target)) return;

    CALayer *visibleFill = _fill.presentationLayer ?: _fill;
    CGFloat currentWidth = CGRectGetWidth(visibleFill.bounds);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.bounds = target;
    [CATransaction commit];
    if (animated) {
        animateLayer(_fill, @"bounds.size.width", @(currentWidth), @(width), 0.16);
    }
}
@end

@implementation VolumeHUD {
    NSPanel *_panel;
    VolumeSpeaker *_speaker;
    VolumeTicks *_ticks;
    NSTimer *_dismissTimer;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    const NSRect frame = NSMakeRect(0, 0, 292, 58);
    const CGFloat cornerRadius = NSHeight(frame) / 2;
    _panel = [[NSPanel alloc] initWithContentRect:frame
                                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                        backing:NSBackingStoreBuffered defer:NO];
    _panel.level = NSStatusWindowLevel;
    _panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.ignoresMouseEvents = YES;
    _panel.hidesOnDeactivate = NO;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorCanJoinAllApplications |
                                NSWindowCollectionBehaviorIgnoresCycle;

    NSView *content = [[NSView alloc] initWithFrame:frame];
    _speaker = [[VolumeSpeaker alloc] initWithFrame:NSMakeRect(18, 12, 47, 34)];
    [content addSubview:_speaker];

    _ticks = [[VolumeTicks alloc] initWithFrame:NSMakeRect(67, 27, 199, 4)];
    [_ticks setAccessibilityRole:NSAccessibilityLevelIndicatorRole];
    [_ticks setAccessibilityLabel:NSLocalizedString(@"音量", nil)];
    [_ticks setAccessibilityMinValue:@0];
    [_ticks setAccessibilityMaxValue:@(VolumeLevelCount)];
    [content addSubview:_ticks];

    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
        glass.cornerRadius = cornerRadius;
        glass.style = NSGlassEffectViewStyleClear;
        glass.contentView = content;
        _panel.contentView = glass;
    } else {
        NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:frame];
        background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        background.material = NSVisualEffectMaterialHUDWindow;
        background.state = NSVisualEffectStateActive;
        background.wantsLayer = YES;
        background.layer.cornerRadius = cornerRadius;
        background.layer.masksToBounds = YES;
        [background addSubview:content];
        _panel.contentView = background;
    }
    return self;
}

- (void)showLevel:(NSUInteger)level previousLevel:(NSUInteger)previousLevel onDisplay:(CGDirectDisplayID)display {
    for (NSScreen *screen in NSScreen.screens) {
        if (![screen.deviceDescription[@"NSScreenNumber"] isEqual:@(display)]) continue;

        BOOL animate = !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        if (animate && !_panel.visible) {
            [_speaker showLevel:previousLevel animated:NO];
            [_ticks showLevel:previousLevel animated:NO];
        }

        NSRect visible = screen.visibleFrame;
        NSRect panelFrame = _panel.frame;
        [_panel setFrameOrigin:NSMakePoint(NSMaxX(visible) - NSWidth(panelFrame) - 18,
                                            NSMaxY(visible) - NSHeight(panelFrame) - 10)];
        [_panel orderFrontRegardless];
        [_speaker showLevel:level animated:animate];
        [_ticks showLevel:level animated:animate];

        [_dismissTimer invalidate];
        __weak VolumeHUD *weakSelf = self;
        _dismissTimer = [NSTimer timerWithTimeInterval:1.1 repeats:NO block:^(NSTimer *timer) {
            [weakSelf hide];
        }];
        [NSRunLoop.mainRunLoop addTimer:_dismissTimer forMode:NSRunLoopCommonModes];
        return;
    }
    [self hide];
}

- (void)hide {
    [_dismissTimer invalidate];
    _dismissTimer = nil;
    [_panel orderOut:nil];
}
@end
