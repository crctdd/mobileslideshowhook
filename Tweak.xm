#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
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

static BOOL MSHPlayerItemHasUsableDuration(AVPlayer *player) {
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
    return presentationSize.width > 1.0 && presentationSize.height > 1.0;
}

static BOOL MSHObjectLooksLikeLivePhotoHost(id object) {
    if (!object) {
        return NO;
    }

    NSString *className = NSStringFromClass([object class]);
    return [className rangeOfString:@"LivePhoto"
                            options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL MSHViewBelongsToLivePhoto(UIView *view) {
    UIResponder *responder = view;
    NSUInteger depth = 0;

    /*
     * Public PHLivePhotoView and Photos' private Live Photo containers all
     * contain "LivePhoto" in their class names on the supported releases.
     * Walking the responder chain also catches the private view controller
     * when the AVPlayerLayer's immediate delegate is only a helper view.
     */
    while (responder && depth < 64) {
        if (MSHObjectLooksLikeLivePhotoHost(responder)) {
            return YES;
        }

        responder = responder.nextResponder;
        depth++;
    }

    return NO;
}

static BOOL MSHLayerBelongsToLivePhoto(CALayer *layer) {
    CALayer *cursor = layer;
    NSUInteger depth = 0;

    while (cursor && depth < 128) {
        if (MSHObjectLooksLikeLivePhotoHost(cursor)) {
            return YES;
        }

        id delegate = cursor.delegate;

        if (MSHObjectLooksLikeLivePhotoHost(delegate) ||
            ([delegate isKindOfClass:[UIView class]] &&
             MSHViewBelongsToLivePhoto((UIView *)delegate))) {
            return YES;
        }

        cursor = cursor.superlayer;
        depth++;
    }

    return NO;
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

static BOOL MSHViewAndAncestorsAreVisible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha < 0.08) {
        return NO;
    }

    UIView *cursor = view.superview;

    while (cursor) {
        if (cursor.hidden || cursor.alpha < 0.08) {
            return NO;
        }

        cursor = cursor.superview;
    }

    CGRect rectInWindow = [view convertRect:view.bounds toView:view.window];

    if (CGRectIsEmpty(rectInWindow) ||
        CGRectIsNull(rectInWindow) ||
        !CGRectIntersectsRect(rectInWindow, view.window.bounds)) {
        return NO;
    }

    CGRect intersection = CGRectIntersection(rectInWindow, view.window.bounds);

    return CGRectGetWidth(intersection) > 20.0 &&
           CGRectGetHeight(intersection) > 20.0;
}

static BOOL MSHClassNameLooksLikePhotosChrome(UIView *view) {
    NSString *className = NSStringFromClass(view.class);

    if (className.length == 0) {
        return NO;
    }

    NSArray<NSString *> *tokens = @[
        @"NavigationBar",
        @"Toolbar",
        @"Chrome",
        @"Scrubber",
        @"Accessory",
        @"PlaybackControl",
        @"ControlBar"
    ];

    for (NSString *token in tokens) {
        if ([className rangeOfString:token
                            options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

static BOOL MSHPhotosChromeVisibleInView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.08) {
        return NO;
    }

    BOOL candidate = NO;

    if ([view isKindOfClass:[UINavigationBar class]] ||
        [view isKindOfClass:[UIToolbar class]]) {
        candidate = YES;
    } else if (MSHClassNameLooksLikePhotosChrome(view)) {
        CGRect bounds = view.bounds;

        /*
         * Ignore tiny helper views whose class name happens to contain
         * a chrome-related token.
         */
        if (CGRectGetWidth(bounds) > 80.0 &&
            CGRectGetHeight(bounds) > 20.0) {
            candidate = YES;
        }
    }

    if (candidate && MSHViewAndAncestorsAreVisible(view)) {
        return YES;
    }

    for (UIView *subview in view.subviews) {
        if (MSHPhotosChromeVisibleInView(subview)) {
            return YES;
        }
    }

    return NO;
}

static BOOL MSHPhotosChromeIsVisibleInWindow(UIWindow *window) {
    return window && MSHPhotosChromeVisibleInView(window);
}

typedef struct {
    BOOL found;
    BOOL visible;
} MSHPlaybackChromeState;

static BOOL MSHClassNameLooksLikePlaybackChrome(UIView *view) {
    NSString *className = NSStringFromClass(view.class);

    if (className.length == 0) {
        return NO;
    }

    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        tokens = @[
            @"Scrubber",
            @"Filmstrip",
            @"Timeline",
            @"PlaybackControl",
            @"PlayerControl",
            @"VideoControl",
            @"TransportControl",
            @"ControlBar"
        ];
    });

    for (NSString *token in tokens) {
        if ([className rangeOfString:token
                            options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

static void MSHFindPlaybackChromeState(UIView *view,
                                       UIView *excludedRoot,
                                       MSHPlaybackChromeState *state) {
    if (!view || view == excludedRoot || state->visible) {
        return;
    }

    BOOL candidate =
        MSHClassNameLooksLikePlaybackChrome(view) ||
        ([view isKindOfClass:[UISlider class]] &&
         ![view isKindOfClass:[MSHProgressSlider class]]);

    if (candidate) {
        state->found = YES;

        CGRect bounds = view.bounds;

        if (CGRectGetWidth(bounds) > 80.0 &&
            CGRectGetHeight(bounds) > 8.0 &&
            MSHViewAndAncestorsAreVisible(view)) {
            state->visible = YES;
            return;
        }
    }

    for (UIView *subview in view.subviews) {
        MSHFindPlaybackChromeState(subview, excludedRoot, state);

        if (state->visible) {
            return;
        }
    }
}

static MSHPlaybackChromeState MSHPlaybackChromeStateInWindow(
    UIWindow *window,
    UIView *excludedRoot) {
    MSHPlaybackChromeState state = { NO, NO };

    if (window) {
        MSHFindPlaybackChromeState(window, excludedRoot, &state);
    }

    return state;
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

    return CGRectGetWidth(intersection) > 2.0 &&
           CGRectGetHeight(intersection) > 2.0;
}

static BOOL MSHLayerIsActuallyVisible(AVPlayerLayer *playerLayer,
                                      UIWindow *window,
                                      CGFloat *visibleAreaOut) {
    if (!playerLayer ||
        !window ||
        !playerLayer.player ||
        !MSHPlayerItemHasUsableDuration(playerLayer.player) ||
        MSHLayerBelongsToLivePhoto(playerLayer) ||
        playerLayer.hidden ||
        playerLayer.opacity < 0.02 ||
        !playerLayer.superlayer) {
        return NO;
    }

    CGFloat width = CGRectGetWidth(playerLayer.bounds);
    CGFloat height = CGRectGetHeight(playerLayer.bounds);

    if (width <= 40.0 || height <= 40.0) {
        return NO;
    }

    CALayer *cursor = playerLayer;

    while (cursor) {
        if (cursor.hidden || cursor.opacity < 0.02) {
            return NO;
        }

        if (cursor == window.layer) {
            break;
        }

        cursor = cursor.superlayer;
    }

    /* Never convert coordinates between unrelated window layer trees. */
    if (cursor != window.layer) {
        return NO;
    }

    id delegate = playerLayer.delegate;

    if ([delegate isKindOfClass:[UIView class]] &&
        !MSHViewIsActuallyVisible((UIView *)delegate)) {
        return NO;
    }

    CGRect rectInWindowLayer;

    @try {
        rectInWindowLayer = [playerLayer convertRect:playerLayer.bounds
                                             toLayer:window.layer];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    if (CGRectIsEmpty(rectInWindowLayer) ||
        CGRectIsNull(rectInWindowLayer) ||
        !CGRectIntersectsRect(rectInWindowLayer, window.layer.bounds)) {
        return NO;
    }

    CGRect intersection =
        CGRectIntersection(rectInWindowLayer, window.layer.bounds);

    CGFloat visibleWidth = CGRectGetWidth(intersection);
    CGFloat visibleHeight = CGRectGetHeight(intersection);
    CGFloat visibleArea = visibleWidth * visibleHeight;
    CGFloat layerRectArea =
        fabs(CGRectGetWidth(rectInWindowLayer) *
             CGRectGetHeight(rectInWindowLayer));

    /*
     * Photos may keep neighbouring video players alive while paging.
     * Compare the visible area with the player layer itself, not the whole
     * window. A portrait video in landscape (and vice versa) legitimately
     * occupies much less than 35% of the screen because of letterboxing.
     */
    if (visibleWidth < 100.0 ||
        visibleHeight < 100.0 ||
        visibleArea < 30000.0 ||
        layerRectArea <= 1.0 ||
        (visibleArea / layerRectArea) < 0.65) {
        return NO;
    }

    if (visibleAreaOut) {
        *visibleAreaOut = visibleArea;
    }

    return YES;
}

static void MSHFindBestVisiblePlayerLayerRecursive(CALayer *layer,
                                                    UIWindow *window,
                                                    AVPlayerLayer **bestLayer,
                                                    CGFloat *bestArea) {
    if (!layer || layer.hidden || layer.opacity < 0.02) {
        return;
    }

    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *playerLayer = (AVPlayerLayer *)layer;
        CGFloat visibleArea = 0.0;

        if (MSHLayerIsActuallyVisible(playerLayer, window, &visibleArea) &&
            visibleArea > *bestArea) {
            *bestArea = visibleArea;
            *bestLayer = playerLayer;
        }
    }

    for (CALayer *sublayer in layer.sublayers) {
        MSHFindBestVisiblePlayerLayerRecursive(sublayer,
                                               window,
                                               bestLayer,
                                               bestArea);
    }
}

static AVPlayerLayer *MSHFindBestVisiblePlayerLayer(
    AVPlayerLayer *preferredLayer,
    UIWindow **selectedWindowOut) {
    AVPlayerLayer *bestLayer = nil;
    UIWindow *bestWindow = nil;
    CGFloat bestArea = 0.0;
    UIWindow *preferredWindow = nil;
    CGFloat preferredArea = 0.0;

    for (UIWindow *window in MSHForegroundWindows()) {
        CGFloat areaBefore = bestArea;

        MSHFindBestVisiblePlayerLayerRecursive(window.layer,
                                               window,
                                               &bestLayer,
                                               &bestArea);

        if (bestArea > areaBefore) {
            bestWindow = window;
        }

        if (preferredLayer && preferredArea <= 0.0) {
            CGFloat area = 0.0;

            if (MSHLayerIsActuallyVisible(preferredLayer, window, &area)) {
                preferredArea = area;
                preferredWindow = window;
            }
        }
    }

    /*
     * Photos may keep two page players partially visible during transitions.
     * Preserve the current player while it is effectively tied for largest;
     * otherwise tiny layout changes make the slider jump between timelines.
     */
    if (preferredLayer && preferredWindow &&
        preferredArea >= (bestArea * 0.85)) {
        if (selectedWindowOut) {
            *selectedWindowOut = preferredWindow;
        }

        return preferredLayer;
    }

    if (selectedWindowOut) {
        *selectedWindowOut = bestWindow;
    }

    return bestLayer;
}

@interface MSHProgressManager : NSObject <UIGestureRecognizerDelegate>

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *lastPlayerItem;
@property (nonatomic, weak) AVPlayerLayer *visiblePlayerLayer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) CADisplayLink *displayLink;

@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) MSHProgressSlider *slider;
@property (nonatomic, strong) UILabel *currentLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *hostConstraints;
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPanGesture;
@property (nonatomic, strong) UITapGestureRecognizer *screenTapGesture;
@property (nonatomic, assign) BOOL userTracking;
@property (nonatomic, assign) BOOL videoWasVisible;
@property (nonatomic, assign) BOOL refreshScheduled;
@property (nonatomic, assign) BOOL dismissGestureActive;
@property (nonatomic, assign) NSUInteger dismissGestureSession;
@property (nonatomic, assign) NSUInteger screenTapSession;
@property (nonatomic, assign) BOOL landscapeUserHidden;
@property (nonatomic, assign) BOOL lastLayoutWasLandscape;
@property (nonatomic, assign) double lastRenderedTime;
@property (nonatomic, assign) BOOL scrubSeekInFlight;
@property (nonatomic, assign) BOOL scrubSeekPending;
@property (nonatomic, assign) BOOL scrubEnding;
@property (nonatomic, assign) BOOL resumeAfterScrub;
@property (nonatomic, assign) double pendingScrubTime;
@property (nonatomic, assign) NSUInteger scrubSession;

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
            [self startDisplayLink];
            [self startRefreshTimer];
            [self refreshNow];
        });
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopRefreshTimer];
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self bindPlayer:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startDisplayLink];
        [self startRefreshTimer];
        [self refreshNow];
    });
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopRefreshTimer];
        self.displayLink.paused = YES;
        self.dismissGestureSession++;
        self.screenTapSession++;
        self.dismissGestureActive = NO;
        self.barContainer.transform = CGAffineTransformIdentity;
        self.barContainer.alpha = 1.0;
        [self bindPlayer:nil];
        [self setBarVisible:NO];
    });
}

