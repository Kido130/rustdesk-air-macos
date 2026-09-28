#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static NSMutableArray *fixtureInventory;
static uint64_t fixtureWindowSpace;
static std::string fixtureWindowDisplay="builtin";
static CGRect fixtureWindowFrame=CGRectMake(10,10,400,300);
static bool refuseMove=false;
static bool refuseFrame=false;
static int moveCalls=0;
static int selectCalls=0;
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t) { return 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) {
    return (__bridge_retained CFArrayRef)@[@(fixtureWindowSpace)];
}
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static bool fixtureEligible(const SavedWindow &,uint64_t sid) { return sid==fixtureWindowSpace; }
static bool fixtureVisible(uint32_t) { return true; }
static int fixtureWindowState(const SavedWindow &) { return (int)WindowState::Ready; }
static uint64_t fixtureSpace(uint32_t) { return fixtureWindowSpace; }
static bool fixtureMove(uint32_t,uint64_t sid) {
    ++moveCalls;
    if(refuseMove)return false;
    fixtureWindowSpace=sid;return true;
}
static bool fixtureDisplay(uint32_t,const std::string &uuid) { return fixtureWindowDisplay==uuid; }
static bool fixtureFrame(const SavedWindow &,CGRect *frame) { *frame=fixtureWindowFrame;return true; }
static bool fixtureFinalIdentity(const SavedWindow &,uint64_t sid) {
    return sid==fixtureWindowSpace;
}
static bool fixtureBounds(const std::string &uuid,CGRect *bounds) {
    if(uuid!="external-a")return false;
    *bounds=CGRectMake(-1920,0,1920,1080);return true;
}
static bool fixtureSetFrame(const SavedWindow &,CGRect frame) {
    if(refuseFrame)return false;
    fixtureWindowFrame=frame;
    fixtureWindowDisplay=frame.origin.x<0 ? "external-a" : "builtin";
    return true;
}
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureSelect(const std::string &uuid,uint64_t sid) {
    if(uuid!="builtin")return false;
    ++selectCalls;
    NSMutableDictionary *display=fixtureInventory[0];
    display[@"Current Space"]=@{@"id64":@(sid)};
    return true;
}
static NSMutableArray *managedFixture(const air::whole_space::Topology &topology) {
    NSMutableArray *displays=NSMutableArray.array;
    for(const auto &display:topology.displays) {
        NSMutableArray *spaces=NSMutableArray.array;
        for(size_t index=0;index<display.order.size();index++)
            [spaces addObject:@{@"id64":@(display.order[index]),
                @"uuid":[NSString stringWithUTF8String:display.spaceUUIDs[index].c_str()],
                @"type":@0}];
        [displays addObject:[@{@"Display Identifier":[NSString stringWithUTF8String:display.uuid.c_str()],
            @"Current Space":@{@"id64":@(display.current)},@"Spaces":spaces} mutableCopy]];
    }
    return displays;
}

