// Serious Sam Fusion 2017 (Steam build 440323, x86_64 under Rosetta 2).
// Build with ./build.sh. ARC is required for zeroing weak object references.
// FUSIONFIX_LOG=1 enables diagnostics on stderr; no log files are opened.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error "fusionfix requires ARC; use ./build.sh"
#endif

static bool gLogging;
static bool enabled(const char *name) {
    const char *value = getenv(name);
    return value && strcmp(value, "1") == 0;
}
static void LOG(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void LOG(const char *fmt, ...) {
    if (!gLogging) return;
    // Use the launcher's existing descriptor, never a path supplied by the environment.
    flockfile(stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    funlockfile(stderr);
}

// Access these only on the main thread. Weak references zero on destruction;
// each operation takes a strong local snapshot for its entire use of the object.
static __weak CAMetalLayer *gMetal;
static __weak NSView *gFSView;
static double gScale;
static atomic_bool gRepairPending;
static atomic_ulong gCalls, gNil;

static bool isEngineView(id view) {
    return strcmp(class_getName([view class]), "SEView") == 0;
}

static void applyScale(CAMetalLayer *layer, NSView *view) {
    if (gScale <= 0) return;
    NSWindow *window = view.window;
    if (window && window.backingScaleFactor <= 1.0) return;
    layer.contentsScale = gScale;
    layer.drawableSize = CGSizeMake(view.bounds.size.width * gScale, view.bounds.size.height * gScale);
}

static void (*orig_setLayer)(id, SEL, id);
static void attachMetal(NSView *view, CAMetalLayer *layer, const char *why) {
    if (![NSThread isMainThread] || !view || !layer) return;
    if (layer.superlayer || view.layer == layer) return;
    layer.frame = view.bounds;
    orig_setLayer(view, @selector(setLayer:), layer);
    [view setWantsLayer:YES];
    applyScale(layer, view);
    LOG("attachMetal(%s): bounds=%.0fx%.0f drawable=%.0fx%.0f", why,
        view.bounds.size.width, view.bounds.size.height, layer.drawableSize.width, layer.drawableSize.height);
}

static void rememberMetal(CAMetalLayer *layer) {
    if (![NSThread isMainThread] || !layer) return;
    gMetal = layer;
    NSView *view = gFSView;
    attachMetal(view, layer, "render-layer");
}

static void requestMetalRepair(CAMetalLayer *layer) {
    if ([NSThread isMainThread]) {
        rememberMetal(layer);
        return;
    }
    // Never synchronously wait for the main thread: it may be waiting for the
    // renderer. Coalesce repairs and don't keep a retired render layer alive.
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gRepairPending, &expected, true)) return;
    __weak CAMetalLayer *pendingLayer = layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&gRepairPending, false);
        CAMetalLayer *current = pendingLayer;
        rememberMetal(current);
    });
}

static void my_setLayer(id self, SEL cmd, id layer) {
    if ([NSThread isMainThread] && isEngineView(self)) {
        CAMetalLayer *metal = gMetal;
        if (layer && ![layer isKindOfClass:[CAMetalLayer class]] && metal && !metal.superlayer) {
            attachMetal(self, metal, "setLayer-substitute");
            return;
        }
    }
    orig_setLayer(self, cmd, layer);
    if ([NSThread isMainThread] && isEngineView(self) && [layer isKindOfClass:[CAMetalLayer class]])
        applyScale(layer, self);
}

static NSRect (*orig_constrain)(id, SEL, NSRect, id);
static NSRect my_constrain(id self, SEL cmd, NSRect rect, id screen) {
    if ([NSThread isMainThread] && !enabled("FUSIONFIX_NO_NOTCH") &&
        strcmp(class_getName([self class]), "_NSFullScreenWindow") == 0) return rect;
    return orig_constrain(self, cmd, rect, screen);
}

static void coverWholeScreen(NSWindow *window) {
    if (!window || enabled("FUSIONFIX_NO_NOTCH")) return;
    NSScreen *screen = window.screen ?: [NSScreen mainScreen];
    if (!screen || NSEqualRects(window.frame, screen.frame)) return;
    [window setFrame:screen.frame display:YES];
}

