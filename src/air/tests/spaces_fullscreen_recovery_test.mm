#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static bool full=false,onSource=true,member=false,canSet=true,canMove=true,canFrame=true,largeFrame=true;
static bool oldIDMissing=false;
static bool selectExternalOnEnter=true;
static uint64_t externalFullSID=847;
static uint32_t actualID=73;
static int setCalls=0,moveCalls=0,frameCalls=0;
static NSMutableDictionary *builtinFixture=nil;
static NSMutableDictionary *externalFixture=nil;
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t sid) { return sid==850 || sid==851 || sid==847 || sid==852 ? 4 : 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) { return nullptr; }
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &w) {
    if(!oldIDMissing)return (int)WindowState::Ready;
    return (int)(closedFullScreenWindowDecision(w.fullScreenPhase,true,false,false,false)
        ? WindowState::Gone : WindowState::AXUnavailable);
}
static int fixtureFullState(const SavedWindow &) { return full ? 1 : 0; }
static bool fixtureSetFull(const SavedWindow &w,bool desired) {
    setCalls++;
    if(!canSet)return false;
    full=desired;member=desired;
    if(desired && w.slot==0)builtinFixture[@"Current Space"]=@{@"id64":@850};
    if(w.slot>0 && (!desired || selectExternalOnEnter))
        externalFixture[@"Current Space"]=@{@"id64":@(desired ? 852 : 189)};
    if(w.slot>0 && desired)externalFullSID=852;
    return true;
}
static uint32_t fixtureResolve(const SavedWindow &) { return actualID; }
static uint64_t fixtureOrdinary(const SavedWindow &w) {
    return !full && onSource ? (w.slot==0 ? 639 : 189) : 0;
}
static bool fixtureFullMember(const SavedWindow &) { return full && member && onSource; }
static uint64_t fixtureFullSpaceID(const SavedWindow &w) {
    return full && member && onSource ? (w.slot==0 ? 850 : externalFullSID) : 0;
}
static bool fixtureAXFrame(const SavedWindow &,CGRect *frame) {
    bool builtin=!saved.empty() && saved[0].slot==0;
    *frame=full ? (largeFrame ? (builtin ? CGRectMake(0,-47,1147,745)
        : CGRectMake(-1920,-47,1920,1080)) : CGRectMake(-870,279,460,332))
        : (builtin ? CGRectMake(100,100,400,300) : CGRectMake(-870,279,460,332));
    return true;
}
static bool fixtureMove(uint32_t,uint64_t sid) {
    moveCalls++;
    if(!canMove || (sid!=189 && sid!=639))return false;
    onSource=true;return true;
}
static bool fixtureFrame(const SavedWindow &w) {
    frameCalls++;return canFrame && nearFrame(w.frame,w.slot==0
        ? CGRectMake(100,100,400,300) : CGRectMake(-870,279,460,332));
}
static bool fixtureDisplay(uint32_t,const std::string &uuid) {
    return onSource && !saved.empty() && uuid==saved[0].sourceUUID;
}
static bool fixtureSwitch(uint64_t sid) {
    builtinFixture[@"Current Space"]=@{@"id64":@(sid)};return true;
}
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureTopology(std::vector<std::string> &topology,const std::string &,bool &online) {
    topology={"builtin-uuid","external-uuid"};online=true;return true;
}

static void resetSaved(int phase) {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();pendingCreate=false;
    pendingCreateBefore.clear();initialSpace=639;builtinUUID="builtin-uuid";lastSelectedSpace=0;
    initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
    selectExternalOnEnter=true;externalFullSID=phase==1 || phase==4 ? 847 : 852;
    slots[0]=slots[1]=slots[2]=0;active=false;
    externalFixture[@"Current Space"]=@{@"id64":@(phase==1 || phase==4 ? 847 : 189)};
    SavedWindow w={73,42,"test.bundle","fixture",CGRectMake(-870,279,460,332),
        CGRectMake(-1920,0,1920,1080),1234567890,
        (phase==1 || phase==4)?847ULL:189ULL,1,
        "external-uuid",true};
    w.fullScreen=true;w.fullScreenPhase=phase;w.fullScreenSpace=847;
    w.axIdentifier="unique.fixture.window";
    saved.push_back(w);
    assert(persist());
}

