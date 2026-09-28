#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore() { return 0; }
static int observations=0,notifications=0;
static bool becomesVisible=true,initialUnknown=false;
static int observe() {
    if(initialUnknown)return (int)MissionState::Unknown;
    if(observations++==0)return (int)MissionState::Absent;
    return (int)(becomesVisible && observations>=4 ? MissionState::Visible : MissionState::Unknown);
}
static CGError notifyDock(CFStringRef name,int) {
    assert(CFEqual(name,CFSTR("com.apple.expose.awake")));
    ++notifications;return kCGErrorSuccess;
}
int main() { @autoreleasepool {
    RecoveryHooks hooks={};hooks.missionState=observe;recoveryHooks=&hooks;
    api().dock=notifyDock;
    assert(openMission() && notifications==1 && observations==4);
    initialUnknown=true;
    assert(!openMission() && notifications==1);
    initialUnknown=false;becomesVisible=false;observations=0;
    CFAbsoluteTime started=CFAbsoluteTimeGetCurrent();
    assert(!openMission() && notifications==2);
    assert(CFAbsoluteTimeGetCurrent()-started>=3 && CFAbsoluteTimeGetCurrent()-started<5);
    hooks.inventory=@[];
    assert(!missionLayoutSnapshot());
    hooks.inventory=@[@{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@1},
        @"Spaces":@[@{@"id64":@1,@"type":@0}]}];
    NSArray *layout=missionLayoutSnapshot();assert(layout.count==1);
    assert(!closeMissionWithEscape(nullptr,layout));
    AXUIElementRef unrelated=AXUIElementCreateApplication(getpid());
    initialUnknown=true;
    assert(!closeMissionWithEscape(unrelated,layout));
    initialUnknown=false;observations=0;
    assert(!closeMissionWithEscape(unrelated,layout));
    CFRelease(unrelated);
    recoveryHooks=nullptr;
    puts("Mission transition: transient AX unavailability settles; unknown preflight refuses; timeout sends only once");
} }