- (void)playerItemEnded:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    id endedItem = notification.object;

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;

        if (strongSelf && endedItem == strongSelf.player.currentItem) {
            [strongSelf updateProgress];
            strongSelf.displayLink.paused = YES;
        }
    });
}

- (void)startDisplayLink {
    if (self.displayLink) {
        return;
    }

    CADisplayLink *displayLink =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(displayLinkFired:)];
    displayLink.preferredFramesPerSecond = 60;
    displayLink.paused = YES;
    [displayLink addToRunLoop:NSRunLoop.mainRunLoop
                      forMode:NSRunLoopCommonModes];
    self.displayLink = displayLink;
}

- (void)displayLinkFired:(CADisplayLink *)displayLink {
    if (!self.player || self.barContainer.hidden) {
        displayLink.paused = YES;
        return;
    }

    [self updateProgress];

    if (self.player.rate == 0.0f && !self.userTracking) {
        displayLink.paused = YES;
    }
}

- (void)startRefreshTimer {
    if (self.refreshTimer) {
        return;
    }

    /*
     * This timer actively scans the visible layer tree.
     * It fixes the old behaviour where the tweak sometimes waited until
     * the stock Photos scrubber was touched before discovering AVPlayer.
     */
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.40
                                             target:self
                                           selector:@selector(refreshTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.refreshTimer = timer;
}

- (void)stopRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer {
    [self refreshNow];
}

- (void)requestRefresh {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestRefresh];
        });

        return;
    }

    /*
     * Hooks are only a wake-up hint. Never bind or walk UIKit synchronously
     * from an AVFoundation call stack; doing so caused re-entrant layer-tree
     * access and could also select a Live Photo's private AVPlayer.
     */
    if (self.refreshScheduled) {
        return;
    }

    self.refreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.refreshScheduled = NO;
        [self refreshNow];
    });
}

