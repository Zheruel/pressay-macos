#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import <EventKit/EventKit.h>

// AppKit is confined to the main thread. Capture and inference never run here.
typedef void (*PressayInputCallback)(int event, int detail, void *context);
static const int64_t PressaySyntheticInput = 0x50524553534159;
static void onMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block(); else dispatch_async(dispatch_get_main_queue(), block);
}
int pressay_microphone_status(void) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized: return 1;
        case AVAuthorizationStatusDenied: case AVAuthorizationStatusRestricted: return 2;
        default: return 0;
    }
}
int pressay_accessibility_status(void) { return AXIsProcessTrusted() ? 1 : 2; }

@interface PressayPanel : NSPanel @end
@implementation PressayPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
// This guide becomes key only when clicked, so its Finder/Close controls remain
// keyboard accessible without activating Pressay when it first appears.
@interface PressayGuidePanel : PressayPanel @end
@implementation PressayGuidePanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end
@interface PressayBundleTile : NSView <NSDraggingSource> @end
@implementation PressayBundleTile
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"Pressay app. Drag into the Accessibility list in System Settings.";
        self.accessibilityHelp = @"Keyboard alternative: use Show in Finder, then the plus button in Accessibility.";
    }
    return self;
}
- (void)drawRect:(NSRect)rect {
    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:NSBundle.mainBundle.bundlePath];
    [icon drawInRect:NSMakeRect(12, 10, 44, 44)];
    [@"Drag Pressay into the list" drawAtPoint:NSMakePoint(68, 25) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor}];
}
- (void)mouseDown:(NSEvent *)event {
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    if (![bundle.pathExtension isEqualToString:@"app"]) return;
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:bundle];
    [item setDraggingFrame:NSMakeRect(12, 10, 44, 44)
                 contents:[[NSWorkspace sharedWorkspace] iconForFile:bundle.path]];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session { return YES; }
@end

