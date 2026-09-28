#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    air::whole_space::Topology original={{{"builtin",{10,11},{"b10","b11"},10},
        {"external-a",{20,21,44},{"a20","a21","full-44"},20},
        {"external-b",{30},{"c30"},30}}};
    air::whole_space::Topology moved;
    assert(expectedFullScreenTopology(original,44,"builtin",2,moved));
    assert(moved.displays[0].order==std::vector<uint64_t>({10,11,44}));
    assert(moved.displays[1].order==std::vector<uint64_t>({20,21}));
    air::whole_space::Topology returned;
    assert(expectedFullScreenTopology(moved,44,"external-a",2,returned));
    assert(sameWholeTopology(original,returned));
    assert(!expectedFullScreenTopology(original,20,"external-b",1,moved));
    air::whole_space::Topology two={{{"builtin",{10},{"b10"},10},
        {"external-a",{20,44,45},{"a20","full-44","full-45"},20},
        {"external-b",{30},{"c30"},30}}};
    air::whole_space::Topology stage;
    assert(expectedFullScreenTopology(two,45,"builtin",1,stage));
    assert(expectedFullScreenTopology(stage,44,"builtin",2,moved));
    assert(expectedFullScreenTopology(moved,44,"external-a",1,stage));
    assert(expectedFullScreenTopology(stage,45,"external-a",2,returned));
    assert(sameWholeTopology(two,returned));

    WholeFullScreenSpace fs;
    fs.sid=44;fs.uuid="full-44";fs.sourceDisplay="external-a";
    fs.sourceIndex=2;fs.owner=900;fs.pid=123;fs.bundle="fixture.app";
    fs.birthSeconds=1000;fs.birthMicroseconds=22;fs.launchTime=1000.000022;
    fs.ownerFrame=CGRectMake(-1920,0,1920,1080);
    fs.surfaces={{900,fs.ownerFrame},{901,CGRectMake(-1920,-10,1920,42)}};
    wholeFullScreens={fs};wholeFullScreenMoves={0};
    wholeFullScreenForwardDone=1;wholeFullScreenReverseDone=0;
    wholeFullScreenPending={true,true,0,moved,original};
    NSDictionary *encoded=encodeWholeFullScreens();
    std::vector<WholeFullScreenSpace> parsed;
    std::vector<uint32_t> moveOrder;uint32_t forward=0,reverse=0;
    WholeFullScreenPending pending;
    std::vector<WholeFullScreenSelection> selections;
    uint32_t anchored=0,selected=0;bool restoreStarted=false;
    WholeFullScreenSelectionPending selectionPending;
    int runtimeIndex=-1;WholeFullScreenRuntimePending runtimePending;
    assert(decodeWholeFullScreens(encoded,parsed,moveOrder,forward,reverse,pending,
        selections,anchored,selected,restoreStarted,selectionPending,runtimeIndex,runtimePending));
    assert(parsed.size()==1 && parsed[0].sid==44 && parsed[0].surfaces.size()==2);
    assert(moveOrder==std::vector<uint32_t>{0} && forward==1 && reverse==0);
    assert(pending.active && pending.reverse && sameWholeTopology(pending.before,moved)
        && sameWholeTopology(pending.after,original));
    NSMutableDictionary *tampered=[encoded mutableCopy];
    NSMutableArray *spaces=[encoded[@"spaces"] mutableCopy];
    NSMutableDictionary *badSpace=[spaces[0] mutableCopy];badSpace[@"owner"]=@999;
    spaces[0]=badSpace;tampered[@"spaces"]=spaces;
    parsed.clear();moveOrder.clear();pending={};
    assert(!decodeWholeFullScreens(tampered,parsed,moveOrder,forward,reverse,pending,
        selections,anchored,selected,restoreStarted,selectionPending,runtimeIndex,runtimePending));

    wholeFullScreenForwardDone=wholeFullScreenReverseDone=0;wholeFullScreenPending={};
    std::string why;
    assert(air::whole_space::begin(wholeJournal,original,"builtin",
        [](uint64_t sid){return sid==44 ? 4 : 0;},&why));
    builtinUUID="builtin";initialSpace=10;wholeFrameInventoryComplete=true;
    std::string pattern=std::string(NSTemporaryDirectory().fileSystemRepresentation)
        +"air-fullscreen-root-XXXXXX";
    std::vector<char> path(pattern.begin(),pattern.end());path.push_back(0);
    assert(mkdtemp(path.data()));
    NSString *folder=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    assert(persist());
    NSDictionary *root=dictionary([NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil]);
    assert([number(root[@"version"]) intValue]==17);
    SavedWindow dialog={777,456,"fixture.dialog","Dialog",CGRectMake(20,30,320,200),
        CGRectMake(0,0,1200,800),1234567890,10,0,"builtin",true};
    dialog.birthSeconds=1234;dialog.birthMicroseconds=5678;
    dialog.memberships={10};dialog.axDialog=true;saved={dialog};
    assert(persist());
    NSDictionary *dialogRoot=dictionary([NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil]);
    assert([number(dialogRoot[@"version"]) intValue]==18);
    saved.clear();wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeJournal={};
    assert(loadJournal() && saved.size()==1 && saved[0].axDialog
        && wholeFullScreens.size()==1 && wholeFullScreens[0].owner==900);
    saved.clear();assert(persist());
    wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeJournal={};
    assert(loadJournal() && wholeFullScreens.size()==1 && wholeFullScreens[0].owner==900
        && wholeFullScreenMoves==std::vector<uint32_t>{0});
    wholeFullScreenSelections={{0,20}};
    wholeFullScreenAnchorDone=0;wholeFullScreenSelectionDone=0;
    air::whole_space::Topology selectedOriginal=original;
    selectedOriginal.displays[1].current=44;
    wholeFullScreenSelectionPending={true,false,0,selectedOriginal,original};
    assert(persist());
    wholeFullScreenSelections.clear();wholeFullScreenSelectionPending={};
    assert(loadJournal() && wholeFullScreenSelections.size()==1
        && wholeFullScreenSelections[0].anchor==20
        && wholeFullScreenSelectionPending.active
        && sameWholeTopology(wholeFullScreenSelectionPending.before,selectedOriginal));
    wholeFullScreenSelectionPending={};wholeFullScreenAnchorDone=1;
    wholeFullScreenSelectionRestoreStarted=true;
    wholeFullScreenSelectionDone=0;
    assert(persist());
    wholeFullScreenSelectionRestoreStarted=false;
    assert(loadJournal() && wholeFullScreenSelectionRestoreStarted
        && wholeFullScreenAnchorDone==1);
    NSMutableDictionary *badRoot=[root mutableCopy];
    badRoot[@"wholeFullScreens"]=NSNull.null;
    assert(!parseJournal(badRoot));

    air::whole_space::Topology prepared=two;
    prepared.displays[0].order.insert(prepared.displays[0].order.end(),{901,902});
    prepared.displays[0].spaceUUIDs.insert(prepared.displays[0].spaceUUIDs.end(),{"p901","p902"});
    assert(air::whole_space::initialize(wholeJournal,prepared,"builtin",901,902,
        "p901","p902",[](uint64_t sid){return sid==44 || sid==45 ? 4 : 0;},&why));
    wholeJournal.forwardDone=4;
    WholeFullScreenSpace firstSpace=fs;firstSpace.sourceIndex=1;
    WholeFullScreenSpace secondSpace=fs;secondSpace.sid=45;secondSpace.uuid="full-45";
    secondSpace.sourceIndex=2;secondSpace.owner=910;
    secondSpace.surfaces={{910,secondSpace.ownerFrame}};
    wholeFullScreens={firstSpace,secondSpace};wholeFullScreenMoves={1,0};
    wholeFullScreenForwardDone=1;wholeFullScreenReverseDone=0;
    wholeFullScreenSelections.clear();wholeFullScreenAnchorDone=wholeFullScreenSelectionDone=0;
    wholeFullScreenSelectionRestoreStarted=false;wholeFullScreenSelectionPending={};
    createdSpaces={901,902};
    ownedSpaces={{901,"p901","builtin"},{902,"p902","builtin"}};
    air::whole_space::Topology beforePending,afterPending;
    assert(expectedFullScreenTopology(two,45,"builtin",1,beforePending));
    assert(expectedFullScreenTopology(beforePending,44,"builtin",2,afterPending));
    wholeFullScreenPending={true,false,1,beforePending,afterPending};
    assert(fullScreenForwardEndpoint(wholeFullScreenPending,beforePending)
        ==WholeFullScreenForwardEndpoint::Before);
    assert(fullScreenForwardEndpoint(wholeFullScreenPending,afterPending)
        ==WholeFullScreenForwardEndpoint::After);
    assert(fullScreenForwardEndpoint(wholeFullScreenPending,two)
        ==WholeFullScreenForwardEndpoint::Unknown);
    assert(persist());
    wholeFullScreenPending={};
    assert(loadJournal() && wholeFullScreenPending.active
        && wholeFullScreenPending.ordinal==1);
    wholeFullScreenPending={};
    assert(persist());
    wholeFullScreenReverseDone=1;
    assert(persist());
    wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeJournal={};
    assert(loadJournal() && wholeFullScreenForwardDone==1 && wholeFullScreenReverseDone==1
        && wholeFullScreenMoves==std::vector<uint32_t>({1,0}));
    wholeFullScreenForwardDone=2;wholeFullScreenReverseDone=0;
    wholeFullScreenRuntimeIndex=1;
    air::whole_space::Topology selectedExtra=afterPending;
    selectedExtra.displays[0].current=44;
    wholeFullScreenRuntimePending={true,-1,selectedExtra,afterPending};
    assert(persist());
    wholeFullScreenRuntimeIndex=-1;wholeFullScreenRuntimePending={};
    assert(loadJournal() && wholeFullScreenRuntimeIndex==1
        && wholeFullScreenRuntimePending.active
        && wholeFullScreenRuntimePending.targetIndex==-1
        && sameWholeTopology(wholeFullScreenRuntimePending.before,selectedExtra)
        && sameWholeTopology(wholeFullScreenRuntimePending.after,afterPending));
    NSDictionary *runtimeRecord=encodeWholeFullScreens();
    NSMutableDictionary *badRuntime=[runtimeRecord mutableCopy];
    badRuntime[@"runtimeIndex"]=@2;
    assert(!decodeWholeFullScreens(badRuntime,parsed,moveOrder,forward,reverse,pending,
        selections,anchored,selected,restoreStarted,selectionPending,runtimeIndex,runtimePending));
    journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);
    puts("whole fullscreen topology and durable owner journal passed");
    return 0;
} }