- (void)bindPlayer:(AVPlayer *)player {
    if (self.player == player) {
        return;
    }

    self.player = player;
    self.lastPlayerItem = nil;
    self.userTracking = NO;
    self.lastRenderedTime = NAN;
    self.scrubSession++;
    self.scrubSeekInFlight = NO;
    self.scrubSeekPending = NO;
    self.scrubEnding = NO;
    self.resumeAfterScrub = NO;
    self.landscapeUserHidden = NO;

    if (!player) {
        self.displayLink.paused = YES;
        [self setBarVisible:NO];
        return;
    }
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
        container.backgroundColor =
            [UIColor.blackColor colorWithAlphaComponent:0.46];

        UILabel *currentLabel = [UILabel new];
        currentLabel.translatesAutoresizingMaskIntoConstraints = NO;
        currentLabel.font =
            [UIFont monospacedDigitSystemFontOfSize:11.0
                                             weight:UIFontWeightMedium];
        currentLabel.textColor = UIColor.whiteColor;
        currentLabel.textAlignment = NSTextAlignmentLeft;
        currentLabel.text = @"0:00";

        UILabel *durationLabel = [UILabel new];
        durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        durationLabel.font =
            [UIFont monospacedDigitSystemFontOfSize:11.0
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
        slider.maximumTrackTintColor =
            [UIColor.whiteColor colorWithAlphaComponent:0.32];
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
            [currentLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                                       constant:12.0],
            [currentLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [currentLabel.widthAnchor constraintEqualToConstant:42.0],

            [durationLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                                         constant:-12.0],
            [durationLabel.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [durationLabel.widthAnchor constraintEqualToConstant:42.0],

            [slider.leadingAnchor constraintEqualToAnchor:currentLabel.trailingAnchor
                                                 constant:6.0],
            [slider.trailingAnchor constraintEqualToAnchor:durationLabel.leadingAnchor
                                                  constant:-6.0],
            [slider.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [slider.heightAnchor constraintEqualToConstant:32.0]
        ]];

        self.barContainer = container;
        self.slider = slider;
        self.currentLabel = currentLabel;
        self.durationLabel = durationLabel;
    }

    if (self.barContainer.superview != window) {
        if (self.dismissPanGesture && self.hostWindow) {
            [self.hostWindow removeGestureRecognizer:self.dismissPanGesture];
            self.dismissPanGesture = nil;
            self.dismissGestureSession++;
            self.dismissGestureActive = NO;
            self.barContainer.transform = CGAffineTransformIdentity;
            self.barContainer.alpha = 1.0;
        }

        if (self.screenTapGesture && self.hostWindow) {
            [self.hostWindow removeGestureRecognizer:self.screenTapGesture];
            self.screenTapGesture = nil;
            self.screenTapSession++;
        }

        if (self.hostConstraints.count > 0) {
            [NSLayoutConstraint deactivateConstraints:self.hostConstraints];
            self.hostConstraints = nil;
        }

        [self.barContainer removeFromSuperview];
        [window addSubview:self.barContainer];

        /*
         * Keep the custom bar above Photos' stock scrubber.
         * Portrait: 118 pt above safe-area bottom
         * Landscape: 56 pt above safe-area bottom
         */
        NSLayoutConstraint *bottom =
            [self.barContainer.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor
                                                           constant:-118.0];

        NSArray<NSLayoutConstraint *> *constraints = @[
            [self.barContainer.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor
                                                            constant:14.0],
            [self.barContainer.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor
                                                             constant:-14.0],
            [self.barContainer.heightAnchor constraintEqualToConstant:44.0],
            bottom
        ];
        [NSLayoutConstraint activateConstraints:constraints];

        self.bottomConstraint = bottom;
        self.hostConstraints = constraints;
        self.hostWindow = window;
    }

    if (!self.dismissPanGesture) {
        UIPanGestureRecognizer *dismissPan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(dismissPanChanged:)];
        dismissPan.delegate = self;
        dismissPan.cancelsTouchesInView = NO;
        dismissPan.delaysTouchesBegan = NO;
        dismissPan.delaysTouchesEnded = NO;
        [window addGestureRecognizer:dismissPan];
        self.dismissPanGesture = dismissPan;
    }

    if (!self.screenTapGesture) {
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

    BOOL landscape =
        CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds);

    self.bottomConstraint.constant = landscape ? -56.0 : -118.0;

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
    self.displayLink.paused = !visible || !self.player || self.userTracking;

    if (visible && self.hostWindow) {
        [self.hostWindow bringSubviewToFront:self.barContainer];
    }
}

