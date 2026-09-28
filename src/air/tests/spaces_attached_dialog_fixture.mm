#import <AppKit/AppKit.h>
#include <cstdio>
#include <unistd.h>

// Disposable, self-owned windows for an external AX parent-motion probe.
// The fixture never changes a user's window, display, or Space.
int main(int argc,char **argv) { @autoreleasepool {
    bool sheet=argc==2 && strcmp(argv[1],"--sheet")==0;
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    NSWindow *parent=[[NSWindow alloc] initWithContentRect:NSMakeRect(180,220,520,360)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    parent.title=@"Air attached-dialog fixture parent";
    NSPanel *child=sheet ? nil : [[NSPanel alloc] initWithContentRect:NSMakeRect(260,290,320,180)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    child.title=@"Air attached-dialog fixture child";
    [parent makeKeyAndOrderFront:nil];
    NSAlert *alert=sheet ? [NSAlert new] : nil;
    if(sheet) {
        alert.messageText=@"Air attached-dialog fixture";
        alert.informativeText=@"Disposable test sheet. It closes automatically.";
        [alert addButtonWithTitle:@"Close"];
        [alert beginSheetModalForWindow:parent completionHandler:^(NSModalResponse) {}];
    } else {
        [parent addChildWindow:child ordered:NSWindowAbove];
        [child orderFront:nil];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        printf("fixture pid=%d parent=%u child=%u kind=%s\n",getpid(),
            (unsigned)parent.windowNumber,(unsigned)(sheet ? alert.window.windowNumber : child.windowNumber),
            sheet ? "sheet" : "panel");
        fflush(stdout);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        [parent close];[child close];[NSApp stop:nil];exit(0);
    });
    [NSApp run];
    return 0;
} }
