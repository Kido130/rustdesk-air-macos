#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
#include <map>

static std::string lastError;
extern "C" void air_set_error(const char *message) { lastError=message ?: ""; }
extern "C" int air_display_restore(void) { return 0; }

static NSMutableDictionary *builtin=nil,*externalB=nil;
static NSArray *inventory=nil;
static std::map<uint32_t,uint64_t> membership;
static std::map<uint32_t,CGRect> liveFrames;
static std::vector<uint32_t> moveOrder,frameOrder;
static std::vector<uint64_t> switchOrder;
static CGRect content=CGRectMake(0,25,1440,875);
static uint32_t unavailableWID=0,wrongMembershipWID=0,frameFailureWID=0,displayFailureWID=0;
static uint32_t staleAfterPreflightWID=0;
static std::map<uint32_t,int> stateReads;
static bool activationPhase=true;

static SavedWindow *window(uint32_t wid) {
    for(auto &w:saved)if(w.id==wid)return &w;
    return nullptr;
}
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t sid) {
    return sid==100 || sid==201 || sid==202 || sid==203 || sid==301 || sid==401 ? 0 : -1;
}
static CFArrayRef fixtureMembership(int,int,CFArrayRef raw) {
    NSArray *ids=(__bridge NSArray *)raw;
    uint32_t wid=ids.count==1 ? [number(ids[0]) unsignedIntValue] : 0;
    auto found=membership.find(wid);
    return found==membership.end() ? nullptr
        : (__bridge_retained CFArrayRef)@[@(found->second)];
}
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &w) {
    if(w.id==staleAfterPreflightWID && ++stateReads[w.id]>1)
        return (int)WindowState::AXUnavailable;
    return w.id==unavailableWID ? (int)WindowState::AXUnavailable : (int)WindowState::Ready;
}
static bool fixtureMove(uint32_t wid,uint64_t sid) {
    moveOrder.push_back(wid);
    if(activationPhase && wid==wrongMembershipWID)
        membership[wid]=sid==201 ? 202 : 201;
    else membership[wid]=sid;
    return true;
}
static bool fixtureFrameAt(const SavedWindow &w,CGRect frame) {
    frameOrder.push_back(w.id);
    assert([builtin[@"Current Space"][@"id64"] unsignedLongLongValue]==slots[w.slot]);
    assert(membership[w.id]==slots[w.slot]);
    assert(nearFrame(frame,mappedFrame(w,content)));
    if(w.id==frameFailureWID)return false;
    liveFrames[w.id]=frame;return true;
}
static bool fixtureRestoreFrame(const SavedWindow &w) {
    assert(membership[w.id]==w.space);
    liveFrames[w.id]=w.frame;return true;
}
static bool fixtureWindowDisplay(uint32_t wid,const std::string &uuid) {
    SavedWindow *w=window(wid);if(!w)return false;
    uint64_t sid=membership[wid];bool target=sid==201 || sid==202 || sid==203;
    std::string actual=target ? "builtin" : w->sourceUUID;
    if(activationPhase && wid==displayFailureWID && target)actual="wrong-display";
    if(target) {
        auto found=liveFrames.find(wid);
        if(found==liveFrames.end() || !nearFrame(found->second,mappedFrame(*w,content)))return false;
    }
    return actual==uuid;
}
static bool fixtureSwitch(uint64_t sid) {
    switchOrder.push_back(sid);builtin[@"Current Space"]=@{@"id64":@(sid)};return true;
}
static bool fixtureSwitchDisplay(const std::string &uuid,uint64_t sid) {
    if(uuid=="builtin")return fixtureSwitch(sid);
    if(uuid=="external-b" && externalB) {
        switchOrder.push_back(sid);externalB[@"Current Space"]=@{@"id64":@(sid)};return true;
    }
    return false;
}
static bool fixtureRemove(uint64_t sid) {
    NSMutableArray *remaining=[NSMutableArray array];
    for(NSDictionary *space in builtin[@"Spaces"])
        if([space[@"id64"] unsignedLongLongValue]!=sid)[remaining addObject:space];
    builtin[@"Spaces"]=remaining;return true;
}
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureTopology(std::vector<std::string> &topology,const std::string &,bool &online) {
    topology={"builtin","external-a","external-b"};online=true;return true;
}
static const char *fixtureBlocker() { return nullptr; }
static bool fixtureSwitchAvailable() { return true; }
static bool fixtureParkingWindows(uint64_t,std::vector<ParkingWindowIdentity> &windows,std::string *) {
    windows.clear();return true;
}

