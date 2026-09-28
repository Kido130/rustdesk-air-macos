// Compile with AppKit, MetalKit, Metal, CoreVideo, CoreMedia, VideoToolbox and IOSurface.
// Runs only its own windowless event loop; never activates an app or posts input.
#include "../renderer.mm"
#include <cassert>
#include <unistd.h>

static unsigned overlayStops=0;
extern "C" int air_codec_selftest(int) { return -1; }
extern "C" int air_cursor_init(void *) { return -1; }
extern "C" void air_cursor_draw(void *,double,double,double,double,double) {}
extern "C" void air_cursor_metrics(uint64_t *,uint64_t *,uint64_t *) {}
extern "C" void air_cursor_position(double,double,int) {}
extern "C" void air_cursor_reset() {}
extern "C" int air_input_capture_test(int,const char *) { return -1; }
extern "C" int air_input_grabbing() { return 0; }
extern "C" void air_input_metrics(uint64_t *,uint64_t *,uint64_t *,uint64_t *,uint64_t *) {}
extern "C" void air_raw_metrics(uint64_t *,uint64_t *,uint64_t *,uint64_t *) {}
extern "C" void air_overlay_attach(void *) {}
extern "C" int air_overlay_pointer(double,double) { return 0; }
extern "C" int air_overlay_visible() { return 0; }
extern "C" void air_overlay_shutdown() { ++overlayStops; }
extern "C" int air_shell_set_startup(int) { return -1; }
extern "C" int air_shell_set_startup_options(int,int,int,int,int,int) { return -1; }
extern "C" int air_shell_get_startup_options(int *,int *,int *,int *,int *) { return 0; }
extern "C" int air_shell_startup_enabled() { return 0; }

static unsigned cleanupCalls=0;
static pid_t originalForeground=0;
static void cleanup(void *context) {
    assert(context==&cleanupCalls);
    assert(!cleanupCalls);
    ++cleanupCalls;
    puts("session cleanup ran before AppKit termination");
}
static void verifyTermination() {
    assert(cleanupCalls==1 && overlayStops==1 && appStopRequested);
    assert(NSApp.windows.count==0);
    assert(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==originalForeground);
    puts("Quit completed cleanup exactly once without cancelling termination or changing foreground");
}
int main(int argc,char **argv) {
    @autoreleasepool {
        originalForeground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        applicationDelegate=[AirApplicationDelegate new]; NSApp.delegate=applicationDelegate;
        air_app_set_cleanup(cleanup,&cleanupCalls);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
            _exit(2);
        });
        if(argc==2 && strcmp(argv[1],"--delegate")==0) {
            assert([applicationDelegate applicationShouldTerminate:NSApp]==NSTerminateNow);
            assert([applicationDelegate applicationShouldTerminate:NSApp]==NSTerminateNow);
            verifyTermination();
            return 0;
        }
        if(argc==2 && strcmp(argv[1],"--stop")==0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{air_app_stop();});
            air_app_run();
            assert(appStopRequested && !cleanupCalls && overlayStops==1);
            air_app_set_cleanup(nullptr,nullptr);
            cleanup(&cleanupCalls);
            verifyTermination();
            return 0;
        }
        atexit(verifyTermination);
        if(argc==2 && strcmp(argv[1],"--before-run")==0) [NSApp terminate:nil];
        else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[NSApp terminate:nil];});
        air_app_run();
        // terminate: must exit after the synchronous cleanup, rather than cancelling logout.
        return 3;
    }
}
