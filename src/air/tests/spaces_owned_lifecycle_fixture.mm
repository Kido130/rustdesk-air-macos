// Coordinator-only, actual Pro test. No real app window is targeted.
#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>
#include <csignal>
static volatile sig_atomic_t cancelled=0;
static void requestCleanup(int) { cancelled=1; }
extern "C" void air_set_error(const char *value) { if(value && *value)fprintf(stderr,"%s\n",value); }
extern "C" int air_display_restore() { return 0; }
static void pump(double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(deadline.timeIntervalSinceNow>0) {
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
        if(event)[NSApp sendEvent:event];
    }
}
static bool visibleWindow(uint32_t wid) {
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    for(NSDictionary *window in windows)
        if([number(window[(id)kCGWindowNumber]) unsignedIntValue]==wid)return true;
    return false;
}
static void emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if(data){fwrite(data.bytes,1,data.length,stdout);putchar('\n');fflush(stdout);}
}
int main(int argc,char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];pump(.3);
    if(argc!=3 || (strcmp(argv[1],"--execute") && strcmp(argv[1],"--recover")) || argv[2][0]!='/')return 2;
    bool recovering=strcmp(argv[1],"--recover")==0;
    NSString *directory=[NSString stringWithUTF8String:argv[2]];
    BOOL isDirectory=NO;
    bool exists=[[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory];
    if((recovering && (!exists || !isDirectory)) || (!recovering && exists))return 2;
    if(!recovering && ![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:nil])return 2;
    journalTestPath=[directory stringByAppendingPathComponent:@"recovery.json"];
    recoveryHooks=nullptr;
    if(recovering && missionState()==MissionState::Visible) {
        if(!loadJournal() || !saved.empty() || !createdSpaces.empty() || pendingCreate)return 3;
        auto down=CGEventCreateKeyboardEvent(nullptr,53,true),up=CGEventCreateKeyboardEvent(nullptr,53,false);
        if(!down || !up){if(down)CFRelease(down);if(up)CFRelease(up);return 3;}
        CGEventPost(kCGHIDEventTap,down);CGEventPost(kCGHIDEventTap,up);CFRelease(down);CFRelease(up);
        pump(.4);
    }
    if(!air_spaces_enabled() || missionState()!=MissionState::Absent){
        const char *reason=migrationBlocker();
        emit(@{@"stage":@"preflight_refused",@"accessibility":@(AXIsProcessTrusted()),
            @"screen_capture":@(CGPreflightScreenCaptureAccess()),@"post_events":@(CGPreflightPostEventAccess()),
            @"mission_state":@((int)missionState()),@"reason":reason ? [NSString stringWithUTF8String:reason] : @"unknown"});return 3;
    }
    if(!acquireJournalLock())return 3;
    Api &a=api();int cid=a.conn();
    if(recovering) {
        if(!loadJournal())return 3;
        int result=restoreLocked();emit(@{@"stage":@"recovery",@"status":@(result)});return result ? 4 : 0;
    }
    NSArray *before=managed();NSDictionary *builtin=builtInManaged(before);
    NSString *uuid=managedDisplayUUID(builtin);
    uint64_t original=[number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    if(!uuid.length || !original || a.spaceType(cid,original)!=0)return 3;
    builtinUUID=uuid.UTF8String;initialSpace=original;
    if(!persist())return 3;
    signal(SIGINT,requestCleanup);signal(SIGTERM,requestCleanup);signal(SIGALRM,requestCleanup);alarm(60);
    NSRunningApplication *previous=NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMutableArray<NSWindow *> *windows=NSMutableArray.array;
    NSMutableArray *observations=NSMutableArray.array;
    bool okay=false;int recovered=-1;
    @try {
        do {
            emit(@{@"stage":@"creating_owned_spaces",@"original":@(original)});
            if(cancelled || !ensureSlots(cid) || cancelled || ownedSpaces.size()!=3 || !ownedSlotsStillOrdered(builtInManaged(managed()),cid))break;
            NSScreen *screen=nil;
            for(NSScreen *candidate in NSScreen.screens)
                if(CGDisplayIsBuiltin([candidate.deviceDescription[@"NSScreenNumber"] unsignedIntValue]))screen=candidate;
            if(!screen)break;
            NSArray *colors=@[NSColor.systemGreenColor,NSColor.systemPurpleColor,NSColor.systemBlueColor];
            bool placed=true;
            for(int i=0;i<3;i++) {
                if(cancelled){placed=false;break;}
                NSRect frame=NSMakeRect(NSMidX(screen.visibleFrame)-180,NSMidY(screen.visibleFrame)-120,360,240);
                NSWindow *window=[[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered defer:NO screen:screen];
                window.releasedWhenClosed=NO;window.title=[NSString stringWithFormat:@"Owned Remote Space Test %d",i+1];
                window.backgroundColor=colors[i];[windows addObject:window];[window orderFront:nil];pump(.1);
                uint32_t wid=(uint32_t)window.windowNumber;
                if(!wid || !move(wid,slots[i],cid) || oneWindowSpace(wid,cid)!=slots[i]
                    || !windowOnDisplay(wid,cid,builtinUUID)){placed=false;break;}
            }
            if(!placed || windows.count!=3)break;
            active=true;
            for(int slot : {1,2,3,1}) {
                if(cancelled){placed=false;break;}
                if(air_spaces_select(slot)!=0){placed=false;break;}
                pump(.2);
                bool visible[3]={};bool correct=true;
                for(int i=0;i<3;i++){visible[i]=visibleWindow((uint32_t)windows[i].windowNumber);if(visible[i]!=(i==slot-1))correct=false;}
                NSDictionary *observation=@{@"slot":@(slot),@"space":@(slots[slot-1]),
                    @"visible":@[@(visible[0]),@(visible[1]),@(visible[2])],@"correct":@(correct)};
                [observations addObject:observation];emit(observation);
                if(!correct){placed=false;break;}
            }
            okay=placed;
        } while(false);
    } @finally {
        for(NSWindow *window in windows)[window close];pump(.2);
        active=false;recovered=restoreLocked();
        if(previous)[previous activateWithOptions:0];
    }
    NSArray *after=managed();
    alarm(0);
    bool same=[before isEqual:after];bool absent=missionState()==MissionState::Absent;
    bool journalGone=![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath];
    emit(@{@"stage":@"result",@"own_window_switches_verified":@(okay),@"recovery_status":@(recovered),
        @"managed_topology_unchanged":@(same),@"mission_control_absent":@(absent),@"journal_removed":@(journalGone),
        @"observations":observations});
    return okay && !recovered && same && absent && journalGone ? 0 : 4;
} }