static void seed() {
    releaseJournalLock();
    [[NSFileManager defaultManager] removeItemAtPath:journalTestPath error:nil];
    builtin=[@{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@100},
        @"Spaces":@[@{@"id64":@100,@"uuid":@"original",@"type":@0},
            @{@"id64":@201,@"uuid":@"remote-1",@"type":@0},
            @{@"id64":@202,@"uuid":@"remote-2",@"type":@0},
            @{@"id64":@203,@"uuid":@"remote-3",@"type":@0}]} mutableCopy];
    externalB=[@{@"Display Identifier":@"external-b",@"Current Space":@{@"id64":@401},
        @"Spaces":@[@{@"id64":@401,@"uuid":@"b",@"type":@0},
            @{@"id64":@406,@"uuid":@"restored-fullscreen",@"type":@4}]} mutableCopy];
    inventory=@[builtin,
        @{@"Display Identifier":@"external-a",@"Current Space":@{@"id64":@301},
            @"Spaces":@[@{@"id64":@301,@"uuid":@"a",@"type":@0}]},
        externalB];
    recoveryHooks->inventory=inventory;
    saved={
        {11,42,"test.bundle","a1",CGRectMake(-1800,40,600,500),CGRectMake(-1920,0,1920,1080),1,301,1,"external-a",true},
        {12,42,"test.bundle","built",CGRectMake(80,80,700,500),CGRectMake(0,0,1440,900),1,100,0,"builtin",true},
        {13,42,"test.bundle","a2",CGRectMake(-1100,100,500,400),CGRectMake(-1920,0,1920,1080),1,301,1,"external-a",true},
        {14,42,"test.bundle","b",CGRectMake(-3700,60,800,600),CGRectMake(-3840,0,1920,1080),1,401,2,"external-b",true}
    };
    membership.clear();liveFrames.clear();
    for(const auto &w:saved){membership[w.id]=w.space;liveFrames[w.id]=w.frame;}
    createdSpaces={201,202,203};
    ownedSpaces={{201,"remote-1","builtin"},{202,"remote-2","builtin"},{203,"remote-3","builtin"}};
    slots[0]=201;slots[1]=202;slots[2]=203;
    initialSpace=100;builtinUUID="builtin";lastSelectedSpace=0;
    initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
    initialSelections.clear();selectionPending={};pendingCreateBefore.clear();pendingCreate=false;
    wholeJournal={};parkingEvacuation={};active=false;switchVerified=false;
    windowInventoryComplete=true;shuttingDown=false;pendingDisplayRecovery=false;
    unavailableWID=wrongMembershipWID=frameFailureWID=displayFailureWID=0;
    staleAfterPreflightWID=0;stateReads.clear();
    activationPhase=true;moveOrder.clear();frameOrder.clear();switchOrder.clear();
    assert(persist());
}
static void restoreAndVerify() {
    activationPhase=false;unavailableWID=wrongMembershipWID=frameFailureWID=displayFailureWID=0;
    int restored=restoreLocked();
    if(restored)fprintf(stderr,"restore failed: %s\n",lastError.c_str());
    assert(restored==0);
    assert([builtin[@"Current Space"][@"id64"] unsignedLongLongValue]==100);
    assert(membership[11]==301 && membership[12]==100 && membership[13]==301 && membership[14]==401);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-placement-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    RecoveryHooks hooks={};recoveryHooks=&hooks;
    hooks.windowState=fixtureWindowState;hooks.move=fixtureMove;hooks.frame=fixtureRestoreFrame;
    hooks.frameAt=fixtureFrameAt;hooks.windowDisplay=fixtureWindowDisplay;
    hooks.switchSpace=fixtureSwitch;hooks.remove=fixtureRemove;hooks.missionState=fixtureMission;
    hooks.switchDisplaySpace=fixtureSwitchDisplay;
    hooks.onlineTopology=fixtureTopology;hooks.migrationBlocker=fixtureBlocker;
    hooks.switchAvailable=fixtureSwitchAvailable;
    hooks.parkingWindows=fixtureParkingWindows;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;native.axWindow=fixtureAXWindow;

    seed();std::string reason;
    assert(placeActivationWindows(7,content,&reason));
    assert((moveOrder==std::vector<uint32_t>{12,11,13,14}));
    assert((frameOrder==std::vector<uint32_t>{12,11,13,14}));
    assert((switchOrder==std::vector<uint64_t>{201,202,203}));
    restoreAndVerify();

    seed();unavailableWID=13;
    assert(!placeActivationWindows(7,content,&reason));
    assert(reason.find("stage=preflight wid=13 slot=2 target=202")!=std::string::npos);
    assert(moveOrder.empty() && switchOrder.empty());restoreAndVerify();

    seed();saved[1].axDialog=true;staleAfterPreflightWID=12;
    assert(!placeActivationWindows(7,content,&reason));
    assert(reason.find("stage=identity_before_move wid=12 slot=1 target=201")!=std::string::npos);
    assert(moveOrder.empty() && stateReads[12]==2);

    seed();saved[1].cgOnly=true;saved[1].frameFromAX=false;
    saved[1].bundle="com.lujjjh.LinearMouse";saved[1].title="LinearMouse";
    staleAfterPreflightWID=12;
    assert(!placeActivationWindows(7,content,&reason));
    assert(reason.find("stage=identity_before_move wid=12 slot=1 target=201")!=std::string::npos);
    assert(moveOrder.empty() && stateReads[12]==2);

    seed();wrongMembershipWID=11;
    assert(!placeActivationWindows(7,content,&reason));
    assert(reason.find("stage=membership wid=11 slot=2 target=202")!=std::string::npos);

    // The first slot is complete when the second placed window fails.  Recovery
    // must still return every window and the built-in selection exactly.
    seed();frameFailureWID=11;
    assert(!placeActivationWindows(7,content,&reason));
    // This fixture intentionally uses a synthetic process identity, so the
    // native-size refusal fallback must fail closed before removing its journal.
    assert(reason.find("stage=refusal_identity wid=11 slot=2 target=202")!=std::string::npos);
    assert((frameOrder==std::vector<uint32_t>{12,11,11,11}));restoreAndVerify();

    seed();displayFailureWID=11;
    assert(!placeActivationWindows(7,content,&reason));
    assert(reason.find("stage=display wid=11 slot=2 target=202")!=std::string::npos);
    restoreAndVerify();

    seed();builtin[@"Current Space"]=@{@"id64":@203};
    initialSelections={{"builtin",100,0,-1,100},{"external-a",301,0,-1,301},
        {"external-b",401,0,-1,401}};
    reason.clear();assert(persist());
    assert(prepareOriginalWindowAccess(saved[1],7,&reason)==RecoverySpaceAccess::Ready);
    assert(reason.empty() && [builtin[@"Current Space"][@"id64"] unsignedLongLongValue]==100
        && switchOrder.back()==100);

    seed();externalB[@"Current Space"]=@{@"id64":@406};
    initialSelections={{"builtin",100,0,-1,100},{"external-a",301,0,-1,301},
        {"external-b",401,0,-1,406}};
    reason.clear();assert(persist());
    assert(prepareOriginalWindowAccess(saved[3],7,&reason)==RecoverySpaceAccess::Ready);
    assert(reason.empty() && [externalB[@"Current Space"][@"id64"] unsignedLongLongValue]==401
        && initialSelections[2].hostSpace==401 && switchOrder.back()==401
        && !selectionPending.active);

    recoveryHooks=nullptr;journalTestPath=nil;releaseJournalLock();
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("activation placement: preflight, grouped owned-Space selection, exact membership/frame/display, diagnostics and partial recovery passed");
    return 0;
} }
