// Original Pressay artwork. Finder overlays the actual draggable icons.
// Build-time AppKit drawing keeps the 1x/2x TIFF reproducible without a browser.
#import <AppKit/AppKit.h>

static NSColor *color(CGFloat red, CGFloat green, CGFloat blue) {
    return [NSColor colorWithSRGBRed:red / 255 green:green / 255 blue:blue / 255 alpha:1];
}

static void label(NSString *text, NSRect rect, CGFloat size,
                  NSFontWeight weight, NSColor *foreground, NSTextAlignment alignment) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = alignment;
    [text drawInRect:rect withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: foreground,
        NSParagraphStyleAttributeName: style
    }];
}

static NSBitmapImageRep *render(NSInteger scale) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:660 * scale pixelsHigh:400 * scale
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *bitmap = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap.CGContext flipped:YES];
    NSAffineTransform *coordinates = [NSAffineTransform transform];
    [coordinates translateXBy:0 yBy:400 * scale];
    [coordinates scaleXBy:scale yBy:-scale];
    [coordinates concat];
    [color(247, 246, 250) setFill];
    NSRectFill(NSMakeRect(0, 0, 660, 400));
    NSColor *ink = color(30, 30, 38), *muted = color(102, 99, 113);
    NSColor *accent = color(116, 75, 218);
    label(@"Make room for your voice.", NSMakeRect(30, 31, 600, 38),
          28, NSFontWeightSemibold, ink, NSTextAlignmentCenter);
    label(@"Drag Pressay to Applications to get started.", NSMakeRect(30, 77, 600, 24),
          14, NSFontWeightRegular, muted, NSTextAlignmentCenter);
    for (NSNumber *position in @[@170, @490]) {
        [color(237, 234, 244) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(position.doubleValue - 75, 111, 150, 144)
                                        xRadius:28 yRadius:28] fill];
    }
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    arrow.lineWidth = 2.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    arrow.lineJoinStyle = NSLineJoinStyleRound;
    [arrow moveToPoint:NSMakePoint(290, 178)];
    [arrow lineToPoint:NSMakePoint(370, 178)];
    [arrow moveToPoint:NSMakePoint(360, 168)];
    [arrow lineToPoint:NSMakePoint(370, 178)];
    [arrow lineToPoint:NSMakePoint(360, 188)];
    [accent setStroke];
    [arrow stroke];
    [color(224, 221, 232) setFill];
    NSRectFill(NSMakeRect(44, 290, 572, 1));
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(46, 315, 110, 48)
                                    xRadius:10 yRadius:10] fill];
    label(@"⌥", NSMakeRect(57, 320, 26, 30), 23, NSFontWeightMedium, accent, NSTextAlignmentLeft);
    label(@"Right Option", NSMakeRect(86, 327, 64, 30), 10, NSFontWeightMedium, ink, NSTextAlignmentLeft);
    label(@"Hold. Speak. Release.", NSMakeRect(178, 315, 420, 25),
          16, NSFontWeightSemibold, ink, NSTextAlignmentLeft);
    label(@"Private dictation. Your words, wherever you write.", NSMakeRect(178, 342, 440, 22),
          12, NSFontWeightRegular, muted, NSTextAlignmentLeft);
    [NSGraphicsContext restoreGraphicsState];
    rep.size = NSMakeSize(660, 400);
    return rep;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: render-background output-directory\n"); return 2; }
        NSURL *directory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSBitmapImageRep *standard = render(1), *retina = render(2);
        NSData *tiff = [NSBitmapImageRep TIFFRepresentationOfImageRepsInArray:@[standard, retina]];
        NSData *png = [retina representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        if (![tiff writeToURL:[directory URLByAppendingPathComponent:@"background.tiff"]
                     options:NSDataWritingAtomic error:&error]
            || ![png writeToURL:[directory URLByAppendingPathComponent:@"background@2x.png"]
                       options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
    }
    return 0;
}
