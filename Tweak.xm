#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface MSHProgressSlider : UISlider
@end

@implementation MSHProgressSlider

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect expandedBounds = CGRectInset(self.bounds, -20.0, -14.0);
    return CGRectContainsPoint(expandedBounds, point);
}

@end

static BOOL MSHDurationIsValid(AVPlayer *player) {
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

static BOOL MSHLayerTreeIsVisible(CALayer *layer) {
    if (!layer || !layer.superlayer || layer.hidden || layer.opacity < 0.02) {
        return NO;
    }

    CALayer *cursor = layer.superlayer;
    while (cursor) {
        if (cursor.hidden || cursor.opacity < 0.02) {
            return NO;
        }
        cursor = cursor.superlayer;
    }

    return YES;
}

static NSArray<UIWindow *> *MSHForegroundWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.alpha > 0.02) {
                [result addObject:window];
            }
        }
    }

    return result;
}

static UIWindow *MSHBestWindow(void) {
    NSArray<UIWindow *> *windows = MSHForegroundWindows();

    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }

    for (UIWindow *window in windows) {
        if (window.windowLevel == UIWindowLevelNormal) {
            return window;
        }
    }

    return windows.firstObject;
}

@interface MSHProgressManager : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, weak) AVPlayerLayer *playerLayer;
@property (nonatomic, weak) AVPlayerViewController *playerController;
@property (nonatomic, strong) id periodicTimeObserver;
@property (nonatomic, strong) NSTimer *refreshTimer;

@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) MSHProgressSlider *slider;
@property (nonatomic, strong) UILabel *currentLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;

@property (nonatomic, assign) BOOL userTracking;
@property (nonatomic, assign) CFTimeInterval lastPlayerActivity;
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
        _lastPlayerActivity = 0.0;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemEnded:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self startRefreshTimer];
            [self refreshNow];
        });
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopRefreshTimer];
    [self bindPlayer:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self startRefreshTimer];
    [self refreshNow];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self stopRefreshTimer];
    [self setBarVisible:NO];
}

- (void)playerItemEnded:(NSNotification *)notification {
    if (notification.object == self.player.currentItem) {
        [self refreshNow];
    }
}

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                        target:self
                                                      selector:@selector(refreshTimerFired:)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)stopRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer {
    [self refreshNow];
}

- (void)notePlayer:(AVPlayer *)player
             layer:(AVPlayerLayer *)layer
        controller:(AVPlayerViewController *)controller {
    if (![NSThread isMainThread]) {
        __weak AVPlayer *weakPlayer = player;
        __weak AVPlayerLayer *weakLayer = layer;
        __weak AVPlayerViewController *weakController = controller;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self notePlayer:weakPlayer layer:weakLayer controller:weakController];
        });
        return;
    }

    self.lastPlayerActivity = CACurrentMediaTime();

    if (layer) {
        self.playerLayer = layer;
    }

    if (controller) {
        self.playerController = controller;
    }

    if (player && player != self.player) {
        [self bindPlayer:player];
    }

    [self refreshNow];
}

- (void)playerWasUsed:(AVPlayer *)player {
    if (!player) {
        return;
    }

    if (![NSThread isMainThread]) {
        __weak AVPlayer *weakPlayer = player;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self playerWasUsed:weakPlayer];
        });
        return;
    }

    if (player == self.player) {
        self.lastPlayerActivity = CACurrentMediaTime();
        [self refreshNow];
    }
}

- (void)layerDetached:(AVPlayerLayer *)layer {
    if (![NSThread isMainThread]) {
        __weak AVPlayerLayer *weakLayer = layer;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self layerDetached:weakLayer];
        });
        return;
    }

    if (layer && layer == self.playerLayer) {
        self.playerLayer = nil;

        if (!self.playerController) {
            [self setBarVisible:NO];
        }
    }
}

- (void)controllerDisappeared:(AVPlayerViewController *)controller {
    if (![NSThread isMainThread]) {
        __weak AVPlayerViewController *weakController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self controllerDisappeared:weakController];
        });
        return;
    }

    if (controller && controller == self.playerController) {
        self.playerController = nil;

        if (!self.playerLayer || !MSHLayerTreeIsVisible(self.playerLayer)) {
            [self setBarVisible:NO];
        }
    }
}

