#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface MSHProgressSlider : UISlider
@end

@implementation MSHProgressSlider

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect expanded = CGRectInset(self.bounds, -18.0, -14.0);
    return CGRectContainsPoint(expanded, point);
}

- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint point = [touch locationInView:self];
    if (CGRectGetWidth(self.bounds) > 0.0) {
        CGFloat ratio = MIN(MAX(point.x / CGRectGetWidth(self.bounds), 0.0), 1.0);
        float value = self.minimumValue + (self.maximumValue - self.minimumValue) * ratio;
        [self setValue:value animated:NO];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    return [super beginTracking:touch withEvent:event];
}

@end

@interface MSHPlayerCandidate : NSObject
@property (nonatomic, weak) UIView *ownerView;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, assign) CGFloat score;
@end

@implementation MSHPlayerCandidate
@end

static BOOL MSHViewIsVisible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha < 0.02) {
        return NO;
    }

    UIView *cursor = view.superview;
    while (cursor) {
        if (cursor.hidden || cursor.alpha < 0.02) {
            return NO;
        }
        cursor = cursor.superview;
    }

    return YES;
}

static BOOL MSHPlayerHasUsableDuration(AVPlayer *player) {
    AVPlayerItem *item = player.currentItem;
    if (!item) {
        return NO;
    }

    CMTime durationTime = item.duration;
    if (!CMTIME_IS_NUMERIC(durationTime)) {
        return NO;
    }

    double duration = CMTimeGetSeconds(durationTime);
    return isfinite(duration) && duration > 0.25;
}

static void MSHInspectLayerTree(CALayer *layer, UIView *ownerView, MSHPlayerCandidate *candidate) {
    if (!layer || layer.hidden || layer.opacity < 0.02) {
        return;
    }

    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *playerLayer = (AVPlayerLayer *)layer;
        AVPlayer *player = playerLayer.player;

        if (player && player.currentItem) {
            CGFloat width = CGRectGetWidth(layer.bounds);
            CGFloat height = CGRectGetHeight(layer.bounds);
            CGFloat area = fabs(width * height);

            if (area <= 1.0) {
                area = fabs(CGRectGetWidth(ownerView.bounds) * CGRectGetHeight(ownerView.bounds));
            }

            BOOL usable = MSHPlayerHasUsableDuration(player);
            CGFloat score = area + (usable ? 10000000.0 : 0.0);

            if (score > candidate.score) {
                candidate.score = score;
                candidate.ownerView = ownerView;
                candidate.player = player;
            }
        }
    }

    for (CALayer *sublayer in layer.sublayers) {
        MSHInspectLayerTree(sublayer, ownerView, candidate);
    }
}

static void MSHInspectViewTree(UIView *view, MSHPlayerCandidate *candidate) {
    if (!view || !MSHViewIsVisible(view)) {
        return;
    }

    MSHInspectLayerTree(view.layer, view, candidate);

    for (UIView *subview in view.subviews) {
        MSHInspectViewTree(subview, candidate);
    }
}

static UIWindow *MSHCurrentWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;

    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow && !window.hidden && window.alpha > 0.02) {
            return window;
        }
    }

    for (UIWindow *window in application.windows) {
        if (!window.hidden && window.alpha > 0.02 && window.windowLevel == UIWindowLevelNormal) {
            return window;
        }
    }

    return application.windows.firstObject;
}

@interface MSHProgressManager : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, strong) MSHProgressSlider *slider;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, assign) BOOL userTracking;
@end

@implementation MSHProgressManager

+ (instancetype)sharedManager {
    static MSHProgressManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [MSHProgressManager new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self startScanning];
            [self scanNow];
        });
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopScanning];
    [self bindPlayer:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self startScanning];
    [self scanNow];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self stopScanning];
    self.slider.hidden = YES;
}

- (void)startScanning {
    if (self.scanTimer) {
        return;
    }

    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.65
                                                      target:self
                                                    selector:@selector(scanTimerFired:)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)stopScanning {
    [self.scanTimer invalidate];
    self.scanTimer = nil;
}

- (void)scanTimerFired:(NSTimer *)timer {
    [self scanNow];
}