- (void)refreshNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshNow];
        });
        return;
    }

    if (UIApplication.sharedApplication.applicationState !=
        UIApplicationStateActive) {
        self.videoWasVisible = NO;
        self.visiblePlayerLayer = nil;
        [self bindPlayer:nil];
        [self setBarVisible:NO];
        return;
    }

    /*
     * Actively find the largest real AVPlayerLayer currently visible.
     * This does not depend on the stock Photos timeline being touched first.
     */
    UIWindow *playerWindow = nil;
    AVPlayerLayer *visibleLayer =
        MSHFindBestVisiblePlayerLayer(self.visiblePlayerLayer, &playerWindow);

    if (!visibleLayer ||
        !playerWindow ||
        !visibleLayer.player ||
        !MSHPlayerItemHasUsableDuration(visibleLayer.player)) {
        self.videoWasVisible = NO;
        self.visiblePlayerLayer = nil;
        [self bindPlayer:nil];
        [self setBarVisible:NO];
        return;
    }

    self.visiblePlayerLayer = visibleLayer;

    AVPlayer *visiblePlayer = visibleLayer.player;

    if (visiblePlayer != self.player) {
        [self bindPlayer:visiblePlayer];
    }

    AVPlayerItem *currentItem = visiblePlayer.currentItem;

    if (currentItem != self.lastPlayerItem) {
        self.lastPlayerItem = currentItem;
        self.userTracking = NO;
        self.lastRenderedTime = NAN;
        self.landscapeUserHidden = NO;
    }

    if (!self.videoWasVisible) {
        self.videoWasVisible = YES;
    }

    [self ensureBarInWindow:playerWindow];
    [self updateProgress];

    /* Follow the native Photos playback chrome whenever it can be found. */
    BOOL landscape =
        CGRectGetWidth(playerWindow.bounds) > CGRectGetHeight(playerWindow.bounds);

    if (landscape != self.lastLayoutWasLandscape) {
        self.lastLayoutWasLandscape = landscape;
        self.landscapeUserHidden = NO;
    }

    MSHPlaybackChromeState chromeState =
        MSHPlaybackChromeStateInWindow(playerWindow, self.barContainer);
    BOOL shouldShowBar;

    if (chromeState.found) {
        shouldShowBar = chromeState.visible;
        self.landscapeUserHidden = !chromeState.visible;
    } else {
        shouldShowBar = landscape
            ? !self.landscapeUserHidden
            : MSHPhotosChromeIsVisibleInWindow(playerWindow);
    }

    if (!self.dismissGestureActive) {
        [self setBarVisible:shouldShowBar];
    }
}

