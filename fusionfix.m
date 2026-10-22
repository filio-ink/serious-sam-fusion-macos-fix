// fusionfix.m - Serious Sam Fusion 2017 (Steam, build 440323 from June 2019, x86_64 under Rosetta 2)
// fixes for current macOS. Injected into the game by the Bin/x64/Sam2017 wrapper via DYLD_INSERT_LIBRARIES.
//
// Problem: the engine still uses -[NSView enterFullScreenMode:withOptions:]. On current macOS the view inside
// the _NSFullScreenWindow gets a default backing layer before the engine attaches its own CAMetalLayer, so the
// engine's layer never ends up on screen (bounds 0x0, no superlayer), nextDrawable returns nil and Metal aborts
// with "-[_MTLCommandBuffer presentDrawable:] failed assertion drawable must not be nil"
// (the engine log shows "Failed creating pipeline state: rasterSampleCount (0) is not supported by device").
//
// Fix: remember the engine's CAMetalLayer (it calls setDevice: on it) and attach it to the fullscreen view
// as soon as both exist. Nothing in the game binary is modified.
//
// Build:
//   xcrun clang -arch x86_64 -dynamiclib -fno-objc-arc -mmacosx-version-min=10.14 -O2 \
//     -framework Foundation -framework AppKit -framework Metal -framework QuartzCore -o fusionfix.dylib fusionfix.m
//
// Env: FUSIONFIX_LOG=<file>   log what happens (set by the wrapper)
//      FUSIONFIX_SCALE=<f>    experimental: Retina scale for windowed mode. Does NOT work with this engine
//                             (it renders into one quadrant), kept only for people who want to experiment.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *gLog = NULL;
static void LOG(const char *fmt, ...) {
    if (!gLog) return;
    va_list ap; va_start(ap, fmt); vfprintf(gLog, fmt, ap); va_end(ap);
    fputc('\n', gLog); fflush(gLog);
}
static IMP hook(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LOG("hook: %s lacks %s", class_getName(cls), sel_getName(sel)); return NULL; }
    IMP orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    return orig;
}

static CAMetalLayer *gMetal = nil;      // the engine's CAMetalLayer (seen in setDevice:)
static NSView *gFSView = nil;           // the view passed to enterFullScreenMode:
static double gScale = 0;               // FUSIONFIX_SCALE (0 = leave alone)

static void applyScale(CAMetalLayer *l, NSView *v) {
    if (gScale <= 0) return;
    NSWindow *w = v.window;
    if (w && w.backingScaleFactor <= 1.0) return;   // captured fullscreen: points == pixels already
    l.contentsScale = gScale;
    l.drawableSize = CGSizeMake(v.bounds.size.width * gScale, v.bounds.size.height * gScale);
    LOG("applyScale: layer=%p scale=%.2f drawable=%.0fx%.0f", l, gScale, l.drawableSize.width, l.drawableSize.height);
}

static void (*orig_setLayer)(id, SEL, id);
static void attachMetal(NSView *v, const char *why) {
    if (!gMetal || !v) return;
    if (gMetal.superlayer || v.layer == gMetal) { LOG("attachMetal(%s): already attached", why); return; }
    gMetal.frame = v.bounds;
    orig_setLayer(v, @selector(setLayer:), gMetal);
    [v setWantsLayer:YES];
    applyScale(gMetal, v);
    LOG("attachMetal(%s): view=%p %s bounds=%.0fx%.0f -> layer=%p drawable=%.0fx%.0f scale=%.2f", why, v,
        class_getName([v class]), v.bounds.size.width, v.bounds.size.height, gMetal,
        gMetal.drawableSize.width, gMetal.drawableSize.height, gMetal.contentsScale);
}

static void my_setLayer(id self, SEL _cmd, id layer) {
    BOOL isSE = strcmp(class_getName([self class]), "SEView") == 0;   // SEView = the engine's render view
    if (isSE) LOG("setLayer: SEView=%p layer=%p(%s) win=%p fsview=%p", self, layer,
                  layer ? class_getName([layer class]) : "nil", [(NSView *)self window], gFSView);
    // AppKit wants to give the engine's view a plain backing layer while the engine's Metal layer is still
    // detached: put the Metal layer there instead.
    if (isSE && layer && ![layer isKindOfClass:[CAMetalLayer class]] && gMetal && !gMetal.superlayer) {
        LOG("setLayer: substituting the engine's CAMetalLayer for %s", class_getName([layer class]));
        attachMetal(self, "setLayer-substitute");
        return;
    }
    orig_setLayer(self, _cmd, layer);
    if (isSE && [layer isKindOfClass:[CAMetalLayer class]]) applyScale(layer, self);
}