@interface PressayNative : NSObject
@property CFMachPortRef tap;
@property CFRunLoopSourceRef source;
@property PressayInputCallback callback;
@property void *context;
@property uint16_t key;
@property BOOL pressed;
@property BOOL blockedUntilRelease;
@property BOOL busy;
@property BOOL reportedAvailable;
@property NSTimer *timer;
@property NSMutableArray *observers;
@property PressayPanel *guide;
@property int guideKind;
- (void)notify:(int)event detail:(int)detail;
- (void)stop;
- (BOOL)createTap;
- (BOOL)handle:(CGEventType)type event:(CGEventRef)event;
- (void)poll;
- (void)showGuide:(int)kind;
- (void)positionGuide;
- (void)stopMeeting;
@end
static PressayNative *native;
static PressayNative *instance(void) {
    if (!native) native = [PressayNative new];
    return native;
}
static uint64_t deviceMask(uint16_t key) {
    switch (key) {
        case 55: return 0x08; case 54: return 0x10;
        case 58: return 0x20; case 61: return 0x40;
        case 56: return 0x02; case 60: return 0x04;
        case 59: return 0x01; case 62: return 0x2000;
        default: return 0;
    }
}
static BOOL modifier(uint16_t key) { return deviceMask(key) != 0 || key == 63; }
static BOOL keyIsDown(uint16_t key) {
    if (key > 127) return NO;
    uint64_t mask = deviceMask(key);
    if (mask) return (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & mask) != 0;
    if (key == 63) return (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskSecondaryFn) != 0;
    return CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key);
}
static BOOL modifierDown(CGEventRef event, uint16_t key) {
    CGEventFlags flags = CGEventGetFlags(event);
    uint64_t mask = deviceMask(key);
    if (mask) return (flags & mask) != 0;
    return key == 63 && (flags & kCGEventFlagMaskSecondaryFn) != 0;
}
static CGEventRef inputEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    PressayNative *owner = (__bridge PressayNative *)context;
    return [owner handle:type event:event] ? NULL : event;
}
static NSTextField *textLabel(NSString *value, NSRect frame, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField wrappingLabelWithString:value];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = NSColor.labelColor;
    label.accessibilityLabel = value;
    return label;
}
extern void pressay_island_update(const char *, const char *, const float *);
extern void pressay_island_elapsed(double);
extern void pressay_island_shutdown(void);
typedef void (*PressayStopCallback)(void);
static PressayStopCallback stopMeetingCallback;
void pressay_set_stop_callback(PressayStopCallback callback) { onMain(^{ stopMeetingCallback = callback; }); }
@implementation PressayNative
- (void)stopMeeting { if (stopMeetingCallback) stopMeetingCallback(); }
- (void)notify:(int)event detail:(int)detail { if (self.callback) self.callback(event, detail, self.context); }
- (void)stop {
    if (self.pressed || self.busy) [self notify:3 detail:0];
    self.pressed = NO;
    self.busy = NO;
    if (self.tap) {
        CGEventTapEnable(self.tap, false);
        if (self.source) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
            CFRelease(self.source); self.source = NULL;
        }
        CFRelease(self.tap); self.tap = NULL;
    }
    [self.timer invalidate]; self.timer = nil;
    for (id observer in self.observers) [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:observer];
    self.observers = nil;
    self.callback = NULL; self.context = NULL;
    pressay_island_shutdown();
}
- (BOOL)createTap {
    if (self.tap) return CGEventTapIsEnabled(self.tap);
    // An active (filtering) tap needs only Accessibility, which applies to the
    // running process. Input Monitoring is never asked for: its preflight
    // answer is fixed at launch, so requiring it stranded fresh grants.
    if (!AXIsProcessTrusted()) return NO;
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    self.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                               mask, inputEvent, (__bridge void *)self);
    if (!self.tap) return NO;
    self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
    CGEventTapEnable(self.tap, true);
    return YES;
}
- (BOOL)handle:(CGEventType)type event:(CGEventRef)event {
    if (event && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == PressaySyntheticInput) return NO;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // A busy main thread disables the tap; that is not a user cancel, so never
        // abort in-flight work. Only a key-up lost meanwhile ends the hold.
        if (self.tap) CGEventTapEnable(self.tap, true);
        if (self.pressed && !keyIsDown(self.key)) { self.pressed = NO; [self notify:2 detail:0]; }
        return NO;
    }
    uint16_t key = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (type == kCGEventKeyDown && key == 53 && (self.busy || self.pressed)) {
        self.pressed = NO; self.blockedUntilRelease = YES;
        [self notify:3 detail:0];
        return YES;
    }
    if (key != self.key) return NO;
    // A modifier's state comes from the event's own flags, as in Hex. The
    // tap sees the event before the session state updates, so reading
    // CGEventSourceFlagsState here inverted press and release: recording
    // started on release and the next poll stopped it.
    BOOL down = modifier(key) ? modifierDown(event, key) : type == kCGEventKeyDown;
    if (modifier(key) && type != kCGEventFlagsChanged) return NO;
    if (!modifier(key) && type != kCGEventKeyDown && type != kCGEventKeyUp) return NO;
    if (!down) {
        BOOL consumed = self.pressed || self.blockedUntilRelease;
        self.blockedUntilRelease = NO;
        if (self.pressed) { self.pressed = NO; [self notify:2 detail:0]; }
        return consumed && !modifier(key);
    }
    if (self.blockedUntilRelease) return !modifier(key);
    if (!modifier(key) && !self.pressed && (CGEventGetFlags(event) & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate))) return NO;
    if (!self.pressed && !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
        self.pressed = YES; [self notify:1 detail:0];
    }
    return !modifier(key);
}
- (void)poll {
    BOOL allowed = AXIsProcessTrusted();
    if (!allowed && self.tap) {
        CGEventTapEnable(self.tap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
        CFRelease(self.source); self.source = NULL;
        CFRelease(self.tap); self.tap = NULL;
        self.pressed = NO; self.blockedUntilRelease = YES;
        [self notify:3 detail:0];
    }
    BOOL available = allowed && [self createTap];
    if (available != self.reportedAvailable) {
        self.reportedAvailable = available; [self notify:5 detail:available];
    }
    if (self.pressed && !keyIsDown(self.key)) { self.pressed = NO; [self notify:2 detail:0]; }
    if (self.blockedUntilRelease && !keyIsDown(self.key)) self.blockedUntilRelease = NO;
    if (self.guide.isVisible) {
        BOOL granted = self.guideKind == 0 ? pressay_microphone_status() == 1 : AXIsProcessTrusted();
        if (granted) [self.guide orderOut:nil]; else [self positionGuide];
    }
}
- (void)suspend {
    self.pressed = NO; self.blockedUntilRelease = YES; self.busy = NO;
    pressay_island_shutdown(); [self notify:4 detail:0];
}
- (void)showInFinder:(id)sender { [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]]; }
- (void)closeGuide:(id)sender { [self.guide orderOut:nil]; }
- (void)showGuide:(int)kind {
    self.guideKind = kind;
    if (!self.guide) {
        self.guide = [[PressayGuidePanel alloc] initWithContentRect:NSMakeRect(0, 0, 310, 330)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
        self.guide.titleVisibility = NSWindowTitleHidden; self.guide.titlebarAppearsTransparent = YES;
        self.guide.level = NSFloatingWindowLevel; self.guide.hidesOnDeactivate = NO;
        self.guide.releasedWhenClosed = NO;
        self.guide.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 310, 330)];
    NSString *title = kind == 0 ? @"Allow Microphone" : @"Allow Accessibility";
    NSString *detail = kind == 0 ? @"Enable the existing Pressay entry to hear your voice. Microphone access requires macOS’s permission prompt; dragging an app does not grant it."
        : @"Pressay needs this to notice your talk key and type your words. Drag the app below into the Accessibility list, then switch it on.";
    [content addSubview:textLabel(title, NSMakeRect(22, 264, 266, 34), 20, NSFontWeightSemibold)];
    [content addSubview:textLabel(detail, NSMakeRect(22, 160, 266, 92), 13, NSFontWeightRegular)];
    if (kind == 1 && [NSBundle.mainBundle.bundleURL.pathExtension isEqualToString:@"app"]) {
        [content addSubview:[[PressayBundleTile alloc] initWithFrame:NSMakeRect(22, 91, 266, 64)]];
        NSButton *finder = [NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(showInFinder:)];
        finder.frame = NSMakeRect(22, 54, 140, 28); [content addSubview:finder];
    } else if (kind == 1) {
        [content addSubview:textLabel(@"Build and launch Pressay.app to add its actual bundle.", NSMakeRect(22, 95, 266, 52), 12, NSFontWeightRegular)];
    }
    NSButton *close = [NSButton buttonWithTitle:@"Close guide" target:self action:@selector(closeGuide:)];
    close.frame = NSMakeRect(178, 18, 110, 28); [content addSubview:close];
    [content addSubview:textLabel(@"Waiting for approval…", NSMakeRect(22, 22, 158, 22), 11, NSFontWeightRegular)];
    self.guide.contentView = content;
    [self positionGuide];
    [self.guide orderFrontRegardless];
}
- (void)positionGuide {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect bounds = screen.visibleFrame;
    NSPoint origin = NSMakePoint(NSMaxX(bounds) - 330, NSMidY(bounds) - 165);
    NSArray<NSRunningApplication *> *settings = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.systempreferences"];
    if (settings.count) {
        // Public window metadata provides bounds without reading screen pixels.
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        for (NSDictionary *window in windows) {
            if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != settings.firstObject.processIdentifier
                || [window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
            CGRect rectangle;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &rectangle) || rectangle.size.width < 200) continue;
            CGFloat desktopTop = NSMaxY(NSScreen.screens.firstObject.frame);
            NSRect settingsFrame = NSMakeRect(rectangle.origin.x, desktopTop - CGRectGetMaxY(rectangle), rectangle.size.width, rectangle.size.height);
            for (NSScreen *candidate in NSScreen.screens) if (NSIntersectsRect(candidate.frame, settingsFrame)) { bounds = candidate.visibleFrame; break; }
            CGFloat right = NSMaxX(settingsFrame) + 12;
            CGFloat x = right + 310 <= NSMaxX(bounds) ? right : NSMinX(settingsFrame) - 322;
            origin = NSMakePoint(MAX(NSMinX(bounds) + 8, MIN(x, NSMaxX(bounds) - 318)),
                MAX(NSMinY(bounds) + 8, MIN(NSMaxY(settingsFrame) - 330, NSMaxY(bounds) - 338)));
            break;
        }
    }
    [self.guide setFrameOrigin:origin];
}

