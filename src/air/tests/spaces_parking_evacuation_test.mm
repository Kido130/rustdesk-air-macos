#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static NSMutableDictionary *builtin=nil;
static int liveState=1,moveCalls=0,expectedVersion=12,transientCandidateMisses=0;
static ParkingWindowIdentity fixture={4098,77,"com.google.Chrome",1700000000,1234,5678,901,10,
    true,CGRectMake(10,20,900,600)};

static int conn(){return 7;}
static CFArrayRef managedStub(int){return nullptr;}
static int typeStub(int,uint64_t){return 0;}
static CFArrayRef membershipStub(int,int,CFArrayRef){return nullptr;}
static AXError axStub(AXUIElementRef,CGWindowID*){return kAXErrorFailure;}
static int missionStub(){return (int)MissionState::Absent;}
static bool parkingWindowsStub(uint64_t sid,std::vector<ParkingWindowIdentity> &result,std::string *reason) {
    if(transientCandidateMisses>0) {
        transientCandidateMisses--;
        if(reason)*reason="transient window inventory";
        return false;
    }
    result.clear();if(sid==fixture.sourceSpace && liveState==1)result.push_back(fixture);return true;
}
static int parkingStateStub(const ParkingWindowIdentity &window) {
    return window.id==fixture.id && window.pid==fixture.pid ? liveState : -1;
}
static NSDictionary *diskJournal() {
    NSData *data=[NSData dataWithContentsOfFile:journalTestPath];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static bool moveParkingStub(const ParkingWindowIdentity &window) {
    moveCalls++;NSDictionary *journal=diskJournal();NSDictionary *pending=journal[@"parkingEvacuation"];
    assert([journal[@"version"] intValue]==expectedVersion && [pending[@"id"] unsignedIntValue]==window.id
        && [pending[@"sourceSpace"] unsignedLongLongValue]==901
        && [pending[@"destinationSpace"] unsignedLongLongValue]==10
        && [pending[@"requiresAX"] boolValue]==window.requiresAX
        && [pending[@"w"] doubleValue]==window.cgFrame.size.width);
    if(liveState!=1)return false;liveState=2;return true;
}
static void clearMemory() {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();pendingCreateBefore.clear();
    initialSelections.clear();selectionPending={};parkingEvacuation={};wholeJournal={};
    slots[0]=slots[1]=slots[2]=0;initialSpace=0;lastSelectedSpace=0;builtinUUID.clear();
    active=false;switchVerified=false;pendingCreate=false;windowInventoryComplete=true;
    initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
}
static void seed() {
    clearMemory();
    air::whole_space::Topology prepared={{{"builtin",{10,11,901,902},{"b10","b11","p901","p902"},10},
        {"external-a",{20},{"a20"},20},{"external-b",{30},{"c30"},30}}};
    std::string reason;assert(air::whole_space::initialize(wholeJournal,prepared,"builtin",901,902,
        "p901","p902",[](uint64_t){return 0;},&reason));
    builtin=[@{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@10},
        @"Spaces":@[@{@"id64":@10,@"uuid":@"b10",@"type":@0},
            @{@"id64":@11,@"uuid":@"b11",@"type":@0},
            @{@"id64":@901,@"uuid":@"p901",@"type":@0},
            @{@"id64":@902,@"uuid":@"p902",@"type":@0}]} mutableCopy];
    recoveryHooks->inventory=@[builtin,
        @{@"Display Identifier":@"external-a",@"Current Space":@{@"id64":@20},
            @"Spaces":@[@{@"id64":@20,@"uuid":@"a20",@"type":@0}]},
        @{@"Display Identifier":@"external-b",@"Current Space":@{@"id64":@30},
            @"Spaces":@[@{@"id64":@30,@"uuid":@"c30",@"type":@0}]}];
    builtinUUID="builtin";initialSpace=10;createdSpaces={901,902};
    ownedSpaces={{901,"p901","builtin"},{902,"p902","builtin"}};
    assert(persist());assert(beginOwnedCleanup());
}

