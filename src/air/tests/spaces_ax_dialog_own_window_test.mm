#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

@interface OwnDialogPanel : NSPanel
@end
@implementation OwnDialogPanel
- (void)dealloc {fprintf(stderr,"own panel deallocated\n");}
@end

int main(int argc,char **argv) { @autoreleasepool {
    bool retainClosed=argc==2 && strcmp(argv[1],"--retain-closed")==0;
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyRegular;
    [NSApp finishLaunching];
    __block NSPanel *panel=nil;
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool {
        panel=[[OwnDialogPanel alloc] initWithContentRect:NSMakeRect(220,220,320,200)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed=NO;panel.title=@"Own dialog fixture";
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
            object:panel queue:nil usingBlock:^(NSNotification *) {if(!retainClosed)panel=nil;}];
        NSString *closeSignal=[NSString stringWithFormat:@"/private/tmp/air-ax-dialog-close-%d",getpid()];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *) {
            if(panel && [[NSFileManager defaultManager] fileExistsAtPath:closeSignal]) {
                [[NSFileManager defaultManager] removeItemAtPath:closeSignal error:nil];
                [panel close];
            }
        }];
        [NSApp activateIgnoringOtherApps:YES];
        [panel makeKeyAndOrderFront:nil];
        printf("own pid=%d wid=%u trusted=%d\n",getpid(),(uint32_t)panel.windowNumber,
            AXIsProcessTrusted());fflush(stdout);
    }});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(panel)[panel close];exit(0);
    });
    [NSApp run];
    return 0;
} }
