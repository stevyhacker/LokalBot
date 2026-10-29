// Adds a Retina (2x) virtual display to a hosted Mac, whose own display offers
// only 1x modes, so the UGC demo films the app with sharp 2x pixels. CI only.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
//   vdisplay <width>x<height> <ready-file>
//
// The size is in points. The display lives as long as this process: once its
// 2x mode is set, the display's ID goes into <ready-file> and the process
// waits; stop it to remove the display. CoreGraphics' CGVirtualDisplay classes
// are not public API, so they are looked up by name at run time and a macOS
// without them fails here, not at link time.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static NSString *describe(CGDisplayModeRef mode) {
    return [NSString stringWithFormat:@"%zu×%zu pt, %zu×%zu px", CGDisplayModeGetWidth(mode),
            CGDisplayModeGetHeight(mode), CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode)];
}

/// The display's 2x mode of the given size in points, once the display lists it.
static CGDisplayModeRef retinaMode(CGDirectDisplayID display, size_t width, size_t height, BOOL log) {
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options));
    CGDisplayModeRef found = NULL;
    for (id item in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)item;
        if (log) printf("  mode %s\n", describe(mode).UTF8String);
        if (!found && CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height
            && CGDisplayModeGetPixelWidth(mode) == 2 * width) {
            found = CGDisplayModeRetain(mode);
        }
    }
    return found;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int width = 0, height = 0;
        if (argc != 3 || sscanf(argv[1], "%ux%u", &width, &height) != 2 || width == 0 || height == 0) {
            fprintf(stderr, "usage: vdisplay <width>x<height> <ready-file>\n");
            return 2;
        }
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        if (!descriptorClass || !settingsClass || !modeClass || !displayClass) {
            fprintf(stderr, "vdisplay: this macOS has no CGVirtualDisplay\n");
            return 1;
        }
        CGVirtualDisplayDescriptor *descriptor = [descriptorClass new];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"LokalBot Film";
        descriptor.maxPixelsWide = 2 * width;
        descriptor.maxPixelsHigh = 2 * height;
        // About 220 pixels per inch, like a Retina laptop panel.
        descriptor.sizeInMillimeters = CGSizeMake(2 * width * 25.4 / 220, 2 * height * 25.4 / 220);
        descriptor.vendorID = 0x4C42;
        descriptor.productID = 0x0F11;
        descriptor.serialNum = 1;
        descriptor.terminationHandler = ^(id gone, id error) {
            fprintf(stderr, "vdisplay: the display went away\n");
            exit(1);
        };
        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            fprintf(stderr, "vdisplay: could not create the display\n");
            return 1;
        }
        CGVirtualDisplaySettings *settings = [settingsClass new];
        settings.hiDPI = 1;
        settings.modes = @[
            [[modeClass alloc] initWithWidth:2 * width height:2 * height refreshRate:60],
            [[modeClass alloc] initWithWidth:width height:height refreshRate:60],
        ];
        if (![display applySettings:settings]) {
            fprintf(stderr, "vdisplay: the display refused its modes\n");
            return 1;
        }
        CGDirectDisplayID displayID = display.displayID;
        printf("vdisplay: display %u\n", displayID);

        CGDisplayModeRef mode = NULL;
        for (int attempt = 0; attempt < 40 && !mode; attempt++) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
            mode = retinaMode(displayID, width, height, attempt == 39);
        }
        if (!mode) {
            fprintf(stderr, "vdisplay: no %u×%u 2x mode; the modes it offers are above\n", width, height);
            return 1;
        }
        CGDisplayConfigRef configuration = NULL;
        CGBeginDisplayConfiguration(&configuration);
        CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, NULL);
        CGError result = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
        CGDisplayModeRef now = CGDisplayCopyDisplayMode(displayID);
        CGRect bounds = CGDisplayBounds(displayID);
        printf("vdisplay: requested %s: %d; now %s at (%.0f, %.0f)\n", describe(mode).UTF8String, result,
               now ? describe(now).UTF8String : "?", bounds.origin.x, bounds.origin.y);
        BOOL retina = now && CGDisplayModeGetPixelWidth(now) == 2 * CGDisplayModeGetWidth(now);
        if (now) CGDisplayModeRelease(now);
        CGDisplayModeRelease(mode);
        if (!retina) {
            fprintf(stderr, "vdisplay: the display did not take its 2x mode\n");
            return 1;
        }
        NSString *ready = [NSString stringWithFormat:@"%u\n", displayID];
        if (![ready writeToFile:@(argv[2]) atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            fprintf(stderr, "vdisplay: cannot write %s\n", argv[2]);
            return 1;
        }
        fflush(stdout);
        CFRunLoopRun();
    }
    return 0;
}
