#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
extern "C" void air_set_error(const char*){}
extern "C" int air_display_restore(void){return 0;}
static NSMutableDictionary *disp=nil;static bool full=false,stable=true,hideAX=false;static uint64_t member=0;static int switches=0;
static int conn(){return 7;} static CFArrayRef managedStub(int){return nullptr;}
static int typeStub(int,uint64_t s){return s>=800?4:0;} static CFArrayRef memberships(int,int,CFArrayRef){return nullptr;}
static AXError axStub(AXUIElementRef,CGWindowID*){return kAXErrorFailure;}
static bool sw(const std::string &u,uint64_t s){if(u!="external")return false;switches++;disp[@"Current Space"]=@{@"id64":@(s)};return true;}
static uint32_t resolve(const SavedWindow&w){return hideAX?0:w.id;} static int fs(const SavedWindow&){return full?1:0;}
static uint64_t ordinary(const SavedWindow&){return full?0:member;} static uint64_t fullsid(const SavedWindow&){return full?member:0;}
static bool ondisplay(uint32_t,const std::string&u){return u=="external";}
static bool frame(const SavedWindow&,CGRect*f){static int n=0;*f=stable||n++%2==0?CGRectMake(20,20,500,400):CGRectMake(30,20,500,400);return true;}
static void reload(){saved.clear();initialSelections.clear();selectionPending={};assert(loadJournal());}
static void base(){saved.clear();initialSelections.clear();selectionPending={};createdSpaces.clear();ownedSpaces.clear();pendingCreateBefore.clear();pendingCreate=false;initialSpace=189;builtinUUID="builtin";initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;lastSelectedSpace=0;slots[0]=slots[1]=slots[2]=0;
 SavedWindow a={101,10,"a","a",CGRectMake(0,0,100,100),CGRectMake(-1000,0,1000,800),1,801,1,"external",true};a.fullScreen=true;a.fullScreenPhase=4;a.fullScreenSpace=801;a.axIdentifier="a";
 SavedWindow b=a;b.id=102;b.pid=11;b.bundle="b";b.fullScreenSpace=802;b.space=802;b.axIdentifier="b";saved={a,b};initialSelections.push_back({"external",189,0,-1,801});disp[@"Current Space"]=@{@"id64":@191};}
int main(){@autoreleasepool{
 NSString *pat=[NSTemporaryDirectory() stringByAppendingPathComponent:@"air-selection-v8-XXXXXX"];std::string q=pat.fileSystemRepresentation;std::vector<char>d(q.begin(),q.end());d.push_back(0);assert(mkdtemp(d.data()));NSString*folder=[NSString stringWithUTF8String:d.data()];journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
 disp=[@{@"Display Identifier":@"external",@"Current Space":@{@"id64":@191},@"Spaces":@[@{@"id64":@189,@"type":@0},@{@"id64":@191,@"type":@0},@{@"id64":@192,@"type":@0},@{@"id64":@801,@"type":@4},@{@"id64":@802,@"type":@4},@{@"id64":@901,@"type":@4}]} mutableCopy];
 RecoveryHooks h={};h.inventory=@[disp];h.switchDisplaySpace=sw;h.resolveWindow=resolve;h.fullScreenState=fs;h.ordinaryAfterExit=ordinary;h.fullScreenSpaceID=fullsid;h.windowDisplay=ondisplay;h.afterExitFrame=frame;recoveryHooks=&h;Api&a=api();a.conn=conn;a.managed=managedStub;a.spaceType=typeStub;a.windowSpaces=memberships;a.axWindow=axStub;
 base();full=false;member=191;selectionPending={true,"external",801,0,0,SelectionPurpose::Prepare,1};assert(persist());reload();assert(reconcileSelectionPending(7));assert(saved[0].fullScreenPhase==2);assert(saved[0].space==191&&initialSelections[0].hostSpace==191);
 saved[1].fullScreenPhase=4;selectionPending={true,"external",802,0,1,SelectionPurpose::Prepare,1};initialSelections[0].hostSpace=802;disp[@"Current Space"]=@{@"id64":@192};member=192;stable=true;assert(persist());reload();assert(reconcileSelectionPending(7));assert(saved[1].space==192&&initialSelections[0].hostSpace==192);
 saved[0].fullScreenPhase=2;saved[0].space=191;selectionPending={true,"external",191,0,0,SelectionPurpose::Reenter,1};initialSelections[0].hostSpace=191;disp[@"Current Space"]=@{@"id64":@901};full=true;member=901;assert(persist());reload();assert(reconcileSelectionPending(7));assert(saved[0].fullScreenPhase==3&&initialSelections[0].hostSpace==901);
 hideAX=true;disp[@"Current Space"]=@{@"id64":@902};member=901;assert(restoreFullScreenWindow(saved[0],7));hideAX=false;
 base();saved[0].fullScreenPhase=4;selectionPending={true,"external",801,0,0,SelectionPurpose::Prepare,1};
 initialSelections[0].hostSpace=801;disp[@"Current Space"]=@{@"id64":@901};full=true;member=901;
 assert(persist());reload();assert(reconcileSelectionPending(7));
 assert(initialSelections[0].hostSpace==901&&!selectionPending.active&&saved[0].fullScreenSpace==801);
 base();full=false;member=191;stable=false;selectionPending={true,"external",801,0,0,SelectionPurpose::Prepare,1};assert(persist());assert(!reconcileSelectionPending(7));assert(saved[0].fullScreenPhase==4&&selectionPending.active);
 base();disp[@"Current Space"]=@{@"id64":@777};selectionPending={true,"external",801,0,0,SelectionPurpose::Prepare,1};assert(persist());assert(!reconcileSelectionPending(7)&&selectionPending.active);
 recoveryHooks=nullptr;journalTestPath=nil;assert([[NSFileManager defaultManager] removeItemAtPath:folder error:nil]);puts("integrated v8 selection journal: distinct exit anchors, reentry adoption, stable-frame and unrelated-space guards passed");
}}
