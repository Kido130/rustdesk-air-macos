#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static NSMutableDictionary *builtin=nil;
static bool full=true,member=true,source=true,allowSwitch=true,allowSet=true,normalFrame=true;
static uint64_t fullSID=877;
static uint32_t resolved=91;
static int switchCount=0,setCount=0,moveCount=0;
static int conn() { return 7; }
static CFArrayRef managedStub(int) { return nullptr; }
static CFArrayRef membershipStub(int,int,CFArrayRef) { return nullptr; }
static AXError axWindowStub(AXUIElementRef,CGWindowID *) { return kAXErrorFailure; }
static int spaceType(int,uint64_t sid) { return sid==877 || sid==881 ? 4 : 0; }
static int windowStateStub(const SavedWindow &) { return (int)WindowState::Ready; }
static int fullState(const SavedWindow &) {
    uint64_t current=[number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    return full && current!=fullSID ? -1 : (full ? 1 : 0);
}
static bool setFull(const SavedWindow &,bool desired) {
    setCount++;if(!allowSet)return false;
    full=desired;member=desired;
    if(desired){fullSID=881;builtin[@"Current Space"]=@{@"id64":@(fullSID)};}
    else builtin[@"Current Space"]=@{@"id64":@189};
    return true;
}
static uint32_t resolve(const SavedWindow &) {
    uint64_t current=[number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    return full && current!=fullSID ? 0 : resolved;
}
static uint64_t ordinary(const SavedWindow &) { return !full && source ? 189 : 0; }
static bool fullMember(const SavedWindow &) { return full && member && source; }
static uint64_t fullSpace(const SavedWindow &) { return fullMember(SavedWindow{}) ? fullSID : 0; }
static bool axFrame(const SavedWindow &,CGRect *frame) {
    *frame=full ? (normalFrame ? CGRectMake(0,0,1147,745) : CGRectMake(100,100,400,300))
        : CGRectMake(100,100,400,300);
    return true;
}
static bool moveWindow(uint32_t,uint64_t sid) { moveCount++;source=sid==189;return source; }
static bool setFrameStub(const SavedWindow &) { return true; }
static bool windowDisplay(uint32_t,const std::string &uuid) { return source && uuid=="builtin-uuid"; }
static bool switchTo(uint64_t sid) {
    switchCount++;
    if(!allowSwitch)return false;
    builtin[@"Current Space"]=@{@"id64":@(sid)};return true;
}
static int mission() { return (int)MissionState::Absent; }
static bool topology(std::vector<std::string> &names,const std::string &,bool &online) {
    names={"builtin-uuid"};online=true;return true;
}
static void reset(int phase,bool anchor) {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();pendingCreateBefore.clear();pendingCreate=false;
    initialSelections.clear();selectionPending={};windowInventoryComplete=true;
    builtinUUID="builtin-uuid";initialSpace=anchor ? 189 : 0;
    initialFullScreenIndex=0;initialFullScreenSpace=877;finalSelectionPending=false;
    lastSelectedSpace=0;slots[0]=slots[1]=slots[2]=0;active=false;
    full=phase==1;member=full;source=true;allowSwitch=true;allowSet=true;normalFrame=true;
    fullSID=877;resolved=91;switchCount=setCount=moveCount=0;
    builtin[@"Current Space"]=@{@"id64":@(full ? 877 : 189)};
    SavedWindow w={91,42,"test.bundle","fixture",CGRectMake(100,100,400,300),
        CGRectMake(0,0,1147,745),1234567890,phase==1 || phase==4 ? 877ULL : 189ULL,
        0,"builtin-uuid",true};
    w.fullScreen=true;w.fullScreenPhase=phase;w.fullScreenSpace=877;
    w.axIdentifier="unique.fixture.window";
    saved.push_back(w);assert(persist());
}

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-initial-fullscreen-XXXXXX"];
    std::string name=pattern.fileSystemRepresentation;
    std::vector<char> path(name.begin(),name.end());path.push_back('\0');
    assert(mkdtemp(path.data()));
    NSString *folder=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    builtin=[@{@"Display Identifier":@"builtin-uuid",@"Current Space":@{@"id64":@877},
        @"Spaces":@[@{@"id64":@189,@"uuid":@"anchor",@"type":@0},
            @{@"id64":@877,@"uuid":@"oldfull",@"type":@4},
            @{@"id64":@881,@"uuid":@"newfull",@"type":@4}]} mutableCopy];
    RecoveryHooks hooks={};hooks.inventory=@[builtin];hooks.windowState=windowStateStub;
    hooks.fullScreenState=fullState;hooks.setFullScreen=setFull;hooks.resolveWindow=resolve;
    hooks.ordinaryAfterExit=ordinary;hooks.fullScreenMembership=fullMember;
    hooks.fullScreenSpaceID=fullSpace;hooks.afterExitFrame=axFrame;
    hooks.move=moveWindow;hooks.frame=setFrameStub;hooks.windowDisplay=windowDisplay;
    hooks.switchSpace=switchTo;hooks.missionState=mission;hooks.onlineTopology=topology;
    recoveryHooks=&hooks;
    Api &native=api();native.conn=conn;native.managed=managedStub;
    native.spaceType=spaceType;native.windowSpaces=membershipStub;native.axWindow=axWindowStub;
    SelectedFullScreenQuiescence transitionGate;
    assert(!transitionGate.observe(false,"transitioning"));
    assert(!transitionGate.observe(true,"stable-owner-and-companion"));
    assert(transitionGate.observe(true,"stable-owner-and-companion"));
    SelectedFullScreenQuiescence unstableGate;
    for(int i=0;i<6;i++)
        assert(!unstableGate.observe(true,i%2 ? "snapshot-b" : "snapshot-a"));
    assert(!unstableGate.observe(false,"snapshot-b"));
    assert(!unstableGate.observe(true,"snapshot-b")); // invalid samples reset the streak
    assert(unstableGate.observe(true,"snapshot-b"));
    std::string safeDiagnostic=selectedFullScreenDiagnostic(123,456,"cg_identity");
    assert(safeDiagnostic.find("window=123")!=std::string::npos
        && safeDiagnostic.find("pid=456")!=std::string::npos
        && safeDiagnostic.find("predicate=cg_identity")!=std::string::npos
        && safeDiagnostic.find("title")==std::string::npos);
    assert(fullScreenCompanionDecision(true,true,true,true,true,true,
        false,false,false,true,true));
    assert(fullScreenCompanionDecision(true,true,true,true,true,false,
        true,true,true,true,true));
    assert(!fullScreenCompanionDecision(true,true,true,true,true,true,
        true,true,false,false,true));
    assert(!fullScreenCompanionDecision(true,true,true,true,true,false,
        true,true,true,true,false));
    CGRect owner=CGRectMake(-1920,0,1920,1080);
    auto chromeStrip=[&](CGRect candidate) {
        return browserFullScreenStripDecision(true,true,true,true,true,true,true,false,true,true,
            owner,candidate);
    };
    assert(chromeStrip(CGRectMake(-1920,0,1920,115)));
    assert(chromeStrip(CGRectMake(-1920,-55,1920,47)));
    assert(chromeStrip(CGRectMake(0,-49,1920,41)));
    assert(!chromeStrip(CGRectMake(-1920,0,1920,300)));
    assert(!chromeStrip(CGRectMake(-1920,0,1920,1080)));
    assert(!chromeStrip(CGRectMake(-960,-49,1920,41)));
    assert(!chromeStrip(CGRectMake(1920,-49,1920,41)));
    assert(!chromeStrip(CGRectMake(0,300,1920,41)));
    assert(browserFullScreenStripDecision(true,true,true,true,true,true,true,true,false,true,
        owner,CGRectMake(0,-49,1920,41)));
    assert(!browserFullScreenStripDecision(true,true,true,true,true,true,true,false,false,true,
        owner,CGRectMake(0,-49,1920,41)));
    assert(!browserFullScreenStripDecision(false,true,true,true,true,true,true,false,true,true,
        owner,CGRectMake(0,-49,1920,41)));
    assert(!browserFullScreenStripDecision(true,true,true,true,true,false,true,false,true,true,
        owner,CGRectMake(0,-49,1920,41)));
    assert(!browserFullScreenStripDecision(true,true,false,true,true,true,true,false,true,true,
        owner,CGRectMake(0,-49,1920,41)));
    CGRect detachedOwner=CGRectMake(-3840,0,1920,1080);
    CGRect detachedParent=CGRectMake(-3840,-47,1920,47);
    CGRect detachedChild=CGRectMake(0,-41,1920,41);
    assert(browserFullScreenDetachedStripGeometry(detachedOwner,detachedParent,detachedChild));
    assert(!browserFullScreenDetachedStripGeometry(detachedOwner,detachedParent,
        CGRectMake(-1920,-41,1920,41)));
    assert(!browserFullScreenDetachedStripGeometry(detachedOwner,detachedParent,
        CGRectMake(0,-41,1920,300)));
    assert(!browserFullScreenDetachedStripGeometry(detachedOwner,
        CGRectMake(-3700,-47,1920,47),detachedChild));
    assert(!browserFullScreenDetachedStripGeometry(detachedOwner,detachedParent,
        CGRectMake(0,10,1920,41)));
    assert(!browserFullScreenDetachedStripGeometry(detachedOwner,detachedParent,
        CGRectMake(0,-41,1000,41)));
    OrdinaryChromeStripEvidence ordinaryChrome;
    ordinaryChrome.chrome=ordinaryChrome.process=ordinaryChrome.space=ordinaryChrome.display=true;
    ordinaryChrome.stableAll=ordinaryChrome.completeAX=ordinaryChrome.candidateAbsentAX=true;
    ordinaryChrome.blankTitle=ordinaryChrome.alphaOne=ordinaryChrome.standardRootCohort=true;
    ordinaryChrome.surfaceTags=true;
    ordinaryChrome.offscreen=true;
    CGRect external1=CGRectMake(-1920,0,1920,1080);
    CGRect root1=CGRectMake(-1920,30,1920,1050);
    CGRect strip1=CGRectMake(-1821,55,1722,89);
    CGRect external2=CGRectMake(-3840,0,1920,1080);
    CGRect root2=CGRectMake(-3840,30,1920,1050);
    CGRect strip2=CGRectMake(-3741,55,1650,89);
    assert(ordinaryChromeStripDecision(ordinaryChrome,external1,root1,strip1));
    assert(ordinaryChromeStripDecision(ordinaryChrome,external2,root2,strip2));
    auto rejected=[&](void (*change)(OrdinaryChromeStripEvidence &)) {
        OrdinaryChromeStripEvidence bad=ordinaryChrome;change(bad);
        assert(!ordinaryChromeStripDecision(bad,external1,root1,strip1));
    };
    rejected([](OrdinaryChromeStripEvidence &e){e.chrome=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.process=false;}); // PID/birth/bundle
    rejected([](OrdinaryChromeStripEvidence &e){e.space=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.display=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.stableAll=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.completeAX=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.candidateAbsentAX=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.blankTitle=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.alphaOne=false;});
    rejected([](OrdinaryChromeStripEvidence &e){e.standardRootCohort=false;});
    assert(ordinaryChromeStripDecision(ordinaryChrome,external1,root1,
        CGRectMake(-1821,55,1722,129))); // contained compositor surface
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external1,root1,
        CGRectMake(-1821,55,1722,900))); // too tall to be a contained companion
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external1,root1,
        CGRectMake(-1821,200,1722,89))); // not at the top of the root
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external1,root1,
        CGRectMake(-2100,55,1722,89))); // outside the root and display
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external1,root1,
        CGRectMake(-1821,55,1000,89))); // too narrow to be the tab strip
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external2,root1,strip1)); // wrong display
    assert(!ordinaryChromeStripDecision(ordinaryChrome,external1,root2,strip1)); // wrong root
    NSArray *externalSelections=@[@{@"Display Identifier":@"external-uuid",
        @"Current Space":@{@"id64":@189}},
        @{@"Display Identifier":@"builtin-uuid",@"Current Space":@{@"id64":@877}}];
    assert(currentSpaceForDisplay(externalSelections,"external-uuid")==189);
    assert(currentSpaceForDisplay(externalSelections,"missing-uuid")==0);
    assert(currentSpaceForDisplay(@[externalSelections[0],externalSelections[0]],"external-uuid")==0);

    reset(1,false);
    SavedWindow untouched={92,43,"other.bundle","untouched",CGRectMake(250,200,320,240),
        CGRectMake(0,0,1147,745),1234567890,189,0,"builtin-uuid",true};
    saved.push_back(untouched);assert(persist());
    assert(loadJournal() && initialFullScreenIndex==0 && initialSpace==0);
    assert(restoreLocked()==0 && saved.empty() && switchCount==0 && moveCount==0);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);

    reset(4,false);full=false;member=false;builtin[@"Current Space"]=@{@"id64":@189};
    assert(loadJournal() && initialSpace==0);
    assert(restoreLocked()==0 && setCount==1 && switchCount==2 && saved.empty());
    assert([number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue]==881);

    reset(4,false);full=false;member=false;builtin[@"Current Space"]=@{@"id64":@189};
    allowSet=false;
    assert(restoreLocked()!=0 && initialSpace==189 && saved[0].fullScreenPhase==4);
    assert(loadJournal() && initialSpace==189 && saved[0].fullScreenPhase==4);
    allowSet=true;assert(restoreLocked()==0 && saved.empty());

    reset(1,false);initialSpace=189;assert(persist());
    assert(loadJournal() && initialSpace==189 && saved[0].fullScreenPhase==1);

    reset(1,false);
    initialSelections.push_back({"builtin-uuid",877,4,0,877});
    windowInventoryComplete=false;assert(persist());
    windowInventoryComplete=true;assert(loadJournal() && !windowInventoryComplete);
    assert(saved.size()==1 && saved[0].fullScreen && initialSelections.size()==1);
    saved.push_back(untouched);assert(persist());
    assert(!loadJournal());
    saved.pop_back();assert(persist());
    assert(loadJournal() && restoreLocked()==0 && windowInventoryComplete);

    reset(2,true);full=false;member=false;source=false;
    assert(restoreLocked()==0 && moveCount==1 && setCount==1 && switchCount==2);

    reset(3,true);full=true;member=true;fullSID=881;
    builtin[@"Current Space"]=@{@"id64":@189};
    assert(restoreLocked()==0 && switchCount==1 && saved.empty());
    assert([number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue]==881);

    reset(3,true);full=true;member=true;fullSID=881;
    builtin[@"Current Space"]=@{@"id64":@189};allowSwitch=false;
    assert(restoreLocked()!=0 && finalSelectionPending && !saved.empty());
    assert([[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
    allowSwitch=true;assert(loadJournal() && finalSelectionPending);
    assert(restoreLocked()==0 && saved.empty());

    reset(3,true);full=true;member=true;fullSID=881;
    builtin[@"Current Space"]=@{@"id64":@999};
    assert(restoreLocked()!=0 && switchCount==0 && !saved.empty());
    assert([number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue]==999);

    // macOS can remove both the original and restored full-screen Spaces
    // after the Host has journaled phase 3 but before the next recovery pass.
    reset(3,true);full=false;member=false;
    initialSelections.push_back({"builtin-uuid",877,4,0,881});
    builtin[@"Spaces"]=@[@{@"id64":@189,@"type":@0}];
    builtin[@"Current Space"]=@{@"id64":@189};
    assert(persist() && loadJournal());
    resolved=0;
    assert(!reconcileVanishedInitialFullScreenSelection(0,7));
    resolved=91;source=false;
    assert(!reconcileVanishedInitialFullScreenSelection(0,7));
    source=true;builtin[@"Current Space"]=@{@"id64":@999};
    assert(!reconcileVanishedInitialFullScreenSelection(0,7));
    builtin[@"Current Space"]=@{@"id64":@189};
    builtin[@"Spaces"]=@[@{@"id64":@189,@"type":@0},@{@"id64":@881,@"type":@4}];
    assert(!reconcileVanishedInitialFullScreenSelection(0,7));
    builtin[@"Spaces"]=@[@{@"id64":@189,@"type":@0}];
    assert(reconcileVanishedInitialFullScreenSelection(0,7));
    assert(initialSelections[0].hostSpace==189 && loadJournal()
        && initialSelections[0].hostSpace==189);
    assert(beginReentryAction(0) && selectionPending.active);
    assert(loadJournal() && selectionPending.active);

    reset(1,false);
    NSDictionary *valid=dictionary([NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil]);
    NSMutableDictionary *bad=[valid mutableCopy];bad[@"initialFullScreenIndex"]=@2;
    assert(!parseJournal(bad));
    bad[@"initialFullScreenIndex"]=@0;bad[@"finalSelectionPending"]=@YES;
    assert(!parseJournal(bad));
    bad[@"finalSelectionPending"]=@NO;bad[@"initialFullScreenSpace"]=@881;
    assert(!parseJournal(bad));

    recoveryHooks=nullptr;journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);
    puts("initial fullscreen: pre-exit crash, phase-4 recovery, new SID selection, hidden AX, retry, outside-space guard, invalid journals passed");
    return 0;
} }