- (void)screenTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded ||
        !self.videoWasVisible ||
        self.dismissGestureActive ||
        !self.hostWindow) {
        return;
    }

    self.screenTapSession++;
    NSUInteger tapSession = self.screenTapSession;
    NSUInteger dismissSession = self.dismissGestureSession;

    /* Let Photos apply its own tap state first, then mirror the real chrome. */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (tapSession != self.screenTapSession ||
            dismissSession != self.dismissGestureSession ||
            !self.videoWasVisible ||
            self.dismissGestureActive ||
            !self.hostWindow) {
            return;
        }

        MSHPlaybackChromeState chromeState =
            MSHPlaybackChromeStateInWindow(self.hostWindow,
                                           self.barContainer);
        BOOL landscape =
            CGRectGetWidth(self.hostWindow.bounds) >
            CGRectGetHeight(self.hostWindow.bounds);

        if (chromeState.found) {
            self.landscapeUserHidden = !chromeState.visible;
            [self setBarVisible:chromeState.visible];
        } else if (landscape) {
            self.landscapeUserHidden = !self.landscapeUserHidden;
            [self setBarVisible:!self.landscapeUserHidden];
        } else {
            [self refreshNow];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (tapSession == self.screenTapSession &&
                dismissSession == self.dismissGestureSession) {
                [self refreshNow];
            }
        });
    });
}