int main(int argc,char **argv) { @autoreleasepool {
    assert(closedFullScreenWindowDecision(1,true,false,false,false));
    assert(!closedFullScreenWindowDecision(1,false,false,false,false));
    assert(!closedFullScreenWindowDecision(1,true,true,false,false));
    assert(!closedFullScreenWindowDecision(1,true,false,true,false));
    assert(!closedFullScreenWindowDecision(1,true,false,false,true));
    for(int phase=2;phase<=4;phase++)
        assert(!closedFullScreenWindowDecision(phase,true,false,false,false));
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-fullscreen-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    builtinFixture=[@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@639},
        @"Spaces":@[@{@"id64":@639,@"uuid":@"original",@"type":@0},
            @{@"id64":@900,@"uuid":@"remote",@"type":@0},
            @{@"id64":@850,@"uuid":@"newfullscreen",@"type":@4},
            @{@"id64":@851,@"uuid":@"otherfullscreen",@"type":@4}]} mutableCopy];
    externalFixture=[@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"ordinary",@"type":@0},
            @{@"id64":@847,@"uuid":@"fullscreen",@"type":@4},
            @{@"id64":@852,@"uuid":@"restored",@"type":@4}]} mutableCopy];
    RecoveryHooks hooks={};hooks.inventory=@[builtinFixture,externalFixture];
    hooks.windowState=fixtureWindowState;hooks.fullScreenState=fixtureFullState;
    hooks.setFullScreen=fixtureSetFull;hooks.resolveWindow=fixtureResolve;
    hooks.ordinaryAfterExit=fixtureOrdinary;hooks.fullScreenMembership=fixtureFullMember;
    hooks.fullScreenSpaceID=fixtureFullSpaceID;
    hooks.afterExitFrame=fixtureAXFrame;
    hooks.move=fixtureMove;hooks.frame=fixtureFrame;hooks.windowDisplay=fixtureDisplay;
    hooks.missionState=fixtureMission;hooks.onlineTopology=fixtureTopology;
    hooks.switchSpace=fixtureSwitch;
    recoveryHooks=&hooks;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;native.axWindow=fixtureAXWindow;

    resetSaved(1);full=true;member=true;onSource=true;
    NSDictionary *v6=dictionary([NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil]);
    assert([v6[@"version"] intValue]==13 && [v6[@"inventoryComplete"] boolValue]
        && [v6[@"windows"] count]==1);
    NSMutableDictionary *v5=[v6 mutableCopy];
    v5[@"version"]=@5;
    [v5 removeObjectForKey:@"initialFullScreenIndex"];
    [v5 removeObjectForKey:@"initialFullScreenSpace"];
    [v5 removeObjectForKey:@"finalSelectionPending"];
    assert(parseJournal(v5) && initialFullScreenIndex==-1);
    NSMutableDictionary *bad=[v6 mutableCopy];
    NSMutableArray *badWindows=[v6[@"windows"] mutableCopy];
    NSMutableDictionary *badWindow=[badWindows[0] mutableCopy];
    badWindow[@"fullScreenPhase"]=@3;badWindows[0]=badWindow;bad[@"windows"]=badWindows;
    assert(!parseJournal(bad));
    badWindow[@"fullScreenPhase"]=@1;badWindow[@"fullScreenSpace"]=@0;
    assert(!parseJournal(bad));
    assert(loadJournal() && saved[0].fullScreenPhase==1 && saved[0].fullScreenSpace==847);
    assert(restoreLocked()==0 && setCalls==0 && saved.empty());
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    resetSaved(1);full=false;member=false;onSource=true;
    externalFixture[@"Current Space"]=@{@"id64":@189};
    assert(loadJournal() && saved[0].fullScreen && saved[0].fullScreenPhase==1);
    assert(restoreLocked()==0 && full && setCalls==1 && saved.empty());

    resetSaved(2);full=false;member=false;onSource=false;
    int priorMove=moveCalls,priorFrame=frameCalls;
    assert(restoreLocked()==0 && full && moveCalls==priorMove+1 && frameCalls==priorFrame+1);
    assert([externalFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==852);

    resetSaved(2);full=false;member=false;onSource=false;
    externalFixture[@"Current Space"]=@{@"id64":@999};
    priorMove=moveCalls;int priorSet=setCalls;
    assert(restoreLocked()!=0 && !saved.empty() && moveCalls==priorMove && setCalls==priorSet);
    assert([externalFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==999);
    externalFixture[@"Current Space"]=@{@"id64":@189};
    assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);full=false;member=false;onSource=true;
    selectExternalOnEnter=false;
    assert(restoreLocked()!=0 && full && !saved.empty());
    assert([externalFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==189);
    externalFixture[@"Current Space"]=@{@"id64":@852};
    assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);full=false;member=false;onSource=false;canMove=false;
    assert(restoreLocked()!=0 && !saved.empty() && [[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    canMove=true;assert(restoreLocked()==0);

    resetSaved(2);full=false;member=false;onSource=false;canFrame=false;
    assert(restoreLocked()!=0 && !saved.empty());
    canFrame=true;assert(restoreLocked()==0);

    resetSaved(2);full=false;member=false;onSource=true;canSet=false;
    assert(restoreLocked()!=0 && !saved.empty());
    canSet=true;assert(restoreLocked()==0);

    resetSaved(2);full=false;member=false;onSource=true;actualID=0;
    assert(restoreLocked()!=0 && !saved.empty());
    actualID=74;assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);full=false;member=false;onSource=true;oldIDMissing=true;
    assert(restoreLocked()!=0 && !saved.empty());
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    oldIDMissing=false;assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);saved[0].axIdentifier.clear();assert(persist());
    full=false;member=false;onSource=true;actualID=0;
    assert(loadJournal() && saved[0].axIdentifier.empty());
    assert(restoreLocked()!=0 && !saved.empty());
    actualID=73;assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);full=true;member=false;onSource=true;
    externalFixture[@"Current Space"]=@{@"id64":@852};
    assert(restoreLocked()!=0 && !saved.empty());
    member=true;assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);full=true;member=true;onSource=true;largeFrame=false;
    externalFixture[@"Current Space"]=@{@"id64":@852};
    assert(restoreLocked()!=0 && !saved.empty());
    largeFrame=true;assert(restoreLocked()==0 && saved.empty());

    resetSaved(2);saved[0].slot=0;saved[0].space=639;
    saved[0].sourceUUID="builtin-uuid";saved[0].sourceDisplay=CGRectMake(0,0,1147,745);
    saved[0].frame=CGRectMake(100,100,400,300);
    lastSelectedSpace=900;assert(persist());
    builtinFixture[@"Current Space"]=@{@"id64":@900};
    full=false;member=false;onSource=false;
    assert(restoreLocked()==0 && full && saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);

    resetSaved(1);saved[0].slot=0;
    saved[0].sourceUUID="builtin-uuid";saved[0].sourceDisplay=CGRectMake(0,0,1147,745);
    lastSelectedSpace=900;assert(persist());
    builtinFixture[@"Current Space"]=@{@"id64":@900};
    full=false;member=false;onSource=true;
    SavedWindow beforeRollback=saved[0];
    assert(rollbackFailedFullScreenPrepare(0,beforeRollback,nullptr,true,7)!=0);
    assert(full && saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);

    resetSaved(1);saved[0].slot=0;
    saved[0].sourceUUID="builtin-uuid";saved[0].sourceDisplay=CGRectMake(0,0,1147,745);
    lastSelectedSpace=900;assert(persist());
    builtinFixture[@"Current Space"]=@{@"id64":@900};
    full=false;member=false;onSource=true;
    assert(restoreLocked()==0 && full && saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);

    resetSaved(4);saved[0].slot=0;
    saved[0].sourceUUID="builtin-uuid";saved[0].sourceDisplay=CGRectMake(0,0,1147,745);
    lastSelectedSpace=900;assert(persist());
    builtinFixture[@"Current Space"]=@{@"id64":@850};
    full=true;member=true;onSource=true;
    assert(loadJournal() && saved[0].fullScreenPhase==4);
    assert(restoreLocked()==0 && saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==639);

    resetSaved(3);saved[0].slot=0;saved[0].space=639;
    saved[0].sourceUUID="builtin-uuid";saved[0].sourceDisplay=CGRectMake(0,0,1147,745);
    saved[0].frame=CGRectMake(100,100,400,300);
    lastSelectedSpace=900;assert(persist());
    builtinFixture[@"Current Space"]=@{@"id64":@851};
    full=true;member=true;onSource=true;
    assert(restoreLocked()!=0 && !saved.empty());
    assert([builtinFixture[@"Current Space"][@"id64"] unsignedLongLongValue]==851);
    builtinFixture[@"Current Space"]=@{@"id64":@850};
    assert(restoreLocked()==0 && saved.empty());

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("fullscreen recovery: phases 1-4, live rollback, built-in initial restore, unrelated current preservation, identity/action failures passed");
    return 0;
} }
