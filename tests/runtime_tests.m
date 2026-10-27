#define FUSIONFIX_TESTING 1
#include "../fusionfix.m"
#include <assert.h>

// Minimal objects model engine ownership without a GPU, display or live game.
@interface TestLayer : NSObject
@property CGRect frame;
@property CGSize drawableSize;
@property double contentsScale;
- (CALayer *)superlayer;
@end
@implementation TestLayer
- (CALayer *)superlayer { return nil; }
@end

@interface SEView : NSObject
@property id layer;
@property BOOL wantsLayer;
- (NSWindow *)window;
- (NSRect)bounds;
@end
@implementation SEView
- (NSWindow *)window { return nil; }
- (NSRect)bounds { return NSMakeRect(0, 0, 640, 480); }
@end

static BOOL enterResult;
static unsigned attachments;
static BOOL stub_enter(id self, SEL cmd, id screen, id options) {
    (void)self; (void)cmd; (void)screen; (void)options;
    return enterResult;
}
static void stub_exit(id self, SEL cmd, id options) {
    (void)self; (void)cmd; (void)options;
    assert(gFSView == nil); // Cleared before potentially re-entrant AppKit teardown.
}
static void stub_setLayer(id self, SEL cmd, id layer) {
    (void)cmd;
    assert([NSThread isMainThread]);
    [(SEView *)self setLayer:layer];
    attachments++;
}
static void drainMainQueue(void) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!finished && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(finished);
}

int main(void) {
    @autoreleasepool {
        orig_enterFS = stub_enter;
        orig_exitFS = stub_exit;
        orig_setLayer = stub_setLayer;
        @autoreleasepool {
            TestLayer *layer = [TestLayer new];
            rememberMetal((CAMetalLayer *)layer);
            assert(gMetal == (id)layer);
        }
        assert(gMetal == nil);
        @autoreleasepool {
            SEView *view = [SEView new];
            enterResult = NO;
            assert(!my_enterFS(view, @selector(enterFullScreenMode:withOptions:), nil, nil));
            assert(gFSView == nil);
            enterResult = YES;
            assert(my_enterFS(view, @selector(enterFullScreenMode:withOptions:), nil, nil));
            assert(gFSView == (id)view);
            my_exitFS(view, @selector(exitFullScreenModeWithOptions:), nil);
            assert(gFSView == nil);
            my_enterFS(view, @selector(enterFullScreenMode:withOptions:), nil, nil);
        }
        assert(gFSView == nil);

        SEView *view = [SEView new];
        gFSView = (NSView *)view;
        TestLayer *layer = [TestLayer new];
        dispatch_semaphore_t queued = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            requestMetalRepair((CAMetalLayer *)layer);
            dispatch_semaphore_signal(queued);
        });
        assert(dispatch_semaphore_wait(queued, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        assert(attachments == 0);
        drainMainQueue();
        assert(attachments == 1 && view.layer == layer);
        assert(layer.frame.size.width == 640 && view.wantsLayer);
        view.layer = nil;
        gMetal = nil;
        attachments = 0;
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) TestLayer *retired = [TestLayer new];
            __weak TestLayer *weakRetired = retired;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @autoreleasepool {
                    TestLayer *current = weakRetired;
                    assert(current != nil);
                    requestMetalRepair((CAMetalLayer *)current);
                }
                dispatch_semaphore_signal(queued);
            });
            assert(dispatch_semaphore_wait(queued, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
        }
        drainMainQueue();
        assert(gMetal == nil && attachments == 0);
        gFSView = nil;
        puts("runtime tests passed: weak lifetime, failed fullscreen, teardown, main-queue repair, retired-layer queue");
    }
    return 0;
}
