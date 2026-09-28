#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

static std::string lastError;
extern "C" void air_set_error(const char *message) { lastError=message ?: ""; }
extern "C" int air_display_restore(void) { return 0; }
static NSMutableDictionary *builtinFixture=nil;
static NSDictionary *externalFixture=nil;
static NSArray *membershipFixture=nil;
static const char *blockedReason=nullptr;
static int switchCalls=0;
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t sid) { return sid==4 ? 4 : 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) {
    return membershipFixture ? (__bridge_retained CFArrayRef)membershipFixture : nullptr;
}
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &) { return (int)WindowState::Ready; }
static bool fixtureMove(uint32_t,uint64_t) { return true; }
static bool fixtureFrame(const SavedWindow &) { return true; }
static bool fixtureWindowDisplay(uint32_t,const std::string &) { return true; }
static bool fixtureSwitch(uint64_t sid) {
    if([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==sid)return true;
    ++switchCalls;builtinFixture[@"Current Space"]=@{@"id64":@(sid)};return true;
}
static bool fixtureRemove(uint64_t sid) {
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
static const char *fixtureBlocker() { return blockedReason; }
static bool fixtureSwitchAvailable() { return true; }
static bool fixtureParkingWindows(uint64_t,std::vector<ParkingWindowIdentity> &windows,std::string *) {
    windows.clear();return true;
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-loop-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    builtinFixture=[@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@900},
        @"Spaces":@[@{@"id64":@639,@"uuid":@"original",@"type":@0},
            @{@"id64":@900,@"uuid":@"second",@"type":@0},
            @{@"id64":@512,@"uuid":@"third",@"type":@0},
            @{@"id64":@1200,@"uuid":@"fourth",@"type":@0}]} mutableCopy];
    externalFixture=@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"external",@"type":@0}]};
    RecoveryHooks hooks={};hooks.inventory=@[builtinFixture,externalFixture];
    hooks.windowState=fixtureWindowState;hooks.move=fixtureMove;
    hooks.frame=fixtureFrame;hooks.windowDisplay=fixtureWindowDisplay;
    hooks.switchSpace=fixtureSwitch;hooks.remove=fixtureRemove;hooks.missionState=fixtureMission;
    hooks.onlineTopology=fixtureTopology;hooks.migrationBlocker=fixtureBlocker;
    hooks.switchAvailable=fixtureSwitchAvailable;recoveryHooks=&hooks;
    hooks.parkingWindows=fixtureParkingWindows;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;
    native.axWindow=fixtureAXWindow;

    blockedReason="fixture missing operation";
    assert(!air_spaces_supported_for_cross_app_migration());
    assert(air_spaces_prepare()!=0 && lastError.find("fixture missing operation")!=std::string::npos);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    blockedReason=nullptr;
    assert(air_spaces_supported_for_cross_app_migration());
    assert(systemChrome(@"com.apple.dock") && systemChrome(@"com.apple.SystemUIServer"));
    assert(!systemChrome(@"com.apple.finder") && !systemChrome(@"com.example.userapp"));

    uint64_t sid=0;
    membershipFixture=nil;
    assert(ordinaryMembership(73,7,&sid)==Membership::Missing && sid==0);
    assert(membershipBlocker(Membership::Missing));
    membershipFixture=@[@639,@900];
    assert(ordinaryMembership(73,7,&sid)==Membership::Multiple && sid==0);
    assert(membershipBlocker(Membership::Multiple));
    membershipFixture=@[@4];
    assert(ordinaryMembership(73,7,&sid)==Membership::NonOrdinary && sid==0);
    assert(membershipBlocker(Membership::NonOrdinary));
    membershipFixture=@[@189];
    assert(ordinaryMembership(73,7,&sid)==Membership::Ordinary && sid==189);
    assert(!membershipBlocker(Membership::Ordinary));

    saved.push_back({74,42,"test.bundle","fullscreen",CGRectMake(0,0,1147,745),
        CGRectMake(0,0,1147,745),1234567890,4,0,"builtin-uuid",true,true,1,4,"fixture"});
    windowInventoryComplete=false;
    assert(air_spaces_activate()!=0 && lastError.find("inventory is incomplete")!=std::string::npos);
    saved.clear();windowInventoryComplete=true;

    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    initialSpace=639;builtinUUID="builtin-uuid";
    slots[0]=900;slots[1]=512;slots[2]=1200;active=true;
    createdSpaces={900,512,1200};
    ownedSpaces={{900,"second","builtin-uuid"},{512,"third","builtin-uuid"},
        {1200,"fourth","builtin-uuid"}};
    assert(persist());
    assert(!air_spaces_loop_supported());
    assert(air_spaces_select(1)==0 && switchCalls==0 && !air_spaces_loop_supported());
    assert(air_spaces_select(2)==0 && switchCalls==1 && air_spaces_loop_supported());
    assert(air_spaces_wrap_boundary(1,-1)==0 && switchCalls==1);

    // A swipe that began in the interior may reach a boundary normally; never double-advance it.
    builtinFixture[@"Current Space"]=@{@"id64":@1200};
    assert(air_spaces_wrap_boundary(2,1)==0 && switchCalls==1);
    assert(air_spaces_wrap_boundary(3,1)==1 && switchCalls==2);
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==900);
    assert(air_spaces_wrap_boundary(1,-1)==1 && switchCalls==3);
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==1200);
    builtinFixture[@"Current Space"]=@{@"id64":@512};
    assert(air_spaces_wrap_boundary(1,-1)==0 && switchCalls==3);
    assert(air_spaces_wrap_boundary(3,0)==-1 && switchCalls==3);

    assert(air_spaces_restore()==0 && !air_spaces_loop_supported());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("Spaces capability/loop: runtime blocker, explicit sticky/fullscreen refusal, verified switch, boundary-start guard, actual wrap/restore passed");
    return 0;
} }