- (void)dismissPanChanged:(UIPanGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.dismissGestureSession++;
            self.dismissGestureActive = YES;
            self.barContainer.transform = CGAffineTransformIdentity;
            self.barContainer.alpha = 1.0;
            break;

        case UIGestureRecognizerStateChanged: {
            if (self.dismissGestureActive) {
                CGFloat translationY =
                    MAX(0.0, [gesture translationInView:self.hostWindow].y);
                CGFloat travel =
                    MAX(120.0, CGRectGetHeight(self.hostWindow.bounds) * 0.35);
                CGFloat progress = MIN(translationY / travel, 1.0);
                CGFloat scale = 1.0 - (0.08 * progress);
                CGAffineTransform transform =
                    CGAffineTransformMakeTranslation(0.0, translationY);

                self.barContainer.transform =
                    CGAffineTransformScale(transform, scale, scale);
                self.barContainer.alpha = 1.0 - (0.65 * progress);
            }
            break;
        }

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            NSUInteger session = self.dismissGestureSession;

            [UIView animateWithDuration:0.20
                             animations:^{
                self.barContainer.transform = CGAffineTransformIdentity;
                self.barContainer.alpha = 1.0;
            } completion:^(__unused BOOL finished) {
                if (session != self.dismissGestureSession) {
                    return;
                }

                self.dismissGestureActive = NO;
                [self requestRefresh];
            }];
            break;
        }

        case UIGestureRecognizerStateEnded: {
            NSUInteger session = self.dismissGestureSession;

            [self setBarVisible:NO];
            self.barContainer.transform = CGAffineTransformIdentity;
            self.barContainer.alpha = 1.0;

            /*
             * Keep the bar hidden through Photos' short completion animation.
             * If the dismissal was cancelled, the refresh restores it once
             * the video has settled back into place.
             */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (session != self.dismissGestureSession) {
                    return;
                }

                self.dismissGestureActive = NO;
                [self refreshNow];
            });
            break;
        }

        default:
            break;
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.screenTapGesture) {
        if (!self.videoWasVisible ||
            self.dismissGestureActive ||
            !self.hostWindow) {
            return NO;
        }

        return YES;
    }

    if (gestureRecognizer != self.dismissPanGesture) {
        return YES;
    }

    if (!self.videoWasVisible || self.barContainer.hidden) {
        return NO;
    }

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:self.hostWindow];

    return velocity.y > 0.0 &&
           velocity.y > (fabs(velocity.x) * 0.75);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.dismissPanGesture &&
        gestureRecognizer != self.screenTapGesture) {
        return YES;
    }

    UIView *touchedView = touch.view;

    if (!touchedView) {
        return YES;
    }

    if (self.barContainer &&
        [touchedView isDescendantOfView:self.barContainer]) {
        return NO;
    }

    return ![touchedView isKindOfClass:[UIControl class]];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return gestureRecognizer == self.dismissPanGesture ||
           otherGestureRecognizer == self.dismissPanGesture ||
           gestureRecognizer == self.screenTapGesture ||
           otherGestureRecognizer == self.screenTapGesture;
}