// On a Mac with a notch, AppKit sizes the fullscreen window to the screen minus the top safe area
// (3024x1900 instead of 3024x1964 on a 14" MacBook Pro) while the engine renders the full display mode,
// so the bottom of the picture is cut off. Let the window cover the whole panel; the notch simply hides
// a bit of the top strip. Set FUSIONFIX_NO_NOTCH=1 to keep AppKit's safe-area behaviour.
static NSRect (*orig_constrain)(id, SEL, NSRect, id);
static NSRect my_constrain(id self, SEL _cmd, NSRect r, id screen) {
    if (strcmp(class_getName([self class]), "_NSFullScreenWindow") == 0 && !getenv("FUSIONFIX_NO_NOTCH")) return r;
    return orig_constrain(self, _cmd, r, screen);
}
static void coverWholeScreen(NSWindow *w) {
    if (!w || getenv("FUSIONFIX_NO_NOTCH")) return;
    NSScreen *scr = w.screen ?: [NSScreen mainScreen];
    NSRect full = scr.frame;
    if (NSEqualRects(w.frame, full)) return;
    LOG("fullscreen window is %.0fx%.0f@%.0f,%.0f, screen is %.0fx%.0f (safe-area top %.0f): extending to the whole panel",
        w.frame.size.width, w.frame.size.height, w.frame.origin.x, w.frame.origin.y, full.size.width, full.size.height,
        scr.safeAreaInsets.top);
    [w setFrame:full display:YES];
    LOG("  -> window now %.0fx%.0f@%.0f,%.0f, view bounds %.0fx%.0f", w.frame.size.width, w.frame.size.height,
        w.frame.origin.x, w.frame.origin.y, w.contentView.bounds.size.width, w.contentView.bounds.size.height);
}

static BOOL (*orig_enterFS)(id, SEL, id, id);
static BOOL my_enterFS(id self, SEL _cmd, id screen, id opts) {
    LOG("enterFullScreenMode: view=%p %s", self, class_getName([self class]));
    BOOL r = orig_enterFS(self, _cmd, screen, opts);
    gFSView = self;
    NSWindow *w = [(NSView *)self window];
    LOG("  -> %d window=%p %s frame=%.0fx%.0f layer=%p scale=%.1f", r, w, w ? class_getName([w class]) : "-",
        w.frame.size.width, w.frame.size.height, [(NSView *)self layer], w ? w.backingScaleFactor : 0);
    coverWholeScreen(w);
    attachMetal(self, "enterFullScreenMode");
    return r;
}

static void (*orig_exitFS)(id, SEL, id);
static void my_exitFS(id self, SEL _cmd, id opts) {
    LOG("exitFullScreenMode: view=%p", self);
    orig_exitFS(self, _cmd, opts);
    gFSView = nil;
}

static void (*orig_setDevice)(id, SEL, id);
static void my_setDevice(id self, SEL _cmd, id dev) {
    orig_setDevice(self, _cmd, dev);
    gMetal = self;
    LOG("CAMetalLayer setDevice: layer=%p dev=%s super=%p bounds=%.0fx%.0f fsview=%p", self,
        dev ? [[dev name] UTF8String] : "nil", [(CALayer *)self superlayer],
        [(CALayer *)self bounds].size.width, [(CALayer *)self bounds].size.height, gFSView);
    // The engine creates the layer after entering fullscreen: attach it now.
    if (gFSView && ![(CALayer *)self superlayer]) attachMetal(gFSView, "setDevice-late");
}

static id (*orig_nextDrawable)(id, SEL);
static unsigned long gCalls = 0, gNil = 0;
static id my_nextDrawable(id self, SEL _cmd) {
    CAMetalLayer *l = self;
    if (!l.superlayer && gFSView) attachMetal(gFSView, "nextDrawable-rescue");
    id d = orig_nextDrawable(self, _cmd);
    gCalls++;
    if (!d) {
        gNil++;
        if (gNil <= 3 || gNil % 500 == 0)
            LOG("nextDrawable NIL #%lu layer=%p super=%p bounds=%.0fx%.0f drawable=%.0fx%.0f", gNil, l, l.superlayer,
                l.bounds.size.width, l.bounds.size.height, l.drawableSize.width, l.drawableSize.height);
    } else if (gCalls == 1 || gCalls % 3000 == 0) {
        LOG("nextDrawable ok #%lu drawable=%.0fx%.0f scale=%.2f", gCalls, l.drawableSize.width, l.drawableSize.height, l.contentsScale);
    }
    return d;
}

__attribute__((constructor)) static void fusionfix_init(void) {
    const char *p = getenv("FUSIONFIX_LOG");
    if (p) gLog = fopen(p, "a");
    const char *s = getenv("FUSIONFIX_SCALE");
    if (s) gScale = atof(s);
    LOG("=== fusionfix 1.1 loaded pid=%d scale=%.2f", getpid(), gScale);
    orig_nextDrawable = (id (*)(id, SEL))hook(objc_getClass("CAMetalLayer"), @selector(nextDrawable), (IMP)my_nextDrawable);
    orig_setDevice = (void (*)(id, SEL, id))hook(objc_getClass("CAMetalLayer"), @selector(setDevice:), (IMP)my_setDevice);
    orig_setLayer = (void (*)(id, SEL, id))hook(objc_getClass("NSView"), @selector(setLayer:), (IMP)my_setLayer);
    orig_enterFS = (BOOL (*)(id, SEL, id, id))hook(objc_getClass("NSView"), @selector(enterFullScreenMode:withOptions:), (IMP)my_enterFS);
    orig_exitFS = (void (*)(id, SEL, id))hook(objc_getClass("NSView"), @selector(exitFullScreenModeWithOptions:), (IMP)my_exitFS);
    orig_constrain = (NSRect (*)(id, SEL, NSRect, id))hook(objc_getClass("NSWindow"), @selector(constrainFrameRect:toScreen:), (IMP)my_constrain);
}
