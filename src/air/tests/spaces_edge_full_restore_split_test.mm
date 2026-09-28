#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

// The production restoreWholeLocked moveWholeSpace hook invokes WindowManager.
// Reverse its real journal algorithm against this inventory instead, then
// exercise restoreWholeLocked's final window/parking/journal path directly.
static std::string lastError;
extern "C" void air_set_error(const char *message) { lastError=message ?: ""; }
extern "C" int air_display_restore(void) { return 0; }

static air::whole_space::Topology liveTopology;
static NSMutableArray *liveInventory;
static uint64_t liveWindowSpace=20;
static std::string liveWindowDisplay="builtin";
static CGRect liveWindowFrame=CGRectMake(10,10,400,300);
static bool allowFrame=true;
static int reverseMoves=0,removedParking=0,windowMoves=0;

static NSMutableArray *inventory(const air::whole_space::Topology &topology) {
    NSMutableArray *rows=NSMutableArray.array;
    for(const auto &display:topology.displays) {
        NSMutableArray *spaces=NSMutableArray.array;
        for(size_t i=0;i<display.order.size();i++)
            [spaces addObject:@{@"id64":@(display.order[i]),
                @"uuid":[NSString stringWithUTF8String:display.spaceUUIDs[i].c_str()],
                @"type":@0}];
        [rows addObject:[@{@"Display Identifier":[NSString stringWithUTF8String:display.uuid.c_str()],
            @"Current Space":@{@"id64":@(display.current)},@"Spaces":spaces} mutableCopy]];
    }
    return rows;
}
static void refreshInventory() {
    liveInventory=inventory(liveTopology);
    recoveryHooks->inventory=liveInventory;
}
static int conn() { return 7; }
static CFArrayRef managedAPI(int) { return nullptr; }
static int spaceType(int,uint64_t) { return 0; }
static CFArrayRef membership(int,int,CFArrayRef) {
    return (__bridge_retained CFArrayRef)@[@(liveWindowSpace)];
}
static CFArrayRef spaceWindows(int,uint32_t,CFArrayRef,uint32_t,uint64_t *,uint64_t *) {
    return (__bridge_retained CFArrayRef)@[];
}
static CFStringRef windowDisplayAPI(int,uint32_t) { return nullptr; }
static AXError axWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static CGError dock(CFStringRef,int) { return kCGErrorSuccess; }
static bool online(std::vector<std::string> &displays,const std::string &,bool &builtin) {
    displays={"builtin","external-a","external-b"};builtin=true;return true;
}
static int mission() { return (int)MissionState::Absent; }
static int ready(const SavedWindow &) { return (int)WindowState::Ready; }
static uint64_t windowSpace(uint32_t) { return liveWindowSpace; }
static bool eligible(const SavedWindow &,uint64_t sid) { return sid==liveWindowSpace; }
static bool visible(uint32_t) { return true; }
static bool windowFrame(const SavedWindow &,CGRect *frame) { *frame=liveWindowFrame;return true; }
static bool finalIdentity(const SavedWindow &,uint64_t sid) { return sid==liveWindowSpace; }
static bool display(uint32_t,const std::string &uuid) { return uuid==liveWindowDisplay; }
static bool bounds(const std::string &uuid,CGRect *frame) {
    if(uuid!="external-a")return false;
    *frame=CGRectMake(-1920,0,1920,1080);return true;
}
static bool frameAt(const SavedWindow &,CGRect frame) {
    if(!allowFrame)return false;
    liveWindowFrame=frame;
    liveWindowDisplay=frame.origin.x<0 ? "external-a" : "builtin";
    return true;
}
static bool moveWindow(uint32_t,uint64_t sid) {
    for(const auto &row:liveTopology.displays)
        if(std::find(row.order.begin(),row.order.end(),sid)!=row.order.end()) {
            ++windowMoves;liveWindowSpace=sid;liveWindowDisplay=row.uuid;return true;
        }
    return false;
}
static bool selectDisplay(const std::string &uuid,uint64_t sid) {
    for(auto &row:liveTopology.displays)if(row.uuid==uuid) {
        if(std::find(row.order.begin(),row.order.end(),sid)==row.order.end())return false;
        row.current=sid;refreshInventory();return true;
    }
    return false;
}
static bool removeParking(uint64_t sid) {
    for(auto &row:liveTopology.displays)for(size_t i=0;i<row.order.size();i++)
        if(row.order[i]==sid) {
            row.order.erase(row.order.begin()+i);
            row.spaceUUIDs.erase(row.spaceUUIDs.begin()+i);
            ++removedParking;refreshInventory();return true;
        }
    return false;
}
static bool parkingWindows(uint64_t,std::vector<ParkingWindowIdentity> &windows,std::string *) {
    windows.clear();return true;
}

