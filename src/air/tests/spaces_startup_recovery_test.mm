#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

static std::string lastError;
extern "C" void air_set_error(const char *message) { lastError=message ?: ""; }
extern "C" int air_display_restore(void) { return 0; }
static bool builtinOnline=false,externalOnline=true,allowMonitor=true,allowMove=true;
static int monitorCalls=0,moveCalls=0,scheduled=0;
static NSMutableDictionary *builtinFixture=nil;
static NSDictionary *externalFixture=nil;
static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static int fixtureType(int,uint64_t) { return 0; }
static CFArrayRef fixtureMembership(int,int,CFArrayRef) { return nullptr; }
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int fixtureWindowState(const SavedWindow &) { return (int)WindowState::Ready; }
static bool fixtureMove(uint32_t,uint64_t) { ++moveCalls;return allowMove; }
static bool fixtureFrame(const SavedWindow &) { return true; }
static bool fixtureWindowDisplay(uint32_t,const std::string &) { return true; }
static int fixtureMission() { return (int)MissionState::Absent; }
static bool fixtureTopology(std::vector<std::string> &topology,const std::string &,bool &online) {
    topology.clear();
    if(builtinOnline)topology.push_back("builtin-uuid");
    if(externalOnline)topology.push_back("external-uuid");
    online=builtinOnline;return true;
}
static bool fixtureMonitor() { ++monitorCalls;return allowMonitor; }
static void fixtureSchedule(uint64_t,uint64_t,unsigned) { ++scheduled; }
static bool fixtureEnabled() { return true; }
static void makeJournal() {
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    initialSpace=639;builtinUUID="builtin-uuid";
    slots[0]=slots[1]=slots[2]=0;
    assert(persist());
}
static void restartMemory() {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();initialSpace=0;builtinUUID.clear();
    slots[0]=slots[1]=slots[2]=0;pendingDisplayRecovery=false;callbackRegistered=false;
    observedTopology.clear();lastSelectedSpace=0;active=false;
}
int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-startup-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    NSString *path=[base stringByAppendingPathComponent:@"recovery.json"];
    journalTestPath=path;
    builtinFixture=[@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@639},
        @"Spaces":@[@{@"id64":@639,@"uuid":@"original",@"type":@0}]} mutableCopy];
    externalFixture=@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"external",@"type":@0}]};
    RecoveryHooks hooks={};hooks.inventory=@[externalFixture];
    hooks.windowState=fixtureWindowState;hooks.move=fixtureMove;
    hooks.frame=fixtureFrame;hooks.windowDisplay=fixtureWindowDisplay;
    hooks.missionState=fixtureMission;hooks.onlineTopology=fixtureTopology;
    hooks.registerCallback=fixtureMonitor;hooks.scheduleRetry=fixtureSchedule;
    hooks.enabled=fixtureEnabled;recoveryHooks=&hooks;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.spaceType=fixtureType;native.windowSpaces=fixtureMembership;
    native.axWindow=fixtureAXWindow;

    makeJournal();restartMemory();
    assert(air_spaces_recover()==0 && lastError.empty() && pendingDisplayRecovery);
    assert(monitorCalls==1 && moveCalls==0 && [[NSFileManager defaultManager] fileExistsAtPath:path]);
    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled==1);
    retryRecovery(recoveryGeneration,retryBurst,0);
    assert(moveCalls==1 && saved.empty() && ![[NSFileManager defaultManager] fileExistsAtPath:path]);

    // Startup also accepts a valid retained journal while only an original
    // external display is absent, then resumes when that display returns.
    externalOnline=false;hooks.inventory=@[builtinFixture];
    makeJournal();restartMemory();
    int beforeExternalMove=moveCalls,beforeExternalSchedule=scheduled;
    assert(air_spaces_recover()==0 && lastError.empty() && pendingDisplayRecovery);
    assert(moveCalls==beforeExternalMove && [[NSFileManager defaultManager] fileExistsAtPath:path]);
    processSpacesDisplayChangedLocked();
    assert(scheduled==beforeExternalSchedule);
    externalOnline=true;hooks.inventory=@[builtinFixture,externalFixture];
    processSpacesDisplayChangedLocked();
    assert(scheduled==beforeExternalSchedule+1);
    retryRecovery(recoveryGeneration,retryBurst,0);
    assert(moveCalls==beforeExternalMove+1 && saved.empty()
        && ![[NSFileManager defaultManager] fileExistsAtPath:path]);

    assert([@"invalid" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    restartMemory();
    assert(air_spaces_recover()!=0 && !pendingDisplayRecovery);
    assert([[NSFileManager defaultManager] removeItemAtPath:path error:nil]);

    builtinOnline=false;hooks.inventory=@[externalFixture];allowMonitor=false;
    makeJournal();restartMemory();
    assert(air_spaces_recover()!=0 && pendingDisplayRecovery && !callbackRegistered);
    assert([[NSFileManager defaultManager] fileExistsAtPath:path]);

    builtinOnline=true;hooks.inventory=@[builtinFixture,externalFixture];allowMonitor=true;allowMove=false;
    restartMemory();
    int failedRestore=air_spaces_recover();
    assert(failedRestore!=0 && !pendingDisplayRecovery
        && moveCalls>beforeExternalMove+1);
    assert([[NSFileManager defaultManager] fileExistsAtPath:path]);

    // A valid journal read through a directory symlink must not mask a failed refresh.
    NSString *linked=[base stringByAppendingPathComponent:@"linked"];
    NSString *absoluteBase=[base hasPrefix:@"/"] ? base
        : [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:base];
    assert(symlink(absoluteBase.fileSystemRepresentation,linked.fileSystemRepresentation)==0);
    journalTestPath=[linked stringByAppendingPathComponent:@"recovery.json"];
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    builtinOnline=false;hooks.inventory=@[externalFixture];allowMove=true;
    restartMemory();
    int ioResult=air_spaces_recover();
    if(ioResult==0 || !pendingDisplayRecovery || journalIOError.empty())
        fprintf(stderr,"io result=%d pending=%d journal=%s error=%s\n",ioResult,
            pendingDisplayRecovery,journalIOError.c_str(),lastError.c_str());
    assert(ioResult!=0 && pendingDisplayRecovery && !journalIOError.empty());
    assert([[NSFileManager defaultManager] fileExistsAtPath:path]);

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("Spaces startup: accepted deferred only for valid offline journal and registered monitor; invalid/read, monitor, generic restore and refresh failures rejected");
    return 0;
} }
