// Runs a disposable AppKit window; no input is generated or captured.
#include "../shell.mm"
#include <cstdio>
extern "C" void air_set_error(const char *message) { fprintf(stderr,"%s\n",message); }

int main() { @autoreleasepool {
    NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    auto original=NSApp.presentationOptions;
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,300,120)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    window.title=@"Disposable Air Shell Test";
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    bool accepted=false,stable=false,restored=false;
    @try {
        air_shell_begin();
        auto active=NSApp.presentationOptions;
        accepted=(active & NSApplicationPresentationDisableProcessSwitching)
            && (active & NSApplicationPresentationHideDock)
            && !(active & NSApplicationPresentationAutoHideDock)
            && (active & NSApplicationPresentationAutoHideMenuBar);
        air_shell_begin();
        stable=NSApp.presentationOptions==active;
        air_shell_end();
        restored=NSApp.presentationOptions==original;
        air_shell_end();
        restored=restored && NSApp.presentationOptions==original && !presenting;
    } @catch(NSException *exception) {
        fprintf(stderr,"AppKit rejected presentation options: %s\n",exception.name.UTF8String);
    } @finally {
        air_shell_end();
        [window close];
        if(prior)[prior activateWithOptions:0];
    }
    printf("{\"options_accepted\":%s,\"repeated_begin_stable\":%s,\"original_options_restored\":%s,\"physical_keyboard_test\":false}\n",
        accepted?"true":"false",stable?"true":"false",restored?"true":"false");
    return accepted && stable && restored ? 0 : 1;
} }
