// Gives the hackathon film's hosted Mac a HiDPI screen, so the app renders at 2x:
// creates a virtual display (the private API Chromium's tests and BetterDisplay
// use), makes it the main display, and stays alive to keep it. CI only.
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics -o virtual-display virtual-display.m
//   ./virtual-display <width in points> <height in points>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static CGVirtualDisplay *display;

int main(int argc, char **argv) {
    @autoreleasepool {
        unsigned int width = argc > 1 ? atoi(argv[1]) : 1600, height = argc > 2 ? atoi(argv[2]) : 1000;
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Film";
        descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
        descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
        descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
        descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
        descriptor.maxPixelsWide = width * 2;
        descriptor.maxPixelsHigh = height * 2;
        descriptor.sizeInMillimeters = CGSizeMake(width * 0.25, height * 0.25);
        descriptor.serialNum = 1;
        descriptor.productID = 0x1234;
        descriptor.vendorID = 0x3456;
        display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) {
            fprintf(stderr, "could not create the virtual display\n");
            return 1;
        }
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[ [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60] ];
        if (![display applySettings:settings]) {
            fprintf(stderr, "could not apply the HiDPI mode\n");
            return 1;
        }
        CGDirectDisplayID others[8];
        uint32_t count = 0;
        CGGetOnlineDisplayList(8, others, &count);
        CGDisplayConfigRef config;
        CGBeginDisplayConfiguration(&config);
        CGConfigureDisplayOrigin(config, display.displayID, 0, 0);
        for (uint32_t i = 0; i < count; i++) {
            if (others[i] != display.displayID) CGConfigureDisplayOrigin(config, others[i], (int)width, 0);
        }
        CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display.displayID);
        printf("virtual display %u: %zu x %zu points, %zu x %zu pixels\n", display.displayID, CGDisplayModeGetWidth(mode),
               CGDisplayModeGetHeight(mode), CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
        fflush(stdout);
        dispatch_main();
    }
}