@end

void pressay_shortcuts_start(uint16_t key, PressayInputCallback callback, void *context) {
    onMain(^{
        PressayNative *owner = instance(); [owner stop];
        owner.key = key; owner.callback = callback; owner.context = context;
        owner.blockedUntilRelease = keyIsDown(key);
        owner.reportedAvailable = [owner createTap];
        [owner notify:5 detail:owner.reportedAvailable];
        owner.observers = [NSMutableArray new];
        for (NSNotificationName name in @[NSWorkspaceWillSleepNotification, NSWorkspaceScreensDidSleepNotification, NSWorkspaceSessionDidResignActiveNotification]) {
            id observer = [[NSWorkspace sharedWorkspace].notificationCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [owner suspend]; }];
            [owner.observers addObject:observer];
        }
        owner.timer = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) { (void)timer; [owner poll]; }];
        [[NSRunLoop mainRunLoop] addTimer:owner.timer forMode:NSRunLoopCommonModes];
    });
}
void pressay_shortcuts_busy(bool busy) { onMain(^{ instance().busy = busy; }); }
void pressay_shortcuts_stop(void) { onMain(^{ [instance() stop]; }); }
void pressay_open_permission(int kind) {
    onMain(^{
        if (kind == 0 && pressay_microphone_status() == 0) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if (!granted) onMain(^{ [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]]; [instance() showGuide:0]; });
            }];
            return;
        }
        NSString *anchor = kind == 0 ? @"Privacy_Microphone" : @"Privacy_Accessibility";
        if (kind == 1) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:anchor]]];
        [instance() showGuide:kind];
    });
}
// Menu bar panel backdrop: macOS 26's Liquid Glass (NSGlassEffectView), the
// material native menu bar extras use; the older menu blur where it is absent.
// It sits behind the transparent web content, in the window's frame view.
void pressay_apply_glass(void *nsWindow, double radius) {
    onMain(^{
        NSWindow *window = (__bridge NSWindow *)nsWindow;
        NSView *content = window.contentView;
        NSView *frame = content.superview;
        if (!content || !frame) return;
        Class glass = NSClassFromString(@"NSGlassEffectView");
        NSView *backdrop;
        if (glass) {
            backdrop = [[glass alloc] initWithFrame:content.frame];
            if ([backdrop respondsToSelector:NSSelectorFromString(@"setCornerRadius:")])
                [backdrop setValue:@(radius) forKey:@"cornerRadius"];
        } else {
            NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:content.frame];
            blur.material = NSVisualEffectMaterialMenu;
            blur.state = NSVisualEffectStateActive;
            blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            blur.wantsLayer = YES;
            blur.layer.cornerRadius = radius;
            blur.layer.masksToBounds = YES;
            backdrop = blur;
        }
        backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [frame addSubview:backdrop positioned:NSWindowBelow relativeTo:content];
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = YES;
    });
}
void pressay_overlay(const char *stage, const char *detail, const float *levels) {
    pressay_island_update(stage, detail, levels);
}
void pressay_overlay_elapsed(double elapsed) { pressay_island_elapsed(elapsed); }
void pressay_overlay_stop_meeting(void) { if (stopMeetingCallback) stopMeetingCallback(); }

