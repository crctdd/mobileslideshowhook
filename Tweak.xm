#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface MSHProgressSlider : UISlider
@end

@implementation MSHProgressSlider

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect expandedBounds = CGRectInset(self.bounds, -20.0, -14.0);
    return CGRectContainsPoint(expandedBounds, point);
}

@end

static BOOL MSHPlayerItemIsUsableVideo(AVPlayer *player) {
    AVPlayerItem *item = player.currentItem;
    if (!item) {
        return NO;
    }

    CMTime durationTime = item.duration;
    if (!CMTIME_IS_NUMERIC(durationTime)) {
        return NO;
    }

    double duration = CMTimeGetSeconds(durationTime);
    if (!isfinite(duration) || duration <= 0.25) {
        return NO;
    }

    CGSize presentationSize = item.presentationSize;
    if (presentationSize.width <= 1.0 || presentationSize.height <= 1.0) {
        return NO;
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

static BOOL MSHViewIsActuallyVisible(UIView *view) {
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

    UIWindow *window = view.window;
    CGRect rectInWindow = [view convertRect:view.bounds toView:window];

    if (CGRectIsEmpty(rectInWindow) ||
        CGRectIsNull(rectInWindow) ||
        !CGRectIntersectsRect(rectInWindow, window.bounds)) {
        return NO;
    }

    CGRect intersection = CGRectIntersection(rectInWindow, window.bounds);
    return CGRectGetWidth(intersection) > 2.0 && CGRectGetHeight(intersection) > 2.0;
}

static BOOL MSHPlayerLayerIsActuallyVisible(AVPlayerLayer *playerLayer, UIWindow *window) {
    if (!playerLayer ||
        !playerLayer.player ||
        playerLayer.hidden ||
        playerLayer.opacity < 0.02 ||
        !playerLayer.superlayer) {
        return NO;
    }

    if (CGRectGetWidth(playerLayer.bounds) <= 2.0 ||
        CGRectGetHeight(playerLayer.bounds) <= 2.0) {
        return NO;
    }

    CGRect videoRect = playerLayer.videoRect;
    if (CGRectGetWidth(videoRect) <= 1.0 ||
        CGRectGetHeight(videoRect) <= 1.0) {
        return NO;
    }

    CALayer *cursor = playerLayer.superlayer;

    while (cursor) {
        if (cursor.hidden || cursor.opacity < 0.02) {
            return NO;
        }
        cursor = cursor.superlayer;
    }

    id delegate = playerLayer.delegate;
    if ([delegate isKindOfClass:[UIView class]]) {
        return MSHViewIsActuallyVisible((UIView *)delegate);
    }

    if (!window) {
        return NO;
    }

    @try {
        CGRect rectInWindowLayer = [playerLayer convertRect:playerLayer.bounds toLayer:window.layer];

        if (CGRectIsEmpty(rectInWindowLayer) ||
            CGRectIsNull(rectInWindowLayer) ||
            !CGRectIntersectsRect(rectInWindowLayer, window.layer.bounds)) {
            return NO;
        }

        CGRect intersection = CGRectIntersection(rectInWindowLayer, window.layer.bounds);
        return CGRectGetWidth(intersection) > 2.0 &&
               CGRectGetHeight(intersection) > 2.0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static AVPlayerLayer *MSHFindVisiblePlayerLayerInLayer(CALayer *layer,
                                                       AVPlayer *player,
                                                       UIWindow *window) {
    if (!layer || layer.hidden || layer.opacity < 0.02) {
        return nil;
    }

    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *playerLayer = (AVPlayerLayer *)layer;

        if (playerLayer.player == player &&
            MSHPlayerLayerIsActuallyVisible(playerLayer, window)) {
            return playerLayer;
        }
    }

    for (CALayer *sublayer in layer.sublayers) {
        AVPlayerLayer *found = MSHFindVisiblePlayerLayerInLayer(sublayer, player, window);
        if (found) {
            return found;
        }
    }

    return nil;
}

static AVPlayerLayer *MSHFindVisiblePlayerLayer(AVPlayer *player) {
    if (!player) {
        return nil;
    }

    for (UIWindow *window in MSHForegroundWindows()) {
        AVPlayerLayer *found = MSHFindVisiblePlayerLayerInLayer(window.layer, player, window);
        if (found) {
            return found;
        }
    }

    return nil;
}

@interface MSHProgressManager : NSObject <UIGestureRecognizerDelegate>

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *lastPlayerItem;
@property (nonatomic, weak) AVPlayerLayer *visiblePlayerLayer;
@property (nonatomic, strong) id periodicTimeObserver;
@property (nonatomic, strong) NSTimer *refreshTimer;

@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) MSHProgressSlider *slider;
@property (nonatomic, strong) UILabel *currentLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, strong) UITapGestureRecognizer *screenTapGesture;

@property (nonatomic, assign) BOOL userTracking;
@property (nonatomic, assign) BOOL userHidden;
@property (nonatomic, assign) BOOL videoWasVisible;

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
        [self updateProgress];
    }
}

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.30
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

