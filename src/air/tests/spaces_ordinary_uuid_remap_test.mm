#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <future>
#include <map>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static std::map<uint64_t,int> kinds;
static int fixtureType(int,uint64_t sid) {
    auto found=kinds.find(sid);
    return found==kinds.end() ? -1 : found->second;
}
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) { return nullptr; }
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureMission() { return (int)MissionState::Absent; }
static bool allowSecondAlreadyRestored=false;
static int fixtureAXUnavailable(const SavedWindow &) { return (int)WindowState::AXUnavailable; }
static bool fixtureAlreadyRestored(const SavedWindow &w) {
    return w.id==73 || (w.id==74 && allowSecondAlreadyRestored);
}
static uint64_t selectedReusable=100;
static uint64_t fixtureReusableWindowSpace(uint32_t wid) { return wid==74 ? 300 : 0; }
static bool fixtureReusableWindowDisplay(uint32_t wid,const std::string &uuid) {
    return wid==74 && uuid=="builtin";
}
static bool fixtureReusableSwitch(const std::string &uuid,uint64_t sid) {
    if(uuid!="builtin" || (sid!=100 && sid!=200 && sid!=300))return false;
    selectedReusable=sid;
    recoveryHooks->inventory=@[
        @{ @"Display Identifier":@"builtin",@"Current Space":@{ @"id64":@(sid) },
            @"Spaces":@[@{@"id64":@100,@"uuid":@"builtin-space",@"type":@0},
                @{@"id64":@200,@"uuid":@"second",@"type":@0},
                @{@"id64":@300,@"uuid":@"third",@"type":@0}] },
        @{ @"Display Identifier":@"external",@"Current Space":@{ @"id64":@32 },
            @"Spaces":@[@{@"id64":@32,@"uuid":@"external-space",@"type":@0}] }
    ];
    return true;
}
static uint64_t builtinWindowSpace=100;
static int builtinFrameRestores=0;
static uint64_t fixtureBuiltinWindowSpace(uint32_t wid) {
    return wid==75 ? builtinWindowSpace : 0;
}
static bool fixtureBuiltinMove(uint32_t wid,uint64_t sid) {
    if(wid!=75)return false;
    builtinWindowSpace=sid;return true;
}
static bool fixtureBuiltinFrame(const SavedWindow &w) {
    if(w.id!=75)return false;
    builtinFrameRestores++;return true;
}
static bool fixtureBuiltinDisplay(uint32_t wid,const std::string &uuid) {
    return wid==75 && uuid=="builtin";
}
static int fixtureReady(const SavedWindow &) { return (int)WindowState::Ready; }
static bool fixtureOnline(std::vector<std::string> &topology,const std::string &,bool &builtinOnline) {
    topology={"builtin","external","external-two"};builtinOnline=true;return true;
}
static NSDictionary *space(uint64_t sid,NSString *uuid,int type=0) {
    return @{@"id64":@(sid),@"uuid":uuid,@"type":@(type)};
}
static NSArray *inventory(NSArray *builtin,NSArray *external) {
    return @[
        @{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@100},@"Spaces":builtin},
        @{@"Display Identifier":@"external",@"Current Space":@{@"id64":@230},@"Spaces":external}
    ];
}
static void reset() {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();reusedSlots.clear();pendingCreateBefore.clear();
    initialSelections.clear();ordinarySpaceIdentities.clear();selectionPending={};
    pendingCreate=false;parkingEvacuation={};wholeJournal={};
    slots[0]=slots[1]=slots[2]=0;lastSelectedSpace=0;
    initialSpace=100;initialFullScreenIndex=-1;initialFullScreenSpace=0;
    finalSelectionPending=false;builtinUUID="builtin";windowInventoryComplete=true;
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,32,1,"external",true});
    initialSelections={{"builtin",100,0,-1,100},{"external",32,0,-1,32}};
    ordinarySpaceIdentities={{100,"builtin","builtin-space"},{32,"external","external-space"}};
    kinds={{100,0},{230,0}};
}