// A token retains only the original AX element/selection, never its text. Tokens
// are short lived and bounded even if a cancelled caller forgets to release one.
@interface PressayFocus : NSObject
@property AXUIElementRef element;
@property pid_t pid;
@property CFRange range;
@property BOOL hasRange;
@property BOOL invalidated;
@property NSDate *created;
@end
@implementation PressayFocus
- (void)dealloc { if (_element) CFRelease(_element); }
@end
static NSMutableDictionary<NSNumber *, PressayFocus *> *targets;
static uint64_t nextTarget = 1;
static AXUIElementRef focusedElement(void) {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    CFTypeRef element = NULL;
    AXError result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute, &element);
    CFRelease(system);
    if (result != kAXErrorSuccess || !element) return NULL;
    if (CFGetTypeID(element) != AXUIElementGetTypeID()) { CFRelease(element); return NULL; }
    return (AXUIElementRef)element;
}
static BOOL secureElement(AXUIElementRef element) {
    CFTypeRef subrole = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSubroleAttribute, &subrole) != kAXErrorSuccess || !subrole) return NO;
    BOOL secure = CFEqual(subrole, kAXSecureTextFieldSubrole); CFRelease(subrole); return secure;
}
static pid_t frontmostPid(void) {
    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
}
// The target is the frontmost app, as in the Swift app and Hex. Its focused AX
// element is kept only as an extra: Electron apps often expose none, or swap it
// while a dictation runs, so requiring that exact element refused every paste.
uint64_t pressay_focused_process(void) {
    pid_t pid = frontmostPid();
    if (pid <= 0 || pid == NSProcessInfo.processInfo.processIdentifier) {
        // Pressay's own window (practice) still has an AX focus to target.
        AXUIElementRef own = focusedElement();
        pid_t ownPid = 0;
        if (!own) return 0;
        if (AXUIElementGetPid(own, &ownPid) != kAXErrorSuccess) { CFRelease(own); return 0; }
        CFRelease(own);
        pid = ownPid;
    }
    AXUIElementRef element = focusedElement();
    pid_t elementPid = 0;
    if (element && (AXUIElementGetPid(element, &elementPid) != kAXErrorSuccess || elementPid != pid)) {
        CFRelease(element); element = NULL;
    }
    if (element && secureElement(element)) { CFRelease(element); return 0; }
    PressayFocus *focus = [PressayFocus new]; focus.element = element;
    focus.pid = pid;
    focus.hasRange = NO;
    focus.created = NSDate.date;
    @synchronized(PressayFocus.class) {
        if (!targets) targets = [NSMutableDictionary new];
        for (NSNumber *key in targets.allKeys) if ([targets[key].created timeIntervalSinceNow] < -600 || targets.count >= 32) [targets removeObjectForKey:key];
        uint64_t token = nextTarget++; targets[@(token)] = focus; return token;
    }
}
static PressayFocus *checkedTarget(uint64_t token, BOOL checkRange) {
    PressayFocus *saved;
    @synchronized(PressayFocus.class) { saved = targets[@(token)]; }
    (void)checkRange;
    if (!saved || saved.invalidated || [saved.created timeIntervalSinceNow] < -600) return nil;
    // Same app still in front is the rule; a password field never gets text.
    AXUIElementRef current = focusedElement();
    BOOL secure = current && secureElement(current);
    pid_t currentPid = 0;
    BOOL samePid = current && AXUIElementGetPid(current, &currentPid) == kAXErrorSuccess && currentPid == saved.pid;
    if (current) CFRelease(current);
    if (secure) return nil;
    return (frontmostPid() == saved.pid || samePid) ? saved : nil;
}
bool pressay_refresh_target(uint64_t token) {
    PressayFocus *saved;
    @synchronized(PressayFocus.class) { saved = targets[@(token)]; }
    if (!saved || saved.invalidated) return false;
    AXUIElementRef element = focusedElement(); pid_t pid = 0;
    if (element && (AXUIElementGetPid(element, &pid) != kAXErrorSuccess || pid != saved.pid)) { CFRelease(element); element = NULL; }
    BOOL valid = (frontmostPid() == saved.pid || element) && !(element && secureElement(element))
        && [saved.created timeIntervalSinceNow] >= -600;
    if (valid) {
        PressayFocus *fresh = [PressayFocus new]; fresh.element = element; fresh.pid = saved.pid; fresh.created = NSDate.date;
        fresh.hasRange = NO;
        @synchronized(PressayFocus.class) { if (targets[@(token)] == saved) targets[@(token)] = fresh; else valid = NO; }
    } else {
        if (element) CFRelease(element);
        @synchronized(PressayFocus.class) { saved.invalidated = YES; }
    }
    return valid;
}
int pressay_activate_application(const char *identifier) {
    NSString *bundle = identifier ? [NSString stringWithUTF8String:identifier] : nil;
    if (!bundle.length) return 0;
    __block pid_t pid = 0;
    void (^activate)(void) = ^{
        NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].firstObject;
        if (!app || app.processIdentifier == NSProcessInfo.processInfo.processIdentifier) return;
        [NSApp hide:nil];
        if ([app activateFromApplication:NSRunningApplication.currentApplication options:0]) pid = app.processIdentifier;
    };
    if (NSThread.isMainThread) activate(); else dispatch_sync(dispatch_get_main_queue(), activate);
    return pid;
}
int pressay_target_process(uint64_t token) {
    @synchronized(PressayFocus.class) { return targets[@(token)].pid; }
}
void pressay_release_target(uint64_t token) { @synchronized(PressayFocus.class) { [targets removeObjectForKey:@(token)]; } }
static NSObject *pasteLock;
static NSArray<NSDictionary<NSPasteboardType, NSData *> *> *pendingSnapshot;
static NSInteger pendingChangeCount;
static NSUInteger restoreGeneration;
static NSArray<NSDictionary<NSPasteboardType, NSData *> *> *snapshotPasteboard(NSPasteboard *pasteboard) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSPasteboardItem *item in pasteboard.pasteboardItems ?: @[]) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSPasteboardType type in item.types) { NSData *data = [item dataForType:type]; if (data) values[type] = data; }
        [items addObject:values];
    }
    return items;
}
static void restorePasteboard(NSPasteboard *pasteboard, NSArray<NSDictionary<NSPasteboardType, NSData *> *> *items) {
    [pasteboard clearContents];
    NSMutableArray *restored = [NSMutableArray array];
    for (NSDictionary<NSPasteboardType, NSData *> *values in items) {
        NSPasteboardItem *item = [NSPasteboardItem new];
        for (NSPasteboardType type in values) [item setData:values[type] forType:type];
        [restored addObject:item];
    }
    if (restored.count) [pasteboard writeObjects:restored];
}
// Web/Electron editors can accept an AXSelectedText write while ignoring it, and
// Electron drops events posted to its main process. Cmd-V through the HID tap
// reaches the focused renderer; the user's clipboard is restored afterwards.
static BOOL pasteText(NSString *text) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pasteLock = [NSObject new]; });
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    @synchronized(pasteLock) {
        // A second insertion before the restore must keep the user's original clipboard.
        NSArray *snapshot = pendingSnapshot && pendingChangeCount == pasteboard.changeCount ? pendingSnapshot : snapshotPasteboard(pasteboard);
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        CGEventRef down = source ? CGEventCreateKeyboardEvent(source, 9, true) : NULL, up = source ? CGEventCreateKeyboardEvent(source, 9, false) : NULL;
        BOOL ready = down && up;
        if (ready) {
            [pasteboard clearContents];
            ready = [pasteboard setString:text forType:NSPasteboardTypeString];
            if (!ready) restorePasteboard(pasteboard, snapshot);
        }
        if (ready) {
            CGEventSourceSetUserData(source, PressaySyntheticInput);
            CGEventSetFlags(down, kCGEventFlagMaskCommand); CGEventSetFlags(up, kCGEventFlagMaskCommand);
            CGEventPost(kCGHIDEventTap, down); CGEventPost(kCGHIDEventTap, up);
            NSInteger inserted = pasteboard.changeCount;
            NSUInteger generation = ++restoreGeneration;
            pendingSnapshot = snapshot; pendingChangeCount = inserted;
            // Electron/content-editable clients may read the pasteboard asynchronously.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                @synchronized(pasteLock) {
                    if (generation != restoreGeneration) return;
                    if (pasteboard.changeCount == inserted) restorePasteboard(pasteboard, snapshot);
                    pendingSnapshot = nil;
                }
            });
        }
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        if (source) CFRelease(source);
        return ready;
    }
}
int pressay_insert_text(const char *utf8, uint64_t token) {
    @autoreleasepool {
        PressayFocus *target = checkedTarget(token, YES);
        if (!target) return 1;
        NSString *text = utf8 ? [NSString stringWithUTF8String:utf8] : nil;
        if (!text || text.length == 0 || text.length > 65536) return 2;
        if (pasteText(text)) return 0;
        Boolean settable = false;
        if (target.element && AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute, &settable) == kAXErrorSuccess && settable
            && AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute, (__bridge CFStringRef)text) == kAXErrorSuccess) return 0;
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        if (!source) return 2;
        CGEventSourceSetUserData(source, PressaySyntheticInput);
        for (NSUInteger start = 0; start < text.length;) {
            if (!checkedTarget(token, NO)) { CFRelease(source); return start ? 3 : 1; }
            NSUInteger count = MIN((NSUInteger)20, text.length - start);
            if (start + count < text.length && CFStringIsSurrogateHighCharacter([text characterAtIndex:start + count - 1])) count--;
            UniChar units[20]; [text getCharacters:units range:NSMakeRange(start, count)];
            CGEventRef down = CGEventCreateKeyboardEvent(source, 0, true), up = CGEventCreateKeyboardEvent(source, 0, false);
            if (!down || !up) { if (down) CFRelease(down); if (up) CFRelease(up); CFRelease(source); return start ? 3 : 2; }
            CGEventSetFlags(down, 0); CGEventSetFlags(up, 0);
            CGEventKeyboardSetUnicodeString(down, count, units); CGEventKeyboardSetUnicodeString(up, count, units);
            CGEventPostToPid(target.pid, down); CGEventPostToPid(target.pid, up);
            CFRelease(down); CFRelease(up); start += count;
        }
        CFRelease(source); return 0;
    }
}