- (void)notePlayer:(AVPlayer *)player {
    if (!player) {
        return;
    }

    if (![NSThread isMainThread]) {
        __weak AVPlayer *weakPlayer = player;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self notePlayer:weakPlayer];
        });

        return;
    }

    if (player != self.player) {
        [self bindPlayer:player];
    }

    [self refreshNow];
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
    self.lastPlayerItem = nil;
    self.visiblePlayerLayer = nil;
    self.userTracking = NO;
    self.userHidden = NO;
    self.videoWasVisible = NO;

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
        currentLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0
                                                            weight:UIFontWeightMedium];
        currentLabel.textColor = UIColor.whiteColor;
        currentLabel.textAlignment = NSTextAlignmentLeft;
        currentLabel.text = @"0:00";

        UILabel *durationLabel = [UILabel new];
        durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0
                                                             weight:UIFontWeightMedium];
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

        UITapGestureRecognizer *sliderTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(sliderTapped:)];

        sliderTap.cancelsTouchesInView = NO;
        [slider addGestureRecognizer:sliderTap];

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

        if (self.screenTapGesture && self.hostWindow) {
            [self.hostWindow removeGestureRecognizer:self.screenTapGesture];
        }

        [window addSubview:self.barContainer];

        NSLayoutConstraint *bottom =
            [self.barContainer.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                                                           constant:-64.0];

        [NSLayoutConstraint activateConstraints:@[
            [self.barContainer.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor
                                                            constant:14.0],
            [self.barContainer.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor
                                                             constant:-14.0],
            [self.barContainer.heightAnchor constraintEqualToConstant:44.0],
            bottom
        ]];

        self.bottomConstraint = bottom;
        self.hostWindow = window;

        UITapGestureRecognizer *screenTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(screenTapped:)];

        screenTap.delegate = self;
        screenTap.cancelsTouchesInView = NO;
        screenTap.delaysTouchesBegan = NO;
        screenTap.delaysTouchesEnded = NO;

        [window addGestureRecognizer:screenTap];
        self.screenTapGesture = screenTap;
    }

    BOOL landscape = CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds);
    self.bottomConstraint.constant = landscape ? -18.0 : -64.0;

    [window bringSubviewToFront:self.barContainer];
}

- (NSString *)timeString:(double)seconds {
    if (!isfinite(seconds) || seconds < 0.0) {
        seconds = 0.0;
    }

    NSInteger wholeSeconds = (NSInteger)floor(seconds);
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

- (void)setBarVisible:(BOOL)visible {
    if (!self.barContainer) {
        return;
    }

    self.barContainer.hidden = !visible;

    if (visible && self.hostWindow) {
        [self.hostWindow bringSubviewToFront:self.barContainer];
    }
}

- (BOOL)videoIsActuallyVisible {
    AVPlayer *player = self.player;

    if (!player || !MSHPlayerItemIsUsableVideo(player)) {
        self.visiblePlayerLayer = nil;
        return NO;
    }

    AVPlayerLayer *visibleLayer = MSHFindVisiblePlayerLayer(player);

    if (!visibleLayer) {
        self.visiblePlayerLayer = nil;
        return NO;
    }

    self.visiblePlayerLayer = visibleLayer;
    return YES;
}

- (void)refreshNow {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        self.videoWasVisible = NO;
        [self setBarVisible:NO];
        return;
    }

    AVPlayer *player = self.player;

    if (!player) {
        self.videoWasVisible = NO;
        [self setBarVisible:NO];
        return;
    }

    AVPlayerItem *currentItem = player.currentItem;

    if (currentItem != self.lastPlayerItem) {
        self.lastPlayerItem = currentItem;
        self.userHidden = NO;
        self.userTracking = NO;
    }

    BOOL visibleVideo = [self videoIsActuallyVisible];

    if (!visibleVideo) {
        self.videoWasVisible = NO;
        [self setBarVisible:NO];
        return;
    }

    if (!self.videoWasVisible) {
        self.videoWasVisible = YES;
        self.userHidden = NO;
    }

    UIWindow *window = MSHBestWindow();

    if (!window) {
        [self setBarVisible:NO];
        return;
    }

    [self ensureBarInWindow:window];
    [self updateProgress];

    [self setBarVisible:!self.userHidden];
}

- (void)updateProgress {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;

    if (!player || !item || !MSHPlayerItemIsUsableVideo(player)) {
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
            [strongSelf updateProgress];
        });
    }];
}

- (void)sliderTouchDown:(UISlider *)slider {
    self.userTracking = YES;
}

- (void)sliderValueChanged:(UISlider *)slider {
    self.userTracking = YES;
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

- (void)screenTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }

    if (![self videoIsActuallyVisible]) {
        return;
    }

    self.userHidden = !self.userHidden;
    [self setBarVisible:!self.userHidden];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    UIView *touchedView = touch.view;

    if (!touchedView) {
        return YES;
    }

    if (self.barContainer &&
        [touchedView isDescendantOfView:self.barContainer]) {
        return NO;
    }

    if ([touchedView isKindOfClass:[UIControl class]]) {
        return NO;
    }

    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig(player);

    if (player) {
        [[MSHProgressManager sharedManager] notePlayer:player];
    }
}

%end

%hook AVPlayerViewController

- (void)setPlayer:(AVPlayer *)player {
    %orig(player);

    if (player) {
        [[MSHProgressManager sharedManager] notePlayer:player];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (self.player) {
        [[MSHProgressManager sharedManager] notePlayer:self.player];
    }
}

%end

%hook AVPlayer

- (void)play {
    %orig;
    [[MSHProgressManager sharedManager] notePlayer:self];
}

- (void)pause {
    %orig;
    [[MSHProgressManager sharedManager] notePlayer:self];
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig(item);

    if (item) {
        [[MSHProgressManager sharedManager] notePlayer:self];
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