int main() { @autoreleasepool {
    air::whole_space::Topology prepared={{{"builtin",{10,11,901,902},
        {"b10","b11","p901","p902"},10},
        {"external-a",{20,21,22},{"a20","a21","a22"},20},
        {"external-b",{30,31,32},{"c30","c31","c32"},30}}};
    std::string why;
    assert(air::whole_space::initialize(wholeJournal,prepared,"builtin",901,902,
        "p901","p902",[](uint64_t){return 0;},&why));
    wholeJournal.forwardDone=4;wholeJournal.runtimeCurrent=wholeJournal.selected[1];
    air::whole_space::Topology activeTopology;
    assert(air::whole_space::stageTopology(wholeJournal,
        air::whole_space::Direction::Forward,4,activeTopology));
    activeTopology.displays[0].current=wholeJournal.runtimeCurrent;
    fixtureInventory=managedFixture(activeTopology);
    builtinUUID="builtin";initialSpace=wholeJournal.selected[0];
    createdSpaces={901,902};
    ownedSpaces={{901,"p901","builtin"},{902,"p902","builtin"}};
    for(int i=0;i<3;i++)slots[i]=wholeJournal.selected[i];
    lastSelectedSpace=wholeJournal.runtimeCurrent;
    active=true;wholeFrameInventoryComplete=true;
    fixtureWindowSpace=wholeJournal.selected[1];
    ProcessBirth birth=processBirth(getpid());assert(birth.valid());
    SavedWindow window={700,(pid_t)getpid(),"fixture.app","Window",CGRectMake(10,10,400,300),
        CGRectMake(-1920,0,1920,1080),birth.seconds+birth.microseconds/1000000.0,
        20,1,"external-a",true};
    window.birthSeconds=birth.seconds;window.birthMicroseconds=birth.microseconds;
    window.memberships={20};saved={window};
    RecoveryHooks hooks={};hooks.inventory=fixtureInventory;
    hooks.windowSpace=fixtureSpace;hooks.move=fixtureMove;
    hooks.windowDisplay=fixtureDisplay;hooks.missionState=fixtureMission;
    hooks.switchDisplaySpace=fixtureSelect;hooks.edgeWindowEligible=fixtureEligible;
    hooks.edgeWindowVisible=fixtureVisible;hooks.edgeWindowFrame=fixtureFrame;
    hooks.frameAt=fixtureSetFrame;hooks.windowState=fixtureWindowState;
    hooks.finalWindowIdentity=fixtureFinalIdentity;hooks.displayBounds=fixtureBounds;
    recoveryHooks=&hooks;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;
    native.axWindow=fixtureAXWindow;
    NSString *pattern=[NSTemporaryDirectory() stringByAppendingPathComponent:@"air-edge-test-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> path(bytes.begin(),bytes.end());path.push_back(0);
    assert(mkdtemp(path.data()));
    NSString *folder=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    assert(acquireJournalLock() && persist());
    NSString *validPath=journalTestPath;
    journalTestPath=@"/dev/null/air-edge-test-recovery.json";
    assert(air_spaces_transfer_window_edge(700,2,1)!=0);
    assert(edgeTransfers.empty() && fixtureWindowSpace==20 && moveCalls==0);
    journalTestPath=validPath;

    assert(air_spaces_transfer_window_edge(700,2,1)==0);
    assert(fixtureWindowSpace==30 && wholeJournal.runtimeCurrent==30
        && edgeTransfers.size()==1 && edgeTransfers[0].stage==3
        && moveCalls==1 && selectCalls==1);
    NSDictionary *journal=dictionary([NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil]);
    assert([number(journal[@"version"]) intValue]==21);
    assert([array(journal[@"edgeTransfers"]) count]==1);
    NSMutableDictionary *corrupt=[journal mutableCopy];
    NSMutableDictionary *badEdge=[array(journal[@"edgeTransfers"])[0] mutableCopy];
    badEdge[@"releaseDisplay"]=@"unknown-display";
    corrupt[@"edgeTransfers"]=@[badEdge];
    assert(!parseJournal(corrupt));

    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers.size()==1 && edgeTransfers[0].original==20);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty() && moveCalls==2);
    assert(air_spaces_transfer_window_edge(700,2,1)!=0);
    assert(fixtureWindowSpace==20 && moveCalls==2);

    // A crash can occur after the private move succeeds but before stage 2 is written.
    edgeTransfers.push_back({700,20,20,30,1,20,"builtin",fixtureWindowFrame});
    fixtureWindowSpace=30;
    assert(persist());
    edgeTransfers.clear();saved.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers.size()==1 && edgeTransfers[0].stage==1);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty() && moveCalls==3);

    // The opposite edge moves the same verified window from slot 3 to slot 2.
    fixtureWindowSpace=30;
    assert(air_spaces_transfer_window_edge(700,3,-1)==0);
    assert(fixtureWindowSpace==20 && edgeTransfers.size()==1
        && edgeTransfers[0].original==20 && edgeTransfers[0].target==20);
    assert(reconcileEdgeTransfers(7,why) && edgeTransfers.empty());

    // At the physical left seam, the exact window can be assigned to an
    // external display and ordinary Space before button release.
    fixtureWindowSpace=21;fixtureWindowDisplay="external-a";
    fixtureWindowFrame=CGRectMake(-16,10,400,300);
    assert(fixtureSelect("builtin",20));
    wholeJournal.runtimeCurrent=20;lastSelectedSpace=20;
    assert(air_spaces_transfer_window_edge(700,2,-1)==0);
    assert(fixtureWindowSpace==10 && fixtureWindowDisplay=="builtin"
        && edgeTransfers[0].releaseSpace==21
        && edgeTransfers[0].releaseDisplay=="external-a"
        && edgeTransfers[0].releaseFrame.origin.x==-16);
    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers[0].releaseSpace==21);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty());

    fixtureWindowSpace=21;fixtureWindowDisplay="external-a";
    fixtureWindowFrame=CGRectMake(-16,10,400,300);
    assert(fixtureSelect("builtin",20));
    wholeJournal.runtimeCurrent=20;lastSelectedSpace=20;
    refuseFrame=true;
    assert(air_spaces_transfer_window_edge(700,2,-1)!=0);
    assert(fixtureWindowSpace==21 && edgeTransfers.size()==1
        && edgeTransfers[0].stage==1);
    refuseFrame=false;
    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers[0].releaseSpace==21);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty());

    // Native macOS switching can move the exact WID before Host writes an
    // edge intent; the saved whole-window ledger still restores it.
    fixtureWindowSpace=30;
    assert(reconcileUnjournaledEdgeMoves(7,why) && fixtureWindowSpace==20);

    fixtureWindowSpace=10;
    assert(fixtureSelect("builtin",10));
    wholeJournal.runtimeCurrent=10;lastSelectedSpace=10;
    assert(air_spaces_transfer_window_edge(700,2,-1)==0);
    assert(fixtureWindowSpace==10 && edgeTransfers[0].releaseSpace==10);
    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers[0].releaseSpace==10);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20);

    fixtureWindowSpace=30;
    assert(fixtureSelect("builtin",30));
    wholeJournal.runtimeCurrent=30;lastSelectedSpace=30;
    assert(persist());
    refuseMove=true;
    assert(air_spaces_transfer_window_edge(700,3,-1)!=0);
    assert(fixtureWindowSpace==30 && edgeTransfers.size()==1
        && edgeTransfers[0].stage==1);
    refuseMove=false;
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty());

    SavedWindow hidden=window;
    hidden.id=701;hidden.space=21;hidden.memberships={21};
    hidden.frame=CGRectMake(-1800,10,400,300);
    saved={hidden};fixtureWindowSpace=21;fixtureWindowDisplay="external-a";
    fixtureWindowFrame=CGRectMake(-1800,10,400,300);
    int beforeHidden=moveCalls;
    assert(reconcileUnjournaledEdgeMoves(7,why)
        && fixtureWindowSpace==21 && moveCalls==beforeHidden);

    // Successful activation puts even an originally hidden window in slot 2.
    // Edge recovery returns it there before topology reversal; the original
    // Space21 remains in the saved full-window ledger for final restoration.
    fixtureWindowSpace=20;fixtureWindowDisplay="builtin";
    fixtureWindowFrame=CGRectMake(10,10,400,300);
    assert(fixtureSelect("builtin",20));
    wholeJournal.runtimeCurrent=20;lastSelectedSpace=20;
    assert(persist());
    assert(air_spaces_transfer_window_edge(701,2,1)==0);
    assert(edgeTransfers[0].original==21 && fixtureWindowSpace==30);
    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers[0].original==21);
    assert(reconcileEdgeTransfers(7,why) && fixtureWindowSpace==20
        && edgeTransfers.empty());
    // After the whole-Space topology is reversed, final restoration moves
    // the exact WID from selected20 to its original hidden21 and frame.
    fixtureInventory=managedFixture(prepared);
    hooks.inventory=fixtureInventory;
    fixtureWindowDisplay="external-a";
    refuseFrame=true;
    assert(!restoreWholeWindowFrames(7,why) && fixtureWindowSpace==21);
    refuseFrame=false;
    assert(restoreWholeWindowFrames(7,why) && fixtureWindowSpace==21
        && nearFrame(fixtureWindowFrame,hidden.frame));

    SavedWindow hiddenCG=hidden;
    hiddenCG.id=702;hiddenCG.frameFromAX=false;hiddenCG.cgOnly=true;
    hiddenCG.title="CG fixture";
    saved={hiddenCG};fixtureWindowSpace=20;
    fixtureWindowDisplay="external-a";
    fixtureWindowFrame=CGRectMake(10,10,400,300);
    refuseMove=true;
    assert(!restoreWholeWindowFrames(7,why) && fixtureWindowSpace==20);
    refuseMove=false;
    assert(restoreWholeWindowFrames(7,why) && fixtureWindowSpace==21
        && nearFrame(fixtureWindowFrame,hiddenCG.frame));

    assert([[NSFileManager defaultManager] removeItemAtPath:journalTestPath error:nil]);
    releaseJournalLock();
    assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);
    recoveryHooks=nullptr;journalTestPath=nil;
    puts("Space edge transfer: adjacent verified move, durable reload/recovery, refusal and failed move passed");
} }
