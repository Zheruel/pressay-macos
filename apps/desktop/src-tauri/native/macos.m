#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

// Only documented permission and event APIs. Never inspect TCC's private database.
int pressay_microphone_status(void) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized: return 1;
        case AVAuthorizationStatusDenied: case AVAuthorizationStatusRestricted: return 2;
        default: return 0;
    }
}
void pressay_request_microphone(void) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) { (void)granted; }];
}
int pressay_accessibility_status(void) { return AXIsProcessTrusted() ? 1 : 2; }
int pressay_input_status(void) { return CGPreflightListenEventAccess() ? 1 : 2; }
void pressay_open_permission(int kind) {
    if (kind == 0 && pressay_microphone_status() == 0) { pressay_request_microphone(); return; }
    NSString *anchor = kind == 0 ? @"Privacy_Microphone" : kind == 1 ? @"Privacy_Accessibility" : @"Privacy_ListenEvent";
    if (kind == 1) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
    if (kind == 2) CGRequestListenEventAccess();
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:anchor]]];
}
uint64_t pressay_focused_process(void) { return (uint64_t)[NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier; }