static BOOL (*orig_enterFS)(id, SEL, id, id);
static BOOL my_enterFS(id self, SEL cmd, id screen, id options) {
    BOOL result = orig_enterFS(self, cmd, screen, options);
    if (!result || ![NSThread isMainThread] || !isEngineView(self)) return result;
    NSView *view = self;
    gFSView = view;
    coverWholeScreen(view.window);
    CAMetalLayer *metal = gMetal;
    attachMetal(view, metal, "enterFullScreenMode");
    return result;
}

static void (*orig_exitFS)(id, SEL, id);
static void my_exitFS(id self, SEL cmd, id options) {
    // Clear before AppKit can re-enter a hook while tearing down fullscreen.
    if ([NSThread isMainThread] && gFSView == self) gFSView = nil;
    orig_exitFS(self, cmd, options);
}

static void (*orig_setDevice)(id, SEL, id);
static void my_setDevice(id self, SEL cmd, id device) {
    orig_setDevice(self, cmd, device);
    if (device) requestMetalRepair(self);
}

static id (*orig_nextDrawable)(id, SEL);
static id my_nextDrawable(id self, SEL cmd) {
    CAMetalLayer *layer = self;
    if (!layer.superlayer) requestMetalRepair(layer);
    id drawable = orig_nextDrawable(self, cmd);
    unsigned long calls = atomic_fetch_add(&gCalls, 1) + 1;
    if (!drawable) {
        unsigned long nils = atomic_fetch_add(&gNil, 1) + 1;
        if (nils <= 3 || nils % 500 == 0) LOG("nextDrawable NIL #%lu", nils);
    } else if (calls == 1 || calls % 3000 == 0) {
        LOG("nextDrawable ok #%lu", calls);
    }
    return drawable;
}

static IMP hook(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    IMP original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return original;
}

#ifndef FUSIONFIX_TESTING
__attribute__((constructor)) static void fusionfix_init(void) {
    // DYLD variables propagate to child processes; don't alter helper applications.
    if (strcmp(getprogname(), "Sam2017_real") != 0) return;
    gLogging = enabled("FUSIONFIX_LOG");
    const char *scale = getenv("FUSIONFIX_SCALE");
    if (scale) {
        char *end = NULL;
        errno = 0;
        double value = strtod(scale, &end);
        if (!errno && end != scale && *end == '\0' && isfinite(value) && value > 0 && value <= 4)
            gScale = value;
        else
            LOG("ignoring invalid FUSIONFIX_SCALE (expected a finite number in (0, 4])");
    }

    Class metal = objc_getClass("CAMetalLayer");
    Class view = objc_getClass("NSView");
    Class window = objc_getClass("NSWindow");
    struct { Class cls; SEL selector; } required[] = {
        {metal, @selector(nextDrawable)}, {metal, @selector(setDevice:)},
        {view, @selector(setLayer:)}, {view, @selector(enterFullScreenMode:withOptions:)},
        {view, @selector(exitFullScreenModeWithOptions:)}, {window, @selector(constrainFrameRect:toScreen:)}
    };
    // Validate the complete set before changing any methods.
    for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++) {
        if (!required[i].cls || !class_getInstanceMethod(required[i].cls, required[i].selector)) {
            LOG("fusionfix disabled: required graphics API is unavailable");
            return;
        }
    }
    orig_nextDrawable = (id (*)(id, SEL))hook(metal, @selector(nextDrawable), (IMP)my_nextDrawable);
    orig_setDevice = (void (*)(id, SEL, id))hook(metal, @selector(setDevice:), (IMP)my_setDevice);
    orig_setLayer = (void (*)(id, SEL, id))hook(view, @selector(setLayer:), (IMP)my_setLayer);
    orig_enterFS = (BOOL (*)(id, SEL, id, id))hook(view, @selector(enterFullScreenMode:withOptions:), (IMP)my_enterFS);
    orig_exitFS = (void (*)(id, SEL, id))hook(view, @selector(exitFullScreenModeWithOptions:), (IMP)my_exitFS);
    orig_constrain = (NSRect (*)(id, SEL, NSRect, id))hook(window, @selector(constrainFrameRect:toScreen:), (IMP)my_constrain);
    LOG("fusionfix 1.2 loaded");
}
#endif