- (void)bindPlayer:(AVPlayer *)player {
    if (self.player == player) {
        return;
    }

    if (self.periodicTimeObserver && self.player) {
        @try {
            [self.player removeTimeObserver:self.periodicTimeObserver];
        } @catch (__unused NSException *exception) {
        }
    }

    self.periodicTimeObserver = nil;
    self.player = player;
    self.userTracking = NO;

    if (!player) {
        [self setBarVisible:NO];
        return;
    }

    __weak typeof(self) weakSelf = self;

    self.periodicTimeObserver =
        [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 10)
                                             queue:dispatch_get_main_queue()
                                        usingBlock:^(__unused CMTime time) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        [strongSelf updateProgress];
    }];
}

- (void)ensureBarInWindow:(UIWindow *)window {
    if (!window) {
        return;
    }

    if (!self.barContainer) {
        UIView *container = [UIView new];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.hidden = YES;
        container.userInteractionEnabled = YES;
        container.layer.cornerRadius = 12.0;
        container.layer.masksToBounds = YES;
        container.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.46];

        UILabel *currentLabel = [UILabel new];
        currentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        currentLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        currentLabel.textColor = UIColor.whiteColor;
        currentLabel.textAlignment = NSTextAlignmentLeft;
        currentLabel.text = @"0:00";

        UILabel *durationLabel = [UILabel new];
        durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        durationLabel.textColor = UIColor.whiteColor;
        durationLabel.textAlignment = NSTextAlignmentRight;
        durationLabel.text = @"0:00";

        MSHProgressSlider *slider = [MSHProgressSlider new];
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        slider.minimumValue = 0.0f;
        slider.maximumValue = 1.0f;
        slider.continuous = YES;
        slider.minimumTrackTintColor = UIColor.whiteColor;
        slider.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.32];
        slider.thumbTintColor = UIColor.whiteColor;
        slider.accessibilityLabel = @"视频进度";

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

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sliderTapped:)];
        tap.cancelsTouchesInView = NO;
        [slider addGestureRecognizer:tap];

        [container addSubview:currentLabel];
        [container addSubview:durationLabel];
        [container addSubview:slider];

        [NSLayoutConstraint activateConstraints:@[
            [currentLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
            [currentLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [currentLabel.widthAnchor constraintEqualToConstant:42.0],

            [durationLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
            [durationLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [durationLabel.widthAnchor constraintEqualToConstant:42.0],

            [slider.leadingAnchor constraintEqualToAnchor:currentLabel.trailingAnchor constant:6.0],
            [slider.trailingAnchor constraintEqualToAnchor:durationLabel.leadingAnchor constant:-6.0],
            [slider.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [slider.heightAnchor constraintEqualToConstant:32.0]
        ]];

        self.barContainer = container;
        self.slider = slider;
        self.currentLabel = currentLabel;
        self.durationLabel = durationLabel;
    }

    if (self.barContainer.superview != window) {
        [self.barContainer removeFromSuperview];
        [window addSubview:self.barContainer];

        NSLayoutConstraint *bottom =
            [self.barContainer.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                                                           constant:-64.0];

        [NSLayoutConstraint activateConstraints:@[
            [self.barContainer.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:14.0],
            [self.barContainer.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-14.0],
            [self.barContainer.heightAnchor constraintEqualToConstant:44.0],
            bottom
        ]];

        self.bottomConstraint = bottom;
        self.hostWindow = window;
    }

    BOOL landscape = CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds);
    self.bottomConstraint.constant = landscape ? -18.0 : -64.0;

    [window bringSubviewToFront:self.barContainer];
}

- (NSString *)timeString:(double)seconds {
    if (!isfinite(seconds) || seconds < 0.0) {
        seconds = 0.0;
    }

    NSInteger wholeSeconds = (NSInteger)llround(floor(seconds));
    NSInteger hours = wholeSeconds / 3600;
    NSInteger minutes = (wholeSeconds % 3600) / 60;
    NSInteger secs = wholeSeconds % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)hours,
                (long)minutes,
                (long)secs];
    }

    return [NSString stringWithFormat:@"%ld:%02ld",
            (long)minutes,
            (long)secs];
}

- (BOOL)hasVisiblePlaybackHost {
    if (self.playerController) {
        UIView *view = self.playerController.viewIfLoaded;
        if (view.window && !view.hidden && view.alpha > 0.02) {
            return YES;
        }
    }

    if (self.playerLayer && MSHLayerTreeIsVisible(self.playerLayer)) {
        return YES;
    }

    if (self.player && self.player.rate != 0.0f) {
        return YES;
    }

    if (self.player) {
        CFTimeInterval age = CACurrentMediaTime() - self.lastPlayerActivity;
        if (age >= 0.0 && age <= 5.0) {
            return YES;
        }
    }

    return NO;
}