- (void)updateProgress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateProgress];
        });
        return;
    }

    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;

    if (!player || !item || !MSHPlayerItemHasUsableDuration(player)) {
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

    if (fabs(self.slider.minimumValue) > 0.001f) {
        self.slider.minimumValue = 0.0f;
    }

    if (fabs((double)self.slider.maximumValue - duration) > 0.01) {
        self.slider.maximumValue = (float)duration;
    }

    if (!self.userTracking) {
        /* Ignore tiny backwards clock corrections while playing forward. */
        if (player.rate > 0.0f && isfinite(self.lastRenderedTime) &&
            current < self.lastRenderedTime &&
            (self.lastRenderedTime - current) < 0.25) {
            current = self.lastRenderedTime;
        }

        [self.slider setValue:(float)current animated:NO];
        NSString *currentText = [self timeString:current];

        if (![self.currentLabel.text isEqualToString:currentText]) {
            self.currentLabel.text = currentText;
        }

        self.lastRenderedTime = current;
    }

    NSString *durationText = [self timeString:duration];

    if (![self.durationLabel.text isEqualToString:durationText]) {
        self.durationLabel.text = durationText;
    }
}

- (void)beginScrubbing {
    AVPlayer *player = self.player;

    if (!player) {
        self.userTracking = NO;
        return;
    }

    self.scrubSession++;
    self.userTracking = YES;
    self.scrubSeekInFlight = NO;
    self.scrubSeekPending = NO;
    self.scrubEnding = NO;
    self.resumeAfterScrub = player.rate > 0.0f;
    self.displayLink.paused = YES;

    if (self.resumeAfterScrub) {
        [player pause];
    }
}