int main() { @autoreleasepool {
    const air::whole_space::Topology original={{{"builtin",{10,11},{"b10","b11"},10},
        {"external-a",{20,21,22},{"a20","a21","a22"},20},
        {"external-b",{30,31,32},{"c30","c31","c32"},30}}};
    const air::whole_space::Topology prepared={{{"builtin",{10,11,901,902},
        {"b10","b11","p901","p902"},10},
        {"external-a",{20,21,22},{"a20","a21","a22"},20},
        {"external-b",{30,31,32},{"c30","c31","c32"},30}}};
    std::string why;
    assert(air::whole_space::initialize(wholeJournal,prepared,"builtin",901,902,
        "p901","p902",[](uint64_t){return 0;},&why));
    assert(air::whole_space::finalOriginalPreservingExtras(wholeJournal,original));
    wholeJournal.forwardDone=4;wholeJournal.runtimeCurrent=wholeJournal.selected[1];
    assert(air::whole_space::stageTopology(wholeJournal,
        air::whole_space::Direction::Forward,4,liveTopology));
    for(auto &row:liveTopology.displays)if(row.uuid=="builtin")
        row.current=wholeJournal.runtimeCurrent;
    RecoveryHooks hooks={};recoveryHooks=&hooks;refreshInventory();
    hooks.windowSpace=windowSpace;hooks.windowState=ready;hooks.move=moveWindow;
    hooks.edgeWindowEligible=eligible;hooks.edgeWindowVisible=visible;
    hooks.edgeWindowFrame=windowFrame;hooks.finalWindowIdentity=finalIdentity;
    hooks.windowDisplay=display;hooks.displayBounds=bounds;hooks.frameAt=frameAt;
    hooks.switchDisplaySpace=selectDisplay;hooks.missionState=mission;
    hooks.onlineTopology=online;hooks.parkingWindows=parkingWindows;
    hooks.remove=removeParking;
    Api &native=api();native.conn=conn;native.managed=managedAPI;
    native.windowSpaces=membership;native.spaceWindows=spaceWindows;
    native.spaceType=spaceType;native.windowDisplay=windowDisplayAPI;
    native.axWindow=axWindow;native.dock=dock;

    builtinUUID="builtin";initialSpace=wholeJournal.selected[0];
    lastSelectedSpace=wholeJournal.runtimeCurrent;
    for(int i=0;i<3;i++)slots[i]=wholeJournal.selected[i];
    createdSpaces={901,902};
    ownedSpaces={{901,"p901","builtin"},{902,"p902","builtin"}};
    active=true;wholeFrameInventoryComplete=true;
    ProcessBirth birth=processBirth(getpid());assert(birth.valid());
    SavedWindow hidden={701,getpid(),"fixture.app","Hidden",CGRectMake(-1800,10,400,300),
        CGRectMake(-1920,0,1920,1080),birth.seconds+birth.microseconds/1000000.0,
        21,1,"external-a",true};
    hidden.birthSeconds=birth.seconds;hidden.birthMicroseconds=birth.microseconds;
    hidden.memberships={21};saved={hidden};
    NSString *pattern=[NSTemporaryDirectory() stringByAppendingPathComponent:@"air-edge-full-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> path(bytes.begin(),bytes.end());path.push_back(0);
    assert(mkdtemp(path.data()));
    NSString *folder=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    assert(acquireJournalLock() && persist());

    // Activation has put an originally inactive Space21 window in slot 2.
    liveWindowSpace=20;liveWindowDisplay="builtin";
    assert(air_spaces_transfer_window_edge(701,2,1)==0);
    assert(liveWindowSpace==30 && edgeTransfers.size()==1
        && edgeTransfers[0].original==21);
    saved.clear();edgeTransfers.clear();wholeJournal={};
    assert(loadJournal() && edgeTransfers.size()==1 && saved.size()==1);
    assert(reconcileEdgeTransfers(7,why) && liveWindowSpace==20 && edgeTransfers.empty());

    // This is the real reverse algorithm, with only the OS move/select
    // operations represented by an in-memory inventory. It cannot call
    // restoreWholeLocked for reverse because that would operate Pro Spaces.
    air::whole_space::Hooks reverse={
        [](const air::whole_space::Journal &journal){
            lastSelectedSpace=journal.runtimeCurrent;return persist();
        },
        []{return liveTopology;},
        [](uint64_t sid,const std::string &destination,uint32_t index){
            assert(wholeJournal.pending.active && wholeJournal.pending.move.sid==sid
                && wholeJournal.pending.move.to.display==destination
                && wholeJournal.pending.move.to.index==index);
            air::whole_space::Topology next;
            assert(air::whole_space::stageTopology(wholeJournal,
                air::whole_space::Direction::Reverse,
                wholeJournal.pending.ordinal+1,next));
            // Preserve any current-display selection already normalized by
            // the preceding journal operation.
            for(auto &row:next.displays)for(const auto &prior:liveTopology.displays)
                if(row.uuid==prior.uuid && std::find(row.order.begin(),row.order.end(),
                    prior.current)!=row.order.end())row.current=prior.current;
            liveTopology=next;refreshInventory();++reverseMoves;return true;
        },
        [](const std::string &uuid,uint64_t sid){return selectDisplay(uuid,sid);}
    };
    assert(air::whole_space::normalizeForReverse(wholeJournal,reverse,&why));
    while(wholeJournal.reverseDone<4)
        assert(air::whole_space::advanceReverse(wholeJournal,reverse,&why));
    while(wholeJournal.selectionDone<3)
        assert(air::whole_space::advanceSelections(wholeJournal,reverse,&why));
    assert(reverseMoves==4 && wholeJournal.reverseDone==4
        && wholeJournal.selectionDone==3 && liveWindowSpace==20);

    // The production restore function must move the exact WID back to its
    // inactive original Space21, restore its frame, delete both owned parking
    // Spaces, and clear the durable journal. A failed frame leaves recovery.
    allowFrame=false;
    int firstRestore=restoreWholeLocked();
    if(firstRestore==0 || liveWindowSpace!=21)
        fprintf(stderr,"first restore=%d windowSpace=%llu error=%s\n",firstRestore,
            (unsigned long long)liveWindowSpace,lastError.c_str());
    assert(firstRestore!=0 && liveWindowSpace==21
        && createdSpaces.size()==2
        && [[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    saved.clear();createdSpaces.clear();ownedSpaces.clear();wholeJournal={};
    bool reloaded=loadJournal();
    if(!reloaded || saved.size()!=1 || createdSpaces.size()!=2)
        fprintf(stderr,"reload=%d windows=%zu parking=%zu reverse=%u selection=%u io=%s\n",
            reloaded,saved.size(),createdSpaces.size(),wholeJournal.reverseDone,
            wholeJournal.selectionDone,journalIOError.c_str());
    assert(reloaded && saved.size()==1 && saved[0].space==21
        && createdSpaces.size()==2 && wholeJournal.reverseDone==4
        && wholeJournal.selectionDone==3);
    allowFrame=true;
    int secondRestore=restoreWholeLocked();
    if(secondRestore!=0)
        fprintf(stderr,"second restore=%d windowSpace=%llu error=%s reverse=%u selection=%u parking=%zu\n",
            secondRestore,(unsigned long long)liveWindowSpace,lastError.c_str(),
            wholeJournal.reverseDone,wholeJournal.selectionDone,createdSpaces.size());
    assert(secondRestore==0 && liveWindowSpace==21
        && nearFrame(liveWindowFrame,hidden.frame)
        && liveWindowDisplay=="external-a" && removedParking==2
        && saved.empty() && ownedSpaces.empty() && createdSpaces.empty()
        && wholeJournal.original.displays.empty()
        && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    for(size_t i=0;i<original.displays.size();i++) {
        assert(liveTopology.displays[i].uuid==original.displays[i].uuid);
        assert(liveTopology.displays[i].order==original.displays[i].order);
        assert(liveTopology.displays[i].spaceUUIDs==original.displays[i].spaceUUIDs);
        assert(liveTopology.displays[i].current==original.displays[i].current);
    }
    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);
    puts("Space edge split lifecycle: core reverse, hidden-window restore, parking cleanup, journal clear passed");
} }
