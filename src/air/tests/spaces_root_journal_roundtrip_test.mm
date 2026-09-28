#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>
extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore() { return 0; }
static void resetFixture(bool initiallyFull) {
    saved.clear();createdSpaces.clear();ownedSpaces.clear();pendingCreateBefore.clear();pendingCreate=false;
    initialSelections.clear();selectionPending={};
    initialSpace=189;builtinUUID="builtin";initialFullScreenIndex=initiallyFull ? 0 : -1;
    initialFullScreenSpace=initiallyFull ? 801 : 0;finalSelectionPending=false;
    lastSelectedSpace=0;slots[0]=slots[1]=slots[2]=0;active=false;
    SavedWindow w={101,42,"fixture.bundle","fixture",CGRectMake(20,20,500,400),
        CGRectMake(0,0,1000,800),1234567890,initiallyFull ? 189ULL : 801ULL,
        initiallyFull ? 0 : 1,initiallyFull ? "builtin" : "external",true};
    w.fullScreen=true;w.fullScreenPhase=initiallyFull ? 3 : 1;w.fullScreenSpace=801;
    w.axIdentifier="fixture.identity";saved.push_back(w);
    initialSelections.push_back({w.sourceUUID,initiallyFull ? 801ULL : 189ULL,
        initiallyFull ? 4 : 0,initiallyFull ? 0 : -1,189});
}
int main() { @autoreleasepool {
    std::string pattern=std::string(NSTemporaryDirectory().fileSystemRepresentation)+"air-root-roundtrip-XXXXXX";
    std::vector<char> path(pattern.begin(),pattern.end());path.push_back(0);
    if(!mkdtemp(path.data()))return 2;
    NSString *folder=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    int failures=0;
    auto check=[&](bool result,const char *name){printf("%s %s\n",result ? "PASS" : "FAIL",name);if(!result)failures++;};

    resetFixture(false);
    selectionPending={true,"external",189,801,0,SelectionPurpose::Prepare,1};
    check(persist() && loadJournal(),"prepare-selection record survives process reload");

    resetFixture(false);selectionPending={true,"external",189,0,0,SelectionPurpose::Reenter,1};
    saved[0].fullScreenPhase=2;saved[0].space=189;
    if(!persist())return 2;
    NSMutableDictionary *invalid=[[NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    invalid[@"selectionPending"][@"windowIndex"]=@9999;
    initialSpace=777;builtinUUID="sentinel";slots[0]=73;createdSpaces={72};
    bool rejected=!parseJournal(invalid);
    check(rejected && initialSpace==777 && builtinUUID=="sentinel" && slots[0]==73
        && createdSpaces==std::vector<uint64_t>{72},"invalid pending identity leaves existing globals intact");

    resetFixture(true);selectionPending={true,"builtin",189,0,0,SelectionPurpose::Reenter,1};
    check(finishReentryAction(0,901) && loadJournal(),"initial-fullscreen reentry record survives process reload");

    resetFixture(true);if(!persist())return 2;
    NSMutableDictionary *badOriginal=[[NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    badOriginal[@"windows"][0][@"fullScreenSpace"]=@802;
    check(!parseJournal(badOriginal),"phase3 initial-fullscreen original SID mismatch rejected");

    resetFixture(true);if(!persist())return 2;
    NSMutableDictionary *badSelection=[[NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    badSelection[@"displaySelections"][0][@"space"]=@802;
    check(!parseJournal(badSelection),"phase3 selected-fullscreen original SID mismatch rejected");

    journalTestPath=nil;
    if(![[NSFileManager defaultManager] removeItemAtPath:folder error:nil])return 2;
    return failures ? 1 : 0;
} }
