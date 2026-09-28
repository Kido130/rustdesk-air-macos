#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char*){}
extern "C" int air_display_restore(){return 0;}
static NSMutableDictionary *builtin=nil;static int removeCalls=0;static bool removalSawDurableClear=true;
static int conn(){return 7;}static CFArrayRef managedStub(int){return nullptr;}static int typeStub(int,uint64_t){return 0;}
static CFArrayRef membershipStub(int,int,CFArrayRef){return nullptr;}static AXError axStub(AXUIElementRef,CGWindowID*){return kAXErrorFailure;}
static int stateStub(const SavedWindow&){return (int)WindowState::Ready;}static bool moveStub(uint32_t,uint64_t){return true;}
static bool frameStub(const SavedWindow&){return true;}static bool displayStub(uint32_t,const std::string&){return true;}
static int missionStub(){return (int)MissionState::Absent;}static bool topologyStub(std::vector<std::string>&v,const std::string&,bool&o){v={"builtin","external"};o=true;return true;}
static bool parkingWindowsStub(uint64_t,std::vector<ParkingWindowIdentity>&windows,std::string*){windows.clear();return true;}
static bool switchStub(uint64_t sid){builtin[@"Current Space"]=@{@"id64":@(sid)};return true;}
static NSDictionary *diskJournal(){NSData*d=[NSData dataWithContentsOfFile:journalTestPath];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;}
static bool removeStub(uint64_t sid){
 removeCalls++;NSDictionary*j=diskJournal();NSArray*diskSlots=[j[@"slotSpaceIDs"] isKindOfClass:NSArray.class]?j[@"slotSpaceIDs"]:nil;
 removalSawDurableClear&=diskSlots&&diskSlots.count==0&&[j[@"lastSelectedSpace"] unsignedLongLongValue]==0&&!active&&!switchVerified;
 NSMutableArray *left=[NSMutableArray array];for(NSDictionary*s in builtin[@"Spaces"])if([s[@"id64"] unsignedLongLongValue]!=sid)[left addObject:s];builtin[@"Spaces"]=left;return true;
}
static void clearMemory(){saved.clear();createdSpaces.clear();ownedSpaces.clear();pendingCreateBefore.clear();initialSelections.clear();selectionPending={};slots[0]=slots[1]=slots[2]=0;initialSpace=0;lastSelectedSpace=0;builtinUUID.clear();active=false;switchVerified=false;pendingCreate=false;initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;}
static void seed(){
 clearMemory();builtin=[@{@"Display Identifier":@"builtin",@"Current Space":@{@"id64":@273},@"Spaces":[@[
  @{@"id64":@1,@"uuid":@"original",@"type":@0},@{@"id64":@10,@"uuid":@"user-a",@"type":@0},@{@"id64":@11,@"uuid":@"user-b",@"type":@0},
  @{@"id64":@272,@"uuid":@"owned-a",@"type":@0},@{@"id64":@273,@"uuid":@"owned-b",@"type":@0},@{@"id64":@274,@"uuid":@"owned-c",@"type":@0}] mutableCopy]} mutableCopy];
 recoveryHooks->inventory=@[builtin,@{@"Display Identifier":@"external",@"Current Space":@{@"id64":@50},@"Spaces":@[@{@"id64":@50,@"uuid":@"external-original",@"type":@0}]}];
 initialSpace=1;builtinUUID="builtin";slots[0]=272;slots[1]=273;slots[2]=274;lastSelectedSpace=273;active=true;switchVerified=true;
 createdSpaces={272,273,274};ownedSpaces={{272,"owned-a","builtin"},{273,"owned-b","builtin"},{274,"owned-c","builtin"}};
 saved.push_back({71,42,"fixture.bundle","private-title",CGRectMake(-1400,80,500,400),CGRectMake(-1920,0,1920,1080),1234,50,1,"external",true});
 assert(persist());
}
int main(int argc,char**argv){@autoreleasepool{
 NSString*parent=argc>1?[NSString stringWithUTF8String:argv[1]]:NSTemporaryDirectory();NSString*pattern=[parent stringByAppendingPathComponent:@"air-cleanup-restart-XXXXXX"];
 std::string q=pattern.fileSystemRepresentation;std::vector<char>d(q.begin(),q.end());d.push_back(0);assert(mkdtemp(d.data()));NSString*base=[NSString stringWithUTF8String:d.data()];journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
 RecoveryHooks hooks={};hooks.windowState=stateStub;hooks.move=moveStub;hooks.frame=frameStub;hooks.windowDisplay=displayStub;hooks.switchSpace=switchStub;hooks.remove=removeStub;hooks.missionState=missionStub;hooks.onlineTopology=topologyStub;hooks.parkingWindows=parkingWindowsStub;recoveryHooks=&hooks;
 Api&a=api();a.conn=conn;a.managed=managedStub;a.spaceType=typeStub;a.windowSpaces=membershipStub;a.axWindow=axStub;
 seed();builtin[@"Current Space"]=@{@"id64":@1};assert(restoreLocked()==0);assert(removalSawDurableClear&&removeCalls==3);assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
 for(int removed=1;removed<=3;removed++){
  seed();builtin[@"Current Space"]=@{@"id64":@1};assert(beginOwnedCleanup());assert(slots[0]==0&&slots[1]==0&&slots[2]==0&&!active&&!switchVerified&&lastSelectedSpace==0);
  for(int n=0;n<removed;n++){uint64_t sid=createdSpaces.front();assert(removeStub(sid));ownedSpaces.erase(ownedSpaces.begin());createdSpaces.erase(createdSpaces.begin());assert(persist());}
  clearMemory();assert(loadJournal());assert(saved.size()==1&&saved[0].id==71&&saved[0].space==50&&initialSpace==1);assert(!slots[0]&&!slots[1]&&!slots[2]&&!active&&!switchVerified&&lastSelectedSpace==0);assert(createdSpaces.size()==size_t(3-removed)&&ownedSpaces.size()==size_t(3-removed));
  assert(restoreLocked()==0);assert([builtin[@"Current Space"][@"id64"] unsignedLongLongValue]==1);assert(![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]);
 }
 seed();builtin[@"Current Space"]=@{@"id64":@1};uint64_t beforeSlots[3]={slots[0],slots[1],slots[2]};uint64_t beforeSelected=lastSelectedSpace;bool beforeActive=active,beforeSwitch=switchVerified;int beforeRemove=removeCalls;
 NSString*block=[base stringByAppendingPathComponent:@"block"];assert([@"x" writeToFile:block atomically:YES encoding:NSUTF8StringEncoding error:nil]);NSString*good=journalTestPath;journalTestPath=[block stringByAppendingPathComponent:@"bad.json"];
 assert(restoreLocked()!=0);assert(removeCalls==beforeRemove&&slots[0]==beforeSlots[0]&&slots[1]==beforeSlots[1]&&slots[2]==beforeSlots[2]&&lastSelectedSpace==beforeSelected&&active==beforeActive&&switchVerified==beforeSwitch);
 journalTestPath=good;assert(removalSawDurableClear);recoveryHooks=nullptr;journalTestPath=nil;assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
 puts("owned cleanup: durable slot clear, restart after removals 1/2/3, resume, window/current evidence, write-failure no-delete passed");return 0;
}}
