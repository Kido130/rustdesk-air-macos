#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return -1; }

static bool builtinOnline=false,externalOnline=true,displayReady=false,allowMove=true,invalidateDuringDisplay=false;
static int monitorCalls=0,displayCalls=0,moveCalls=0,frameCalls=0;
static std::vector<std::pair<uint64_t,uint64_t>> scheduled;
static NSMutableDictionary *builtinFixture=nil;
static NSDictionary *externalFixture=nil;
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t) { return 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) { return nullptr; }
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &) { return (int)WindowState::Ready; }
static bool fixtureMove(uint32_t,uint64_t) { ++moveCalls;return allowMove; }
static bool fixtureFrame(const SavedWindow &) { ++frameCalls;return true; }
static bool fixtureWindowDisplay(uint32_t,const std::string &) { return true; }
static bool fixtureSwitch(uint64_t) { assert(false && "initial Space is already selected");return false; }
static bool fixtureRemove(uint64_t) { assert(false && "no Space is owned");return false; }
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureTopology(std::vector<std::string> &topology,const std::string &uuid,bool &online) {
    assert(uuid=="builtin-uuid");
    topology.clear();
    if(builtinOnline)topology.push_back("builtin-uuid");
    if(externalOnline)topology.push_back("external-uuid");
    online=builtinOnline;return true;
}
static bool fixtureMonitor() { ++monitorCalls;return true; }
static int fixtureDisplayRestore() {
    ++displayCalls;
    assert(mutex.try_lock()); // The display path must run outside the Spaces mutex.
    assert(retryDisplayInFlight);
    mutex.unlock();
    assert(air_spaces_prepare()!=0);
    assert(air_spaces_recover()!=0);
    if(invalidateDuringDisplay) {
        std::lock_guard<std::mutex> lock(mutex);
        ++recoveryGeneration;pendingDisplayRecovery=false;
    }
    return displayReady ? 0 : -1;
}
static void fixtureSchedule(uint64_t generation,uint64_t burst,unsigned attempt) {
    scheduled.push_back({generation,burst});
    assert(attempt<3);
}
static void makeJournal() {
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    initialSpace=639;builtinUUID="builtin-uuid";lastSelectedSpace=639;
    slots[0]=639;slots[1]=900;slots[2]=512;
    assert(persist());
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-deferred-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    builtinFixture=[@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@639},
        @"Spaces":@[@{@"id64":@639,@"uuid":@"original",@"type":@0}]} mutableCopy];
    externalFixture=@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"external",@"type":@0}]};
    RecoveryHooks hooks={};
    hooks.inventory=@[externalFixture];
    hooks.windowState=fixtureWindowState;hooks.move=fixtureMove;
    hooks.frame=fixtureFrame;hooks.windowDisplay=fixtureWindowDisplay;
    hooks.switchSpace=fixtureSwitch;hooks.remove=fixtureRemove;
    hooks.missionState=fixtureMission;hooks.onlineTopology=fixtureTopology;
    hooks.registerCallback=fixtureMonitor;hooks.displayRestore=fixtureDisplayRestore;
    hooks.scheduleRetry=fixtureSchedule;recoveryHooks=&hooks;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;
    native.axWindow=fixtureAXWindow;
    makeJournal();

    assert(restoreLocked()!=0 && pendingDisplayRecovery && monitorCalls==1);
    assert(moveCalls==0 && frameCalls==0 && displayCalls==0);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    processSpacesDisplayChangedLocked();
    assert(scheduled.empty());

    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled.size()==1);
    uint64_t firstGeneration=recoveryGeneration,firstBurst=retryBurst;
    retryRecovery(firstGeneration,firstBurst,0);
    retryRecovery(firstGeneration,firstBurst,1);
    retryRecovery(firstGeneration,firstBurst,2);
    assert(displayCalls==3 && moveCalls==0 && scheduled.size()==3);
    assert(pendingDisplayRecovery && !saved.empty());
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    // A changed topology creates one new bounded burst; an old timer is inert.
    builtinOnline=false;hooks.inventory=@[externalFixture];
    processSpacesDisplayChangedLocked();
    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled.size()==4 && retryBurst!=firstBurst);
    retryRecovery(firstGeneration,firstBurst,2);
    assert(displayCalls==3);
    displayReady=true;allowMove=false;
    uint64_t secondBurst=retryBurst;
    retryRecovery(recoveryGeneration,secondBurst,0);
    assert(displayCalls==4 && moveCalls==1 && frameCalls==0 && scheduled.size()==5);
    allowMove=true;
    retryRecovery(recoveryGeneration,secondBurst,1);
    assert(displayCalls==5 && moveCalls==2 && frameCalls==1);
    assert(saved.empty() && !pendingDisplayRecovery && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    // A present built-in display is insufficient when the window's original
    // external display is missing.  Keep the journal and retry on its return.
    makeJournal();
    externalOnline=false;hooks.inventory=@[builtinFixture];
    int externalDisplayCalls=displayCalls,externalMoveCalls=moveCalls,externalFrameCalls=frameCalls;
    size_t beforeExternalSchedule=scheduled.size();
    assert(restoreLocked()!=0 && pendingDisplayRecovery && monitorCalls==1);
    assert(moveCalls==externalMoveCalls && frameCalls==externalFrameCalls
        && displayCalls==externalDisplayCalls);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    processSpacesDisplayChangedLocked();
    assert(scheduled.size()==beforeExternalSchedule);
    externalOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled.size()==beforeExternalSchedule+1);
    uint64_t externalGeneration=recoveryGeneration,externalBurst=retryBurst;
    retryRecovery(externalGeneration,externalBurst,0);
    assert(displayCalls==externalDisplayCalls+1 && moveCalls==externalMoveCalls+1);
    assert(saved.empty() && !pendingDisplayRecovery && ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    // A change during display restoration invalidates the pending Spaces action.
    builtinOnline=false;hooks.inventory=@[externalFixture];
    makeJournal();
    assert(restoreLocked()!=0 && pendingDisplayRecovery);
    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    uint64_t interruptedGeneration=recoveryGeneration,interruptedBurst=retryBurst;
    int oldDisplayCalls=displayCalls,oldMoveCalls=moveCalls;
    invalidateDuringDisplay=true;
    retryRecovery(interruptedGeneration,interruptedBurst,0);
    invalidateDuringDisplay=false;
    assert(displayCalls==oldDisplayCalls+1 && moveCalls==oldMoveCalls && !pendingDisplayRecovery);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    assert(restoreLocked()==0 && saved.empty());

    // A delayed callback from a prior recovery cannot act on a later journal.
    makeJournal();
    oldDisplayCalls=displayCalls;oldMoveCalls=moveCalls;
    retryRecovery(interruptedGeneration,interruptedBurst,0);
    retryRecovery(firstGeneration,secondBurst,1);
    assert(displayCalls==oldDisplayCalls && moveCalls==oldMoveCalls);
    assert(!pendingDisplayRecovery && !saved.empty());
    assert(restoreLocked()==0 && saved.empty());

    // Shutdown suppresses reconfiguration-driven recovery but retains the journal.
    builtinOnline=false;hooks.inventory=@[externalFixture];
    makeJournal();
    assert(restoreLocked()!=0 && pendingDisplayRecovery);
    size_t priorSchedules=scheduled.size();
    assert(air_spaces_shutdown()!=0 && shuttingDown && !pendingDisplayRecovery);
    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled.size()==priorSchedules && [[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("deferred Spaces: absence/return, display-first retry, bounded failures, topology burst, stale timer, shutdown passed");
    return 0;
} }