void pressay_clear_targets(void) { @synchronized(PressayFocus.class) { [targets removeAllObjects]; } }
static bool copyString(NSString *value, char *buffer, size_t capacity) {
    if (!value.length || !buffer || capacity < 2) return false;
    const char *utf8 = value.UTF8String;
    if (!utf8 || strlen(utf8) >= capacity) return false;
    memcpy(buffer, utf8, strlen(utf8) + 1); return true;
}
bool pressay_target_application(uint64_t token, char *buffer, size_t capacity) {
    @autoreleasepool {
        PressayFocus *target;
        @synchronized(PressayFocus.class) { target = targets[@(token)]; }
        if (!target) return false;
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:target.pid];
        return copyString(app.bundleIdentifier ?: app.localizedName, buffer, capacity);
    }
}
static NSString *callAppName(NSString *bundleID) {
    NSArray<NSArray<NSString *> *> *known = @[
        @[@"us.zoom.xos", @"Zoom"], @[@"com.microsoft.teams", @"Microsoft Teams"],
        @[@"com.cisco.webexmeetingsapp", @"Webex"], @[@"com.webex.meetingmanager", @"Webex"],
        @[@"com.apple.FaceTime", @"FaceTime"], @[@"com.apple.TelephonyUtilities", @"FaceTime"],
        @[@"com.tinyspeck.slackmacgap", @"Slack"], @[@"com.hnc.Discord", @"Discord"],
        @[@"net.whatsapp.WhatsApp", @"WhatsApp"], @[@"com.google.Chrome", @"Google Chrome"],
        @[@"com.apple.Safari", @"Safari"], @[@"com.apple.WebKit", @"Safari"],
        @[@"company.thebrowser.Browser", @"Arc"], @[@"com.microsoft.edgemac", @"Microsoft Edge"],
        @[@"com.brave.Browser", @"Brave"], @[@"org.mozilla.firefox", @"Firefox"]
    ];
    for (NSArray<NSString *> *entry in known) {
        if ([bundleID isEqualToString:entry[0]] || [bundleID hasPrefix:[entry[0] stringByAppendingString:@"."]]) return entry[1];
    }
    return nil;
}
bool pressay_active_call(char *buffer, size_t capacity) {
    @autoreleasepool {
        if (@available(macOS 14.2, *)) {
            AudioObjectPropertyAddress address = {kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            UInt32 size = 0;
            if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || !size || size > 1024 * 1024) return false;
            NSMutableData *data = [NSMutableData dataWithLength:size];
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, data.mutableBytes) != noErr) return false;
            AudioObjectID *objects = data.mutableBytes;
            for (NSUInteger index = 0; index < size / sizeof(AudioObjectID); index++) {
                UInt32 running = 0, runningSize = sizeof(running);
                AudioObjectPropertyAddress input = {kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                if (AudioObjectGetPropertyData(objects[index], &input, 0, NULL, &runningSize, &running) != noErr || !running) continue;
                CFStringRef bundle = NULL; UInt32 bundleSize = sizeof(bundle);
                AudioObjectPropertyAddress identity = {kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                if (AudioObjectGetPropertyData(objects[index], &identity, 0, NULL, &bundleSize, &bundle) != noErr || !bundle) continue;
                NSString *bundleID = CFBridgingRelease(bundle);
                if ([bundleID isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;
                NSString *name = callAppName(bundleID);
                if (name && copyString(name, buffer, capacity)) return true;
            }
        }
        return false;
    }
}
typedef void (*PressayRemindersCallback)(const char *error, void *context);
void pressay_export_reminders(const char *json, PressayRemindersCallback callback, void *context) {
    NSString *input = json ? [NSString stringWithUTF8String:json] : nil;
    // Permission is requested only by this explicit export action, never startup.
    onMain(^{
        NSDictionary *payload = input ? [NSJSONSerialization JSONObjectWithData:[input dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSArray *items = [payload isKindOfClass:NSDictionary.class] ? payload[@"items"] : nil;
        NSString *title = [payload isKindOfClass:NSDictionary.class] ? payload[@"title"] : nil;
        if (![items isKindOfClass:NSArray.class] || !items.count || items.count > 500 || ![title isKindOfClass:NSString.class]) {
            callback("Choose valid action items to export", context); return;
        }
        for (id item in items) if (![item isKindOfClass:NSString.class] || ![item length]) {
            callback("An action item is empty or invalid", context); return;
        }
        EKEventStore *store = [EKEventStore new];
        [store requestFullAccessToRemindersWithCompletion:^(BOOL granted, NSError *error) {
            (void)error;
            if (!granted) { callback("Allow Pressay to access Reminders in System Settings, then try exporting again.", context); return; }
            EKCalendar *calendar = store.defaultCalendarForNewReminders;
            if (!calendar) { callback("Open Reminders and create a list, then try exporting again.", context); return; }
            NSError *saveError = nil;
            for (NSString *item in items) {
                EKReminder *reminder = [EKReminder reminderWithEventStore:store];
                reminder.title = item; reminder.notes = [NSString stringWithFormat:@"From “%@” in Pressay", title]; reminder.calendar = calendar;
                if (![store saveReminder:reminder commit:NO error:&saveError]) { [store reset]; callback(saveError.localizedDescription.UTF8String ?: "Reminders could not save this item", context); return; }
            }
            if (![store commit:&saveError]) { [store reset]; callback(saveError.localizedDescription.UTF8String ?: "Reminders could not save the action items", context); return; }
            callback(NULL, context);
        }];
    });
}

// Device enumeration must not instantiate an AudioUnit. CPAL's supports_input
// probe can wait on microphone consent; this metadata-only path never opens a
// device and remains usable before the user grants microphone permission.
int pressay_input_devices(char *buffer, size_t capacity) {
    @autoreleasepool {
        if (!buffer || capacity < 2) return 2;
        AudioObjectPropertyAddress devicesAddress = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &size) != noErr || size > 1024 * 1024) return 1;
        NSMutableArray<NSDictionary *> *names = [NSMutableArray new];
        if (size > 0) {
            NSMutableData *storage = [NSMutableData dataWithLength:size];
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, NULL, &size, storage.mutableBytes) != noErr) return 1;
            AudioObjectID *devices = storage.mutableBytes;
            for (NSUInteger index = 0; index < size / sizeof(AudioObjectID); index++) {
                AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
                UInt32 streamBytes = 0;
                if (AudioObjectGetPropertyDataSize(devices[index], &streams, 0, NULL, &streamBytes) != noErr || streamBytes == 0) continue;
                AudioObjectPropertyAddress nameAddress = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                CFStringRef name = NULL; UInt32 nameBytes = sizeof(name);
                if (AudioObjectGetPropertyData(devices[index], &nameAddress, 0, NULL, &nameBytes, &name) != noErr || !name) continue;
                NSString *value = CFBridgingRelease(name);
                nameAddress.mSelector = kAudioDevicePropertyDeviceUID;
                CFStringRef uid = NULL; UInt32 uidBytes = sizeof(uid);
                if (AudioObjectGetPropertyData(devices[index], &nameAddress, 0, NULL, &uidBytes, &uid) != noErr || !uid) continue;
                NSString *identifier = CFBridgingRelease(uid);
                if (value.length && identifier.length) [names addObject:@{@"id": [@"cpal:coreaudio:" stringByAppendingString:identifier], @"name": value}];
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
        if (!json || json.length >= capacity) return 2;
        memcpy(buffer, json.bytes, json.length); buffer[json.length] = '\0'; return 0;
    }
}
