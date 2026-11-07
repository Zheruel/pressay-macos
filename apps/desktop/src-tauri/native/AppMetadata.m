#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <string.h>

// NSWorkspace resolves an application bundle identifier, never a caller path.
// The caller owns this small JSON allocation; nil/missing apps return NULL.
char *pressay_app_metadata_json(const char *identifier) {
    if (!identifier) return NULL;
    __block char *result = NULL;
    void (^lookup)(void) = ^{
        @autoreleasepool {
            NSString *bundleID = [NSString stringWithUTF8String:identifier];
            if (!bundleID.length || bundleID.length > 512) return;
            NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleID];
            if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"app"]) return;
            NSBundle *bundle = [NSBundle bundleWithURL:url];
            id displayName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
            if (![displayName isKindOfClass:[NSString class]] || ![displayName length])
                displayName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
            if (![displayName isKindOfClass:[NSString class]] || ![displayName length])
                displayName = [[[NSFileManager defaultManager] displayNameAtPath:url.path] stringByDeletingPathExtension];
            if (![displayName isKindOfClass:[NSString class]] || [displayName length] > 512) return;
            NSMutableDictionary *metadata = [@{@"name": displayName} mutableCopy];
            NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:url.path];
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32 bitsPerSample:8
                samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                bytesPerRow:128 bitsPerPixel:32];
            NSGraphicsContext *context = bitmap ? [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap] : nil;
            if (icon && context) {
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:context];
                [icon drawInRect:NSMakeRect(0, 0, 32, 32) fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy fraction:1.0 respectFlipped:YES
                    hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
                [NSGraphicsContext restoreGraphicsState];
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (png.length && png.length <= 64 * 1024)
                    metadata[@"icon"] = [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil];
            if (json.length && json.length <= 96 * 1024) {
                result = malloc(json.length + 1);
                if (result) { memcpy(result, json.bytes, json.length); result[json.length] = '\0'; }
            }
        }
    };
    if ([NSThread isMainThread]) lookup();
    else dispatch_sync(dispatch_get_main_queue(), lookup);
    return result;
}
void pressay_app_metadata_free(char *value) { free(value); }

// Match Swift's regional date formatting, which can differ from WebKit's
// preferred UI language. This reads only the public OS locale setting.
size_t pressay_formatting_locale(const char *identifier, char *buffer, size_t capacity) {
    @autoreleasepool {
        NSLocale *locale = identifier
            ? [[NSLocale alloc] initWithLocaleIdentifier:[NSString stringWithUTF8String:identifier]]
            : NSLocale.currentLocale;
        // countryCode resolves ICU's rg override (en_US@rg=hrzzzz => HR).
        // CanonicalLanguageIdentifier alone retains @rg, which Intl rejects.
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (locale.languageCode.length) [parts addObject:locale.languageCode];
        NSString *original = identifier ? [NSString stringWithUTF8String:identifier] : locale.localeIdentifier;
        NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:original];
        NSString *script = components[NSLocaleScriptCode] ?: locale.scriptCode;
        if (script.length) [parts addObject:script];
        if (locale.countryCode.length) [parts addObject:locale.countryCode];
        if (locale.variantCode.length) [parts addObject:locale.variantCode];
        const char *value = [[parts componentsJoinedByString:@"-"] UTF8String];
        size_t length = value ? strlen(value) : 0;
        if (!buffer || !length || length >= capacity) return 0;
        memcpy(buffer, value, length + 1);
        return length;
    }
}
