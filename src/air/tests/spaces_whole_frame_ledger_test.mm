#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static int frameCalls=0;
static bool allowFrame=true,allowDisplay=true,frameRestoresDisplay=false;
static bool exactSurface=true;
static uint64_t liveSpace=41;
static std::vector<uint64_t> liveMembership={11,12,41,51};
static std::vector<uint64_t> externalMembership={41};
static int ready(const SavedWindow &) {
    return (int)(exactSurface ? WindowState::Ready : WindowState::AXUnavailable);
}
static bool frame(const SavedWindow &) {
    frameCalls++;
    if(frameRestoresDisplay && allowFrame)allowDisplay=true;
    return allowFrame;
}
static bool display(uint32_t,const std::string &) { return allowDisplay; }
static bool bounds(const std::string &uuid,CGRect *value) {
    if(uuid=="external-a")*value=CGRectMake(1200,0,1000,800);
    else if(uuid=="builtin")*value=CGRectMake(0,0,1200,800);
    else return false;
    return true;
}
static uint64_t space(uint32_t) { return liveSpace; }
static std::vector<uint64_t> membership(uint32_t wid) {
    if(wid==74)return {11};
    if(wid==75 || wid==6110)return externalMembership;
    return liveMembership;
}

int main() { @autoreleasepool {
    std::string pattern=std::string(NSTemporaryDirectory().fileSystemRepresentation)
        +"air-whole-frames-XXXXXX";
    std::vector<char> directory(pattern.begin(),pattern.end());directory.push_back(0);
    assert(mkdtemp(directory.data()));
    NSString *folder=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];

    air::whole_space::Topology topology={{{"builtin",{11,12,901,902},
        {"b11","b12","p901","p902"},11},
        {"external-a",{41},{"a41"},41},
        {"external-b",{51},{"c51"},51}}};
    std::string why;
    assert(air::whole_space::initialize(wholeJournal,topology,"builtin",901,902,
        "p901","p902",[](uint64_t){return 0;},&why));
    auto originalWithEmpty=wholeJournal;
    originalWithEmpty.original.displays[0].order.insert(
        originalWithEmpty.original.displays[0].order.begin()+1,16);
    originalWithEmpty.original.displays[0].spaceUUIDs.insert(
        originalWithEmpty.original.displays[0].spaceUUIDs.begin()+1,"empty16");
    originalWithEmpty.prepared.displays[0].order.insert(
        originalWithEmpty.prepared.displays[0].order.begin()+1,16);
    originalWithEmpty.prepared.displays[0].spaceUUIDs.insert(
        originalWithEmpty.prepared.displays[0].spaceUUIDs.begin()+1,"empty16");
    originalWithEmpty.forwardDone=originalWithEmpty.reverseDone=4;
    originalWithEmpty.selectionDone=3;
    assert(absentEmptyOriginalSpaceDecision(originalWithEmpty,16,"empty16",topology));
    auto selectedEmpty=originalWithEmpty;
    selectedEmpty.original.displays[0].current=16;
    assert(!absentEmptyOriginalSpaceDecision(selectedEmpty,16,"empty16",topology));
    auto pendingEmpty=originalWithEmpty;
    pendingEmpty.pending.active=true;
    assert(!absentEmptyOriginalSpaceDecision(pendingEmpty,16,"empty16",topology));
    auto observedEmpty=topology;
    observedEmpty.displays[0].order.push_back(16);
    observedEmpty.displays[0].spaceUUIDs.push_back("empty16");
    assert(!absentEmptyOriginalSpaceDecision(originalWithEmpty,16,"empty16",observedEmpty));
    assert(!absentEmptyOriginalSpaceDecision(originalWithEmpty,16,"wrong-uuid",topology));
    assert(!absentEmptyOriginalSpaceDecision(originalWithEmpty,11,"b11",topology));
    builtinUUID="builtin";initialSpace=11;lastSelectedSpace=11;
    createdSpaces={901,902};ownedSpaces={{901,"p901","builtin"},{902,"p902","builtin"}};
    ProcessBirth birth=processBirth(getpid());assert(birth.valid());
    SavedWindow window={73,getpid(),"test.bundle","fixture",CGRectMake(1320,80,500,400),
        CGRectMake(1200,0,1000,800),1234567890,41,1,"external-a",true};
    window.birthSeconds=birth.seconds;window.birthMicroseconds=birth.microseconds;
    window.memberships={11,12,41,51};
    saved={window};wholeFrameInventoryComplete=true;
    assert(persist());
    NSData *data=[NSData dataWithContentsOfFile:journalTestPath];
    NSDictionary *encoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert([number(encoded[@"version"]) intValue]==16);
    saved.clear();wholeFrameInventoryComplete=false;
    assert(loadJournal() && wholeFrameInventoryComplete && saved.size()==1
        && saved[0].frame.origin.x==1320 && saved[0].sourceUUID=="external-a"
        && saved[0].memberships==window.memberships);

    NSMutableDictionary *invalid=[encoded mutableCopy];
    NSMutableArray *windows=[encoded[@"windows"] mutableCopy];
    NSMutableDictionary *wrong=[windows[0] mutableCopy];wrong[@"sourceUUID"]=@"external-b";
    windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid) && saved.size()==1 && saved[0].sourceUUID=="external-a");
    wrong=[encoded[@"windows"][0] mutableCopy];wrong[@"memberships"]=@[@11,@11,@41,@51];
    windows=[encoded[@"windows"] mutableCopy];windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    wrong=[encoded[@"windows"][0] mutableCopy];wrong[@"memberships"]=@[@11,@12,@41,@999];
    windows=[encoded[@"windows"] mutableCopy];windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    NSMutableDictionary *legacy=[encoded mutableCopy];legacy[@"version"]=@14;
    wrong=[encoded[@"windows"][0] mutableCopy];[wrong removeObjectForKey:@"memberships"];
    windows=[encoded[@"windows"] mutableCopy];windows[0]=wrong;legacy[@"windows"]=windows;
    assert(parseJournal(legacy) && saved[0].memberships==std::vector<uint64_t>{41});
    legacy=[encoded mutableCopy];legacy[@"version"]=@15;
    wrong=[encoded[@"windows"][0] mutableCopy];
    [wrong removeObjectForKey:@"readOnlyCG"];[wrong removeObjectForKey:@"surfaceTags"];
    windows=[encoded[@"windows"] mutableCopy];windows[0]=wrong;legacy[@"windows"]=windows;
    assert(parseJournal(legacy) && saved[0].memberships==window.memberships);
    assert(parseJournal(encoded) && saved[0].memberships==window.memberships);

    // A Chrome parking companion has only the matching original external
    // Space as its durable destination; a cross-slot destination is rejected.
    wholeJournal.forwardDone=wholeJournal.reverseDone=4;wholeJournal.selectionDone=3;
    lastSelectedSpace=0;
    parkingEvacuation={true,{9199,getpid(),"com.google.Chrome",1234567890,
        birth.seconds,birth.microseconds,901,41,true,
        CGRectMake(-1920,30,1920,1050)}};
    assert(persist());
    NSData *parkingData=[NSData dataWithContentsOfFile:journalTestPath];
    NSDictionary *parkingJournal=[NSJSONSerialization JSONObjectWithData:parkingData options:0 error:nil];
    assert(parseJournal(parkingJournal) && parkingEvacuation.active
        && parkingEvacuation.window.destinationSpace==41);
    NSMutableDictionary *invalidParking=[parkingJournal mutableCopy];
    NSMutableDictionary *parkingEntry=[parkingJournal[@"parkingEvacuation"] mutableCopy];
    parkingEntry[@"destinationSpace"]=@51;invalidParking[@"parkingEvacuation"]=parkingEntry;
    assert(!parseJournal(invalidParking));
    parkingEvacuation={};wholeJournal.reverseDone=0;wholeJournal.selectionDone=0;
    lastSelectedSpace=11;
    assert(persist());

    // A post-launch window from the external parking Space has a durable
    // destination and frame even when no pre-session SavedWindow exists.
    wholeJournal.forwardDone=4;
    runtimeLaunchWindows={{8101,getpid(),"test.bundle","external-a",1234567890,
        birth.seconds,birth.microseconds,901,41,1,1,CGRectMake(1240,50,700,500)},
        {8102,getpid(),"test.bundle","external-a",1234567890,
        birth.seconds,birth.microseconds,41,41,1,2,CGRectMake(1200,50,920,700)}};
    assert(persist());
    NSData *launchData=[NSData dataWithContentsOfFile:journalTestPath];
    NSDictionary *launchJournal=[NSJSONSerialization JSONObjectWithData:launchData options:0 error:nil];
    assert([number(launchJournal[@"version"]) intValue]==22);
    runtimeLaunchWindows.clear();
    assert(loadJournal() && runtimeLaunchWindows.size()==2
        && runtimeLaunchWindows[0].sourceSpace==901
        && runtimeLaunchWindows[0].destination==41
        && runtimeLaunchWindows[0].originalFrame.size.width==700
        && runtimeLaunchWindows[1].sourceSpace==runtimeLaunchWindows[1].destination);
    NSMutableDictionary *wrongLaunch=[launchJournal mutableCopy];
    NSMutableArray *launchEntries=[launchJournal[@"runtimeLaunchWindows"] mutableCopy];
    NSMutableDictionary *wrongEntry=[launchEntries[0] mutableCopy];
    wrongEntry[@"destination"]=@51;launchEntries[0]=wrongEntry;
    wrongLaunch[@"runtimeLaunchWindows"]=launchEntries;
    assert(!parseJournal(wrongLaunch) && runtimeLaunchWindows.size()==2);
    wrongEntry=[launchJournal[@"runtimeLaunchWindows"][0] mutableCopy];
    wrongEntry[@"sourceDisplay"]=@"external-b";
    launchEntries=[launchJournal[@"runtimeLaunchWindows"] mutableCopy];launchEntries[0]=wrongEntry;
    wrongLaunch[@"runtimeLaunchWindows"]=launchEntries;
    assert(!parseJournal(wrongLaunch));
    runtimeLaunchWindows.clear();wholeJournal.forwardDone=0;assert(persist());

    assert(stationaryBuiltinUnmappedDecision(true,true,true,true,true,true));
    for(int missing=0;missing<6;missing++) {
        bool facts[6]={true,true,true,true,true,true};facts[missing]=false;
        assert(!stationaryBuiltinUnmappedDecision(facts[0],facts[1],facts[2],
            facts[3],facts[4],facts[5]));
    }
    assert(stationaryBuiltinTransparentDecision(true,true,true,true,true,true,true));
    for(int missing=0;missing<7;missing++) {
        bool facts[7]={true,true,true,true,true,true,true};facts[missing]=false;
        assert(!stationaryBuiltinTransparentDecision(facts[0],facts[1],facts[2],
            facts[3],facts[4],facts[5],facts[6]));
    }

    RecoveryHooks hooks={};hooks.windowState=ready;hooks.frame=frame;
    hooks.windowDisplay=display;hooks.displayBounds=bounds;hooks.windowSpace=space;
    hooks.windowMembership=membership;
    recoveryHooks=&hooks;
    assert(restoreWholeWindowFrames(0,why) && frameCalls==1);
    liveMembership={11,41,51};assert(!restoreWholeWindowFrames(0,why) && frameCalls==1);
    liveMembership={11,12,41,51};allowDisplay=false;
    assert(!restoreWholeWindowFrames(0,why) && frameCalls==1);
    allowDisplay=true;allowFrame=false;
    assert(!restoreWholeWindowFrames(0,why) && frameCalls==2);
    ReadOnlyChromeEvidence evidence;
    evidence.chrome=evidence.stableProcess=evidence.completeAX=evidence.absentAX=true;
    evidence.blankTitle=evidence.alphaOne=evidence.offscreen=evidence.stableAll=true;
    evidence.exactDisplay=evidence.rootParent=evidence.exactTags=evidence.singleOrdinaryMembership=true;
    evidence.selectedOrdinaryAnchor=true;
    assert(readOnlyChromeDecision(evidence));
    evidence.exactTags=false;assert(!readOnlyChromeDecision(evidence));
    evidence.exactTags=true;evidence.completeAX=false;assert(!readOnlyChromeDecision(evidence));
    evidence.completeAX=true;evidence.offscreen=false;assert(!readOnlyChromeDecision(evidence));
    evidence.offscreen=true;evidence.rootParent=false;assert(!readOnlyChromeDecision(evidence));
    evidence.rootParent=true;evidence.singleOrdinaryMembership=false;
    assert(!readOnlyChromeDecision(evidence));
    evidence.singleOrdinaryMembership=true;evidence.selectedOrdinaryAnchor=false;
    assert(!readOnlyChromeDecision(evidence));

    CGRect premiereFrame=CGRectMake(-1920,120,1920,1050);
    NSString *premiere=@"com.adobe.PremierePro.26";
    assert(premiereDialogWindowTags(0x300000100082401ULL));
    assert(premiereDialogWindowTags(0x300000100482001ULL));
    assert(!premiereDialogWindowTags(0x300000100482000ULL));
    assert(journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,true,true,CGRectNull,true,true));
    assert(!journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,true,true,CGRectNull,true,false));
    assert(!journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,true,true,CGRectNull,false,true));
    assert(!journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,false,true,CGRectNull,true,true));
    assert(!journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,true,false,CGRectNull,true,true));
    assert(!journalableAXFrame(premiere,@"AXLayoutArea",@"AXDialog",
        premiereFrame,CGRectOffset(premiereFrame,4,0),true,true,CGRectNull,true,true));
    assert(!journalableAXFrame(@"other.app",@"AXLayoutArea",@"AXDialog",
        premiereFrame,premiereFrame,true,true,CGRectNull,true,true));
    SavedWindow premiereSaved=window;
    premiereSaved.bundle="com.adobe.PremierePro.26";premiereSaved.axDialog=true;
    assert(premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));
    premiereSaved.axDialog=false;
    assert(!premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));
    premiereSaved.axDialog=true;premiereSaved.bundle="wrong.bundle";
    assert(!premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));
    premiereSaved.bundle="com.adobe.PremierePro.26";premiereSaved.cgOnly=true;
    assert(!premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));
    premiereSaved.cgOnly=false;premiereSaved.readOnlyCG=true;
    assert(!premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));
    premiereSaved.readOnlyCG=false;premiereSaved.frameFromAX=false;
    assert(!premiereDialogMutationGate(premiere,@"AXLayoutArea",@"AXDialog",premiereSaved));

    SavedWindow strip={74,getpid(),"com.google.Chrome","",CGRectMake(0,64,1200,41),
        CGRectMake(0,0,1200,800),1234567890,11,0,"builtin",false};
    strip.birthSeconds=birth.seconds;strip.birthMicroseconds=birth.microseconds;
    strip.memberships={11};strip.readOnlyCG=true;strip.surfaceTags=0x1400c0202ULL;
    assert(!readOnlyChromeGoneDecision(strip,birth,false));
    assert(!readOnlyChromeGoneDecision(strip,{},false));
    assert(readOnlyChromeGoneDecision(strip,birth,true));
    assert(readOnlyChromeGoneDecision(strip,{},true));
    ProcessBirth reused=birth;reused.microseconds=(reused.microseconds+1)%1000000;
    assert(readOnlyChromeGoneDecision(strip,reused,false));
    SavedWindow changed=strip;changed.surfaceTags++;
    assert(!sameWholeFrameSnapshot({strip},{changed}));
    saved={strip};allowDisplay=true;
    assert(restoreWholeWindowFrames(0,why) && frameCalls==2);
    assert(persist());
    saved.clear();assert(loadJournal() && saved.size()==1 && saved[0].readOnlyCG
        && saved[0].surfaceTags==strip.surfaceTags);
    encoded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:journalTestPath]
        options:0 error:nil];
    invalid=[encoded mutableCopy];windows=[encoded[@"windows"] mutableCopy];
    wrong=[windows[0] mutableCopy];wrong[@"surfaceTags"]=@0;windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    wrong=[windows[0] mutableCopy];wrong[@"surfaceTags"]=@(0x1400c0402ULL);
    windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    SavedWindow external={75,getpid(),"com.google.Chrome","",CGRectMake(1200,58,1000,46),
        CGRectMake(1200,0,1000,800),1234567890,41,1,"external-a",false};
    external.birthSeconds=birth.seconds;external.birthMicroseconds=birth.microseconds;
    external.memberships={41};external.readOnlyCG=true;external.surfaceTags=0x1400c0202ULL;
    saved={external};assert(persist());
    saved.clear();assert(loadJournal() && saved.size()==1 && saved[0].readOnlyCG
        && saved[0].slot==1 && saved[0].space==41);
    assert(restoreWholeWindowFrames(0,why) && frameCalls==2);
    NSData *externalJournal=[NSData dataWithContentsOfFile:journalTestPath];
    externalMembership={51};
    assert(!restoreWholeWindowFrames(0,why) && frameCalls==2
        && [[NSData dataWithContentsOfFile:journalTestPath] isEqualToData:externalJournal]);
    externalMembership={41};
    exactSurface=false;
    assert(!restoreWholeWindowFrames(0,why) && frameCalls==2
        && [[NSData dataWithContentsOfFile:journalTestPath] isEqualToData:externalJournal]);
    exactSurface=true;
    encoded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:journalTestPath]
        options:0 error:nil];
    invalid=[encoded mutableCopy];windows=[encoded[@"windows"] mutableCopy];
    wrong=[windows[0] mutableCopy];wrong[@"space"]=@51;wrong[@"memberships"]=@[@51];
    windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid) && saved.size()==1 && saved[0].space==41);
    SavedWindow finder={6110,getpid(),"com.apple.finder","16-script-edit",
        CGRectMake(1320,59,920,464),CGRectMake(1200,0,1000,800),
        1234567890,41,1,"external-a",false};
    finder.cgOnly=true;finder.birthSeconds=birth.seconds;
    finder.birthMicroseconds=birth.microseconds;finder.memberships={41};
    finder.surfaceTags=0x200000100482001ULL;
    assert(exactFinderJournal(finder));
    CGRect nontrivialContent=CGRectMake(3.5,26.5,1147,718.5);
    CGRect fractionalMapped=mappedFrame(finder,nontrivialContent);
    CGRect integerMapped=mappedFinderFrame(finder,nontrivialContent);
    assert(fractionalMapped.origin.x!=round(fractionalMapped.origin.x));
    assert(finderIntegerFrame(integerMapped)
        && integerMapped.size.width==finder.frame.size.width
        && integerMapped.size.height==finder.frame.size.height
        && CGRectContainsRect(nontrivialContent,integerMapped));
    assert(CGRectIsNull(mappedFinderFrame(finder,CGRectMake(0,0,919,464))));
    // Finder's signed AppleScript WID/name/bounds must agree with CG when
    // AXWindows contains unmappable proxies; AX completeness is immaterial.
    assert(finderIndependentWindowIdentity(true,false,false,true,true));
    assert(finderIndependentWindowIdentity(true,true,false,true,true));
    assert(!finderIndependentWindowIdentity(false,false,false,true,true));
    assert(!finderIndependentWindowIdentity(true,false,true,true,true));
    assert(!finderIndependentWindowIdentity(true,false,false,false,true));
    assert(!finderIndependentWindowIdentity(true,false,false,true,false));
    FinderRestoreEvidence renamedAndResized;
    renamedAndResized.journal=renamedAndResized.process=true;
    renamedAndResized.signedProcess=renamedAndResized.stableCG=true;
    renamedAndResized.parentRoot=renamedAndResized.exactTags=true;
    renamedAndResized.ordinaryMembership=renamedAndResized.expectedDisplay=true;
    renamedAndResized.exactAppleBounds=true;
    // The current title and size may change while Remote Mode is active.
    assert(finderRestoreDecision(renamedAndResized,finder.title,
        @"Documents (renamed)",CGRectMake(120,80,861,443)));
    for(bool FinderRestoreEvidence::*field:{
        &FinderRestoreEvidence::journal,&FinderRestoreEvidence::process,
        &FinderRestoreEvidence::signedProcess,&FinderRestoreEvidence::stableCG,
        &FinderRestoreEvidence::parentRoot,&FinderRestoreEvidence::exactTags,
        &FinderRestoreEvidence::ordinaryMembership,&FinderRestoreEvidence::expectedDisplay,
        &FinderRestoreEvidence::exactAppleBounds}) {
        FinderRestoreEvidence bad=renamedAndResized;bad.*field=false;
        assert(!finderRestoreDecision(bad,finder.title,
            @"Documents (renamed)",CGRectMake(120,80,861,443)));
    }
    assert(!finderRestoreDecision(renamedAndResized,finder.title,@"",
        CGRectMake(120,80,861,443)));
    assert(!finderRestoreDecision(renamedAndResized,finder.title,
        @"Documents (renamed)",CGRectMake(120.5,80,861,443)));
    CGRect originalFinder=CGRectMake(-1778,59,920,464);
    CGRect targetFinder=CGRectMake(33,80,920,464);
    assert(finderForwardRollbackCandidate(originalFinder,targetFinder,
        CGRectMake(32,80,919,464))); // Finder clamped a partial set-bounds.
    assert(!finderForwardRollbackCandidate(originalFinder,targetFinder,originalFinder));
    assert(!finderForwardRollbackCandidate(originalFinder,targetFinder,
        CGRectMake(-900,80,920,464))); // An unrelated move is not overwritten.
    assert(finderRollbackSpaceDecision(9,9,41,true));
    assert(finderRollbackSpaceDecision(41,9,41,true));
    assert(!finderRollbackSpaceDecision(51,9,41,true)); // Other ordinary Space.
    assert(!finderRollbackSpaceDecision(41,9,41,false)); // Space/display mismatch.
    SavedWindow wrongFinder=finder;wrongFinder.surfaceTags++;
    assert(!exactFinderJournal(wrongFinder));
    wrongFinder=finder;wrongFinder.memberships={41,51};
    assert(!exactFinderJournal(wrongFinder));
    wrongFinder=finder;wrongFinder.title.clear();
    assert(!exactFinderJournal(wrongFinder));
    saved={finder};assert(persist());
    encoded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:journalTestPath]
        options:0 error:nil];
    assert([number(encoded[@"version"]) intValue]==19);
    saved.clear();assert(loadJournal() && saved.size()==1 && exactFinderJournal(saved[0]));
    for(NSNumber *tag in @[@0,@(0x200000100482000ULL),@(0x200000100082401ULL)]) {
        invalid=[encoded mutableCopy];windows=[encoded[@"windows"] mutableCopy];
        wrong=[windows[0] mutableCopy];wrong[@"surfaceTags"]=tag;
        windows[0]=wrong;invalid[@"windows"]=windows;
        assert(!parseJournal(invalid));
    }
    invalid=[encoded mutableCopy];invalid[@"version"]=@18;
    assert(!parseJournal(invalid));
    invalid=[encoded mutableCopy];windows=[encoded[@"windows"] mutableCopy];
    wrong=[windows[0] mutableCopy];wrong[@"title"]=@"";
    windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    invalid=[encoded mutableCopy];windows=[encoded[@"windows"] mutableCopy];
    wrong=[windows[0] mutableCopy];wrong[@"memberships"]=@[@41,@51];
    windows[0]=wrong;invalid[@"windows"]=windows;
    assert(!parseJournal(invalid));
    // Whole-Space reversal returns the original membership first. Finder's
    // AppleScript frame restore must then be allowed to return its display.
    saved={finder};externalMembership={41};allowFrame=true;allowDisplay=false;
    frameRestoresDisplay=true;int finderFrameBefore=frameCalls;
    assert(restoreWholeWindowFrames(0,why) && frameCalls==finderFrameBefore+1
        && allowDisplay);
    frameRestoresDisplay=false;allowDisplay=false;
    externalMembership={51};finderFrameBefore=frameCalls;
    assert(!restoreWholeWindowFrames(0,why) && frameCalls==finderFrameBefore);
    externalMembership={41};allowDisplay=true;
    recoveryHooks=nullptr;
    journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);
    puts("whole-Space frame journal, identity validation, and guarded restore passed");
    return 0;
} }