- (void)attachSliderToWindow:(UIWindow *)window {
    if (!window) {
        return;
    }

    if (!self.slider) {
        MSHProgressSlider *slider = [MSHProgressSlider new];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        slider.minimumValue = 0.0f;
        slider.maximumValue = 1.0f;
        slider.continuous = YES;
        slider.hidden = YES;
        slider.accessibilityLabel = @"视频进度";

        if (@available(iOS 13.0, *)) {
            slider.minimumTrackTintColor = UIColor.labelColor;
            slider.maximumTrackTintColor = [UIColor.labelColor colorWithAlphaComponent:0.28];
            slider.thumbTintColor = UIColor.labelColor;
        } else {
            slider.minimumTrackTintColor = UIColor.whiteColor;
            slider.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.28];
            slider.thumbTintColor = UIColor.whiteColor;
        }

        [slider addTarget:self
                   action:@selector(sliderTouchDown:)
         forControlEvents:UIControlEventTouchDown];

        [slider addTarget:self
                   action:@selector(sliderValueChanged:)
         forControlEvents:UIControlEventValueChanged];

        [slider addTarget:self
                   action:@selector(sliderTouchEnded:)
         forControlEvents:(UIControlEventTouchUpInside |
                           UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel)];

        self.slider = slider;
    }

    if (self.slider.superview != window) {
        [self.slider removeFromSuperview];
        [window addSubview:self.slider];

        NSLayoutConstraint *bottomConstraint =
            [self.slider.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                                                    constant:-86.0];

        [NSLayoutConstraint activateConstraints:@[
            [self.slider.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:54.0],
            [self.slider.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-54.0],
            [self.slider.heightAnchor constraintEqualToConstant:34.0],
            bottomConstraint
        ]];

        self.bottomConstraint = bottomConstraint;
        self.window = window;
    }

    BOOL landscape = CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds);
    self.bottomConstraint.constant = landscape ? -34.0 : -86.0;

    [window bringSubviewToFront:self.slider];
}

- (void)scanNow {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        self.slider.hidden = YES;
        return;
    }

    UIWindow *window = MSHCurrentWindow();
    if (!window) {
        self.slider.hidden = YES;
        [self bindPlayer:nil];
        return;
    }

    [self attachSliderToWindow:window];

    MSHPlayerCandidate *candidate = [MSHPlayerCandidate new];
    candidate.score = -1.0;
    MSHInspectViewTree(window, candidate);

    AVPlayer *candidatePlayer = candidate.player;

    if (!candidatePlayer || !candidate.ownerView || !MSHViewIsVisible(candidate.ownerView)) {
        self.slider.hidden = YES;
        [self bindPlayer:nil];
        return;
    }

    if (candidatePlayer != self.player) {
        [self bindPlayer:candidatePlayer];
    }

    [self refreshSliderFromPlayer];
}

- (void)bindPlayer:(AVPlayer *)player {
    if (self.player == player) {
        return;
    }

    if (self.timeObserver && self.player) {
        @try {
            [self.player removeTimeObserver:self.timeObserver];
        } @catch (__unused NSException *exception) {
        }
    }

    self.timeObserver = nil;
    self.player = player;
    self.userTracking = NO;

    if (!player) {
        self.slider.hidden = YES;
        return;
    }

    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMake(1, 4);

    self.timeObserver =
        [player addPeriodicTimeObserverForInterval:interval
                                             queue:dispatch_get_main_queue()
                                        usingBlock:^(CMTime time) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf refreshSliderFromPlayer];
    }];

    [self refreshSliderFromPlayer];
}

- (void)refreshSliderFromPlayer {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;

    if (!player || !item) {
        self.slider.hidden = YES;
        return;
    }

    CMTime durationTime = item.duration;
    if (!CMTIME_IS_NUMERIC(durationTime)) {
        self.slider.hidden = YES;
        return;
    }

    double duration = CMTimeGetSeconds(durationTime);
    if (!isfinite(duration) || duration <= 0.25) {
        self.slider.hidden = YES;
        return;
    }

    self.slider.maximumValue = (float)duration;
    self.slider.minimumValue = 0.0f;

    if (!self.userTracking) {
        double current = CMTimeGetSeconds(player.currentTime);
        if (isfinite(current)) {
            current = MIN(MAX(current, 0.0), duration);
            [self.slider setValue:(float)current animated:NO];
        }
    }

    self.slider.hidden = NO;

    if (self.window) {
        [self.window bringSubviewToFront:self.slider];
    }
}

- (void)sliderTouchDown:(UISlider *)slider {
    self.userTracking = YES;
}

- (void)sliderValueChanged:(UISlider *)slider {
    self.userTracking = YES;
}

- (void)sliderTouchEnded:(UISlider *)slider {
    AVPlayer *player = self.player;
    if (!player) {
        self.userTracking = NO;
        return;
    }

    double seconds = slider.value;
    if (!isfinite(seconds) || seconds < 0.0) {
        self.userTracking = NO;
        return;
    }

    CMTime target = CMTimeMakeWithSeconds(seconds, 600);
    CMTime tolerance = CMTimeMakeWithSeconds(0.05, 600);

    __weak typeof(self) weakSelf = self;
    [player seekToTime:target
       toleranceBefore:tolerance
        toleranceAfter:tolerance
     completionHandler:^(__unused BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.userTracking = NO;
            [weakSelf refreshSliderFromPlayer];
        });
    }];
}

@end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[MSHProgressManager sharedManager] scanNow];
    });
}

- (void)viewDidLayoutSubviews {
    %orig;

    static CFTimeInterval lastScan = 0.0;
    CFTimeInterval now = CACurrentMediaTime();

    if (now - lastScan > 0.20) {
        lastScan = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MSHProgressManager sharedManager] scanNow];
        });
    }
}

%end

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [MSHProgressManager sharedManager];
        });
    }
}
