#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

static std::string capturedError;
extern "C" void air_set_error(const char *message) { capturedError=message ?: ""; }
extern "C" int air_display_restore(void) { return 0; }

static NSMutableDictionary *builtIn=nil,*remapped=nil,*externalDisplay=nil;
static NSArray *currentInventory=nil;
static uint64_t membership=900;
static int switchCalls=0,moveCalls=0,frameCalls=0;
static std::string switchedDisplay;
static std::vector<std::string> onlineDisplays;

static int fixtureConn() { return 7; }
static CFArrayRef fixtureManaged(int) { return nullptr; }
static CFArrayRef fixtureWindowSpaces(int,int,CFArrayRef) { return nullptr; }
static int fixtureSpaceType(int,uint64_t sid) {
    return sid==639 || sid==189 || sid==900 ? 0 : -1;
}
static AXError fixtureAXWindow(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static uint64_t fixtureWindowSpace(uint32_t wid) { return wid==73 ? membership : 0; }
static int fixtureWindowState(const SavedWindow &) {
    return [remapped[@"Current Space"][@"id64"] unsignedLongLongValue]==900
        ? (int)WindowState::Ready : (int)WindowState::AXUnavailable;
}
static bool fixtureSwitchDisplay(const std::string &display,uint64_t sid) {
    switchCalls++;switchedDisplay=display;
    for(NSMutableDictionary *candidate in currentInventory)
        if([managedDisplayUUID(candidate) isEqualToString:
                [NSString stringWithUTF8String:display.c_str()]]) {
            candidate[@"Current Space"]=@{@"id64":@(sid)};return true;
        }
    return false;
}
static bool fixtureMove(uint32_t,uint64_t) { moveCalls++;return true; }
static bool fixtureFrame(const SavedWindow &) { frameCalls++;return true; }
static bool fixtureTopology(std::vector<std::string> &topology,
                            const std::string &original,bool &builtinOnline) {
    topology=onlineDisplays;
    builtinOnline=std::find(topology.begin(),topology.end(),original)!=topology.end();
    return true;
}

static NSDictionary *space(uint64_t sid,NSString *uuid) {
    return @{@"id64":@(sid),@"uuid":uuid,@"type":@0};
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-inactive-slot-XXXXXX"];
    std::string raw=pattern.fileSystemRepresentation;
    std::vector<char> path(raw.begin(),raw.end());path.push_back('\0');
    assert(mkdtemp(path.data()));
    NSString *directory=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[directory stringByAppendingPathComponent:@"recovery.json"];

    builtIn=[@{@"Display Identifier":@"journal-built-in",
        @"Current Space":@{@"id64":@639},
        @"Spaces":@[space(639,@"original-built-in")]} mutableCopy];
    remapped=[@{@"Display Identifier":@"currently-owning-display",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[space(189,@"other"),space(900,@"temporary-exact")]} mutableCopy];
    externalDisplay=[@{@"Display Identifier":@"external-original",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[space(189,@"external-original-space")]} mutableCopy];
    currentInventory=@[builtIn,remapped,externalDisplay];

    RecoveryHooks hooks={};
    hooks.inventory=currentInventory;hooks.windowSpace=fixtureWindowSpace;
    hooks.windowState=fixtureWindowState;hooks.switchDisplaySpace=fixtureSwitchDisplay;
    hooks.move=fixtureMove;hooks.frame=fixtureFrame;hooks.onlineTopology=fixtureTopology;
    recoveryHooks=&hooks;
    Api &native=api();native.conn=fixtureConn;native.managed=fixtureManaged;
    native.windowSpaces=fixtureWindowSpaces;native.spaceType=fixtureSpaceType;
    native.axWindow=fixtureAXWindow;

    SavedWindow window={73,42,"test.bundle","fixture",CGRectMake(-800,100,600,400),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-original",true};
    window.fullScreen=true;window.fullScreenPhase=2;window.fullScreenSpace=847;
    window.axIdentifier="exact.test.window";
    saved={window};createdSpaces={900};
    ownedSpaces={{900,"temporary-exact","journal-built-in"}};
    slots[0]=0;slots[1]=900;slots[2]=0;

    assert(windowState(saved[0])==WindowState::AXUnavailable);
    std::string reason;
    assert(prepareRecoveryWindowAccess(saved[0],7,&reason)==RecoverySpaceAccess::Ready);
    assert(reason.empty() && switchCalls==1
        && switchedDisplay=="currently-owning-display");
    assert(windowState(saved[0])==WindowState::Ready);
    assert(ownedSpaces[0].displayUUID=="journal-built-in"
        && ownedSpaces[0].uuid=="temporary-exact");

    remapped[@"Current Space"]=@{@"id64":@189};switchCalls=0;
    ownedSpaces[0].uuid="tampered";reason.clear();
    assert(prepareRecoveryWindowAccess(saved[0],7,&reason)==RecoverySpaceAccess::Failed);
    assert(switchCalls==0 && reason.find("conflicts")!=std::string::npos);
    ownedSpaces[0].uuid="temporary-exact";

    NSMutableDictionary *duplicate=[@{@"Display Identifier":@"duplicate-display",
        @"Current Space":@{@"id64":@189},
        @"Spaces":@[space(900,@"temporary-exact")]} mutableCopy];
    currentInventory=@[builtIn,remapped,externalDisplay,duplicate];hooks.inventory=currentInventory;
    reason.clear();
    assert(prepareRecoveryWindowAccess(saved[0],7,&reason)==RecoverySpaceAccess::Failed);
    assert(switchCalls==0 && reason.find("multiple")!=std::string::npos);

    currentInventory=@[builtIn,remapped,externalDisplay];hooks.inventory=currentInventory;
    membership=189;reason.clear();
    assert(prepareRecoveryWindowAccess(saved[0],7,&reason)==RecoverySpaceAccess::NotNeeded);
    assert(switchCalls==0);

    membership=900;switchCalls=moveCalls=frameCalls=0;capturedError.clear();
    remapped[@"Current Space"]=@{@"id64":@189};
    builtinUUID="journal-built-in";initialSpace=639;initialFullScreenIndex=-1;
    initialFullScreenSpace=0;initialSelections.clear();selectionPending={};
    pendingCreate=false;pendingCreateBefore.clear();active=true;lastSelectedSpace=900;
    wholeJournal={};parkingEvacuation={};
    onlineDisplays={"currently-owning-display","journal-built-in"};
    assert(persist());
    assert(restoreLocked()!=0);
    assert(switchCalls==0 && moveCalls==0 && frameCalls==0);
    assert(capturedError.find("external-original")!=std::string::npos
        && capturedError.find("offline")!=std::string::npos
        && capturedError.find("no window was moved or frame-restored")!=std::string::npos);
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:directory error:nil]);
    puts("inactive-slot recovery: exact relocated Space selection and offline-source atomic hold passed");
    return 0;
} }
