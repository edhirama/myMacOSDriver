// Private API declarations. These classes and functions ship in CoreGraphics / HIServices
// but have no public headers. They are used by DeskPad, BetterDisplay, yabai and others.
//
// Everything here is weakly linked: if a future macOS removes one, the host still launches and
// the symbol is simply null. Callers must check availability first (see Capabilities.swift).
#define MD_WEAK __attribute__((weak_import))
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

MD_WEAK
@interface CGVirtualDisplayMode : NSObject
@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

MD_WEAK
@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

MD_WEAK
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nullable) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsHigh;
@property unsigned int maxPixelsWide;
@property CGSize sizeInMillimeters;
@property unsigned int productID;
@property unsigned int vendorID;
@property unsigned int serialNum;
@property (copy, nullable) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

MD_WEAK
@interface CGVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

/// Maps an accessibility window element to its CGWindowID.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID) MD_WEAK;

/// Whether _AXUIElementGetWindow exists in this OS.
static inline bool MDHasAXWindowLookup(void) { return &_AXUIElementGetWindow != NULL; }

/// Null-safe call: kAXErrorNotImplemented when the function is missing.
static inline AXError MDAXWindowID(AXUIElementRef element, CGWindowID *outWindowID) {
    if (&_AXUIElementGetWindow == NULL) { return kAXErrorNotImplemented; }
    return _AXUIElementGetWindow(element, outWindowID);
}

NS_ASSUME_NONNULL_END