int main(int argc,char **argv){@autoreleasepool{
    NSString *parent=argc>1?[NSString stringWithUTF8String:argv[1]]:NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-parking-evacuation-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;std::vector<char> path(bytes.begin(),bytes.end());
    path.push_back(0);assert(mkdtemp(path.data()));NSString *base=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    RecoveryHooks hooks={};hooks.missionState=missionStub;hooks.parkingWindows=parkingWindowsStub;
    hooks.parkingWindowState=parkingStateStub;hooks.moveParkingWindow=moveParkingStub;recoveryHooks=&hooks;
    Api &native=api();native.conn=conn;native.managed=managedStub;native.spaceType=typeStub;
    native.windowSpaces=membershipStub;native.axWindow=axStub;

    seed();liveState=1;moveCalls=0;std::string reason;
    assert(evacuateOwnedParkingSpace(ownedSpaces[0],7,&reason));
    assert(liveState==2 && moveCalls==1 && !parkingEvacuation.active);
    assert(diskJournal()[@"parkingEvacuation"]==NSNull.null);

    // A moving auxiliary surface can fail an initial read. No mutation may
    // happen until a later complete inventory validates the exact candidate.
    seed();liveState=1;moveCalls=0;transientCandidateMisses=2;
    assert(evacuateOwnedParkingSpace(ownedSpaces[0],7,&reason));
    assert(transientCandidateMisses==0 && liveState==2 && moveCalls==1
        && !parkingEvacuation.active);

    // Window-based migration uses the same durable evacuation when a new
    // unrelated window lands on a temporary desktop during restoration.
    clearMemory();builtinUUID="builtin";initialSpace=10;createdSpaces={901};
    ownedSpaces={{901,"p901","builtin"}};expectedVersion=13;
    assert(persist());liveState=1;moveCalls=0;
    assert(evacuateOwnedParkingSpace(ownedSpaces[0],7,&reason));
    assert(liveState==2 && moveCalls==1 && !parkingEvacuation.active);
    liveState=1;parkingEvacuation={true,fixture};assert(persist());
    clearMemory();assert(loadJournal() && parkingEvacuation.active);
    moveCalls=0;assert(reconcileParkingEvacuation(7,&reason));
    assert(liveState==2 && moveCalls==1 && !parkingEvacuation.active);
    expectedVersion=12;

    // Crash after the OS move but before clearing the pending record: restart
    // accepts only the exact destination endpoint and performs no duplicate move.
    seed();liveState=1;parkingEvacuation={true,fixture};assert(persist());liveState=2;
    clearMemory();assert(loadJournal() && parkingEvacuation.active);moveCalls=0;
    assert(reconcileParkingEvacuation(7,&reason) && !parkingEvacuation.active && moveCalls==0);

    // Crash before the OS move: restart retries from the exact source and
    // keeps the pending record durable until the destination is revalidated.
    seed();liveState=1;parkingEvacuation={true,fixture};assert(persist());
    clearMemory();assert(loadJournal() && parkingEvacuation.active);moveCalls=0;
    assert(reconcileParkingEvacuation(7,&reason) && liveState==2 && moveCalls==1
        && !parkingEvacuation.active);

    // Any third Space/process endpoint fails closed and retains the journal.
    seed();liveState=-1;parkingEvacuation={true,fixture};assert(persist());
    clearMemory();assert(loadJournal() && parkingEvacuation.active);moveCalls=0;
    assert(!reconcileParkingEvacuation(7,&reason) && parkingEvacuation.active && moveCalls==0);
    assert(diskJournal()[@"parkingEvacuation"]!=NSNull.null);

    // A window closed during interruption needs no mutation; exact absence is
    // a valid retry endpoint.
    liveState=0;assert(reconcileParkingEvacuation(7,&reason));
    assert(!parkingEvacuation.active && moveCalls==0);

    seed();liveState=1;fixture.requiresAX=false;parkingEvacuation={true,fixture};assert(persist());
    clearMemory();assert(loadJournal() && parkingEvacuation.active
        && !parkingEvacuation.window.requiresAX
        && CGRectEqualToRect(parkingEvacuation.window.cgFrame,CGRectMake(10,20,900,600)));
    fixture.requiresAX=true;parkingEvacuation={};assert(persist());

    seed();NSDictionary *valid=diskJournal();NSMutableDictionary *bad=[valid mutableCopy];
    bad[@"parkingEvacuation"]=@{@"id":@4098,@"pid":@77,@"bundle":@"com.google.Chrome",
        @"launch":@1700000000,@"birthSeconds":@1234,@"birthMicroseconds":@5678,
        @"sourceSpace":@901,@"destinationSpace":@11};
    assert(!parseJournal(bad));

    // Keep the v12 whole-Space and v10 window-fallback schemas disjoint while
    // preserving compatibility with a pre-evacuation v9 whole-Space journal.
    bad=[valid mutableCopy];bad[@"inventoryComplete"]=@YES;
    assert(!parseJournal(bad));
    NSMutableDictionary *legacy=[valid mutableCopy];legacy[@"version"]=@9;
    [legacy removeObjectForKey:@"inventoryComplete"];
    [legacy removeObjectForKey:@"parkingEvacuation"];
    clearMemory();assert(parseJournal(legacy) && !wholeJournal.original.displays.empty()
        && !parkingEvacuation.active && windowInventoryComplete);

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("parking evacuation: durable pre-move record, source retry, destination adoption, conflict retention and exact endpoint validation passed");
    return 0;
}}
