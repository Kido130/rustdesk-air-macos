#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 || strcmp(argv[1],"--read-only")!=0)return 2;
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!all)return 3;
    int cid=api().conn ? api().conn() : 0;
    unsigned tested=0;
    for(NSDictionary *info in all) {
        NSString *title=info[(id)kCGWindowName];
        if(![title isEqual:@"LinearMouse"])continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(![app.bundleIdentifier isEqual:@"com.lujjjh.LinearMouse"])continue;
        CGRect frame={};
        assert(CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame));
        assert(stableTitledLinearMouseSurface(info,wid,pid,frame,cid));
        NSMutableDictionary *wrong=[info mutableCopy];
        wrong[(id)kCGWindowName]=@"unrelated";
        assert(!stableTitledLinearMouseSurface(wrong,wid,pid,frame,cid));
        wrong=[info mutableCopy];wrong[(id)kCGWindowAlpha]=@0;
        assert(!stableTitledLinearMouseSurface(wrong,wid,pid,frame,cid));
        assert(!stableTitledLinearMouseSurface(info,wid,pid+1,frame,cid));
        assert(!stableTitledLinearMouseSurface(info,wid,pid,
            CGRectOffset(frame,1,0),cid));
        ProcessBirth birth=processBirth(pid);assert(birth.valid());
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        assert(members.count==1);
        uint64_t sid=[number(members[0]) unsignedLongLongValue];assert(sid);
        NSString *display=CFBridgingRelease(api().windowDisplay(cid,wid));assert(display.length);
        double launch=stableLaunchTime(app,pid);assert(launch>0);
        SavedWindow savedWindow={wid,pid,app.bundleIdentifier.UTF8String,title.UTF8String,frame,
            CGRectMake(-3840,0,1920,1080),launch,sid,1,display.UTF8String,false};
        savedWindow.cgOnly=true;savedWindow.birthSeconds=birth.seconds;
        savedWindow.birthMicroseconds=birth.microseconds;savedWindow.memberships={sid};
        assert(exactCGOnlyWindow(savedWindow));
        Conn savedConnection=api().conn;
        api().conn=nullptr;
        assert(!exactCGOnlyWindow(savedWindow));
        assert(windowState(savedWindow)==WindowState::AXUnavailable);
        api().conn=savedConnection;
        SavedWindow wrongWindow=savedWindow;wrongWindow.title="other";
        assert(!exactCGOnlyWindow(wrongWindow));
        wrongWindow=savedWindow;wrongWindow.birthSeconds++;
        assert(!exactCGOnlyWindow(wrongWindow));
        tested++;
    }
    printf("readonly_axless_titled_cg: tested=%u mutations=0\n",tested);
    return tested ? 0 : 4;
} }
