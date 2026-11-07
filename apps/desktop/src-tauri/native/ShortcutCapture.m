#import <Cocoa/Cocoa.h>
#include <stdint.h>
// Local-only recording needs no extra privacy permission. Global hold handling
// is suspended by the Rust owner before this monitor is installed.
typedef void (*CaptureCallback)(int32_t);
static id keyMonitor;
static id resignMonitor;
static id windowMonitor;
static CaptureCallback captured;
static void onMain(void (^action)(void)) {
    if (NSThread.isMainThread) action(); else dispatch_async(dispatch_get_main_queue(), action);
}
void pressay_key_capture_stop(void) {
    onMain(^{
        if (keyMonitor) [NSEvent removeMonitor:keyMonitor];
        if (resignMonitor) [NSNotificationCenter.defaultCenter removeObserver:resignMonitor];
        if (windowMonitor) [NSNotificationCenter.defaultCenter removeObserver:windowMonitor];
        keyMonitor = nil; resignMonitor = nil; windowMonitor = nil; captured = NULL;
    });
}
static BOOL modifierPressed(NSEvent *event) {
    uint64_t flags = event.modifierFlags, family = 0, device = 0, paired = 0;
    switch (event.keyCode) {
        case 54: family = NSEventModifierFlagCommand; device = 0x10; paired = 0x18; break;
        case 55: family = NSEventModifierFlagCommand; device = 0x08; paired = 0x18; break;
        case 58: family = NSEventModifierFlagOption; device = 0x20; paired = 0x60; break;
        case 61: family = NSEventModifierFlagOption; device = 0x40; paired = 0x60; break;
        case 56: family = NSEventModifierFlagShift; device = 0x02; paired = 0x06; break;
        case 60: family = NSEventModifierFlagShift; device = 0x04; paired = 0x06; break;
        case 59: family = NSEventModifierFlagControl; device = 0x01; paired = 0x2001; break;
        case 62: family = NSEventModifierFlagControl; device = 0x2000; paired = 0x2001; break;
        case 63: return (flags & NSEventModifierFlagFunction) != 0;
        default: return NO;
    }
    return (flags & family) && (!(flags & paired) || (flags & device));
}
static NSEvent *handleCaptureEvent(NSEvent *event) {
            if (!captured) return event;
            if (event.type == NSEventTypeKeyDown && event.keyCode == 53) { captured(-1); return nil; }
            if (event.keyCode > 127 || event.keyCode == 57 || (event.type == NSEventTypeKeyDown && event.isARepeat)) return nil;
            if (event.type == NSEventTypeFlagsChanged && !modifierPressed(event)) return nil;
            captured(event.keyCode); return nil;
}
void pressay_key_capture_start(CaptureCallback callback) {
    onMain(^{
        pressay_key_capture_stop(); captured = callback;
        keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            return handleCaptureEvent(event);
        }];
        windowMonitor = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResignKeyNotification object:NSApp.keyWindow queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; if (captured) captured(-1);
        }];
        resignMonitor = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note; if (captured) captured(-1);
        }];
    });
}