- (void)queueScrubSeekToSeconds:(double)seconds ending:(BOOL)ending {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;

    if (!player || !item || !self.userTracking) {
        return;
    }

    double duration = CMTimeGetSeconds(item.duration);

    if (!isfinite(seconds) || !isfinite(duration) || duration <= 0.0) {
        return;
    }

    self.pendingScrubTime = MIN(MAX(seconds, 0.0), duration);
    self.scrubSeekPending = YES;

    if (ending) {
        self.scrubEnding = YES;
    }

    [self performPendingScrubSeek];
}

- (void)performPendingScrubSeek {
    if (self.scrubSeekInFlight ||
        !self.scrubSeekPending ||
        !self.userTracking) {
        return;
    }

    AVPlayer *player = self.player;

    if (!player) {
        self.userTracking = NO;
        return;
    }

    double seconds = self.pendingScrubTime;
    BOOL exactSeek = self.scrubEnding;
    NSUInteger session = self.scrubSession;

    self.scrubSeekPending = NO;
    self.scrubSeekInFlight = YES;

    CMTime target = CMTimeMakeWithSeconds(seconds, 600);
    CMTime tolerance = exactSeek
        ? kCMTimeZero
        : CMTimeMakeWithSeconds(1.0 / 30.0, 600);

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

            if (session != strongSelf.scrubSession ||
                player != strongSelf.player) {
                return;
            }

            strongSelf.scrubSeekInFlight = NO;

            if (strongSelf.scrubSeekPending) {
                [strongSelf performPendingScrubSeek];
                return;
            }

            if (strongSelf.scrubEnding) {
                BOOL shouldResume = strongSelf.resumeAfterScrub;

                strongSelf.scrubEnding = NO;
                strongSelf.resumeAfterScrub = NO;
                strongSelf.userTracking = NO;
                strongSelf.lastRenderedTime = NAN;
                [strongSelf updateProgress];

                if (shouldResume) {
                    [player play];
                    strongSelf.displayLink.paused = NO;
                }
            }
        });
    }];
}

- (void)sliderTouchDown:(UISlider *)slider {
    [self beginScrubbing];
}

- (void)sliderValueChanged:(UISlider *)slider {
    if (!self.userTracking) {
        [self beginScrubbing];
    }

    self.currentLabel.text = [self timeString:slider.value];
    [self queueScrubSeekToSeconds:slider.value ending:NO];
}

- (void)sliderTouchEnded:(UISlider *)slider {
    [self queueScrubSeekToSeconds:slider.value ending:YES];
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

    if (!self.userTracking) {
        [self beginScrubbing];
    }

    self.slider.value = value;
    self.currentLabel.text = [self timeString:value];

    [self queueScrubSeekToSeconds:value ending:YES];
}


@end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    %orig(player);

    if (player) {
        [[MSHProgressManager sharedManager] requestRefresh];
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
