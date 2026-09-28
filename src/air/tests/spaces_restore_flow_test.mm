#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }
static int moveCalls=0,frameCalls=0,switchCalls=0,removeCalls=0;
static bool allowMove=true,allowFrame=true,allowSwitch=true,allowRemove=true;
static int transientSwitchFailures=0;
static NSMutableDictionary *builtinFixture=nil;

static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t) { return 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) { return nullptr; }
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &) { return (int)WindowState::Ready; }
static bool fixtureMove(uint32_t,uint64_t) { ++moveCalls;return allowMove; }
static bool fixtureFrame(const SavedWindow &) { ++frameCalls;return allowFrame; }
static bool fixtureWindowDisplay(uint32_t,const std::string &) { return true; }
static bool fixtureSwitch(uint64_t sid) {
    ++switchCalls;
    if(!allowSwitch)return false;
    if(transientSwitchFailures>0) { transientSwitchFailures--;return false; }
    builtinFixture[@"Current Space"]=@{@"id64":@(sid)};
    return true;
}
static bool fixtureRemove(uint64_t sid) {
    ++removeCalls;
    if(!allowRemove)return false;
    NSMutableArray *remaining=[NSMutableArray array];
    for(NSDictionary *space in builtinFixture[@"Spaces"])
        if([space[@"id64"] unsignedLongLongValue]!=sid)[remaining addObject:space];
    builtinFixture[@"Spaces"]=remaining;
    return true;
}
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureTopology(std::vector<std::string> &topology,const std::string &,bool &online) {
    topology={"builtin-uuid","external-uuid"};online=true;return true;
}
static bool fixtureParkingWindows(uint64_t,std::vector<ParkingWindowIdentity> &windows,std::string *) {
    windows.clear();return true;
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-restore-flow-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    builtinFixture=[@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@900},
        @"Spaces":[@[@{@"id64":@639,@"uuid":@"original",@"type":@0},
            @{@"id64":@900,@"uuid":@"owned-space",@"type":@0},
            @{@"id64":@512,@"uuid":@"other",@"type":@0}] mutableCopy]} mutableCopy];
    NSDictionary *external=@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"external-space",@"type":@0}]};
    RecoveryHooks hooks={};
    hooks.inventory=@[builtinFixture,external];
    hooks.windowState=fixtureWindowState;
    hooks.move=fixtureMove;hooks.frame=fixtureFrame;
    hooks.windowDisplay=fixtureWindowDisplay;
    hooks.switchSpace=fixtureSwitch;hooks.remove=fixtureRemove;
    hooks.missionState=fixtureMission;
    hooks.onlineTopology=fixtureTopology;
    hooks.parkingWindows=fixtureParkingWindows;
    recoveryHooks=&hooks;
    Api &native=api();
    native.conn=fixtureConn;
    native.managed=fixtureManaged;
    native.spaceType=fixtureType;
    native.windowSpaces=fixtureMembership;
    native.axWindow=fixtureAXWindow;
    initialSpace=639;builtinUUID="builtin-uuid";lastSelectedSpace=900;
    slots[0]=639;slots[1]=900;slots[2]=512;
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    createdSpaces.push_back(900);
    ownedSpaces.push_back({900,"owned-space","builtin-uuid"});
    assert(persist());

    allowMove=false;
    assert(restoreLocked()!=0 && saved.size()==1 && createdSpaces.size()==1);
    assert(frameCalls==0 && switchCalls==0 && removeCalls==0);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    allowMove=true;allowFrame=false;
    assert(restoreLocked()!=0 && saved.size()==1 && createdSpaces.size()==1);
    assert(frameCalls==1 && switchCalls==0 && removeCalls==0);

    allowFrame=true;allowSwitch=false;
    assert(restoreLocked()!=0 && saved.size()==1 && createdSpaces.size()==1);
    assert(switchCalls==1 && removeCalls==0);
    builtinFixture[@"Current Space"]=@{@"id64":@512}; // Swipe before the next poll; still a saved session slot.

    allowSwitch=true;allowRemove=false;
    assert(restoreLocked()!=0 && [builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);
    assert(createdSpaces.size()==1 && ownedSpaces.size()==1 && removeCalls==1);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    allowRemove=true;
    builtinFixture[@"Current Space"]=@{@"id64":@512};
    lastSelectedSpace=512;assert(persist());
    transientSwitchFailures=1;
    int priorRetrySwitches=switchCalls;
    int retryResult=restoreWithSettlingRetryLocked();
    assert(retryResult==0 && transientSwitchFailures==0
        && switchCalls==priorRetrySwitches+2
        && saved.empty() && createdSpaces.empty() && ownedSpaces.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    builtinFixture[@"Current Space"]=@{@"id64":@777};
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    initialSpace=639;builtinUUID="builtin-uuid";lastSelectedSpace=900;
    slots[0]=639;slots[1]=900;slots[2]=512;
    assert(persist());
    int priorSwitch=switchCalls;
    assert(restoreLocked()!=0 && switchCalls==priorSwitch && !saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==777);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("restore flow: move/frame/switch/remove failure retention, in-slot swipe, outside-slot preservation passed");
    return 0;
} }