- (void)setBarVisible:(BOOL)visible {
    if (!self.barContainer) {
        return;
    }

    self.barContainer.hidden = !visible;

    if (visible && self.hostWindow) {
        [self.hostWindow bringSubviewToFront:self.barContainer];
    }
}

- (void)refreshNow {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self setBarVisible:NO];
        return;
    }

    AVPlayer *player = self.player;
    if (!player || !MSHDurationIsValid(player) || ![self hasVisiblePlaybackHost]) {
        [self setBarVisible:NO];
        return;
    }

    UIWindow *window = MSHBestWindow();
    if (!window) {
        [self setBarVisible:NO];
        return;
    }

    [self ensureBarInWindow:window];
    [self updateProgress];
    [self setBarVisible:YES];
}

- (void)updateProgress {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;

    if (!player || !item || !MSHDurationIsValid(player)) {
        [self setBarVisible:NO];
        return;
    }

    double duration = CMTimeGetSeconds(item.duration);
    double current = CMTimeGetSeconds(player.currentTime);

    if (!isfinite(duration) || duration <= 0.25) {
        [self setBarVisible:NO];
        return;
    }

    if (!isfinite(current)) {
        current = 0.0;
    }

    current = MIN(MAX(current, 0.0), duration);

    self.slider.minimumValue = 0.0f;
    self.slider.maximumValue = (float)duration;

    if (!self.userTracking) {
        [self.slider setValue:(float)current animated:NO];
        self.currentLabel.text = [self timeString:current];
    }

    self.durationLabel.text = [self timeString:duration];
}

- (void)seekToSliderValue {
    AVPlayer *player = self.player;
    if (!player) {
        self.userTracking = NO;
        return;
    }

    double seconds = self.slider.value;
    if (!isfinite(seconds) || seconds < 0.0) {
        self.userTracking = NO;
        return;
    }

    CMTime target = CMTimeMakeWithSeconds(seconds, 600);
    CMTime tolerance = CMTimeMakeWithSeconds(0.03, 600);

    __weak typeof(self) weakSelf = self;

    [player seekToTime:target
       toleranceBefore:tolerance
        toleranceAfter:tolerance
     completionHandler:^(__unused BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            strongSelf.userTracking = NO;
            strongSelf.lastPlayerActivity = CACurrentMediaTime();
            [strongSelf updateProgress];
        });
    }];
}

- (void)sliderTouchDown:(UISlider *)slider {
    self.userTracking = YES;
    self.lastPlayerActivity = CACurrentMediaTime();
}

- (void)sliderValueChanged:(UISlider *)slider {
    self.userTracking = YES;
    self.lastPlayerActivity = CACurrentMediaTime();
    self.currentLabel.text = [self timeString:slider.value];
}

- (void)sliderTouchEnded:(UISlider *)slider {
    [self seekToSliderValue];
}

- (void)sliderTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.slider) {
        return;
    }

    CGPoint location = [gesture locationInView:self.slider];
    CGFloat width = CGRectGetWidth(self.slider.bounds);

    if (width <= 1.0) {
        return;
    }

    CGFloat ratio = MIN(MAX(location.x / width, 0.0), 1.0);
    float value =
        self.slider.minimumValue +
        (self.slider.maximumValue - self.slider.minimumValue) * ratio;

    self.userTracking = YES;
    self.slider.value = value;
    self.currentLabel.text = [self timeString:value];
    [self seekToSliderValue];
}

@end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig(player);

    if (player) {
        [[MSHProgressManager sharedManager] notePlayer:player
                                                layer:self
                                           controller:nil];
    } else {
        [[MSHProgressManager sharedManager] layerDetached:self];
    }
}

- (void)removeFromSuperlayer {
    [[MSHProgressManager sharedManager] layerDetached:self];
    %orig;
}

%end

%hook AVPlayerViewController

- (void)setPlayer:(AVPlayer *)player {
    %orig(player);

    if (player) {
        [[MSHProgressManager sharedManager] notePlayer:player
                                                layer:nil
                                           controller:self];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (self.player) {
        [[MSHProgressManager sharedManager] notePlayer:self.player
                                                layer:nil
                                           controller:self];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[MSHProgressManager sharedManager] controllerDisappeared:self];
}

%end

%hook AVPlayer

- (void)play {
    %orig;
    [[MSHProgressManager sharedManager] playerWasUsed:self];
}

- (void)pause {
    %orig;
    [[MSHProgressManager sharedManager] playerWasUsed:self];
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig(item);

    if (item) {
        [[MSHProgressManager sharedManager] playerWasUsed:self];
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