int main() { @autoreleasepool {
    assert(!fullScreenProcessGoneDecision(false,false,false,false));
    assert(!fullScreenProcessGoneDecision(false,false,true,false));
    assert(!fullScreenProcessGoneDecision(false,false,false,true));
    assert(!fullScreenProcessGoneDecision(true,true,true,true));
    assert(fullScreenProcessGoneDecision(false,true,false,false));
    assert(fullScreenProcessGoneDecision(false,false,true,true));
    CGRect chromeDisplay=CGRectMake(-1920,0,1920,1080);
    CGRect chromeRoot=CGRectMake(-1920,30,1920,1050);
    CGRect chromeTransparent=CGRectMake(-1921,1059,335,22);
    assert(ordinaryChromeTransparentBottomEdge(chromeDisplay,chromeRoot,chromeTransparent));
    assert(!ordinaryChromeTransparentBottomEdge(chromeDisplay,chromeRoot,
        CGRectMake(-1921,1059,700,22)));
    assert(!ordinaryChromeTransparentBottomEdge(chromeDisplay,chromeRoot,
        CGRectMake(-1600,1059,335,22)));
    assert(!ordinaryChromeTransparentBottomEdge(chromeDisplay,chromeRoot,
        CGRectMake(-1921,1050,335,22)));
    char path[]="/tmp/air-spaces-uuid-remap-XXXXXX";
    assert(mkdtemp(path));
    NSString *directory=[NSString stringWithUTF8String:path];
    journalTestPath=[directory stringByAppendingPathComponent:@"recovery.json"];
    api().spaceType=fixtureType;
    std::string reason;

    reset();
    assert(persist());
    saved.clear();ordinarySpaceIdentities.clear();initialSelections.clear();
    assert(loadJournal() && saved[0].space==32 && ordinarySpaceIdentities.size()==2);
    assert(reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space")],
        @[space(230,@"external-space")]),7,reason));
    assert(saved[0].space==230 && initialSpace==100
        && initialSelections[1].space==230 && initialSelections[1].hostSpace==230
        && ordinarySpaceIdentities[1].id==230);
    saved.clear();ordinarySpaceIdentities.clear();initialSelections.clear();
    assert(loadJournal() && saved[0].space==230 && initialSelections[1].space==230
        && ordinarySpaceIdentities[1].id==230);

    reset();kinds={{101,0},{32,0}};reason.clear();
    assert(reconcileOrdinarySpaceIDs(inventory(@[space(101,@"builtin-space")],
        @[space(32,@"external-space")]),7,reason));
    assert(initialSpace==101 && initialSelections[0].space==101
        && initialSelections[0].hostSpace==101 && saved[0].space==32);

    reset();ordinarySpaceIdentities.erase(ordinarySpaceIdentities.begin());
    kinds={{101,0},{32,0}};reason.clear();
    assert(reconcileOrdinarySpaceIDs(inventory(@[space(101,@"builtin-space")],
        @[space(32,@"external-space")]),7,reason));
    assert(initialSpace==100 && initialSelections[0].space==100);

    std::vector<uint64_t> planned;int missing=-1;
    assert(planReusedSlots({100,200},100,planned,missing)
        && planned==std::vector<uint64_t>({100,200}) && missing==1);
    assert(planReusedSlots({200,100,300},100,planned,missing)
        && planned==std::vector<uint64_t>({100,200,300}) && missing==0);
    assert(planReusedSlots({200,100,300,400},100,planned,missing)
        && planned==std::vector<uint64_t>({100,200,300}) && missing==0);
    assert(!planReusedSlots({100,200,300,400,500},100,planned,missing));

    reset();
    reusedSlots={{100,"builtin-space","builtin"},{200,"second","builtin"},
        {300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;
    kinds={{100,0},{200,0},{300,0},{500,0}};
    NSArray *nonadjacent=inventory(@[space(100,@"builtin-space"),space(500,@"other"),
        space(200,@"second"),space(300,@"third")],@[space(32,@"external-space")]);
    assert(ownedSlotsStillOrdered(nonadjacent[0],7) && beginOwnedCleanup()
        && slots[0]==100 && slots[1]==200 && slots[2]==300 && createdSpaces.empty());
    assert(persist());
    reusedSlots.clear();slots[0]=slots[1]=slots[2]=0;
    assert(loadJournal() && reusedSlots.size()==3 && reusedSlots[1].id==200
        && slots[1]==200 && ownedSlotsStillOrdered(nonadjacent[0],7));
    ordinarySpaceIdentities.push_back({200,"builtin","second"});
    ordinarySpaceIdentities.push_back({300,"builtin","third"});
    kinds={{100,0},{250,0},{300,0},{32,0}};reason.clear();
    NSArray *renumbered=inventory(@[space(100,@"builtin-space"),
        space(250,@"second"),space(300,@"third")],@[space(32,@"external-space")]);
    bool remapped=reconcileOrdinarySpaceIDs(renumbered,7,reason);
    if(!remapped || reusedSlots[1].id!=250 || slots[1]!=250
        || !ownedSlotsStillOrdered(renumbered[0],7))
        fprintf(stderr,"reuse remap=%d reason=%s reused=%llu slot=%llu\n",
            remapped,reason.c_str(),(unsigned long long)reusedSlots[1].id,
            (unsigned long long)slots[1]);
    assert(remapped && reusedSlots[1].id==250 && slots[1]==250
        && ownedSlotsStillOrdered(renumbered[0],7));
    reusedSlots.clear();slots[0]=slots[1]=slots[2]=0;
    assert(loadJournal() && reusedSlots[1].id==250 && slots[1]==250);

    reset();
    reusedSlots={{100,"builtin-space","builtin"},{200,"second","builtin"},
        {300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;lastSelectedSpace=300;
    SavedWindow launched={74,43,"test.new","new",CGRectMake(-1500,95,430,310),
        CGRectMake(-1920,0,1920,1080),1234567891,32,2,"external",true};
    launched.birthSeconds=123;launched.birthMicroseconds=456;
    launched.memberships={32};launched.minimizedKnown=true;launched.minimized=true;
    saved.push_back(launched);
    assert(persist());
    saved.clear();reusedSlots.clear();slots[0]=slots[1]=slots[2]=0;
    assert(loadJournal() && saved.size()==2 && saved[1].id==74
        && saved[1].space==32 && saved[1].slot==2 && saved[1].sourceUUID=="external"
        && saved[1].memberships.empty() && saved[1].minimizedKnown
        && saved[1].minimized && reusedSlots.size()==3 && slots[2]==300);
    SavedWindow ordinary=saved[1];
    assert(!ordinaryRestoredReadOnlyDecision(ordinary,true,true,true));
    ordinary.minimized=false;
    assert(ordinaryRestoredReadOnlyDecision(ordinary,true,true,true));
    assert(!ordinaryRestoredReadOnlyDecision(ordinary,false,true,true));
    assert(!ordinaryRestoredReadOnlyDecision(ordinary,true,false,true));
    assert(!ordinaryRestoredReadOnlyDecision(ordinary,true,true,false));
    SavedWindow excluded=ordinary;excluded.axDialog=true;
    assert(!ordinaryRestoredReadOnlyDecision(excluded,true,true,true));
    excluded=ordinary;excluded.memberships={ordinary.space,200};
    assert(!ordinaryRestoredReadOnlyDecision(excluded,true,true,true));

    reset();reason.clear();
    assert(!reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space"),
        space(230,@"external-space")],@[]),7,reason) && saved[0].space==32);

    reset();kinds[230]=4;reason.clear();
    assert(!reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space")],
        @[space(230,@"external-space",4)]),7,reason) && saved[0].space==32);

    reset();kinds[231]=0;reason.clear();
    assert(!reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space")],
        @[space(230,@"external-space"),space(231,@"external-space")]),7,reason)
        && saved[0].space==32);

    reset();kinds[32]=0;reason.clear();
    assert(!reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space")],
        @[space(32,@"reused"),space(230,@"external-space")]),7,reason)
        && saved[0].space==32);

    reset();ordinarySpaceIdentities.clear();reason.clear();
    assert(reconcileOrdinarySpaceIDs(inventory(@[space(100,@"builtin-space")],
        @[space(230,@"external-space")]),7,reason) && saved[0].space==32
        && initialSelections[1].space==32);

    reset();saved.clear();ordinarySpaceIdentities.clear();
    reusedSlots={{100,"builtin-space","builtin"},{200,"second","builtin"},
        {300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;lastSelectedSpace=100;active=true;
    initialSelections={{"builtin",100,0,-1,100},{"external",32,0,-1,32},
        {"external-two",33,0,-1,33}};
    kinds={{100,0},{200,0},{300,0},{32,0},{33,0}};
    NSArray *all=@[
        @{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@100},
            @"Spaces":@[space(100,@"builtin-space"),space(200,@"second"),space(300,@"third")]},
        @{@"Display Identifier":@"external",@"Current Space":@{@"id64":@32},
            @"Spaces":@[space(32,@"external-space")]},
        @{@"Display Identifier":@"external-two",@"Current Space":@{@"id64":@33},
            @"Spaces":@[space(33,@"external-two-space")]}
    ];
    RecoveryHooks hooks={};hooks.inventory=all;hooks.missionState=fixtureMission;
    hooks.onlineTopology=fixtureOnline;recoveryHooks=&hooks;
    api().conn=fixtureConn;api().managed=fixtureManaged;
    api().windowSpaces=fixtureMembership;api().axWindow=fixtureAXWindow;
    assert(persist());
    active=false;reusedSlots.clear();initialSelections.clear();slots[0]=slots[1]=slots[2]=0;
    assert(loadJournal() && saved.empty() && reusedSlots.size()==3);
    assert(restoreLocked()==0 && saved.empty() && reusedSlots.empty()
        && slots[0]==0 && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    assert([all[0][@"Spaces"] count]==3 && [all[0][@"Current Space"][@"id64"] unsignedLongLongValue]==100);
    recoveryHooks=nullptr;

    reset();
    saved.push_back(ordinary);reusedSlots={{100,"builtin-space","builtin"},
        {200,"second","builtin"},{300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;lastSelectedSpace=100;active=true;
    kinds={{100,0},{200,0},{300,0},{32,0},{33,0}};
    RecoveryHooks alreadyHooks={};alreadyHooks.inventory=all;
    alreadyHooks.missionState=fixtureMission;alreadyHooks.onlineTopology=fixtureOnline;
    alreadyHooks.windowState=fixtureAXUnavailable;
    alreadyHooks.alreadyRestoredOrdinary=fixtureAlreadyRestored;
    recoveryHooks=&alreadyHooks;
    assert(persist());allowSecondAlreadyRestored=false;
    assert(restoreLocked()!=0 && [[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    allowSecondAlreadyRestored=true;
    assert(restoreLocked()==0 && saved.empty()
        && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    recoveryHooks=nullptr;

    reset();saved.clear();saved.push_back(ordinary);
    reusedSlots={{100,"builtin-space","builtin"},{200,"second","builtin"},
        {300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;lastSelectedSpace=100;
    kinds={{100,0},{200,0},{300,0},{32,0}};
    RecoveryHooks reusedHooks={};reusedHooks.windowSpace=fixtureReusableWindowSpace;
    reusedHooks.windowDisplay=fixtureReusableWindowDisplay;
    reusedHooks.switchDisplaySpace=fixtureReusableSwitch;
    recoveryHooks=&reusedHooks;selectedReusable=100;
    assert(fixtureReusableSwitch("builtin",100));
    reason.clear();reusedSlots[2].uuid="wrong";
    assert(prepareRecoveryWindowAccess(ordinary,7,&reason)==RecoverySpaceAccess::Failed
        && selectedReusable==100);
    reusedSlots[2].uuid="third";reason.clear();
    assert(prepareRecoveryWindowAccess(ordinary,7,&reason)==RecoverySpaceAccess::Ready
        && selectedReusable==300 && initialSelections[0].hostSpace==300
        && !selectionPending.active);
    assert(beginHostSelection("builtin",100,-1,SelectionPurpose::Final,7)
        && selectedReusable==100 && initialSelections[0].hostSpace==100
        && !selectionPending.active);
    assert(fixtureReusableSwitch("builtin",200));lastSelectedSpace=200;
    assert(prepareRecoveryWindowAccess(ordinary,7,&reason)==RecoverySpaceAccess::Ready
        && selectedReusable==300 && initialSelections[0].hostSpace==300);
    assert(beginHostSelection("builtin",100,-1,SelectionPurpose::Final,7)
        && selectedReusable==100 && initialSelections[0].hostSpace==100);
    assert(fixtureReusableSwitch("builtin",200));lastSelectedSpace=100;
    assert(prepareRecoveryWindowAccess(ordinary,7,&reason)==RecoverySpaceAccess::Failed
        && selectedReusable==200);
    assert(fixtureReusableSwitch("builtin",300));lastSelectedSpace=300;
    assert(prepareRecoveryWindowAccess(ordinary,7,&reason)==RecoverySpaceAccess::Ready
        && selectedReusable==300 && initialSelections[0].hostSpace==300);
    assert(beginHostSelection("builtin",100,-1,SelectionPurpose::Final,7)
        && selectedReusable==100 && initialSelections[0].hostSpace==100);
    assert(clearJournal());recoveryHooks=nullptr;

    reset();saved.clear();
    saved.push_back({75,43,"test.builtin","builtin",CGRectMake(80,90,400,300),
        CGRectMake(0,0,1147,745),1234567891,200,0,"builtin",true});
    ordinarySpaceIdentities.push_back({200,"builtin","second"});
    reusedSlots={{100,"builtin-space","builtin"},{200,"second","builtin"},
        {300,"third","builtin"}};
    slots[0]=100;slots[1]=200;slots[2]=300;lastSelectedSpace=100;active=true;
    kinds={{100,0},{200,0},{300,0},{32,0},{33,0}};
    builtinWindowSpace=100;builtinFrameRestores=0;
    RecoveryHooks builtinHooks={};builtinHooks.inventory=all;
    builtinHooks.onlineTopology=fixtureOnline;builtinHooks.missionState=fixtureMission;
    builtinHooks.windowSpace=fixtureBuiltinWindowSpace;
    builtinHooks.windowDisplay=fixtureBuiltinDisplay;
    builtinHooks.windowState=fixtureReady;builtinHooks.move=fixtureBuiltinMove;
    builtinHooks.frame=fixtureBuiltinFrame;recoveryHooks=&builtinHooks;
    assert(persist());
    assert(restoreLocked()==0 && builtinWindowSpace==200 && builtinFrameRestores==1
        && saved.empty() && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    recoveryHooks=nullptr;

    reusedCachedSlot.store(2);reusedCachedCount.store(3);reusedCachedLoop.store(1);
    {
        std::unique_lock<std::mutex> held(mutex);
        auto reads=std::async(std::launch::async,[] {
            return std::vector<int>{air_spaces_current_slot(),air_spaces_slot_count(),
                air_spaces_loop_supported()};
        });
        assert(reads.wait_for(std::chrono::milliseconds(250))==std::future_status::ready);
        assert(reads.get()==std::vector<int>({2,3,1}));
    }
    reusedCachedSlot.store(0);reusedCachedCount.store(0);reusedCachedLoop.store(0);

    journalTestPath=nil;
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    puts("ordinary UUID remap: journal roundtrip, matching replacement and fail-closed cases passed");
    return 0;
} }
