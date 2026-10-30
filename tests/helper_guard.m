#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2 || argc == 3);
        Method method = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
        IMP before = method_getImplementation(method);
        void *library = dlopen(argv[1], RTLD_NOW);
        if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        if (argc == 3) {
            assert(method_getImplementation(method) != before);
            puts("game process guard passed: graphics hooks installed");
        } else {
            assert(method_getImplementation(method) == before);
            puts("helper process guard passed: graphics methods unchanged after dlopen");
        }
    }
    return 0;
}
