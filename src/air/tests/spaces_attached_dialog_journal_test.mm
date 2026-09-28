#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }
static int alwaysReady(const SavedWindow &) { return (int)WindowState::Ready; }
static int moveCount=0;
static bool countMove(uint32_t,uint64_t) { moveCount++;return true; }

int main() { @autoreleasepool {
    char pattern[]="/tmp/air-attached-journal-XXXXXX";
    if(!mkdtemp(pattern))return 2;
    NSString *folder=[NSString stringWithUTF8String:pattern];
    journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
    air::whole_space::Topology topology={{{"builtin",{100,800,801},
        {"builtin-original","parking-a","parking-b"},100},
        {"external-a",{200},{"external-original-a"},200},
        {"external-b",{300},{"external-original-b"},300}}};
    std::string why;
    if(!air::whole_space::initialize(wholeJournal,topology,"builtin",800,801,
        "parking-a","parking-b",[](uint64_t){return 0;},&why))return 3;
    builtinUUID="builtin";initialSpace=100;lastSelectedSpace=100;
    createdSpaces={800,801};
    ownedSpaces={{800,"parking-a","builtin"},{801,"parking-b","builtin"}};
    wholeFrameInventoryComplete=true;
    CGRect display=CGRectMake(-1920,0,1920,1080);
    SavedWindow parent={101,42,"fixture.bundle","root",
        CGRectMake(-1800,80,700,500),display,1234567890,200,1,"external-a",true};
    parent.birthSeconds=123;parent.birthMicroseconds=456;parent.memberships={200};
    SavedWindow child={102,42,"fixture.bundle","floating",
        CGRectMake(-1780,100,300,180),display,1234567890,200,1,"external-a",true};
    child.birthSeconds=123;child.birthMicroseconds=456;child.memberships={200};
    child.followerParent=101;child.followerOffset=CGPointMake(20,20);
    saved={parent,child};
    int failures=0;
    auto check=[&](bool okay,const char *label) {
        printf("%s %s\n",okay ? "PASS" : "FAIL",label);
        if(!okay)failures++;
    };
    check(supportedAttachedFollowerSubrole(@"AXFloatingWindow")
        && !supportedAttachedFollowerSubrole(@"AXSystemDialog")
        && !supportedAttachedFollowerSubrole(@"AXDialog"),
        "untested dialog subtypes remain refused");
    check(persist(),"durable follower journal persisted");
    NSData *data=[NSData dataWithContentsOfFile:journalTestPath];
    NSDictionary *original=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    check([number(original[@"version"]) intValue]==20,
        "follower record uses journal version 20");
    saved.clear();wholeJournal={};wholeFrameInventoryComplete=false;
    check(loadJournal() && saved.size()==2 && saved[1].followerParent==101
        && saved[1].followerOffset.x==20 && saved[1].followerOffset.y==20,
        "parent link and relative frame survive reload");
    auto mutate=[&](void (^change)(NSMutableDictionary *,NSMutableArray *)) {
        NSMutableDictionary *journal=[[NSJSONSerialization JSONObjectWithData:data
            options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        NSMutableArray *windows=journal[@"windows"];
        change(journal,windows);
        return !parseJournal(journal);
    };
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"followerParent"]=@999;
    }),"missing parent rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"followerX"]=@77;
    }),"changed relative geometry rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[0][@"followerParent"]=@102;
    }),"parent follower cycle rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"memberships"]=@[@300];
    }),"different parent/child Space rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"pid"]=@43;
    }),"different parent/child process rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"sourceUUID"]=@"external-b";
    }),"different parent/child display rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"dx"]=@(-1800);
    }),"different parent/child display bounds rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"birthMicroseconds"]=@457;
    }),"different parent/child process birth rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        windows[1][@"w"]=@810;
    }),"follower larger than parent rejected");
    check(mutate(^(NSMutableDictionary *,NSMutableArray *windows) {
        [windows[1] removeObjectForKey:@"followerParent"];
    }),"missing follower identity rejected");
    check(mutate(^(NSMutableDictionary *journal,NSMutableArray *) {
        journal[@"version"]=@19;
    }),"journal version downgrade cannot discard follower identity");
    RecoveryHooks hooks={};hooks.windowState=alwaysReady;hooks.move=countMove;
    recoveryHooks=&hooks;slots[1]=201;
    SavedWindow wideChild=child;
    wideChild.frame.origin.x=parent.frame.origin.x+400;
    wideChild.followerOffset=CGPointMake(400,20);
    saved={parent,wideChild};moveCount=0;why.clear();
    check(!placeActivationWindows(7,CGRectMake(0,0,600,450),&why)
        && why.find("stage=follower_bounds")!=std::string::npos && moveCount==0,
        "clipped attached child refuses before first window move");
    recoveryHooks=nullptr;slots[1]=0;
    saved={parent};
    check(persist(),"older whole-Space journal persisted");
    NSData *older=[NSData dataWithContentsOfFile:journalTestPath];
    NSDictionary *olderRecord=[NSJSONSerialization JSONObjectWithData:older options:0 error:nil];
    saved.clear();wholeJournal={};wholeFrameInventoryComplete=false;
    check([number(olderRecord[@"version"]) intValue]==16 && loadJournal()
        && saved.size()==1 && saved[0].followerParent==0,
        "version 16 recovery remains readable");
    parent.axDialog=true;saved={parent};
    check(persist(),"older dialog journal persisted");
    older=[NSData dataWithContentsOfFile:journalTestPath];
    olderRecord=[NSJSONSerialization JSONObjectWithData:older options:0 error:nil];
    saved.clear();wholeJournal={};wholeFrameInventoryComplete=false;
    check([number(olderRecord[@"version"]) intValue]==18 && loadJournal()
        && saved.size()==1 && saved[0].axDialog && saved[0].followerParent==0,
        "version 18 dialog recovery remains readable");
    journalTestPath=nil;
    [[NSFileManager defaultManager] removeItemAtPath:folder error:nil];
    return failures ? 1 : 0;
} }
