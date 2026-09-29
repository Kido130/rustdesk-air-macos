#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#include "spaces.h"
#include "whole_space_swap.h"
#ifdef AIR_SPACES_JOURNAL_TEST
#include "whole_space_swap.mm"
#endif
extern "C" void air_set_error(const char *);
#include <dlfcn.h>
#include <mutex>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <sys/stat.h>
#include <sys/file.h>
#include <libproc.h>
#include <limits.h>
#include <atomic>
#include <dispatch/dispatch.h>
extern "C" int air_display_restore(void);

// SkyLight's bridged operation is private; resolve its class and selectors at
// runtime and verify the resulting Space membership after every invocation.
@interface NSObject (AirBridgedSpaceMove)
- (id)initWithWindows:(NSArray *)windows spaceID:(unsigned long long)spaceID;
- (id)initWithDisplayIdentifier:(NSString *)displayIdentifier spaceID:(unsigned long long)spaceID;
- (id)initWithSpaceID:(unsigned long long)spaceID;
- (id)initWithSpaceID:(unsigned long long)spaceID displayIdentifier:(NSString *)displayIdentifier index:(unsigned int)index;
- (void)performWithWMBridgeDelegate;
@end

bool vanishedCompleteInventoryWindow(uint32_t wid,int cid,const char **reason);
namespace {
using Conn = int (*)();
using Managed = CFArrayRef (*)(int);
using WindowSpaces = CFArrayRef (*)(int,int,CFArrayRef);
using SpaceType = int (*)(int,uint64_t);
using Compat = CGError (*)(int,uint64_t,int);
using Workspace = CGError (*)(int,uint32_t *,int,int);
using LegacyMove = void (*)(int,CFArrayRef,uint64_t);
using CoreDock = CGError (*)(CFStringRef,int);
using AXWindow = AXError (*)(AXUIElementRef,CGWindowID *);
using WindowDisplay = CFStringRef (*)(int,uint32_t);
using SpaceWindows = CFArrayRef (*)(int,uint32_t,CFArrayRef,uint32_t,uint64_t *,uint64_t *);
using MoveWindow = CGError (*)(int,uint32_t,const CGPoint *);
struct Api { void *sky=nullptr,*app=nullptr; Conn conn=nullptr; Managed managed=nullptr; WindowSpaces windowSpaces=nullptr; SpaceType spaceType=nullptr; Compat compat=nullptr; Workspace workspace=nullptr; LegacyMove legacyMove=nullptr; CoreDock dock=nullptr; AXWindow axWindow=nullptr; WindowDisplay windowDisplay=nullptr; SpaceWindows spaceWindows=nullptr; MoveWindow moveWindow=nullptr; };
struct SavedWindow { uint32_t id; pid_t pid; std::string bundle,title; CGRect frame,sourceDisplay; double launchTime; uint64_t space; int slot; std::string sourceUUID; bool frameFromAX=false; bool fullScreen=false; int fullScreenPhase=0; uint64_t fullScreenSpace=0; std::string axIdentifier; bool cgOnly=false; uint64_t birthSeconds=0,birthMicroseconds=0; std::vector<uint64_t> memberships; bool readOnlyCG=false; uint64_t surfaceTags=0; bool axDialog=false; uint32_t followerParent=0; CGPoint followerOffset={}; bool minimizedKnown=false,minimized=false; };
struct OwnedSpace { uint64_t id; std::string uuid,displayUUID; };
struct ParkingWindowIdentity {
    uint32_t id=0;pid_t pid=0;std::string bundle;double launchTime=0;
    uint64_t birthSeconds=0,birthMicroseconds=0;
    uint64_t sourceSpace=0,destinationSpace=0;
    bool requiresAX=true;CGRect cgFrame={};
};
struct ParkingEvacuation { bool active=false;ParkingWindowIdentity window; };
// A window opened on an external display after its ordinary Space moved to the
// built-in panel. The move intent is durable; the selected Space itself returns
// to that display during whole-Space restoration.
struct RuntimeLaunchWindow {
    uint32_t id=0;pid_t pid=0;std::string bundle,sourceDisplay;
    double launchTime=0;uint64_t birthSeconds=0,birthMicroseconds=0;
    uint64_t sourceSpace=0,destination=0;int slot=0,stage=0;
    CGRect originalFrame={};
};
struct EdgeTransfer {
    uint32_t window=0;
    uint64_t original=0,from=0,target=0;
    int stage=0;
    uint64_t releaseSpace=0;
    std::string releaseDisplay;
    CGRect releaseFrame={};
};
struct WholeFullScreenSurface {
    uint32_t wid=0;CGRect frame={};
};
struct WholeFullScreenSpace {
    uint64_t sid=0;std::string uuid,sourceDisplay,bundle;
    uint32_t sourceIndex=0,owner=0;pid_t pid=0;
    uint64_t birthSeconds=0,birthMicroseconds=0;double launchTime=0;
    CGRect ownerFrame={};
    std::vector<WholeFullScreenSurface> surfaces;
};
struct WholeFullScreenPending {
    bool active=false,reverse=false;
    uint32_t ordinal=0;
    air::whole_space::Topology before,after;
};
struct WholeFullScreenSelection { uint32_t recordIndex=0;uint64_t anchor=0; };
struct WholeFullScreenSelectionPending {
    bool active=false,restore=false;uint32_t ordinal=0;
    air::whole_space::Topology before,after;
};
struct WholeFullScreenRuntimePending {
    bool active=false;int targetIndex=-1;
    air::whole_space::Topology before,after;
};
struct DisplaySelection { std::string displayUUID; uint64_t space=0; int type=-1; int fullScreenWindow=-1; uint64_t hostSpace=0; };
struct OrdinarySpaceIdentity { uint64_t id=0; std::string displayUUID,spaceUUID; };
enum class SelectionPurpose { Prepare=1,RestoreAnchor=2,Reenter=3,Final=4 };
struct SelectionPending { bool active=false; std::string displayUUID; uint64_t fromSpace=0,targetSpace=0; int windowIndex=-1; SelectionPurpose purpose=SelectionPurpose::Prepare; int stage=0; };
#ifdef AIR_SPACES_JOURNAL_TEST
struct RecoveryHooks {
    NSArray *inventory=nil;
    int (*windowState)(const SavedWindow &)=nullptr;
    bool (*move)(uint32_t,uint64_t)=nullptr;
    bool (*frame)(const SavedWindow &)=nullptr;
    bool (*frameAt)(const SavedWindow &,CGRect)=nullptr;
    bool (*windowDisplay)(uint32_t,const std::string &)=nullptr;
    bool (*displayBounds)(const std::string &,CGRect *)=nullptr;
    bool (*switchSpace)(uint64_t)=nullptr;
    bool (*remove)(uint64_t)=nullptr;
    int (*missionState)()=nullptr;
    bool (*onlineTopology)(std::vector<std::string> &,const std::string &,bool &)=nullptr;
    bool (*registerCallback)()=nullptr;
    int (*displayRestore)()=nullptr;
    void (*scheduleRetry)(uint64_t,uint64_t,unsigned)=nullptr;
    bool (*enabled)()=nullptr;
    const char *(*migrationBlocker)()=nullptr;
    bool (*switchAvailable)()=nullptr;
    int (*fullScreenState)(const SavedWindow &)=nullptr;
    bool (*setFullScreen)(const SavedWindow &,bool)=nullptr;
    uint32_t (*resolveWindow)(const SavedWindow &)=nullptr;
    uint64_t (*ordinaryAfterExit)(const SavedWindow &)=nullptr;
    bool (*fullScreenMembership)(const SavedWindow &)=nullptr;
    uint64_t (*fullScreenSpaceID)(const SavedWindow &)=nullptr;
    bool (*afterExitFrame)(const SavedWindow &,CGRect *)=nullptr;
    bool (*switchDisplaySpace)(const std::string &,uint64_t)=nullptr;
    uint64_t (*windowSpace)(uint32_t)=nullptr;
    std::vector<uint64_t> (*windowMembership)(uint32_t)=nullptr;
    bool (*parkingWindows)(uint64_t,std::vector<ParkingWindowIdentity> &,std::string *)=nullptr;
    int (*parkingWindowState)(const ParkingWindowIdentity &)=nullptr;
    bool (*moveParkingWindow)(const ParkingWindowIdentity &)=nullptr;
    bool (*setAttachedFollowerPosition)(const SavedWindow &,CGPoint)=nullptr;
    bool (*edgeWindowEligible)(const SavedWindow &,uint64_t)=nullptr;
    bool (*edgeWindowVisible)(uint32_t)=nullptr;
    bool (*edgeWindowFrame)(const SavedWindow &,CGRect *)=nullptr;
    bool (*finalWindowIdentity)(const SavedWindow &,uint64_t)=nullptr;
    bool (*alreadyRestoredOrdinary)(const SavedWindow &)=nullptr;
};
RecoveryHooks *recoveryHooks=nullptr;
#endif
std::mutex mutex;
std::vector<SavedWindow> saved;
struct ReusedRoute { uint32_t id=0;uint64_t target=0;unsigned attempts=0; };
std::set<uint32_t> reusedRouteBaseline;
std::set<pid_t> reusedRouteBaselineChromePIDs;
std::vector<ReusedRoute> reusedRoutePending;
std::atomic<bool> reusedRouteBusy{false};
std::atomic<int> reusedCachedSlot{0},reusedCachedCount{0},reusedCachedLoop{0};
CFAbsoluteTime nextReusedRouteScan=0;
std::vector<uint64_t> createdSpaces;
std::vector<OwnedSpace> ownedSpaces;
std::vector<OwnedSpace> reusedSlots;
std::vector<uint64_t> pendingCreateBefore;
bool pendingCreate=false;
uint64_t lastSelectedSpace=0;
std::string journalIOError;
int journalLockFD=-1;
#ifdef AIR_SPACES_JOURNAL_TEST
NSString *journalTestPath=nil;
#endif
uint64_t slots[3]={};
uint64_t initialSpace=0;
int initialFullScreenIndex=-1;
uint64_t initialFullScreenSpace=0;
bool finalSelectionPending=false;
std::vector<DisplaySelection> initialSelections;
std::vector<OrdinarySpaceIdentity> ordinarySpaceIdentities;
SelectionPending selectionPending;
std::string builtinUUID;
bool active=false;
bool windowInventoryComplete=true;
bool wholeFrameInventoryComplete=false;
bool shuttingDown=false;
bool switchVerified=false;
bool pendingDisplayRecovery=false,callbackRegistered=false,observedBuiltinOnline=false;
bool retryDisplayInFlight=false;
uint64_t recoveryGeneration=0,retryBurst=0;
std::vector<std::string> observedTopology;
std::atomic<bool> callbackQueued{false};
air::whole_space::Journal wholeJournal;
std::vector<WholeFullScreenSpace> wholeFullScreens;
std::vector<uint32_t> wholeFullScreenMoves;
uint32_t wholeFullScreenForwardDone=0,wholeFullScreenReverseDone=0;
WholeFullScreenPending wholeFullScreenPending;
std::vector<WholeFullScreenSelection> wholeFullScreenSelections;
uint32_t wholeFullScreenAnchorDone=0,wholeFullScreenSelectionDone=0;
bool wholeFullScreenSelectionRestoreStarted=false;
WholeFullScreenSelectionPending wholeFullScreenSelectionPending;
int wholeFullScreenRuntimeIndex=-1;
WholeFullScreenRuntimePending wholeFullScreenRuntimePending;
ParkingEvacuation parkingEvacuation;
std::vector<RuntimeLaunchWindow> runtimeLaunchWindows;
std::vector<EdgeTransfer> edgeTransfers;
int error(const char *message) { air_set_error(message); return -1; }
Api &api() {
    static Api a=[] {
        Api a;
        a.sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
        a.app=dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",RTLD_LAZY);
        if(a.sky) {
            a.conn=(Conn)dlsym(a.sky,"SLSMainConnectionID");
            a.managed=(Managed)dlsym(a.sky,"SLSCopyManagedDisplaySpaces");
            a.windowSpaces=(WindowSpaces)dlsym(a.sky,"SLSCopySpacesForWindows");
            a.spaceType=(SpaceType)dlsym(a.sky,"SLSSpaceGetType");
            a.compat=(Compat)dlsym(a.sky,"SLSSpaceSetCompatID");
            a.workspace=(Workspace)dlsym(a.sky,"SLSSetWindowListWorkspace");
            a.legacyMove=(LegacyMove)dlsym(a.sky,"SLSMoveWindowsToManagedSpace");
            a.windowDisplay=(WindowDisplay)dlsym(a.sky,"SLSCopyManagedDisplayForWindow");
            a.spaceWindows=(SpaceWindows)dlsym(a.sky,"SLSCopyWindowsWithOptionsAndTags");
            a.moveWindow=(MoveWindow)dlsym(a.sky,"SLSMoveWindow");
            a.dock=(CoreDock)dlsym(a.app,"CoreDockSendNotification");
        }
        if(a.app) a.axWindow=(AXWindow)dlsym(a.app,"_AXUIElementGetWindow");
        return a;
    }();
    return a;
}
NSString *journalPath() {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(journalTestPath)return journalTestPath;
#endif
    NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RustDesk Air"];
    return [base stringByAppendingPathComponent:@"spaces-recovery.json"];
}
void releaseJournalLock() {
    if(journalLockFD>=0){close(journalLockFD);journalLockFD=-1;}
}
bool acquireJournalLock() {
    if(journalLockFD>=0)return true;
    NSString *directory=[journalPath() stringByDeletingLastPathComponent];
    NSError *creation=nil;
    if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&creation]) {
        journalIOError=creation.localizedDescription.UTF8String ?: "Cannot create Spaces lock directory";return false;
    }
    struct stat folder={};
    if(lstat(directory.fileSystemRepresentation,&folder)!=0 || !S_ISDIR(folder.st_mode)
        || folder.st_uid!=geteuid() || chmod(directory.fileSystemRepresentation,0700)!=0) {
        journalIOError="Spaces lock directory is unavailable or not owned by this user";return false;
    }
    NSString *path=[directory stringByAppendingPathComponent:@".spaces-recovery.lock"];
    int fd=open(path.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) {journalIOError=std::string("Cannot open Spaces lock: ")+strerror(errno);return false;}
    struct stat info={};
    if(fstat(fd,&info)!=0 || !S_ISREG(info.st_mode) || info.st_uid!=geteuid()
        || info.st_nlink!=1 || fchmod(fd,0600)!=0) {
        journalIOError="Spaces lock file is not a private regular file owned by this user";
        close(fd);return false;
    }
    if(flock(fd,LOCK_EX|LOCK_NB)!=0) {
        journalIOError=errno==EWOULDBLOCK ? "Another Host owns Spaces recovery"
            : std::string("Cannot lock Spaces recovery: ")+strerror(errno);
        close(fd);return false;
    }
    journalLockFD=fd;return true;
}
NSNumber *number(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }
NSArray *array(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
NSDictionary *dictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
NSArray *managed() {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->inventory)return recoveryHooks->inventory;
#endif
    Api &a=api(); if(!a.conn || !a.managed) return nil; return CFBridgingRelease(a.managed(a.conn()));
}
NSString *displayUUID(CGDirectDisplayID id) {
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(id);
    if(!uuid) return nil;
    NSString *result=CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,uuid));
    CFRelease(uuid); return result;
}
struct RemotePhysicalDisplay { CGRect bounds={}; int slot=-1; std::string uuid; };
// Native slots retain macOS's stable built-in Space as slot 0. The chooser is
// intentionally exposed in reverse order below: far external, near external,
// built-in. This keeps recovery tied to native Space identity while presenting
// the three physical desktops from farthest to nearest as Spaces 1 through 3.
bool remotePhysicalDisplays(std::vector<RemotePhysicalDisplay> &result) {
    result.clear();
    CGDirectDisplayID ids[32],builtin=0;uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return false;
    std::vector<CGDirectDisplayID> external;
    for(uint32_t i=0;i<count;i++) {
        if(CGDisplayIsBuiltin(ids[i])) {
            if(builtin)return false;
            builtin=ids[i];
        } else external.push_back(ids[i]);
    }
    if(!builtin || external.size()!=2)return false;
    CGRect built=CGDisplayBounds(builtin);
    auto distance=[&](CGDirectDisplayID id) {
        CGRect frame=CGDisplayBounds(id);
        double dx=CGRectGetMidX(frame)-CGRectGetMidX(built);
        double dy=CGRectGetMidY(frame)-CGRectGetMidY(built);
        return dx*dx+dy*dy;
    };
    std::sort(external.begin(),external.end(),[&](CGDirectDisplayID left,CGDirectDisplayID right) {
        double a=distance(left),b=distance(right);
        if(a!=b)return a<b;
        NSString *l=displayUUID(left),*r=displayUUID(right);
        return [(l ?: @"") compare:(r ?: @"")] == NSOrderedAscending;
    });
    NSString *builtUUID=displayUUID(builtin);
    if(!builtUUID)return false;
    result.push_back({built,0,builtUUID.UTF8String});
    for(int i=0;i<2;i++) {
        NSString *uuid=displayUUID(external[i]);
        if(!uuid)return false;
        result.push_back({CGDisplayBounds(external[i]),i+1,uuid.UTF8String});
    }
    return true;
}
int nativeSlotForDisplayUUID(const std::string &uuid) {
    std::vector<RemotePhysicalDisplay> displays;
    if(!remotePhysicalDisplays(displays))return -1;
    for(const auto &display:displays)if(display.uuid==uuid)return display.slot;
    return -1;
}
int logicalSlotForNativeIndex(int index,bool reversed) {
    return index<0 || index>2 ? 0 : reversed ? 3-index : index+1;
}
int nativeIndexForLogicalSlot(int slot,bool reversed) {
    return slot<1 || slot>3 ? -1 : reversed ? 3-slot : slot-1;
}
NSDictionary *builtInManaged(NSArray *displays) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->inventory) {
        for(NSDictionary *display in displays)
            if([display[@"Display Identifier"] isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])
                return display;
        return nil;
    }
#endif
    NSString *uuid=displayUUID(CGMainDisplayID());
    CGDirectDisplayID ids[32]; uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess) return nil;
    for(uint32_t i=0;i<count;i++) if(CGDisplayIsBuiltin(ids[i])) { uuid=displayUUID(ids[i]); break; }
    for(NSDictionary *d in displays) if([dictionary(d[@"Display Identifier"])[@"value"] isEqual:uuid] || [d[@"Display Identifier"] isEqual:uuid]) return d;
    return nil;
}
std::vector<uint64_t> userSpaces(NSDictionary *display,int cid) {
    std::vector<uint64_t> result;
    for(NSDictionary *item in array(display[@"Spaces"])) {
        uint64_t sid=[number(item[@"id64"]) unsignedLongLongValue];
        if(sid && api().spaceType(cid,sid)==0) result.push_back(sid);
    }
    return result;
}
bool fullSpaceOrder(NSDictionary *display,std::vector<uint64_t> &ids) {
    ids.clear();
    NSArray *spaces=array(display[@"Spaces"]);
    if(!spaces || spaces.count>128)return false;
    for(id item in spaces) {
        NSDictionary *space=dictionary(item);
        uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
        if(!sid || !number(space[@"type"])
            || std::find(ids.begin(),ids.end(),sid)!=ids.end())return false;
        ids.push_back(sid);
    }
    return !ids.empty();
}
bool additionPreservesOrder(const std::vector<uint64_t> &before,
                            const std::vector<uint64_t> &after,uint64_t added) {
    if(!added || after.size()!=before.size()+1)return false;
    auto prior=after;
    auto position=std::find(prior.begin(),prior.end(),added);
    if(position==prior.end())return false;
    prior.erase(position);
    return prior==before;
}
NSString *managedDisplayUUID(NSDictionary *display) {
    id raw=display[@"Display Identifier"];
    if([raw isKindOfClass:NSString.class])return raw;
    id value=dictionary(raw)[@"value"];
    return [value isKindOfClass:NSString.class] ? value : nil;
}
NSDictionary *managedSpace(NSDictionary *display,uint64_t sid) {
    for(NSDictionary *item in array(display[@"Spaces"]))
        if([number(item[@"id64"]) unsignedLongLongValue]==sid)return item;
    return nil;
}
NSString *managedSpaceUUID(NSDictionary *space) {
    id raw=space[@"uuid"];
    if([raw isKindOfClass:NSString.class] && [raw length]>0)return raw;
    // macOS 27 leaves the original built-in "Desktop 1" UUID empty while
    // still exposing a unique, durable managed Space ID.  Preserve the
    // stronger UUID identity whenever it exists and use a namespaced ID only
    // for that legitimate empty-UUID case.  The numeric ID is also the value
    // used by every move, selection, and recovery operation in this journal.
    uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
    return sid ? [NSString stringWithFormat:@"id64:%llu",sid] : nil;
}
bool wholeTopology(NSArray *inventory,const std::vector<std::string> &displayOrder,
                   air::whole_space::Topology &topology) {
    if(!inventory || inventory.count!=displayOrder.size() || displayOrder.size()!=3)return false;
    air::whole_space::Topology parsed;
    for(const std::string &uuid:displayOrder) {
        NSDictionary *found=nil;
        for(NSDictionary *display in inventory) {
            NSString *identity=managedDisplayUUID(display);
            if([identity isEqualToString:[NSString stringWithUTF8String:uuid.c_str()]]) {
                if(found)return false;
                found=display;
            }
        }
        std::vector<uint64_t> order;
        uint64_t current=[number(dictionary(found[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(!found || !current || !fullSpaceOrder(found,order)
            || std::find(order.begin(),order.end(),current)==order.end())return false;
        air::whole_space::Display parsedDisplay;
        parsedDisplay.uuid=uuid;parsedDisplay.order=std::move(order);parsedDisplay.current=current;
        for(NSDictionary *space in array(found[@"Spaces"])) {
            NSString *identity=managedSpaceUUID(space);
            if(!identity)return false;
            parsedDisplay.spaceUUIDs.push_back(identity.UTF8String);
        }
        if(parsedDisplay.spaceUUIDs.size()!=parsedDisplay.order.size())return false;
        parsed.displays.push_back(std::move(parsedDisplay));
    }
    topology=std::move(parsed);return true;
}
bool captureOrdinarySpaceIdentities(NSArray *inventory,int cid,
                                    std::vector<OrdinarySpaceIdentity> &result) {
    std::set<uint64_t> ids;std::set<std::string> uuids;
    for(NSDictionary *display in inventory) {
        NSString *displayUUID=managedDisplayUUID(display);
        if(!displayUUID.length)return false;
        for(NSDictionary *space in array(display[@"Spaces"])) {
            uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
            if(!sid || api().spaceType(cid,sid)!=0)continue;
            NSString *uuid=space[@"uuid"];
            // An empty UUID (notably built-in Desktop 1) retains strict ID recovery.
            if(![uuid isKindOfClass:NSString.class] || !uuid.length)continue;
            if(uuid.length>128 || !ids.insert(sid).second
                || !uuids.insert(uuid.UTF8String).second)return false;
            result.push_back({sid,displayUUID.UTF8String,uuid.UTF8String});
        }
    }
    return true;
}

std::vector<std::string> wholeDisplayOrder() {
    std::vector<std::string> order;
    if(wholeJournal.original.displays.size()!=3)return order;
    for(const auto &display:wholeJournal.original.displays)order.push_back(display.uuid);
    return order;
}
bool assignOwnedSlots(NSDictionary *display,int cid) {
    std::vector<uint64_t> order;
    if(!fullSpaceOrder(display,order) || createdSpaces.size()!=3 || ownedSpaces.size()!=3
        || ![managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])return false;
    uint64_t selected[3]={};size_t indices[3]={};int found=0;
    for(size_t index=0;index<order.size();index++) {
        uint64_t sid=order[index];
        if(std::find(createdSpaces.begin(),createdSpaces.end(),sid)==createdSpaces.end())continue;
        auto owner=std::find_if(ownedSpaces.begin(),ownedSpaces.end(),
            [&](const OwnedSpace &space){return space.id==sid;});
        NSString *uuid=managedSpaceUUID(managedSpace(display,sid));
        if(owner==ownedSpaces.end() || owner->displayUUID!=builtinUUID || !uuid
            || ![uuid isEqualToString:[NSString stringWithUTF8String:owner->uuid.c_str()]]
            || api().spaceType(cid,sid)!=0 || found>=3)return false;
        selected[found]=sid;indices[found]=index;found++;
    }
    if(found!=3 || indices[1]!=indices[0]+1 || indices[2]!=indices[1]+1)return false;
    for(int i=0;i<3;i++)slots[i]=selected[i];
    return true;
}
bool planReusedSlots(const std::vector<uint64_t> &ordinary,uint64_t initial,
                     std::vector<uint64_t> &selected,int &missing) {
    selected.clear();missing=0;
    if(!initial || ordinary.empty() || ordinary.size()>4
        || std::count(ordinary.begin(),ordinary.end(),initial)!=1
        || std::set<uint64_t>(ordinary.begin(),ordinary.end()).size()!=ordinary.size())return false;
    selected.push_back(initial);
    for(uint64_t sid:ordinary)if(sid!=initial && selected.size()<3)selected.push_back(sid);
    missing=3-(int)selected.size();
    return true;
}
bool ownedSlotsStillOrdered(NSDictionary *display,int cid) {
    if(!slots[0] || !slots[1] || !slots[2])return false;
    if(!reusedSlots.empty()) {
        if(reusedSlots.size()!=3 || !createdSpaces.empty() || !ownedSpaces.empty()
            || ![managedDisplayUUID(display) isEqualToString:
                [NSString stringWithUTF8String:builtinUUID.c_str()]])return false;
        std::vector<uint64_t> order;
        if(!fullSpaceOrder(display,order))return false;
        for(int i=0;i<3;i++) {
            const auto &identity=reusedSlots[i];
            if(slots[i]!=identity.id || identity.displayUUID!=builtinUUID
                || std::count(order.begin(),order.end(),identity.id)!=1
                || api().spaceType(cid,identity.id)!=0
                || ![managedSpaceUUID(managedSpace(display,identity.id)) isEqualToString:
                    [NSString stringWithUTF8String:identity.uuid.c_str()]])return false;
            for(int j=0;j<i;j++)if(slots[j]==slots[i] || reusedSlots[j].uuid==identity.uuid)return false;
        }
        return slots[0]==initialSpace;
    }
    uint64_t original[3]={slots[0],slots[1],slots[2]};
    bool valid=assignOwnedSlots(display,cid);
    for(int i=0;i<3;i++)if(slots[i]!=original[i])valid=false;
    for(int i=0;i<3;i++)slots[i]=original[i];
    return valid;
}
enum class OwnedStatus { Absent, Match, Conflict, Unknown };
OwnedStatus ownedStatus(NSArray *all,const OwnedSpace &owned,int cid) {
    if(!all || owned.id==0 || owned.uuid.empty() || owned.displayUUID.empty())return OwnedStatus::Unknown;
    NSDictionary *found=nil;
    NSString *foundDisplay=nil;
    for(NSDictionary *display in all) {
        NSDictionary *candidate=managedSpace(display,owned.id);
        if(!candidate)continue;
        if(found)return OwnedStatus::Conflict;
        found=candidate;foundDisplay=managedDisplayUUID(display);
    }
    if(!found)return OwnedStatus::Absent;
    NSString *uuid=managedSpaceUUID(found);
    if(!uuid || !foundDisplay)return OwnedStatus::Unknown;
    if(![uuid isEqualToString:[NSString stringWithUTF8String:owned.uuid.c_str()]]
        || ![foundDisplay isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
        || api().spaceType(cid,owned.id)!=0)return OwnedStatus::Conflict;
    return OwnedStatus::Match;
}
enum class Membership { Ordinary, Missing, Multiple, NonOrdinary };
const char *membershipBlocker(Membership membership) {
    switch(membership) {
        case Membership::Ordinary:return nullptr;
        case Membership::Multiple:return "A window belongs to multiple Spaces; sticky windows cannot be migrated and restored safely";
        case Membership::NonOrdinary:return "A full-screen or non-desktop window cannot be migrated into an ordinary Remote Space";
        case Membership::Missing:return "A desktop window's Space membership is unavailable; Remote Spaces cannot omit it";
    }
    return "A desktop window's Space membership is unknown";
}
id axAttribute(AXUIElementRef element,CFStringRef name);
struct ProcessBirth {uint64_t seconds=0,microseconds=0;bool valid() const{return seconds>0&&microseconds<1000000;}bool operator==(const ProcessBirth &other) const{return valid()&&other.valid()&&seconds==other.seconds&&microseconds==other.microseconds;}};
struct DeferredInvisibleWindow {
    uint32_t id=0;pid_t pid=0;ProcessBirth birth;uint64_t space=0,tags=0;
    std::string bundle,title,displayUUID;CGRect frame={};
};
std::vector<DeferredInvisibleWindow> deferredInvisibleWindows;
struct RetainedOrdinaryWindow {
    uint32_t id=0;pid_t pid=0;ProcessBirth birth;uint64_t space=0;
    std::string displayUUID,reason;CGRect frame={};
};
std::vector<RetainedOrdinaryWindow> retainedOrdinaryWindows;
ProcessBirth processBirth(pid_t pid){struct proc_bsdinfo info={};int size=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info));return size==(int)sizeof(info)?ProcessBirth{info.pbi_start_tvsec,info.pbi_start_tvusec}:ProcessBirth{};}
double stableLaunchTime(NSRunningApplication *app,pid_t pid){if(app.launchDate)return app.launchDate.timeIntervalSince1970;ProcessBirth birth=processBirth(pid);return birth.valid()?birth.seconds+birth.microseconds/1000000.0:0;}
bool systemChrome(NSString *bundle) {
    return [@[@"com.apple.dock",@"com.apple.WindowServer",@"com.apple.SystemUIServer",
        @"com.apple.controlcenter",@"com.apple.notificationcenterui",@"com.apple.loginwindow",
        @"com.apple.universalcontrol"] containsObject:bundle];
}
struct DormantAXInventory { bool readable=false,complete=false;ProcessBirth birth;std::set<uint32_t> windows; };
using DormantAXCache=std::map<pid_t,DormantAXInventory>;
int dormantAXRoleKind(id role) {
    if(![role isKindOfClass:NSString.class])return -1;
    if([role isEqual:(__bridge NSString *)kAXWindowRole])return 1;
    return [role isEqual:(__bridge NSString *)kAXScrollAreaRole] ? 0 : -1;
}
void recordDormantAXElement(DormantAXInventory &inventory,id role,AXError status,CGWindowID candidate) {
    if(![role isKindOfClass:NSString.class]){inventory.complete=false;return;}
    if(status==kAXErrorSuccess && candidate){inventory.windows.insert(candidate);return;}
    if(dormantAXRoleKind(role)!=0)inventory.complete=false;
}
bool dormantExclusionDecision(bool initiallyOffscreen,bool readable,bool complete,bool matched,bool liveSameOwner,
                              bool liveOffscreen,bool exactProcessIdentity,bool membershipReadable,bool membershipEmpty) {
    return initiallyOffscreen&&readable&&complete&&!matched&&liveSameOwner&&liveOffscreen&&exactProcessIdentity
        &&membershipReadable&&membershipEmpty;
}
DormantAXInventory readDormantAXInventory(pid_t pid) {
    DormantAXInventory result;result.birth=processBirth(pid);
    if(!result.birth.valid())return result;
    AXUIElementRef application=AXUIElementCreateApplication(pid);
    if(!application)return result;
    AXUIElementSetMessagingTimeout(application,0.5);CFTypeRef raw=nullptr;
    AXError status=AXUIElementCopyAttributeValue(application,kAXWindowsAttribute,&raw);CFRelease(application);
    if(status!=kAXErrorSuccess||!raw||CFGetTypeID(raw)!=CFArrayGetTypeID()){if(raw)CFRelease(raw);return result;}
    result.readable=true;result.complete=true;
    for(id item in (__bridge NSArray *)raw){if(CFGetTypeID((__bridge CFTypeRef)item)!=AXUIElementGetTypeID()){result.complete=false;continue;}AXUIElementRef element=(__bridge AXUIElementRef)item;
        id role=axAttribute(element,kAXRoleAttribute);
        CGWindowID candidate=0;
        AXError status=api().axWindow?api().axWindow(element,&candidate):kAXErrorFailure;
        recordDormantAXElement(result,role,status,candidate);
    }
    if(!(result.birth==processBirth(pid)))result.complete=false;
    CFRelease(raw);return result;
}
// CursorUIViewService creates small compositor surfaces on every Space.  It is
// an Apple input overlay, not an application window that can be moved or whose
// frame should be restored.  Require the sealed system executable as well as
// the exact CG/AX shape; a bundle name alone is insufficient to omit a window.
bool cursorUIOverlayMetadata(NSString *bundle,NSString *owner,NSString *title,
                             int layer,double alpha,CGRect frame,bool processIsAppleCursorService,
                             bool stableProcess,bool completeAX,bool hasAXWindows) {
    return [bundle isEqual:@"com.apple.TextInputUI.xpc.CursorUIViewService"]
        && [owner isEqual:@"CursorUIViewService"]
        && (!title || ([title isKindOfClass:NSString.class] && title.length==0))
        && layer==0 && alpha==1 && CGRectGetWidth(frame)==64 && CGRectGetHeight(frame)==64
        && std::isfinite(frame.origin.x) && std::isfinite(frame.origin.y)
        && processIsAppleCursorService && stableProcess && completeAX && !hasAXWindows;
}
bool appleCursorServiceExecutable(pid_t pid) {
    if(pid<=0)return false;
    char observed[PROC_PIDPATHINFO_MAXSIZE]={};
    if(proc_pidpath(pid,observed,sizeof(observed))<=0)return false;
    static const char *expected="/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService";
    char actualPath[PATH_MAX]={},expectedPath[PATH_MAX]={};
    return realpath(observed,actualPath) && realpath(expected,expectedPath)
        && strcmp(actualPath,expectedPath)==0;
}
bool verifiedCursorUIOverlay(NSDictionary *info,uint32_t wid,pid_t pid,
                             DormantAXCache &cache) {
    if(!info || !wid || pid<=0
        || [number(info[(id)kCGWindowNumber]) unsignedIntValue]!=wid
        || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid)return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated
        || ![app.bundleIdentifier isEqual:@"com.apple.TextInputUI.xpc.CursorUIViewService"])
        return false;
    ProcessBirth birth=processBirth(pid);if(!birth.valid())return false;
    CGRect frame={};
    if(!CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame))return false;
    NSNumber *layer=number(info[(id)kCGWindowLayer]);
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    if(!layer || !alpha)return false;
    auto found=cache.find(pid);
    if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    return cursorUIOverlayMetadata(app.bundleIdentifier,
        info[(id)kCGWindowOwnerName],info[(id)kCGWindowName],layer.intValue,
        alpha.doubleValue,frame,appleCursorServiceExecutable(pid),
        birth==processBirth(pid) && found->second.birth==birth,
        found->second.readable && found->second.complete,
        !found->second.windows.empty());
}
bool dormantInventoryOnlyWindow(NSDictionary *info,uint32_t wid,pid_t pid,NSString *bundle,ProcessBirth sourceBirth,int cid,DormantAXCache &cache) {
    NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);if(onscreen&&onscreen.boolValue)return false;
    auto found=cache.find(pid);if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    if(!(found->second.birth==sourceBirth))return false;
    if(!found->second.readable||!found->second.complete||found->second.windows.count(wid))return false;
    NSRunningApplication *liveApp=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    bool exactIdentity=liveApp&&!liveApp.terminated&&bundle&&[liveApp.bundleIdentifier isEqual:bundle]
        &&sourceBirth==processBirth(pid);
    NSArray *live=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));bool liveSameOwner=false,liveOffscreen=true;
    for(NSDictionary *candidate in live)if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid){liveSameOwner=[number(candidate[(id)kCGWindowOwnerPID]) intValue]==pid;break;}
    NSArray *visible=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    if(!live || !visible)return false;
    for(NSDictionary *candidate in visible)if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid){liveOffscreen=false;break;}
    NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    return dormantExclusionDecision(!onscreen||!onscreen.boolValue,found->second.readable,found->second.complete,
        found->second.windows.count(wid),liveSameOwner,liveOffscreen,exactIdentity,members!=nil,members&&members.count==0);
}
AXUIElementRef findAXWindow(pid_t pid,uint32_t wid);
bool readAXFrame(AXUIElementRef window,CGRect *frame);
bool windowOnDisplay(uint32_t wid,int cid,const std::string &uuid);
bool spaceOnDisplay(NSArray *all,uint64_t sid,const std::string &uuid);
NSDictionary *windowLayerDescription(uint32_t wid);
bool nearFrame(CGRect a,CGRect b);
bool exactSingletonMembership(int cid,uint32_t wid,uint64_t sid);
bool readCGFrame(uint32_t wid,pid_t pid,CGRect *frame);
bool exactInvisibleOnePixelMetadata(CGRect cgFrame,NSNumber *cgAlpha,id role,id subrole,id minimized,
                                      bool axFrameReadable,CGRect axFrame) {
    return std::isfinite(cgFrame.origin.x)&&std::isfinite(cgFrame.origin.y)
        &&std::isfinite(cgFrame.size.width)&&std::isfinite(cgFrame.size.height)
        &&cgFrame.size.width>0&&cgFrame.size.height>0&&cgFrame.size.width<=1&&cgFrame.size.height<=1
        &&cgAlpha&&std::isfinite(cgAlpha.doubleValue)&&cgAlpha.doubleValue==0
        &&[role isEqual:(__bridge NSString *)kAXWindowRole]&&[subrole isEqual:@"AXUnknown"]
        &&minimized&&CFGetTypeID((__bridge CFTypeRef)minimized)==CFBooleanGetTypeID()
        &&!CFBooleanGetValue((__bridge CFBooleanRef)minimized)&&axFrameReadable
        &&CGRectEqualToRect(axFrame,cgFrame);
}
bool auxiliaryTinyWindow(NSDictionary *info,uint32_t wid,pid_t pid,NSString *bundle,ProcessBirth sourceBirth,
                         CGRect sourceFrame,uint64_t sourceSpace,int cid,DormantAXCache &cache) {
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    if(!sourceBirth.valid())return false;
    auto found=cache.find(pid);if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    bool identity=found->second.birth==sourceBirth;NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    identity=identity&&app&&!app.terminated&&bundle&&[app.bundleIdentifier isEqual:bundle]&&sourceBirth==processBirth(pid);
    NSArray *live=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    bool sameOwner=false,layerZero=false,zeroAlpha=false,stableFrame=false;
    if(live)for(NSDictionary *candidate in live)if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
        sameOwner=[number(candidate[(id)kCGWindowOwnerPID]) intValue]==pid;
        NSNumber *layer=number(candidate[(id)kCGWindowLayer]),*currentAlpha=number(candidate[(id)kCGWindowAlpha]);
        layerZero=layer&&layer.intValue==0;zeroAlpha=currentAlpha&&currentAlpha.doubleValue==0;CGRect current={};
        stableFrame=CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
            &&CGRectEqualToRect(current,sourceFrame);break;
    }
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    bool exactMembership=membership&&membership.count==1&&[number(membership[0]) unsignedLongLongValue]==sourceSpace;
    // Display utilities also own transparent one-pixel helper surfaces with
    // no AX window. A complete AX inventory plus two matching CG observations
    // identifies these without treating an inaccessible user window as absent.
    if(sourceFrame.size.width>0 && sourceFrame.size.width<=1
        && sourceFrame.size.height>0 && sourceFrame.size.height<=1
        && found->second.readable && found->second.complete
        && !found->second.windows.count(wid) && identity && sameOwner
        && layerZero && zeroAlpha && stableFrame && exactMembership)return true;
    AXUIElementRef ax=findAXWindow(pid,wid);bool metadata=false;
    if(ax){id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute),mini=axAttribute(ax,kAXMinimizedAttribute);
        CGRect frame={};bool frameReadable=readAXFrame(ax,&frame);
        metadata=exactInvisibleOnePixelMetadata(sourceFrame,alpha,role,subrole,mini,frameReadable,frame);CFRelease(ax);}
    return metadata&&found->second.readable&&found->second.complete&&found->second.windows.count(wid)
        &&identity&&sameOwner&&layerZero&&zeroAlpha&&stableFrame&&exactMembership;
}
// A selected full-screen Space can contain private compositor surfaces in
// addition to its one real AXStandardWindow.  They must not be journaled as
// user windows, but an inaccessible ordinary window must never be dismissed
// as one of these surfaces.  Keep the final classification small and directly
// testable; the caller supplies independently revalidated evidence.
bool fullScreenCompanionDecision(bool exactProcessIdentity,bool exactSpace,
                                 bool exactDisplay,bool stableCGIdentity,
                                 bool ownerIsUniqueStandardWindow,
                                 bool exactNonStandardAXSurface,
                                 bool completeAXInventory,bool ownerInAXInventory,
                                 bool candidateAbsentFromAXInventory,
                                 bool blankTitle,bool containedInOwnerFrame) {
    if(!exactProcessIdentity || !exactSpace || !exactDisplay || !stableCGIdentity
        || !ownerIsUniqueStandardWindow || !blankTitle || !containedInOwnerFrame)return false;
    if(exactNonStandardAXSurface)return true;
    return completeAXInventory && ownerInAXInventory && candidateAbsentFromAXInventory;
}
bool browserFullScreenStripDecision(bool knownBrowser,bool exactProcessIdentity,bool exactSpace,
                                    bool stableCGIdentity,bool ownerIsUniqueStandardWindow,
                                    bool completeAXInventory,bool ownerInAXInventory,
                                    bool exactNonStandardAXSurface,
                                    bool candidateAbsentFromAXInventory,bool blankTitle,
                                    CGRect ownerFrame,CGRect candidateFrame) {
    if(!knownBrowser || !exactProcessIdentity || !exactSpace || !stableCGIdentity
        || !ownerIsUniqueStandardWindow || !completeAXInventory || !ownerInAXInventory
        || (!candidateAbsentFromAXInventory && !exactNonStandardAXSurface) || !blankTitle
        || !std::isfinite(ownerFrame.origin.x) || !std::isfinite(ownerFrame.origin.y)
        || !std::isfinite(ownerFrame.size.width) || !std::isfinite(ownerFrame.size.height)
        || !std::isfinite(candidateFrame.origin.x) || !std::isfinite(candidateFrame.origin.y)
        || !std::isfinite(candidateFrame.size.width) || !std::isfinite(candidateFrame.size.height)
        || ownerFrame.size.width<100 || ownerFrame.size.height<100
        || candidateFrame.size.width<ownerFrame.size.width*0.75
        || candidateFrame.size.width>ownerFrame.size.width+2
        || candidateFrame.size.height<=0
        || candidateFrame.size.height>std::min(128.0,ownerFrame.size.height*0.15))return false;
    bool alignedLeft=fabs(candidateFrame.origin.x-ownerFrame.origin.x)<=2;
    bool adjacentRight=fabs(candidateFrame.origin.x-CGRectGetMaxX(ownerFrame))<=2;
    return (alignedLeft || adjacentRight)
        && candidateFrame.origin.y>=ownerFrame.origin.y-128
        && CGRectGetMaxY(candidateFrame)<=ownerFrame.origin.y+128;
}
// Chrome can place a toolbar child beyond an intervening display while its
// parent strip stays above the full-screen owner.
bool browserFullScreenDetachedStripGeometry(CGRect owner,CGRect parent,CGRect child) {
    for(CGRect frame:{owner,parent,child})
        if(!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y)
            || !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height))return false;
    return owner.size.width>=100 && owner.size.height>=100
        && fabs(parent.origin.x-owner.origin.x)<=2
        && fabs(parent.size.width-owner.size.width)<=2
        && parent.size.height>0 && parent.size.height<=128
        && parent.origin.y>=owner.origin.y-128
        && CGRectGetMaxY(parent)<=owner.origin.y+2
        && fabs(child.origin.x-(CGRectGetMaxX(owner)+owner.size.width))<=2
        && fabs(child.size.width-parent.size.width)<=2
        && child.size.height>0 && child.size.height<=parent.size.height
        && child.origin.y>=parent.origin.y-2
        && CGRectGetMaxY(child)<=owner.origin.y+2;
}
bool backgroundChromeFourSurfaceGeometry(CGRect display,CGRect owner,CGRect root,
                                         CGRect middle,CGRect leaf) {
    for(CGRect frame:{display,owner,root,middle,leaf})
        if(!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y)
            || !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height))return false;
    return display.size.width>=100 && display.size.height>=100
        && CGRectEqualToRect(owner,display)
        && fabs(root.origin.x-owner.origin.x)<=2
        && root.origin.y>=owner.origin.y-2
        && root.origin.y<=owner.origin.y+32
        && fabs(root.size.width-owner.size.width)<=2
        && root.size.height>0 && root.size.height<=128
        && fabs(middle.origin.x-root.origin.x)<=2
        && fabs(middle.size.width-root.size.width)<=2
        && middle.size.height>0 && middle.size.height<=root.size.height
        && middle.origin.y>=root.origin.y-64
        && CGRectGetMaxY(middle)<=CGRectGetMaxY(root)
        && fabs(leaf.origin.x-root.origin.x)<=2
        && fabs(leaf.size.width-root.size.width)<=2
        && leaf.size.height>0 && leaf.size.height<=middle.size.height
        && leaf.origin.y>=root.origin.y-64
        && CGRectGetMaxY(leaf)<=CGRectGetMaxY(root);
}
struct SelectedFullScreenOwner {
    uint32_t id=0;pid_t pid=0;NSString *bundle=nil;ProcessBirth birth;CGRect frame={};
};
// A pre-journal sample is accepted only after the same complete, validated
// selected-full-screen inventory is observed twice in a row.  Invalid samples
// deliberately break the streak: a transition may settle and retry, but it can
// never be journaled from one lucky read.
struct SelectedFullScreenQuiescence {
    bool havePrior=false;
    std::string prior;
    bool observe(bool valid,const std::string &signature) {
        if(!valid) { havePrior=false;prior.clear();return false; }
        if(havePrior && prior==signature)return true;
        havePrior=true;prior=signature;return false;
    }
};
std::string selectedFullScreenDiagnostic(uint32_t wid,pid_t pid,const char *predicate) {
    char detail[256];
    snprintf(detail,sizeof(detail),
        "Selected full-screen inventory rejected [window=%u pid=%d predicate=%s]",
        wid,pid,predicate ? predicate : "unknown");
    return detail;
}
bool stableCGSurface(NSDictionary *original,uint32_t wid,pid_t pid,CGRect frame) {
    NSArray *live=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));
    if(!live)return false;
    for(NSDictionary *candidate in live)if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
        CGRect current={};
        return [number(candidate[(id)kCGWindowOwnerPID]) intValue]==pid
            && [number(candidate[(id)kCGWindowLayer]) intValue]==0
            && CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
            && CGRectEqualToRect(current,frame)
            && [number(candidate[(id)kCGWindowAlpha]) isEqual:number(original[(id)kCGWindowAlpha])];
    }
    return false;
}
// Some offscreen Chrome child surfaces are present in the complete CG list but
// never returned by the IncludingWindow query.  Validate the same exact child
// twice in the complete list instead of weakening stableCGSurface for windows.
bool stableAllCGSurface(NSDictionary *original,uint32_t wid,pid_t pid,CGRect frame) {
    NSNumber *originalAlpha=number(original[(id)kCGWindowAlpha]);
    if(!originalAlpha || originalAlpha.doubleValue!=1)return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        NSUInteger matches=0;
        for(NSDictionary *candidate in all)
            if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                matches++;CGRect current={};NSNumber *alpha=number(candidate[(id)kCGWindowAlpha]);
                NSString *title=candidate[(id)kCGWindowName];
                if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || [number(candidate[(id)kCGWindowLayer]) intValue]!=0
                    || !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
                    || !CGRectEqualToRect(current,frame) || !alpha || alpha.doubleValue!=1
                    || ([title isKindOfClass:NSString.class] && title.length))return false;
            }
        if(matches!=1)return false;
        if(sample==0)usleep(25000);
    }
    return true;
}
bool stableTitledCGSurface(NSDictionary *original,uint32_t wid,pid_t pid,CGRect frame) {
    NSString *title=original[(id)kCGWindowName];
    NSNumber *alpha=number(original[(id)kCGWindowAlpha]);
    ProcessBirth birth=processBirth(pid);
    if(![title isKindOfClass:NSString.class] || !title.length
        || !alpha || alpha.doubleValue!=1 || !birth.valid())return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        unsigned matches=0;
        for(NSDictionary *candidate in all)
            if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                matches++;CGRect current={};
                if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || [number(candidate[(id)kCGWindowLayer]) intValue]!=0
                    || [number(candidate[(id)kCGWindowAlpha]) doubleValue]!=1
                    || ![candidate[(id)kCGWindowName] isEqualToString:title]
                    || !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
                    || !CGRectEqualToRect(current,frame))return false;
            }
        if(matches!=1 || !(birth==processBirth(pid)))return false;
        if(sample==0)usleep(25000);
    }
    return true;
}
bool premiereDialogWindowTags(uint64_t tags) {
    return tags==0x300000100082401ULL || tags==0x300000100482001ULL;
}
struct ReadOnlyChromeEvidence {
    bool chrome=false,stableProcess=false,completeAX=false,absentAX=false;
    bool blankTitle=false,alphaOne=false,offscreen=false,stableAll=false;
    bool exactDisplay=false,rootParent=false,exactTags=false,singleOrdinaryMembership=false;
    bool selectedOrdinaryAnchor=false;
};
bool readOnlyChromeDecision(const ReadOnlyChromeEvidence &e) {
    return e.chrome && e.stableProcess && e.completeAX && e.absentAX
        && e.blankTitle && e.alphaOne && e.offscreen && e.stableAll
        && e.exactDisplay && e.rootParent && e.exactTags && e.singleOrdinaryMembership
        && e.selectedOrdinaryAnchor;
}
struct OrdinaryChromeStripEvidence {
    bool chrome=false,process=false,space=false,display=false,stableAll=false;
    bool completeAX=false,candidateAbsentAX=false,blankTitle=false,alphaOne=false;
    bool standardRootCohort=false,offscreen=false,surfaceTags=false;
};
enum class OrdinaryChromeGeometry { None=0,Contained=1,Edge=2 };
OrdinaryChromeGeometry ordinaryChromeStripKind(CGRect display,CGRect root,CGRect candidate,
                                                bool offscreen=false) {
    for(CGRect rect:{display,root,candidate})
        if(!std::isfinite(rect.origin.x) || !std::isfinite(rect.origin.y)
            || !std::isfinite(rect.size.width) || !std::isfinite(rect.size.height))
            return OrdinaryChromeGeometry::None;
    if(root.size.width<100 || root.size.height<200 || candidate.size.height<=0
        || candidate.size.width<root.size.width*0.70
        || candidate.size.width>root.size.width+2
        || !CGRectContainsRect(CGRectInset(display,-2,-2),root))
        return OrdinaryChromeGeometry::None;
    bool contained=offscreen
        && candidate.size.height<=root.size.height*0.75
        && CGRectContainsRect(CGRectInset(display,-2,-2),candidate)
        && CGRectContainsRect(CGRectInset(root,-2,-2),candidate)
        && candidate.origin.y>=root.origin.y-2
        && candidate.origin.y<=root.origin.y+160;
    if(contained)return OrdinaryChromeGeometry::Contained;
    bool alignedLeft=fabs(candidate.origin.x-root.origin.x)<=2;
    bool adjacentRight=fabs(candidate.origin.x-CGRectGetMaxX(root))<=2;
    bool whollyAbove=offscreen && CGRectGetMaxY(candidate)<=CGRectGetMinY(display)+2;
    bool oneDisplayPastRight=fabs(candidate.origin.x
        -(CGRectGetMaxX(display)+display.size.width))<=2;
    bool edge=candidate.size.height<=128
        && (alignedLeft || adjacentRight || (whollyAbove && oneDisplayPastRight))
        && candidate.origin.y>=root.origin.y-128
        && CGRectGetMaxY(candidate)<=root.origin.y+128;
    return edge ? OrdinaryChromeGeometry::Edge : OrdinaryChromeGeometry::None;
}
bool ordinaryChromeStripGeometry(CGRect display,CGRect root,CGRect candidate,bool offscreen=false) {
    return ordinaryChromeStripKind(display,root,candidate,offscreen)
        !=OrdinaryChromeGeometry::None;
}
bool ordinaryChromeSurfaceTagDecision(uint64_t tags,OrdinaryChromeGeometry kind) {
    return (kind==OrdinaryChromeGeometry::Contained && tags==0x1400c0402ULL)
        || (kind==OrdinaryChromeGeometry::Edge && tags==0x1400c0202ULL);
}
bool ordinaryChromeTransparentBottomEdge(CGRect display,CGRect root,CGRect child) {
    return root.size.width>=100 && root.size.height>=200
        && child.size.width>0 && child.size.width<=root.size.width*0.25
        && child.size.height>0 && child.size.height<=32
        && CGRectContainsRect(CGRectInset(display,-2,-2),root)
        && CGRectContainsRect(CGRectInset(display,-2,-2),child)
        && fabs(child.origin.x-root.origin.x)<=2
        && fabs(CGRectGetMaxY(child)-CGRectGetMaxY(root))<=2;
}
bool ordinaryChromeStripDecision(const OrdinaryChromeStripEvidence &e,
                                 CGRect display,CGRect root,CGRect candidate) {
    if(!e.chrome || !e.process || !e.space || !e.display || !e.stableAll
        || !e.completeAX || !e.candidateAbsentAX || !e.blankTitle || !e.alphaOne
        || !e.standardRootCohort || !e.surfaceTags)return false;
    return ordinaryChromeStripGeometry(display,root,candidate,e.offscreen);
}
struct OrdinaryOwnedChildEvidence {
    bool finder=false,process=false,space=false,display=false,stableCG=false;
    bool completeAX=false,candidateAbsentAX=false,exactParent=false,parentRoot=false,parentInAX=false;
    bool parentStandard=false,blankTitle=false,alphaOne=false,onscreen=false,contained=false;
};
bool ordinaryOwnedChildDecision(const OrdinaryOwnedChildEvidence &e) {
    return e.finder && e.process && e.space && e.display && e.stableCG
        && e.completeAX && e.candidateAbsentAX && e.exactParent && e.parentRoot && e.parentInAX
        && e.parentStandard && e.blankTitle && e.alphaOne && e.onscreen && e.contained;
}
bool ordinaryChromeCrossDisplayPairGeometry(CGRect source,CGRect external,CGRect root,
                                            CGRect aligned,CGRect displaced) {
    for(CGRect frame:{source,external,root,aligned,displaced})
        if(!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y)
            || !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height))return false;
    return external.size.width>=500 && external.size.height>=400
        && fabs(root.origin.x-external.origin.x)<=2
        && root.origin.y>=external.origin.y && root.origin.y<=external.origin.y+40
        && fabs(root.size.width-external.size.width)<=2
        && fabs(CGRectGetMaxY(root)-CGRectGetMaxY(external))<=2
        && fabs(aligned.origin.x-external.origin.x)<=2
        && fabs(displaced.origin.x-(CGRectGetMaxX(external)+external.size.width))<=2
        && fabs(aligned.size.width-external.size.width)<=2
        && fabs(displaced.size.width-external.size.width)<=2
        && aligned.size.height>0 && aligned.size.height<=128
        && displaced.size.height>0 && displaced.size.height<=aligned.size.height
        && fabs(CGRectGetMaxY(aligned)-external.origin.y)<=2
        && fabs(CGRectGetMaxY(displaced)-external.origin.y)<=2
        && !CGRectIntersectsRect(aligned,source)
        && !CGRectIntersectsRect(displaced,source);
}
bool ordinaryChromePairAbsentFromOnscreenInventory(NSArray *visible,uint32_t alignedID,
                                                   uint32_t displacedID) {
    if(!visible || !visible.count || !alignedID || !displacedID || alignedID==displacedID)return false;
    for(id row in visible) {
        NSDictionary *info=dictionary(row);
        NSNumber *idNumber=info ? number(info[(id)kCGWindowNumber]) : nil;
        if(!idNumber || idNumber.unsignedIntValue==alignedID
            || idNumber.unsignedIntValue==displacedID)return false;
    }
    return true;
}
uint32_t exactWindowParent(int cid,uint32_t wid,bool *known=nullptr) {
    using WindowQuery=CFTypeRef (*)(int,CFArrayRef,int);
    using QueryWindows=CFTypeRef (*)(CFTypeRef);
    using IteratorCount=int (*)(CFTypeRef);
    using IteratorAdvance=bool (*)(CFTypeRef);
    using IteratorParent=uint32_t (*)(CFTypeRef);
    if(known)*known=false;
    if(!api().sky)return 0;
    static WindowQuery query=(WindowQuery)dlsym(api().sky,"SLSWindowQueryWindows");
    static QueryWindows windows=(QueryWindows)dlsym(api().sky,"SLSWindowQueryResultCopyWindows");
    static IteratorCount count=(IteratorCount)dlsym(api().sky,"SLSWindowIteratorGetCount");
    static IteratorAdvance advance=(IteratorAdvance)dlsym(api().sky,"SLSWindowIteratorAdvance");
    static IteratorParent parent=(IteratorParent)dlsym(api().sky,"SLSWindowIteratorGetParentID");
    if(!cid || !wid || !query || !windows || !count || !advance || !parent)return 0;
    CFTypeRef result=query(cid,(__bridge CFArrayRef)@[@(wid)],1);if(!result)return 0;
    CFTypeRef iterator=windows(result);CFRelease(result);if(!iterator)return 0;
    bool valid=count(iterator)==1 && advance(iterator);
    uint32_t value=valid ? parent(iterator) : 0;
    if(known)*known=valid;
    CFRelease(iterator);return value;
}
bool exactWindowTags(int cid,uint32_t wid,uint64_t *value) {
    using WindowQuery=CFTypeRef (*)(int,CFArrayRef,int);
    using QueryWindows=CFTypeRef (*)(CFTypeRef);
    using IteratorCount=int (*)(CFTypeRef);
    using IteratorAdvance=bool (*)(CFTypeRef);
    using IteratorTags=uint64_t (*)(CFTypeRef);
    if(value)*value=0;if(!api().sky || !value)return false;
    static WindowQuery query=(WindowQuery)dlsym(api().sky,"SLSWindowQueryWindows");
    static QueryWindows windows=(QueryWindows)dlsym(api().sky,"SLSWindowQueryResultCopyWindows");
    static IteratorCount count=(IteratorCount)dlsym(api().sky,"SLSWindowIteratorGetCount");
    static IteratorAdvance advance=(IteratorAdvance)dlsym(api().sky,"SLSWindowIteratorAdvance");
    static IteratorTags tags=(IteratorTags)dlsym(api().sky,"SLSWindowIteratorGetTags");
    if(!cid || !wid || !query || !windows || !count || !advance || !tags)return false;
    CFTypeRef result=query(cid,(__bridge CFArrayRef)@[@(wid)],1);if(!result)return false;
    CFTypeRef iterator=windows(result);CFRelease(result);if(!iterator)return false;
    bool okay=count(iterator)==1 && advance(iterator);if(okay)*value=tags(iterator);
    CFRelease(iterator);return okay;
}
bool signedCUAServiceExecutable(pid_t pid) {
    if(pid<=0)return false;
    char observed[PROC_PIDPATHINFO_MAXSIZE]={};
    if(proc_pidpath(pid,observed,sizeof(observed))<=0)return false;
    NSString *service=[NSHomeDirectory() stringByAppendingPathComponent:
        @".codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"];
    const char *expected=service.fileSystemRepresentation;
    char actualPath[PATH_MAX]={},expectedPath[PATH_MAX]={};
    if(!realpath(observed,actualPath) || !realpath(expected,expectedPath)
        || strcmp(actualPath,expectedPath)!=0)return false;
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)actualPath,strlen(actualPath),false);
    if(!url)return false;
    SecStaticCodeRef code=nullptr;SecRequirementRef requirement=nullptr;
    OSStatus created=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code);
    CFRelease(url);
    OSStatus required=SecRequirementCreateWithString(CFSTR(
        "anchor apple generic and identifier \"com.openai.sky.CUAService\" and "
        "certificate leaf[subject.OU] = \"2DC432GLL2\" and "
        "certificate leaf[subject.CN] = \"Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)\""),
        kSecCSDefaultFlags,&requirement);
    bool signedOkay=created==errSecSuccess && required==errSecSuccess
        && SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement)==errSecSuccess;
    if(requirement)CFRelease(requirement);
    if(code)CFRelease(code);
    return signedOkay;
}
bool signedSystemFinderExecutable(pid_t pid) {
    if(pid<=0)return false;
    char observed[PROC_PIDPATHINFO_MAXSIZE]={};
    if(proc_pidpath(pid,observed,sizeof(observed))<=0)return false;
    static const char *expected="/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder";
    char actualPath[PATH_MAX]={},expectedPath[PATH_MAX]={};
    if(!realpath(observed,actualPath) || !realpath(expected,expectedPath)
        || strcmp(actualPath,expectedPath)!=0)return false;
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)actualPath,strlen(actualPath),false);
    if(!url)return false;
    SecStaticCodeRef code=nullptr;SecRequirementRef requirement=nullptr;
    OSStatus created=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code);
    CFRelease(url);
    OSStatus required=SecRequirementCreateWithString(
        CFSTR("anchor apple and identifier \"com.apple.finder\""),
        kSecCSDefaultFlags,&requirement);
    bool signedOkay=created==errSecSuccess && required==errSecSuccess
        && SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement)==errSecSuccess;
    if(requirement)CFRelease(requirement);
    if(code)CFRelease(code);
    return signedOkay;
}
struct TextKitAgentSurfaceEvidence {
    bool exactBundle=false,exactOwner=false,blankTitle=false,layerZero=false;
    bool alphaOne=false,onscreenKeyAbsent=false,zeroFrame=false,exactTags=false;
    bool parentRoot=false,zeroMembership=false,noAXWindow=false;
    bool stableCG=false,stableProcess=false,signedSystemProcess=false;
};
bool textKitAgentSurfaceDecision(const TextKitAgentSurfaceEvidence &e) {
    return e.exactBundle && e.exactOwner && e.blankTitle && e.layerZero
        && e.alphaOne && e.onscreenKeyAbsent && e.zeroFrame && e.exactTags
        && e.parentRoot && e.zeroMembership && e.noAXWindow
        && e.stableCG && e.stableProcess && e.signedSystemProcess;
}
bool signedSystemTextKitAgentExecutable(pid_t pid) {
    if(pid<=0)return false;
    char observed[PROC_PIDPATHINFO_MAXSIZE]={};
    if(proc_pidpath(pid,observed,sizeof(observed))<=0)return false;
    static const char *expected=
        "/System/Library/PrivateFrameworks/UIFoundation.framework/Versions/A/XPCServices/"
        "nsattributedstringagent.xpc/Contents/MacOS/nsattributedstringagent";
    char actualPath[PATH_MAX]={},expectedPath[PATH_MAX]={};
    if(!realpath(observed,actualPath) || !realpath(expected,expectedPath)
        || strcmp(actualPath,expectedPath)!=0)return false;
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)actualPath,strlen(actualPath),false);
    if(!url)return false;
    SecStaticCodeRef code=nullptr;SecRequirementRef requirement=nullptr;
    OSStatus created=SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code);
    CFRelease(url);
    OSStatus required=SecRequirementCreateWithString(CFSTR(
        "anchor apple and identifier \"com.apple.textkit.nsattributedstringagent\""),
        kSecCSDefaultFlags,&requirement);
    bool signedOkay=created==errSecSuccess && required==errSecSuccess
        && SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement)==errSecSuccess;
    if(requirement)CFRelease(requirement);
    if(code)CFRelease(code);
    return signedOkay;
}
// UIFoundation's sealed attributed-string helper exposes a stable, root-level
// zero-size compositor sentinel with no AX endpoint and no Space membership.
// It cannot be moved or restored. Omit only this exact signed system surface.
bool verifiedTextKitAgentSurface(NSDictionary *info,uint32_t wid,pid_t pid,int cid) {
    if(!info || !wid || pid<=0 || !cid || !api().windowSpaces
        || [number(info[(id)kCGWindowNumber]) unsignedIntValue]!=wid
        || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid)return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    ProcessBirth birth=processBirth(pid);CGRect frame={};uint64_t tags=0;bool parentKnown=false;
    NSString *title=info[(id)kCGWindowName];NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    TextKitAgentSurfaceEvidence e;
    e.exactBundle=app && !app.terminated
        && [app.bundleIdentifier isEqual:@"com.apple.textkit.nsattributedstringagent"];
    e.exactOwner=[info[(id)kCGWindowOwnerName] isEqual:@"nsattributedstringagent"];
    e.blankTitle=[title isKindOfClass:NSString.class] && title.length==0;
    e.layerZero=[number(info[(id)kCGWindowLayer]) intValue]==0;
    e.alphaOne=alpha && alpha.doubleValue==1;
    e.onscreenKeyAbsent=info[(id)kCGWindowIsOnscreen]==nil;
    e.zeroFrame=CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)
        && CGRectEqualToRect(frame,CGRectZero);
    e.exactTags=exactWindowTags(cid,wid,&tags) && tags==0x200100000000ULL;
    e.parentRoot=parentKnown && parent==0;
    if(!(e.exactBundle && e.exactOwner && e.blankTitle && e.layerZero
        && e.alphaOne && e.onscreenKeyAbsent && e.zeroFrame && e.exactTags
        && e.parentRoot && birth.valid()))return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        if(!members || members.count)return false;
        if(sample==0)usleep(25000);
    }
    e.zeroMembership=true;
    AXUIElementRef ax=findAXWindow(pid,wid);
    e.noAXWindow=ax==nullptr;if(ax)CFRelease(ax);
    e.stableCG=stableAllCGSurface(info,wid,pid,frame);
    e.stableProcess=birth==processBirth(pid);
    e.signedSystemProcess=signedSystemTextKitAgentExecutable(pid);
    return textKitAgentSurfaceDecision(e);
}
struct CUAOverlayEvidence {
    bool signedProcess=false,stableBirth=false,exactCG=false,completeAX=false;
    bool parentRoot=false,ordinarySpace=false,exactDisplay=false;
    bool positionSettable=false,sizeUnsettable=false;
};
bool cuaOverlayDecision(const CUAOverlayEvidence &e,CGRect frame,CGRect axFrame,
                        NSString *title,id role,id subrole,uint64_t tags) {
    return e.signedProcess && e.stableBirth && e.exactCG && e.completeAX
        && e.parentRoot && e.ordinarySpace && e.exactDisplay
        && e.positionSettable && e.sizeUnsettable
        && [title isEqual:@"Software Cursor"]
        && [role isEqual:(__bridge NSString *)kAXWindowRole]
        && [subrole isEqual:@"AXUnknown"]
        && (tags==0x2001000c0202ULL || tags==0x2001000c2202ULL)
        && std::isfinite(frame.origin.x) && std::isfinite(frame.origin.y)
        && frame.size.width==126 && frame.size.height==126
        && CGRectEqualToRect(axFrame,frame);
}
bool verifiedCUAOverlay(NSDictionary *info,uint32_t wid,pid_t pid,int cid) {
    if(!info || !wid || pid<=0 || !cid || !api().windowSpaces || !api().spaceType
        || !api().windowDisplay || [number(info[(id)kCGWindowNumber]) unsignedIntValue]!=wid
        || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid)return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    ProcessBirth birth=processBirth(pid);CGRect frame={};
    if(!app || app.terminated || ![app.bundleIdentifier isEqual:@"com.openai.sky.CUAService"]
        || !birth.valid() || !signedCUAServiceExecutable(pid)
        || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)
        || !CGRectEqualToRect(CGRectMake(frame.origin.x,frame.origin.y,126,126),frame))return false;
    NSString *source=CFBridgingRelease(api().windowDisplay(cid,wid));
    if(!source.length)return false;
    uint64_t sourceSpace=0,sourceTags=0;
    int sourceOnscreen=-2;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        NSDictionary *current=nil;unsigned matches=0;
        for(NSDictionary *row in all)
            if([number(row[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                current=row;matches++;
            }
        if(matches!=1)return false;
        CGRect cgFrame={},axFrame={};uint64_t tags=0;bool parentKnown=false;
        uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        DormantAXInventory axInventory=readDormantAXInventory(pid);
        AXUIElementRef ax=findAXWindow(pid,wid);
        id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
        id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
        Boolean position=false,size=false;
        bool axExact=ax && axInventory.readable && axInventory.complete
            && axInventory.windows.count(wid)
            && AXUIElementIsAttributeSettable(ax,kAXPositionAttribute,&position)==kAXErrorSuccess
            && position && AXUIElementIsAttributeSettable(ax,kAXSizeAttribute,&size)==kAXErrorSuccess
            && !size && readAXFrame(ax,&axFrame);
        if(ax)CFRelease(ax);
        bool cgExact=[number(current[(id)kCGWindowOwnerPID]) intValue]==pid
            && [number(current[(id)kCGWindowLayer]) intValue]==0
            && [number(current[(id)kCGWindowAlpha]) doubleValue]==1
            && CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(current[(id)kCGWindowBounds]),&cgFrame)
            && CGRectEqualToRect(cgFrame,frame);
        CUAOverlayEvidence e;
        e.signedProcess=[app.bundleIdentifier isEqual:@"com.openai.sky.CUAService"];
        e.stableBirth=birth==processBirth(pid) && axInventory.birth==birth;
        e.exactCG=cgExact;e.completeAX=axExact;
        e.parentRoot=parentKnown && parent==0;
        uint64_t sid=members.count==1 ? [number(members[0]) unsignedLongLongValue] : 0;
        e.ordinarySpace=sid && api().spaceType(cid,sid)==0
            && (!sample || sid==sourceSpace);
        NSString *liveSource=CFBridgingRelease(api().windowDisplay(cid,wid));
        e.exactDisplay=liveSource.length && [liveSource isEqualToString:source];
        e.positionSettable=position;e.sizeUnsettable=!size;
        NSNumber *onscreen=number(current[(id)kCGWindowIsOnscreen]);
        int onscreenState=onscreen ? int(onscreen.boolValue) : -1;
        if(!exactWindowTags(cid,wid,&tags)
            || (sample && (tags!=sourceTags || onscreenState!=sourceOnscreen))
            || !cuaOverlayDecision(e,frame,axFrame,current[(id)kCGWindowName],
                role,subrole,tags))return false;
        if(sample==0) {
            sourceSpace=sid;sourceTags=tags;sourceOnscreen=onscreenState;
            usleep(25000);
        }
    }
    return birth==processBirth(pid) && signedCUAServiceExecutable(pid);
}
struct DetachedMenuStripEvidence {
    bool layerZero=false,blankTitle=false,alphaOne=false,onscreenKeyAbsent=false;
    bool parentKnown=false,parentRoot=false,exactTags=false,zeroMembership=false;
    bool stableProcess=false,absentVisible=false;
};
bool detachedMenuStripMetadata(const DetachedMenuStripEvidence &e,CGRect frame,
                               CGRect display,bool builtin) {
    return e.layerZero && e.blankTitle && e.alphaOne && e.onscreenKeyAbsent
        && e.parentKnown && e.parentRoot && e.exactTags && e.zeroMembership
        && e.stableProcess && e.absentVisible
        && std::isfinite(frame.origin.x) && std::isfinite(frame.origin.y)
        && std::isfinite(frame.size.width) && std::isfinite(frame.size.height)
        && CGRectGetWidth(display)>0 && CGRectGetHeight(display)>30
        && frame.origin.x==display.origin.x && frame.origin.y==display.origin.y
        && frame.size.width==display.size.width
        && frame.size.height==(builtin ? 26 : 30);
}
struct DetachedMenuStripScan {
    // Share the first independent inventory within one pass.  Every surface
    // still receives a fresh second inventory and fresh SkyLight identity.
    NSArray *all=nil;
    NSArray *visible=nil;
    bool loaded=false;
    bool ready=false;
    bool load() {
        if(loaded)return ready;
        loaded=true;
        all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        visible=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        if(!all || !visible)return false;
        usleep(25000);
        ready=true;return true;
    }
};
bool verifiedDetachedMenuStripSurface(NSDictionary *info,uint32_t wid,pid_t pid,int cid,
                                      DetachedMenuStripScan *sharedScan=nullptr) {
    if(!info || !wid || pid<=0 || !cid || !api().windowSpaces
        || [number(info[(id)kCGWindowNumber]) unsignedIntValue]!=wid
        || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid
        || [number(info[(id)kCGWindowLayer]) intValue]!=0
        || ![info[(id)kCGWindowName] isKindOfClass:NSString.class]
        || [info[(id)kCGWindowName] length]!=0
        || [number(info[(id)kCGWindowAlpha]) doubleValue]!=1
        || info[(id)kCGWindowIsOnscreen]!=nil)return false;
    CGRect frame={};
    if(!CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame))return false;
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return false;
    CGRect matched={};bool builtin=false;unsigned matches=0;
    for(uint32_t index=0;index<count;index++) {
        CGRect bounds=CGDisplayBounds(displays[index]);
        if(frame.origin.x==bounds.origin.x && frame.origin.y==bounds.origin.y
            && frame.size.width==bounds.size.width
            && frame.size.height==(CGDisplayIsBuiltin(displays[index]) ? 26 : 30)) {
            matched=bounds;builtin=CGDisplayIsBuiltin(displays[index]);matches++;
        }
    }
    if(matches!=1)return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    ProcessBirth birth=processBirth(pid);
    if(!app || app.terminated || !app.bundleIdentifier.length || !birth.valid())return false;
    DetachedMenuStripScan ownScan;
    DetachedMenuStripScan *scan=sharedScan ? sharedScan : &ownScan;
    if(!scan->load())return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=sample ? CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID)) : scan->all;
        NSArray *visible=sample ? CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly,kCGNullWindowID)) : scan->visible;
        if(!all || !visible)return false;
        NSDictionary *current=nil;unsigned found=0;
        for(NSDictionary *row in all)if([number(row[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
            current=row;found++;
        }
        if(found!=1 || [number(current[(id)kCGWindowOwnerPID]) intValue]!=pid)return false;
        bool absentVisible=true;
        for(NSDictionary *row in visible)if([number(row[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
            absentVisible=false;break;
        }
        CGRect liveFrame={};uint64_t tags=0;bool parentKnown=false;
        uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        DetachedMenuStripEvidence e;
        e.layerZero=[number(current[(id)kCGWindowLayer]) intValue]==0;
        e.blankTitle=[current[(id)kCGWindowName] isKindOfClass:NSString.class]
            && [current[(id)kCGWindowName] length]==0;
        e.alphaOne=[number(current[(id)kCGWindowAlpha]) doubleValue]==1;
        e.onscreenKeyAbsent=current[(id)kCGWindowIsOnscreen]==nil;
        e.parentKnown=parentKnown;e.parentRoot=parent==0;
        e.exactTags=exactWindowTags(cid,wid,&tags) && tags==0x200000090040ULL;
        e.zeroMembership=members && members.count==0;
        e.stableProcess=birth==processBirth(pid)
            && [[NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier
                isEqualToString:app.bundleIdentifier];
        e.absentVisible=absentVisible;
        if(!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(current[(id)kCGWindowBounds]),&liveFrame)
            || !CGRectEqualToRect(liveFrame,frame)
            || !detachedMenuStripMetadata(e,liveFrame,matched,builtin))return false;
    }
    return true;
}
bool stableTitledLinearMouseSurface(NSDictionary *original,uint32_t wid,pid_t pid,
                                   CGRect frame,int cid) {
    NSString *title=original[(id)kCGWindowName];
    NSNumber *alpha=number(original[(id)kCGWindowAlpha]);
    if(![title isEqual:@"LinearMouse"] || !alpha || alpha.doubleValue!=1
        || frame.size.width<20 || frame.size.height<20)return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        NSUInteger matches=0;
        for(NSDictionary *candidate in all)
            if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                matches++;CGRect current={};
                if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || [number(candidate[(id)kCGWindowLayer]) intValue]!=0
                    || !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
                    || !CGRectEqualToRect(current,frame)
                    || ![candidate[(id)kCGWindowName] isEqual:title]
                    || [number(candidate[(id)kCGWindowAlpha]) doubleValue]!=1)return false;
            }
        uint64_t tags=0;bool parentKnown=false;
        uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
        if(matches!=1 || !parentKnown || parent!=0
            || !exactWindowTags(cid,wid,&tags) || tags!=0x200100480001ULL)return false;
        if(sample==0)usleep(25000);
    }
    return true;
}
std::set<uint32_t> backgroundChromeFullScreenCompanions(NSArray *windows,uint64_t sid,
        CGRect displayBounds,const std::string &sourceUUID,int cid) {
    std::set<uint32_t> rejected;
    if(!sid || api().spaceType(cid,sid)!=4)return rejected;
    NSMutableArray *cohort=NSMutableArray.array;
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        if(!wid)return rejected;
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!members)return rejected;
        if(members.count==1 && [number(members[0]) unsignedLongLongValue]==sid)
            [cohort addObject:info];
    }
    if(cohort.count!=4)return rejected;
    uint32_t owner=0,root=0,middle=0,leaf=0;CGRect ownerFrame={},rootFrame={},middleFrame={},leafFrame={};
    pid_t pid=0;ProcessBirth birth;NSString *bundle=nil;
    for(NSDictionary *info in cohort) {
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t candidatePID=[number(info[(id)kCGWindowOwnerPID]) intValue];
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:candidatePID];
        ProcessBirth candidateBirth=processBirth(candidatePID);
        CGRect frame={};uint64_t tags=0;
        if(!candidatePID || !app || app.terminated
            || ![app.bundleIdentifier isEqual:@"com.google.Chrome"]
            || !candidateBirth.valid() || !(candidateBirth==processBirth(candidatePID))
            || (pid && (pid!=candidatePID || !(birth==candidateBirth)))
            || !CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)
            || !stableCGSurface(info,wid,candidatePID,frame)
            || !windowOnDisplay(wid,cid,sourceUUID)
            || !exactWindowTags(cid,wid,&tags))return rejected;
        pid=candidatePID;birth=candidateBirth;bundle=app.bundleIdentifier;
        NSString *title=info[(id)kCGWindowName];
        bool blank=![title isKindOfClass:NSString.class] || !title.length;
        uint32_t parent=exactWindowParent(cid,wid);
        if(!blank && tags==0x300040100082401ULL && parent==0 && !owner) {
            owner=wid;ownerFrame=frame;
        } else if(blank && tags==0x8040401400c2080ULL && parent==0 && !root) {
            root=wid;rootFrame=frame;
        } else if(blank && tags==0x1400c2282ULL) {
            if(!middle){middle=wid;middleFrame=frame;}
            else if(!leaf){leaf=wid;leafFrame=frame;}
            else return rejected;
        } else return rejected;
    }
    if(!owner || !root || !middle || !leaf || !bundle)return rejected;
    if(exactWindowParent(cid,middle)!=root || exactWindowParent(cid,leaf)!=middle) {
        if(exactWindowParent(cid,leaf)==root
            && exactWindowParent(cid,middle)==leaf) {
            std::swap(middle,leaf);std::swap(middleFrame,leafFrame);
        } else return rejected;
    }
    if(!backgroundChromeFourSurfaceGeometry(displayBounds,ownerFrame,rootFrame,middleFrame,leafFrame)
        || !(birth==processBirth(pid)) || stableLaunchTime(
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid],pid)<=0)return rejected;
    DormantAXInventory ax=readDormantAXInventory(pid);
    if(!(ax.birth==birth) || !ax.readable || !ax.complete
        || ax.windows.count(owner) || ax.windows.count(root)
        || ax.windows.count(middle) || ax.windows.count(leaf))return rejected;
    NSArray *visible=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    if(!visible)return rejected;
    for(NSDictionary *info in visible) {
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        if(wid==owner || wid==root || wid==middle || wid==leaf)return rejected;
    }
    for(uint32_t wid:{owner,root,middle,leaf}) {
        AXUIElementRef axWindow=findAXWindow(pid,wid);
        if(axWindow){CFRelease(axWindow);return rejected;}
    }
    return {root,middle,leaf};
}
// Chrome can retain two offscreen toolbar strips in the built-in desktop Space
// while their AXStandard window lives on an external ordinary Space.  Neither
// strip alone is enough to establish that cross-display compositor identity.
bool ordinaryChromeCrossDisplayPair(NSArray *windows,uint32_t wid,pid_t pid,
                                    NSString *bundle,ProcessBirth birth,CGRect sourceBounds,
                                    uint64_t sid,const std::string &sourceUUID,int cid,
                                    const DormantAXInventory &ax) {
    if(!windows || ![bundle isEqual:@"com.google.Chrome"] || !birth.valid()
        || !ax.readable || !ax.complete || !(ax.birth==birth) || sourceUUID.empty())return false;
    CGDirectDisplayID displays[32]={};uint32_t count=0;bool builtin=false;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return false;
    for(uint32_t i=0;i<count;i++)
        if([displayUUID(displays[i]) isEqual:[NSString stringWithUTF8String:sourceUUID.c_str()]]
            && CGDisplayIsBuiltin(displays[i])
            && CGRectEqualToRect(CGDisplayBounds(displays[i]),sourceBounds))builtin=true;
    if(!builtin)return false;
    NSArray *visibleBefore=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    if(!visibleBefore || !visibleBefore.count)return false;
    auto strip=[&](NSDictionary *info,uint32_t candidateID,CGRect frame)->bool {
        if(!candidateID || [number(info[(id)kCGWindowLayer]) intValue]!=0
            || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid
            || ax.windows.count(candidateID) || exactWindowParent(cid,candidateID)!=0)return false;
        NSString *title=info[(id)kCGWindowName];NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
        NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);uint64_t tags=0;
        if(([title isKindOfClass:NSString.class] && title.length)
            || !alpha || alpha.doubleValue!=1 || (onscreen && onscreen.boolValue)
            || !exactWindowTags(cid,candidateID,&tags) || tags!=0x1400c0202ULL
            || !stableAllCGSurface(info,candidateID,pid,frame)
            || !windowOnDisplay(candidateID,cid,sourceUUID))return false;
        AXUIElementRef child=findAXWindow(pid,candidateID);
        if(child){CFRelease(child);return false;}
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(candidateID)]));
        return members.count==1 && [number(members[0]) unsignedLongLongValue]==sid
            && api().spaceType(cid,sid)==0;
    };
    for(uint32_t rootID:ax.windows) {
        AXUIElementRef root=findAXWindow(pid,rootID);CGRect rootFrame={},rootCG={};
        id role=root?axAttribute(root,kAXRoleAttribute):nil;
        id subrole=root?axAttribute(root,kAXSubroleAttribute):nil;
        bool standard=root && [role isEqual:(__bridge NSString *)kAXWindowRole]
            && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
            && readAXFrame(root,&rootFrame) && readCGFrame(rootID,pid,&rootCG)
            && nearFrame(rootFrame,rootCG);
        if(root)CFRelease(root);if(!standard)continue;
        NSString *rootUUID=api().windowDisplay ? CFBridgingRelease(api().windowDisplay(cid,rootID)) : nil;
        if(!rootUUID || [rootUUID isEqual:[NSString stringWithUTF8String:sourceUUID.c_str()]])continue;
        NSArray *rootMembers=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(rootID)]));
        uint64_t rootSID=rootMembers.count==1 ? [number(rootMembers[0]) unsignedLongLongValue] : 0;
        if(!rootSID || rootSID==sid || api().spaceType(cid,rootSID)!=0
            || !windowOnDisplay(rootID,cid,rootUUID.UTF8String)
            || !spaceOnDisplay(managed(),rootSID,rootUUID.UTF8String))continue;
        for(uint32_t i=0;i<count;i++) {
            if(CGDisplayIsBuiltin(displays[i]) || ![displayUUID(displays[i]) isEqual:rootUUID])continue;
            CGRect external=CGDisplayBounds(displays[i]);uint32_t alignedID=0,displacedID=0;
            CGRect aligned={},displaced={};int alignedCount=0,displacedCount=0;
            for(NSDictionary *info in windows) {
                uint32_t candidateID=[number(info[(id)kCGWindowNumber]) unsignedIntValue];CGRect frame={};
                if(!candidateID || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary(
                        info[(id)kCGWindowBounds]),&frame)
                    || frame.size.height<=0 || frame.size.height>128
                    || fabs(frame.size.width-external.size.width)>2
                    || fabs(CGRectGetMaxY(frame)-external.origin.y)>2)continue;
                bool atLeft=fabs(frame.origin.x-external.origin.x)<=2;
                bool pastRight=fabs(frame.origin.x
                    -(CGRectGetMaxX(external)+external.size.width))<=2;
                if(!atLeft && !pastRight)continue;
                if(!strip(info,candidateID,frame))continue;
                if(atLeft){alignedID=candidateID;aligned=frame;alignedCount++;}
                if(pastRight){displacedID=candidateID;displaced=frame;displacedCount++;}
            }
            if(alignedCount==1 && displacedCount==1
                && (wid==alignedID || wid==displacedID)
                && ordinaryChromeCrossDisplayPairGeometry(sourceBounds,external,rootFrame,
                    aligned,displaced) && birth==processBirth(pid)
                && ordinaryChromePairAbsentFromOnscreenInventory(visibleBefore,alignedID,displacedID)) {
                NSArray *visibleAfter=CFBridgingRelease(CGWindowListCopyWindowInfo(
                    kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
                if(ordinaryChromePairAbsentFromOnscreenInventory(visibleAfter,alignedID,
                    displacedID))return true;
            }
        }
    }
    return false;
}
bool selectedFullScreenCompanion(NSDictionary *info,uint32_t wid,pid_t pid,NSString *bundle,
                                 ProcessBirth birth,CGRect frame,uint64_t sid,
                                 const std::string &sourceUUID,
                                 const SelectedFullScreenOwner &owner,int cid,
                                 DormantAXCache &cache,std::string *failedPredicate=nullptr) {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    bool exactProcess=owner.id && pid==owner.pid && owner.birth==birth && app && !app.terminated
        && bundle && owner.bundle && [bundle isEqual:owner.bundle]
        && [app.bundleIdentifier isEqual:bundle] && birth==processBirth(pid);
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    bool exactSpace=membership && membership.count==1
        && [number(membership[0]) unsignedLongLongValue]==sid && api().spaceType(cid,sid)==4;
    bool exactDisplay=windowOnDisplay(wid,cid,sourceUUID) && windowOnDisplay(owner.id,cid,sourceUUID);
    NSArray *ownerMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
        (__bridge CFArrayRef)@[@(owner.id)]));
    AXUIElementRef ownerAX=findAXWindow(owner.pid,owner.id);Boolean ownerSettable=false;CGRect ownerAXFrame={};
    id ownerRole=ownerAX ? axAttribute(ownerAX,kAXRoleAttribute) : nil;
    id ownerSubrole=ownerAX ? axAttribute(ownerAX,kAXSubroleAttribute) : nil;
    id ownerState=ownerAX ? axAttribute(ownerAX,CFSTR("AXFullScreen")) : nil;
    bool ownerLive=ownerAX
        && [ownerRole isEqual:(__bridge NSString *)kAXWindowRole]
        && [ownerSubrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && ownerState && CFGetTypeID((__bridge CFTypeRef)ownerState)==CFBooleanGetTypeID()
        && CFBooleanGetValue((__bridge CFBooleanRef)ownerState)
        && AXUIElementIsAttributeSettable(ownerAX,CFSTR("AXFullScreen"),&ownerSettable)==kAXErrorSuccess
        && ownerSettable && readAXFrame(ownerAX,&ownerAXFrame) && nearFrame(ownerAXFrame,owner.frame)
        && ownerMembership.count==1 && [number(ownerMembership[0]) unsignedLongLongValue]==sid;
    if(ownerAX)CFRelease(ownerAX);
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    bool stable=alpha && std::isfinite(alpha.doubleValue)
        && alpha.doubleValue>=0 && alpha.doubleValue<=1
        && stableCGSurface(info,wid,pid,frame);
    AXUIElementRef ax=findAXWindow(pid,wid);bool nonstandard=false;
    if(ax) {
        id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
        id state=axAttribute(ax,CFSTR("AXFullScreen"));Boolean settable=true;CGRect axFrame={};
        nonstandard=[role isEqual:(__bridge NSString *)kAXWindowRole]
            && [subrole isEqual:@"AXUnknown"]
            && state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
            && !CFBooleanGetValue((__bridge CFBooleanRef)state)
            && AXUIElementIsAttributeSettable(ax,CFSTR("AXFullScreen"),&settable)==kAXErrorSuccess
            && !settable && readAXFrame(ax,&axFrame) && CGRectEqualToRect(axFrame,frame);
        CFRelease(ax);
    }
    auto found=cache.find(pid);if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    bool complete=found->second.birth==birth && found->second.readable && found->second.complete;
    NSString *title=info[(id)kCGWindowName];
    bool blank=![title isKindOfClass:NSString.class] || title.length==0;
    CGRect tolerance=CGRectMake(owner.frame.origin.x-2,owner.frame.origin.y-130,
        owner.frame.size.width+4,owner.frame.size.height+132);
    bool contained=CGRectContainsRect(tolerance,frame);
    bool ownerInInventory=found->second.windows.count(owner.id);
    bool candidateAbsent=!found->second.windows.count(wid);
    if(fullScreenCompanionDecision(exactProcess,exactSpace,exactDisplay,stable,ownerLive,nonstandard,
        complete,ownerInInventory,candidateAbsent,blank,contained))return true;
    bool browser=windowOnDisplay(owner.id,cid,sourceUUID)
        && browserFullScreenStripDecision([bundle isEqual:@"com.google.Chrome"],exactProcess,
            exactSpace,stable,ownerLive,complete,ownerInInventory,nonstandard,candidateAbsent,blank,
            owner.frame,frame);
    if(browser)return true;
    if([bundle isEqual:@"com.google.Chrome"] && exactProcess && exactSpace && exactDisplay
        && stable && ownerLive && complete && ownerInInventory && nonstandard && blank) {
        uint32_t parentID=exactWindowParent(cid,wid);
        if(parentID && parentID!=wid && parentID!=owner.id) {
            NSArray *parentWindows=CFBridgingRelease(CGWindowListCopyWindowInfo(
                kCGWindowListOptionIncludingWindow,parentID));
            for(NSDictionary *parentInfo in parentWindows) {
                if([number(parentInfo[(id)kCGWindowNumber]) unsignedIntValue]!=parentID
                    || [number(parentInfo[(id)kCGWindowOwnerPID]) intValue]!=pid)continue;
                CGRect parentFrame={};uint64_t parentTags=0,childTags=0;
                if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary(
                        parentInfo[(id)kCGWindowBounds]),&parentFrame)
                    || !browserFullScreenDetachedStripGeometry(owner.frame,parentFrame,frame)
                    || !exactWindowTags(cid,parentID,&parentTags)
                    || !exactWindowTags(cid,wid,&childTags)
                    || !parentTags || parentTags!=childTags)continue;
                if(selectedFullScreenCompanion(parentInfo,parentID,pid,bundle,birth,parentFrame,
                        sid,sourceUUID,owner,cid,cache)
                    && exactWindowParent(cid,wid)==parentID)return true;
            }
        }
    }
    if(failedPredicate) {
        if(!exactProcess)*failedPredicate="process_identity";
        else if(!exactSpace)*failedPredicate="space_membership";
        else if(!exactDisplay)*failedPredicate="display_membership";
        else if(!stable)*failedPredicate="cg_identity";
        else if(!ownerLive)*failedPredicate="owner_ax_identity";
        else if(!complete)*failedPredicate="complete_ax_inventory";
        else if(!ownerInInventory)*failedPredicate="owner_ax_inventory_membership";
        else if(!candidateAbsent && !nonstandard)*failedPredicate="companion_ax_identity";
        else if(!blank)*failedPredicate="blank_companion_title";
        else if(!contained)*failedPredicate="companion_geometry";
        else *failedPredicate="companion_classification";
    }
    return false;
}
bool stableChromeTransparentCGSurface(uint32_t wid,pid_t pid,CGRect frame,ProcessBirth birth) {
    if(!birth.valid())return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        unsigned matches=0;
        for(NSDictionary *candidate in all)
            if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                matches++;CGRect current={};NSNumber *alpha=number(candidate[(id)kCGWindowAlpha]);
                if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || [number(candidate[(id)kCGWindowLayer]) intValue]!=0
                    || !alpha || alpha.doubleValue!=0
                    || !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
                    || !CGRectEqualToRect(current,frame))return false;
            }
        if(matches!=1 || !(birth==processBirth(pid)))return false;
        if(sample==0)usleep(25000);
    }
    return true;
}
bool ordinaryCompanionSurface(NSDictionary *info,NSArray *windows,uint32_t wid,pid_t pid,NSString *bundle,
                              ProcessBirth birth,CGRect frame,CGRect displayBounds,uint64_t sid,
                              const std::string &sourceUUID,int cid,DormantAXCache &cache) {
    if(!birth.valid() || !bundle)return false;
    AXUIElementRef ownAX=findAXWindow(pid,wid);
    if(ownAX){CFRelease(ownAX);return false;}
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(!app || app.terminated || ![app.bundleIdentifier isEqual:bundle]
        || !(birth==processBirth(pid))
        || !windowOnDisplay(wid,cid,sourceUUID))return false;
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    if(membership.count!=1 || [number(membership[0]) unsignedLongLongValue]!=sid
        || api().spaceType(cid,sid)!=0)return false;
    NSString *title=info[(id)kCGWindowName];
    if([title isKindOfClass:NSString.class] && title.length)return false;
    auto found=cache.find(pid);if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    if(!(found->second.birth==birth) || !found->second.readable || !found->second.complete
        || found->second.windows.count(wid))return false;
    if([bundle isEqual:@"com.apple.finder"]) {
        NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
        NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
        uint32_t parentID=exactWindowParent(cid,wid);
        OrdinaryOwnedChildEvidence evidence;
        evidence.finder=true;evidence.process=birth==processBirth(pid);
        evidence.space=true;evidence.display=windowOnDisplay(wid,cid,sourceUUID);
        evidence.stableCG=stableAllCGSurface(info,wid,pid,frame);
        evidence.completeAX=true;evidence.candidateAbsentAX=true;
        evidence.exactParent=parentID && parentID!=wid;
        evidence.parentRoot=evidence.exactParent && exactWindowParent(cid,parentID)==0;
        evidence.parentInAX=evidence.exactParent && found->second.windows.count(parentID);
        evidence.blankTitle=![title isKindOfClass:NSString.class] || title.length==0;
        evidence.alphaOne=alpha && alpha.doubleValue==1;
        evidence.onscreen=onscreen && onscreen.boolValue;
        CGRect verifiedParentFrame={};
        if(evidence.parentInAX) {
            AXUIElementRef parent=findAXWindow(pid,parentID);CGRect cgFrame={};
            id role=parent ? axAttribute(parent,kAXRoleAttribute) : nil;
            id subrole=parent ? axAttribute(parent,kAXSubroleAttribute) : nil;
            bool standard=parent
                && [role isEqual:(__bridge NSString *)kAXWindowRole]
                && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                && readAXFrame(parent,&verifiedParentFrame) && readCGFrame(parentID,pid,&cgFrame)
                && nearFrame(verifiedParentFrame,cgFrame);
            if(parent)CFRelease(parent);
            NSArray *parentMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(parentID)]));
            evidence.parentStandard=standard;
            evidence.space=evidence.space && parentMembership.count==1
                && [number(parentMembership[0]) unsignedLongLongValue]==sid;
            evidence.display=evidence.display && windowOnDisplay(parentID,cid,sourceUUID);
            evidence.contained=standard
                && CGRectContainsRect(CGRectInset(verifiedParentFrame,-2,-2),frame);
        }
        if(ordinaryOwnedChildDecision(evidence)) {
            NSArray *confirmed=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(wid)]));
            NSArray *confirmedParentMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(parentID)]));
            CGRect confirmedParentCG={};AXUIElementRef confirmedParentAX=findAXWindow(pid,parentID);
            id confirmedRole=confirmedParentAX ? axAttribute(confirmedParentAX,kAXRoleAttribute) : nil;
            id confirmedSubrole=confirmedParentAX ? axAttribute(confirmedParentAX,kAXSubroleAttribute) : nil;
            CGRect confirmedParentFrame={};
            bool confirmedParent=confirmedParentAX
                && [confirmedRole isEqual:(__bridge NSString *)kAXWindowRole]
                && [confirmedSubrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                && readAXFrame(confirmedParentAX,&confirmedParentFrame)
                && readCGFrame(parentID,pid,&confirmedParentCG)
                && nearFrame(confirmedParentFrame,confirmedParentCG)
                && nearFrame(confirmedParentFrame,verifiedParentFrame);
            if(confirmedParentAX)CFRelease(confirmedParentAX);
            return confirmed.count==1 && [number(confirmed[0]) unsignedLongLongValue]==sid
                && confirmedParentMembership.count==1
                && [number(confirmedParentMembership[0]) unsignedLongLongValue]==sid
                && api().spaceType(cid,sid)==0 && exactWindowParent(cid,wid)==parentID
                && exactWindowParent(cid,parentID)==0 && confirmedParent
                && stableAllCGSurface(info,wid,pid,frame)
                && windowOnDisplay(wid,cid,sourceUUID)
                && windowOnDisplay(parentID,cid,sourceUUID) && birth==processBirth(pid);
        }
        return false;
    }
    if([bundle isEqual:@"com.google.Chrome"]) {
        if(ordinaryChromeCrossDisplayPair(windows,wid,pid,bundle,birth,displayBounds,sid,
            sourceUUID,cid,found->second))return true;
        NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
        NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
        uint64_t transparentTags=0;bool parentKnown=false;
        uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
        if(alpha && alpha.doubleValue==0 && (!onscreen || !onscreen.boolValue)
            && parentKnown && parent==0
            && exactWindowTags(cid,wid,&transparentTags)
            && transparentTags==0x1400c0202ULL
            && stableChromeTransparentCGSurface(wid,pid,frame,birth)) {
            int matchingRoots=0;
            for(uint32_t rootID:found->second.windows) {
                AXUIElementRef root=findAXWindow(pid,rootID);
                id role=root ? axAttribute(root,kAXRoleAttribute) : nil;
                id subrole=root ? axAttribute(root,kAXSubroleAttribute) : nil;
                CGRect rootFrame={},rootCG={};
                bool standard=root
                    && [role isEqual:(__bridge NSString *)kAXWindowRole]
                    && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                    && readAXFrame(root,&rootFrame) && readCGFrame(rootID,pid,&rootCG)
                    && nearFrame(rootFrame,rootCG);
                if(root)CFRelease(root);
                if(!standard || !ordinaryChromeTransparentBottomEdge(
                    displayBounds,rootFrame,frame))continue;
                NSArray *rootMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
                    (__bridge CFArrayRef)@[@(rootID)]));
                if(rootMembership.count==1
                    && [number(rootMembership[0]) unsignedLongLongValue]==sid
                    && windowOnDisplay(rootID,cid,sourceUUID))matchingRoots++;
            }
            NSArray *confirmed=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(wid)]));
            uint64_t confirmedTags=0;
            if(matchingRoots==1 && confirmed.count==1
                && [number(confirmed[0]) unsignedLongLongValue]==sid
                && windowOnDisplay(wid,cid,sourceUUID)
                && exactWindowTags(cid,wid,&confirmedTags)
                && confirmedTags==transparentTags && birth==processBirth(pid))return true;
        }
        OrdinaryChromeStripEvidence evidence;
        evidence.chrome=true;evidence.process=birth==processBirth(pid);
        evidence.space=true;evidence.display=windowOnDisplay(wid,cid,sourceUUID);
        evidence.stableAll=stableAllCGSurface(info,wid,pid,frame);
        evidence.completeAX=true;evidence.candidateAbsentAX=true;
        evidence.blankTitle=true;evidence.alphaOne=alpha && alpha.doubleValue==1;
        evidence.offscreen=!onscreen || !onscreen.boolValue;
        uint64_t surfaceTags=0;
        OrdinaryChromeGeometry surfaceKind=OrdinaryChromeGeometry::None;
        if(exactWindowTags(cid,wid,&surfaceTags)) {
            // These exact Chrome compositor classes differ from AXStandard user windows.
            // Unknown tag layouts fail closed on future macOS/Chrome versions.
            for(uint32_t rootID:found->second.windows) {
                AXUIElementRef root=findAXWindow(pid,rootID);CGRect rootFrame={};
                bool framed=root && readAXFrame(root,&rootFrame);if(root)CFRelease(root);
                if(!framed)continue;
                OrdinaryChromeGeometry kind=ordinaryChromeStripKind(
                    displayBounds,rootFrame,frame,evidence.offscreen);
                if(kind==OrdinaryChromeGeometry::None)continue;
                if(surfaceKind==OrdinaryChromeGeometry::None)surfaceKind=kind;
                else if(surfaceKind!=kind){surfaceKind=OrdinaryChromeGeometry::None;break;}
            }
            evidence.surfaceTags=ordinaryChromeSurfaceTagDecision(surfaceTags,surfaceKind);
        }
        if(!evidence.stableAll || !evidence.process || !evidence.display
            || !evidence.alphaOne || !evidence.surfaceTags)return false;
        CGRect matchingRoot={};int matchingRoots=0;bool exactCohort=true;
        for(uint32_t rootID:found->second.windows) {
            AXUIElementRef root=findAXWindow(pid,rootID);if(!root)continue;
            id role=axAttribute(root,kAXRoleAttribute),subrole=axAttribute(root,kAXSubroleAttribute);
            CGRect rootFrame={};bool standard=[role isEqual:(__bridge NSString *)kAXWindowRole]
                && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                && readAXFrame(root,&rootFrame);
            CFRelease(root);if(!standard
                || !ordinaryChromeStripGeometry(displayBounds,rootFrame,frame,evidence.offscreen))continue;
            matchingRoots++;
            NSArray *rootMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(rootID)]));
            CGRect rootCG={};
            bool exact=rootMembership.count==1 && [number(rootMembership[0]) unsignedLongLongValue]==sid
                && windowOnDisplay(rootID,cid,sourceUUID)
                && readCGFrame(rootID,pid,&rootCG) && nearFrame(rootFrame,rootCG);
            if(!exact)exactCohort=false;
            else matchingRoot=rootFrame;
        }
        evidence.standardRootCohort=matchingRoots>0 && exactCohort;
        if(!ordinaryChromeStripDecision(evidence,displayBounds,matchingRoot,frame))return false;
        NSArray *confirmed=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        uint64_t confirmedTags=0;
        return confirmed.count==1 && [number(confirmed[0]) unsignedLongLongValue]==sid
            && api().spaceType(cid,sid)==0 && windowOnDisplay(wid,cid,sourceUUID)
            && exactWindowTags(cid,wid,&confirmedTags) && confirmedTags==surfaceTags
            && birth==processBirth(pid);
    }
    if([bundle isEqual:@"com.apple.Safari"]) {
        if(!stableCGSurface(info,wid,pid,frame))return false;
        NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
        bool narrow=frame.size.width<=30 || frame.size.height<=30;
        bool inside=CGRectContainsRect(CGRectInset(displayBounds,-2,-2),frame);
        return alpha && alpha.doubleValue==0 && narrow && inside;
    }
    return false;
}
Membership ordinaryMembership(uint32_t wid,int cid,uint64_t *space) {
    if(space)*space=0;
    if(!api().windowSpaces || !api().spaceType)return Membership::Missing;
    NSArray *ids=@[@(wid)];
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)ids));
    if(!membership || !membership.count)return Membership::Missing;
    if(membership.count!=1)return Membership::Multiple;
    uint64_t sid=[number(membership[0]) unsignedLongLongValue];
    if(!sid || api().spaceType(cid,sid)!=0)return Membership::NonOrdinary;
    if(space)*space=sid;
    return Membership::Ordinary;
}
uint64_t oneWindowSpace(uint32_t wid,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->windowSpace)return recoveryHooks->windowSpace(wid);
#endif
    uint64_t sid=0;
    return ordinaryMembership(wid,cid,&sid)==Membership::Ordinary ? sid : 0;
}
bool move(uint32_t wid,uint64_t sid,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->move)return recoveryHooks->move(wid,sid);
#endif
    if(!sid || api().spaceType(cid,sid)!=0) return false;
    if(oneWindowSpace(wid,cid)==sid) return true;
    NSArray *ids=@[@(wid)];
    Class bridged=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    if(bridged && [bridged instancesRespondToSelector:@selector(initWithWindows:spaceID:)]
        && [bridged instancesRespondToSelector:@selector(performWithWMBridgeDelegate)]) {
        id operation=[[bridged alloc] initWithWindows:ids spaceID:sid];
        if(operation) {
            [operation performWithWMBridgeDelegate];
            for(int retry=0;retry<80;retry++) {
                if(oneWindowSpace(wid,cid)==sid) return true;
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
                usleep(1000);
            }
        }
    }
    // On macOS 26+ the older calls may leave another app's window in place.
    // Do not report success based only on their return value or resolved symbol.
    if([NSProcessInfo processInfo].operatingSystemVersion.majorVersion>=26) return false;
    if(api().legacyMove) api().legacyMove(cid,(__bridge CFArrayRef)ids,sid);
    for(int retry=0;retry<20;retry++) {
        if(oneWindowSpace(wid,cid)==sid) return true;
        usleep(25000);
    }
    // Some releases require the compatibility workspace path instead.
    if(!api().compat || !api().workspace) return false;
    constexpr int workspaceId=0x79616265;
    if(api().compat(cid,sid,workspaceId)!=kCGErrorSuccess) return false;
    CGError result=api().workspace(cid,&wid,1,workspaceId);
    api().compat(cid,sid,0);
    if(result!=kCGErrorSuccess) return false;
    for(int retry=0;retry<20;retry++) {
        if(oneWindowSpace(wid,cid)==sid) return true;
        usleep(25000);
    }
    return false;
}
uint64_t builtInCurrentSpace() {
    NSDictionary *display=builtInManaged(managed());
    NSString *uuid=managedDisplayUUID(display);
    if(!uuid || ![uuid isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])return 0;
    return [number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
}
bool bridgedSwitchAvailable() {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->switchAvailable)return recoveryHooks->switchAvailable();
#endif
    Class bridged=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    return bridged && [bridged instancesRespondToSelector:@selector(initWithDisplayIdentifier:spaceID:)]
        && [bridged instancesRespondToSelector:@selector(performWithWMBridgeDelegate)];
}
bool verifiedInitialFullScreenSpace(uint64_t sid,int cid);
uint64_t currentSpaceForDisplay(NSArray *all,const std::string &uuid);
bool missionControlSwitchDisplaySpace(const std::string &uuid,uint64_t sid,int cid);
bool switchSpace(uint64_t sid,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->switchSpace)return recoveryHooks->switchSpace(sid);
#endif
    NSDictionary *display=builtInManaged(managed());
    NSString *uuid=managedDisplayUUID(display);
    int type=sid ? api().spaceType(cid,sid) : -1;
    if(!sid || builtinUUID.empty() || ![uuid isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]]
        || !managedSpace(display,sid) || (type!=0 && !(type==4 && verifiedInitialFullScreenSpace(sid,cid))))return false;
    if(builtInCurrentSpace()==sid)return true;
    if(!bridgedSwitchAvailable())return false;
    Class bridged=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    id operation=[[bridged alloc] initWithDisplayIdentifier:uuid spaceID:sid];
    if(!operation)return false;
    [operation performWithWMBridgeDelegate];
    for(int retry=0;retry<80;retry++) {
        if(builtInCurrentSpace()==sid)return true;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
        usleep(1000);
    }
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27
        && missionControlSwitchDisplaySpace(builtinUUID,sid,cid);
}
id axAttribute(AXUIElementRef element,CFStringRef name);
bool readAXFrame(AXUIElementRef window,CGRect *frame);
bool readCGFrame(uint32_t wid,pid_t pid,CGRect *frame);
bool windowOnDisplay(uint32_t wid,int cid,const std::string &uuid);
bool spaceOnDisplay(NSArray *all,uint64_t sid,const std::string &uuid);
bool fullScreenMembership(const SavedWindow &w,int cid);
bool setFullScreenElement(AXUIElementRef window,bool desired);
bool persist();
bool nearFrame(CGRect a,CGRect b);
AXUIElementRef findAXWindow(pid_t pid,uint32_t wid) {
    if(pid<=0 || !wid || !api().axWindow)return nullptr;
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    if(!app) return nullptr;
    CFTypeRef raw=nullptr;
    AXError result=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&raw);
    AXUIElementRef found=nullptr;
    if(result==kAXErrorSuccess && raw && CFGetTypeID(raw)==CFArrayGetTypeID()) {
        for(id item in (__bridge NSArray *)raw) {
            if(CFGetTypeID((__bridge CFTypeRef)item)!=AXUIElementGetTypeID())continue;
            CGWindowID candidate=0;
            if(api().axWindow((__bridge AXUIElementRef)item,&candidate)==kAXErrorSuccess && candidate==wid) {
                found=(AXUIElementRef)CFRetain((__bridge CFTypeRef)item);break;
            }
        }
    }
    if(raw)CFRelease(raw);
    // About This Mac can expose a real standard window through Main/Focused
    // while returning an empty AXWindows array. Match both AX PID and CG WID.
    if(!found)for(CFStringRef key : {kAXMainWindowAttribute,kAXFocusedWindowAttribute}) {
        CFTypeRef value=nullptr;
        AXError status=AXUIElementCopyAttributeValue(app,key,&value);
        pid_t owner=0;CGWindowID candidate=0;CGRect frame={};
        if(status==kAXErrorSuccess && value && CFGetTypeID(value)==AXUIElementGetTypeID()
            && AXUIElementGetPid((AXUIElementRef)value,&owner)==kAXErrorSuccess && owner==pid
            && api().axWindow((AXUIElementRef)value,&candidate)==kAXErrorSuccess && candidate==wid
            && readCGFrame(wid,pid,&frame))found=(AXUIElementRef)CFRetain(value);
        if(value)CFRelease(value);
        if(found)break;
    }
    CFRelease(app);return found;
}
bool sameProcess(const SavedWindow &w) {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
    double live=stableLaunchTime(app,w.pid);
    return app && [app.bundleIdentifier isEqualToString:[NSString stringWithUTF8String:w.bundle.c_str()]]
        && w.launchTime>0 && live>0 && fabs(live-w.launchTime)<=1;
}
AXUIElementRef findIdentifiedAXWindow(const SavedWindow &w,uint32_t *actualID) {
    if(actualID)*actualID=0;
    if(!sameProcess(w) || !api().axWindow)return nullptr;
    AXUIElementRef app=AXUIElementCreateApplication(w.pid);
    if(!app)return nullptr;
    AXUIElementSetMessagingTimeout(app,0.5);
    NSArray *windows=array(axAttribute(app,kAXWindowsAttribute));
    AXUIElementRef exact=nullptr,identified=nullptr;
    uint32_t exactID=0,identifiedID=0;int identifierCount=0;
    for(id item in windows) {
        AXUIElementRef candidate=(__bridge AXUIElementRef)item;
        CGWindowID wid=0;
        if(api().axWindow(candidate,&wid)!=kAXErrorSuccess || !wid)continue;
        NSString *identifier=axAttribute(candidate,kAXIdentifierAttribute);
        bool matchesIdentifier=!w.axIdentifier.empty() && [identifier isKindOfClass:NSString.class]
            && [identifier isEqualToString:[NSString stringWithUTF8String:w.axIdentifier.c_str()]];
        if(matchesIdentifier) {
            identifierCount++;
            if(identifierCount==1){identified=(AXUIElementRef)CFRetain(candidate);identifiedID=wid;}
        }
        if(wid==w.id && (w.axIdentifier.empty() || matchesIdentifier)) {
            if(exact) { CFRelease(exact);exact=nullptr;exactID=0;identifierCount=2;break; }
            exact=(AXUIElementRef)CFRetain(candidate);exactID=wid;
        }
    }
    CFRelease(app);
    if(identifierCount>1) {if(exact)CFRelease(exact);if(identified)CFRelease(identified);return nullptr;}
    if(exact) {if(identified)CFRelease(identified);if(actualID)*actualID=exactID;return exact;}
    if(identified && actualID)*actualID=identifiedID;
    return identified;
}
uint32_t resolvedWindowID(const SavedWindow &w) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->resolveWindow)return recoveryHooks->resolveWindow(w);
#endif
    uint32_t wid=0;
    AXUIElementRef window=findIdentifiedAXWindow(w,&wid);
    if(window)CFRelease(window);
    return wid;
}
int fullScreenState(const SavedWindow &w) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->fullScreenState)return recoveryHooks->fullScreenState(w);
#endif
    AXUIElementRef window=findIdentifiedAXWindow(w,nullptr);
    if(!window)return -1;
    id value=axAttribute(window,CFSTR("AXFullScreen"));
    CFRelease(window);
    return value && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
        ? (CFBooleanGetValue((__bridge CFBooleanRef)value) ? 1 : 0) : -1;
}
bool setFullScreen(SavedWindow &w,bool desired,AXUIElementRef retained=nullptr) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->setFullScreen)return recoveryHooks->setFullScreen(w,desired);
#endif
    AXUIElementRef window=retained ? retained : findIdentifiedAXWindow(w,nullptr);
    if(!window)return false;
    bool changed=setFullScreenElement(window,desired);
    CGWindowID actual=0;
    id identifier=changed ? axAttribute(window,kAXIdentifierAttribute) : nil;
    bool identityOkay=w.axIdentifier.empty() || ([identifier isKindOfClass:NSString.class]
        && [identifier isEqualToString:[NSString stringWithUTF8String:w.axIdentifier.c_str()]]);
    if(changed && (!sameProcess(w) || !identityOkay
        || api().axWindow(window,&actual)!=kAXErrorSuccess || !actual)) {
        setFullScreenElement(window,!desired);
        changed=false;
    }
    if(changed && actual!=w.id) {
        uint32_t old=w.id;
        w.id=actual;
        if(!persist()) {
            setFullScreenElement(window,!desired);
            w.id=old;changed=false;
        }
    }
    if(!retained)CFRelease(window);
    return changed;
}
bool setFullScreenElement(AXUIElementRef window,bool desired) {
    if(!window)return false;
    Boolean settable=false;
    if(AXUIElementIsAttributeSettable(window,CFSTR("AXFullScreen"),&settable)!=kAXErrorSuccess
        || !settable || AXUIElementSetAttributeValue(window,CFSTR("AXFullScreen"),
            desired?kCFBooleanTrue:kCFBooleanFalse)!=kAXErrorSuccess)return false;
    for(int retry=0;retry<80;retry++) {
        id state=axAttribute(window,CFSTR("AXFullScreen"));
        if(state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
            && CFBooleanGetValue((__bridge CFBooleanRef)state)==desired)return true;
        usleep(100000);
    }
    return false;
}
uint64_t fullScreenSpaceID(const SavedWindow &w,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->fullScreenSpaceID)return recoveryHooks->fullScreenSpaceID(w);
#endif
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(w.id)]));
    uint64_t sid=membership.count==1 ? [number(membership[0]) unsignedLongLongValue] : 0;
    return sid && api().spaceType(cid,sid)==4 && windowOnDisplay(w.id,cid,w.sourceUUID) ? sid : 0;
}
bool verifiedInitialFullScreenSpace(uint64_t sid,int cid) {
    if(initialFullScreenIndex<0 || (size_t)initialFullScreenIndex>=saved.size()
        || !sid || api().spaceType(cid,sid)!=4)return false;
    const SavedWindow &w=saved[initialFullScreenIndex];
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->fullScreenSpaceID)
        return w.fullScreen && w.slot==0 && w.sourceUUID==builtinUUID
            && fullScreenSpaceID(w,cid)==sid && fullScreenMembership(w,cid);
#endif
    if(!w.fullScreen || w.slot!=0 || w.sourceUUID!=builtinUUID || !sameProcess(w)
        || !spaceOnDisplay(managed(),sid,builtinUUID)
        || !windowOnDisplay(w.id,cid,builtinUUID))return false;
    CGRect bounds={};
    if(!readCGFrame(w.id,w.pid,&bounds))return false;
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(w.id)]));
    return membership.count==1 && [number(membership[0]) unsignedLongLongValue]==sid;
}
bool fullScreenMembership(const SavedWindow &w,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->fullScreenMembership)return recoveryHooks->fullScreenMembership(w);
#endif
    return fullScreenSpaceID(w,cid)!=0;
}
uint64_t ordinaryAfterExit(const SavedWindow &w,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->ordinaryAfterExit)return recoveryHooks->ordinaryAfterExit(w);
#endif
    uint64_t sid=oneWindowSpace(w.id,cid);
    return sid && windowOnDisplay(w.id,cid,w.sourceUUID) ? sid : 0;
}
bool afterExitFrame(const SavedWindow &w,CGRect *frame) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->afterExitFrame)return recoveryHooks->afterExitFrame(w,frame);
#endif
    AXUIElementRef window=findIdentifiedAXWindow(w,nullptr);
    if(!window)return false;
    bool okay=readAXFrame(window,frame);
    CFRelease(window);
    return okay;
}
bool awaitFullScreenMembership(SavedWindow &w,int cid,AXUIElementRef retained=nullptr) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->fullScreenMembership) {
        CGRect first={},second={};
        return fullScreenState(w)==1 && fullScreenMembership(w,cid)
            && afterExitFrame(w,&first) && afterExitFrame(w,&second)
            && first.size.width>=w.sourceDisplay.size.width*0.7
            && first.size.height>=w.sourceDisplay.size.height*0.7 && nearFrame(first,second);
    }
#endif
    for(int retry=0;retry<80;retry++) {
        if(retained) {
            CGWindowID current=0;
            if(!sameProcess(w) || api().axWindow(retained,&current)!=kAXErrorSuccess || !current)return false;
            if(current!=w.id) {
                uint32_t prior=w.id;w.id=current;
                if(!persist()) {w.id=prior;return false;}
            }
        }
        if(fullScreenState(w)==1 && fullScreenMembership(w,cid)) {
            CGRect first={},second={};
            if(afterExitFrame(w,&first) && first.size.width>=w.sourceDisplay.size.width*0.7
                && first.size.height>=w.sourceDisplay.size.height*0.7) {
                usleep(50000);
                if(afterExitFrame(w,&second) && nearFrame(first,second))return true;
            }
        }
        usleep(100000);
    }
    return false;
}
uint64_t awaitOrdinaryAfterExit(const SavedWindow &w,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->ordinaryAfterExit)return fullScreenState(w)==0 ? ordinaryAfterExit(w,cid) : 0;
#endif
    for(int retry=0;retry<80;retry++) {
        uint64_t sid=ordinaryAfterExit(w,cid);
        if(fullScreenState(w)==0 && sid)return sid;
        usleep(100000);
    }
    return 0;
}
bool readAXFrame(AXUIElementRef window,CGRect *frame) {
    id rawPosition=axAttribute(window,kAXPositionAttribute);
    id rawSize=axAttribute(window,kAXSizeAttribute);
    CGPoint position={};CGSize size={};
    if(!rawPosition || !rawSize
        || CFGetTypeID((__bridge CFTypeRef)rawPosition)!=AXValueGetTypeID()
        || CFGetTypeID((__bridge CFTypeRef)rawSize)!=AXValueGetTypeID()
        || !AXValueGetValue((__bridge AXValueRef)rawPosition,kAXValueTypeCGPoint,&position)
        || !AXValueGetValue((__bridge AXValueRef)rawSize,kAXValueTypeCGSize,&size))return false;
    *frame=CGRectMake(position.x,position.y,size.width,size.height);
    return std::isfinite(position.x) && std::isfinite(position.y)
        && std::isfinite(size.width) && std::isfinite(size.height) && size.width>0 && size.height>0;
}
bool readCGFrame(uint32_t wid,pid_t pid,CGRect *frame) {
    for(int inventory=0;inventory<2;inventory++) {
        NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(
            inventory ? kCGWindowListOptionAll : kCGWindowListOptionIncludingWindow,
            inventory ? kCGNullWindowID : wid));
        for(NSDictionary *info in list) {
            if([number(info[(id)kCGWindowNumber]) unsignedIntValue]!=wid
                || [number(info[(id)kCGWindowOwnerPID]) intValue]!=pid)continue;
            return CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),frame);
        }
    }
    return false;
}
bool nearFrame(CGRect a,CGRect b) {
    return fabs(a.origin.x-b.origin.x)<=2 && fabs(a.origin.y-b.origin.y)<=2
        && fabs(a.size.width-b.size.width)<=2 && fabs(a.size.height-b.size.height)<=2;
}
bool attachedFollowerGeometry(CGRect parent,CGRect child,CGPoint offset) {
    if(CGRectIsEmpty(parent) || CGRectIsEmpty(child)
        || !std::isfinite(offset.x) || !std::isfinite(offset.y)
        || child.size.width>parent.size.width || child.size.height>parent.size.height)
        return false;
    CGRect expected=CGRectMake(parent.origin.x+offset.x,parent.origin.y+offset.y,
        child.size.width,child.size.height);
    return nearFrame(expected,child)
        && CGRectContainsRect(CGRectInset(parent,-64,-64),child);
}
bool supportedAttachedFollowerSubrole(id subrole) {
    return [subrole isEqual:@"AXFloatingWindow"];
}
// AppKit's 66x20 Window Sharing badge is a child of a real standard window.
// It is not an independently placeable dialog; its verified root is journaled.
bool verifiedWindowSharingCompanion(uint32_t wid,pid_t pid,int cid,AXUIElementRef child) {
    if(!wid || pid<=0 || !cid || !child || !api().windowSpaces || !api().windowDisplay)return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    ProcessBirth birth=processBirth(pid);
    if(!app || app.terminated || !app.bundleIdentifier.length || !birth.valid()
        || ![axAttribute(child,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]
        || ![axAttribute(child,kAXSubroleAttribute) isEqual:@"AXDialog"]
        || ![axAttribute(child,kAXTitleAttribute) isEqual:@"Window"]
        || ![axAttribute(child,kAXIdentifierAttribute) isEqual:@"_NS:8"])return false;
    for(CFStringRef key : {kAXModalAttribute,kAXMainAttribute,kAXFocusedAttribute}) {
        id value=axAttribute(child,key);
        if(!value || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
            || CFBooleanGetValue((__bridge CFBooleanRef)value))return false;
    }
    NSArray *children=array(axAttribute(child,kAXChildrenAttribute));
    if(children.count!=1 || CFGetTypeID((__bridge CFTypeRef)children[0])!=AXUIElementGetTypeID())return false;
    AXUIElementRef button=(__bridge AXUIElementRef)children[0];
    if(![axAttribute(button,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXButtonRole]
        || ![axAttribute(button,kAXTitleAttribute) isEqual:@"WindowSharingSessionButton"])return false;
    NSDictionary *cg=windowLayerDescription(wid);CGRect childCG={},childAX={},rootCG={},rootAX={};
    uint64_t tags=0;bool known=false,rootKnown=false;
    uint32_t parent=exactWindowParent(cid,wid,&known);
    uint32_t rootParent=parent ? exactWindowParent(cid,parent,&rootKnown) : 0;
    if(!cg || !known || !parent || !rootKnown || rootParent || parent==wid
        || [number(cg[(id)kCGWindowOwnerPID]) intValue]!=pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
        || ![cg[(id)kCGWindowName] isEqual:@"Window"]
        || !readCGFrame(wid,pid,&childCG) || !readAXFrame(child,&childAX)
        || childCG.size.width!=66 || childCG.size.height!=20
        || !nearFrame(childCG,childAX) || !exactWindowTags(cid,wid,&tags)
        || tags!=0x20000001000c2080ULL)return false;
    AXUIElementRef root=findAXWindow(pid,parent);
    NSArray *childSpaces=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    NSArray *rootSpaces=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(parent)]));
    NSString *childDisplay=CFBridgingRelease(api().windowDisplay(cid,wid));
    NSString *rootDisplay=CFBridgingRelease(api().windowDisplay(cid,parent));
    bool exact=root && [axAttribute(root,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]
        && [axAttribute(root,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && readAXFrame(root,&rootAX) && readCGFrame(parent,pid,&rootCG)
        && nearFrame(rootAX,rootCG) && CGRectContainsRect(rootCG,childCG)
        && childSpaces.count==1 && rootSpaces.count==1 && [childSpaces[0] isEqual:rootSpaces[0]]
        && childDisplay.length && [childDisplay isEqual:rootDisplay]
        && birth==processBirth(pid);
    if(root)CFRelease(root);
    return exact;
}
// Only the AppKit AXFloatingWindow subtype has passed a separate-process AX
// parent-move and exact reverse test. AXSystemDialog stays fail-closed.
bool inspectAttachedFollower(uint32_t wid,pid_t pid,int cid,AXUIElementRef child,
                             uint32_t *parentID,CGPoint *offset,CGRect *childFrame=nullptr,
                             bool requireContainedGeometry=true) {
    if(!wid || pid<=0 || !cid || !child || !api().windowSpaces || !api().windowDisplay)
        return false;
    id role=axAttribute(child,kAXRoleAttribute),subrole=axAttribute(child,kAXSubroleAttribute);
    if(![role isEqual:(__bridge NSString *)kAXWindowRole]
        || !supportedAttachedFollowerSubrole(subrole))return false;
    bool known=false;uint32_t parent=exactWindowParent(cid,wid,&known);
    bool rootKnown=false;uint32_t rootParent=parent
        ? exactWindowParent(cid,parent,&rootKnown) : 0;
    if(!known || !parent || parent==wid || !rootKnown || rootParent!=0)return false;
    AXUIElementRef root=findAXWindow(pid,parent);
    if(!root)return false;
    Boolean position=false;CGRect rootAX={},rootCG={},childAX={},childCG={};
    NSArray *own=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    NSArray *owner=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(parent)]));
    NSString *ownDisplay=CFBridgingRelease(api().windowDisplay(cid,wid));
    NSString *ownerDisplay=CFBridgingRelease(api().windowDisplay(cid,parent));
    bool okay=[axAttribute(root,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]
        && [axAttribute(root,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && AXUIElementIsAttributeSettable(root,kAXPositionAttribute,&position)==kAXErrorSuccess
        && position && readAXFrame(root,&rootAX) && readCGFrame(parent,pid,&rootCG)
        && readAXFrame(child,&childAX) && readCGFrame(wid,pid,&childCG)
        && nearFrame(rootAX,rootCG) && nearFrame(childAX,childCG)
        && own.count==1 && owner.count==1 && [own[0] isEqual:owner[0]]
        && ownDisplay.length && [ownDisplay isEqual:ownerDisplay];
    CGPoint relative=CGPointMake(childCG.origin.x-rootCG.origin.x,
        childCG.origin.y-rootCG.origin.y);
    okay=okay && std::isfinite(relative.x) && std::isfinite(relative.y)
        && !CGRectIsEmpty(rootCG) && !CGRectIsEmpty(childCG)
        && (!requireContainedGeometry
            || attachedFollowerGeometry(rootCG,childCG,relative));
    CFRelease(root);
    if(okay) {
        if(parentID)*parentID=parent;
        if(offset)*offset=relative;
        if(childFrame)*childFrame=childAX;
    }
    return okay;
}
bool journaledAttachedFollowerIdentity(const SavedWindow &w,bool requireOriginalOffset,
                                       CGRect *observedAXFrame=nullptr) {
    if(!w.followerParent || !w.frameFromAX || w.fullScreen || w.cgOnly || w.readOnlyCG
        || w.axDialog || !sameProcess(w))return false;
    ProcessBirth birth=processBirth(w.pid);
    if(!birth.valid() || birth.seconds!=w.birthSeconds
        || birth.microseconds!=w.birthMicroseconds)return false;
    auto parent=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &entry) {
        return entry.id==w.followerParent && entry.pid==w.pid;
    });
    if(parent==saved.end() || parent->followerParent || parent->cgOnly || parent->readOnlyCG
        || parent->space!=w.space || parent->slot!=w.slot
        || parent->sourceUUID!=w.sourceUUID || parent->memberships!=w.memberships
        || !nearFrame(parent->sourceDisplay,w.sourceDisplay)
        || fabs(parent->launchTime-w.launchTime)>1
        || parent->birthSeconds!=w.birthSeconds
        || parent->birthMicroseconds!=w.birthMicroseconds)return false;
    AXUIElementRef child=findAXWindow(w.pid,w.id);
    int cid=api().conn ? api().conn() : 0;
    uint32_t observedParent=0;CGPoint observedOffset={};CGRect observedFrame={};
    bool okay=child && inspectAttachedFollower(w.id,w.pid,cid,child,
        &observedParent,&observedOffset,&observedFrame,requireOriginalOffset)
        && observedParent==w.followerParent
        && (!requireOriginalOffset
            || (fabs(observedOffset.x-w.followerOffset.x)<=2
                && fabs(observedOffset.y-w.followerOffset.y)<=2));
    if(child)CFRelease(child);
    if(okay && observedAXFrame)*observedAXFrame=observedFrame;
    return okay;
}
bool exactJournaledAttachedFollower(const SavedWindow &w) {
    return journaledAttachedFollowerIdentity(w,true);
}
bool exactRootAXDialog(AXUIElementRef ax,uint32_t wid,pid_t pid,int cid,CGRect *frame=nullptr) {
    if(!ax || !wid || pid<=0 || !cid)return false;
    id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
    id modal=axAttribute(ax,CFSTR("AXModal"));
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    bool premiereLayoutDialog=app && !app.terminated
        && [app.bundleIdentifier isEqual:@"com.adobe.PremierePro.26"]
        && [role isEqual:@"AXLayoutArea"];
    Boolean position=false,size=false;
    CFTypeRef parent=nullptr;
    AXError parentStatus=AXUIElementCopyAttributeValue(ax,kAXParentAttribute,&parent);
    pid_t parentPID=0;
    bool axParent=parentStatus==kAXErrorSuccess && parent
        && CFGetTypeID(parent)==AXUIElementGetTypeID()
        && [axAttribute((AXUIElementRef)parent,kAXRoleAttribute)
            isEqual:(__bridge NSString *)kAXApplicationRole]
        && AXUIElementGetPid((AXUIElementRef)parent,&parentPID)==kAXErrorSuccess
        && parentPID==pid;
    if(parent)CFRelease(parent);
    bool parentKnown=false;uint32_t cgParent=exactWindowParent(cid,wid,&parentKnown);
    CGRect axFrame={},cgFrame={};
    NSDictionary *cg=windowLayerDescription(wid);
    bool axFrameKnown=readAXFrame(ax,&axFrame),cgFrameKnown=readCGFrame(wid,pid,&cgFrame);
    uint64_t tags=0;
    bool premiereSurface=!premiereLayoutDialog || (exactWindowTags(cid,wid,&tags)
        && premiereDialogWindowTags(tags) && cg
        && stableTitledCGSurface(cg,wid,pid,cgFrame));
    bool exact=([role isEqual:(__bridge NSString *)kAXWindowRole] || premiereLayoutDialog)
        && [subrole isEqual:@"AXDialog"] && modal
        && CFGetTypeID((__bridge CFTypeRef)modal)==CFBooleanGetTypeID()
        && !CFBooleanGetValue((__bridge CFBooleanRef)modal)
        && axParent && parentKnown && cgParent==0
        && AXUIElementIsAttributeSettable(ax,kAXPositionAttribute,&position)==kAXErrorSuccess
        && position && AXUIElementIsAttributeSettable(ax,kAXSizeAttribute,&size)==kAXErrorSuccess
        && size && axFrameKnown && cgFrameKnown
        && nearFrame(axFrame,cgFrame) && cg && premiereSurface
        && (!premiereLayoutDialog || CGRectEqualToRect(axFrame,cgFrame))
        && [number(cg[(id)kCGWindowOwnerPID]) intValue]==pid
        && [number(cg[(id)kCGWindowLayer]) intValue]==0
        && [number(cg[(id)kCGWindowAlpha]) doubleValue]==1;
    if(exact && frame)*frame=axFrame;
    return exact;
}
bool exactJournaledAXDialog(const SavedWindow &w) {
    if(!w.axDialog || !w.frameFromAX || w.fullScreen || w.cgOnly || w.readOnlyCG
        || !sameProcess(w) || !w.birthSeconds || w.birthMicroseconds>=1000000)return false;
    ProcessBirth birth=processBirth(w.pid);
    if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)return false;
    int cid=api().conn ? api().conn() : 0;
    AXUIElementRef ax=findAXWindow(w.pid,w.id);
    bool exact=exactRootAXDialog(ax,w.id,w.pid,cid);
    if(ax)CFRelease(ax);
    NSArray *members=exact && api().windowSpaces ? CFBridgingRelease(api().windowSpaces(
        cid,0x7,(__bridge CFArrayRef)@[@(w.id)])) : nil;
    uint64_t sid=members.count==1 ? [number(members[0]) unsignedLongLongValue] : 0;
    return exact && sid && (sid==w.space || (w.slot>=0 && w.slot<3 && sid==slots[w.slot]))
        && api().spaceType && api().spaceType(cid,sid)==0;
}
bool exactConvertedAXDialog(const SavedWindow &w) {
    // Some Electron apps replace a saved dialog with a standard window while
    // retaining its CG identity. Accept that app-directed conversion only at
    // the exact original frame, Space, display, and process identity.
    if(!w.axDialog || !w.frameFromAX || !sameProcess(w)
        || !(processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds}))return false;
    int cid=api().conn ? api().conn() : 0;
    if(!cid || oneWindowSpace(w.id,cid)!=w.space
        || !windowOnDisplay(w.id,cid,w.sourceUUID))return false;
    AXUIElementRef ax=findAXWindow(w.pid,w.id);
    id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
    id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
    CGRect axFrame={},cgFrame={};bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,w.id,&parentKnown);
    NSDictionary *cg=windowLayerDescription(w.id);
    bool exact=ax && [role isEqual:(__bridge NSString *)kAXWindowRole]
        && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && readAXFrame(ax,&axFrame) && readCGFrame(w.id,w.pid,&cgFrame)
        && nearFrame(axFrame,w.frame) && nearFrame(cgFrame,w.frame)
        && parentKnown && parent==0 && cg
        && [number(cg[(id)kCGWindowLayer]) intValue]==0
        && [number(cg[(id)kCGWindowAlpha]) doubleValue]==1
        && [[NSString stringWithUTF8String:w.title.c_str()] isEqual:cg[(id)kCGWindowName]];
    if(ax)CFRelease(ax);
    return exact;
}
bool journalableAXFrame(NSString *bundle,id role,id subrole,CGRect axFrame,CGRect cgFrame,
                        bool positionSettable,bool sizeSettable,CGRect builtinContent,
                        bool stableCG,bool verifiedDialog=false) {
    if([bundle isEqual:@"com.adobe.AfterEffects.application"]
        && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXFloatingWindow"])
        return positionSettable && sizeSettable && stableCG && CGRectEqualToRect(axFrame,cgFrame);
    if([bundle isEqual:@"com.adobe.PremierePro.26"]
        && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXDialog"])
        return positionSettable && sizeSettable && verifiedDialog && stableCG
            && CGRectEqualToRect(axFrame,cgFrame);
    if(![role isEqual:(__bridge NSString *)kAXWindowRole] || !positionSettable)return false;
    if(!sizeSettable && (CGRectIsNull(builtinContent)
        || axFrame.size.width>builtinContent.size.width
        || axFrame.size.height>builtinContent.size.height))return false;
    if([subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole])return true;
    if([subrole isEqual:@"AXDialog"] && sizeSettable && verifiedDialog)return true;
    return [bundle isEqual:@"com.google.Chrome"]
        && [subrole isEqual:@"AXUnknown"] && !sizeSettable
        && CGRectEqualToRect(axFrame,cgFrame) && stableCG;
}
bool exactFinderJournal(const SavedWindow &w) {
    return w.cgOnly && !w.frameFromAX && !w.readOnlyCG && !w.fullScreen
        && w.bundle=="com.apple.finder" && !w.title.empty()
        && w.surfaceTags==0x200000100482001ULL && w.memberships.size()==1
        && w.memberships[0]==w.space && w.birthSeconds
        && w.birthMicroseconds<1000000;
}
bool finderIntegerFrame(CGRect f) {
    return std::isfinite(f.origin.x) && std::isfinite(f.origin.y)
        && std::isfinite(f.size.width) && std::isfinite(f.size.height)
        && f.size.width>0 && f.size.height>0
        && floor(f.origin.x)==f.origin.x && floor(f.origin.y)==f.origin.y
        && floor(f.size.width)==f.size.width && floor(f.size.height)==f.size.height
        && fabs(f.origin.x)<100000 && fabs(f.origin.y)<100000
        && f.size.width<100000 && f.size.height<100000;
}
NSString *finderBoundsText(CGRect f) {
    return [NSString stringWithFormat:@"{%lld, %lld, %lld, %lld}",
        (long long)f.origin.x,(long long)f.origin.y,
        (long long)(f.origin.x+f.size.width),(long long)(f.origin.y+f.size.height)];
}
bool finderAppleBounds(const SavedWindow &w,CGRect *frame,
                       const CGRect *expected=nullptr,const CGRect *target=nullptr) {
    if(!exactFinderJournal(w) || !signedSystemFinderExecutable(w.pid)
        || !sameProcess(w) || !finderIntegerFrame(w.frame)
        || (expected && !finderIntegerFrame(*expected))
        || (target && !finderIntegerFrame(*target)) || bool(expected)!=bool(target))return false;
    NSString *title=[NSString stringWithUTF8String:w.title.c_str()];
    if(!title || [title rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound)
        return false;
    NSString *escaped=[[title stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSMutableString *source=[NSMutableString stringWithFormat:
        @"tell application id \"com.apple.finder\"\nwith timeout of 5 seconds\n"
         "set f to first Finder window whose id is %u\n"
         "if id of f is not %u or name of f is not \"%@\" then error \"Finder identity changed\"\n",
        w.id,w.id,escaped];
    if(expected) [source appendFormat:@"if bounds of f is not %@ then error \"Finder bounds changed\"\n"
        "set bounds of f to %@\n",finderBoundsText(*expected),finderBoundsText(*target)];
    [source appendString:@"return {id of f, name of f, bounds of f}\nend timeout\nend tell"];
    NSDictionary *failure=nil;
    NSAppleScript *script=[[NSAppleScript alloc] initWithSource:source];
    NSAppleEventDescriptor *answer=[script executeAndReturnError:&failure];
    if(!answer || answer.numberOfItems!=3) {
        fprintf(stderr,"air_finder_apple_events wid=%u pid=%d error=%s; check Host Finder Automation permission\n",
            w.id,w.pid,[[failure description] UTF8String] ?: "missing reply");
        return false;
    }
    NSAppleEventDescriptor *idReply=[answer descriptorAtIndex:1],*nameReply=[answer descriptorAtIndex:2];
    NSAppleEventDescriptor *bounds=[answer descriptorAtIndex:3];
    if(!idReply || idReply.int32Value!=(int32_t)w.id || ![nameReply.stringValue isEqualToString:title]
        || !bounds || bounds.numberOfItems!=4)return false;
    double left=[bounds descriptorAtIndex:1].int32Value,top=[bounds descriptorAtIndex:2].int32Value;
    double right=[bounds descriptorAtIndex:3].int32Value,bottom=[bounds descriptorAtIndex:4].int32Value;
    CGRect got=CGRectMake(left,top,right-left,bottom-top);
    if(frame)*frame=got;
    return finderIntegerFrame(got) && (!target || CGRectEqualToRect(got,*target));
}
bool finderIndependentWindowIdentity(bool axReadable,bool axComplete,bool mappedInAX,
                                     bool signedFinder,bool exactAppleCG) {
    // AX completeness is deliberately not required for Finder's proxy list.
    (void)axComplete;
    return axReadable && !mappedInAX && signedFinder && exactAppleCG;
}
bool journalableFinderCGWindow(NSDictionary *info,uint32_t wid,pid_t pid,
    NSString *bundle,ProcessBirth birth,CGRect cgFrame,uint64_t sid,int slot,
    const std::string &sourceUUID,CGRect sourceBounds,CGRect builtinContent,
    double launch,int cid,
    const DormantAXInventory &ax,uint64_t *surfaceTags) {
    // Finder's AXWindows list contains unmappable proxy elements. The signed
    // Finder executable plus AppleScript's exact WID/name/bounds response below
    // supplies independent identity even when AX inventory is incomplete.
    if(![bundle isEqual:@"com.apple.finder"] || !birth.valid()
        || !(ax.birth==birth) || !ax.readable || ax.windows.count(wid)
        || !signedSystemFinderExecutable(pid) || !finderIntegerFrame(cgFrame)
        || [number(info[(id)kCGWindowLayer]) intValue]!=0
        || [number(info[(id)kCGWindowAlpha]) doubleValue]!=1
        || !stableTitledCGSurface(info,wid,pid,cgFrame))return false;
    NSString *title=info[(id)kCGWindowName];
    if(![title isKindOfClass:NSString.class] || !title.length || slot<0 || slot>2
        || CGRectIsNull(builtinContent)
        || cgFrame.size.width>builtinContent.size.width
        || cgFrame.size.height>builtinContent.size.height)return false;
    bool parentKnown=false;uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    uint64_t tags=0;
    if(!parentKnown || parent || !exactWindowTags(cid,wid,&tags)
        || tags!=0x200000100482001ULL)return false;
    SavedWindow proposed={wid,pid,bundle.UTF8String,title.UTF8String,cgFrame,
        sourceBounds,launch,sid,slot,sourceUUID,false};
    proposed.cgOnly=true;proposed.birthSeconds=birth.seconds;
    proposed.birthMicroseconds=birth.microseconds;proposed.memberships={sid};
    proposed.surfaceTags=tags;
    CGRect apple={};
    bool appleExact=finderAppleBounds(proposed,&apple) && CGRectEqualToRect(apple,cgFrame);
    if(!finderIndependentWindowIdentity(ax.readable,ax.complete,ax.windows.count(wid),
            signedSystemFinderExecutable(pid),appleExact)
        || !windowOnDisplay(wid,cid,sourceUUID))return false;
    if(surfaceTags)*surfaceTags=tags;
    return true;
}
bool exactCGOnlyWindow(const SavedWindow &w,CGRect *frame=nullptr) {
    if(!w.cgOnly || w.fullScreen || !w.birthSeconds || w.birthMicroseconds>=1000000
        || !sameProcess(w))return false;
    ProcessBirth birth=processBirth(w.pid);
    if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)return false;
    int cid=api().conn ? api().conn() : 0;
    NSDictionary *cg=windowLayerDescription(w.id);CGRect live={};
    if(!cg || [number(cg[(id)kCGWindowOwnerPID]) intValue]!=w.pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&live)
        || !std::isfinite(live.origin.x) || !std::isfinite(live.origin.y)
        || live.size.width!=w.frame.size.width || live.size.height!=w.frame.size.height
        || !(exactFinderJournal(w) ? stableTitledCGSurface(cg,w.id,w.pid,live)
            : w.bundle=="com.lujjjh.LinearMouse" && w.title=="LinearMouse"
            ? stableTitledLinearMouseSurface(cg,w.id,w.pid,live,cid)
            : stableCGSurface(cg,w.id,w.pid,live)))return false;
    if(exactFinderJournal(w)) {
        uint64_t tags=0;CGRect apple={};
        if(!exactWindowTags(cid,w.id,&tags) || tags!=w.surfaceTags
            || !finderAppleBounds(w,&apple) || !CGRectEqualToRect(apple,live)
            || !signedSystemFinderExecutable(w.pid))return false;
    }
    NSArray *membership=cid && api().windowSpaces ? CFBridgingRelease(api().windowSpaces(
        cid,0x7,(__bridge CFArrayRef)@[@(w.id)])) : nil;
    uint64_t sid=0;
    if(w.memberships.size()>1) {
        std::vector<uint64_t> live;
        if(!membership || membership.count!=w.memberships.size())return false;
        for(id value in membership) {
            NSNumber *raw=number(value);
            if(!raw || !raw.unsignedLongLongValue)return false;
            live.push_back(raw.unsignedLongLongValue);
        }
        std::sort(live.begin(),live.end());
        if(live!=w.memberships)return false;
        sid=w.space;
    } else sid=membership.count==1 ? [number(membership[0]) unsignedLongLongValue] : 0;
    if(!sid || (sid!=w.space && sid!=slots[w.slot])
        || api().spaceType(cid,sid)!=0)return false;
    if(frame)*frame=live;
    return true;
}
bool windowOnDisplay(uint32_t wid,int cid,const std::string &uuid);
bool spaceOnDisplay(NSArray *all,uint64_t sid,const std::string &uuid);
struct FinderRestoreEvidence {
    bool journal=false,process=false,signedProcess=false,stableCG=false;
    bool parentRoot=false,exactTags=false,ordinaryMembership=false;
    bool expectedDisplay=false,exactAppleBounds=false;
};
bool finderRestoreDecision(const FinderRestoreEvidence &e,
                           const std::string &journaledTitle,NSString *currentTitle,
                           CGRect current) {
    return e.journal && e.process && e.signedProcess && e.stableCG
        && e.parentRoot && e.exactTags && e.ordinaryMembership
        && e.expectedDisplay && e.exactAppleBounds && !journaledTitle.empty()
        && [currentTitle isKindOfClass:NSString.class] && currentTitle.length
        && finderIntegerFrame(current);
}
bool finderForwardRollbackCandidate(CGRect before,CGRect target,CGRect observed) {
    return finderIntegerFrame(before) && finderIntegerFrame(target)
        && finderIntegerFrame(observed) && !CGRectEqualToRect(observed,before)
        && CGRectIntersectsRect(observed,target);
}
bool finderRollbackSpaceDecision(uint64_t observed,uint64_t original,
                                 uint64_t selected,bool spaceOnActualDisplay) {
    return observed && (observed==original || (selected && observed==selected))
        && spaceOnActualDisplay;
}
bool finderCurrentIdentity(const SavedWindow &w,bool originalSpace,
                           CGRect *frame,std::string *currentTitle=nullptr,
                           bool immediateRollback=false) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->windowState) {
        if(frame)*frame=w.frame;
        if(currentTitle)*currentTitle=w.title;
        return recoveryHooks->windowState(w)==1; // WindowState::Ready
    }
#endif
    if(!exactFinderJournal(w) || !sameProcess(w) || !signedSystemFinderExecutable(w.pid))return false;
    ProcessBirth birth=processBirth(w.pid);
    if(!birth.valid() || birth.seconds!=w.birthSeconds
        || birth.microseconds!=w.birthMicroseconds)return false;
    int cid=api().conn ? api().conn() : 0;
    NSDictionary *cg=windowLayerDescription(w.id);CGRect live={};
    NSString *title=cg[(id)kCGWindowName];
    if(!cid || !cg || [number(cg[(id)kCGWindowOwnerPID]) intValue]!=w.pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
        || ![title isKindOfClass:NSString.class] || !title.length
        || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&live)
        || !finderIntegerFrame(live) || !stableTitledCGSurface(cg,w.id,w.pid,live))return false;
    bool parentKnown=false;uint32_t parent=exactWindowParent(cid,w.id,&parentKnown);
    uint64_t tags=0,sid=oneWindowSpace(w.id,cid);
    if(!parentKnown || parent || !exactWindowTags(cid,w.id,&tags)
        || tags!=w.surfaceTags || !sid || !api().spaceType
        || api().spaceType(cid,sid)!=0
        || (originalSpace ? sid!=w.space || !spaceOnDisplay(managed(),w.space,w.sourceUUID)
            : sid!=w.space && sid!=slots[w.slot]))return false;
    NSString *actualDisplay=api().windowDisplay
        ? CFBridgingRelease(api().windowDisplay(cid,w.id)) : nil;
    bool sourceDisplay=actualDisplay && [actualDisplay isEqualToString:
        [NSString stringWithUTF8String:w.sourceUUID.c_str()]];
    bool selectedDisplay=actualDisplay && [actualDisplay isEqualToString:
        [NSString stringWithUTF8String:builtinUUID.c_str()]];
    if(!sourceDisplay && !selectedDisplay)return false;
    bool matchedDisplay=actualDisplay && spaceOnDisplay(managed(),sid,actualDisplay.UTF8String);
    if(immediateRollback && !finderRollbackSpaceDecision(
        sid,w.space,slots[w.slot],matchedDisplay))return false;
    SavedWindow observed=w;observed.title=title.UTF8String;
    CGRect apple={};
    bool appleExact=finderAppleBounds(observed,&apple) && CGRectEqualToRect(apple,live);
    FinderRestoreEvidence evidence;
    evidence.journal=exactFinderJournal(w);
    evidence.process=sameProcess(w) && birth.seconds==w.birthSeconds
        && birth.microseconds==w.birthMicroseconds;
    evidence.signedProcess=signedSystemFinderExecutable(w.pid);
    evidence.stableCG=true;evidence.parentRoot=parentKnown && parent==0;
    evidence.exactTags=tags==w.surfaceTags;
    evidence.ordinaryMembership=originalSpace ? sid==w.space
        : sid==w.space || sid==slots[w.slot];
    evidence.expectedDisplay=!immediateRollback || matchedDisplay;
    evidence.exactAppleBounds=appleExact;
    if(!finderRestoreDecision(evidence,w.title,title,live))return false;
    if(frame)*frame=live;
    if(currentTitle)*currentTitle=observed.title;
    return true;
}
bool restoreFinderFrame(const SavedWindow &w) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->frame)return recoveryHooks->frame(w);
#endif
    CGRect current={};std::string title;
    if(!finderCurrentIdentity(w,true,&current,&title))return false;
    if(!CGRectEqualToRect(current,w.frame)) {
        SavedWindow observed=w;observed.title=title;
        CGRect replied={};
        bool exactReply=finderAppleBounds(observed,&replied,&current,&w.frame);
        if(!exactReply) {
            // Finder may clamp a set-bounds request after applying it. Retry
            // only from its newly verified exact ID, title, bounds and Space.
            CGRect after={};std::string afterTitle;
            if(!finderCurrentIdentity(w,true,&after,&afterTitle))return false;
            observed.title=afterTitle;
            if(!CGRectEqualToRect(after,w.frame)
                && !finderAppleBounds(observed,&replied,&after,&w.frame))return false;
        }
    }
    for(int retry=0;retry<20;retry++) {
        CGRect restored={};
        if(finderCurrentIdentity(w,true,&restored)
            && CGRectEqualToRect(restored,w.frame)
            && windowOnDisplay(w.id,api().conn(),w.sourceUUID))return true;
        usleep(25000);
    }
    return false;
}
bool premiereDialogMutationGate(NSString *actualBundle,id role,id subrole,
                                const SavedWindow &w) {
    if(![actualBundle isEqual:@"com.adobe.PremierePro.26"]
        || ![role isEqual:@"AXLayoutArea"] || ![subrole isEqual:@"AXDialog"])return true;
    return w.axDialog && w.frameFromAX && !w.cgOnly && !w.readOnlyCG
        && w.bundle=="com.adobe.PremierePro.26";
}
bool cgOnlyFrameRestorableBundle(NSString *bundle) {
    // Premiere's AX-less progress/dialog surface can resemble a stable CG
    // window, but setFrame cannot restore its position without the AX element.
    return ![bundle isEqualToString:@"com.adobe.PremierePro.26"];
}
bool setFrame(const SavedWindow &w,CGRect frame) {
    if(w.followerParent)return false;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->frameAt)return recoveryHooks->frameAt(w,frame);
#endif
    if(w.cgOnly) {
        if(!cgOnlyFrameRestorableBundle(
            [NSString stringWithUTF8String:w.bundle.c_str()]))return false;
        if(w.bundle=="com.apple.finder" && !exactFinderJournal(w))return false;
        CGRect current={};
        bool finder=exactFinderJournal(w);
        if((!finder && !api().moveWindow) || !exactCGOnlyWindow(w,&current)
            || frame.size.width!=w.frame.size.width || frame.size.height!=w.frame.size.height)return false;
        if(CGRectEqualToRect(current,frame))return true;
        if(finder) {
            auto rollback=[&]() {
                CGRect observed={};std::string currentTitle;
                if(!finderCurrentIdentity(w,false,&observed,&currentTitle,true))return false;
                if(CGRectEqualToRect(observed,current))return true;
                if(!finderForwardRollbackCandidate(current,frame,observed))return false;
                SavedWindow exact=w;exact.title=currentTitle;
                CGRect reply={};
                finderAppleBounds(exact,&reply,&observed,&current);
                CGRect restored={};
                return finderCurrentIdentity(w,false,&restored,nullptr,true)
                    && CGRectEqualToRect(restored,current);
            };
            CGRect replied={};
            if(!finderAppleBounds(w,&replied,&current,&frame)) {
                if(!rollback())fprintf(stderr,"air_finder_forward_rollback_incomplete wid=%u pid=%d\n",w.id,w.pid);
                return false;
            }
            for(int retry=0;retry<20;retry++) {
                CGRect got={};
                if(exactCGOnlyWindow(w,&got) && CGRectEqualToRect(got,frame))return true;
                usleep(25000);
            }
            if(!rollback())fprintf(stderr,"air_finder_forward_rollback_incomplete wid=%u pid=%d\n",w.id,w.pid);
            return false;
        }
        CGPoint target=frame.origin;
        if(api().moveWindow(api().conn(),w.id,&target)!=kCGErrorSuccess)return false;
        for(int retry=0;retry<20;retry++) {
            CGRect got={};
            if(exactCGOnlyWindow(w,&got) && nearFrame(got,frame))return true;
            usleep(25000);
        }
        return false;
    }
    AXUIElementRef window=findAXWindow(w.pid,w.id);
    if(!window) return false;
    NSRunningApplication *actualApp=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
    if(!premiereDialogMutationGate(actualApp && !actualApp.terminated
            ? actualApp.bundleIdentifier : nil,axAttribute(window,kAXRoleAttribute),
            axAttribute(window,kAXSubroleAttribute),w)
        || (w.axDialog && !exactJournaledAXDialog(w))) {
        CFRelease(window);return false;
    }
    CGRect wanted=frame;
    if(!w.frameFromAX) {
        // Version 2 journals contain CoreGraphics bounds, which can differ
        // from Accessibility's frame by a few title-bar/border pixels.
        CGRect currentAX={},currentCG={};
        if(!readAXFrame(window,&currentAX) || !readCGFrame(w.id,w.pid,&currentCG)) {
            CFRelease(window);return false;
        }
        wanted.origin.x+=currentAX.origin.x-currentCG.origin.x;
        wanted.origin.y+=currentAX.origin.y-currentCG.origin.y;
        wanted.size.width+=currentAX.size.width-currentCG.size.width;
        wanted.size.height+=currentAX.size.height-currentCG.size.height;
    }
    CGPoint p=wanted.origin;CGSize s=wanted.size;
    AXValueRef pos=AXValueCreate(kAXValueTypeCGPoint,&p),size=AXValueCreate(kAXValueTypeCGSize,&s);
    CGRect currentAX={};
    if(!readAXFrame(window,&currentAX)) {
        CFRelease(pos);CFRelease(size);CFRelease(window);return false;
    }
    bool sameSize=CGSizeEqualToSize(currentAX.size,wanted.size);
    Boolean sizeSettable=false;
    if(!sameSize && (AXUIElementIsAttributeSettable(window,kAXSizeAttribute,&sizeSettable)
        !=kAXErrorSuccess || !sizeSettable)) {
        CFRelease(pos);CFRelease(size);CFRelease(window);return false;
    }
    id role=axAttribute(window,kAXRoleAttribute),subrole=axAttribute(window,kAXSubroleAttribute);
    bool chromeUnknown=w.bundle=="com.google.Chrome"
        && [role isEqual:(__bridge NSString *)kAXWindowRole]
        && [subrole isEqual:@"AXUnknown"];
    bool afterEffectsFloating=w.bundle=="com.adobe.AfterEffects.application"
        && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXFloatingWindow"];
    bool premiereLayoutDialog=w.bundle=="com.adobe.PremierePro.26"
        && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXDialog"] && w.axDialog;
    if(chromeUnknown || afterEffectsFloating || premiereLayoutDialog) {
        CGRect currentCG={};ProcessBirth birth=processBirth(w.pid);
        if(!w.frameFromAX || !birth.valid() || birth.seconds!=w.birthSeconds
            || birth.microseconds!=w.birthMicroseconds
            || !readCGFrame(w.id,w.pid,&currentCG)
            || !CGRectEqualToRect(currentAX,currentCG)) {
            CFRelease(pos);CFRelease(size);CFRelease(window);return false;
        }
    }
    AXError a=AXUIElementSetAttributeValue(window,kAXPositionAttribute,pos);
    AXError b=sameSize ? kAXErrorSuccess
        : AXUIElementSetAttributeValue(window,kAXSizeAttribute,size);
    bool verified=false;
    for(int retry=0;retry<20 && a==kAXErrorSuccess && b==kAXErrorSuccess;retry++) {
        CGRect got={};verified=readAXFrame(window,&got) && nearFrame(got,wanted);
        if(chromeUnknown || afterEffectsFloating || premiereLayoutDialog) {
            CGRect cg={};verified=verified && readCGFrame(w.id,w.pid,&cg)
                && nearFrame(cg,wanted) && nearFrame(cg,got);
        }
        if(!w.frameFromAX) {
            CGRect cg={};verified=verified && readCGFrame(w.id,w.pid,&cg) && nearFrame(cg,frame);
        }
        if(verified && w.axDialog)verified=exactJournaledAXDialog(w);
        if(verified)break;
        usleep(25000);
    }
    CFRelease(pos);CFRelease(size);CFRelease(window);
    return a==kAXErrorSuccess && b==kAXErrorSuccess && verified;
}
bool setFrame(const SavedWindow &w) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->frame)return recoveryHooks->frame(w);
#endif
    return setFrame(w,w.frame);
}
bool readWindowMinimized(AXUIElementRef window,bool *minimized) {
    id value=window ? axAttribute(window,kAXMinimizedAttribute) : nil;
    if(!value || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID())return false;
    if(minimized)*minimized=[value boolValue];
    return true;
}
bool setWindowMinimizedState(const SavedWindow &w,bool desired) {
    if(!w.minimizedKnown)return true;
    AXUIElementRef window=findAXWindow(w.pid,w.id);
    bool current=false;
    if(!window || !readWindowMinimized(window,&current)) {
        if(window)CFRelease(window);
        return false;
    }
    if(current!=desired && AXUIElementSetAttributeValue(window,kAXMinimizedAttribute,
        desired ? kCFBooleanTrue : kCFBooleanFalse)!=kAXErrorSuccess) {
        CFRelease(window);return false;
    }
    bool verified=false;
    for(int retry=0;retry<20;retry++) {
        if(readWindowMinimized(window,&current) && current==desired){verified=true;break;}
        usleep(25000);
    }
    CFRelease(window);return verified;
}
bool restoreWindowMinimized(const SavedWindow &w) {
    return setWindowMinimizedState(w,w.minimized);
}
enum class WindowState { Gone, Ready, AXUnavailable };
bool closedFullScreenWindowDecision(int fullScreenPhase,bool completeAXInventory,bool matchingAXWindow,
                                    bool cgSurfacePresent,bool spaceMembershipPresent) {
    // After this Host changes full-screen state, the app can replace its CG
    // window ID.  Missing evidence for the old ID cannot prove user closure.
    return fullScreenPhase==1 && completeAXInventory && !matchingAXWindow && !cgSurfacePresent
        && !spaceMembershipPresent;
}
bool fullScreenProcessGoneDecision(bool sameProcessIdentity,bool provenReplacement,
                                   bool processDead,bool exactWindowAbsent) {
    return !sameProcessIdentity && (provenReplacement || (processDead && exactWindowAbsent));
}
bool closedFullScreenWindow(const SavedWindow &w,int cid) {
    if(!cid || !api().axWindow || !api().windowSpaces)return false;
    AXUIElementRef application=AXUIElementCreateApplication(w.pid);
    if(!application)return false;
    AXUIElementSetMessagingTimeout(application,0.5);
    CFTypeRef raw=nullptr;
    AXError status=AXUIElementCopyAttributeValue(application,kAXWindowsAttribute,&raw);
    CFRelease(application);
    if(status!=kAXErrorSuccess || !raw || CFGetTypeID(raw)!=CFArrayGetTypeID()) {
        if(raw)CFRelease(raw);return false;
    }
    bool complete=true,matching=false;
    for(id item in (__bridge NSArray *)raw) {
        AXUIElementRef element=(__bridge AXUIElementRef)item;
        CGWindowID wid=0;
        if(api().axWindow(element,&wid)!=kAXErrorSuccess || !wid) {
            complete=false;break;
        }
        NSString *identifier=axAttribute(element,kAXIdentifierAttribute);
        if(wid==w.id || (!w.axIdentifier.empty()
            && [identifier isKindOfClass:NSString.class]
            && [identifier isEqualToString:[NSString stringWithUTF8String:w.axIdentifier.c_str()]])) {
            matching=true;break;
        }
    }
    CFRelease(raw);
    CGRect ignored={};
    bool cgSurface=readCGFrame(w.id,w.pid,&ignored);
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,
        (__bridge CFArrayRef)@[@(w.id)]));
    return membership && closedFullScreenWindowDecision(w.fullScreenPhase,complete,matching,cgSurface,membership.count>0);
}
bool exactReadOnlyChromeSurface(const SavedWindow &w) {
    if(!w.readOnlyCG || w.cgOnly || w.fullScreen || w.frameFromAX
        || w.bundle!="com.google.Chrome" || w.surfaceTags!=0x1400c0202ULL
        || w.memberships.size()!=1 || !sameProcess(w))return false;
    ProcessBirth birth=processBirth(w.pid);
    if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)return false;
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!all)return false;
    NSDictionary *info=nil;NSUInteger count=0;
    for(NSDictionary *candidate in all)
        if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==w.id){info=candidate;count++;}
    CGRect frame={};NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
    NSString *title=info[(id)kCGWindowName];
    if(count!=1 || [number(info[(id)kCGWindowOwnerPID]) intValue]!=w.pid
        || [number(info[(id)kCGWindowLayer]) intValue]!=0
        || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)
        || !CGRectEqualToRect(frame,w.frame) || !alpha || alpha.doubleValue!=1
        || (onscreen && onscreen.boolValue)
        || ([title isKindOfClass:NSString.class] && title.length)
        || !stableAllCGSurface(info,w.id,w.pid,frame))return false;
    int cid=api().conn ? api().conn() : 0;
    uint64_t tags=0;
    bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,w.id,&parentKnown);
    DormantAXInventory ax=readDormantAXInventory(w.pid);
    return cid && ax.birth==birth && ax.readable && ax.complete && !ax.windows.count(w.id)
        && parentKnown && parent==0
        && exactWindowTags(cid,w.id,&tags) && tags==w.surfaceTags;
}
bool readOnlyChromeGoneDecision(const SavedWindow &w,ProcessBirth observed,
                                bool completeWindowAbsence) {
    // LaunchServices can temporarily lose a live app; only process replacement
    // or two complete CG/Space inventories prove this journaled surface gone.
    return (observed.valid() && (observed.seconds!=w.birthSeconds
        || observed.microseconds!=w.birthMicroseconds)) || completeWindowAbsence;
}
WindowState windowState(const SavedWindow &w) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->windowState)return (WindowState)recoveryHooks->windowState(w);
#endif
    if(w.fullScreen) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
        if(app && [app.bundleIdentifier isEqualToString:[NSString stringWithUTF8String:w.bundle.c_str()]]
            && stableLaunchTime(app,w.pid)<=0)return WindowState::AXUnavailable;
        if(!sameProcess(w)) {
            ProcessBirth observed=processBirth(w.pid);
            bool replaced=observed.valid() && (w.birthSeconds
                ? !(observed==ProcessBirth{w.birthSeconds,w.birthMicroseconds})
                : fabs(observed.seconds+observed.microseconds/1000000.0-w.launchTime)>1);
            int cid=api().conn ? api().conn() : 0;
            bool dead=kill(w.pid,0)<0 && errno==ESRCH;
            bool absent=dead && cid && ::vanishedCompleteInventoryWindow(w.id,cid,nullptr);
            return fullScreenProcessGoneDecision(false,replaced,dead,absent)
                ? WindowState::Gone : WindowState::AXUnavailable;
        }
        if(resolvedWindowID(w))return WindowState::Ready;
        int cid=api().conn ? api().conn() : 0;
        if(w.fullScreen && (w.fullScreenPhase==1 || w.fullScreenPhase==4
                || (!initialSelections.empty() && w.fullScreenPhase==3)) && cid
            && sameProcess(w) && fullScreenMembership(w,cid))
            return WindowState::Ready;
        if(closedFullScreenWindow(w,cid))return WindowState::Gone;
        return WindowState::AXUnavailable;
    }
    if(w.readOnlyCG) {
        ProcessBirth birth=processBirth(w.pid);
        if(readOnlyChromeGoneDecision(w,birth,false))return WindowState::Gone;
        if(exactReadOnlyChromeSurface(w))return WindowState::Ready;
        int cid=api().conn ? api().conn() : 0;
        bool absent=cid && ::vanishedCompleteInventoryWindow(w.id,cid,nullptr);
        return readOnlyChromeGoneDecision(w,birth,absent)
            ? WindowState::Gone : WindowState::AXUnavailable;
    }
    if(w.cgOnly) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
        bool titledLinearMouse=w.bundle=="com.lujjjh.LinearMouse" && w.title=="LinearMouse";
        if(!app || app.terminated || !sameProcess(w)) {
            if(titledLinearMouse) {
                ProcessBirth birth=processBirth(w.pid);
                if(birth.valid() && birth.seconds==w.birthSeconds
                    && birth.microseconds==w.birthMicroseconds)return WindowState::AXUnavailable;
                if(!birth.valid() && (kill(w.pid,0)==0 || errno!=ESRCH))
                    return WindowState::AXUnavailable;
            }
            return WindowState::Gone;
        }
        if(exactCGOnlyWindow(w))return WindowState::Ready;
        if(titledLinearMouse) {
            ProcessBirth birth=processBirth(w.pid);
            int cid=api().conn ? api().conn() : 0;
            if(birth.valid() && birth.seconds==w.birthSeconds
                && birth.microseconds==w.birthMicroseconds && cid
                && ::vanishedCompleteInventoryWindow(w.id,cid,nullptr))return WindowState::Gone;
        }
        return WindowState::AXUnavailable;
    }
    if(w.followerParent) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
        ProcessBirth birth=processBirth(w.pid);
        if(!birth.valid())return kill(w.pid,0)<0 && errno==ESRCH
            ? WindowState::Gone : WindowState::AXUnavailable;
        if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)
            return WindowState::Gone;
        if(!app || app.terminated || !sameProcess(w))return WindowState::AXUnavailable;
        if(exactJournaledAttachedFollower(w))return WindowState::Ready;
        DormantAXInventory ax=readDormantAXInventory(w.pid);
        int cid=api().conn ? api().conn() : 0;
        return ax.readable && ax.complete && ax.birth==birth && !ax.windows.count(w.id)
            && cid && ::vanishedCompleteInventoryWindow(w.id,cid,nullptr)
            ? WindowState::Gone : WindowState::AXUnavailable;
    }
    if(w.axDialog) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
        ProcessBirth birth=processBirth(w.pid);
        if(!birth.valid())return kill(w.pid,0)<0 && errno==ESRCH
            ? WindowState::Gone : WindowState::AXUnavailable;
        if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)
            return WindowState::Gone;
        if(!app || app.terminated || !sameProcess(w))return WindowState::AXUnavailable;
        if(exactJournaledAXDialog(w) || exactConvertedAXDialog(w))return WindowState::Ready;
        // A closed dialog is the one safe exception to exact revalidation:
        // the same app must expose a complete AX inventory without this ID,
        // and two complete CG/Space inventories must also show its absence.
        DormantAXInventory ax=readDormantAXInventory(w.pid);
        int cid=api().conn ? api().conn() : 0;
        return ax.readable && ax.complete && ax.birth==birth && !ax.windows.count(w.id)
            && cid && ::vanishedCompleteInventoryWindow(w.id,cid,nullptr)
            ? WindowState::Gone : WindowState::AXUnavailable;
    }
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
    if(!app || ![app.bundleIdentifier isEqualToString:[NSString stringWithUTF8String:w.bundle.c_str()]]) return WindowState::Gone;
    double liveLaunch=stableLaunchTime(app,w.pid);
    if(w.launchTime && liveLaunch<=0)return WindowState::AXUnavailable;
    if(w.launchTime && fabs(liveLaunch-w.launchTime)>1)return WindowState::Gone;
    AXUIElementRef application=AXUIElementCreateApplication(w.pid);
    if(!application)return WindowState::AXUnavailable;
    CFTypeRef raw=nullptr;
    AXError status=AXUIElementCopyAttributeValue(application,kAXWindowsAttribute,&raw);
    CFRelease(application);
    if(status!=kAXErrorSuccess || !raw || CFGetTypeID(raw)!=CFArrayGetTypeID()) {
        if(raw)CFRelease(raw);
        AXUIElementRef exact=findAXWindow(w.pid,w.id);
        if(exact){CFRelease(exact);return WindowState::Ready;}
        return WindowState::AXUnavailable;
    }
    bool found=false;
    for(id element in (__bridge NSArray *)raw) {
        CGWindowID wid=0;
        if(api().axWindow((__bridge AXUIElementRef)element,&wid)==kAXErrorSuccess && wid==w.id) {
            found=true;break;
        }
    }
    CFRelease(raw);
    if(found)return WindowState::Ready;
    AXUIElementRef exact=findAXWindow(w.pid,w.id);
    if(exact){CFRelease(exact);return WindowState::Ready;}
    CGRect ignored={};
    return readCGFrame(w.id,w.pid,&ignored) ? WindowState::AXUnavailable : WindowState::Gone;
}
NSDictionary *serialize(const SavedWindow &w,bool includeFollower=false) {
    NSMutableArray *memberships=NSMutableArray.array;
    for(uint64_t sid:w.memberships)[memberships addObject:@(sid)];
    NSDictionary *record=@{@"id":@(w.id),@"pid":@(w.pid),@"bundle":[NSString stringWithUTF8String:w.bundle.c_str()],
        @"title":[NSString stringWithUTF8String:w.title.c_str()],@"x":@(w.frame.origin.x),@"y":@(w.frame.origin.y),
        @"w":@(w.frame.size.width),@"h":@(w.frame.size.height),@"space":@(w.space),@"slot":@(w.slot),
        @"dx":@(w.sourceDisplay.origin.x),@"dy":@(w.sourceDisplay.origin.y),
        @"dw":@(w.sourceDisplay.size.width),@"dh":@(w.sourceDisplay.size.height),@"launch":@(w.launchTime),
        @"sourceUUID":[NSString stringWithUTF8String:w.sourceUUID.c_str()],
        @"frameKind":w.frameFromAX ? @"ax" : @"cg",
        @"fullScreen":@(w.fullScreen),@"fullScreenPhase":@(w.fullScreenPhase),
        @"fullScreenSpace":@(w.fullScreenSpace),
        @"axIdentifier":[NSString stringWithUTF8String:w.axIdentifier.c_str()],
        @"cgOnly":@(w.cgOnly),@"birthSeconds":@(w.birthSeconds),
        @"birthMicroseconds":@(w.birthMicroseconds),
        @"minimizedKnown":@(w.minimizedKnown),@"minimized":@(w.minimized)};
    if(w.memberships.empty())return record;
    NSMutableDictionary *withMembership=[record mutableCopy];
    withMembership[@"memberships"]=memberships;
    withMembership[@"readOnlyCG"]=@(w.readOnlyCG);
    withMembership[@"surfaceTags"]=@(w.surfaceTags);
    withMembership[@"axDialog"]=@(w.axDialog);
    if(includeFollower) {
        withMembership[@"followerParent"]=@(w.followerParent);
        withMembership[@"followerX"]=@(w.followerOffset.x);
        withMembership[@"followerY"]=@(w.followerOffset.y);
    }
    return withMembership;
}
NSArray *encodeWholeTopology(const air::whole_space::Topology &topology) {
    NSMutableArray *rows=NSMutableArray.array;
    for(const auto &display:topology.displays) {
        NSMutableArray *ids=NSMutableArray.array,*uuids=NSMutableArray.array;
        for(uint64_t sid:display.order)[ids addObject:@(sid)];
        for(const auto &uuid:display.spaceUUIDs)
            [uuids addObject:[NSString stringWithUTF8String:uuid.c_str()]];
        [rows addObject:@{@"uuid":[NSString stringWithUTF8String:display.uuid.c_str()],
            @"current":@(display.current),@"order":ids,@"spaceUUIDs":uuids}];
    }
    return rows;
}
bool decodeWholeTopology(NSArray *rows,air::whole_space::Topology &topology) {
    if(!rows || rows.count!=3)return false;
    air::whole_space::Topology parsed;
    std::set<std::string> displays;std::set<uint64_t> spaces;
    for(id raw in rows) {
        NSDictionary *row=dictionary(raw);NSString *uuid=row[@"uuid"];
        NSArray *ids=array(row[@"order"]),*uuids=array(row[@"spaceUUIDs"]);
        NSNumber *current=number(row[@"current"]);
        if(![uuid isKindOfClass:NSString.class] || !uuid.length || uuid.length>128
            || !ids || !uuids || ids.count<1 || ids.count>128 || ids.count!=uuids.count
            || !current || !current.unsignedLongLongValue
            || !displays.insert(uuid.UTF8String).second)return false;
        air::whole_space::Display display;display.uuid=uuid.UTF8String;
        display.current=current.unsignedLongLongValue;
        for(NSUInteger index=0;index<ids.count;index++) {
            NSNumber *sid=number(ids[index]);NSString *identity=uuids[index];
            if(!sid || !sid.unsignedLongLongValue || !spaces.insert(sid.unsignedLongLongValue).second
                || ![identity isKindOfClass:NSString.class] || !identity.length
                || identity.length>128)return false;
            display.order.push_back(sid.unsignedLongLongValue);
            display.spaceUUIDs.push_back(identity.UTF8String);
        }
        if(std::find(display.order.begin(),display.order.end(),display.current)==display.order.end())return false;
        parsed.displays.push_back(std::move(display));
    }
    topology=std::move(parsed);return true;
}
bool sameWholeTopology(const air::whole_space::Topology &a,const air::whole_space::Topology &b) {
    if(a.displays.size()!=b.displays.size())return false;
    for(size_t i=0;i<a.displays.size();i++) {
        const auto &x=a.displays[i],&y=b.displays[i];
        if(x.uuid!=y.uuid || x.current!=y.current || x.order!=y.order
            || x.spaceUUIDs!=y.spaceUUIDs)return false;
    }
    return true;
}
NSDictionary *encodeWholeFullScreens() {
    NSMutableArray *spaces=NSMutableArray.array,*moves=NSMutableArray.array,*selections=NSMutableArray.array;
    for(const auto &space:wholeFullScreens) {
        NSMutableArray *surfaces=NSMutableArray.array;
        for(const auto &surface:space.surfaces)[surfaces addObject:@{
            @"wid":@(surface.wid),@"x":@(surface.frame.origin.x),@"y":@(surface.frame.origin.y),
            @"w":@(surface.frame.size.width),@"h":@(surface.frame.size.height)}];
        [spaces addObject:@{@"sid":@(space.sid),@"uuid":[NSString stringWithUTF8String:space.uuid.c_str()],
            @"sourceDisplay":[NSString stringWithUTF8String:space.sourceDisplay.c_str()],
            @"sourceIndex":@(space.sourceIndex),@"owner":@(space.owner),@"pid":@(space.pid),
            @"bundle":[NSString stringWithUTF8String:space.bundle.c_str()],
            @"birthSeconds":@(space.birthSeconds),@"birthMicroseconds":@(space.birthMicroseconds),
            @"launchTime":@(space.launchTime),@"surfaces":surfaces}];
    }
    for(uint32_t index:wholeFullScreenMoves)[moves addObject:@(index)];
    for(const auto &selection:wholeFullScreenSelections)
        [selections addObject:@{@"recordIndex":@(selection.recordIndex),@"anchor":@(selection.anchor)}];
    id pending=wholeFullScreenPending.active ? @{@"reverse":@(wholeFullScreenPending.reverse),
        @"ordinal":@(wholeFullScreenPending.ordinal),
        @"before":encodeWholeTopology(wholeFullScreenPending.before),
        @"after":encodeWholeTopology(wholeFullScreenPending.after)} : (id)NSNull.null;
    id selectionPending=wholeFullScreenSelectionPending.active ? @{
        @"restore":@(wholeFullScreenSelectionPending.restore),
        @"ordinal":@(wholeFullScreenSelectionPending.ordinal),
        @"before":encodeWholeTopology(wholeFullScreenSelectionPending.before),
        @"after":encodeWholeTopology(wholeFullScreenSelectionPending.after)} : (id)NSNull.null;
    id runtimePending=wholeFullScreenRuntimePending.active ? @{
        @"targetIndex":@(wholeFullScreenRuntimePending.targetIndex),
        @"before":encodeWholeTopology(wholeFullScreenRuntimePending.before),
        @"after":encodeWholeTopology(wholeFullScreenRuntimePending.after)} : (id)NSNull.null;
    return @{@"spaces":spaces,@"moves":moves,@"forwardDone":@(wholeFullScreenForwardDone),
        @"reverseDone":@(wholeFullScreenReverseDone),@"pending":pending,
        @"selections":selections,@"anchorDone":@(wholeFullScreenAnchorDone),
        @"selectionDone":@(wholeFullScreenSelectionDone),
        @"selectionRestoreStarted":@(wholeFullScreenSelectionRestoreStarted),
        @"selectionPending":selectionPending,
        @"runtimeIndex":@(wholeFullScreenRuntimeIndex),@"runtimePending":runtimePending};
}
bool decodeWholeFullScreens(NSDictionary *record,std::vector<WholeFullScreenSpace> &spaces,
                            std::vector<uint32_t> &moves,uint32_t &forward,uint32_t &reverse,
                            WholeFullScreenPending &pending,
                            std::vector<WholeFullScreenSelection> &selections,
                            uint32_t &anchorDone,uint32_t &selectionDone,
                            bool &selectionRestoreStarted,
                            WholeFullScreenSelectionPending &selectionPending,
                            int &runtimeIndex,WholeFullScreenRuntimePending &runtimePending) {
    NSArray *rawSpaces=array(record[@"spaces"]),*rawMoves=array(record[@"moves"]);
    NSNumber *f=number(record[@"forwardDone"]),*r=number(record[@"reverseDone"]);
    if(!record || !rawSpaces || rawSpaces.count>64 || !rawMoves || rawMoves.count>64 || !f || !r)return false;
    std::set<uint64_t> sids;std::set<uint32_t> owners;
    for(id raw in rawSpaces) {
        NSDictionary *item=dictionary(raw);NSString *uuid=item[@"uuid"],*source=item[@"sourceDisplay"],*bundle=item[@"bundle"];
        NSNumber *sid=number(item[@"sid"]),*sourceIndex=number(item[@"sourceIndex"]);
        NSNumber *owner=number(item[@"owner"]),*pid=number(item[@"pid"]);
        NSNumber *seconds=number(item[@"birthSeconds"]),*microseconds=number(item[@"birthMicroseconds"]);
        NSNumber *launch=number(item[@"launchTime"]);NSArray *rawSurfaces=array(item[@"surfaces"]);
        if(!sid || !sid.unsignedLongLongValue || !sids.insert(sid.unsignedLongLongValue).second
            || ![uuid isKindOfClass:NSString.class] || !uuid.length || uuid.length>128
            || ![source isKindOfClass:NSString.class] || !source.length || source.length>128
            || ![bundle isKindOfClass:NSString.class] || !bundle.length || bundle.length>512
            || !sourceIndex || sourceIndex.unsignedIntegerValue>=128
            || !owner || !owner.unsignedIntValue || !owners.insert(owner.unsignedIntValue).second
            || !pid || pid.intValue<=0 || !seconds || !seconds.unsignedLongLongValue
            || !microseconds || microseconds.unsignedLongLongValue>=1000000
            || !launch || !std::isfinite(launch.doubleValue) || launch.doubleValue<=0
            || !rawSurfaces || rawSurfaces.count<1 || rawSurfaces.count>128)return false;
        WholeFullScreenSpace space;space.sid=sid.unsignedLongLongValue;space.uuid=uuid.UTF8String;
        space.sourceDisplay=source.UTF8String;space.sourceIndex=sourceIndex.unsignedIntValue;
        space.owner=owner.unsignedIntValue;space.pid=pid.intValue;space.bundle=bundle.UTF8String;
        space.birthSeconds=seconds.unsignedLongLongValue;
        space.birthMicroseconds=microseconds.unsignedLongLongValue;space.launchTime=launch.doubleValue;
        std::set<uint32_t> surfaceIDs;
        for(id rawSurface in rawSurfaces) {
            NSDictionary *entry=dictionary(rawSurface);
            NSNumber *wid=number(entry[@"wid"]),*x=number(entry[@"x"]),*y=number(entry[@"y"]);
            NSNumber *w=number(entry[@"w"]),*h=number(entry[@"h"]);
            if(!wid || !wid.unsignedIntValue || !surfaceIDs.insert(wid.unsignedIntValue).second
                || !x || !y || !w || !h || !std::isfinite(x.doubleValue)
                || !std::isfinite(y.doubleValue) || !std::isfinite(w.doubleValue)
                || !std::isfinite(h.doubleValue) || w.doubleValue<=0 || h.doubleValue<=0)return false;
            space.surfaces.push_back({wid.unsignedIntValue,
                CGRectMake(x.doubleValue,y.doubleValue,w.doubleValue,h.doubleValue)});
            if(wid.unsignedIntValue==space.owner)space.ownerFrame=space.surfaces.back().frame;
        }
        if(CGRectIsEmpty(space.ownerFrame))return false;
        spaces.push_back(std::move(space));
    }
    std::set<uint32_t> moveIDs;
    for(id raw in rawMoves) {
        NSNumber *index=number(raw);
        if(!index || index.unsignedIntegerValue>=spaces.size()
            || !moveIDs.insert(index.unsignedIntValue).second)return false;
        moves.push_back(index.unsignedIntValue);
    }
    forward=f.unsignedIntValue;reverse=r.unsignedIntValue;
    if(forward>moves.size() || reverse>forward)return false;
    id rawPending=record[@"pending"];
    if(!rawPending)return false;
    if(rawPending!=NSNull.null) {
        NSDictionary *item=dictionary(rawPending);NSNumber *direction=number(item[@"reverse"]),*ordinal=number(item[@"ordinal"]);
        if(!item || !direction || CFGetTypeID((__bridge CFTypeRef)direction)!=CFBooleanGetTypeID()
            || !ordinal || ordinal.unsignedIntValue!=(direction.boolValue?reverse:forward)
            || ordinal.unsignedIntegerValue>=moves.size()
            || (direction.boolValue ? reverse>=forward : reverse!=0)
            || !decodeWholeTopology(array(item[@"before"]),pending.before)
            || !decodeWholeTopology(array(item[@"after"]),pending.after))return false;
        pending.active=true;pending.reverse=direction.boolValue;pending.ordinal=ordinal.unsignedIntValue;
    }
    NSArray *rawSelections=array(record[@"selections"]);
    NSNumber *anchored=number(record[@"anchorDone"]),*selected=number(record[@"selectionDone"]);
    NSNumber *started=number(record[@"selectionRestoreStarted"]);
    id rawSelectionPending=record[@"selectionPending"];
    if(!rawSelections || rawSelections.count>3 || !anchored || !selected || !started
        || CFGetTypeID((__bridge CFTypeRef)started)!=CFBooleanGetTypeID()
        || !rawSelectionPending)return false;
    std::set<uint32_t> selectedRecords;
    for(id raw in rawSelections) {
        NSDictionary *item=dictionary(raw);NSNumber *index=number(item[@"recordIndex"]),*anchor=number(item[@"anchor"]);
        if(!index || index.unsignedIntegerValue>=spaces.size()
            || !selectedRecords.insert(index.unsignedIntValue).second
            || !anchor || !anchor.unsignedLongLongValue)return false;
        selections.push_back({index.unsignedIntValue,anchor.unsignedLongLongValue});
    }
    anchorDone=anchored.unsignedIntValue;selectionDone=selected.unsignedIntValue;
    selectionRestoreStarted=started.boolValue;
    if(anchorDone>selections.size() || selectionDone>selections.size()
        || (selectionDone && !selectionRestoreStarted))return false;
    if(rawSelectionPending!=NSNull.null) {
        NSDictionary *item=dictionary(rawSelectionPending);
        NSNumber *restore=number(item[@"restore"]),*ordinal=number(item[@"ordinal"]);
        if(!item || !restore || CFGetTypeID((__bridge CFTypeRef)restore)!=CFBooleanGetTypeID()
            || !ordinal || ordinal.unsignedIntValue!=(restore.boolValue ? selectionDone : anchorDone)
            || ordinal.unsignedIntegerValue>=selections.size()
            || (restore.boolValue ? !selectionRestoreStarted : selectionRestoreStarted)
            || !decodeWholeTopology(array(item[@"before"]),selectionPending.before)
            || !decodeWholeTopology(array(item[@"after"]),selectionPending.after))return false;
        selectionPending.active=true;selectionPending.restore=restore.boolValue;
        selectionPending.ordinal=ordinal.unsignedIntValue;
    }
    NSNumber *selectedRuntime=number(record[@"runtimeIndex"]);
    id rawRuntimePending=record[@"runtimePending"];
    if(!selectedRuntime || selectedRuntime.intValue<-1
        || selectedRuntime.integerValue>=(NSInteger)spaces.size()
        || !rawRuntimePending)return false;
    runtimeIndex=selectedRuntime.intValue;
    if(rawRuntimePending!=NSNull.null) {
        NSDictionary *item=dictionary(rawRuntimePending);
        NSNumber *target=number(item[@"targetIndex"]);
        if(!item || !target || target.intValue<-1
            || target.integerValue>=(NSInteger)spaces.size()
            || target.intValue==runtimeIndex
            || !decodeWholeTopology(array(item[@"before"]),runtimePending.before)
            || !decodeWholeTopology(array(item[@"after"]),runtimePending.after))return false;
        runtimePending.active=true;runtimePending.targetIndex=target.intValue;
    }
    return true;
}
bool journalFailure(const char *step) {
    journalIOError=std::string(step)+": "+strerror(errno);
    return false;
}
bool syncJournalDirectory(NSString *directory) {
    int fd=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(fd<0)return journalFailure("Cannot open recovery directory");
    bool okay=fsync(fd)==0;
    if(!okay)journalFailure("Cannot sync recovery directory");
    if(close(fd)!=0 && okay)return journalFailure("Cannot close recovery directory");
    return okay;
}
bool persist() {
    journalIOError.clear();
    bool hasFollower=std::any_of(saved.begin(),saved.end(),[](const SavedWindow &w){
        return w.followerParent!=0;
    });
    NSMutableArray *windows=NSMutableArray.array;
    for(const auto &w:saved) [windows addObject:serialize(w,hasFollower)];
    NSMutableArray *created=NSMutableArray.array;
    for(uint64_t sid:createdSpaces) {
        auto it=std::find_if(ownedSpaces.begin(),ownedSpaces.end(),[&](const OwnedSpace &s){return s.id==sid;});
        if(it==ownedSpaces.end()) [created addObject:@(sid)];
        else [created addObject:@{@"id":@(sid),
            @"uuid":[NSString stringWithUTF8String:it->uuid.c_str()],
            @"displayUUID":[NSString stringWithUTF8String:it->displayUUID.c_str()]}];
    }
    NSMutableArray *reused=NSMutableArray.array;
    for(const auto &space:reusedSlots)[reused addObject:@{
        @"id":@(space.id),@"uuid":[NSString stringWithUTF8String:space.uuid.c_str()],
        @"displayUUID":[NSString stringWithUTF8String:space.displayUUID.c_str()]}];
    NSMutableArray *before=NSMutableArray.array;
    for(uint64_t sid:pendingCreateBefore)[before addObject:@(sid)];
    NSMutableArray *slotIDs=NSMutableArray.array;
    for(uint64_t sid:slots)if(sid)[slotIDs addObject:@(sid)];
    NSDictionary *pending=pendingCreate
        ? @{@"before":before,@"displayUUID":[NSString stringWithUTF8String:builtinUUID.c_str()]}
        : (id)NSNull.null;
    NSMutableArray *selections=NSMutableArray.array;
    for(const auto &selection:initialSelections) [selections addObject:@{
        @"displayUUID":[NSString stringWithUTF8String:selection.displayUUID.c_str()],
        @"space":@(selection.space),@"type":@(selection.type),@"fullScreenWindow":@(selection.fullScreenWindow),
        @"hostSpace":@(selection.hostSpace)}];
    NSMutableArray *ordinaryIdentities=NSMutableArray.array;
    for(const auto &identity:ordinarySpaceIdentities)[ordinaryIdentities addObject:@{
        @"id":@(identity.id),
        @"displayUUID":[NSString stringWithUTF8String:identity.displayUUID.c_str()],
        @"spaceUUID":[NSString stringWithUTF8String:identity.spaceUUID.c_str()]}];
    id selection=selectionPending.active ? @{
        @"displayUUID":[NSString stringWithUTF8String:selectionPending.displayUUID.c_str()],
        @"fromSpace":@(selectionPending.fromSpace),@"targetSpace":@(selectionPending.targetSpace),
        @"windowIndex":@(selectionPending.windowIndex),@"purpose":@((int)selectionPending.purpose),
        @"stage":@(selectionPending.stage)} : (id)NSNull.null;
    bool whole=!wholeJournal.original.displays.empty();
    if(hasFollower && (!whole || !wholeFrameInventoryComplete)) {
        journalIOError="Attached windows require a complete whole-Space recovery journal";
        return false;
    }
    id parkingWindow=parkingEvacuation.active ? @{
        @"id":@(parkingEvacuation.window.id),@"pid":@(parkingEvacuation.window.pid),
        @"bundle":[NSString stringWithUTF8String:parkingEvacuation.window.bundle.c_str()],
        @"launch":@(parkingEvacuation.window.launchTime),
        @"birthSeconds":@(parkingEvacuation.window.birthSeconds),
        @"birthMicroseconds":@(parkingEvacuation.window.birthMicroseconds),
        @"sourceSpace":@(parkingEvacuation.window.sourceSpace),
        @"destinationSpace":@(parkingEvacuation.window.destinationSpace),
        @"requiresAX":@(parkingEvacuation.window.requiresAX),
        @"x":@(parkingEvacuation.window.cgFrame.origin.x),
        @"y":@(parkingEvacuation.window.cgFrame.origin.y),
        @"w":@(parkingEvacuation.window.cgFrame.size.width),
        @"h":@(parkingEvacuation.window.cgFrame.size.height)} : (id)NSNull.null;
    NSMutableArray *edgeWindows=NSMutableArray.array;
    for(const EdgeTransfer &entry:edgeTransfers)[edgeWindows addObject:@{
        @"window":@(entry.window),@"original":@(entry.original),
        @"from":@(entry.from),@"target":@(entry.target),@"stage":@(entry.stage),
        @"releaseSpace":@(entry.releaseSpace),
        @"releaseDisplay":[NSString stringWithUTF8String:entry.releaseDisplay.c_str()],
        @"releaseX":@(entry.releaseFrame.origin.x),@"releaseY":@(entry.releaseFrame.origin.y),
        @"releaseW":@(entry.releaseFrame.size.width),@"releaseH":@(entry.releaseFrame.size.height)}];
    NSMutableArray *launched=NSMutableArray.array;
    for(const RuntimeLaunchWindow &entry:runtimeLaunchWindows)[launched addObject:@{
        @"id":@(entry.id),@"pid":@(entry.pid),
        @"bundle":[NSString stringWithUTF8String:entry.bundle.c_str()],
        @"sourceDisplay":[NSString stringWithUTF8String:entry.sourceDisplay.c_str()],
        @"launch":@(entry.launchTime),@"birthSeconds":@(entry.birthSeconds),
        @"birthMicroseconds":@(entry.birthMicroseconds),
        @"sourceSpace":@(entry.sourceSpace),@"destination":@(entry.destination),
        @"slot":@(entry.slot),@"stage":@(entry.stage),
        @"x":@(entry.originalFrame.origin.x),@"y":@(entry.originalFrame.origin.y),
        @"w":@(entry.originalFrame.size.width),@"h":@(entry.originalFrame.size.height)}];
    bool hasDialog=std::any_of(saved.begin(),saved.end(),[](const SavedWindow &w){return w.axDialog;});
    bool hasFinder=std::any_of(saved.begin(),saved.end(),[](const SavedWindow &w){
        return w.cgOnly && w.bundle=="com.apple.finder";
    });
    NSMutableDictionary *journal=[@{@"version":@(whole ? (wholeFrameInventoryComplete ? (!runtimeLaunchWindows.empty() ? 22 : (!edgeTransfers.empty() ? 21 : (hasFollower ? 20 : (hasFinder ? 19 : (hasDialog ? 18 : (wholeFullScreens.empty() ? 16 : 17)))))) : 12) : 13),@"initialSpace":@(initialSpace),
        @"initialFullScreenIndex":@(initialFullScreenIndex),
        @"initialFullScreenSpace":@(initialFullScreenSpace),
        @"finalSelectionPending":@(finalSelectionPending),
        @"builtinUUID":[NSString stringWithUTF8String:builtinUUID.c_str()],
        @"createdSpaces":created,@"pendingCreate":pending,
        @"lastSelectedSpace":@(lastSelectedSpace),@"slotSpaceIDs":slotIDs,@"windows":windows,
        @"displaySelections":selections,@"selectionPending":selection,
        @"parkingEvacuation":parkingWindow,
        @"inventoryComplete":whole ? (id)NSNull.null : @(windowInventoryComplete),
        @"wholeSpace":whole ? (id)air::whole_space::encode(wholeJournal) : (id)NSNull.null,
        @"wholeFullScreens":whole && !wholeFullScreens.empty() ? (id)encodeWholeFullScreens() : (id)NSNull.null} mutableCopy];
    if(!edgeTransfers.empty())journal[@"edgeTransfers"]=edgeWindows;
    if(!runtimeLaunchWindows.empty())journal[@"runtimeLaunchWindows"]=launched;
    if(!whole && ordinaryIdentities.count)journal[@"ordinarySpaceIdentities"]=ordinaryIdentities;
    if(!whole && reused.count)journal[@"reusedSlotSpaces"]=reused;
    NSError *jsonError=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:journal options:0 error:&jsonError];
    if(!data){journalIOError=jsonError.localizedDescription.UTF8String ?: "Cannot encode recovery journal";return false;}
    NSString *path=journalPath();
    NSString *dir=[path stringByDeletingLastPathComponent];
    NSError *directoryError=nil;
    if(![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) {
        journalIOError=directoryError.localizedDescription.UTF8String ?: "Cannot create recovery directory";return false;
    }
    struct stat directoryInfo={};
    if(lstat(dir.fileSystemRepresentation,&directoryInfo)!=0)return journalFailure("Cannot inspect recovery directory");
    if(!S_ISDIR(directoryInfo.st_mode) || directoryInfo.st_uid!=geteuid()) {
        journalIOError="Recovery directory is not a directory owned by this user";return false;
    }
    if(chmod(dir.fileSystemRepresentation,0700)!=0)return journalFailure("Cannot secure recovery directory");
    std::string temporary=std::string(dir.fileSystemRepresentation)+"/.spaces-recovery-XXXXXX";
    std::vector<char> name(temporary.begin(),temporary.end());name.push_back('\0');
    int fd=mkstemp(name.data());
    if(fd<0)return journalFailure("Cannot create private recovery file");
    bool okay=fchmod(fd,0600)==0;
    if(!okay)journalFailure("Cannot secure recovery file");
    const uint8_t *bytes=(const uint8_t *)data.bytes;
    size_t offset=0;
    while(okay && offset<data.length) {
        ssize_t written=write(fd,bytes+offset,data.length-offset);
        if(written<0 && errno==EINTR)continue;
        if(written<=0){journalFailure("Cannot write recovery file");okay=false;break;}
        offset+=(size_t)written;
    }
    if(okay && fsync(fd)!=0){journalFailure("Cannot sync recovery file");okay=false;}
    if(close(fd)!=0 && okay){journalFailure("Cannot close recovery file");okay=false;}
    if(!okay){unlink(name.data());return false;}
    if(rename(name.data(),path.fileSystemRepresentation)!=0) {
        journalFailure("Cannot replace recovery journal");unlink(name.data());return false;
    }
    return syncJournalDirectory(dir);
}
bool clearJournal() {
    NSString *path=journalPath();
    if(unlink(path.fileSystemRepresentation)!=0) {
        if(errno==ENOENT)return true;
        return journalFailure("Cannot remove recovery journal");
    }
    if(syncJournalDirectory([path stringByDeletingLastPathComponent]))return true;
    std::string syncError=journalIOError;
    if(!persist())journalIOError=syncError+"; also could not replace recovery journal: "+journalIOError;
    else journalIOError=syncError+"; recovery journal was restored";
    return false;
}
bool parseJournal(NSDictionary *journal) {
    int version=[number(journal[@"version"]) intValue];
    if(((version<2 || version>6) && version!=8 && version!=9 && version!=10 && version!=11 && version!=12 && version!=13 && version!=14 && version!=15 && version!=16 && version!=17 && version!=18 && version!=19 && version!=20 && version!=21 && version!=22)
        || !number(journal[@"initialSpace"]) || !array(journal[@"windows"]))return false;
    std::vector<OrdinarySpaceIdentity> parsedOrdinaryIdentities;
    if(id raw=journal[@"ordinarySpaceIdentities"]) {
        NSArray *entries=array(raw);
        if(version!=13 || !entries || !entries.count || entries.count>384)return false;
        std::set<uint64_t> ids;std::set<std::string> uuids;
        for(id value in entries) {
            NSDictionary *entry=dictionary(value);
            NSNumber *sid=number(entry[@"id"]);
            NSString *display=entry[@"displayUUID"],*space=entry[@"spaceUUID"];
            if(!sid.unsignedLongLongValue || ![display isKindOfClass:NSString.class]
                || !display.length || display.length>128
                || ![space isKindOfClass:NSString.class] || !space.length || space.length>128
                || !ids.insert(sid.unsignedLongLongValue).second
                || !uuids.insert(space.UTF8String).second)return false;
            parsedOrdinaryIdentities.push_back({sid.unsignedLongLongValue,
                display.UTF8String,space.UTF8String});
        }
    }
    air::whole_space::Journal parsedWhole;
    bool hasWhole=false;
    if(version==9 || version==11 || version==12 || version==14 || version==15 || version==16 || version==17 || version>=18) {
        std::string reason;
        if(!air::whole_space::decode(dictionary(journal[@"wholeSpace"]),parsedWhole,&reason))return false;
        hasWhole=true;
    }
    std::vector<WholeFullScreenSpace> parsedFullScreens;
    std::vector<uint32_t> parsedFullScreenMoves;
    uint32_t parsedFullScreenForward=0,parsedFullScreenReverse=0;
    WholeFullScreenPending parsedFullScreenPending;
    std::vector<WholeFullScreenSelection> parsedFullScreenSelections;
    uint32_t parsedFullScreenAnchored=0,parsedFullScreenSelected=0;
    bool parsedFullScreenSelectionRestoreStarted=false;
    WholeFullScreenSelectionPending parsedFullScreenSelectionPending;
    int parsedFullScreenRuntimeIndex=-1;
    WholeFullScreenRuntimePending parsedFullScreenRuntimePending;
    if(version==17 || (version>=18 && dictionary(journal[@"wholeFullScreens"]))) {
        if(!decodeWholeFullScreens(dictionary(journal[@"wholeFullScreens"]),parsedFullScreens,
            parsedFullScreenMoves,parsedFullScreenForward,parsedFullScreenReverse,
            parsedFullScreenPending,parsedFullScreenSelections,parsedFullScreenAnchored,
            parsedFullScreenSelected,parsedFullScreenSelectionRestoreStarted,
            parsedFullScreenSelectionPending,parsedFullScreenRuntimeIndex,
            parsedFullScreenRuntimePending) || parsedFullScreens.empty())return false;
    } else if(journal[@"wholeFullScreens"] && journal[@"wholeFullScreens"]!=NSNull.null)return false;
    bool parsedInventoryComplete=true;
    if(version==10 || version==13) {
        NSNumber *complete=number(journal[@"inventoryComplete"]);
        if(!complete || CFGetTypeID((__bridge CFTypeRef)complete)!=CFBooleanGetTypeID()
            || journal[@"wholeSpace"]!=NSNull.null)return false;
        parsedInventoryComplete=complete.boolValue;
    }
    ParkingEvacuation parsedParkingEvacuation;
    if(version==11 || version==12 || version==13 || version==14 || version==15 || version==16 || version==17 || version>=18) {
        if(version!=13 && journal[@"inventoryComplete"]!=NSNull.null)return false;
        id raw=journal[@"parkingEvacuation"];
        if(!raw)return false;
        if(raw!=NSNull.null) {
            NSDictionary *entry=dictionary(raw);NSString *bundle=entry[@"bundle"];
            NSNumber *wid=number(entry[@"id"]),*pid=number(entry[@"pid"]),*launch=number(entry[@"launch"]);
            NSNumber *birthSeconds=number(entry[@"birthSeconds"]),*birthMicroseconds=number(entry[@"birthMicroseconds"]);
            NSNumber *source=number(entry[@"sourceSpace"]),*destination=number(entry[@"destinationSpace"]);
            NSNumber *requiresAX=version>=12 ? number(entry[@"requiresAX"]) : @YES;
            NSNumber *x=version>=12 ? number(entry[@"x"]) : @0;
            NSNumber *y=version>=12 ? number(entry[@"y"]) : @0;
            NSNumber *width=version>=12 ? number(entry[@"w"]) : @0;
            NSNumber *height=version>=12 ? number(entry[@"h"]) : @0;
            if(!entry || !wid.unsignedIntValue || pid.intValue<=0
                || ![bundle isKindOfClass:NSString.class] || !bundle.length || bundle.length>512
                || !launch || !std::isfinite(launch.doubleValue) || launch.doubleValue<=0
                || !birthSeconds.unsignedLongLongValue || !birthMicroseconds
                || birthMicroseconds.unsignedLongLongValue>=1000000
                || !source.unsignedLongLongValue || !destination.unsignedLongLongValue
                || source.unsignedLongLongValue==destination.unsignedLongLongValue
                || !requiresAX || (version>=12
                    && (CFGetTypeID((__bridge CFTypeRef)requiresAX)!=CFBooleanGetTypeID()
                        || !x || !y || !width || !height
                        || !std::isfinite(x.doubleValue) || !std::isfinite(y.doubleValue)
                        || !std::isfinite(width.doubleValue) || !std::isfinite(height.doubleValue)
                        || width.doubleValue<=0 || height.doubleValue<=0)))return false;
            parsedParkingEvacuation={true,{wid.unsignedIntValue,pid.intValue,bundle.UTF8String,
                launch.doubleValue,birthSeconds.unsignedLongLongValue,birthMicroseconds.unsignedLongLongValue,
                source.unsignedLongLongValue,destination.unsignedLongLongValue,(bool)requiresAX.boolValue,
                CGRectMake(x.doubleValue,y.doubleValue,width.doubleValue,height.doubleValue)}};
        }
    } else if(journal[@"parkingEvacuation"] && journal[@"parkingEvacuation"]!=NSNull.null)return false;
    NSString *parsedBuiltin=@"";
    std::vector<uint64_t> parsedCreated;
    std::vector<OwnedSpace> parsedOwned;
    std::vector<uint64_t> parsedBefore;
    bool parsedPending=false;
    uint64_t parsedSelected=0;
    uint64_t parsedSlots[3]={};
    if(version>=3) {
        parsedBuiltin=journal[@"builtinUUID"];
        NSArray *ids=array(journal[@"createdSpaces"]);
        if(![parsedBuiltin isKindOfClass:NSString.class] || !ids || ids.count>16)return false;
        for(id value in ids) {
            NSDictionary *identity=dictionary(value);
            NSNumber *sid=version>=4 && identity ? number(identity[@"id"]) : number(value);
            if(!sid || !sid.unsignedLongLongValue
                || std::find(parsedCreated.begin(),parsedCreated.end(),sid.unsignedLongLongValue)!=parsedCreated.end())return false;
            parsedCreated.push_back(sid.unsignedLongLongValue);
            if(identity) {
                NSString *uuid=identity[@"uuid"],*display=identity[@"displayUUID"];
                if(![uuid isKindOfClass:NSString.class] || !uuid.length
                    || ![display isKindOfClass:NSString.class] || !display.length
                    || ![display isEqualToString:parsedBuiltin])return false;
                parsedOwned.push_back({sid.unsignedLongLongValue,uuid.UTF8String,display.UTF8String});
            }
        }
    }
    if(version>=4) {
        if(!number(journal[@"lastSelectedSpace"]))return false;
        parsedSelected=[number(journal[@"lastSelectedSpace"]) unsignedLongLongValue];
        NSArray *slotIDs=array(journal[@"slotSpaceIDs"]);
        if(!slotIDs || (slotIDs.count!=0 && slotIDs.count!=3))return false;
        for(NSUInteger i=0;i<slotIDs.count;i++) {
            NSNumber *sid=number(slotIDs[i]);
            if(!sid || !sid.unsignedLongLongValue)return false;
            parsedSlots[i]=sid.unsignedLongLongValue;
            for(NSUInteger prior=0;prior<i;prior++)if(parsedSlots[prior]==parsedSlots[i])return false;
        }
        id pending=journal[@"pendingCreate"];
        if(pending!=NSNull.null) {
            NSDictionary *entry=dictionary(pending);
            NSArray *before=array(entry[@"before"]);
            NSString *display=entry[@"displayUUID"];
            if(!entry || !before || before.count>128 || ![display isKindOfClass:NSString.class]
                || ![display isEqualToString:parsedBuiltin])return false;
            for(id value in before) {
                NSNumber *sid=number(value);
                if(!sid || !sid.unsignedLongLongValue
                    || std::find(parsedBefore.begin(),parsedBefore.end(),sid.unsignedLongLongValue)!=parsedBefore.end())return false;
                parsedBefore.push_back(sid.unsignedLongLongValue);
            }
            parsedPending=true;
        }
    }
    uint64_t parsedInitial=[number(journal[@"initialSpace"]) unsignedLongLongValue];
    std::vector<OwnedSpace> parsedReused;
    if(id raw=journal[@"reusedSlotSpaces"]) {
        NSArray *entries=array(raw);
        if(version!=13 || !entries || entries.count!=3 || !parsedCreated.empty()
            || !parsedOwned.empty() || parsedPending || !parsedInitial)return false;
        std::set<uint64_t> ids;std::set<std::string> uuids;
        for(id value in entries) {
            NSDictionary *entry=dictionary(value);
            NSNumber *sid=number(entry[@"id"]);
            NSString *uuid=entry[@"uuid"],*display=entry[@"displayUUID"];
            if(!sid.unsignedLongLongValue || !ids.insert(sid.unsignedLongLongValue).second
                || ![uuid isKindOfClass:NSString.class] || !uuid.length || uuid.length>128
                || !uuids.insert(uuid.UTF8String).second
                || ![display isKindOfClass:NSString.class]
                || ![display isEqualToString:parsedBuiltin])return false;
            parsedReused.push_back({sid.unsignedLongLongValue,uuid.UTF8String,display.UTF8String});
        }
        if(parsedReused[0].id!=parsedInitial
            || (parsedSlots[0] && (parsedSlots[0]!=parsedReused[0].id
                || parsedSlots[1]!=parsedReused[1].id
                || parsedSlots[2]!=parsedReused[2].id)))return false;
    }
    int parsedInitialFullScreenIndex=-1;
    uint64_t parsedInitialFullScreenSpace=0;
    bool parsedFinalSelectionPending=false;
    std::vector<DisplaySelection> parsedSelections;
    SelectionPending parsedSelection;
    if(version>=6) {
        NSNumber *index=number(journal[@"initialFullScreenIndex"]);
        NSNumber *space=number(journal[@"initialFullScreenSpace"]);
        NSNumber *pending=number(journal[@"finalSelectionPending"]);
        if(!index || !space || !pending || index.longLongValue<-1
            || index.longLongValue>10000)return false;
        parsedInitialFullScreenIndex=index.intValue;
        parsedInitialFullScreenSpace=space.unsignedLongLongValue;
        parsedFinalSelectionPending=pending.boolValue;
        if((parsedInitialFullScreenIndex<0)!=(parsedInitialFullScreenSpace==0)
            || (parsedInitialFullScreenIndex<0 && parsedFinalSelectionPending))return false;
    }
    if(version>=8) {
        NSArray *entries=array(journal[@"displaySelections"]);
        if(!entries || entries.count>32)return false;
        for(NSDictionary *entry in entries) {
            NSString *uuid=entry[@"displayUUID"];NSNumber *space=number(entry[@"space"]);
            NSNumber *type=number(entry[@"type"]),*window=number(entry[@"fullScreenWindow"]);
            if(![uuid isKindOfClass:NSString.class] || !uuid.length || !space.unsignedLongLongValue
                || !type || (type.intValue!=0 && type.intValue!=4) || !window
                || window.intValue < -1 || window.intValue>10000
                || std::find_if(parsedSelections.begin(),parsedSelections.end(),[&](const DisplaySelection &s){return s.displayUUID==uuid.UTF8String;})!=parsedSelections.end())return false;
            NSNumber *host=version>=8 ? number(entry[@"hostSpace"]) : space;
            if(!host || !host.unsignedLongLongValue)return false;
            parsedSelections.push_back({uuid.UTF8String,space.unsignedLongLongValue,type.intValue,window.intValue,host.unsignedLongLongValue});
        }
        {
            id rawSelection=journal[@"selectionPending"];
            if(!rawSelection)return false;
            if(rawSelection!=NSNull.null) {
                NSDictionary *entry=dictionary(rawSelection);NSString *uuid=entry[@"displayUUID"];
                NSNumber *from=number(entry[@"fromSpace"]),*target=number(entry[@"targetSpace"]);
                NSNumber *index=number(entry[@"windowIndex"]),*purpose=number(entry[@"purpose"]),*stage=number(entry[@"stage"]);
                if(!entry || ![uuid isKindOfClass:NSString.class] || !uuid.length || !from || !target || !index || !purpose || !stage
                    || !from.unsignedLongLongValue || index.intValue < -1 || index.intValue>10000
                    || purpose.intValue<1 || purpose.intValue>4 || (stage.intValue!=1 && stage.intValue!=2)
                    || ((purpose.intValue==2 || purpose.intValue==4) && !target.unsignedLongLongValue)
                    || (purpose.intValue==3 && target.unsignedLongLongValue))return false;
                parsedSelection={true,uuid.UTF8String,from.unsignedLongLongValue,target.unsignedLongLongValue,index.intValue,
                    (SelectionPurpose)purpose.intValue,stage.intValue};
            }
        }
    }
    if(version>=4 && ((!parsedInitial && parsedInitialFullScreenIndex<0) || !parsedBuiltin.length))return false;
    if(parsedSlots[0] && parsedSlots[0]!=parsedInitial && !hasWhole) {
        if(version<4 || parsedOwned.size()<3)return false;
        for(uint64_t slot:parsedSlots)
            if(!slot || std::find_if(parsedOwned.begin(),parsedOwned.end(),
                [&](const OwnedSpace &owner){return owner.id==slot;})==parsedOwned.end())return false;
    }
    if(parsedSelected && parsedSlots[0]
        && parsedSelected!=parsedSlots[0] && parsedSelected!=parsedSlots[1] && parsedSelected!=parsedSlots[2])return false;
    for(const auto &owner:parsedOwned)if(owner.id==parsedInitial)return false;
    if(parsedPending && (!parsedInitial || std::find(parsedBefore.begin(),parsedBefore.end(),parsedInitial)==parsedBefore.end()))return false;
    std::vector<SavedWindow> parsed;
    if([array(journal[@"windows"]) count]>10000) return false;
    for(NSDictionary *item in array(journal[@"windows"])) {
        if(![item isKindOfClass:NSDictionary.class]) return false;
        SavedWindow w={};
        w.id=[number(item[@"id"]) unsignedIntValue];w.pid=[number(item[@"pid"]) intValue];
        NSString *bundle=item[@"bundle"], *title=item[@"title"];
        if(![bundle isKindOfClass:NSString.class] || ![title isKindOfClass:NSString.class]) return false;
        w.bundle=bundle.UTF8String;w.title=title.UTF8String;
        w.frame=CGRectMake([number(item[@"x"]) doubleValue],[number(item[@"y"]) doubleValue],
            [number(item[@"w"]) doubleValue],[number(item[@"h"]) doubleValue]);
        w.sourceDisplay=CGRectMake([number(item[@"dx"]) doubleValue],[number(item[@"dy"]) doubleValue],
            [number(item[@"dw"]) doubleValue],[number(item[@"dh"]) doubleValue]);
        w.launchTime=[number(item[@"launch"]) doubleValue];
        w.space=[number(item[@"space"]) unsignedLongLongValue];w.slot=[number(item[@"slot"]) intValue];
        if(version>=3) {
            NSString *sourceUUID=item[@"sourceUUID"],*kind=item[@"frameKind"];
            if(![sourceUUID isKindOfClass:NSString.class] || ![kind isKindOfClass:NSString.class]
                || (![kind isEqual:@"ax"] && ![kind isEqual:@"cg"]))return false;
            w.sourceUUID=sourceUUID.UTF8String;w.frameFromAX=[kind isEqual:@"ax"];
        }
        if(version>=5) {
            NSNumber *full=number(item[@"fullScreen"]),*phase=number(item[@"fullScreenPhase"]);
            NSNumber *fsSpace=number(item[@"fullScreenSpace"]);
            NSString *identifier=item[@"axIdentifier"];
            if(!full || !phase || !fsSpace || ![identifier isKindOfClass:NSString.class]
                || identifier.length>256)return false;
            w.fullScreen=full.boolValue;w.fullScreenPhase=phase.intValue;
            w.fullScreenSpace=fsSpace.unsignedLongLongValue;w.axIdentifier=identifier.UTF8String;
            if((w.fullScreen && (w.fullScreenPhase<1 || w.fullScreenPhase>4 || !w.fullScreenSpace
                || !w.frameFromAX || w.sourceUUID.empty() || w.launchTime<=0))
                || (!w.fullScreen && (w.fullScreenPhase || w.fullScreenSpace || !w.axIdentifier.empty())))return false;
            if(w.fullScreen && (((w.fullScreenPhase==1 || w.fullScreenPhase==4)
                    && w.space!=w.fullScreenSpace)
                || ((w.fullScreenPhase==2 || w.fullScreenPhase==3)
                    && w.space==w.fullScreenSpace)))return false;
        }
        if(version==13 || version==14 || version==15 || version==16 || version==17 || version>=18) {
            NSNumber *cgOnly=number(item[@"cgOnly"]);
            NSNumber *birthSeconds=number(item[@"birthSeconds"]);
            NSNumber *birthMicroseconds=number(item[@"birthMicroseconds"]);
            if(!cgOnly || CFGetTypeID((__bridge CFTypeRef)cgOnly)!=CFBooleanGetTypeID()
                || !birthSeconds || !birthMicroseconds)return false;
            w.cgOnly=cgOnly.boolValue;
            w.birthSeconds=birthSeconds.unsignedLongLongValue;
            w.birthMicroseconds=birthMicroseconds.unsignedLongLongValue;
            if(item[@"minimizedKnown"] || item[@"minimized"]) {
                NSNumber *known=number(item[@"minimizedKnown"]),*minimized=number(item[@"minimized"]);
                if(!known || !minimized
                    || CFGetTypeID((__bridge CFTypeRef)known)!=CFBooleanGetTypeID()
                    || CFGetTypeID((__bridge CFTypeRef)minimized)!=CFBooleanGetTypeID()
                    || (!known.boolValue && minimized.boolValue))return false;
                w.minimizedKnown=known.boolValue;w.minimized=minimized.boolValue;
            }
            if(w.cgOnly && (w.fullScreen || w.frameFromAX || w.title.empty()
                || !w.birthSeconds || w.birthMicroseconds>=1000000))return false;
        }
        if(version==15 || version==16 || version==17 || version>=18) {
            NSArray *memberships=array(item[@"memberships"]);
            if(!memberships || memberships.count<1 || memberships.count>128)return false;
            for(id value in memberships) {
                NSNumber *sid=number(value);
                if(!sid || !sid.unsignedLongLongValue)return false;
                w.memberships.push_back(sid.unsignedLongLongValue);
            }
            if(!std::is_sorted(w.memberships.begin(),w.memberships.end())
                || std::adjacent_find(w.memberships.begin(),w.memberships.end())!=w.memberships.end()
                || std::find(w.memberships.begin(),w.memberships.end(),w.space)==w.memberships.end())return false;
        } else if(version==14)w.memberships={w.space};
        if(version==16 || version==17 || version>=18) {
            NSNumber *readOnly=number(item[@"readOnlyCG"]),*tags=number(item[@"surfaceTags"]);
            if(!readOnly || CFGetTypeID((__bridge CFTypeRef)readOnly)!=CFBooleanGetTypeID()
                || !tags)return false;
            w.readOnlyCG=readOnly.boolValue;w.surfaceTags=tags.unsignedLongLongValue;
            bool finder=(version>=19 && w.cgOnly && !w.readOnlyCG
                && !w.frameFromAX && !w.fullScreen && w.bundle=="com.apple.finder"
                && !w.title.empty() && w.memberships.size()==1
                && w.surfaceTags==0x200000100482001ULL);
            if(version>=19 && w.cgOnly && w.bundle=="com.apple.finder" && !finder)return false;
            if(w.readOnlyCG ? (w.cgOnly || w.frameFromAX || w.fullScreen
                    || w.bundle!="com.google.Chrome" || !w.title.empty()
                    || w.memberships.size()!=1 || w.surfaceTags!=0x1400c0202ULL)
                : w.surfaceTags!=0 && !finder)return false;
        }
        if(version>=18) {
            NSNumber *dialog=number(item[@"axDialog"]);
            if(!dialog || CFGetTypeID((__bridge CFTypeRef)dialog)!=CFBooleanGetTypeID())return false;
            w.axDialog=dialog.boolValue;
            if(w.axDialog && (!w.frameFromAX || w.fullScreen || w.cgOnly || w.readOnlyCG
                || w.memberships.size()!=1 || !w.birthSeconds
                || w.birthMicroseconds>=1000000))return false;
        }
        if(version==20 || (version>=21 && item[@"followerParent"])) {
            NSNumber *parent=number(item[@"followerParent"]),*x=number(item[@"followerX"]),
                *y=number(item[@"followerY"]);
            if(!parent || !x || !y || !std::isfinite(x.doubleValue)
                || !std::isfinite(y.doubleValue))return false;
            w.followerParent=parent.unsignedIntValue;
            w.followerOffset=CGPointMake(x.doubleValue,y.doubleValue);
            if(w.followerParent && (w.followerParent==w.id || !w.frameFromAX
                || w.fullScreen || w.cgOnly || w.readOnlyCG || w.axDialog
                || w.memberships.size()!=1 || !w.birthSeconds
                || w.birthMicroseconds>=1000000))return false;
        } else if(item[@"followerParent"] || item[@"followerX"] || item[@"followerY"]) {
            return false;
        }
        if(!w.id || w.pid<=0 || w.bundle.empty() || !w.space || w.slot<0 || w.slot>2
            || !std::isfinite(w.frame.origin.x) || !std::isfinite(w.frame.origin.y)
            || !std::isfinite(w.frame.size.width) || !std::isfinite(w.frame.size.height)
            || !std::isfinite(w.sourceDisplay.origin.x) || !std::isfinite(w.sourceDisplay.origin.y)
            || !std::isfinite(w.sourceDisplay.size.width) || !std::isfinite(w.sourceDisplay.size.height)
            || w.frame.size.width<=0 || w.frame.size.height<=0
            || w.sourceDisplay.size.width<=0 || w.sourceDisplay.size.height<=0) return false;
        if(w.minimizedKnown && (!w.frameFromAX || w.fullScreen || w.cgOnly
            || w.readOnlyCG || w.axDialog || w.followerParent))return false;
        for(const SavedWindow &prior:parsed)if(prior.pid==w.pid && prior.id==w.id)return false;
        parsed.push_back(w);
    }
    if(version==18 && std::none_of(parsed.begin(),parsed.end(),
        [](const SavedWindow &w){return w.axDialog;}))return false;
    if(version==19 && std::none_of(parsed.begin(),parsed.end(),
        [](const SavedWindow &w){return w.cgOnly && w.bundle=="com.apple.finder";}))return false;
    if(version>=20) {
        bool hasFollower=false;
        for(const SavedWindow &w:parsed)if(w.followerParent) {
            hasFollower=true;
            auto parent=std::find_if(parsed.begin(),parsed.end(),[&](const SavedWindow &p) {
                return p.id==w.followerParent && p.pid==w.pid;
            });
            if(parent==parsed.end() || parent->followerParent || !parent->frameFromAX
                || parent->cgOnly || parent->readOnlyCG || parent->axDialog
                || parent->space!=w.space || parent->slot!=w.slot
                || parent->sourceUUID!=w.sourceUUID || parent->memberships!=w.memberships
                || !nearFrame(parent->sourceDisplay,w.sourceDisplay)
                || fabs(parent->launchTime-w.launchTime)>1
                || parent->birthSeconds!=w.birthSeconds
                || parent->birthMicroseconds!=w.birthMicroseconds
                || !attachedFollowerGeometry(parent->frame,w.frame,w.followerOffset))return false;
        }
        if(version==20 && !hasFollower)return false;
    }
    std::vector<EdgeTransfer> parsedEdges;
    if(version==21 || (version==22 && journal[@"edgeTransfers"])) {
        NSArray *entries=array(journal[@"edgeTransfers"]);
        if(!hasWhole || !entries || entries.count==0 || entries.count>parsed.size())return false;
        for(id value in entries) {
            NSDictionary *entry=dictionary(value);
            NSNumber *wid=number(entry[@"window"]),*original=number(entry[@"original"]),
                *from=number(entry[@"from"]),*target=number(entry[@"target"]),
                *stage=number(entry[@"stage"]),*releaseSpace=number(entry[@"releaseSpace"]),
                *rx=number(entry[@"releaseX"]),*ry=number(entry[@"releaseY"]),
                *rw=number(entry[@"releaseW"]),*rh=number(entry[@"releaseH"]);
            NSString *releaseDisplay=entry[@"releaseDisplay"];
            if(!wid.unsignedIntValue || !original.unsignedLongLongValue
                || !from.unsignedLongLongValue || !target.unsignedLongLongValue
                || stage.intValue<1 || stage.intValue>3
                || from.unsignedLongLongValue==target.unsignedLongLongValue
                || !releaseSpace.unsignedLongLongValue
                || ![releaseDisplay isKindOfClass:NSString.class] || !releaseDisplay.length
                || !rx || !ry || !rw || !rh || !std::isfinite(rx.doubleValue)
                || !std::isfinite(ry.doubleValue) || !std::isfinite(rw.doubleValue)
                || !std::isfinite(rh.doubleValue) || rw.doubleValue<=0 || rh.doubleValue<=0)return false;
            auto window=std::find_if(parsed.begin(),parsed.end(),[&](const SavedWindow &w){
                return w.id==wid.unsignedIntValue && w.space==original.unsignedLongLongValue
                    && w.frameFromAX && !w.fullScreen && !w.cgOnly && !w.readOnlyCG
                    && !w.axDialog && !w.followerParent && w.memberships.size()==1
                    && w.memberships[0]==w.space && w.birthSeconds>0;
            });
            if(window==parsed.end() || std::any_of(parsedEdges.begin(),parsedEdges.end(),
                [&](const EdgeTransfer &prior){return prior.window==wid.unsignedIntValue;}))return false;
            int fromIndex=-1,targetIndex=-1;
            for(int i=0;i<3;i++) {
                if(parsedWhole.selected[i]==from.unsignedLongLongValue)fromIndex=i;
                if(parsedWhole.selected[i]==target.unsignedLongLongValue)targetIndex=i;
            }
            if(fromIndex<0 || targetIndex<0 || std::abs(fromIndex-targetIndex)!=1)return false;
            bool releaseKnown=false;
            for(const auto &display:parsedWhole.original.displays)
                if(display.uuid==releaseDisplay.UTF8String
                    && std::find(display.order.begin(),display.order.end(),
                        releaseSpace.unsignedLongLongValue)!=display.order.end())releaseKnown=true;
            if(!releaseKnown && !(releaseDisplay.UTF8String==parsedWhole.builtin
                && (releaseSpace.unsignedLongLongValue==from.unsignedLongLongValue
                    || releaseSpace.unsignedLongLongValue==target.unsignedLongLongValue)))return false;
            parsedEdges.push_back({wid.unsignedIntValue,original.unsignedLongLongValue,
                from.unsignedLongLongValue,target.unsignedLongLongValue,stage.intValue,
                releaseSpace.unsignedLongLongValue,releaseDisplay.UTF8String,
                CGRectMake(rx.doubleValue,ry.doubleValue,rw.doubleValue,rh.doubleValue)});
        }
    } else if(journal[@"edgeTransfers"])return false;
    std::vector<RuntimeLaunchWindow> parsedLaunches;
    if(version==22) {
        NSArray *entries=array(journal[@"runtimeLaunchWindows"]);
        if(!hasWhole || parsedWhole.forwardDone!=4 || parsedWhole.parkingCount!=2
            || !entries || entries.count==0 || entries.count>10000)return false;
        for(id value in entries) {
            NSDictionary *item=dictionary(value);
            NSNumber *wid=number(item[@"id"]),*pid=number(item[@"pid"]),
                *launch=number(item[@"launch"]),*birthSeconds=number(item[@"birthSeconds"]),
                *birthMicroseconds=number(item[@"birthMicroseconds"]),
                *source=number(item[@"sourceSpace"]),*destination=number(item[@"destination"]),
                *slot=number(item[@"slot"]),*stage=number(item[@"stage"]),
                *x=number(item[@"x"]),*y=number(item[@"y"]),
                *width=number(item[@"w"]),*height=number(item[@"h"]);
            NSString *bundle=item[@"bundle"],*display=item[@"sourceDisplay"];
            if(!wid.unsignedIntValue || pid.intValue<=0 || !launch || !std::isfinite(launch.doubleValue)
                || launch.doubleValue<=0 || !birthSeconds.unsignedLongLongValue
                || !birthMicroseconds || birthMicroseconds.unsignedLongLongValue>=1000000
                || !source.unsignedLongLongValue || !destination.unsignedLongLongValue
                || !slot || slot.intValue<1 || slot.intValue>2 || !stage
                || stage.intValue<0 || stage.intValue>2
                || ![bundle isKindOfClass:NSString.class] || !bundle.length || bundle.length>512
                || ![display isKindOfClass:NSString.class] || !display.length
                || !x || !y || !width || !height || !std::isfinite(x.doubleValue)
                || !std::isfinite(y.doubleValue) || !std::isfinite(width.doubleValue)
                || !std::isfinite(height.doubleValue) || width.doubleValue<=0 || height.doubleValue<=0
                || destination.unsignedLongLongValue!=parsedWhole.selected[slot.intValue]
                || std::any_of(parsed.begin(),parsed.end(),[&](const SavedWindow &w){
                    return w.id==wid.unsignedIntValue && w.pid==pid.intValue;
                }) || std::any_of(parsedLaunches.begin(),parsedLaunches.end(),[&](const RuntimeLaunchWindow &w){
                    return w.id==wid.unsignedIntValue;
                }))return false;
            const auto &original=parsedWhole.original.displays;
            auto owner=std::find_if(original.begin(),original.end(),[&](const air::whole_space::Display &d){
                return d.uuid==display.UTF8String;
            });
            int displaySlot=0;
            for(const auto &d:original)if(d.uuid!=parsedWhole.builtin) {
                ++displaySlot;if(d.uuid==display.UTF8String)break;
            }
            bool knownSource=owner!=original.end() && owner->uuid!=parsedWhole.builtin
                && (std::find(owner->order.begin(),owner->order.end(),source.unsignedLongLongValue)
                    !=owner->order.end() || source.unsignedLongLongValue==parsedWhole.parking[slot.intValue-1]);
            if(!knownSource || displaySlot!=slot.intValue)return false;
            parsedLaunches.push_back({wid.unsignedIntValue,pid.intValue,bundle.UTF8String,
                display.UTF8String,launch.doubleValue,birthSeconds.unsignedLongLongValue,
                birthMicroseconds.unsignedLongLongValue,source.unsignedLongLongValue,
                destination.unsignedLongLongValue,slot.intValue,stage.intValue,
                CGRectMake(x.doubleValue,y.doubleValue,width.doubleValue,height.doubleValue)});
        }
    } else if(journal[@"runtimeLaunchWindows"])return false;
    if(parsedInitialFullScreenIndex>=0) {
        if((size_t)parsedInitialFullScreenIndex>=parsed.size())return false;
        const SavedWindow &initial=parsed[parsedInitialFullScreenIndex];
        if(!initial.fullScreen || initial.slot!=0 || initial.sourceUUID!=parsedBuiltin.UTF8String
            || initial.fullScreenSpace!=parsedInitialFullScreenSpace
            || parsedInitial==parsedInitialFullScreenSpace)return false;
        int occupants=0;
        for(const SavedWindow &window:parsed)
            if(window.space==parsedInitialFullScreenSpace
                || window.fullScreenSpace==parsedInitialFullScreenSpace)occupants++;
        if(occupants!=1)return false;
        if(!parsedInitial) {
            if(parsedPending || !parsedCreated.empty() || parsedSelected || parsedSlots[0]
                || initial.fullScreenPhase!=1 && initial.fullScreenPhase!=4
                || parsedFinalSelectionPending)return false;
        } else if(initial.space!=parsedInitial
            && (initial.fullScreenPhase==2 || initial.fullScreenPhase==3)) {
            return false;
        }
    }
    for(const DisplaySelection &selection:parsedSelections)if(selection.type==4) {
        if(selection.fullScreenWindow<0 || (size_t)selection.fullScreenWindow>=parsed.size())return false;
        const SavedWindow &w=parsed[selection.fullScreenWindow];
        if(!w.fullScreen || w.fullScreenSpace!=selection.space
            || w.sourceUUID!=selection.displayUUID)return false;
    } else if(selection.fullScreenWindow!=-1)return false;
    if(parsedSelection.active) {
        auto display=std::find_if(parsedSelections.begin(),parsedSelections.end(),[&](const DisplaySelection &item){return item.displayUUID==parsedSelection.displayUUID;});
        if(display==parsedSelections.end() || display->hostSpace!=parsedSelection.fromSpace
            || (parsedSelection.windowIndex>=0 && (size_t)parsedSelection.windowIndex>=parsed.size()))return false;
        if(parsedSelection.purpose==SelectionPurpose::Prepare) {
            if(parsedSelection.windowIndex<0)return false;
            const SavedWindow &w=parsed[parsedSelection.windowIndex];
            if(parsedSelection.targetSpace) {
                if(!w.fullScreen || w.fullScreenPhase!=1 || w.fullScreenSpace!=parsedSelection.targetSpace)return false;
            } else if(!w.fullScreen || w.fullScreenPhase!=4)return false;
        }
    }
    if(!parsedInventoryComplete) {
        if(hasWhole || parsed.empty() || parsedSelections.empty() || !parsedCreated.empty()
            || !parsedOwned.empty() || parsedPending || parsedSlots[0] || parsedSlots[1]
            || parsedSlots[2] || parsedSelected || parsedFinalSelectionPending)return false;
        for(const SavedWindow &w:parsed)if(!w.fullScreen)return false;
        for(const SavedWindow &w:parsed)if(std::find_if(parsedSelections.begin(),parsedSelections.end(),
            [&](const DisplaySelection &selection){return selection.displayUUID==w.sourceUUID;})==parsedSelections.end())return false;
        if(parsedSelection.active && parsedSelection.purpose!=SelectionPurpose::Prepare)return false;
    }
    if(hasWhole) {
        if(parsedBuiltin.UTF8String!=parsedWhole.builtin || parsedInitial!=parsedWhole.selected[0]
            || (version!=14 && version!=15 && version!=16 && version!=17 && version!=18 && version!=19 && version!=20 && version!=21 && version!=22 && !parsed.empty()) || parsedInitialFullScreenIndex>=0 || parsedInitialFullScreenSpace
            || parsedFinalSelectionPending || !parsedSelections.empty() || parsedSelection.active
            || parsedCreated.size()!=parsedOwned.size() || parsedCreated.size()>parsedWhole.parkingCount
            || (parsedSelected && parsedSelected!=parsedWhole.runtimeCurrent))return false;
        if(version==14 || version==15 || version==16 || version==17 || version>=18) {
            if(journal[@"inventoryComplete"]!=NSNull.null
                || parsedWhole.original.displays.size()!=3)return false;
            for(const SavedWindow &w:parsed) {
                if(w.fullScreen || (!w.frameFromAX && !w.cgOnly && !w.readOnlyCG) || !w.birthSeconds
                    || w.birthMicroseconds>=1000000 || w.slot<0 || w.slot>=3
                    || w.sourceUUID!=parsedWhole.original.displays[w.slot].uuid)return false;
                const auto &space=parsedWhole.original.displays[w.slot].order;
                if(std::find(space.begin(),space.end(),w.space)==space.end())return false;
                if(w.readOnlyCG && w.space!=parsedWhole.selected[w.slot])return false;
                for(uint64_t sid:w.memberships) {
                    bool found=false;
                    for(const auto &display:parsedWhole.original.displays)
                        if(std::find(display.order.begin(),display.order.end(),sid)!=display.order.end())found=true;
                    if(!found)return false;
                }
            }
        }
        if(version==17 || (version>=18 && !parsedFullScreens.empty())) {
            std::set<uint32_t> expectedMoves;
            std::set<std::pair<std::string,uint32_t>> sourcePositions;
            std::set<std::string> fullScreenUUIDs;
            std::set<uint32_t> fullScreenSurfaces;
            for(size_t i=0;i<parsedFullScreens.size();i++) {
                const auto &fs=parsedFullScreens[i];
                bool sourceKnown=false;
                for(const auto &display:parsedWhole.original.displays) {
                    if(display.uuid==fs.sourceDisplay)sourceKnown=true;
                    if(std::find(display.order.begin(),display.order.end(),fs.sid)!=display.order.end())return false;
                }
                if(!sourceKnown || !sourcePositions.insert({fs.sourceDisplay,fs.sourceIndex}).second
                    || !fullScreenUUIDs.insert(fs.uuid).second)return false;
                if(fs.sourceDisplay!=parsedWhole.builtin)expectedMoves.insert((uint32_t)i);
                for(const SavedWindow &w:parsed)if(w.id==fs.owner && w.pid==fs.pid)return false;
                for(const auto &surface:fs.surfaces)
                    if(!fullScreenSurfaces.insert(surface.wid).second)return false;
            }
            if(std::set<uint32_t>(parsedFullScreenMoves.begin(),parsedFullScreenMoves.end())!=expectedMoves
                || !std::is_sorted(parsedFullScreenMoves.begin(),parsedFullScreenMoves.end(),
                    [&](uint32_t left,uint32_t right) {
                        const auto &a=parsedFullScreens[left],&b=parsedFullScreens[right];
                        return a.sourceDisplay==b.sourceDisplay ? a.sourceIndex>b.sourceIndex
                            : a.sourceDisplay<b.sourceDisplay;
                    })
                || (parsedFullScreenForward && parsedWhole.forwardDone!=4))return false;
            std::set<std::string> selectedDisplays;
            for(const auto &selection:parsedFullScreenSelections) {
                const auto &space=parsedFullScreens[selection.recordIndex];
                if(!selectedDisplays.insert(space.sourceDisplay).second)return false;
                const auto found=std::find_if(parsedWhole.original.displays.begin(),
                    parsedWhole.original.displays.end(),[&](const air::whole_space::Display &display){
                        return display.uuid==space.sourceDisplay;});
                if(found==parsedWhole.original.displays.end() || found->current!=selection.anchor)return false;
            }
            if(parsedFullScreenSelectionRestoreStarted
                && (parsedFullScreenAnchored!=parsedFullScreenSelections.size()
                    || !parsedCreated.empty()
                    || parsedFullScreenReverse!=parsedFullScreenForward
                    || parsedFullScreenRuntimeIndex>=0 || parsedFullScreenRuntimePending.active))return false;
            if((parsedFullScreenRuntimeIndex>=0 || parsedFullScreenRuntimePending.active)
                && (parsedWhole.forwardDone!=4 || parsedWhole.reverseDone
                    || parsedFullScreenForward!=parsedFullScreenMoves.size()
                    || parsedFullScreenReverse))return false;
        }
        std::set<uint64_t> remaining;
        for(size_t index=0;index<parsedOwned.size();index++) {
            int parkingIndex=parsedCreated[index]==parsedWhole.parking[0] ? 0
                : parsedCreated[index]==parsedWhole.parking[1] ? 1 : -1;
            if(parkingIndex<0 || !remaining.insert(parsedCreated[index]).second
                || parsedOwned[index].id!=parsedCreated[index]
                || parsedOwned[index].uuid!=parsedWhole.parkingUUID[parkingIndex]
                || parsedOwned[index].displayUUID!=parsedWhole.builtin)return false;
        }
        bool cleanup=!parsedWhole.pending.active && !parsedWhole.runtimeSelectionPending.active
            && !parsedWhole.selectionPending.active && !parsedSlots[0] && !parsedSlots[1] && !parsedSlots[2]
            && ((parsedWhole.reverseDone==4 && parsedWhole.selectionDone==3)
                || (parsedWhole.forwardDone==0 && parsedWhole.reverseDone==0 && parsedWhole.selectionDone==0));
        if(!cleanup && parsedCreated.size()!=parsedWhole.parkingCount)return false;
        if(parsedSlots[0]) {
            // Slots remain journaled through reverse and selection recovery;
            // beginOwnedCleanup clears them only after original frames verify.
            if(parsedWhole.forwardDone!=4)return false;
            for(int index=0;index<3;index++)if(parsedSlots[index]!=parsedWhole.selected[index])return false;
        }
        if(parsedPending) {
            if(parsedWhole.parkingCount>=2 || parsedBefore.empty())return false;
        }
        if(parsedParkingEvacuation.active) {
            bool sourceOwned=std::find(parsedCreated.begin(),parsedCreated.end(),
                parsedParkingEvacuation.window.sourceSpace)!=parsedCreated.end();
            const auto &parking=parsedParkingEvacuation.window;
            bool chromeExternal=parking.bundle=="com.google.Chrome"
                && ((parking.sourceSpace==parsedWhole.parking[0]
                        && parking.destinationSpace==parsedWhole.selected[1])
                    || (parking.sourceSpace==parsedWhole.parking[1]
                        && parking.destinationSpace==parsedWhole.selected[2]));
            if(!sourceOwned || (parking.destinationSpace!=parsedWhole.selected[0] && !chromeExternal)
                || (parking.destinationSpace!=parsedInitial && !chromeExternal)
                || parsedSlots[0] || parsedSelected || parsedPending
                || parsedWhole.pending.active || parsedWhole.runtimeSelectionPending.active
                || parsedWhole.selectionPending.active)return false;
            bool terminal=(parsedWhole.forwardDone==0 && parsedWhole.reverseDone==0
                    && parsedWhole.selectionDone==0)
                || (parsedWhole.reverseDone==4 && parsedWhole.selectionDone==3);
            if(!terminal)return false;
        }
    }
    if(version==13 && parsedParkingEvacuation.active) {
        const auto &parking=parsedParkingEvacuation.window;
        bool sourceOwned=std::find(parsedCreated.begin(),parsedCreated.end(),parking.sourceSpace)
            !=parsedCreated.end();
        bool savedConflict=std::any_of(parsed.begin(),parsed.end(),[&](const SavedWindow &w) {
            return w.id==parking.id && w.pid==parking.pid;
        });
        if(!sourceOwned || parking.destinationSpace!=parsedInitial || !parsedInitial
            || parsedSlots[0] || parsedSlots[1] || parsedSlots[2] || parsedSelected
            || parsedPending || parsedSelection.active || savedConflict)return false;
    }
    initialSpace=parsedInitial;builtinUUID=parsedBuiltin.UTF8String;
    initialFullScreenIndex=parsedInitialFullScreenIndex;
    initialFullScreenSpace=parsedInitialFullScreenSpace;
    finalSelectionPending=parsedFinalSelectionPending;
    createdSpaces=std::move(parsedCreated);ownedSpaces=std::move(parsedOwned);
    reusedSlots=std::move(parsedReused);
    pendingCreateBefore=std::move(parsedBefore);pendingCreate=parsedPending;
    for(int i=0;i<3;i++)slots[i]=parsedSlots[i];
    initialSelections=std::move(parsedSelections);selectionPending=std::move(parsedSelection);
    ordinarySpaceIdentities=std::move(parsedOrdinaryIdentities);
    lastSelectedSpace=parsedSelected;saved=std::move(parsed);
    wholeJournal=std::move(parsedWhole);parkingEvacuation=std::move(parsedParkingEvacuation);
    wholeFullScreens=std::move(parsedFullScreens);wholeFullScreenMoves=std::move(parsedFullScreenMoves);
    wholeFullScreenForwardDone=parsedFullScreenForward;wholeFullScreenReverseDone=parsedFullScreenReverse;
    wholeFullScreenPending=std::move(parsedFullScreenPending);
    wholeFullScreenSelections=std::move(parsedFullScreenSelections);
    wholeFullScreenAnchorDone=parsedFullScreenAnchored;
    wholeFullScreenSelectionDone=parsedFullScreenSelected;
    wholeFullScreenSelectionRestoreStarted=parsedFullScreenSelectionRestoreStarted;
    wholeFullScreenSelectionPending=std::move(parsedFullScreenSelectionPending);
    wholeFullScreenRuntimeIndex=parsedFullScreenRuntimeIndex;
    wholeFullScreenRuntimePending=std::move(parsedFullScreenRuntimePending);
    edgeTransfers=std::move(parsedEdges);
    runtimeLaunchWindows=std::move(parsedLaunches);
    windowInventoryComplete=parsedInventoryComplete;wholeFrameInventoryComplete=hasWhole && version>=14;return true;
}
bool loadJournal() {
    NSData *data=[NSData dataWithContentsOfFile:journalPath()];
    NSDictionary *journal=data ? dictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
    return parseJournal(journal);
}
AXUIElementRef dockApplication() {
    NSArray *apps=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if(!apps.count) return nullptr;
    return AXUIElementCreateApplication(((NSRunningApplication *)apps[0]).processIdentifier);
}
AXUIElementRef windowManagerApplication() {
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<27)return nullptr;
    NSArray *apps=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.WindowManager"];
    if(apps.count!=1)return nullptr;
    NSRunningApplication *app=apps[0];
    NSString *path=app.executableURL.path.stringByStandardizingPath;
    if(![path isEqual:@"/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"])
        return nullptr;
    return AXUIElementCreateApplication(app.processIdentifier);
}
id axAttribute(AXUIElementRef element,CFStringRef name) {
    CFTypeRef result=nullptr;
    if(AXUIElementCopyAttributeValue(element,name,&result)!=kAXErrorSuccess) return nil;
    return CFBridgingRelease(result);
}
AXUIElementRef descendantSearch(AXUIElementRef parent,NSString *identifier,NSNumber *displayID,
                                int depth,int *budget,CFAbsoluteTime deadline) {
    if(depth>9 || --*budget<0 || CFAbsoluteTimeGetCurrent()>deadline)return nullptr;
    AXUIElementSetMessagingTimeout(parent,0.4);
    NSString *own=axAttribute(parent,CFSTR("AXIdentifier"));
    if([own isKindOfClass:NSString.class] && [own isEqual:identifier]) {
        if(!displayID || [number(axAttribute(parent,CFSTR("AXDisplayID"))) isEqual:displayID]) return (AXUIElementRef)CFRetain(parent);
    }
    for(id child in array(axAttribute(parent,kAXChildrenAttribute))) {
        if(CFGetTypeID((__bridge CFTypeRef)child)!=AXUIElementGetTypeID())continue;
        AXUIElementRef result=descendantSearch((__bridge AXUIElementRef)child,identifier,displayID,
            depth+1,budget,deadline);
        if(result) return result;
    }
    return nullptr;
}
enum class MissionState { Absent, Visible, Unknown };
MissionState missionState(AXUIElementRef *found=nullptr) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->missionState)return (MissionState)recoveryHooks->missionState();
#endif
    if(found)*found=nullptr;
    if(!AXIsProcessTrusted())return MissionState::Unknown;
    AXUIElementRef dock=dockApplication();
    if(!dock)return MissionState::Unknown;
    AXUIElementSetMessagingTimeout(dock,0.5);
    CFTypeRef raw=nullptr;
    AXError status=AXUIElementCopyAttributeValue(dock,kAXChildrenAttribute,&raw);
    CFRelease(dock);
    if(status!=kAXErrorSuccess || !raw || CFGetTypeID(raw)!=CFArrayGetTypeID()) {
        if(raw)CFRelease(raw);
        return MissionState::Unknown;
    }
    MissionState result=MissionState::Absent;
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+2.0;
    NSUInteger checked=0;
    for(id child in (__bridge NSArray *)raw) {
        if(++checked>128 || CFAbsoluteTimeGetCurrent()>deadline) { result=MissionState::Unknown;break; }
        if(CFGetTypeID((__bridge CFTypeRef)child)!=AXUIElementGetTypeID()) {
            result=MissionState::Unknown;break;
        }
        AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)child,0.4);
        CFTypeRef identifier=nullptr;
        AXError read=AXUIElementCopyAttributeValue((__bridge AXUIElementRef)child,CFSTR("AXIdentifier"),&identifier);
        if(read==kAXErrorNoValue || read==kAXErrorAttributeUnsupported) {
            if(identifier)CFRelease(identifier);
            continue;
        }
        if(read!=kAXErrorSuccess) {
            if(identifier)CFRelease(identifier);
            result=MissionState::Unknown;
            break;
        }
        if(!identifier || CFGetTypeID(identifier)!=CFStringGetTypeID()) {
            if(identifier)CFRelease(identifier);
            result=MissionState::Unknown;
            break;
        }
        bool isMission=identifier && CFGetTypeID(identifier)==CFStringGetTypeID()
            && CFEqual(identifier,CFSTR("mc"));
        if(identifier)CFRelease(identifier);
        if(isMission) {
            result=MissionState::Visible;
            if(found)*found=(AXUIElementRef)CFRetain((__bridge CFTypeRef)child);
            break;
        }
    }
    CFRelease(raw);
    return result;
}
bool openMission() {
    if(missionState()!=MissionState::Absent || !api().dock)return false;
    if(api().dock(CFSTR("com.apple.expose.awake"),0)!=kCGErrorSuccess)return false;
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+3.0;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        MissionState state=missionState();
        if(state==MissionState::Visible)return true;
        usleep(50000);
    }
    return false;
}
AXUIElementRef missionList(NSString *identifier,CGDirectDisplayID display,bool open) {
    AXUIElementRef mc=nullptr;
    MissionState state=missionState(&mc);
    if(state==MissionState::Absent && open && openMission())state=missionState(&mc);
    if(state!=MissionState::Visible || !mc) { if(mc)CFRelease(mc);return nullptr; }
    // Dock may publish its Mission Control group before its display controls.
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+3.0;
    AXUIElementRef found=nullptr;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        int budget=128;
        AXUIElementRef mcDisplay=descendantSearch(mc,@"mc.display",@(display),0,&budget,deadline);
        // macOS 27 keeps an empty Dock "mc" placeholder while the real
        // per-display controls belong to the WindowManager application.
        AXUIElementRef windowManager=nullptr;
        if(!mcDisplay && (windowManager=windowManagerApplication())) {
            budget=256;
            mcDisplay=descendantSearch(windowManager,@"mc.display",@(display),0,&budget,deadline);
        }
        found=mcDisplay ? descendantSearch(mcDisplay,identifier,nil,0,&budget,deadline):nullptr;
        if(mcDisplay)CFRelease(mcDisplay);
        if(windowManager)CFRelease(windowManager);
        if(found)break;
        AXUIElementRef current=nullptr;
        MissionState currentState=missionState(&current);
        bool same=currentState==MissionState::Visible && current && CFEqual(current,mc);
        if(current)CFRelease(current);
        if(!same)break;
        usleep(50000);
    }
    CFRelease(mc);return found;
}
NSArray *missionLayoutSnapshot() {
    NSArray *inventory=managed();
    if(!inventory || inventory.count==0 || inventory.count>32)return nil;
    NSMutableArray *rows=NSMutableArray.array;
    for(NSDictionary *display in inventory) {
        NSString *uuid=managedDisplayUUID(display);
        NSNumber *current=number(dictionary(display[@"Current Space"])[@"id64"]);
        NSArray *spaces=array(display[@"Spaces"]);
        if(!uuid.length || !current.unsignedLongLongValue || !spaces || !spaces.count)return nil;
        NSMutableArray *members=NSMutableArray.array;
        for(NSDictionary *space in spaces) {
            NSNumber *sid=number(space[@"id64"]),*type=number(space[@"type"]);
            if(!sid.unsignedLongLongValue || !type)return nil;
            [members addObject:@{@"id":sid,@"type":type}];
        }
        [rows addObject:@{@"display":uuid,@"current":current,@"spaces":members}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left,NSDictionary *right) {
        return [left[@"display"] compare:right[@"display"]];
    }];
    return rows;
}
bool closeMissionWithEscape(AXUIElementRef expectedMC,NSArray *expectedLayout) {
    if(!expectedMC || !expectedLayout || !CGPreflightPostEventAccess())return false;
    AXUIElementRef currentMC=nullptr;
    MissionState state=missionState(&currentMC);
    bool same=state==MissionState::Visible && currentMC && CFEqual(currentMC,expectedMC);
    if(currentMC)CFRelease(currentMC);
    NSArray *immediate=missionLayoutSnapshot();
    if(!same || !immediate || ![immediate isEqual:expectedLayout])return false;
    CGEventRef down=CGEventCreateKeyboardEvent(nullptr,53,true);
    CGEventRef up=CGEventCreateKeyboardEvent(nullptr,53,false);
    if(!down || !up) {
        if(down)CFRelease(down);if(up)CFRelease(up);return false;
    }
    CGEventSetFlags(down,0);CGEventSetFlags(up,0);
    // One bounded cleanup gesture, only after both events exist and all
    // identity/layout checks above passed.
    CGEventPost(kCGHIDEventTap,down);
    CGEventPost(kCGHIDEventTap,up);
    CFRelease(down);CFRelease(up);
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+3.0;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        MissionState after=missionState();
        if(after==MissionState::Absent) {
            NSArray *layout=missionLayoutSnapshot();
            return layout && [layout isEqual:expectedLayout];
        }
        usleep(50000);
    }
    return false;
}
bool closeMission() {
    MissionState state=missionState();
    if(state==MissionState::Absent)return true;
    if(state!=MissionState::Visible)return false;
    NSArray *expectedLayout=missionLayoutSnapshot();
    if(!expectedLayout)return false;
    CGDirectDisplayID ids[32],builtin=0;uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return false;
    for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(ids[i])){builtin=ids[i];break;}
    NSDictionary *display=builtInManaged(managed());
    NSArray *spaces=array(display[@"Spaces"]);
    uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    if(!builtin || !current || !spaces || spaces.count<1)return false;
    NSUInteger index=NSNotFound;
    for(NSUInteger i=0;i<spaces.count;i++) {
        NSDictionary *space=dictionary(spaces[i]);
        if(!space || !number(space[@"type"]) || !number(space[@"id64"]))return false;
        if([number(space[@"id64"]) unsignedLongLongValue]==current) {
            if([number(space[@"type"]) intValue]!=0)return false;
            index=i;
        }
    }
    AXUIElementRef list=missionList(@"mc.spaces.list",builtin,false);
    if(!list) {
        if(missionState()==MissionState::Absent) {
            NSArray *after=missionLayoutSnapshot();
            return after && [after isEqual:expectedLayout];
        }
        AXUIElementRef expectedMC=nullptr;
        MissionState fallbackState=missionState(&expectedMC);
        bool closed=fallbackState==MissionState::Visible && expectedMC
            && closeMissionWithEscape(expectedMC,expectedLayout);
        if(expectedMC)CFRelease(expectedMC);
        return closed;
    }
    NSArray *children=array(axAttribute(list,kAXChildrenAttribute));
    if(children.count!=spaces.count || index==NSNotFound) { CFRelease(list);return false; }
    NSArray *immediate=missionLayoutSnapshot();
    if(!immediate || ![immediate isEqual:expectedLayout]) { CFRelease(list);return false; }
    AXUIElementRef thumbnail=(__bridge AXUIElementRef)children[index];
    CFArrayRef actions=nullptr;
    AXError names=AXUIElementCopyActionNames(thumbnail,&actions);
    bool press=false;
    if(names==kAXErrorSuccess)for(NSString *action in (__bridge NSArray *)actions)
        if([action isEqualToString:(__bridge NSString *)kAXPressAction])press=true;
    if(actions)CFRelease(actions);
    bool wm27=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27;
    AXUIElementRef expectedMC=nullptr;
    if(wm27) {
        MissionState beforeAction=missionState(&expectedMC);
        if(beforeAction!=MissionState::Visible || !expectedMC
            || ![missionLayoutSnapshot() isEqual:expectedLayout]) {
            if(expectedMC)CFRelease(expectedMC);CFRelease(list);return false;
        }
    }
    AXError action=press ? AXUIElementPerformAction(thumbnail,kAXPressAction) : kAXErrorActionUnsupported;
    CFRelease(list);
    if(action!=kAXErrorSuccess) {if(expectedMC)CFRelease(expectedMC);return false;}
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+3.0;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        MissionState after=missionState();
        if(after==MissionState::Absent) {
            NSArray *layout=missionLayoutSnapshot();if(expectedMC)CFRelease(expectedMC);
            return layout && [layout isEqual:expectedLayout];
        }
        usleep(50000);
    }
    if(!wm27)return false;
    bool closed=closeMissionWithEscape(expectedMC,expectedLayout);CFRelease(expectedMC);
    return closed;
}
bool missionControlSwitchDisplaySpace(const std::string &uuid,uint64_t sid,int cid) {
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<27 || uuid.empty() || !sid
        || missionState()!=MissionState::Absent)return false;
    NSArray *inventory=managed();NSDictionary *selected=nil;NSUInteger index=NSNotFound;
    NSString *identity=[NSString stringWithUTF8String:uuid.c_str()];
    for(NSDictionary *candidate in inventory)if([managedDisplayUUID(candidate) isEqual:identity]) {
        if(selected)return false;selected=candidate;
    }
    NSArray *spaces=array(selected[@"Spaces"]);NSNumber *current=number(dictionary(selected[@"Current Space"])[@"id64"]);
    if(!selected || !spaces || !current.unsignedLongLongValue || current.unsignedLongLongValue==sid)return false;
    for(NSUInteger i=0;i<spaces.count;i++) {
        NSDictionary *space=dictionary(spaces[i]);NSNumber *spaceID=number(space[@"id64"]),*type=number(space[@"type"]);
        if(!spaceID.unsignedLongLongValue || !type)return false;
        if(spaceID.unsignedLongLongValue==sid) {
            if(index!=NSNotFound || (type.intValue!=0 && type.intValue!=4)
                || api().spaceType(cid,sid)!=type.intValue)return false;
            index=i;
        }
    }
    if(index==NSNotFound)return false;
    CGDirectDisplayID ids[32]={},displayID=0;uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return false;
    for(uint32_t i=0;i<count;i++)if([displayUUID(ids[i]) isEqual:identity]) {
        if(displayID)return false;displayID=ids[i];
    }
    NSArray *before=missionLayoutSnapshot();if(!displayID || !before)return false;
    NSMutableArray *after=[before mutableCopy];bool updated=false;
    for(NSUInteger i=0;i<after.count;i++) {
        NSDictionary *row=dictionary(after[i]);
        if(![row[@"display"] isEqual:identity])continue;
        if(updated || [number(row[@"current"]) unsignedLongLongValue]!=current.unsignedLongLongValue)return false;
        NSMutableDictionary *changed=[row mutableCopy];changed[@"current"]=@(sid);after[i]=changed;updated=true;
    }
    if(!updated || !openMission())return false;
    auto fail=[&] { if(missionState()==MissionState::Visible
            && [missionLayoutSnapshot() isEqual:before])closeMission();return false; };
    AXUIElementRef list=missionList(@"mc.spaces.list",displayID,false);
    if(!list)return fail();
    NSArray *children=array(axAttribute(list,kAXChildrenAttribute));
    if(children.count!=spaces.count || index>=children.count
        || ![missionLayoutSnapshot() isEqual:before]) {CFRelease(list);return fail();}
    AXUIElementRef thumbnail=(__bridge AXUIElementRef)children[index];CFArrayRef actions=nullptr;
    AXError names=AXUIElementCopyActionNames(thumbnail,&actions);bool canPress=false;
    if(names==kAXErrorSuccess)for(NSString *action in (__bridge NSArray *)actions)
        if([action isEqualToString:(__bridge NSString *)kAXPressAction])canPress=true;
    if(actions)CFRelease(actions);
    if(!canPress || ![missionLayoutSnapshot() isEqual:before]) {CFRelease(list);return fail();}
    AXError action=AXUIElementPerformAction(thumbnail,kAXPressAction);CFRelease(list);
    if(action!=kAXErrorSuccess)return fail();
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+4.0;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        if(missionState()==MissionState::Absent) {
            NSArray *actual=missionLayoutSnapshot();
            return actual && [actual isEqual:after]
                && currentSpaceForDisplay(managed(),uuid)==sid;
        }
        usleep(50000);
    }
    return false;
}
CGRect builtInContentBounds() {
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return CGRectNull;
    for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(ids[i])) {
        CGRect bounds=CGDisplayBounds(ids[i]);
        for(NSScreen *screen in NSScreen.screens) {
            NSNumber *screenID=number(screen.deviceDescription[@"NSScreenNumber"]);
            if(screenID.unsignedIntValue!=ids[i])continue;
            NSRect full=screen.frame,visible=screen.visibleFrame;
            return CGRectMake(bounds.origin.x+(visible.origin.x-full.origin.x),
                bounds.origin.y+(NSMaxY(full)-NSMaxY(visible)),
                visible.size.width,visible.size.height);
        }
        return CGRectInset(bounds,20,50);
    }
    return CGRectNull;
}
CGRect mappedFrame(const SavedWindow &w,CGRect content) {
    double width=std::min((double)w.frame.size.width,(double)content.size.width);
    double height=std::min((double)w.frame.size.height,(double)content.size.height);
    double sourceTravelX=std::max(1.0,(double)w.sourceDisplay.size.width-w.frame.size.width);
    double sourceTravelY=std::max(1.0,(double)w.sourceDisplay.size.height-w.frame.size.height);
    double x=std::max(0.0,std::min(1.0,((double)w.frame.origin.x-w.sourceDisplay.origin.x)/sourceTravelX));
    double y=std::max(0.0,std::min(1.0,((double)w.frame.origin.y-w.sourceDisplay.origin.y)/sourceTravelY));
    return CGRectMake(content.origin.x+x*(content.size.width-width),
        content.origin.y+y*(content.size.height-height),width,height);
}
CGRect mappedFinderFrame(const SavedWindow &w,CGRect content) {
    if(!exactFinderJournal(w) || !finderIntegerFrame(w.frame)
        || CGRectIsNull(content) || !std::isfinite(content.origin.x)
        || !std::isfinite(content.origin.y) || !std::isfinite(content.size.width)
        || !std::isfinite(content.size.height)
        || w.frame.size.width>content.size.width
        || w.frame.size.height>content.size.height)return CGRectNull;
    CGRect mapped=mappedFrame(w,content);
    double left=ceil(content.origin.x),top=ceil(content.origin.y);
    double right=floor(CGRectGetMaxX(content)-w.frame.size.width);
    double bottom=floor(CGRectGetMaxY(content)-w.frame.size.height);
    if(left>right || top>bottom)return CGRectNull;
    double x=std::clamp(round(mapped.origin.x),left,right);
    double y=std::clamp(round(mapped.origin.y),top,bottom);
    CGRect target=CGRectMake(x,y,w.frame.size.width,w.frame.size.height);
    return finderIntegerFrame(target) && CGRectContainsRect(content,target)
        ? target : CGRectNull;
}
bool windowOnDisplay(uint32_t wid,int cid,const std::string &uuid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->windowDisplay)return recoveryHooks->windowDisplay(wid,uuid);
#endif
    if(!api().windowDisplay || uuid.empty())return false;
    NSString *actual=CFBridgingRelease(api().windowDisplay(cid,wid));
    return [actual isEqualToString:[NSString stringWithUTF8String:uuid.c_str()]];
}
bool spaceOnDisplay(NSArray *all,uint64_t sid,const std::string &uuid) {
    for(NSDictionary *display in all) {
        NSString *displayUUID=display[@"Display Identifier"];
        if(!uuid.empty() && ![displayUUID isEqualToString:[NSString stringWithUTF8String:uuid.c_str()]])continue;
        for(NSDictionary *space in array(display[@"Spaces"]))
            if([number(space[@"id64"]) unsignedLongLongValue]==sid)return true;
    }
    return false;
}
uint64_t currentSpaceForDisplay(NSArray *all,const std::string &uuid) {
    if(uuid.empty())return 0;
    uint64_t current=0;bool found=false;
    for(NSDictionary *display in all) {
        NSString *identity=managedDisplayUUID(display);
        if(![identity isEqualToString:[NSString stringWithUTF8String:uuid.c_str()]])continue;
        if(found)return 0;
        found=true;
        current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    }
    return current;
}
// An ordered-out app surface on the currently selected desktop is left in
// place. If it later becomes a standard AX window, runtime routing captures
// it as a new window rather than treating its old CG ID as session baseline.
bool deferredInvisibleWindow(NSDictionary *original,uint32_t wid,pid_t pid,
                             NSString *bundle,CGRect frame,uint64_t sid,
                             const std::string &sourceUUID,int cid,
                             DeferredInvisibleWindow *result) {
    if(!original || !wid || pid<=0 || !bundle.length || !cid || sourceUUID.empty()
        || !api().windowSpaces || !api().windowDisplay || !api().axWindow
        || api().spaceType(cid,sid)!=0
        || currentSpaceForDisplay(managed(),sourceUUID)!=sid
        || !spaceOnDisplay(managed(),sid,sourceUUID)
        || !exactSingletonMembership(cid,wid,sid))return false;
    bool powered=false;CGDirectDisplayID displays[32]={};uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return false;
    for(uint32_t i=0;i<count;i++) {
        NSString *uuid=displayUUID(displays[i]);
        if([uuid isEqualToString:[NSString stringWithUTF8String:sourceUUID.c_str()]]
            && CGDisplayIsActive(displays[i]) && !CGDisplayIsAsleep(displays[i]))powered=true;
    }
    if(!powered)return false;
    NSString *title=original[(id)kCGWindowName],*owner=original[(id)kCGWindowOwnerName];
    NSNumber *alpha=number(original[(id)kCGWindowAlpha]);
    if(![title isKindOfClass:NSString.class])title=@"";
    if(![owner isKindOfClass:NSString.class])owner=@"";
    ProcessBirth birth=processBirth(pid);uint64_t tags=0;bool parentKnown=false;
    if(!birth.valid() || !alpha || alpha.doubleValue!=1
        || [number(original[(id)kCGWindowLayer]) intValue]!=0
        || !exactWindowTags(cid,wid,&tags) || !tags
        || exactWindowParent(cid,wid,&parentKnown)!=0 || !parentKnown)return false;
    for(int sample=0;sample<2;sample++) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(!app || app.terminated || app.hidden || ![app.bundleIdentifier isEqual:bundle]
            || !(birth==processBirth(pid))
            || currentSpaceForDisplay(managed(),sourceUUID)!=sid
            || !exactSingletonMembership(cid,wid,sid))return false;
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        NSArray *onscreen=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        if(!all || !onscreen || all.count>10000 || onscreen.count>10000)return false;
        NSUInteger found=0;CGRect current={};
        for(NSDictionary *cg in all)if([number(cg[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
            found++;NSString *currentTitle=cg[(id)kCGWindowName];
            NSString *currentOwner=cg[(id)kCGWindowOwnerName];
            if(![currentTitle isKindOfClass:NSString.class])currentTitle=@"";
            if(![currentOwner isKindOfClass:NSString.class])currentOwner=@"";
            if([number(cg[(id)kCGWindowOwnerPID]) intValue]!=pid
                || [number(cg[(id)kCGWindowLayer]) intValue]!=0
                || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
                || ![currentTitle isEqual:title]
                || ![currentOwner isEqual:owner]
                || !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&current)
                || !CGRectEqualToRect(current,frame))return false;
        }
        if(found!=1)return false;
        for(NSDictionary *cg in onscreen)
            if([number(cg[(id)kCGWindowNumber]) unsignedIntValue]==wid)return false;
        uint64_t observedTags=0;
        if(!exactWindowTags(cid,wid,&observedTags) || observedTags!=tags
            || oneWindowSpace(wid,cid)!=sid)return false;
        AXUIElementRef exposed=findAXWindow(pid,wid);
        if(exposed){CFRelease(exposed);return false;}
        DormantAXInventory ax=readDormantAXInventory(pid);
        if(!ax.readable || !ax.complete || !(ax.birth==birth) || ax.windows.count(wid))return false;
        AXUIElementRef application=AXUIElementCreateApplication(pid);
        if(!application)return false;
        bool exact=true;
        for(CFStringRef key : {kAXMainWindowAttribute,kAXFocusedWindowAttribute}) {
            CFTypeRef value=nullptr;pid_t ownerPID=0;CGWindowID other=0;
            AXError status=AXUIElementCopyAttributeValue(application,key,&value);
            exact=exact && status==kAXErrorSuccess && value
                && CFGetTypeID(value)==AXUIElementGetTypeID()
                && AXUIElementGetPid((AXUIElementRef)value,&ownerPID)==kAXErrorSuccess
                && ownerPID==pid && api().axWindow((AXUIElementRef)value,&other)==kAXErrorSuccess
                && other && other!=wid;
            if(value)CFRelease(value);
        }
        CFRelease(application);
        if(!exact || !(birth==processBirth(pid)))return false;
        if(sample==0)usleep(25000);
    }
    if(result)*result={wid,pid,birth,sid,tags,bundle.UTF8String,title.UTF8String,sourceUUID,frame};
    return true;
}
// An AX-inaccessible surface with an exact ordinary endpoint stays where it
// is. It can be enrolled by runtime routing if the app later exposes AX.
bool deferredUninspectableOrdinaryWindow(NSDictionary *original,uint32_t wid,pid_t pid,
                                         NSString *bundle,CGRect frame,uint64_t sid,
                                         const std::string &sourceUUID,int cid,
                                         DeferredInvisibleWindow *result) {
    if(!original || !wid || pid<=0 || !bundle.length || sourceUUID.empty()
        || api().spaceType(cid,sid)!=0 || !spaceOnDisplay(managed(),sid,sourceUUID))return false;
    ProcessBirth birth=processBirth(pid);
    if(!birth.valid() || [number(original[(id)kCGWindowLayer]) intValue]!=0)return false;
    CGRect freshFrame={};NSString *freshTitle=@"",*freshOwner=@"";
    NSNumber *freshAlpha=nil;
    for(int sample=0;sample<2;sample++) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(!app || app.terminated || ![app.bundleIdentifier isEqual:bundle]
            || !(birth==processBirth(pid)) || !exactSingletonMembership(cid,wid,sid)
            || !spaceOnDisplay(managed(),sid,sourceUUID))return false;
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        if(!all || all.count>10000)return false;
        NSUInteger matches=0;
        for(NSDictionary *cg in all)if([number(cg[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
            matches++;CGRect observed={};NSString *currentTitle=cg[(id)kCGWindowName];
            NSString *currentOwner=cg[(id)kCGWindowOwnerName];
            NSNumber *currentAlpha=number(cg[(id)kCGWindowAlpha]);
            if(![currentTitle isKindOfClass:NSString.class])currentTitle=@"";
            if(![currentOwner isKindOfClass:NSString.class])currentOwner=@"";
            if([number(cg[(id)kCGWindowOwnerPID]) intValue]!=pid
                || [number(cg[(id)kCGWindowLayer]) intValue]!=0
                || !currentAlpha
                || !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&observed))return false;
            if(sample==0) {
                freshFrame=observed;freshTitle=currentTitle;freshOwner=currentOwner;
                freshAlpha=currentAlpha;
            } else if(!CGRectEqualToRect(observed,freshFrame)
                || ![currentTitle isEqual:freshTitle]
                || ![currentOwner isEqual:freshOwner]
                || ![currentAlpha isEqual:freshAlpha])return false;
        }
        AXUIElementRef ax=findAXWindow(pid,wid);
        if(ax){CFRelease(ax);return false;}
        DormantAXInventory inventory=readDormantAXInventory(pid);
        if(!inventory.readable || !inventory.complete || !(inventory.birth==birth)
            || inventory.windows.count(wid))return false;
        if(matches!=1)return false;
        if(sample==0)usleep(25000);
    }
    if(result)*result={wid,pid,birth,sid,0,bundle.UTF8String,freshTitle.UTF8String,sourceUUID,freshFrame};
    return true;
}
// Read-only exception for a hidden, AX-absent surface whose cached display
// disagrees with its unique ordinary Space. Exposed windows remain blockers.
bool deferredStaleDisplaySurface(NSDictionary *info,uint32_t wid,pid_t pid,
                                 NSString *bundle,CGRect frame,uint64_t sid,int cid,
                                 DeferredInvisibleWindow *result) {
    if([number(info[(id)kCGWindowIsOnscreen]) boolValue])return false;
    std::string membershipDisplay;
    unsigned owners=0;
    for(NSDictionary *display in managed()) {
        NSString *uuid=managedDisplayUUID(display);
        if(uuid.length && spaceOnDisplay(@[display],sid,uuid.UTF8String)) {
            membershipDisplay=uuid.UTF8String;owners++;
        }
    }
    if(owners!=1 || !deferredUninspectableOrdinaryWindow(info,wid,pid,bundle,
        frame,sid,membershipDisplay,cid,result))return false;
    NSArray *visible=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    if(!visible)return false;
    for(NSDictionary *window in visible)
        if([number(window[(id)kCGWindowNumber]) unsignedIntValue]==wid)return false;
    return true;
}
// A CG surface with no Space and no exposed AX window has no valid migration
// endpoint. Leave it untouched; if it later gains both, runtime routing can
// inspect it as a newly exposed window.
bool deferredUnmappedNoAXWindow(NSDictionary *original,uint32_t wid,pid_t pid,
                                NSString *bundle,int cid,DeferredInvisibleWindow *result) {
    if(!original || !wid || pid<=0 || !bundle.length || !cid || !api().windowSpaces
        || [number(original[(id)kCGWindowLayer]) intValue]!=0)return false;
    CGRect frame={};NSString *title=original[(id)kCGWindowName];
    NSString *owner=original[(id)kCGWindowOwnerName];
    NSNumber *alpha=number(original[(id)kCGWindowAlpha]);
    if(![title isKindOfClass:NSString.class])title=@"";
    if(![owner isKindOfClass:NSString.class])owner=@"";
    ProcessBirth birth=processBirth(pid);
    if(!birth.valid() || !alpha
        || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(original[(id)kCGWindowBounds]),&frame))return false;
    for(int sample=0;sample<2;sample++) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!app || app.terminated || ![app.bundleIdentifier isEqual:bundle]
            || !(birth==processBirth(pid)) || !all || all.count>10000
            || !members || members.count)return false;
        NSUInteger matches=0;
        for(NSDictionary *cg in all)if([number(cg[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
            matches++;CGRect observed={};NSString *currentTitle=cg[(id)kCGWindowName];
            NSString *currentOwner=cg[(id)kCGWindowOwnerName];
            if(![currentTitle isKindOfClass:NSString.class])currentTitle=@"";
            if(![currentOwner isKindOfClass:NSString.class])currentOwner=@"";
            if([number(cg[(id)kCGWindowOwnerPID]) intValue]!=pid
                || [number(cg[(id)kCGWindowLayer]) intValue]!=0
                || ![number(cg[(id)kCGWindowAlpha]) isEqual:alpha]
                || ![currentOwner isEqual:owner]
                || ![currentTitle isEqual:title]
                || !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&observed)
                || !CGRectEqualToRect(observed,frame))return false;
        }
        AXUIElementRef ax=findAXWindow(pid,wid);
        if(ax){CFRelease(ax);return false;}
        DormantAXInventory inventory=readDormantAXInventory(pid);
        if(matches!=1 || !inventory.readable || !inventory.complete
            || !(inventory.birth==birth) || inventory.windows.count(wid))return false;
        if(sample==0)usleep(25000);
    }
    if(result)*result={wid,pid,birth,0,0,bundle.UTF8String,title.UTF8String,"",frame};
    return true;
}
void recordRetainedOrdinary(uint32_t wid,pid_t pid,uint64_t sid,
                            const std::string &display,CGRect frame,const char *reason) {
    ProcessBirth birth=processBirth(pid);
    retainedOrdinaryWindows.push_back({wid,pid,birth,sid,display,reason,frame});
    NSLog(@"RustDesk Air: retained ordinary window WID %u in original Space %llu (%s)",
        wid,(unsigned long long)sid,reason);
}
bool retainedOrdinaryStillOriginal(int cid) {
    for(const auto &w:retainedOrdinaryWindows) {
        if(!w.birth.valid() || !(processBirth(w.pid)==w.birth)
            || api().spaceType(cid,w.space)!=0
            || !spaceOnDisplay(managed(),w.space,w.displayUUID)
            || !exactSingletonMembership(cid,w.id,w.space)
            || !windowOnDisplay(w.id,cid,w.displayUUID))return false;
        CGRect frame={};
        if(!readCGFrame(w.id,w.pid,&frame) || !nearFrame(frame,w.frame))return false;
    }
    return true;
}
bool switchDisplaySpace(const std::string &uuid,uint64_t sid,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->switchDisplaySpace)return recoveryHooks->switchDisplaySpace(uuid,sid);
#endif
    NSArray *inventory=managed();
    if(!sid || uuid.empty() || !spaceOnDisplay(inventory,sid,uuid)
        || currentSpaceForDisplay(inventory,uuid)==0)return false;
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27) {
        if(currentSpaceForDisplay(inventory,uuid)==sid)return true;
        return missionControlSwitchDisplaySpace(uuid,sid,cid);
    }
    if(!bridgedSwitchAvailable())return false;
    NSString *display=[NSString stringWithUTF8String:uuid.c_str()];
    Class bridged=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    id operation=[[bridged alloc] initWithDisplayIdentifier:display spaceID:sid];
    if(!operation)return false;
    [operation performWithWMBridgeDelegate];
    for(int retry=0;retry<80;retry++) {
        if(currentSpaceForDisplay(managed(),uuid)==sid)return true;
        usleep(25000);
    }
    return false;
}
enum class RecoverySpaceAccess { NotNeeded, Ready, Failed };
DisplaySelection *selectionForDisplay(const std::string &uuid);
bool beginHostSelection(const std::string &uuid,uint64_t target,int windowIndex,
                        SelectionPurpose purpose,int cid);
bool exactOwnedTemporaryDisplay(NSArray *inventory,uint64_t sid,int cid,
                                std::string *currentDisplay,std::string *reason) {
    if(currentDisplay)currentDisplay->clear();
    if(!inventory || !sid || std::count(createdSpaces.begin(),createdSpaces.end(),sid)!=1) {
        if(reason)*reason="the window's temporary Space is not uniquely journal-owned";
        return false;
    }
    auto owner=std::find_if(ownedSpaces.begin(),ownedSpaces.end(),
        [&](const OwnedSpace &candidate){return candidate.id==sid;});
    if(owner==ownedSpaces.end() || std::count_if(ownedSpaces.begin(),ownedSpaces.end(),
            [&](const OwnedSpace &candidate){return candidate.id==sid;})!=1
        || owner->uuid.empty() || owner->displayUUID.empty()) {
        if(reason)*reason="the window's temporary Space has no exact journal identity";
        return false;
    }
    NSString *expected=[NSString stringWithUTF8String:owner->uuid.c_str()];
    NSString *foundDisplay=nil;NSUInteger matches=0;
    for(NSDictionary *display in inventory) {
        NSDictionary *space=managedSpace(display,sid);
        if(!space)continue;
        matches++;
        NSString *identity=managedSpaceUUID(space),*displayIdentity=managedDisplayUUID(display);
        if(!identity || !displayIdentity || ![identity isEqualToString:expected]
            || api().spaceType(cid,sid)!=0) {
            if(reason)*reason="the window's temporary Space conflicts with its journal identity";
            return false;
        }
        foundDisplay=displayIdentity;
    }
    if(matches!=1 || !foundDisplay.length) {
        if(reason)*reason=matches ? "the window's temporary Space is present on multiple displays"
                                 : "the window's temporary Space is unavailable";
        return false;
    }
    if(currentDisplay)*currentDisplay=foundDisplay.UTF8String;
    return true;
}
RecoverySpaceAccess prepareRecoveryWindowAccess(const SavedWindow &w,int cid,std::string *reason) {
    if(w.cgOnly)return RecoverySpaceAccess::NotNeeded;
    uint64_t temporary=oneWindowSpace(w.id,cid);
    bool owned=std::find(createdSpaces.begin(),createdSpaces.end(),temporary)!=createdSpaces.end();
    bool reused=std::count_if(reusedSlots.begin(),reusedSlots.end(),
        [&](const OwnedSpace &space){return space.id==temporary;})==1;
    if(!temporary || (!owned && !reused))return RecoverySpaceAccess::NotNeeded;
    std::string display;
    if(reused) {
        NSArray *inventory=managed();
        if(!ownedSlotsStillOrdered(builtInManaged(inventory),cid)
            || !windowOnDisplay(w.id,cid,builtinUUID)) {
            if(reason)*reason="the window's reusable Space changed its journaled identity";
            return RecoverySpaceAccess::Failed;
        }
        display=builtinUUID;
    } else if(!exactOwnedTemporaryDisplay(managed(),temporary,cid,&display,reason))
        return RecoverySpaceAccess::Failed;
    uint64_t current=currentSpaceForDisplay(managed(),display);
    if(reused && current) {
        DisplaySelection *selection=selectionForDisplay(display);
        if(!selection)return RecoverySpaceAccess::Failed;
        if(selection->hostSpace!=current) {
            if(lastSelectedSpace!=current
                || std::find(std::begin(slots),std::end(slots),current)==std::end(slots)) {
                if(reason)*reason="the built-in display selected an unrelated Space during recovery";
                return RecoverySpaceAccess::Failed;
            }
            uint64_t prior=selection->hostSpace;
            selection->hostSpace=current;
            if(!persist()) {
                selection->hostSpace=prior;
                if(reason)*reason="the verified reusable Space selection could not be journaled";
                return RecoverySpaceAccess::Failed;
            }
        }
    }
    bool selected=current==temporary;
    if(!selected && current && reused) {
        DisplaySelection *selection=selectionForDisplay(display);
        selected=selection && selection->hostSpace==current
            && beginHostSelection(display,temporary,-1,SelectionPurpose::RestoreAnchor,cid);
    } else if(!selected && current)selected=switchDisplaySpace(display,temporary,cid);
    if(!selected) {
        if(reason)*reason="the exact temporary Space could not be selected for window recovery";
        return RecoverySpaceAccess::Failed;
    }
    std::string verifiedDisplay;
    bool verified=reused
        ? ownedSlotsStillOrdered(builtInManaged(managed()),cid)
            && windowOnDisplay(w.id,cid,builtinUUID)
        : exactOwnedTemporaryDisplay(managed(),temporary,cid,&verifiedDisplay,reason);
    if(reused)verifiedDisplay=builtinUUID;
    if(!verified
        || verifiedDisplay!=display || currentSpaceForDisplay(managed(),display)!=temporary
        || oneWindowSpace(w.id,cid)!=temporary) {
        if(reason && reason->empty())*reason="the selected temporary Space changed identity during window recovery";
        return RecoverySpaceAccess::Failed;
    }
    return RecoverySpaceAccess::Ready;
}
RecoverySpaceAccess prepareOriginalWindowAccess(const SavedWindow &w,int cid,std::string *reason) {
    if(w.cgOnly || !w.space || w.sourceUUID.empty()
        || oneWindowSpace(w.id,cid)!=w.space)return RecoverySpaceAccess::NotNeeded;
    NSArray *inventory=managed();
    if(!spaceOnDisplay(inventory,w.space,w.sourceUUID)
        || api().spaceType(cid,w.space)!=0) {
        if(reason)*reason="the journaled original Space is unavailable for Accessibility reacquisition";
        return RecoverySpaceAccess::Failed;
    }
    uint64_t current=currentSpaceForDisplay(inventory,w.sourceUUID);
    if(!current) {
        if(reason)*reason="the original display has no selected Space for Accessibility reacquisition";
        return RecoverySpaceAccess::Failed;
    }
    if(current==w.space)return RecoverySpaceAccess::NotNeeded;
    DisplaySelection *selection=selectionForDisplay(w.sourceUUID);
    if(!selection) {
        if(reason)*reason="the original display has no journaled selection identity";
        return RecoverySpaceAccess::Failed;
    }
    bool selected=false;
    if(w.sourceUUID==builtinUUID && w.space==initialSpace
        && std::count(createdSpaces.begin(),createdSpaces.end(),current)==1)
        selected=switchSpace(w.space,cid);
    else if(current==selection->hostSpace)
        selected=beginHostSelection(w.sourceUUID,w.space,-1,SelectionPurpose::RestoreAnchor,cid);
    if(!selected || currentSpaceForDisplay(managed(),w.sourceUUID)!=w.space
        || oneWindowSpace(w.id,cid)!=w.space) {
        if(reason)*reason="the original Space could not be selected from a journaled Host-controlled selection";
        return RecoverySpaceAccess::Failed;
    }
    return RecoverySpaceAccess::Ready;
}
bool recoveryEndpointsAvailable(const std::vector<std::string> &online,NSArray *inventory,
                                bool preparationOnly,int cid,std::string *reason) {
    for(size_t index=0;index<saved.size();index++) {
        const SavedWindow &w=saved[index];
        if(preparationOnly && (!w.fullScreen
            || ((int)index!=initialFullScreenIndex && w.fullScreenPhase==1)))continue;
        if(w.sourceUUID.empty()
            || std::count(online.begin(),online.end(),w.sourceUUID)!=1) {
            if(reason)*reason="The original display "+w.sourceUUID
                +" for a journaled window is offline; no window was moved or frame-restored";
            return false;
        }
        NSUInteger managedMatches=0;
        NSString *source=[NSString stringWithUTF8String:w.sourceUUID.c_str()];
        for(NSDictionary *display in inventory)
            if([managedDisplayUUID(display) isEqualToString:source])managedMatches++;
        if(managedMatches!=1) {
            if(reason)*reason="The original display "+w.sourceUUID
                +" has no unique managed Space inventory; no window was moved or frame-restored";
            return false;
        }
        bool needsOrdinaryEndpoint=!w.fullScreen || w.fullScreenPhase==2 || w.fullScreenPhase==3;
        if(needsOrdinaryEndpoint && (!spaceOnDisplay(inventory,w.space,w.sourceUUID)
                || api().spaceType(cid,w.space)!=0)) {
            if(reason)*reason="The original Space on display "+w.sourceUUID
                +" is unavailable; no window was moved or frame-restored";
            return false;
        }
    }
    return true;
}
bool wholeMoveAvailable();
bool moveWholeSpace(uint64_t sid,const std::string &destination,uint32_t index,int cid) {
    auto order=wholeDisplayOrder();
    air::whole_space::Topology before;
    if(!wholeMoveAvailable() || !sid || destination.empty() || api().spaceType(cid,sid)!=0
        || !wholeTopology(managed(),order,before))return false;
    unsigned occurrences=0;
    for(const auto &display:before.displays)for(uint64_t candidate:display.order)
        if(candidate==sid)occurrences++;
    const auto found=std::find_if(before.displays.begin(),before.displays.end(),
        [&](const air::whole_space::Display &display){return display.uuid==destination;});
    if(occurrences!=1 || found==before.displays.end() || index>found->order.size())return false;
    Class cls=NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
    NSString *display=[NSString stringWithUTF8String:destination.c_str()];
    id operation=[[cls alloc] initWithSpaceID:sid displayIdentifier:display index:index];
    if(!operation)return false;
    [operation performWithWMBridgeDelegate];
    for(int retry=0;retry<80;retry++) {
        air::whole_space::Topology after;
        if(wholeTopology(managed(),order,after)) {
            unsigned matches=0;
            for(const auto &candidate:after.displays)for(size_t position=0;position<candidate.order.size();position++)
                if(candidate.order[position]==sid && candidate.uuid==destination && position==index)matches++;
            if(matches==1)return true;
        }
        usleep(25000);
    }
    return false;
}
bool fullScreenSpaceIdentity(const WholeFullScreenSpace &space,const std::string &display,int cid,
                             bool originalFrame=false) {
    if(api().spaceType(cid,space.sid)!=4)return false;
    NSArray *inventory=managed();NSDictionary *found=nil;unsigned occurrences=0;
    for(NSDictionary *row in inventory)for(NSDictionary *candidate in array(row[@"Spaces"]))
        if([number(candidate[@"id64"]) unsignedLongLongValue]==space.sid) {
            occurrences++;
            if([managedDisplayUUID(row) isEqualToString:
                [NSString stringWithUTF8String:display.c_str()]])found=candidate;
        }
    if(occurrences!=1 || !found || ![managedSpaceUUID(found) isEqualToString:
        [NSString stringWithUTF8String:space.uuid.c_str()]]
        || [number(found[@"fs_wid"]) unsignedIntValue]!=space.owner
        || [number(found[@"pid"]) intValue]!=space.pid)return false;
    ProcessBirth birth=processBirth(space.pid);
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:space.pid];
    if(birth.seconds!=space.birthSeconds || birth.microseconds!=space.birthMicroseconds
        || !app || app.terminated || ![app.bundleIdentifier isEqualToString:
            [NSString stringWithUTF8String:space.bundle.c_str()]]
        || fabs(stableLaunchTime(app,space.pid)-space.launchTime)>1)return false;
    NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(space.owner)]));
    CGRect frame={};
    return members.count==1 && [number(members[0]) unsignedLongLongValue]==space.sid
        && windowOnDisplay(space.owner,cid,display)
        && readCGFrame(space.owner,space.pid,&frame)
        && (!originalFrame || nearFrame(frame,space.ownerFrame));
}
bool originalFullScreenSurfaces(const WholeFullScreenSpace &space,int cid) {
    if(!fullScreenSpaceIdentity(space,space.sourceDisplay,cid,true))return false;
    for(const auto &surface:space.surfaces) {
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(surface.wid)]));
        CGRect frame={};
        if(members.count!=1 || [number(members[0]) unsignedLongLongValue]!=space.sid
            || !windowOnDisplay(surface.wid,cid,space.sourceDisplay)
            || !readCGFrame(surface.wid,space.pid,&frame)
            || !nearFrame(frame,surface.frame))return false;
    }
    return true;
}
bool expectedFullScreenTopology(const air::whole_space::Topology &before,
                                uint64_t sid,const std::string &destination,uint32_t index,
                                air::whole_space::Topology &after) {
    after=before;air::whole_space::Display *from=nullptr,*to=nullptr;
    size_t sourceIndex=0;unsigned count=0;
    for(auto &display:after.displays)for(size_t i=0;i<display.order.size();i++)
        if(display.order[i]==sid){from=&display;sourceIndex=i;count++;}
    for(auto &display:after.displays)if(display.uuid==destination)to=&display;
    if(count!=1 || !from || !to || from==to || from->current==sid || index>to->order.size())return false;
    uint64_t moving=from->order[sourceIndex];std::string uuid=from->spaceUUIDs[sourceIndex];
    from->order.erase(from->order.begin()+sourceIndex);
    from->spaceUUIDs.erase(from->spaceUUIDs.begin()+sourceIndex);
    to->order.insert(to->order.begin()+index,moving);
    to->spaceUUIDs.insert(to->spaceUUIDs.begin()+index,std::move(uuid));
    return true;
}
bool advanceWholeFullScreen(bool reverse,int cid,std::string &reason) {
    if(!reverse && (wholeFullScreenReverseDone || wholeFullScreenSelectionRestoreStarted)) {
        reason="fullscreen migration is already restoring";return false;
    }
    uint32_t &done=reverse ? wholeFullScreenReverseDone : wholeFullScreenForwardDone;
    if(done>=(reverse ? wholeFullScreenForwardDone : wholeFullScreenMoves.size()))return true;
    uint32_t ordinal=done;
    uint32_t recordIndex=wholeFullScreenMoves[reverse
        ? wholeFullScreenForwardDone-1-ordinal : ordinal];
    const WholeFullScreenSpace &space=wholeFullScreens[recordIndex];
    std::string destination=reverse ? space.sourceDisplay : builtinUUID;
    air::whole_space::Topology current;
    if(!wholeTopology(managed(),wholeDisplayOrder(),current)) {
        reason="managed fullscreen topology is unavailable";return false;
    }
    if(wholeFullScreenPending.active) {
        if(wholeFullScreenPending.reverse!=reverse || wholeFullScreenPending.ordinal!=ordinal) {
            reason="fullscreen move journal order is inconsistent";return false;
        }
    } else {
        if(missionState()!=MissionState::Absent
            || !fullScreenSpaceIdentity(space,reverse ? builtinUUID : space.sourceDisplay,cid)) {
            reason="fullscreen owner or Mission Control changed before move";return false;
        }
        const air::whole_space::Display *target=nullptr;
        for(const auto &display:current.displays)if(display.uuid==destination)target=&display;
        if(!target || api().spaceType(cid,target->current)!=0) {
            reason="fullscreen move destination has no ordinary anchor";return false;
        }
        uint32_t index=reverse ? space.sourceIndex : (uint32_t)target->order.size();
        air::whole_space::Topology after;
        if(!expectedFullScreenTopology(current,space.sid,destination,index,after)) {
            reason="fullscreen move endpoint is invalid";return false;
        }
        wholeFullScreenPending={true,reverse,ordinal,current,after};
        if(!persist()){reason="cannot journal fullscreen move: "+journalIOError;return false;}
    }
    auto &pending=wholeFullScreenPending;
    bool before=sameWholeTopology(current,pending.before);
    bool after=sameWholeTopology(current,pending.after);
    if(!before && !after) {
        reason="fullscreen move endpoint differs from durable topology";return false;
    }
    if(before) {
        if(!fullScreenSpaceIdentity(space,reverse ? builtinUUID : space.sourceDisplay,cid)
            || missionState()!=MissionState::Absent) {
            reason="fullscreen owner changed before durable move";return false;
        }
        const auto &target=pending.after.displays;
        uint32_t index=0;bool found=false;
        for(const auto &display:target)if(display.uuid==destination)
            for(size_t i=0;i<display.order.size();i++)if(display.order[i]==space.sid){index=(uint32_t)i;found=true;}
        if(!found){reason="fullscreen destination index is absent";return false;}
        Class cls=NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
        id operation=[[cls alloc] initWithSpaceID:space.sid
            displayIdentifier:[NSString stringWithUTF8String:destination.c_str()] index:index];
        if(!operation){reason="fullscreen native move operation is unavailable";return false;}
        [operation performWithWMBridgeDelegate];
        bool arrived=false;
        for(int retry=0;retry<80;retry++) {
            air::whole_space::Topology sample;
            if(wholeTopology(managed(),wholeDisplayOrder(),sample)
                && sameWholeTopology(sample,pending.after)
                && fullScreenSpaceIdentity(space,destination,cid)) {arrived=true;break;}
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
            usleep(1000);
        }
        if(!arrived){reason="fullscreen move did not reach its exact endpoint";return false;}
    } else if(!fullScreenSpaceIdentity(space,destination,cid)) {
        reason="fullscreen Space endpoint lacks its original owner";return false;
    }
    WholeFullScreenPending completed=pending;
    done++;pending={};
    if(!persist()) {
        --done;pending=std::move(completed);
        reason="cannot record fullscreen move completion: "+journalIOError;return false;
    }
    return true;
}
bool originalWholeFullScreensRestored(const air::whole_space::Topology &topology,int cid) {
    // An app can create a new fullscreen Space while recovery is running.
    // Verify every journaled Space's original type and owner, but preserve
    // unrelated new fullscreen Spaces instead of blocking cleanup forever.
    std::set<uint64_t> originalIDs,originalFullScreenIDs;
    for(const auto &display:wholeJournal.original.displays)
        originalIDs.insert(display.order.begin(),display.order.end());
    for(const auto &space:wholeFullScreens)
        if(!originalFullScreenIDs.insert(space.sid).second)return false;
    for(const auto &display:topology.displays)
        for(uint64_t sid:display.order) {
            int type=api().spaceType(cid,sid);
            if(originalIDs.count(sid)) {
                if(type!=(originalFullScreenIDs.count(sid) ? 4 : 0))return false;
            } else if(type!=0 && type!=4)return false;
        }
    for(const auto &space:wholeFullScreens) {
        const air::whole_space::Display *source=nullptr;
        for(const auto &display:topology.displays)
            if(display.uuid==space.sourceDisplay)source=&display;
        if(!source || space.sourceIndex>=source->order.size()
            || source->order[space.sourceIndex]!=space.sid
            || source->spaceUUIDs[space.sourceIndex]!=space.uuid
            || !originalFullScreenSurfaces(space,cid))return false;
    }
    return true;
}
enum class WholeFullScreenForwardEndpoint { Before, After, Unknown };
WholeFullScreenForwardEndpoint fullScreenForwardEndpoint(
    const WholeFullScreenPending &pending,const air::whole_space::Topology &actual) {
    if(!pending.active || pending.reverse)return WholeFullScreenForwardEndpoint::Unknown;
    if(sameWholeTopology(actual,pending.before))return WholeFullScreenForwardEndpoint::Before;
    if(sameWholeTopology(actual,pending.after))return WholeFullScreenForwardEndpoint::After;
    return WholeFullScreenForwardEndpoint::Unknown;
}
bool reconcileWholeFullScreenForwardForRestore(int cid,std::string &reason) {
    if(!wholeFullScreenPending.active || wholeFullScreenPending.reverse)return true;
    if(wholeFullScreenPending.ordinal!=wholeFullScreenForwardDone
        || wholeFullScreenForwardDone>=wholeFullScreenMoves.size()) {
        reason="pending fullscreen forward move has an invalid ordinal";return false;
    }
    const auto &space=wholeFullScreens[wholeFullScreenMoves[wholeFullScreenForwardDone]];
    air::whole_space::Topology actual;
    if(!wholeTopology(managed(),wholeDisplayOrder(),actual)) {
        reason="pending fullscreen forward topology is unreadable";return false;
    }
    auto endpoint=fullScreenForwardEndpoint(wholeFullScreenPending,actual);
    if(endpoint==WholeFullScreenForwardEndpoint::After)
        return advanceWholeFullScreen(false,cid,reason);
    if(endpoint!=WholeFullScreenForwardEndpoint::Before
        || missionState()!=MissionState::Absent
        || !fullScreenSpaceIdentity(space,space.sourceDisplay,cid)) {
        reason="pending fullscreen move differs from its exact source and destination";return false;
    }
    for(int sample=0;sample<8;sample++) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if(!wholeTopology(managed(),wholeDisplayOrder(),actual)
            || fullScreenForwardEndpoint(wholeFullScreenPending,actual)
                !=WholeFullScreenForwardEndpoint::Before
            || !fullScreenSpaceIdentity(space,space.sourceDisplay,cid)) {
            reason="pending fullscreen move has not settled at its source";return false;
        }
    }
    WholeFullScreenPending canceled=wholeFullScreenPending;
    wholeFullScreenPending={};
    if(!persist()) {
        wholeFullScreenPending=std::move(canceled);
        reason="cannot journal cancellation of an unperformed fullscreen move: "+journalIOError;
        return false;
    }
    return true;
}
bool wholeSelectedRestoreStageTopology(const air::whole_space::Topology &,int);
bool advanceWholeFullScreenSelection(bool restore,int cid,std::string &reason) {
    uint32_t &done=restore ? wholeFullScreenSelectionDone : wholeFullScreenAnchorDone;
    if(done>=wholeFullScreenSelections.size())return true;
    uint32_t ordinal=done;
    const auto &selection=wholeFullScreenSelections[ordinal];
    const auto &space=wholeFullScreens[selection.recordIndex];
    uint64_t source=restore ? selection.anchor : space.sid;
    uint64_t target=restore ? space.sid : selection.anchor;
    air::whole_space::Topology current;
    if(!wholeTopology(managed(),wholeDisplayOrder(),current)) {
        reason="fullscreen display selection topology is unavailable";return false;
    }
    if(wholeFullScreenSelectionPending.active) {
        if(wholeFullScreenSelectionPending.restore!=restore
            || wholeFullScreenSelectionPending.ordinal!=ordinal) {
            reason="fullscreen selection journal order is inconsistent";return false;
        }
    } else {
        if(restore && !wholeSelectedRestoreStageTopology(current,cid)) {
            reason="original fullscreen selection stage has unrelated topology changes";return false;
        }
        air::whole_space::Topology after=current;
        bool located=false;
        for(auto &display:after.displays)if(display.uuid==space.sourceDisplay) {
            if(display.current!=source
                || std::find(display.order.begin(),display.order.end(),target)==display.order.end()) {
                reason="fullscreen selection source or target changed";return false;
            }
            display.current=target;located=true;
        }
        if(!located || missionState()!=MissionState::Absent
            || !fullScreenSpaceIdentity(space,space.sourceDisplay,cid)) {
            reason="fullscreen selection owner or Mission Control changed";return false;
        }
        wholeFullScreenSelectionPending={true,restore,ordinal,current,after};
        if(!persist()){reason="cannot journal fullscreen selection: "+journalIOError;return false;}
    }
    auto &pending=wholeFullScreenSelectionPending;
    bool before=sameWholeTopology(current,pending.before);
    bool after=sameWholeTopology(current,pending.after);
    if(!before && !after) {
        reason="fullscreen selection differs from its durable endpoints";return false;
    }
    if(before) {
        if(!fullScreenSpaceIdentity(space,space.sourceDisplay,cid)
            || missionState()!=MissionState::Absent || !bridgedSwitchAvailable()) {
            reason="fullscreen selection owner or native operation is unavailable";return false;
        }
        Class cls=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
        id operation=[[cls alloc] initWithDisplayIdentifier:
            [NSString stringWithUTF8String:space.sourceDisplay.c_str()] spaceID:target];
        if(!operation){reason="fullscreen native selection operation is unavailable";return false;}
        [operation performWithWMBridgeDelegate];
        bool arrived=false;
        for(int retry=0;retry<80;retry++) {
            air::whole_space::Topology sample;
            if(wholeTopology(managed(),wholeDisplayOrder(),sample)
                && sameWholeTopology(sample,pending.after)
                && fullScreenSpaceIdentity(space,space.sourceDisplay,cid)) {arrived=true;break;}
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
            usleep(1000);
        }
        if(!arrived){reason="fullscreen selection did not reach its exact endpoint";return false;}
    } else if(!fullScreenSpaceIdentity(space,space.sourceDisplay,cid)) {
        reason="fullscreen selected endpoint lacks its original owner";return false;
    }
    WholeFullScreenSelectionPending completed=pending;
    done++;pending={};
    if(!persist()) {
        --done;pending=std::move(completed);
        reason="cannot record fullscreen selection completion: "+journalIOError;return false;
    }
    return true;
}
bool wholeRuntimeTopologyWithFullScreens(const air::whole_space::Topology &actual,int cid) {
    if(wholeFullScreenRuntimePending.active)return false;
    if(wholeFullScreenForwardDone!=wholeFullScreenMoves.size()
        || wholeFullScreenReverseDone)return false;
    for(const auto &space:wholeFullScreens)
        if(!fullScreenSpaceIdentity(space,builtinUUID,cid))return false;
    air::whole_space::Topology projected=actual;
    if(wholeFullScreenRuntimeIndex>=0) {
        const auto &space=wholeFullScreens[wholeFullScreenRuntimeIndex];
        bool found=false;
        for(auto &display:projected.displays)if(display.uuid==builtinUUID) {
            if(display.current!=space.sid)return false;
            display.current=wholeJournal.runtimeCurrent;found=true;
        }
        if(!found)return false;
    }
    return air::whole_space::runtimeTopology(wholeJournal,projected);
}
bool reconcileWholeFullScreenRuntimePending(int cid,std::string &reason) {
    if(!wholeFullScreenRuntimePending.active)return true;
    air::whole_space::Topology current;
    if(!wholeTopology(managed(),wholeDisplayOrder(),current)) {
        reason="fullscreen runtime selection topology is unavailable";return false;
    }
    int settledIndex=-2;
    if(sameWholeTopology(current,wholeFullScreenRuntimePending.before))
        settledIndex=wholeFullScreenRuntimeIndex;
    else if(sameWholeTopology(current,wholeFullScreenRuntimePending.after))
        settledIndex=wholeFullScreenRuntimePending.targetIndex;
    if(settledIndex==-2 || (settledIndex>=0
        && !fullScreenSpaceIdentity(wholeFullScreens[settledIndex],builtinUUID,cid))) {
        reason="fullscreen runtime selection differs from its durable endpoints";return false;
    }
    int original=wholeFullScreenRuntimeIndex;
    WholeFullScreenRuntimePending pending=wholeFullScreenRuntimePending;
    wholeFullScreenRuntimeIndex=settledIndex;wholeFullScreenRuntimePending={};
    if(!persist()) {
        wholeFullScreenRuntimeIndex=original;wholeFullScreenRuntimePending=std::move(pending);
        reason="cannot reconcile fullscreen runtime selection: "+journalIOError;return false;
    }
    return true;
}
bool adoptObservedWholeRuntimeSelection(int cid) {
    if(wholeFullScreenRuntimePending.active || wholeJournal.runtimeSelectionPending.active)return false;
    air::whole_space::Topology actual;
    if(!wholeTopology(managed(),wholeDisplayOrder(),actual))return false;
    if(wholeRuntimeTopologyWithFullScreens(actual,cid))return true;
    for(const auto &space:wholeFullScreens)
        if(!fullScreenSpaceIdentity(space,builtinUUID,cid))return false;
    uint64_t selected=0;
    for(const auto &display:actual.displays)if(display.uuid==builtinUUID)selected=display.current;
    int extra=-1;
    for(size_t i=0;i<wholeFullScreens.size();i++)
        if(wholeFullScreens[i].sid==selected)extra=(int)i;
    if(extra>=0) {
        air::whole_space::Topology projected=actual;
        for(auto &display:projected.displays)if(display.uuid==builtinUUID)
            display.current=wholeJournal.runtimeCurrent;
        if(!air::whole_space::runtimeTopology(wholeJournal,projected))return false;
        int previous=wholeFullScreenRuntimeIndex;wholeFullScreenRuntimeIndex=extra;
        if(!persist()){wholeFullScreenRuntimeIndex=previous;return false;}
        return true;
    }
    bool primary=false;
    for(uint64_t sid:wholeJournal.selected)if(sid==selected)primary=true;
    if(!primary)return false;
    auto journal=wholeJournal;
    journal.runtimeCurrent=selected;
    if(!air::whole_space::runtimeTopology(journal,actual))return false;
    int previous=wholeFullScreenRuntimeIndex;
    uint64_t oldRuntime=wholeJournal.runtimeCurrent,oldSelected=lastSelectedSpace;
    wholeFullScreenRuntimeIndex=-1;wholeJournal.runtimeCurrent=selected;
    lastSelectedSpace=selected;
    if(!persist()) {
        wholeFullScreenRuntimeIndex=previous;wholeJournal.runtimeCurrent=oldRuntime;
        lastSelectedSpace=oldSelected;return false;
    }
    return true;
}
bool selectWholeFullScreenRuntime(int targetIndex,int cid,std::string &reason) {
    if(targetIndex<-1 || targetIndex>=(int)wholeFullScreens.size()
        || wholeJournal.forwardDone!=4 || wholeJournal.reverseDone
        || wholeFullScreenForwardDone!=wholeFullScreenMoves.size()
        || wholeFullScreenReverseDone || missionState()!=MissionState::Absent
        || !reconcileWholeFullScreenRuntimePending(cid,reason)) {
        if(reason.empty())reason="fullscreen runtime selection is unavailable";
        return false;
    }
    if(wholeFullScreenRuntimeIndex==targetIndex)return true;
    air::whole_space::Topology before;
    if(!wholeTopology(managed(),wholeDisplayOrder(),before)
        || !wholeRuntimeTopologyWithFullScreens(before,cid)) {
        reason="fullscreen runtime topology changed before selection";return false;
    }
    uint64_t sid=targetIndex>=0 ? wholeFullScreens[targetIndex].sid : wholeJournal.runtimeCurrent;
    air::whole_space::Topology after=before;bool found=false;
    for(auto &display:after.displays)if(display.uuid==builtinUUID) {
        display.current=sid;found=true;
    }
    if(!found || !bridgedSwitchAvailable()) {
        reason="fullscreen runtime selection bridge is unavailable";return false;
    }
    wholeFullScreenRuntimePending={true,targetIndex,before,after};
    if(!persist()) {
        wholeFullScreenRuntimePending={};
        reason="cannot journal fullscreen runtime selection: "+journalIOError;return false;
    }
    Class cls=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    id operation=[[cls alloc] initWithDisplayIdentifier:
        [NSString stringWithUTF8String:builtinUUID.c_str()] spaceID:sid];
    if(!operation){reason="fullscreen runtime selection operation is unavailable";return false;}
    [operation performWithWMBridgeDelegate];
    bool arrived=false;
    for(int retry=0;retry<80;retry++) {
        air::whole_space::Topology sample;
        if(wholeTopology(managed(),wholeDisplayOrder(),sample)
            && sameWholeTopology(sample,wholeFullScreenRuntimePending.after)
            && (targetIndex<0 || fullScreenSpaceIdentity(
                wholeFullScreens[targetIndex],builtinUUID,cid))) {arrived=true;break;}
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
        usleep(1000);
    }
    if(!arrived){reason="fullscreen runtime selection did not reach its exact endpoint";return false;}
    return reconcileWholeFullScreenRuntimePending(cid,reason);
}
air::whole_space::Hooks wholeHooks(int cid) {
    return {
        [](const air::whole_space::Journal &journal) {
            lastSelectedSpace=journal.runtimeCurrent;
            return persist();
        },
        [] {
            air::whole_space::Topology topology;
            wholeTopology(managed(),wholeDisplayOrder(),topology);
            return topology;
        },
        [cid](uint64_t sid,const std::string &display,uint32_t index) {
            return moveWholeSpace(sid,display,index,cid);
        },
        [cid](const std::string &display,uint64_t sid) {
            return switchDisplaySpace(display,sid,cid);
        }
    };
}
DisplaySelection *selectionForDisplay(const std::string &uuid) {
    auto found=std::find_if(initialSelections.begin(),initialSelections.end(),[&](const DisplaySelection &item){return item.displayUUID==uuid;});
    return found==initialSelections.end() ? nullptr : &*found;
}
bool beginHostSelection(const std::string &uuid,uint64_t target,int windowIndex,SelectionPurpose purpose,int cid) {
    DisplaySelection *display=selectionForDisplay(uuid);
    if(selectionPending.active || !display || !display->hostSpace || !target || target==display->hostSpace)return false;
    uint64_t current=currentSpaceForDisplay(managed(),uuid);
    if(current!=display->hostSpace)return false;
    selectionPending={true,uuid,display->hostSpace,target,windowIndex,purpose,1};
    if(!persist()){selectionPending={};return false;}
    if(currentSpaceForDisplay(managed(),uuid)!=selectionPending.fromSpace
        || !switchDisplaySpace(uuid,target,cid))return false;
    selectionPending.stage=2;
    if(!persist())return false;
    uint64_t oldHost=display->hostSpace;SelectionPending completed=selectionPending;
    display->hostSpace=target;selectionPending={};
    if(persist())return true;
    display->hostSpace=oldHost;selectionPending=std::move(completed);return false;
}
bool beginReentryAction(size_t index) {
    if(index>=saved.size() || selectionPending.active)return false;
    SavedWindow &w=saved[index];DisplaySelection *display=selectionForDisplay(w.sourceUUID);
    if(!display || !w.fullScreen || w.fullScreenPhase<2 || w.fullScreenPhase>3
        || display->hostSpace!=w.space || currentSpaceForDisplay(managed(),w.sourceUUID)!=w.space)return false;
    selectionPending={true,w.sourceUUID,w.space,0,(int)index,SelectionPurpose::Reenter,1};
    if(persist())return true;
    selectionPending={};return false;
}
bool reconcileVanishedInitialFullScreenSelection(size_t index,int cid) {
    if(index>=saved.size() || (int)index!=initialFullScreenIndex || selectionPending.active
        || !createdSpaces.empty() || !ownedSpaces.empty() || pendingCreate || active)return false;
    SavedWindow &w=saved[index];
    DisplaySelection *display=selectionForDisplay(w.sourceUUID);
    if(!display || w.sourceUUID!=builtinUUID || w.slot!=0 || !w.fullScreen
        || w.fullScreenPhase!=3 || !initialSpace || w.space!=initialSpace
        || display->type!=4 || display->fullScreenWindow!=(int)index
        || display->space!=initialFullScreenSpace || !display->hostSpace
        || display->hostSpace==w.space || display->hostSpace==display->space)return false;
    NSArray *inventory=managed();
    if(spaceOnDisplay(inventory,display->hostSpace,"")
        || spaceOnDisplay(inventory,display->space,"")
        || !spaceOnDisplay(inventory,w.space,builtinUUID)
        || api().spaceType(cid,w.space)!=0
        || currentSpaceForDisplay(inventory,builtinUUID)!=w.space
        || resolvedWindowID(w)!=w.id || fullScreenState(w)!=0
        || ordinaryAfterExit(w,cid)!=w.space
        || !windowOnDisplay(w.id,cid,builtinUUID))return false;
    // Both selected full-screen Spaces vanished after the exact original
    // window exited. Its unchanged ordinary identity and membership establish
    // the Host-owned selection endpoint before journaling another reentry.
    uint64_t stale=display->hostSpace;
    display->hostSpace=w.space;
    if(persist())return true;
    display->hostSpace=stale;
    return false;
}
bool finishReentryAction(size_t index,uint64_t sid) {
    if(!selectionPending.active || selectionPending.purpose!=SelectionPurpose::Reenter
        || selectionPending.windowIndex!=(int)index || !sid)return false;
    DisplaySelection *display=selectionForDisplay(selectionPending.displayUUID);if(!display)return false;
    uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
    display->hostSpace=sid;selectionPending={};
    if(persist())return true;
    display->hostSpace=oldHost;selectionPending=std::move(old);return false;
}
bool reconcileSelectionPending(int cid) {
    if(!selectionPending.active)return true;
    DisplaySelection *display=selectionForDisplay(selectionPending.displayUUID);if(!display)return false;
    uint64_t current=currentSpaceForDisplay(managed(),selectionPending.displayUUID);
    if(current==selectionPending.fromSpace) {
        SelectionPending old=selectionPending;selectionPending={};
        if(persist())return true;selectionPending=std::move(old);return false;
    }
    auto targetValid=[&]() {
        if(!selectionPending.targetSpace || !spaceOnDisplay(managed(),selectionPending.targetSpace,selectionPending.displayUUID))return false;
        int type=api().spaceType(cid,selectionPending.targetSpace);
        if(selectionPending.purpose==SelectionPurpose::RestoreAnchor)return type==0;
        if(selectionPending.purpose==SelectionPurpose::Prepare) {
            if(selectionPending.windowIndex<0 || (size_t)selectionPending.windowIndex>=saved.size() || type!=4)return false;
            SavedWindow &candidate=saved[selectionPending.windowIndex];
            return sameProcess(candidate) && fullScreenSpaceID(candidate,cid)==selectionPending.targetSpace;
        }
        if(selectionPending.purpose==SelectionPurpose::Final) {
            DisplaySelection *original=selectionForDisplay(selectionPending.displayUUID);
            if(!original)return false;
            if(type==0)return original->type==0 && original->space==selectionPending.targetSpace;
            if(type!=4 || original->fullScreenWindow<0 || (size_t)original->fullScreenWindow>=saved.size())return false;
            SavedWindow &candidate=saved[original->fullScreenWindow];
            return sameProcess(candidate) && fullScreenSpaceID(candidate,cid)==selectionPending.targetSpace;
        }
        return false;
    };
    if(selectionPending.targetSpace && current==selectionPending.targetSpace && targetValid()) {
        uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
        display->hostSpace=current;selectionPending={};
        if(persist())return true;display->hostSpace=oldHost;selectionPending=std::move(old);return false;
    }
    if(selectionPending.windowIndex<0 || (size_t)selectionPending.windowIndex>=saved.size())return false;
    SavedWindow &w=saved[selectionPending.windowIndex];
    uint32_t actual=resolvedWindowID(w);
    if(!actual || !windowOnDisplay(actual,cid,w.sourceUUID))return false;
    if(selectionPending.purpose==SelectionPurpose::Prepare && w.fullScreenPhase==4
        && api().spaceType(cid,current)==0 && fullScreenState(w)==0
        && ordinaryAfterExit(w,cid)==current) {
        CGRect first={},second={};
        if(!afterExitFrame(w,&first))return false;
        usleep(50000);
        if(!afterExitFrame(w,&second) || !nearFrame(first,second))return false;
        SavedWindow oldWindow=w;uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
        w.id=actual;w.space=current;w.frame=second;w.fullScreenPhase=2;
        display->hostSpace=current;selectionPending={};
        if(persist())return true;w=oldWindow;display->hostSpace=oldHost;selectionPending=std::move(old);return false;
    }
    if(selectionPending.purpose==SelectionPurpose::Prepare && w.fullScreenPhase==4
        && api().spaceType(cid,current)==4 && fullScreenState(w)==1
        && fullScreenSpaceID(w,cid)==current) {
        uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
        display->hostSpace=current;selectionPending={};
        if(persist())return true;display->hostSpace=oldHost;selectionPending=std::move(old);return false;
    }
    if(selectionPending.purpose==SelectionPurpose::Reenter && (w.fullScreenPhase==2 || w.fullScreenPhase==3)
        && api().spaceType(cid,current)==4 && fullScreenState(w)==1
        && fullScreenSpaceID(w,cid)==current) {
        SavedWindow oldWindow=w;uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
        w.fullScreenPhase=3;display->hostSpace=current;selectionPending={};
        if(persist())return true;w=oldWindow;display->hostSpace=oldHost;selectionPending=std::move(old);return false;
    }
    return false;
}
bool sourceCurrentIs(const SavedWindow &w,uint64_t sid) {
    return sid && currentSpaceForDisplay(managed(),w.sourceUUID)==sid;
}
bool awaitSourceCurrent(const SavedWindow &w,uint64_t sid) {
    if(!sid)return false;
    for(int retry=0;retry<80;retry++) {
        if(sourceCurrentIs(w,sid))return true;
        usleep(100000);
    }
    return false;
}
bool wholeMoveAvailable() {
    Class move=NSClassFromString(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation");
    return move && [move instancesRespondToSelector:@selector(initWithSpaceID:displayIdentifier:index:)]
        && [move instancesRespondToSelector:@selector(performWithWMBridgeDelegate)];
}
bool wholeFullScreenAnchorTopology(const air::whole_space::Topology &original,int cid,
                                   air::whole_space::Topology &projected) {
    projected=original;
    for(auto &display:projected.displays) {
        int selectedType=api().spaceType(cid,display.current);
        if(selectedType==0)continue;
        if(selectedType!=4)return false;
        uint64_t anchor=0;
        for(uint64_t sid:display.order)if(api().spaceType(cid,sid)==0) {
            anchor=sid;break;
        }
        if(!anchor)return false;
        display.current=anchor;
    }
    return true;
}
const char *wholeModeBlocker(air::whole_space::Topology *topology=nullptr) {
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<27)
        return "whole-Space migration requires macOS 27 or newer";
    Api &a=api();
    if(!AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || !a.conn || !a.managed
        || !a.spaceType || !a.spaceWindows || !a.windowSpaces || !a.windowDisplay
        || !a.axWindow || !a.dock)
        return "Accessibility, Screen Recording, or required Spaces APIs are unavailable";
    if(!wholeMoveAvailable())return "the managed-Space display-index move operation is unavailable";
    if(!bridgedSwitchAvailable())return "the managed-Space selection operation is unavailable";
    if(missionState()!=MissionState::Absent)
        return "Mission Control is visible or its Dock Accessibility state cannot be verified";
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess || count!=3)
        return "exactly three online displays are required";
    CGDirectDisplayID builtin=0;unsigned builtinCount=0;
    std::vector<std::string> external;
    for(uint32_t index=0;index<count;index++) {
        if(CGDisplayIsInMirrorSet(ids[index]))return "mirrored displays cannot use whole-Space migration";
        NSString *uuid=displayUUID(ids[index]);
        if(!uuid)return "an online display identity is unavailable";
        if(CGDisplayIsBuiltin(ids[index])){builtin=ids[index];builtinCount++;}
        else external.push_back(uuid.UTF8String);
    }
    if(builtinCount!=1 || external.size()!=2)return "one built-in and exactly two external displays are required";
    NSString *builtUUID=displayUUID(builtin);
    if(!builtUUID)return "the built-in display identity is unavailable";
    std::vector<std::string> order={builtUUID.UTF8String,external[0],external[1]};
    air::whole_space::Topology snapshot;
    if(!wholeTopology(managed(),order,snapshot))
        return "displays do not expose three separate complete managed-Space inventories";
    std::string reason;
    int cid=a.conn();
    air::whole_space::Topology projected;
    if(!wholeFullScreenAnchorTopology(snapshot,cid,projected)
        || !air::whole_space::eligible(projected,order[0],
            [&](uint64_t sid){return a.spaceType(cid,sid);},&reason))
        return "each display needs an ordinary anchor and only supported fullscreen Spaces";
    if(topology)*topology=std::move(snapshot);
    return nullptr;
}
const char *migrationBlocker() {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->migrationBlocker)return recoveryHooks->migrationBlocker();
#endif
    if(!air_spaces_enabled())return "Accessibility, Screen Recording, or required SkyLight APIs are unavailable";
    if(!api().windowDisplay || !api().spaceWindows)
        return "window display or complete Space membership APIs are unavailable";
    Class moveClass=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    if(!moveClass || ![moveClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)]
        || ![moveClass instancesRespondToSelector:@selector(performWithWMBridgeDelegate)])
        return "the cross-application managed-Space move operation is unavailable";
    if(!bridgedSwitchAvailable())
        return "the managed-Space selection operation is unavailable";
    if(missionState()!=MissionState::Absent)
        return "Mission Control is visible or its Dock Accessibility state cannot be verified";
    CGDirectDisplayID ids[32],builtin=0;uint32_t count=0,external=0,builtinCount=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return "the display layout cannot be read";
    for(uint32_t i=0;i<count;i++) {
        if(CGDisplayIsBuiltin(ids[i])){builtin=ids[i];builtinCount++;}
        else external++;
    }
    if(builtinCount!=1 || external!=2 || CGDisplayIsInMirrorSet(builtin))
        return "one unmirrored built-in display and exactly two external displays are required";
    NSString *uuid=displayUUID(builtin);
    NSDictionary *display=builtInManaged(managed());
    if(!uuid || ![managedDisplayUUID(display) isEqualToString:uuid])
        return "the built-in managed display identity is unavailable";
    uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    if(!current || (api().spaceType(api().conn(),current)!=0
        && api().spaceType(api().conn(),current)!=4))
        return "the current built-in Space is neither an ordinary desktop nor a supported single-window full-screen Space";
    NSArray *spaces=array(display[@"Spaces"]);
    if(!spaces || !spaces.count)return "the built-in Space inventory is unavailable";
    if(userSpaces(display,api().conn()).size()>4)
        return "more than four built-in desktops are present; close extras before Remote Spaces";
    return nullptr;
}
bool ensureSlots(int cid) {
    if(missionState()!=MissionState::Absent || pendingCreate || !createdSpaces.empty()
        || !ownedSpaces.empty() || !reusedSlots.empty()
        || slots[0] || slots[1] || slots[2])return false;
    bool openedMission=false;
    auto fail=[&] { if(openedMission)closeMission();return false; };
    CGDirectDisplayID builtin=0, ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return fail();
    for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(ids[i])){builtin=ids[i];break;}
    if(!builtin)return fail();
    NSDictionary *starting=builtInManaged(managed());
    auto originalOrdinary=userSpaces(starting,cid);
    std::vector<uint64_t> initialPlan;int missing=0;
    if(![managedDisplayUUID(starting) isEqualToString:
            [NSString stringWithUTF8String:builtinUUID.c_str()]]
        || !planReusedSlots(originalOrdinary,initialSpace,initialPlan,missing))
        return fail();
    for(int attempt=0;attempt<missing;attempt++) {
        NSDictionary *d=builtInManaged(managed());if(!d)return fail();
        std::vector<uint64_t> before;
        auto ordinary=userSpaces(d,cid);
        if(!fullSpaceOrder(d,before)
            || ![managedDisplayUUID(d) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]]
            || std::find(ordinary.begin(),ordinary.end(),initialSpace)==ordinary.end())return fail();
        if(before.size()>125 || ordinary.size()>=4)return fail();
        uint64_t current=[number(dictionary(d[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(current!=initialSpace
            && std::find(createdSpaces.begin(),createdSpaces.end(),current)==createdSpaces.end())return fail();
        openedMission=true;
        AXUIElementRef add=missionList(@"mc.spaces.add",builtin,true);
        if(!add)return fail();
        CFArrayRef actions=nullptr;
        AXError names=AXUIElementCopyActionNames(add,&actions);
        bool canPress=false;
        if(names==kAXErrorSuccess)for(NSString *action in (__bridge NSArray *)actions)
            if([action isEqualToString:(__bridge NSString *)kAXPressAction])canPress=true;
        if(actions)CFRelease(actions);
        if(!canPress){CFRelease(add);return fail();}
        pendingCreateBefore=before;
        pendingCreate=true;
        if(!persist()){CFRelease(add);return fail();}
        AXError status=AXUIElementPerformAction(add,kAXPressAction);CFRelease(add);
        if(status!=kAXErrorSuccess)return fail();
        uint64_t addedID=0;NSString *newUUID=nil;NSDictionary *afterDisplay=nil;
        std::vector<uint64_t> after;
        for(int retry=0;retry<40;retry++) {
            usleep(50000);
            afterDisplay=builtInManaged(managed());
            if(!fullSpaceOrder(afterDisplay,after))continue;
            std::vector<uint64_t> added;
            for(uint64_t sid:after)if(std::find(before.begin(),before.end(),sid)==before.end())added.push_back(sid);
            if(added.size()>1)return fail();
            if(added.size()!=1)continue;
            if(after.size()!=before.size()+1)return fail();
            for(uint64_t sid:before)if(std::find(after.begin(),after.end(),sid)==after.end())return fail();
            addedID=added[0];
            newUUID=managedSpaceUUID(managedSpace(afterDisplay,addedID));
            if(newUUID)break;
        }
        if(!addedID || !newUUID
            || ![managedDisplayUUID(afterDisplay) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])
            return fail();
        createdSpaces.push_back(addedID);
        ownedSpaces.push_back({addedID,newUUID.UTF8String,builtinUUID});
        pendingCreate=false;pendingCreateBefore.clear();
        if(!persist())return fail();
        if(!additionPreservesOrder(before,after,addedID) || api().spaceType(cid,addedID)!=0)return fail();
        uint64_t selected=[number(dictionary(afterDisplay[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(selected!=initialSpace && std::find(createdSpaces.begin(),createdSpaces.end(),selected)==createdSpaces.end())return fail();
        if(selected!=initialSpace && selected!=lastSelectedSpace) {
            lastSelectedSpace=selected;
            if(!persist())return fail();
        }
    }
    if(openedMission && !closeMission())return false;
    NSDictionary *finalDisplay=builtInManaged(managed());
    auto ordinary=userSpaces(finalDisplay,cid);
    std::vector<uint64_t> selected;int remaining=0;
    if(![managedDisplayUUID(finalDisplay) isEqualToString:
            [NSString stringWithUTF8String:builtinUUID.c_str()]]
        || !planReusedSlots(ordinary,initialSpace,selected,remaining) || remaining)return false;
    std::vector<OwnedSpace> adopted;
    for(uint64_t sid:selected) {
        NSString *uuid=managedSpaceUUID(managedSpace(finalDisplay,sid));
        if(!uuid || api().spaceType(cid,sid)!=0)return false;
        adopted.push_back({sid,uuid.UTF8String,builtinUUID});
    }
    // The prior journal still owns any newly created desktops until this
    // adoption record is durably written. Afterward they are user desktops.
    auto previousCreated=createdSpaces;
    auto previousOwned=ownedSpaces;
    auto previousIdentities=ordinarySpaceIdentities;
    for(const auto &space:adopted) {
        NSDictionary *managedEntry=managedSpace(finalDisplay,space.id);
        NSString *uuid=managedEntry[@"uuid"];
        if(![uuid isKindOfClass:NSString.class] || !uuid.length)continue;
        auto found=std::find_if(ordinarySpaceIdentities.begin(),ordinarySpaceIdentities.end(),
            [&](const OrdinarySpaceIdentity &entry){return entry.id==space.id;});
        if(found==ordinarySpaceIdentities.end())
            ordinarySpaceIdentities.push_back({space.id,builtinUUID,uuid.UTF8String});
    }
    reusedSlots=std::move(adopted);createdSpaces.clear();ownedSpaces.clear();
    if(!persist()) {
        reusedSlots.clear();createdSpaces=std::move(previousCreated);
        ownedSpaces=std::move(previousOwned);
        ordinarySpaceIdentities=std::move(previousIdentities);return false;
    }
    for(int i=0;i<3;i++)slots[i]=reusedSlots[i].id;
    return ownedSlotsStillOrdered(finalDisplay,cid);
}
bool reconcileWholePendingParking(int cid) {
    if(pendingCreate) {
        if(missionState()==MissionState::Visible && !closeMission())return false;
        if(missionState()!=MissionState::Absent)return false;
        NSDictionary *display=builtInManaged(managed());std::vector<uint64_t> current;
        if(!display || !fullSpaceOrder(display,current))return false;
        std::vector<uint64_t> added;
        for(uint64_t sid:current)
            if(std::find(pendingCreateBefore.begin(),pendingCreateBefore.end(),sid)==pendingCreateBefore.end())added.push_back(sid);
        bool same=current==pendingCreateBefore;
        if(!same && (added.size()!=1 || !additionPreservesOrder(pendingCreateBefore,current,added[0])))return false;
        if(same) {
            pendingCreate=false;pendingCreateBefore.clear();
            if(!persist())return false;
        } else {
            uint64_t sid=added[0];NSString *uuid=managedSpaceUUID(managedSpace(display,sid));
            // Pressing Mission Control's add button can select the new Space.
            // Preparation and recovery keep the original built-in selection so
            // the durable topology remains deterministic before any move.
            uint64_t target=wholeJournal.selected[0];
            uint64_t current=currentSpaceForDisplay(managed(),builtinUUID);
            if(!target || !current || (current!=target && !switchDisplaySpace(builtinUUID,target,cid)))return false;
            air::whole_space::Topology topology;std::string reason;
            if(!uuid || api().spaceType(cid,sid)!=0 || !wholeTopology(managed(),wholeDisplayOrder(),topology)
                || !air::whole_space::addParking(wholeJournal,topology,sid,uuid.UTF8String,
                    [&](uint64_t value){return api().spaceType(cid,value);},&reason))return false;
            createdSpaces.push_back(sid);ownedSpaces.push_back({sid,uuid.UTF8String,builtinUUID});
            pendingCreate=false;pendingCreateBefore.clear();
            if(!persist())return false;
        }
    }
    return true;
}
bool ensureWholeParking(int cid,std::string *failure) {
    if(failure)failure->clear();
    auto explain=[&](const std::string &stage) {
        if(failure)*failure=stage;
        return false;
    };
    if(wholeJournal.original.displays.size()!=3 || wholeJournal.parkingCount>2
        || createdSpaces.size()!=ownedSpaces.size()
        || createdSpaces.size()!=wholeJournal.parkingCount)
        return explain("parking journal and owned Space counts disagree");
    if(!reconcileWholePendingParking(cid))return explain("pending parking creation could not be reconciled");
    if(missionState()!=MissionState::Absent)return explain("Mission Control is already visible or its state is unreadable");
    CGDirectDisplayID builtin=0,ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)
        return explain("online display inventory is unavailable");
    for(uint32_t index=0;index<count;index++)if(CGDisplayIsBuiltin(ids[index])){builtin=ids[index];break;}
    if(!builtin)return explain("built-in display is absent from the online inventory");
    bool opened=false;
    auto fail=[&](const std::string &stage) {
        bool closed=!opened || closeMission();
        return explain(stage+(closed ? "" : "; Mission Control could not be closed"));
    };
    for(int attempt=wholeJournal.parkingCount;attempt<2;attempt++) {
        const std::string step="parking Space "+std::to_string(attempt+1)+": ";
        air::whole_space::Topology beforeTopology;
        if(!wholeTopology(managed(),wholeDisplayOrder(),beforeTopology))return fail(step+"initial topology is unreadable");
        NSDictionary *display=builtInManaged(managed());
        std::vector<uint64_t> before;
        if(!display || !fullSpaceOrder(display,before) || before.size()>126)
            return fail(step+"built-in Space order is unreadable or full");
        opened=true;
        AXUIElementRef add=missionList(@"mc.spaces.add",builtin,true);
        if(!add)return fail(step+"Mission Control add button is unavailable");
        CFArrayRef actions=nullptr;
        AXError names=AXUIElementCopyActionNames(add,&actions);
        bool canPress=false;
        if(names==kAXErrorSuccess)for(NSString *action in (__bridge NSArray *)actions)
            if([action isEqualToString:(__bridge NSString *)kAXPressAction])canPress=true;
        if(actions)CFRelease(actions);
        if(!canPress){CFRelease(add);return fail(step+"Mission Control add button has no press action");}
        pendingCreateBefore=before;pendingCreate=true;
        if(!persist()){CFRelease(add);return fail(step+"creation intent could not be journaled");}
        AXError status=AXUIElementPerformAction(add,kAXPressAction);CFRelease(add);
        if(status!=kAXErrorSuccess)
            return fail(step+"Mission Control add action failed (AX "+std::to_string(status)+")");
        uint64_t added=0;NSString *spaceUUID=nil;
        air::whole_space::Topology afterTopology;
        for(int retry=0;retry<40;retry++) {
            usleep(50000);
            NSDictionary *afterDisplay=builtInManaged(managed());
            std::vector<uint64_t> after;
            if(!fullSpaceOrder(afterDisplay,after) || !additionPreservesOrder(before,after,0)) {
                std::vector<uint64_t> candidates;
                if(fullSpaceOrder(afterDisplay,after))
                    for(uint64_t sid:after)if(std::find(before.begin(),before.end(),sid)==before.end())candidates.push_back(sid);
                if(candidates.size()!=1 || !additionPreservesOrder(before,after,candidates[0]))continue;
                added=candidates[0];
            } else continue;
            spaceUUID=managedSpaceUUID(managedSpace(afterDisplay,added));
            if(spaceUUID && wholeTopology(managed(),wholeDisplayOrder(),afterTopology))break;
        }
        std::string reason;
        if(!added || !spaceUUID || api().spaceType(cid,added)!=0)
            return fail(step+"added Space identity, UUID, or ordinary type could not be verified");
        if(missionState()==MissionState::Visible && !closeMission())
            return explain(step+"Mission Control could not be closed after creation");
        if(missionState()!=MissionState::Absent)
            return explain(step+"Mission Control remains visible or unreadable after creation");
        uint64_t target=wholeJournal.selected[0];
        uint64_t current=currentSpaceForDisplay(managed(),builtinUUID);
        if(!target || !current || (current!=target && !switchDisplaySpace(builtinUUID,target,cid))
            || !wholeTopology(managed(),wholeDisplayOrder(),afterTopology)
            || !air::whole_space::addParking(wholeJournal,afterTopology,added,spaceUUID.UTF8String,
                [&](uint64_t sid){return api().spaceType(cid,sid);},&reason))
            return fail(step+"original selection or parking topology could not be verified"+
                (reason.empty() ? "" : ": "+reason));
        createdSpaces.push_back(added);
        ownedSpaces.push_back({added,spaceUUID.UTF8String,builtinUUID});
        pendingCreate=false;pendingCreateBefore.clear();
        if(!persist())return fail(step+"verified parking identity could not be journaled");
    }
    if(!closeMission())return explain("Mission Control could not be closed after both parking Spaces");
    return true;
}
NSDictionary *exactWindowLayerDescription(NSArray *rows,uint32_t wid) {
    for(id raw in rows) {NSDictionary *item=dictionary(raw);NSNumber *numberID=number(item[(id)kCGWindowNumber]);NSNumber *layer=number(item[(id)kCGWindowLayer]);if(numberID.unsignedIntValue==wid && layer)return item;}
    return nil;
}
NSDictionary *windowLayerDescription(uint32_t wid) {
    NSArray *including=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid));
    NSDictionary *found=exactWindowLayerDescription(including,wid);if(found)return found;
    const void *encoded=(const void *)(uintptr_t)wid;CFArrayRef request=CFArrayCreate(kCFAllocatorDefault,&encoded,1,nullptr);
    NSArray *described=CFBridgingRelease(CGWindowListCreateDescriptionFromArray(request));CFRelease(request);
    return exactWindowLayerDescription(described,wid);
}
enum class SpaceCandidateDescription { Present, Departed, Unresolved };
SpaceCandidateDescription resolveSpaceCandidateDescription(int cid,uint32_t wid,NSDictionary **description) {
    if(description)*description=nil;
    if(!api().windowSpaces || !wid)return SpaceCandidateDescription::Unresolved;
    for(int retry=0;retry<20;retry++) {
        NSDictionary *found=windowLayerDescription(wid);
        if(found) {
            if(description)*description=found;
            return SpaceCandidateDescription::Present;
        }
        NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        if(!membership)return SpaceCandidateDescription::Unresolved;
        if(membership.count==0)return SpaceCandidateDescription::Departed;
        usleep(50000);
    }
    return SpaceCandidateDescription::Unresolved;
}
bool noNormalWindowsInSpace(int cid,uint64_t sid) {
    if(!api().spaceWindows || !api().windowSpaces)return false;
    DormantAXCache cursorAX;DetachedMenuStripScan menuStrips;
    NSArray *spaceIDs=@[@(sid)];
    uint64_t setTags=0,clearTags=0;
    NSArray *candidates=CFBridgingRelease(api().spaceWindows(cid,0,(__bridge CFArrayRef)spaceIDs,0x7,&setTags,&clearTags));
    if(!candidates)return false;
    for(id value in candidates) {
        NSNumber *numberID=number(value);
        if(!numberID || !numberID.unsignedIntValue)return false;
        uint32_t wid=numberID.unsignedIntValue;
        NSDictionary *found=nil;
        SpaceCandidateDescription state=resolveSpaceCandidateDescription(cid,wid,&found);
        if(state==SpaceCandidateDescription::Departed)continue;
        if(state!=SpaceCandidateDescription::Present)return false;
        if([number(found[(id)kCGWindowLayer]) intValue]==0
            && !verifiedCursorUIOverlay(found,wid,
                [number(found[(id)kCGWindowOwnerPID]) intValue],cursorAX)
            && !verifiedCUAOverlay(found,wid,
                [number(found[(id)kCGWindowOwnerPID]) intValue],cid)
            && !verifiedDetachedMenuStripSurface(found,wid,
                [number(found[(id)kCGWindowOwnerPID]) intValue],cid,&menuStrips))return false;
    }
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!all)return false;
    for(NSDictionary *item in all) {
        if([number(item[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(item[(id)kCGWindowNumber]) unsignedIntValue];
        if(!wid)return false;
        NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!membership)return false;
        if(verifiedCursorUIOverlay(item,wid,
            [number(item[(id)kCGWindowOwnerPID]) intValue],cursorAX)
            || verifiedCUAOverlay(item,wid,
                [number(item[(id)kCGWindowOwnerPID]) intValue],cid)
            || verifiedDetachedMenuStripSurface(item,wid,
                [number(item[(id)kCGWindowOwnerPID]) intValue],cid,&menuStrips))continue;
        for(id value in membership) {
            NSNumber *member=number(value);
            if(!member)return false;
            if(member.unsignedLongLongValue==sid)return false;
        }
    }
    return true;
}
struct RemovalMCWindows { std::set<uint32_t> before;pid_t windowManagerPID=0;bool active=false; };
bool exactSingletonMembership(int cid,uint32_t wid,uint64_t sid) {
    NSArray *membership=api().windowSpaces ? CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)])) : nil;
    return membership.count==1 && [number(membership[0]) unsignedLongLongValue]==sid;
}
bool verifiedRemovalMCWindow(const RemovalMCWindows *context,int cid,uint64_t sid,uint32_t wid,NSDictionary *cg) {
    AXUIElementRef currentWM=windowManagerApplication();pid_t currentPID=0;
    bool sameWM=currentWM && AXUIElementGetPid(currentWM,&currentPID)==kAXErrorSuccess
        && context && currentPID==context->windowManagerPID;if(currentWM)CFRelease(currentWM);
    return context && context->active && context->windowManagerPID>0 && sameWM
        && context->before.find(wid)==context->before.end() && missionState()==MissionState::Visible
        && cg && [number(cg[(id)kCGWindowNumber]) unsignedIntValue]==wid
        && [number(cg[(id)kCGWindowLayer]) intValue]==0
        && [number(cg[(id)kCGWindowOwnerPID]) intValue]==context->windowManagerPID
        && exactSingletonMembership(cid,wid,sid);
}
bool noNormalWindowsInSpaceForRemoval(int cid,uint64_t sid,const RemovalMCWindows *context) {
    if(!context || !context->active)return noNormalWindowsInSpace(cid,sid);
    DormantAXCache cursorAX;DetachedMenuStripScan menuStrips;
    if(!api().spaceWindows || !api().windowSpaces)return false;uint64_t setTags=0,clearTags=0;
    NSArray *candidates=CFBridgingRelease(api().spaceWindows(cid,0,(__bridge CFArrayRef)@[@(sid)],0x7,&setTags,&clearTags));if(!candidates)return false;
    for(id value in candidates){NSNumber *n=number(value);if(!n||!n.unsignedIntValue)return false;uint32_t wid=n.unsignedIntValue;NSDictionary *found=nil;SpaceCandidateDescription state=resolveSpaceCandidateDescription(cid,wid,&found);if(state==SpaceCandidateDescription::Departed)continue;if(state!=SpaceCandidateDescription::Present)return false;if([number(found[(id)kCGWindowLayer]) intValue]==0&&!verifiedRemovalMCWindow(context,cid,sid,wid,found)&&!verifiedCursorUIOverlay(found,wid,[number(found[(id)kCGWindowOwnerPID]) intValue],cursorAX)&&!verifiedCUAOverlay(found,wid,[number(found[(id)kCGWindowOwnerPID]) intValue],cid)&&!verifiedDetachedMenuStripSurface(found,wid,[number(found[(id)kCGWindowOwnerPID]) intValue],cid,&menuStrips))return false;}
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));if(!all)return false;
    for(NSDictionary *item in all){if([number(item[(id)kCGWindowLayer]) intValue]!=0)continue;uint32_t wid=[number(item[(id)kCGWindowNumber]) unsignedIntValue];if(!wid)return false;NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));if(!membership)return false;if(verifiedCursorUIOverlay(item,wid,[number(item[(id)kCGWindowOwnerPID]) intValue],cursorAX)||verifiedCUAOverlay(item,wid,[number(item[(id)kCGWindowOwnerPID]) intValue],cid)||verifiedDetachedMenuStripSurface(item,wid,[number(item[(id)kCGWindowOwnerPID]) intValue],cid,&menuStrips))continue;for(id value in membership){NSNumber *member=number(value);if(!member)return false;if(member.unsignedLongLongValue==sid&&!verifiedRemovalMCWindow(context,cid,sid,wid,item))return false;}}
    return true;
}
enum class ParkingWindowState { Conflict=-1,Gone=0,Source=1,Destination=2 };
CGRect boundsForDisplayUUID(const std::string &uuid,bool *found) {
    if(found)*found=false;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->displayBounds) {
        CGRect bounds={};bool okay=recoveryHooks->displayBounds(uuid,&bounds);
        if(found)*found=okay;
        return bounds;
    }
#endif
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return {};
    for(uint32_t index=0;index<count;index++) {
        NSString *candidate=displayUUID(displays[index]);
        if(candidate && uuid==candidate.UTF8String) {
            if(found)*found=true;
            return CGDisplayBounds(displays[index]);
        }
    }
    return {};
}
ParkingWindowState parkingWindowState(const ParkingWindowIdentity &window,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->parkingWindowState)
        return (ParkingWindowState)recoveryHooks->parkingWindowState(window);
#endif
    if(!window.id || window.pid<=0 || window.bundle.empty() || !window.launchTime
        || !window.birthSeconds || window.birthMicroseconds>=1000000
        || !window.sourceSpace || !window.destinationSpace
        || api().spaceType(cid,window.sourceSpace)!=0
        || api().spaceType(cid,window.destinationSpace)!=0)return ParkingWindowState::Conflict;
    NSDictionary *cg=windowLayerDescription(window.id);
    NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,
        (__bridge CFArrayRef)@[@(window.id)]));
    if(!cg) return membership && membership.count==0
        ? ParkingWindowState::Gone : ParkingWindowState::Conflict;
    if(membership.count!=1 || [number(cg[(id)kCGWindowNumber]) unsignedIntValue]!=window.id
        || [number(cg[(id)kCGWindowOwnerPID]) intValue]!=window.pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0)return ParkingWindowState::Conflict;
    uint64_t sid=[number(membership[0]) unsignedLongLongValue];
    ParkingWindowState state=sid==window.sourceSpace ? ParkingWindowState::Source
        : sid==window.destinationSpace ? ParkingWindowState::Destination : ParkingWindowState::Conflict;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:window.pid];
    ProcessBirth birth=processBirth(window.pid);CGRect cgFrame={},axFrame={};
    AXUIElementRef ax=findAXWindow(window.pid,window.id);
    id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
    id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
    bool chromeExternal=window.bundle=="com.google.Chrome"
        && ((window.sourceSpace==wholeJournal.parking[0]
                && window.destinationSpace==wholeJournal.selected[1])
            || (window.sourceSpace==wholeJournal.parking[1]
                && window.destinationSpace==wholeJournal.selected[2]));
    bool commonIdentity=app && !app.terminated && [app.bundleIdentifier isEqualToString:
        [NSString stringWithUTF8String:window.bundle.c_str()]]
        && birth.seconds==window.birthSeconds && birth.microseconds==window.birthMicroseconds
        && fabs(stableLaunchTime(app,window.pid)-window.launchTime)<=1
        && CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&cgFrame)
        && (chromeExternal || windowOnDisplay(window.id,cid,builtinUUID));
    bool exactCGFrame=window.cgFrame.size.width<=0
        || CGRectEqualToRect(cgFrame,window.cgFrame);
    bool inspection=window.requiresAX
        ? ax && [role isEqual:(__bridge NSString *)kAXWindowRole]
            && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
            && readAXFrame(ax,&axFrame)
        : exactCGFrame;
    if(chromeExternal) {
        std::string destinationDisplay;
        for(const auto &display:wholeJournal.original.displays)
            if(display.current==window.destinationSpace)destinationDisplay=display.uuid;
        bool found=false;CGRect external=boundsForDisplayUUID(destinationDisplay,&found);
        bool parentKnown=false;
        uint32_t parent=exactWindowParent(cid,window.id,&parentKnown);
        bool root=window.requiresAX && inspection && parentKnown && parent==0
            && found && CGRectIntersectsRect(axFrame,external);
        bool helper=false;
        if(!window.requiresAX && !ax && parentKnown && parent==0 && found
            && [number(cg[(id)kCGWindowAlpha]) doubleValue]==1) {
            NSString *title=cg[(id)kCGWindowName];
            DormantAXInventory inventory=readDormantAXInventory(window.pid);
            if((![title isKindOfClass:NSString.class] || !title.length)
                && inventory.readable && inventory.complete && inventory.birth==birth
                && !inventory.windows.count(window.id)) {
                NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
                    kCGWindowListOptionAll,kCGNullWindowID));
                for(NSDictionary *peer in all) {
                    uint32_t peerID=[number(peer[(id)kCGWindowNumber]) unsignedIntValue];
                    if(!peerID || peerID==window.id
                        || [number(peer[(id)kCGWindowOwnerPID]) intValue]!=window.pid
                        || !inventory.windows.count(peerID)
                        || !windowOnDisplay(peerID,cid,destinationDisplay)
                        || !exactSingletonMembership(cid,peerID,window.destinationSpace))continue;
                    AXUIElementRef peerAX=findAXWindow(window.pid,peerID);
                    CGRect peerFrame={};bool peerRoot=peerAX
                        && [axAttribute(peerAX,kAXRoleAttribute)
                            isEqual:(__bridge NSString *)kAXWindowRole]
                        && [axAttribute(peerAX,kAXSubroleAttribute)
                            isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                        && readAXFrame(peerAX,&peerFrame)
                        && CGRectIntersectsRect(peerFrame,external);
                    if(peerAX)CFRelease(peerAX);
                    if(peerRoot) {helper=true;break;}
                }
            }
        }
        inspection=root || helper;
    }
    if(ax)CFRelease(ax);
    if(!commonIdentity || !inspection
        || (!chromeExternal && !stableCGSurface(cg,window.id,window.pid,cgFrame))
        || !exactSingletonMembership(cid,window.id,sid))return ParkingWindowState::Conflict;
    return state;
}
bool parkingWindowCandidates(uint64_t sid,int cid,std::vector<ParkingWindowIdentity> &windows,
                             std::string *reason) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->parkingWindows)
        return recoveryHooks->parkingWindows(sid,windows,reason);
#endif
    windows.clear();
    if(missionState()!=MissionState::Absent) {
        if(reason)*reason="Mission Control is visible while parking windows are inspected";
        return false;
    }
    uint64_t setTags=0,clearTags=0;
    NSArray *raw=CFBridgingRelease(api().spaceWindows(cid,0,(__bridge CFArrayRef)@[@(sid)],
        0x7,&setTags,&clearTags));
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!raw || !all || raw.count>10000) {
        if(reason)*reason="the parking Space window inventory is unavailable";return false;
    }
    std::set<uint32_t> ids;
    DormantAXCache cursorAX;DetachedMenuStripScan menuStrips;
    for(id value in raw) {
        uint32_t wid=[number(value) unsignedIntValue];
        if(!wid || !ids.insert(wid).second) {
            if(reason)*reason="the parking Space window inventory is invalid";return false;
        }
    }
    for(NSDictionary *cg in all)if([number(cg[(id)kCGWindowLayer]) intValue]==0) {
        uint32_t wid=[number(cg[(id)kCGWindowNumber]) unsignedIntValue];
        if(!wid) {if(reason)*reason="a normal window has no identity";return false;}
        NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        if(!membership) {if(reason)*reason="a normal window's Space membership is unavailable";return false;}
        for(id member in membership)if([number(member) unsignedLongLongValue]==sid)ids.insert(wid);
    }
    for(uint32_t wid:ids) {
        NSDictionary *cg=nil;
        SpaceCandidateDescription state=resolveSpaceCandidateDescription(cid,wid,&cg);
        if(state==SpaceCandidateDescription::Departed)continue;
        if(state!=SpaceCandidateDescription::Present) {
            if(reason)*reason="a parking Space window description is unavailable";return false;
        }
        NSNumber *layer=number(cg[(id)kCGWindowLayer]);
        if(!layer) {if(reason)*reason="a parking Space window layer is unavailable";return false;}
        if(layer.intValue!=0)continue;
        pid_t pid=[number(cg[(id)kCGWindowOwnerPID]) intValue];
        if(verifiedCursorUIOverlay(cg,wid,pid,cursorAX)
            || verifiedCUAOverlay(cg,wid,pid,cid)
            || verifiedDetachedMenuStripSurface(cg,wid,pid,cid,&menuStrips))continue;
        NSRunningApplication *app=pid>0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
        NSString *bundle=app.bundleIdentifier;ProcessBirth birth=processBirth(pid);CGRect frame={};
        NSArray *membership=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        bool exactMembership=membership.count==1 && [number(membership[0]) unsignedLongLongValue]==sid;
        bool frameReadable=CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&frame);
        bool stable=frameReadable && stableCGSurface(cg,wid,pid,frame);
        bool onDisplay=windowOnDisplay(wid,cid,builtinUUID);
        int parkingIndex=sid==wholeJournal.parking[0] ? 0
            : sid==wholeJournal.parking[1] ? 1 : -1;
        bool chromeExternal=[bundle isEqualToString:@"com.google.Chrome"] && parkingIndex>=0;
        if(!pid || !app || app.terminated || !bundle.length || !birth.valid() || !exactMembership
            || api().spaceType(cid,sid)!=0 || !frameReadable
            || (!chromeExternal && (!stable || !onDisplay))) {
            if(reason)*reason="a parking Space window failed validation [wid="+std::to_string(wid)
                +" pid="+std::to_string(pid)+" identity="+std::to_string(bool(app && !app.terminated && bundle.length && birth.valid()))
                +" membership="+std::to_string(exactMembership)+" frame="+std::to_string(frameReadable)
                +" stable="+std::to_string(stable)+" display="+std::to_string(onDisplay)+"]";
            return false;
        }
        if(systemChrome(bundle))continue;
        for(const SavedWindow &savedWindow:saved)if(savedWindow.id==wid && savedWindow.pid==pid) {
            if(reason)*reason="a journaled user window unexpectedly occupies a parking Space";
            return false;
        }
        AXUIElementRef ax=findAXWindow(pid,wid);CGRect axFrame={};
        id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
        id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
        bool standard=ax && [role isEqual:(__bridge NSString *)kAXWindowRole]
            && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
            && readAXFrame(ax,&axFrame);
        if(ax)CFRelease(ax);
        double launch=stableLaunchTime(app,pid);
        if(launch<=0) {if(reason)*reason="a parking window process launch identity is unavailable";return false;}
        uint64_t destination=chromeExternal ? wholeJournal.selected[parkingIndex+1]
            : wholeJournal.original.displays.empty() ? initialSpace : wholeJournal.selected[0];
        ParkingWindowIdentity identity={wid,pid,bundle.UTF8String,launch,birth.seconds,birth.microseconds,
            sid,destination,standard,frame};
        if(parkingWindowState(identity,cid)!=ParkingWindowState::Source) {
            if(reason)*reason="a parking window changed while its identity was captured";return false;
        }
        windows.push_back(std::move(identity));
    }
    std::sort(windows.begin(),windows.end(),[](const auto &left,const auto &right){return left.id<right.id;});
    return true;
}
bool clearParkingEvacuation() {
    ParkingEvacuation prior=parkingEvacuation;parkingEvacuation={};
    if(persist())return true;
    parkingEvacuation=std::move(prior);return false;
}
bool reconcileParkingEvacuation(int cid,std::string *reason) {
    if(!parkingEvacuation.active)return true;
    ParkingWindowState state=parkingWindowState(parkingEvacuation.window,cid);
    if(state==ParkingWindowState::Gone || state==ParkingWindowState::Destination) {
        if(clearParkingEvacuation())return true;
        if(reason)*reason="the completed parking window evacuation could not be journaled";
        return false;
    }
    if(state!=ParkingWindowState::Source) {
        if(reason)*reason="the pending parking window identity or membership conflicts with the recovery journal";
        return false;
    }
#ifdef AIR_SPACES_JOURNAL_TEST
    bool moved=recoveryHooks && recoveryHooks->moveParkingWindow
        ? recoveryHooks->moveParkingWindow(parkingEvacuation.window)
        : move(parkingEvacuation.window.id,parkingEvacuation.window.destinationSpace,cid);
#else
    bool moved=move(parkingEvacuation.window.id,parkingEvacuation.window.destinationSpace,cid);
#endif
    if(!moved || parkingWindowState(parkingEvacuation.window,cid)!=ParkingWindowState::Destination) {
        if(reason)*reason="a verified parking window could not be moved to the original built-in Space";
        return false;
    }
    if(clearParkingEvacuation())return true;
    if(reason)*reason="the parking window move completed but its endpoint could not be journaled";
    return false;
}
bool evacuateOwnedParkingSpace(const OwnedSpace &owned,int cid,std::string *reason) {
    if(parkingEvacuation.active && !reconcileParkingEvacuation(cid,reason))return false;
    uint64_t destination=wholeJournal.original.displays.empty()
        ? initialSpace : wholeJournal.selected[0];
    if(!destination || initialSpace!=destination
        || api().spaceType(cid,initialSpace)!=0 || owned.id==initialSpace
        || ownedStatus(managed(),owned,cid)!=OwnedStatus::Match) {
        if(reason)*reason="parking evacuation endpoints are not exact journal-owned ordinary Spaces";
        return false;
    }
    for(unsigned iteration=0;iteration<10000;iteration++) {
        std::vector<ParkingWindowIdentity> windows;
        // WindowManager may finish moving an auxiliary surface while the
        // first recovery inventory is being read. Recheck the complete
        // identity predicates for one bounded interval before retaining the
        // journal; no window is moved from a failed sample.
        bool candidatesReady=false;
        for(int sample=0;sample<20;sample++) {
            if(parkingWindowCandidates(owned.id,cid,windows,reason)) {
                candidatesReady=true;break;
            }
            if(sample+1<20)usleep(50000);
        }
        if(!candidatesReady)return false;
        if(windows.empty())return true;
        ParkingWindowIdentity candidate=windows.front();
        bool chromeExternal=candidate.bundle=="com.google.Chrome"
            && ((candidate.sourceSpace==wholeJournal.parking[0]
                    && candidate.destinationSpace==wholeJournal.selected[1])
                || (candidate.sourceSpace==wholeJournal.parking[1]
                    && candidate.destinationSpace==wholeJournal.selected[2]));
        if(candidate.sourceSpace!=owned.id
            || (candidate.destinationSpace!=destination && !chromeExternal)) {
            if(reason)*reason="a parking window candidate has an invalid recovery endpoint";return false;
        }
        parkingEvacuation={true,candidate};
        if(!persist()) {
            parkingEvacuation={};
            if(reason)*reason="a parking window move could not be journaled before mutation";
            return false;
        }
        if(!reconcileParkingEvacuation(cid,reason))return false;
    }
    if(reason)*reason="the parking Space kept creating windows during bounded evacuation";
    return false;
}
bool awaitStableEmptyOwnedSpace(const OwnedSpace &owned,int cid,const std::vector<uint64_t> &expectedOrder,
                                MissionState expectedMission,const RemovalMCWindows *context=nullptr) {
    auto valid=[&]() {
        NSArray *inventory=managed();NSDictionary *display=builtInManaged(inventory);
        std::vector<uint64_t> order;uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        return [managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
            && fullSpaceOrder(display,order) && order==expectedOrder && current==initialSpace
            && ownedStatus(inventory,owned,cid)==OwnedStatus::Match && missionState()==expectedMission;
    };
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<27)
        return valid() && noNormalWindowsInSpace(cid,owned.id) && valid();
    int consecutive=0;CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+2.0;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        if(!valid())return false;
        if(noNormalWindowsInSpaceForRemoval(cid,owned.id,context)) {
            if(++consecutive>=3)return valid();
        } else consecutive=0;
        usleep(50000);
    }
    return false;
}
bool beginOwnedCleanup() {
    if(createdSpaces.empty() && ownedSpaces.empty())return true;
    uint64_t oldSlots[3]={slots[0],slots[1],slots[2]},oldSelected=lastSelectedSpace;
    bool oldActive=active,oldSwitchVerified=switchVerified;
    slots[0]=slots[1]=slots[2]=0;lastSelectedSpace=0;active=false;switchVerified=false;
    if(persist())return true;
    for(int i=0;i<3;i++)slots[i]=oldSlots[i];lastSelectedSpace=oldSelected;
    active=oldActive;switchVerified=oldSwitchVerified;return false;
}
bool removalPreflight(OwnedStatus status,uint64_t owned,uint64_t original,uint64_t current,
                      size_t ordinaryCount,bool empty) {
    return status==OwnedStatus::Match && owned && owned!=original && ordinaryCount>=2
        && current!=owned && empty;
}
bool removeOwnedSpace(const OwnedSpace &owned,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->remove)return recoveryHooks->remove(owned.id);
#endif
    NSArray *beforeAll=managed();
    OwnedStatus status=ownedStatus(beforeAll,owned,cid);
    NSDictionary *beforeDisplay=builtInManaged(beforeAll);
    if(![managedDisplayUUID(beforeDisplay) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]])
        return false;
    auto ordinary=userSpaces(beforeDisplay,cid);
    std::vector<uint64_t> before;
    if(!fullSpaceOrder(beforeDisplay,before))return false;
    uint64_t current=[number(dictionary(beforeDisplay[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    bool initiallyEmpty=awaitStableEmptyOwnedSpace(owned,cid,before,MissionState::Absent);
    if(current!=initialSpace || std::find(before.begin(),before.end(),owned.id)==before.end()
        || !removalPreflight(status,owned.id,initialSpace,current,ordinary.size(),initiallyEmpty)
        || missionState()!=MissionState::Absent)return false;
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27) {
        // macOS 27 exposes a native destroy operation. Use it for this exact,
        // empty, journal-owned Space without opening Mission Control.
        Class destroy=NSClassFromString(@"SLSBridgedSpaceDestroyOperation");
        if(!destroy || ![destroy instancesRespondToSelector:@selector(initWithSpaceID:)]
            || ![destroy instancesRespondToSelector:@selector(performWithWMBridgeDelegate)])
            return false;
        id operation=[[destroy alloc] initWithSpaceID:owned.id];
        if(!operation)return false;
        [operation performWithWMBridgeDelegate];
        auto expected=before;
        expected.erase(std::find(expected.begin(),expected.end(),owned.id));
        for(int retry=0;retry<80;retry++) {
            NSArray *all=managed();NSDictionary *display=builtInManaged(all);
            std::vector<uint64_t> order;
            if([managedDisplayUUID(display) isEqualToString:
                    [NSString stringWithUTF8String:owned.displayUUID.c_str()]]
                && fullSpaceOrder(display,order) && order==expected
                && currentSpaceForDisplay(all,owned.displayUUID)==initialSpace
                && ownedStatus(all,owned,cid)==OwnedStatus::Absent
                && missionState()==MissionState::Absent)return true;
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
            usleep(1000);
        }
        return false;
    }
    RemovalMCWindows mcWindows;
    if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27) {
        CFArrayRef rawIDs=CGWindowListCreate(kCGWindowListOptionAll,kCGNullWindowID);
        NSArray *descriptions=rawIDs?CFBridgingRelease(CGWindowListCreateDescriptionFromArray(rawIDs)):nil;
        if(!rawIDs || !descriptions || descriptions.count!=(NSUInteger)CFArrayGetCount(rawIDs)){if(rawIDs)CFRelease(rawIDs);return false;}
        for(CFIndex i=0;i<CFArrayGetCount(rawIDs);i++){uint32_t wid=(uint32_t)(uintptr_t)CFArrayGetValueAtIndex(rawIDs,i);if(!wid){CFRelease(rawIDs);return false;}mcWindows.before.insert(wid);}CFRelease(rawIDs);
        for(NSDictionary *space in array(beforeDisplay[@"Spaces"])) {uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];uint64_t st=0,ct=0;NSArray *wins=sid&&api().spaceWindows?CFBridgingRelease(api().spaceWindows(cid,0,(__bridge CFArrayRef)@[@(sid)],0x7,&st,&ct)):nil;if(!wins)return false;for(id raw in wins){uint32_t wid=[number(raw) unsignedIntValue];if(!wid)return false;mcWindows.before.insert(wid);}}
        AXUIElementRef wm=windowManagerApplication();pid_t wmPID=0;if(!wm||AXUIElementGetPid(wm,&wmPID)!=kAXErrorSuccess||wmPID<=0){if(wm)CFRelease(wm);return false;}CFRelease(wm);mcWindows.windowManagerPID=wmPID;
    }
    CGDirectDisplayID ids[32],builtin=0;uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return false;
    for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(ids[i])){builtin=ids[i];break;}
    if(!builtin)return false;
    if(!openMission()) {
        if(missionState()==MissionState::Visible)closeMission();
        return false;
    }
    mcWindows.active=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27;bool removed=false;
    do {
        NSDictionary *currentDisplay=builtInManaged(managed());
        std::vector<uint64_t> currentOrder;
        if(![managedDisplayUUID(currentDisplay) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
            || !fullSpaceOrder(currentDisplay,currentOrder) || currentOrder!=before
            || ownedStatus(managed(),owned,cid)!=OwnedStatus::Match
            || !awaitStableEmptyOwnedSpace(owned,cid,before,MissionState::Visible,&mcWindows))break;
        NSArray *items=array(currentDisplay[@"Spaces"]);
        if(!items || items.count!=before.size())break;
        NSUInteger index=NSNotFound;
        for(NSUInteger i=0;i<items.count;i++) {
            NSDictionary *space=dictionary(items[i]);
            if(!space || !number(space[@"type"]) || !number(space[@"id64"])) { index=NSNotFound;break; }
            if([number(space[@"id64"]) unsignedLongLongValue]==owned.id)index=i;
        }
        AXUIElementRef list=missionList(@"mc.spaces.list",builtin,false);
        if(!list)break;
        NSArray *children=array(axAttribute(list,kAXChildrenAttribute));
        if(index==NSNotFound || children.count!=items.count) { CFRelease(list);break; }
        AXUIElementRef thumbnail=(__bridge AXUIElementRef)children[index];
        CFArrayRef actions=nullptr;
        AXError names=AXUIElementCopyActionNames(thumbnail,&actions);
        bool canRemove=false;
        if(names==kAXErrorSuccess)for(NSString *action in (__bridge NSArray *)actions)
            if([action isEqualToString:@"AXRemoveDesktop"])canRemove=true;
        if(actions)CFRelease(actions);
        NSArray *preAction=managed();
        NSDictionary *preActionDisplay=builtInManaged(preAction);
        std::vector<uint64_t> preActionOrder;
        uint64_t preActionCurrent=[number(dictionary(preActionDisplay[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(!canRemove || ![managedDisplayUUID(preActionDisplay) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
            || !fullSpaceOrder(preActionDisplay,preActionOrder) || preActionOrder!=before
            || preActionCurrent!=initialSpace
            || !removalPreflight(ownedStatus(preAction,owned,cid),owned.id,initialSpace,
                preActionCurrent,userSpaces(preActionDisplay,cid).size(),
                awaitStableEmptyOwnedSpace(owned,cid,before,MissionState::Visible,&mcWindows))) {
            CFRelease(list);break;
        }
        AXError action=AXUIElementPerformAction(thumbnail,CFSTR("AXRemoveDesktop"));
        CFRelease(list);
        if(action!=kAXErrorSuccess)break;
        for(int retry=0;retry<40;retry++) {
            NSDictionary *afterDisplay=builtInManaged(managed());
            std::vector<uint64_t> after;
            auto expected=before;
            expected.erase(std::find(expected.begin(),expected.end(),owned.id));
            if(fullSpaceOrder(afterDisplay,after) && after==expected
                && ownedStatus(managed(),owned,cid)==OwnedStatus::Absent
                && [number(dictionary(afterDisplay[@"Current Space"])[@"id64"]) unsignedLongLongValue]==initialSpace) {
                removed=true;break;
            }
            usleep(50000);
        }
    } while(false);
    if(missionState()==MissionState::Visible && !closeMission())return false;
    if(missionState()!=MissionState::Absent)return false;
    auto exactRemoval=[&]() {
        NSArray *all=managed();NSDictionary *display=builtInManaged(all);
        std::vector<uint64_t> after,expected=before;
        auto found=std::find(expected.begin(),expected.end(),owned.id);
        if(found==expected.end())return false;
        expected.erase(found);
        if(![managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
            || !fullSpaceOrder(display,after) || after!=expected
            || ownedStatus(all,owned,cid)!=OwnedStatus::Absent)return false;
        uint64_t selected=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(selected!=initialSpace && !switchDisplaySpace(owned.displayUUID,initialSpace,cid))return false;
        all=managed();display=builtInManaged(all);after.clear();
        return [managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
            && fullSpaceOrder(display,after) && after==expected
            && [number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue]==initialSpace
            && ownedStatus(all,owned,cid)==OwnedStatus::Absent;
    };
    if(removed && exactRemoval())return true;
    if(exactRemoval())return true;

    // The macOS 27 Mission Control AX tree can refuse AXRemoveDesktop even
    // after the same thumbnail passed the complete ownership and emptiness
    // preflight.  Use WindowManager's managed-Space destroy operation only for
    // that exact, journal-owned, non-current empty parking Space, then require
    // the same exact endpoint before accepting the deletion.
    NSArray *retryAll=managed();NSDictionary *retryDisplay=builtInManaged(retryAll);
    std::vector<uint64_t> retryOrder;
    uint64_t retryCurrent=[number(dictionary(retryDisplay[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    Class destroy=NSClassFromString(@"SLSBridgedSpaceDestroyOperation");
    if(!destroy || ![destroy instancesRespondToSelector:@selector(initWithSpaceID:)]
        || ![destroy instancesRespondToSelector:@selector(performWithWMBridgeDelegate)]
        || ![managedDisplayUUID(retryDisplay) isEqualToString:[NSString stringWithUTF8String:owned.displayUUID.c_str()]]
        || !fullSpaceOrder(retryDisplay,retryOrder) || retryOrder!=before
        || retryCurrent!=initialSpace
        || !removalPreflight(ownedStatus(retryAll,owned,cid),owned.id,initialSpace,retryCurrent,
            userSpaces(retryDisplay,cid).size(),awaitStableEmptyOwnedSpace(owned,cid,before,MissionState::Absent)))return false;
    id operation=[[destroy alloc] initWithSpaceID:owned.id];
    if(!operation)return false;
    [operation performWithWMBridgeDelegate];
    for(int retry=0;retry<80;retry++) {
        if(exactRemoval())return true;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
        usleep(1000);
    }
    return false;
}
bool monitorDisplayReturnLocked();
bool onlineTopology(std::vector<std::string> &topology,const std::string &original,bool &builtinOnline) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->onlineTopology)
        return recoveryHooks->onlineTopology(topology,original,builtinOnline);
#endif
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return false;
    topology.clear();builtinOnline=false;
    for(uint32_t i=0;i<count;i++) {
        NSString *uuid=displayUUID(ids[i]);if(!uuid)return false;
        std::string value=uuid.UTF8String;
        topology.push_back(value);
        if(value==original && CGDisplayIsBuiltin(ids[i]))builtinOnline=true;
    }
    std::sort(topology.begin(),topology.end());
    return true;
}
bool originalDisplaysOnline(const std::vector<std::string> &online) {
    auto present=[&](const std::string &uuid) {
        return !uuid.empty() && std::find(online.begin(),online.end(),uuid)!=online.end();
    };
    if(!present(builtinUUID))return false;
    if(!wholeJournal.original.displays.empty()) {
        for(const auto &display:wholeJournal.original.displays)
            if(!present(display.uuid))return false;
    } else if(!initialSelections.empty()) {
        for(const auto &display:initialSelections)
            if(!present(display.displayUUID))return false;
    } else for(const auto &window:saved)
        if(!present(window.sourceUUID))return false;
    return true;
}
bool deferRecoveryForMissingDisplay(std::vector<std::string> online,bool builtinOnline) {
    if(shuttingDown)return false;
    if(!pendingDisplayRecovery)++recoveryGeneration;
    pendingDisplayRecovery=true;observedTopology=std::move(online);
    observedBuiltinOnline=builtinOnline;++retryBurst;
    return monitorDisplayReturnLocked();
}
bool wholeWindowMembershipMatches(const SavedWindow &w,int cid) {
    std::vector<uint64_t> expected=w.memberships.empty() ? std::vector<uint64_t>{w.space} : w.memberships;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->windowMembership)
        return recoveryHooks->windowMembership(w.id)==expected;
    if(recoveryHooks && recoveryHooks->windowSpace)
        return expected.size()==1 && recoveryHooks->windowSpace(w.id)==expected[0];
#endif
    if(!api().windowSpaces)return false;
    NSArray *raw=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(w.id)]));
    if(!raw || raw.count!=expected.size())return false;
    std::vector<uint64_t> live;
    for(id item in raw) {
        NSNumber *sid=number(item);
        if(!sid || !sid.unsignedLongLongValue)return false;
        live.push_back(sid.unsignedLongLongValue);
    }
    std::sort(live.begin(),live.end());
    return live==expected;
}
bool restoreAttachedFollowerFrame(const SavedWindow &w,int cid) {
    if(!w.followerParent || !cid || !journaledAttachedFollowerIdentity(w,false)
        || !wholeWindowMembershipMatches(w,cid)
        || !windowOnDisplay(w.id,cid,w.sourceUUID))return false;
    auto parent=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &entry) {
        return entry.id==w.followerParent && entry.pid==w.pid;
    });
    if(parent==saved.end() || !wholeWindowMembershipMatches(*parent,cid)
        || !windowOnDisplay(parent->id,cid,parent->sourceUUID))return false;
    AXUIElementRef parentAX=findAXWindow(w.pid,parent->id);
    AXUIElementRef child=findAXWindow(w.pid,w.id);
    CGRect parentFrame={},parentCG={},childFrame={},childCG={};
    bool identity=parentAX && child && readAXFrame(parentAX,&parentFrame)
        && readCGFrame(parent->id,w.pid,&parentCG)
        && nearFrame(parentFrame,parent->frame) && nearFrame(parentCG,parent->frame)
        && readAXFrame(child,&childFrame) && readCGFrame(w.id,w.pid,&childCG)
        && nearFrame(childFrame,childCG)
        && fabs(childFrame.size.width-w.frame.size.width)<=2
        && fabs(childFrame.size.height-w.frame.size.height)<=2;
    if(parentAX)CFRelease(parentAX);
    if(!identity) {if(child)CFRelease(child);return false;}
    if(nearFrame(childFrame,w.frame) && exactJournaledAttachedFollower(w)) {
        CFRelease(child);return true;
    }
    Boolean settable=false;
    if(AXUIElementIsAttributeSettable(child,kAXPositionAttribute,&settable)!=kAXErrorSuccess
        || !settable) {CFRelease(child);return false;}
    CGPoint destination=w.frame.origin;
    bool requested=false;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->setAttachedFollowerPosition)
        requested=recoveryHooks->setAttachedFollowerPosition(w,destination);
    else
#endif
    {
        AXValueRef position=AXValueCreate(kAXValueTypeCGPoint,&destination);
        requested=position && AXUIElementSetAttributeValue(child,kAXPositionAttribute,
            position)==kAXErrorSuccess;
        if(position)CFRelease(position);
    }
    CFRelease(child);
    if(!requested)return false;
    for(int retry=0;retry<20;retry++) {
        CGRect observedAX={},observedCG={};
        if(journaledAttachedFollowerIdentity(w,true,&observedAX)
            && readCGFrame(w.id,w.pid,&observedCG)
            && nearFrame(observedAX,w.frame) && nearFrame(observedCG,w.frame)
            && wholeWindowMembershipMatches(w,cid)
            && windowOnDisplay(w.id,cid,w.sourceUUID))return true;
        usleep(25000);
    }
    return false;
}
bool exactFinalWindow(const SavedWindow &w,uint64_t current,int cid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->finalWindowIdentity)
        return recoveryHooks->finalWindowIdentity(w,current);
#endif
    if(w.fullScreen || w.readOnlyCG
        || !current || oneWindowSpace(w.id,cid)!=current || !sameProcess(w)
        || !(processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds}))return false;
    if(w.cgOnly)return !w.frameFromAX && exactCGOnlyWindow(w);
    if(!w.frameFromAX)return false;
    AXUIElementRef ax=findAXWindow(w.pid,w.id);
    CGRect axFrame={},cgFrame={};
    bool exact=ax && readAXFrame(ax,&axFrame) && readCGFrame(w.id,w.pid,&cgFrame)
        && nearFrame(axFrame,cgFrame);
    if(ax)CFRelease(ax);
    return exact;
}
bool restoreWholeWindowFrames(int cid,std::string &reason) {
    if(!wholeFrameInventoryComplete)return true;
    for(const SavedWindow &w:saved) {
        if(w.followerParent)continue;
        ProcessBirth birth=processBirth(w.pid);
        if(!birth.valid()) {
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
            if(!app || app.terminated)continue;
            reason="window "+std::to_string(w.id)+" has unreadable process identity";
            return false;
        }
        if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)continue;
        bool finder=exactFinderJournal(w);
        CGRect finderCurrent={};
        WindowState state=finder
            ? (finderCurrentIdentity(w,true,&finderCurrent)
                ? WindowState::Ready : WindowState::AXUnavailable)
            : windowState(w);
        if(state==WindowState::Gone)continue;
        uint64_t runtimeSource=wholeJournal.selected[w.slot];
        if(state==WindowState::Ready && w.space!=runtimeSource
            && !wholeWindowMembershipMatches(w,cid)) {
            // The original ledger is durable. A crash after this exact WID
            // move retries here before the journal can be cleared.
            if(w.memberships.size()!=1 || oneWindowSpace(w.id,cid)!=runtimeSource
                || !spaceOnDisplay(managed(),w.space,w.sourceUUID)
                || !spaceOnDisplay(managed(),runtimeSource,w.sourceUUID)
                || !exactFinalWindow(w,runtimeSource,cid)
                || !move(w.id,w.space,cid)
                || !wholeWindowMembershipMatches(w,cid)) {
                reason="window "+std::to_string(w.id)+" could not regain its original hidden Space";
                return false;
            }
        }
        if(state!=WindowState::Ready || !wholeWindowMembershipMatches(w,cid)
            || (!finder && !windowOnDisplay(w.id,cid,w.sourceUUID))) {
            reason="window "+std::to_string(w.id)+" cannot be verified in its original Space and display";
            return false;
        }
        bool found=false;CGRect bounds=boundsForDisplayUUID(w.sourceUUID,&found);
        if(!found || !nearFrame(bounds,w.sourceDisplay)) {
            reason="window "+std::to_string(w.id)+" has a changed original display geometry";
            return false;
        }
        if(w.readOnlyCG)continue;
        bool needsFrame=true;
        if(w.frameFromAX) {
            AXUIElementRef ax=findAXWindow(w.pid,w.id);CGRect current={};
            if(ax) {
                bool readable=readAXFrame(ax,&current);
                needsFrame=!readable || !nearFrame(current,w.frame);
                // A pre-existing oversized built-in window may be normalized
                // by macOS while Spaces are cleaned up. Keep its native fit;
                // restoring the cropped original would undo the user's fix.
                if(needsFrame && readable && w.slot==0 && w.sourceUUID==builtinUUID
                    && w.space==wholeJournal.selected[0]) {
                    CGRect content=builtInContentBounds();
                    if(!CGRectIsNull(content) && !CGRectContainsRect(content,w.frame)
                        && nearFrame(current,mappedFrame(w,content))) {
                        needsFrame=false;
                        fprintf(stderr,"air_builtin_oversize_normalized wid=%u pid=%d\n",w.id,w.pid);
                    }
                }
                CFRelease(ax);
            }
        }
        if((needsFrame && !(finder ? restoreFinderFrame(w) : setFrame(w)))
            || !wholeWindowMembershipMatches(w,cid)
            || !windowOnDisplay(w.id,cid,w.sourceUUID)) {
            reason="window "+std::to_string(w.id)+" could not return to its original frame";
            return false;
        }
    }
    for(const SavedWindow &w:saved)if(w.followerParent) {
        ProcessBirth birth=processBirth(w.pid);
        if(!birth.valid()) {
            if(kill(w.pid,0)<0 && errno==ESRCH)continue;
            reason="attached window "+std::to_string(w.id)+" has unreadable process identity";
            return false;
        }
        if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)continue;
        WindowState state=windowState(w);
        if(state==WindowState::Gone)continue;
        if(!restoreAttachedFollowerFrame(w,cid)) {
            reason="attached window "+std::to_string(w.id)
                +" could not return to its original frame";
            return false;
        }
    }
    return true;
}
bool wholeSelectedRestoreStageTopology(const air::whole_space::Topology &actual,int cid) {
    air::whole_space::Topology anchored=actual;
    for(size_t index=0;index<wholeFullScreenSelections.size();index++) {
        const auto &selection=wholeFullScreenSelections[index];
        const auto &space=wholeFullScreens[selection.recordIndex];
        bool found=false;
        for(auto &display:anchored.displays)if(display.uuid==space.sourceDisplay) {
            bool completed=index<wholeFullScreenSelectionDone;
            bool pending=wholeFullScreenSelectionPending.active
                && wholeFullScreenSelectionPending.restore
                && wholeFullScreenSelectionPending.ordinal==index;
            if(display.current!=(completed ? space.sid : selection.anchor)
                && !(pending && display.current==space.sid))return false;
            display.current=selection.anchor;found=true;
        }
        if(!found)return false;
    }
    return (air::whole_space::finalOriginal(wholeJournal,anchored)
        || air::whole_space::finalOriginalPreservingExtras(wholeJournal,anchored))
        && originalWholeFullScreensRestored(actual,cid);
}
bool wholeSelectedFinalTopology(const air::whole_space::Topology &actual,int cid) {
    return wholeFullScreenSelectionDone==wholeFullScreenSelections.size()
        && !wholeFullScreenSelectionPending.active
        && wholeSelectedRestoreStageTopology(actual,cid);
}
int clearWholeRecoveryState() {
    if(!clearJournal())return error(("Whole-Space recovery journal could not be cleared: "+journalIOError).c_str());
    edgeTransfers.clear();
    runtimeLaunchWindows.clear();
    saved.clear();createdSpaces.clear();ownedSpaces.clear();reusedSlots.clear();builtinUUID.clear();initialSpace=0;
    reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();reusedRoutePending.clear();deferredInvisibleWindows.clear();retainedOrdinaryWindows.clear();reusedCachedSlot.store(0);
    reusedCachedCount.store(0);reusedCachedLoop.store(0);nextReusedRouteScan=0;
    initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
    initialSelections.clear();ordinarySpaceIdentities.clear();selectionPending={};pendingCreateBefore.clear();pendingCreate=false;
    lastSelectedSpace=0;pendingDisplayRecovery=false;observedBuiltinOnline=false;observedTopology.clear();
    active=false;windowInventoryComplete=true;wholeFrameInventoryComplete=false;
    switchVerified=false;slots[0]=slots[1]=slots[2]=0;
    wholeJournal={};parkingEvacuation={};
    wholeFullScreens.clear();wholeFullScreenMoves.clear();
    wholeFullScreenForwardDone=wholeFullScreenReverseDone=0;wholeFullScreenPending={};
    wholeFullScreenSelections.clear();wholeFullScreenSelectionPending={};
    wholeFullScreenAnchorDone=wholeFullScreenSelectionDone=0;
    wholeFullScreenSelectionRestoreStarted=false;
    wholeFullScreenRuntimeIndex=-1;wholeFullScreenRuntimePending={};
    ++recoveryGeneration;++retryBurst;releaseJournalLock();return 0;
}
bool reconcileEdgeTransfers(int cid,std::string &reason);
bool reconcileUnjournaledEdgeMoves(int cid,std::string &reason);
bool settleRuntimeLaunchesBeforeReverse(int cid,std::string &reason);
bool restoreRuntimeLaunchFramesAfterReverse(int cid,std::string &reason);
bool chromeFullScreenBecameOrdinary(const WholeFullScreenSpace &space,int cid) {
    if(space.bundle!="com.google.Chrome" || space.sourceDisplay==builtinUUID
        || !(processBirth(space.pid)==ProcessBirth{space.birthSeconds,space.birthMicroseconds})
        || spaceOnDisplay(managed(),space.sid,"")
        || !windowOnDisplay(space.owner,cid,space.sourceDisplay))return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:space.pid];
    if(!app || app.terminated || ![app.bundleIdentifier isEqualToString:@"com.google.Chrome"])
        return false;
    auto source=std::find_if(wholeJournal.original.displays.begin(),wholeJournal.original.displays.end(),
        [&](const air::whole_space::Display &display){return display.uuid==space.sourceDisplay;});
    if(source==wholeJournal.original.displays.end()
        || api().spaceType(cid,source->current)!=0
        || oneWindowSpace(space.owner,cid)!=source->current)return false;
    AXUIElementRef ax=findAXWindow(space.pid,space.owner);
    if(!ax)return false;
    id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
    id fullscreen=axAttribute(ax,CFSTR("AXFullScreen"));CGRect axFrame={},cgFrame={};
    bool exact=[role isEqual:(__bridge NSString *)kAXWindowRole]
        && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && fullscreen && CFGetTypeID((__bridge CFTypeRef)fullscreen)==CFBooleanGetTypeID()
        && !CFBooleanGetValue((__bridge CFBooleanRef)fullscreen)
        && readAXFrame(ax,&axFrame) && readCGFrame(space.owner,space.pid,&cgFrame)
        && nearFrame(axFrame,cgFrame);
    CFRelease(ax);
    bool found=false;CGRect display=boundsForDisplayUUID(space.sourceDisplay,&found);
    return exact && found && CGRectContainsRect(CGRectInset(display,-2,-2),cgFrame);
}
bool reconcileConvertedChromeFullScreens(int cid,std::string &reason) {
    if(wholeFullScreens.empty())return true;
    if(!createdSpaces.empty() || !ownedSpaces.empty()
        || wholeFullScreenForwardDone!=wholeFullScreenMoves.size()
        || wholeFullScreenReverseDone!=wholeFullScreenForwardDone
        || wholeFullScreenAnchorDone!=wholeFullScreenSelections.size()
        || wholeFullScreenSelectionDone || wholeFullScreenSelectionRestoreStarted
        || wholeFullScreenPending.active || wholeFullScreenRuntimePending.active
        || wholeFullScreenSelectionPending.active)return true;
    for(const auto &space:wholeFullScreens)
        if(!chromeFullScreenBecameOrdinary(space,cid))return true;
    auto spacesBefore=wholeFullScreens;
    auto movesBefore=wholeFullScreenMoves;
    auto selectionsBefore=wholeFullScreenSelections;
    auto forwardBefore=wholeFullScreenForwardDone,reverseBefore=wholeFullScreenReverseDone;
    auto anchorBefore=wholeFullScreenAnchorDone;
    wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeFullScreenSelections.clear();
    wholeFullScreenForwardDone=wholeFullScreenReverseDone=0;
    wholeFullScreenAnchorDone=wholeFullScreenSelectionDone=0;
    if(!persist()) {
        wholeFullScreens=std::move(spacesBefore);wholeFullScreenMoves=std::move(movesBefore);
        wholeFullScreenSelections=std::move(selectionsBefore);
        wholeFullScreenForwardDone=forwardBefore;wholeFullScreenReverseDone=reverseBefore;
        wholeFullScreenAnchorDone=anchorBefore;
        reason="Chrome's ordinary-window endpoint could not be recorded";
        return false;
    }
    fprintf(stderr,"air_chrome_fullscreen_ordinary_reconciled count=%lu\n",
        (unsigned long)spacesBefore.size());
    return true;
}
bool restoreOriginalSelectionAfterExtraFullScreen(int cid,std::string &reason) {
    air::whole_space::Topology observed;
    if(!wholeTopology(managed(),wholeDisplayOrder(),observed))return false;
    air::whole_space::Topology projected=observed;
    std::set<uint64_t> originalIDs;
    for(const auto &display:wholeJournal.original.displays)
        originalIDs.insert(display.order.begin(),display.order.end());
    bool changed=false;
    for(const auto &original:wholeJournal.original.displays) {
        auto found=std::find_if(projected.displays.begin(),projected.displays.end(),
            [&](const air::whole_space::Display &candidate){return candidate.uuid==original.uuid;});
        if(found==projected.displays.end())return false;
        if(found->current==original.current)continue;
        if(originalIDs.count(found->current)
            || std::find(found->order.begin(),found->order.end(),original.current)==found->order.end()
            || api().spaceType(cid,found->current)!=4)return false;
        found->current=original.current;changed=true;
    }
    if(!changed)return true;
    if(missionState()!=MissionState::Absent
        || !air::whole_space::finalOriginalPreservingExtras(wholeJournal,projected)
        || !originalWholeFullScreensRestored(observed,cid))return false;
    for(const auto &original:wholeJournal.original.displays) {
        if(currentSpaceForDisplay(managed(),original.uuid)==original.current)continue;
        air::whole_space::Topology expected=observed;
        auto target=std::find_if(expected.displays.begin(),expected.displays.end(),
            [&](const air::whole_space::Display &candidate){return candidate.uuid==original.uuid;});
        if(target==expected.displays.end())return false;
        target->current=original.current;
        if(!switchDisplaySpace(original.uuid,original.current,cid)) {
            reason="Could not return a display from an unrelated fullscreen Space";
            return false;
        }
        air::whole_space::Topology after;
        if(!wholeTopology(managed(),wholeDisplayOrder(),after)
            || !sameWholeTopology(expected,after)) {
            reason="Original display selection changed during fullscreen recovery";
            return false;
        }
        observed=std::move(after);
    }
    return air::whole_space::finalOriginalPreservingExtras(wholeJournal,observed);
}
bool absentEmptyOriginalSpaceDecision(const air::whole_space::Journal &journal,
                                      uint64_t sid,const std::string &uuid,
                                      const air::whole_space::Topology &observed) {
    if(!sid || uuid.empty() || journal.forwardDone!=4 || journal.reverseDone!=4
        || journal.selectionDone!=3 || journal.pending.active
        || journal.runtimeSelectionPending.active || journal.selectionPending.active
        || journal.runtimeCurrent!=journal.selected[0])return false;
    const auto *original=(const air::whole_space::Display *)nullptr;
    const auto *prepared=(const air::whole_space::Display *)nullptr;
    for(const auto &display:journal.original.displays)
        if(display.uuid==journal.builtin)original=&display;
    for(const auto &display:journal.prepared.displays)
        if(display.uuid==journal.builtin)prepared=&display;
    if(!original || !prepared || original->order.size()<=1
        || original->order.size()!=original->spaceUUIDs.size()
        || prepared->order.size()!=prepared->spaceUUIDs.size()
        || original->current==sid || prepared->current==sid
        || std::find(std::begin(journal.selected),std::end(journal.selected),sid)
            !=std::end(journal.selected))return false;
    auto found=std::find(original->order.begin(),original->order.end(),sid);
    if(found==original->order.end()
        || original->spaceUUIDs[found-original->order.begin()]!=uuid)return false;
    auto preparedFound=std::find(prepared->order.begin(),prepared->order.end(),sid);
    if(preparedFound==prepared->order.end()
        || prepared->spaceUUIDs[preparedFound-prepared->order.begin()]!=uuid)return false;
    for(const auto &display:observed.displays)
        if(std::find(display.order.begin(),display.order.end(),sid)!=display.order.end()
            || std::find(display.spaceUUIDs.begin(),display.spaceUUIDs.end(),uuid)
                !=display.spaceUUIDs.end())return false;
    return true;
}
bool adoptAbsentEmptyOriginalBuiltinSpaces(int cid,const std::vector<uint64_t> &presentParking,
                                           std::string &reason) {
    if(wholeJournal.forwardDone!=4 || wholeJournal.reverseDone!=4
        || wholeJournal.selectionDone!=3 || wholeJournal.pending.active
        || wholeJournal.runtimeSelectionPending.active || wholeJournal.selectionPending.active
        || wholeFullScreenPending.active || wholeFullScreenRuntimePending.active
        || wholeFullScreenSelectionPending.active || parkingEvacuation.active)return true;
    air::whole_space::Topology first;
    if(!wholeTopology(managed(),wholeDisplayOrder(),first)) {
        reason="The original Space inventory is unavailable";return false;
    }
    auto builtin=std::find_if(wholeJournal.original.displays.begin(),wholeJournal.original.displays.end(),
        [&](const air::whole_space::Display &d){return d.uuid==wholeJournal.builtin;});
    if(builtin==wholeJournal.original.displays.end())return true;
    // The system may remove an empty, unselected desktop while Remote Mode is
    // active.  Only retire its saved identity after two stable inventories and
    // an exhaustive check that no user or compositor window still names it.
    for(size_t index=0;index<builtin->order.size();) {
        uint64_t sid=builtin->order[index];std::string uuid=builtin->spaceUUIDs[index];
        if(!absentEmptyOriginalSpaceDecision(wholeJournal,sid,uuid,first)) {index++;continue;}
        for(const SavedWindow &w:saved)
            if(w.space==sid || std::find(w.memberships.begin(),w.memberships.end(),sid)
                !=w.memberships.end()) {
                reason="A saved window still names the absent original Space";return false;
            }
        for(const auto &w:runtimeLaunchWindows)if(w.sourceSpace==sid || w.destination==sid) {
            reason="A launched window still names the absent original Space";return false;
        }
        for(const auto &edge:edgeTransfers)
            if(edge.original==sid || edge.from==sid || edge.target==sid || edge.releaseSpace==sid) {
                reason="An edge-moved window still names the absent original Space";return false;
            }
        for(const auto &space:wholeFullScreens)if(space.sid==sid) {
            reason="A fullscreen owner still names the absent original Space";return false;
        }
        uint64_t setTags=0,clearTags=0;
        NSArray *spaceRows=CFBridgingRelease(api().spaceWindows(cid,0,
            (__bridge CFArrayRef)@[@(sid)],0x7,&setTags,&clearTags));
        if(spaceRows.count) {reason="The absent original Space still has windows";return false;}
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!all) {reason="The window inventory is unavailable";return false;}
        for(NSDictionary *row in all) {
            uint32_t wid=[number(row[(id)kCGWindowNumber]) unsignedIntValue];
            if(!wid)continue;
            NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(wid)]));
            if(!members) {reason="A window's Space membership is unavailable";return false;}
            for(id member:members)if([number(member) unsignedLongLongValue]==sid) {
                reason="A compositor window still names the absent original Space";return false;
            }
        }
        usleep(100000);
        air::whole_space::Topology second;
        if(!wholeTopology(managed(),wholeDisplayOrder(),second)
            || !sameWholeTopology(first,second)
            || !absentEmptyOriginalSpaceDecision(wholeJournal,sid,uuid,second)) {
            reason="The absent original Space did not remain absent";return false;
        }
        auto prior=wholeJournal;
        auto remove=[&](air::whole_space::Topology &topology) {
            for(auto &display:topology.displays)if(display.uuid==wholeJournal.builtin) {
                auto it=std::find(display.order.begin(),display.order.end(),sid);
                size_t position=it-display.order.begin();
                display.order.erase(it);display.spaceUUIDs.erase(display.spaceUUIDs.begin()+position);
            }
        };
        remove(wholeJournal.original);remove(wholeJournal.prepared);
        if(!air::whole_space::cleanupTopologyPreservingExtras(wholeJournal,second,presentParking)) {
            wholeJournal=std::move(prior);
            reason="Retiring the empty Space does not explain the observed topology";return false;
        }
        if(!persist()) {
            wholeJournal=std::move(prior);
            reason="The retired empty Space could not be recorded: "+journalIOError;return false;
        }
        fprintf(stderr,"air_absent_empty_original_space_retired sid=%llu\n",
            (unsigned long long)sid);
        first=std::move(second);
        builtin=std::find_if(wholeJournal.original.displays.begin(),wholeJournal.original.displays.end(),
            [&](const air::whole_space::Display &d){return d.uuid==wholeJournal.builtin;});
    }
    return true;
}
int restoreWholeLocked() {
    if(!api().conn || !api().managed || !api().spaceType || !api().spaceWindows
        || !api().windowSpaces || !api().windowDisplay || !api().axWindow || !api().dock)
        return error("Whole-Space recovery APIs are unavailable");
    auto incomplete=[&](const std::string &reason) {
        if(!persist())return error(("Whole-Space recovery journal refresh failed: "+journalIOError).c_str());
        return error((reason+"; recovery journal retained").c_str());
    };
    std::vector<std::string> online;bool builtinOnline=false;
    if(!onlineTopology(online,builtinUUID,builtinOnline))
        return incomplete("The original display topology cannot be inspected");
    if(!builtinOnline || !originalDisplaysOnline(online)) {
        if(!shuttingDown && !deferRecoveryForMissingDisplay(std::move(online),builtinOnline))
            return incomplete("Cannot monitor an original display's return");
        return incomplete(shuttingDown ? "An original display is unavailable"
                                       : "Recovery will retry when all original displays return");
    }
    int cid=api().conn();
    if(wholeFullScreenSelectionRestoreStarted) {
        if(!createdSpaces.empty() || !ownedSpaces.empty()
            || wholeFullScreenAnchorDone!=wholeFullScreenSelections.size()
            || wholeFullScreenReverseDone!=wholeFullScreenForwardDone)
            return incomplete("Fullscreen selection restoration has an incomplete cleanup boundary");
        std::string reason;
        air::whole_space::Topology topology;
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeSelectedRestoreStageTopology(topology,cid))
            return incomplete("Original fullscreen selection recovery topology changed");
        while(wholeFullScreenSelectionDone<wholeFullScreenSelections.size())
            if(!advanceWholeFullScreenSelection(true,cid,reason))
                return incomplete("Cannot restore original fullscreen selection: "+reason);
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeSelectedFinalTopology(topology,cid)
            || missionState()!=MissionState::Absent)
            return incomplete("Original selected fullscreen topology was not restored");
        if(!restoreWholeWindowFrames(cid,reason))
            return incomplete("Original ordinary windows changed after fullscreen selection: "+reason);
        return clearWholeRecoveryState();
    }
    std::string anchorReason;
    while(wholeFullScreenAnchorDone<wholeFullScreenSelections.size())
        if(!advanceWholeFullScreenSelection(false,cid,anchorReason))
            return incomplete("Cannot reconcile selected fullscreen anchor: "+anchorReason);
    if(!reconcileWholePendingParking(cid))return incomplete("A pending parking Space addition is ambiguous");
    bool preparationOnly=wholeJournal.forwardDone==0 && wholeJournal.reverseDone==0
        && !wholeJournal.pending.active && !wholeJournal.runtimeSelectionPending.active
        && wholeJournal.selectionDone==0 && !wholeJournal.selectionPending.active
        && wholeFullScreenForwardDone==0 && wholeFullScreenReverseDone==0
        && !wholeFullScreenPending.active;
    air::whole_space::Topology topology;
    if(!wholeTopology(managed(),wholeDisplayOrder(),topology))
        return incomplete("The managed whole-Space topology is unavailable");
    auto hooks=wholeHooks(cid);std::string reason;
    if(!preparationOnly) {
        if(wholeJournal.parkingCount!=2)return incomplete("Whole-Space migration lacks both parking Spaces");
        while(wholeJournal.forwardDone<4)
            if(!air::whole_space::advanceForward(wholeJournal,hooks,&reason))
                return incomplete("Cannot reconcile forward whole-Space migration: "+reason);
        if(!reconcileEdgeTransfers(cid,reason))
            return incomplete("Cannot restore an edge-moved window: "+reason);
        if(!settleRuntimeLaunchesBeforeReverse(cid,reason))
            return incomplete("Cannot reconcile a window launched during Remote Mode: "+reason);
        if(wholeJournal.reverseDone==0 && !reconcileUnjournaledEdgeMoves(cid,reason))
            return incomplete("Cannot restore a native edge-moved window: "+reason);
        if(wholeJournal.reverseDone==0 && wholeJournal.runtimeSelectionPending.active
            && wholeFullScreenRuntimeIndex<0 && !wholeFullScreenRuntimePending.active
            && !air::whole_space::normalizeForReverse(wholeJournal,hooks,&reason))
            return incomplete("Cannot settle pending runtime Space selection: "+reason);
        if(wholeJournal.reverseDone==0
            && wholeFullScreenForwardDone==wholeFullScreenMoves.size()
            && !wholeFullScreenPending.active && !wholeFullScreenRuntimePending.active
            && wholeFullScreenReverseDone==0
            && !adoptObservedWholeRuntimeSelection(cid))
            return incomplete("Cannot verify the selected fullscreen Space before restoration");
        if((wholeFullScreenRuntimeIndex>=0 || wholeFullScreenRuntimePending.active)
            && !selectWholeFullScreenRuntime(-1,cid,reason))
            return incomplete("Cannot normalize selected fullscreen Space before restoration: "+reason);
        if(wholeFullScreenPending.active && !wholeFullScreenPending.reverse
            && !reconcileWholeFullScreenForwardForRestore(cid,reason))
            return incomplete("Cannot reconcile pending fullscreen migration: "+reason);
        while(wholeFullScreenReverseDone<wholeFullScreenForwardDone)
            if(!advanceWholeFullScreen(true,cid,reason))
                return incomplete("Cannot reverse fullscreen Space migration: "+reason);
        if(wholeJournal.reverseDone==0
            && !air::whole_space::normalizeForReverse(wholeJournal,hooks,&reason))
            return incomplete("Cannot normalize the selected Space before restoration: "+reason);
        while(wholeJournal.reverseDone<4)
            if(!air::whole_space::advanceReverse(wholeJournal,hooks,&reason))
                return incomplete("Cannot reverse whole-Space migration: "+reason);
        if(wholeJournal.legacyTerminalCleanup) {
            if(!air::whole_space::restoreLegacyTerminalSelections(wholeJournal,hooks,&reason))
                return incomplete("Cannot restore evidence-upgraded display selections: "+reason);
        } else while(wholeJournal.selectionDone<3)
            if(!air::whole_space::advanceSelections(wholeJournal,hooks,&reason))
                return incomplete("Cannot restore original display selections: "+reason);
        if(!restoreRuntimeLaunchFramesAfterReverse(cid,reason))
            return incomplete("Cannot restore a window launched during Remote Mode: "+reason);
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology))
            return incomplete("Whole-Space topology differs before parking cleanup");
        if(!restoreWholeWindowFrames(cid,reason))
            return incomplete("Cannot restore original whole-Space window frames: "+reason);
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology))
            return incomplete("Whole-Space topology changed while restoring window frames");
    }
    // A parking deletion can complete immediately before the process records
    // it.  Reconcile that exact endpoint from ownership identities and the
    // durable journal instead of requiring both parking Spaces to remain.
    std::vector<uint64_t> presentParking;
    for(const auto &owner:ownedSpaces) {
        OwnedStatus status=ownedStatus(managed(),owner,cid);
        if(status==OwnedStatus::Match)presentParking.push_back(owner.id);
        else if(status!=OwnedStatus::Absent)
            return incomplete("A parking Space identity conflicts before cleanup");
    }
    if(preparationOnly) {
        if(!air::whole_space::normalizePreparationCleanup(wholeJournal,presentParking,hooks,&reason))
            return incomplete("Cannot normalize selections before parking preparation cleanup: "+reason);
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology))
            return incomplete("Parking preparation topology is unavailable after selection normalization");
    }
    if(!preparationOnly
        && !adoptAbsentEmptyOriginalBuiltinSpaces(cid,presentParking,reason))
        return incomplete("Cannot reconcile an absent original empty Space: "+reason);
    bool cleanupEndpoint=preparationOnly
        ? air::whole_space::preparationCleanupTopology(wholeJournal,topology,presentParking)
        : (air::whole_space::legacyTerminalCleanupTopology(wholeJournal,topology,presentParking)
            || air::whole_space::cleanupTopology(wholeJournal,topology,presentParking)
            || air::whole_space::cleanupTopologyPreservingExtras(wholeJournal,topology,presentParking));
    if(!cleanupEndpoint) {
        return incomplete(preparationOnly ? "Parking preparation topology changed before cleanup"
                                          : "Whole-Space topology differs before parking cleanup");
    }
    if(!beginOwnedCleanup())
        return error(("Could not journal the whole-Space cleanup boundary: "+journalIOError).c_str());
    for(size_t index=0;index<createdSpaces.size();) {
        uint64_t sid=createdSpaces[index];
        auto owner=std::find_if(ownedSpaces.begin(),ownedSpaces.end(),
            [&](const OwnedSpace &candidate){return candidate.id==sid;});
        if(owner==ownedSpaces.end())return incomplete("A parking Space ownership record is missing");
        OwnedStatus status=ownedStatus(managed(),*owner,cid);
        if(status==OwnedStatus::Match && !evacuateOwnedParkingSpace(*owner,cid,&reason))
            return incomplete("Cannot evacuate a user window from a parking Space: "+reason);
        if(status!=OwnedStatus::Match && status!=OwnedStatus::Absent)
            return incomplete("A parking Space identity conflicts before cleanup");
        auto remaining=createdSpaces;remaining.erase(remaining.begin()+index);
        air::whole_space::Topology before,after;
        if(!wholeTopology(managed(),wholeDisplayOrder(),before))
            return incomplete("Parking cleanup topology is unavailable");
        status=ownedStatus(managed(),*owner,cid);
        if(status==OwnedStatus::Match) {
            bool removed=false;
            // Dock can transiently refuse the second back-to-back desktop
            // removal even though the same owned, empty parking Space passes
            // every preflight.  Retry the complete guarded operation, and also
            // adopt an exact deletion endpoint when the destroy completed just
            // after its local verification deadline.
            for(int attempt=0;attempt<3 && !removed;attempt++) {
                if(removeOwnedSpace(*owner,cid)
                    && wholeTopology(managed(),wholeDisplayOrder(),after)
                    && air::whole_space::parkingRemovalEndpoint(wholeJournal,before,sid,after,&reason)) {
                    removed=true;
                    break;
                }
                for(int settle=0;settle<20 && !removed;settle++) {
                    usleep(50000);
                    if(ownedStatus(managed(),*owner,cid)==OwnedStatus::Absent
                        && wholeTopology(managed(),wholeDisplayOrder(),after)
                        && air::whole_space::parkingRemovalEndpoint(wholeJournal,before,sid,after,&reason))
                        removed=true;
                }
                if(!removed && ownedStatus(managed(),*owner,cid)!=OwnedStatus::Match)break;
                if(!removed)usleep(250000);
            }
            if(!removed)
                return incomplete("A verified parking Space could not be removed exactly");
        } else if(status==OwnedStatus::Absent) {
            after=before;
            bool exact=preparationOnly
                ? air::whole_space::preparationCleanupTopology(wholeJournal,after,remaining)
                : (air::whole_space::legacyTerminalCleanupTopology(wholeJournal,after,remaining)
                    || air::whole_space::cleanupTopology(wholeJournal,after,remaining)
                    || air::whole_space::cleanupTopologyPreservingExtras(wholeJournal,after,remaining));
            if(!exact)return incomplete("An absent parking Space has an unrelated topology");
        } else return incomplete("A parking Space identity conflicts with the recovery journal");
        ownedSpaces.erase(owner);createdSpaces.erase(createdSpaces.begin()+index);
        if(!persist())return error(("Could not persist parking Space cleanup: "+journalIOError).c_str());
    }
    if(!reconcileConvertedChromeFullScreens(cid,reason))
        return incomplete(reason);
    if(!restoreOriginalSelectionAfterExtraFullScreen(cid,reason))
        return incomplete(reason.empty() ? "An unrelated fullscreen Space changed original display selection"
                                         : reason);
    if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
        || (!air::whole_space::finalOriginal(wholeJournal,topology)
            && !air::whole_space::finalOriginalPreservingExtras(wholeJournal,topology))
        || !originalWholeFullScreensRestored(topology,cid)
        || missionState()!=MissionState::Absent)
        return incomplete("The exact original topology and selections were not restored");
    if(!restoreWholeWindowFrames(cid,reason))
        return incomplete("Cannot verify original whole-Space window frames after parking cleanup: "+reason);
    if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
        || (!air::whole_space::finalOriginal(wholeJournal,topology)
            && !air::whole_space::finalOriginalPreservingExtras(wholeJournal,topology))
        || !originalWholeFullScreensRestored(topology,cid))
        return incomplete("Whole-Space topology changed during final window frame restoration");
    if(!wholeFullScreenSelections.empty()) {
        wholeFullScreenSelectionRestoreStarted=true;
        if(!persist()) {
            wholeFullScreenSelectionRestoreStarted=false;
            return error(("Cannot journal original fullscreen selection restoration: "+journalIOError).c_str());
        }
        while(wholeFullScreenSelectionDone<wholeFullScreenSelections.size())
            if(!advanceWholeFullScreenSelection(true,cid,reason))
                return incomplete("Cannot restore original fullscreen selection: "+reason);
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeSelectedFinalTopology(topology,cid)
            || missionState()!=MissionState::Absent)
            return incomplete("Original selected fullscreen topology was not restored");
        if(!restoreWholeWindowFrames(cid,reason))
            return incomplete("Original ordinary windows changed after fullscreen selection: "+reason);
    }
    return clearWholeRecoveryState();
}
void spacesDisplayChanged(CGDirectDisplayID,CGDisplayChangeSummaryFlags,void *);
bool monitorDisplayReturnLocked() {
    if(callbackRegistered)return true;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->registerCallback) {
        callbackRegistered=recoveryHooks->registerCallback();return callbackRegistered;
    }
#endif
    callbackRegistered=CGDisplayRegisterReconfigurationCallback(spacesDisplayChanged,nullptr)==kCGErrorSuccess;
    return callbackRegistered;
}
void scheduleRecoveryLocked(uint64_t generation,uint64_t burst,unsigned attempt);
bool restoreFullScreenWindow(SavedWindow &w,int cid) {
    uint32_t actual=resolvedWindowID(w);
    if(w.fullScreenPhase<1 || w.fullScreenPhase>4)return false;
    if(!actual) {
        uint64_t hiddenSpace=fullScreenSpaceID(w,cid);
        DisplaySelection *display=selectionForDisplay(w.sourceUUID);
        bool initial=initialFullScreenIndex>=0 && (size_t)initialFullScreenIndex<saved.size()
            && &w==&saved[initialFullScreenIndex] && verifiedInitialFullScreenSpace(hiddenSpace,cid);
        return initial || ((w.fullScreenPhase==1 || w.fullScreenPhase==4)
            && hiddenSpace==w.fullScreenSpace && fullScreenMembership(w,cid))
            || (w.fullScreenPhase==4 && display && display->hostSpace==hiddenSpace
                && fullScreenMembership(w,cid))
            || (!initialSelections.empty() && w.fullScreenPhase==3 && hiddenSpace
                && fullScreenMembership(w,cid));
    }
    if(actual!=w.id) {
        w.id=actual;
        if(!persist())return false;
    }
    int state=fullScreenState(w);
    if(state==1 && awaitFullScreenMembership(w,cid))
        return w.slot==0 || sourceCurrentIs(w,fullScreenSpaceID(w,cid));
    if(state!=0)return false;
    uint64_t expectedSourceCurrent=0;
    if(w.fullScreenPhase==2 || w.fullScreenPhase==3) {
        expectedSourceCurrent=w.space;
        if(w.slot>0 && !sourceCurrentIs(w,expectedSourceCurrent))return false;
        if(api().spaceType(cid,w.space)!=0 || !spaceOnDisplay(managed(),w.space,w.sourceUUID)
            || !move(w.id,w.space,cid) || !setFrame(w))return false;
        if(!windowOnDisplay(w.id,cid,w.sourceUUID))return false;
    } else {
        uint64_t ordinary=awaitOrdinaryAfterExit(w,cid);
        if(!windowOnDisplay(w.id,cid,w.sourceUUID) || !ordinary)return false;
        expectedSourceCurrent=ordinary;
        if(w.slot>0 && !sourceCurrentIs(w,ordinary))return false;
        if(initialFullScreenIndex>=0 && (size_t)initialFullScreenIndex<saved.size()
            && &w==&saved[initialFullScreenIndex] && !initialSpace) {
            NSDictionary *display=builtInManaged(managed());
            if(![managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]]
                || [number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue]!=ordinary
                || !spaceOnDisplay(managed(),ordinary,builtinUUID))return false;
            initialSpace=ordinary;
            if(!persist()){initialSpace=0;return false;}
        }
        if(w.fullScreenPhase==1) {
            w.fullScreenPhase=4;
            if(!persist()) {w.fullScreenPhase=1;return false;}
        }
    }
    if(w.fullScreenPhase==2) {
        w.fullScreenPhase=3;
        if(!persist()) {w.fullScreenPhase=2;return false;}
    }
    AXUIElementRef retained=nullptr;
#ifdef AIR_SPACES_JOURNAL_TEST
    bool mocked=recoveryHooks && recoveryHooks->setFullScreen;
#else
    bool mocked=false;
#endif
    if(!mocked)retained=findIdentifiedAXWindow(w,nullptr);
    if(!mocked && !retained)return false;
    if(w.slot>0 && !sourceCurrentIs(w,expectedSourceCurrent)) {
        if(retained)CFRelease(retained);
        return false;
    }
    bool entered=setFullScreen(w,true,retained);
    bool verified=entered && awaitFullScreenMembership(w,cid,retained);
    if(verified && w.slot>0)verified=awaitSourceCurrent(w,fullScreenSpaceID(w,cid));
    if(retained)CFRelease(retained);
    return verified;
}
bool currentSpaceWasRestoredFullScreen(uint64_t current,int cid) {
    if(!current || api().spaceType(cid,current)!=4)return false;
    for(auto &w:saved)if(w.fullScreen && (w.fullScreenPhase==3 || w.fullScreenPhase==4) && w.slot==0
        && w.sourceUUID==builtinUUID && resolvedWindowID(w)==w.id
        && fullScreenSpaceID(w,cid)==current && awaitFullScreenMembership(w,cid))return true;
    return false;
}
bool reconcileOrdinarySpaceIDs(NSArray *inventory,int cid,std::string &reason) {
    if(ordinarySpaceIdentities.empty())return true; // Older journals remain ID-strict.
    std::set<uint64_t> referenced={initialSpace};
    for(const auto &w:saved) {
        referenced.insert(w.space);
        referenced.insert(w.memberships.begin(),w.memberships.end());
    }
    for(const auto &selection:initialSelections) {
        if(selection.type==0)referenced.insert(selection.space);
        referenced.insert(selection.hostSpace);
    }
    if(selectionPending.active) {
        referenced.insert(selectionPending.fromSpace);
        referenced.insert(selectionPending.targetSpace);
    }
    if(parkingEvacuation.active)referenced.insert(parkingEvacuation.window.destinationSpace);
    referenced.insert(pendingCreateBefore.begin(),pendingCreateBefore.end());
    for(const auto &space:reusedSlots)referenced.insert(space.id);
    for(uint64_t sid:slots)if(sid)referenced.insert(sid);
    if(lastSelectedSpace)referenced.insert(lastSelectedSpace);
    std::map<uint64_t,uint64_t> replacements;
    std::set<uint64_t> resolved;
    for(const auto &identity:ordinarySpaceIdentities) {
        if(!referenced.count(identity.id))continue;
        uint64_t match=0;unsigned matches=0;bool oldIDOccupied=false;
        for(NSDictionary *display in inventory) {
            NSString *displayUUID=managedDisplayUUID(display);
            for(NSDictionary *space in array(display[@"Spaces"])) {
                uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
                NSString *uuid=space[@"uuid"];
                if(sid==identity.id && (![displayUUID isEqualToString:
                    [NSString stringWithUTF8String:identity.displayUUID.c_str()]]
                    || ![uuid isKindOfClass:NSString.class]
                    || ![uuid isEqualToString:[NSString stringWithUTF8String:identity.spaceUUID.c_str()]]))
                    oldIDOccupied=true;
                if([displayUUID isEqualToString:[NSString stringWithUTF8String:identity.displayUUID.c_str()]]
                    && [uuid isKindOfClass:NSString.class]
                    && [uuid isEqualToString:[NSString stringWithUTF8String:identity.spaceUUID.c_str()]]) {
                    matches++;match=sid;
                    if(!sid || api().spaceType(cid,sid)!=0) {
                        reason="An original ordinary Space UUID now has a different type";return false;
                    }
                }
            }
        }
        if(oldIDOccupied || matches>1 || (match && !resolved.insert(match).second)) {
            reason="An original ordinary Space UUID or numeric ID is ambiguous";return false;
        }
        replacements[identity.id]=match;
    }
    bool changed=false;
    auto remap=[&](uint64_t &sid)->bool {
        auto found=replacements.find(sid);
        if(found==replacements.end())return true;
        if(!found->second) {
            reason="An original ordinary Space UUID is unavailable";return false;
        }
        if(sid!=found->second){sid=found->second;changed=true;}
        return true;
    };
    for(auto &w:saved) {
        if(!remap(w.space))return false;
        for(uint64_t &sid:w.memberships)if(!remap(sid))return false;
    }
    if(!remap(initialSpace))return false;
    for(auto &selection:initialSelections) {
        if(selection.type==0 && !remap(selection.space))return false;
        if(!remap(selection.hostSpace))return false;
    }
    if(selectionPending.active && (!remap(selectionPending.fromSpace)
        || !remap(selectionPending.targetSpace)))return false;
    if(parkingEvacuation.active && !remap(parkingEvacuation.window.destinationSpace))return false;
    for(uint64_t &sid:pendingCreateBefore)if(!remap(sid))return false;
    for(auto &space:reusedSlots)if(!remap(space.id))return false;
    for(uint64_t &sid:slots)if(sid && !remap(sid))return false;
    if(lastSelectedSpace && !remap(lastSelectedSpace))return false;
    for(auto &identity:ordinarySpaceIdentities) {
        auto found=replacements.find(identity.id);
        if(found!=replacements.end() && found->second)identity.id=found->second;
    }
    if(changed && !persist()) {
        reason="Cannot persist remapped ordinary Space identities: "+journalIOError;return false;
    }
    return true;
}
bool ordinaryRestoredReadOnlyDecision(const SavedWindow &w,bool sameProcessIdentity,
                                      bool originalEndpoint,bool stableOriginalFrame) {
    return !w.fullScreen && !w.axDialog && !w.followerParent && !w.cgOnly
        && !w.readOnlyCG && !w.minimized && w.frameFromAX && w.id && w.pid>0 && w.space
        && !w.sourceUUID.empty() && w.launchTime>0 && sameProcessIdentity
        && (w.memberships.empty()
            || (w.memberships.size()==1 && w.memberships[0]==w.space))
        && originalEndpoint && stableOriginalFrame;
}
bool alreadyRestoredOrdinary(const SavedWindow &w,int cid) {
    if(!ordinaryRestoredReadOnlyDecision(w,true,true,true))return false;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->alreadyRestoredOrdinary)
        return recoveryHooks->alreadyRestoredOrdinary(w);
#endif
    if(!sameProcess(w)
        || (w.birthSeconds
            && !(processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds}))
        || (!w.birthSeconds && w.birthMicroseconds)
        || api().spaceType(cid,w.space)!=0
        || !spaceOnDisplay(managed(),w.space,w.sourceUUID)
        || !exactSingletonMembership(cid,w.id,w.space)
        || !windowOnDisplay(w.id,cid,w.sourceUUID))return false;
    NSDictionary *cg=windowLayerDescription(w.id);
    CGRect first={},second={};
    NSNumber *onscreen=number(cg[(id)kCGWindowIsOnscreen]);
    if(!cg || [number(cg[(id)kCGWindowOwnerPID]) intValue]!=w.pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
        || (w.minimizedKnown && (!onscreen || !onscreen.boolValue))
        || !readCGFrame(w.id,w.pid,&first)
        || !CGRectEqualToRect(first,w.frame)
        || !stableCGSurface(cg,w.id,w.pid,first))return false;
    usleep(25000);
    return readCGFrame(w.id,w.pid,&second) && CGRectEqualToRect(second,w.frame)
        && exactSingletonMembership(cid,w.id,w.space)
        && windowOnDisplay(w.id,cid,w.sourceUUID);
}
int restoreLocked() {
    if(!wholeJournal.original.displays.empty())return restoreWholeLocked();
    if(!api().conn || !api().managed || !api().windowSpaces || !api().spaceType || !api().axWindow)
        return error("Spaces recovery API unavailable");
    int cid=api().conn();bool failed=false;std::string firstFailure;
    auto incomplete=[&](const char *reason) {
        if(!persist())return error(("Spaces recovery is incomplete and its journal could not be refreshed: "+journalIOError).c_str());
        return error(reason);
    };
    std::vector<std::string> topology;
    if(!builtinUUID.empty()) {
        bool builtinOnline=false;
        if(!onlineTopology(topology,builtinUUID,builtinOnline))
            return incomplete("The original built-in display cannot be inspected; Spaces recovery journal retained");
        if(!builtinOnline || !originalDisplaysOnline(topology)) {
            if(!shuttingDown && !deferRecoveryForMissingDisplay(std::move(topology),builtinOnline))
                return incomplete("Cannot monitor an original display's return; Spaces recovery journal retained");
            return incomplete(shuttingDown
                ? "An original display is unavailable; Spaces recovery journal retained"
                : "An original display is unavailable; Spaces recovery will retry when all return");
        }
    }
    NSArray *inventory=managed();
    std::string identityReason;
    if(!reconcileOrdinarySpaceIDs(inventory,cid,identityReason))
        return error((identityReason+"; recovery journal retained").c_str());
    if(selectionPending.active && !reconcileSelectionPending(cid))
        return error("A pending display selection or full-screen action cannot be reconciled without changing an unrelated Space; recovery journal retained");
    bool preparationOnly=(!initialSelections.empty() || initialFullScreenIndex>=0) && createdSpaces.empty()
        && !pendingCreate && !slots[0] && !slots[1] && !slots[2] && !active;
    std::string endpointReason;
    if(!builtinUUID.empty() && !recoveryEndpointsAvailable(
            topology,inventory,preparationOnly,cid,&endpointReason)) {
        endpointReason+="; recovery journal retained";
        return incomplete(endpointReason.c_str());
    }
    for(size_t index=0;index<saved.size();index++) {
        SavedWindow &w=saved[index];
        auto failedWindow=[&](const char *stage) {
            failed=true;
            if(firstFailure.empty())firstFailure=" [wid="+std::to_string(w.id)
                +" stage="+stage+"]";
        };
        // The initial fullscreen window exits before any desktop migration.
        // During that preparation interval ordinary windows and other phase-1
        // fullscreen windows have never been changed by this Host.
        if(preparationOnly && (!w.fullScreen
            || ((int)index!=initialFullScreenIndex && w.fullScreenPhase==1)))continue;
        std::string accessReason;
        RecoverySpaceAccess access=prepareRecoveryWindowAccess(w,cid,&accessReason);
        if(access==RecoverySpaceAccess::Failed) {
            accessReason+="; recovery journal retained";
            return incomplete(accessReason.c_str());
        }
        WindowState state=windowState(w);
        if(access==RecoverySpaceAccess::Ready)
            for(int retry=0;state==WindowState::AXUnavailable && retry<40;retry++) {
                usleep(50000);state=windowState(w);
            }
        if(state==WindowState::AXUnavailable) {
            accessReason.clear();
            RecoverySpaceAccess originalAccess=prepareOriginalWindowAccess(w,cid,&accessReason);
            if(originalAccess==RecoverySpaceAccess::Failed) {
                accessReason+="; recovery journal retained";
                return incomplete(accessReason.c_str());
            }
            if(originalAccess==RecoverySpaceAccess::Ready)
                for(int retry=0;state==WindowState::AXUnavailable && retry<40;retry++) {
                    usleep(50000);state=windowState(w);
                }
        }
        if(state==WindowState::Gone)continue;
        if(state==WindowState::AXUnavailable) {
            if(alreadyRestoredOrdinary(w,cid))continue;
            failedWindow("ax_state");continue;
        }
        if(w.fullScreen) {
            bool needsReentry=(w.fullScreenPhase==2 || w.fullScreenPhase==3) && fullScreenState(w)==0;
            bool journaledSelection=!initialSelections.empty();
            if(journaledSelection && needsReentry && (int)index==initialFullScreenIndex
                && !selectionPending.active)reconcileVanishedInitialFullScreenSelection(index,cid);
            if(journaledSelection && needsReentry && currentSpaceForDisplay(managed(),w.sourceUUID)!=w.space
                && !beginHostSelection(w.sourceUUID,w.space,(int)index,SelectionPurpose::RestoreAnchor,cid)) {failedWindow("select_reentry_anchor");continue;}
            if(journaledSelection && needsReentry && !beginReentryAction(index)) {failedWindow("journal_reentry");continue;}
            if(!restoreFullScreenWindow(w,cid))failedWindow("restore_fullscreen");
            else if(journaledSelection && needsReentry) {
                uint64_t restored=fullScreenSpaceID(w,cid);
                if(!finishReentryAction(index,restored))failedWindow("complete_reentry");
            }
            continue;
        }
        bool exactSurface=w.axDialog || (w.cgOnly && w.bundle=="com.lujjjh.LinearMouse"
            && w.title=="LinearMouse");
        if(api().spaceType(cid,w.space)!=0 || !spaceOnDisplay(inventory,w.space,w.sourceUUID)
            || (exactSurface && windowState(w)!=WindowState::Ready)
            || !move(w.id,w.space,cid)) { failedWindow("move_original");continue; }
        if(w.minimizedKnown) {
            std::string minimizedAccessReason;
            if(prepareOriginalWindowAccess(w,cid,&minimizedAccessReason)==RecoverySpaceAccess::Failed) {
                failedWindow("select_original_frame");continue;
            }
            if(w.minimized && !setWindowMinimizedState(w,false)) {
                failedWindow("unminimize_original");continue;
            }
        }
        if(!setFrame(w)) {
            restoreWindowMinimized(w);failedWindow("frame_original");continue;
        }
        if(!restoreWindowMinimized(w)) {failedWindow("minimized_original");continue;}
        if(!w.sourceUUID.empty()) {
            bool returnedToDisplay=false;
            for(int retry=0;retry<20;retry++) {
                if(windowOnDisplay(w.id,cid,w.sourceUUID)){returnedToDisplay=true;break;}
                usleep(25000);
            }
            if(!returnedToDisplay)failedWindow("display_original");
        }
    }
    if(failed)return incomplete(("Some windows could not be returned to their original Spaces, displays, and frames"
        +firstFailure+"; recovery journal retained").c_str());
    if(initialFullScreenIndex>=0 && !initialSpace) {
        if(!createdSpaces.empty() || pendingCreate || (size_t)initialFullScreenIndex>=saved.size())
            return incomplete("The initial full-screen desktop anchor was never verified; recovery journal retained");
        SavedWindow &original=saved[initialFullScreenIndex];
        uint64_t target=fullScreenSpaceID(original,cid);
        if(!verifiedInitialFullScreenSpace(target,cid) || builtInCurrentSpace()!=target
            || !awaitFullScreenMembership(original,cid) || builtInCurrentSpace()!=target
            || missionState()!=MissionState::Absent)
            return incomplete("The initial full-screen window could not be verified as active; recovery journal retained");
        if(!clearJournal())return error(("Spaces recovery journal could not be cleared: "+journalIOError).c_str());
        saved.clear();createdSpaces.clear();ownedSpaces.clear();reusedSlots.clear();builtinUUID.clear();initialSpace=0;
        reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();reusedRoutePending.clear();deferredInvisibleWindows.clear();retainedOrdinaryWindows.clear();reusedCachedSlot.store(0);
        reusedCachedCount.store(0);reusedCachedLoop.store(0);nextReusedRouteScan=0;
        initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
        initialSelections.clear();ordinarySpaceIdentities.clear();selectionPending={};
        pendingCreateBefore.clear();pendingCreate=false;lastSelectedSpace=0;
        pendingDisplayRecovery=false;observedBuiltinOnline=false;observedTopology.clear();
        active=false;windowInventoryComplete=true;switchVerified=false;slots[0]=slots[1]=slots[2]=0;
        parkingEvacuation={};
        ++recoveryGeneration;++retryBurst;releaseJournalLock();return 0;
    }
    NSDictionary *builtin=builtInManaged(managed());
    if((!builtinUUID.empty() && ![managedDisplayUUID(builtin) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])
        || !managedSpace(builtin,initialSpace) || api().spaceType(cid,initialSpace)!=0)
        return incomplete("The original built-in Space is unavailable; recovery journal retained");
    uint64_t current=[number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    if(current!=initialSpace) {
        bool inSessionSlot=current==lastSelectedSpace;
        for(uint64_t sid:slots)if(sid && sid==current)inSessionSlot=true;
        if((!inSessionSlot && !currentSpaceWasRestoredFullScreen(current,cid)
            && !(initialFullScreenIndex>=0 && verifiedInitialFullScreenSpace(current,cid)))
            || builtInCurrentSpace()!=current || !switchSpace(initialSpace,cid))
            return incomplete("The initial Space could not be safely restored; recovery journal retained");
    }
    if(pendingCreate)
        return incomplete("A Space add was interrupted before its ownership could be verified; recovery journal retained");
    if(!beginOwnedCleanup())
        return error(("Could not journal the owned Space cleanup boundary: "+journalIOError).c_str());
    for(size_t i=0;i<createdSpaces.size();) {
        uint64_t sid=createdSpaces[i];
        auto owner=std::find_if(ownedSpaces.begin(),ownedSpaces.end(),
            [&](const OwnedSpace &space){return space.id==sid;});
        if(owner==ownedSpaces.end()) {
            if(spaceOnDisplay(managed(),sid,""))
                return incomplete("A legacy journal cannot prove ownership of a created Space; recovery journal retained");
            createdSpaces.erase(createdSpaces.begin()+i);
            if(!persist())return error(("Could not persist completed Space recovery: "+journalIOError).c_str());
            continue;
        }
        OwnedStatus status=ownedStatus(managed(),*owner,cid);
        if(status==OwnedStatus::Match) {
            std::string reason;
            if(!evacuateOwnedParkingSpace(*owner,cid,&reason))
                return incomplete(("Cannot evacuate a user window from an owned Space: "+reason
                    +"; recovery journal retained").c_str());
        }
        if(status!=OwnedStatus::Absent && (status!=OwnedStatus::Match || !removeOwnedSpace(*owner,cid)))
            return incomplete("An owned Space could not be verified empty and removed; recovery journal retained");
        ownedSpaces.erase(owner);
        createdSpaces.erase(createdSpaces.begin()+i);
        if(!persist())return error(("Could not persist completed Space recovery: "+journalIOError).c_str());
    }
    if(initialFullScreenIndex>=0) {
        if((size_t)initialFullScreenIndex>=saved.size())
            return incomplete("The initial full-screen window identity is invalid; recovery journal retained");
        SavedWindow &original=saved[initialFullScreenIndex];
        if(windowState(original)==WindowState::Gone) {
            if(!initialSpace || api().spaceType(cid,initialSpace)!=0
                || !spaceOnDisplay(managed(),initialSpace,builtinUUID))
                return incomplete("The closed initial full-screen window has no verified ordinary fallback; recovery journal retained");
        } else {
        uint64_t target=fullScreenSpaceID(original,cid);
        if(!verifiedInitialFullScreenSpace(target,cid) || builtInCurrentSpace()!=initialSpace)
            return incomplete("The restored initial full-screen Space is unavailable; recovery journal retained");
        if(!finalSelectionPending) {
            finalSelectionPending=true;
            if(!persist()){finalSelectionPending=false;return error(("Could not journal final full-screen selection: "+journalIOError).c_str());}
        }
        if(builtInCurrentSpace()!=initialSpace || !switchSpace(target,cid)
            || builtInCurrentSpace()!=target || !awaitFullScreenMembership(original,cid)
            || builtInCurrentSpace()!=target)
            return incomplete("The initial full-screen window could not be safely reselected; recovery journal retained");
        }
    }
    if(initialSelections.empty())for(SavedWindow &w:saved)if(w.fullScreen && w.slot>0
        && windowState(w)!=WindowState::Gone) {
        uint64_t restored=fullScreenSpaceID(w,cid);
        if(!restored || !sourceCurrentIs(w,restored)
            || !awaitFullScreenMembership(w,cid) || !sourceCurrentIs(w,restored))
            return incomplete("An external display's original full-screen selection was not restored; recovery journal retained");
    }
    for(const DisplaySelection &selection:initialSelections) {
        if(selection.displayUUID==builtinUUID)continue;
        uint64_t target=selection.space;
        bool closedFullScreen=false;
        if(selection.type==4) {
            if(selection.fullScreenWindow<0 || (size_t)selection.fullScreenWindow>=saved.size())
                return incomplete("A display's original full-screen selection identity is invalid; recovery journal retained");
            SavedWindow &w=saved[selection.fullScreenWindow];
            WindowState state=windowState(w);
            if(state==WindowState::Gone) {
                closedFullScreen=true;
                // Closing a full-screen window removes its Space.  The
                // journaled ordinary source desktop is its exact fallback.
                target=w.space;
                if(!target || api().spaceType(cid,target)!=0
                    || !spaceOnDisplay(managed(),target,selection.displayUUID))
                    return incomplete("A closed full-screen window has no verified ordinary source Space; recovery journal retained");
            } else {
                // The original full-screen Space can be present while its AX
                // window is inaccessible because another Space is selected.
                // Verify process and Space identity before changing selection;
                // check AX only after its Space is visible again.
                if(state!=WindowState::Ready)
                    return incomplete("A display's original full-screen window identity is unavailable; recovery journal retained");
#ifndef AIR_SPACES_JOURNAL_TEST
                if(!sameProcess(w) || (w.birthSeconds
                    && !(processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds})))
                    return incomplete("A display's original full-screen process changed; recovery journal retained");
#endif
                target=fullScreenSpaceID(w,cid);
                if(!target || !spaceOnDisplay(managed(),target,selection.displayUUID))
                    return incomplete("A display's original full-screen window was not restored; recovery journal retained");
            }
        }
        uint64_t current=currentSpaceForDisplay(managed(),selection.displayUUID);
        bool hostInduced=current==selection.hostSpace && spaceOnDisplay(managed(),current,selection.displayUUID);
        if(hostInduced && api().spaceType(cid,current)==4) {
            hostInduced=false;
            for(SavedWindow &w:saved)if(w.fullScreen && w.sourceUUID==selection.displayUUID
                && (w.fullScreenPhase==3 || w.fullScreenPhase==4
                    || (w.fullScreenPhase==1 && w.fullScreenSpace==current))
                && windowState(w)!=WindowState::Gone
                && fullScreenSpaceID(w,cid)==current) {hostInduced=true;break;}
        }
        if(!current || !target || (!hostInduced && current!=target))
            return incomplete("A display has an unrelated user-selected Space; recovery journal retained");
        SelectionPurpose purpose=closedFullScreen
            ? SelectionPurpose::RestoreAnchor : SelectionPurpose::Final;
        if(current!=target && (!beginHostSelection(selection.displayUUID,target,-1,purpose,cid)
            || currentSpaceForDisplay(managed(),selection.displayUUID)!=target))
            return incomplete("A display's original selected Space could not be restored; recovery journal retained");
        if(selection.type==4 && !closedFullScreen) {
            SavedWindow &w=saved[selection.fullScreenWindow];
            if(fullScreenSpaceID(w,cid)!=target || !awaitFullScreenMembership(w,cid)
                || currentSpaceForDisplay(managed(),selection.displayUUID)!=target)
                return incomplete("A display's original full-screen window was not restored; recovery journal retained");
        }
    }
    if(missionState()!=MissionState::Absent)
        return incomplete("Mission Control could not be verified closed; recovery journal retained");
    if(!clearJournal())return error(("Spaces recovery journal could not be cleared: "+journalIOError).c_str());
    saved.clear();createdSpaces.clear();ownedSpaces.clear();reusedSlots.clear();builtinUUID.clear();initialSpace=0;
    reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();reusedRoutePending.clear();deferredInvisibleWindows.clear();retainedOrdinaryWindows.clear();reusedCachedSlot.store(0);
    reusedCachedCount.store(0);reusedCachedLoop.store(0);nextReusedRouteScan=0;
    initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
    initialSelections.clear();ordinarySpaceIdentities.clear();selectionPending={};
    pendingCreateBefore.clear();pendingCreate=false;lastSelectedSpace=0;
    pendingDisplayRecovery=false;observedBuiltinOnline=false;observedTopology.clear();
    ++recoveryGeneration;++retryBurst;
    active=false;windowInventoryComplete=true;switchVerified=false;slots[0]=slots[1]=slots[2]=0;
    parkingEvacuation={};
    releaseJournalLock();return 0;
}
int restoreWithSettlingRetryLocked() {
    int result=restoreLocked();
    for(unsigned attempt=1;result && attempt<6;attempt++) {
        if(pendingDisplayRecovery || !journalIOError.empty()
            || ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])break;
        usleep(500000);
        if(missionState()==MissionState::Visible && !closeMission())break;
        result=restoreLocked();
        if(!result) {
            NSLog(@"RustDesk Air: Spaces restoration completed after %u settling retries",attempt);
            air_set_error("");
        }
    }
    return result;
}
bool loopSupportedLocked() {
    if(!active || !switchVerified || shuttingDown || retryDisplayInFlight || !api().conn
        || !bridgedSwitchAvailable() || ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])return false;
    for(int i=0;i<3;i++) {
        if(!slots[i])return false;
        for(int j=0;j<i;j++)if(slots[i]==slots[j])return false;
    }
    if(!wholeJournal.original.displays.empty()) {
        air::whole_space::Topology topology;
        if(wholeFullScreenRuntimeIndex>=0 || wholeFullScreenRuntimePending.active
            || !wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeRuntimeTopologyWithFullScreens(topology,api().conn()))return false;
    }
    return true;
}
void retryRecovery(uint64_t generation,uint64_t burst,unsigned attempt) {
    {
        std::lock_guard<std::mutex> lock(mutex);
        if(shuttingDown || retryDisplayInFlight || !pendingDisplayRecovery
            || generation!=recoveryGeneration || burst!=retryBurst
            || ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])return;
        retryDisplayInFlight=true;
    }
#ifdef AIR_SPACES_JOURNAL_TEST
    int displayResult=recoveryHooks && recoveryHooks->displayRestore
        ? recoveryHooks->displayRestore() : air_display_restore();
#else
    int displayResult=air_display_restore();
#endif
    std::lock_guard<std::mutex> lock(mutex);
    retryDisplayInFlight=false;
    if(shuttingDown || !pendingDisplayRecovery || generation!=recoveryGeneration || burst!=retryBurst
        || ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])return;
    int result=displayResult ? displayResult : restoreLocked();
    if(result && pendingDisplayRecovery && generation==recoveryGeneration && burst==retryBurst && attempt<2)
        scheduleRecoveryLocked(generation,burst,attempt+1);
}
void scheduleRecoveryLocked(uint64_t generation,uint64_t burst,unsigned attempt) {
    if(attempt>=3)return;
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->scheduleRetry) {
        recoveryHooks->scheduleRetry(generation,burst,attempt);return;
    }
#endif
    int delay=attempt==0 ? 500 : attempt==1 ? 1500 : 3000;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(delay)*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        retryRecovery(generation,burst,attempt);
    });
}
void processSpacesDisplayChangedLocked() {
    if(shuttingDown || !pendingDisplayRecovery || builtinUUID.empty())return;
    std::vector<std::string> topology;bool builtinOnline=false;
    if(!onlineTopology(topology,builtinUUID,builtinOnline)
        || (topology==observedTopology && builtinOnline==observedBuiltinOnline))return;
    observedTopology=std::move(topology);observedBuiltinOnline=builtinOnline;
    ++retryBurst;
    if(builtinOnline && originalDisplaysOnline(observedTopology))
        scheduleRecoveryLocked(recoveryGeneration,retryBurst,0);
}
void spacesDisplayChanged(CGDirectDisplayID,CGDisplayChangeSummaryFlags flags,void *) {
    if(flags & kCGDisplayBeginConfigurationFlag)return;
    if(callbackQueued.exchange(true))return;
    dispatch_async(dispatch_get_main_queue(), ^{
        callbackQueued=false;
        std::lock_guard<std::mutex> lock(mutex);
        processSpacesDisplayChangedLocked();
    });
}
// Diagnostics read only public AX properties and managed Space metadata.
// They never inspect window titles/content or open Mission Control.
id diagnosticAttribute(AXUIElementRef element,CFStringRef name,AXError *status) {
    CFTypeRef value=nullptr;
    AXError result=AXUIElementCopyAttributeValue(element,name,&value);
    if(status)*status=result;
    if(result!=kAXErrorSuccess) { if(value)CFRelease(value);return nil; }
    return CFBridgingRelease(value);
}
NSString *diagnosticString(id raw) {
    if(![raw isKindOfClass:NSString.class])return nil;
    NSString *value=(NSString *)raw;
    return value.length>128 ? [value substringToIndex:128] : value;
}
void diagnosticControlMetadata(AXUIElementRef element,NSMutableDictionary *node,CFAbsoluteTime deadline) {
    if(CFAbsoluteTimeGetCurrent()>deadline) { node[@"metadata_truncated"]=@YES;return; }
    CFArrayRef rawActions=nullptr;
    AXError actionError=AXUIElementCopyActionNames(element,&rawActions);
    if(actionError==kAXErrorSuccess) {
        NSArray *names=CFBridgingRelease(rawActions);
        NSMutableArray *actions=[NSMutableArray array];
        for(id raw in names) {
            if(actions.count>=16)break;
            NSString *name=diagnosticString(raw);
            if(name)[actions addObject:name];
        }
        node[@"actions"]=actions;
        if(names.count>16)node[@"actions_truncated"]=@YES;
    } else {
        if(rawActions)CFRelease(rawActions);
        node[@"actions_error"]=@(actionError);
    }
    if(CFAbsoluteTimeGetCurrent()>deadline) { node[@"metadata_truncated"]=@YES;return; }
    AXError descriptionError=kAXErrorSuccess;
    NSString *description=diagnosticString(diagnosticAttribute(element,kAXDescriptionAttribute,&descriptionError));
    if(description)node[@"description"]=description.length>96 ? [description substringToIndex:96] : description;
    else if(descriptionError!=kAXErrorSuccess)node[@"description_error"]=@(descriptionError);
    if(CFAbsoluteTimeGetCurrent()>deadline) { node[@"metadata_truncated"]=@YES;return; }
    AXError enabledError=kAXErrorSuccess,selectedError=kAXErrorSuccess;
    NSNumber *enabled=number(diagnosticAttribute(element,kAXEnabledAttribute,&enabledError));
    if(CFAbsoluteTimeGetCurrent()>deadline) { node[@"metadata_truncated"]=@YES;return; }
    NSNumber *selected=number(diagnosticAttribute(element,kAXSelectedAttribute,&selectedError));
    if(enabled)node[@"enabled"]=enabled;
    else if(enabledError!=kAXErrorSuccess)node[@"enabled_error"]=@(enabledError);
    if(selected)node[@"selected"]=selected;
    else if(selectedError!=kAXErrorSuccess)node[@"selected_error"]=@(selectedError);
}
NSDictionary *diagnosticAXNode(AXUIElementRef element,int depth,int *budget,CFAbsoluteTime deadline,
    CGDirectDisplayID builtinID,NSArray *builtinSpaces,bool inBuiltinDisplay,
    bool desktopChild,bool mappingPossible,NSUInteger desktopIndex,bool *partial) {
    if(*budget<=0 || depth>6 || CFAbsoluteTimeGetCurrent()>deadline) { *partial=true;return nil; }
    --*budget;
    AXUIElementSetMessagingTimeout(element,0.5);
    NSMutableDictionary *node=[NSMutableDictionary dictionary];
    NSString *role=diagnosticString(diagnosticAttribute(element,kAXRoleAttribute,nullptr));
    NSString *identifier=diagnosticString(diagnosticAttribute(element,CFSTR("AXIdentifier"),nullptr));
    NSNumber *display=number(diagnosticAttribute(element,CFSTR("AXDisplayID"),nullptr));
    if(role)node[@"role"]=role;
    if(identifier)node[@"identifier"]=identifier;
    if(display)node[@"display_id"]=display;
    bool builtin=inBuiltinDisplay || (builtinID && display &&
        [identifier isEqual:@"mc.display"] && display.unsignedIntValue==builtinID);
    bool list=builtin && [identifier isEqual:@"mc.spaces.list"];
    bool container=[identifier isEqual:@"mc"] || (builtin &&
        ([identifier isEqual:@"mc.display"] || [identifier isEqual:@"mc.spaces"]
            || [identifier isEqual:@"mc.spaces.add"] || list));
    bool ordinaryDesktop=false;
    if(desktopChild && mappingPossible && [role isEqual:@"AXButton"] && desktopIndex<builtinSpaces.count) {
        NSDictionary *space=dictionary(builtinSpaces[desktopIndex]);
        NSNumber *sid=number(space[@"id64"]),*type=number(space[@"type"]);
        if(sid && type.intValue==0) {
            ordinaryDesktop=true;
            node[@"ax_child_index"]=@(desktopIndex); // zero-based, mapping is inferred
            node[@"inferred_space_id"]=sid;
            node[@"space_id_mapping_verified"]=@NO;
        }
    }
    if(container || ordinaryDesktop)diagnosticControlMetadata(element,node,deadline);
    // Mission Control also contains live app-window previews. Stop at desktop
    // thumbnails and inspect only the Spaces controls, never preview content.
    if(desktopChild || [identifier isEqual:@"mc.spaces.add"]
        || ([identifier isEqual:@"mc.display"] && !builtin)) {
        node[@"children"]=@[];
        return node;
    }
    AXError childrenError=kAXErrorSuccess;
    NSArray *children=array(diagnosticAttribute(element,kAXChildrenAttribute,&childrenError));
    NSMutableArray *brief=[NSMutableArray array];
    if(childrenError==kAXErrorSuccess && children) {
        bool countsMatch=list && children.count==builtinSpaces.count;
        if(list)node[@"managed_space_count"]=@(builtinSpaces.count);
        NSUInteger skipped=0;
        NSUInteger limit=MIN(children.count,(NSUInteger)128);
        if(limit<children.count) { node[@"children_truncated"]=@YES;*partial=true; }
        for(NSUInteger index=0;index<limit;index++) {
            id child=children[index];
            if(CFGetTypeID((__bridge CFTypeRef)child)!=AXUIElementGetTypeID())continue;
            NSString *childID=diagnosticString(diagnosticAttribute((__bridge AXUIElementRef)child,CFSTR("AXIdentifier"),nullptr));
            bool relevant=true;
            if([identifier isEqual:@"mc"])relevant=[childID isEqual:@"mc.display"];
            else if([identifier isEqual:@"mc.display"] && builtin)relevant=[childID isEqual:@"mc.spaces"];
            else if([identifier isEqual:@"mc.spaces"])
                relevant=[childID isEqual:@"mc.spaces.add"] || [childID isEqual:@"mc.spaces.list"];
            if(!relevant) { skipped++;continue; }
            NSDictionary *sub=diagnosticAXNode((__bridge AXUIElementRef)child,depth+1,budget,deadline,
                builtinID,builtinSpaces,builtin,list,countsMatch,index,partial);
            if(sub)[brief addObject:sub];
        }
        if(skipped)node[@"children_skipped"]=@(skipped);
    } else if(childrenError!=kAXErrorNoValue && childrenError!=kAXErrorAttributeUnsupported) {
        *partial=true;
        node[@"children_error"]=@(childrenError);
    }
    node[@"children"]=brief;
    return node;
}
NSUInteger diagnosticCountIdentifier(NSDictionary *node,NSString *identifier) {
    NSUInteger count=[node[@"identifier"] isEqual:identifier] ? 1 : 0;
    for(NSDictionary *child in array(node[@"children"]))count+=diagnosticCountIdentifier(child,identifier);
    return count;
}
NSArray *diagnosticDisplays(NSArray *inventory,bool *available) {
    *available=inventory!=nil;
    if(!inventory)return @[];
    CGDirectDisplayID ids[32]={};uint32_t count=0;
    bool online=CGGetOnlineDisplayList(32,ids,&count)==kCGErrorSuccess;
    NSMutableArray *result=[NSMutableArray array];
    for(NSDictionary *item in inventory) {
        if(result.count>=32)break;
        NSDictionary *display=dictionary(item);if(!display)continue;
        id rawUUID=display[@"Display Identifier"];
        NSString *uuid=diagnosticString(rawUUID);
        if(!uuid)uuid=diagnosticString(dictionary(rawUUID)[@"value"]);
        NSMutableDictionary *entry=[NSMutableDictionary dictionary];
        if(uuid)entry[@"uuid"]=uuid;
        uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        entry[@"current_space_id"]=@(current);
        NSMutableArray *spaces=[NSMutableArray array];
        for(NSDictionary *space in array(display[@"Spaces"])) {
            if(spaces.count>=64)break;
            NSNumber *sid=number(dictionary(space)[@"id64"]);
            NSNumber *kind=number(dictionary(space)[@"type"]);
            if(sid)[spaces addObject:kind ? @{ @"id":sid, @"type":kind } : @{ @"id":sid }];
        }
        entry[@"spaces"]=spaces;
        if(online && uuid)for(uint32_t i=0;i<count;i++) {
            if([displayUUID(ids[i]) isEqual:uuid]) {
                entry[@"cg_display_id"]=@(ids[i]);
                entry[@"builtin"]=@(CGDisplayIsBuiltin(ids[i])!=0);
                break;
            }
        }
        [result addObject:entry];
    }
    return result;
}
NSDictionary *diagnostics() {
    bool trusted=AXIsProcessTrusted(),screen=CGPreflightScreenCaptureAccess(),post=CGPreflightPostEventAccess();
    NSArray *inventory=managed();
    bool spacesAvailable=false;
    NSMutableDictionary *result=[@{ @"pid":@(getpid()), @"ax_trusted":@(trusted),
        @"screen_capture_allowed":@(screen), @"post_events_allowed":@(post),
        @"managed_displays":diagnosticDisplays(inventory,&spacesAvailable),
        @"managed_spaces_readable":@(spacesAvailable) } mutableCopy];
    const char *wholeBlocker=wholeModeBlocker();
    const char *windowBlocker=migrationBlocker();
    result[@"whole_space_available"]=@(wholeBlocker==nullptr);
    result[@"whole_space_blocker"]=wholeBlocker ? [NSString stringWithUTF8String:wholeBlocker] : @"";
    result[@"window_migration_available"]=@(windowBlocker==nullptr);
    result[@"window_migration_blocker"]=windowBlocker ? [NSString stringWithUTF8String:windowBlocker] : @"";
    if(NSBundle.mainBundle.bundleIdentifier)result[@"bundle_id"]=NSBundle.mainBundle.bundleIdentifier;
    CGDirectDisplayID online[32]={},builtinID=0;uint32_t onlineCount=0;
    if(CGGetOnlineDisplayList(32,online,&onlineCount)==kCGErrorSuccess)
        for(uint32_t i=0;i<onlineCount;i++)if(CGDisplayIsBuiltin(online[i])){builtinID=online[i];break;}
    if(builtinID)result[@"builtin_cg_display_id"]=@(builtinID);
    NSArray *builtinSpaces=array(builtInManaged(inventory)[@"Spaces"]);
    if(!trusted) { result[@"dock_status"]=@"ax_untrusted";return result; }
    AXUIElementRef dock=dockApplication();
    if(!dock) { result[@"dock_status"]=@"dock_not_running";return result; }
    AXUIElementSetMessagingTimeout(dock,0.75);
    AXError childrenError=kAXErrorSuccess;
    NSArray *children=array(diagnosticAttribute(dock,kAXChildrenAttribute,&childrenError));
    if(childrenError!=kAXErrorSuccess || !children || children.count==0) {
        result[@"dock_status"]=@"dock_tree_unavailable";
        result[@"dock_children_error"]=@(childrenError);
        CFRelease(dock);return result;
    }
    AXUIElementRef mc=nullptr;
    for(id child in children) {
        if(CFGetTypeID((__bridge CFTypeRef)child)!=AXUIElementGetTypeID())continue;
        NSString *identifier=diagnosticString(diagnosticAttribute((__bridge AXUIElementRef)child,CFSTR("AXIdentifier"),nullptr));
        if([identifier isEqual:@"mc"]) { mc=(AXUIElementRef)CFRetain((__bridge CFTypeRef)child);break; }
    }
    result[@"dock_child_count"]=@(children.count);
    if(!mc) {
        result[@"dock_status"]=@"mission_control_not_visible";
        CFRelease(dock);return result;
    }
    AXUIElementSetMessagingTimeout(mc,0.75);
    int budget=96;bool partial=false;
    NSDictionary *tree=diagnosticAXNode(mc,0,&budget,CFAbsoluteTimeGetCurrent()+8.0,
        builtinID,builtinSpaces,false,false,false,0,&partial);
    if(tree)result[@"mission_control_tree"]=tree;
    NSUInteger displayCount=tree ? diagnosticCountIdentifier(tree,@"mc.display") : 0;
    NSUInteger addCount=tree ? diagnosticCountIdentifier(tree,@"mc.spaces.add") : 0;
    NSUInteger listCount=tree ? diagnosticCountIdentifier(tree,@"mc.spaces.list") : 0;
    result[@"mc_display_count"]=@(displayCount);
    result[@"mc_add_count"]=@(addCount);
    result[@"mc_list_count"]=@(listCount);
    result[@"tree_truncated_or_error"]=@(partial);
    result[@"dock_status"]=displayCount && listCount && !partial
        ? @"mission_control_tree_present" : @"mission_control_tree_unavailable";
    CFRelease(mc);CFRelease(dock);
    return result;
}

#ifdef AIR_SPACES_EVIDENCE_RECOVERY
bool upgradeWholeJournalFromEvidence(NSDictionary *snapshot,NSDictionary *capturedRoot,std::string *why) {
    air::whole_space::Journal capturedJournal;
    if(wholeJournal.version!=2 || !snapshot || !capturedRoot
        || [number(capturedRoot[@"version"]) intValue]!=9
        || !air::whole_space::decode(dictionary(capturedRoot[@"wholeSpace"]),capturedJournal,why)
        || capturedJournal.version!=2) {
        if(why && why->empty())*why="loaded and captured schema-v2 whole-Space journals are required";
        return false;
    }
    NSArray *managed=array(snapshot[@"managed_displays"]);
    if(managed.count!=3) {
        if(why)*why="evidence must contain exactly three managed displays";
        return false;
    }
    std::map<uint64_t,int> capturedTypes;
    for(const auto &display:capturedJournal.original.displays) {
        NSDictionary *evidence=nil;
        for(id raw in managed) {
            NSDictionary *candidate=dictionary(raw);
            if([candidate[@"uuid"] isEqualToString:[NSString stringWithUTF8String:display.uuid.c_str()]]) {
                if(evidence) {
                    if(why)*why="evidence contains a duplicate display";
                    return false;
                }
                evidence=candidate;
            }
        }
        NSArray *spaces=array(evidence[@"spaces"]);
        NSNumber *currentID=number(evidence[@"current_id"]),*currentType=number(evidence[@"current_type"]);
        if(!evidence || !currentID || !currentType || currentID.unsignedLongLongValue!=display.current
            || currentType.intValue!=0 || spaces.count!=display.order.size()) {
            if(why)*why="evidence display, selection, or order does not match the journal";
            return false;
        }
        for(size_t index=0;index<display.order.size();index++) {
            NSDictionary *space=dictionary(spaces[index]);
            NSNumber *rawID=number(space[@"id"]),*rawType=number(space[@"type"]);
            uint64_t sid=rawID.unsignedLongLongValue;int kind=rawType.intValue;
            if(!rawID || !rawType || sid!=display.order[index] || (kind!=0 && kind!=4)
                || !capturedTypes.emplace(sid,kind).second) {
                if(why)*why="evidence Space identity, order, or type does not match the journal";
                return false;
            }
        }
    }
    return air::whole_space::upgradeLegacyFullscreenJournal(wholeJournal,capturedJournal.original,
        [&](uint64_t sid) {
            auto found=capturedTypes.find(sid);
            return found==capturedTypes.end() ? -1 : found->second;
        },why);
}
#endif
} // namespace
extern "C" const char *air_spaces_diagnostics() {
    static thread_local std::string json;
    @autoreleasepool {
        NSDictionary *report=diagnostics();
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
        json=data ? std::string((const char *)data.bytes,data.length) : "{\"dock_status\":\"serialization_error\"}";
    }
    return json.c_str();
}
extern "C" int air_spaces_enabled() {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->enabled)return recoveryHooks->enabled();
#endif
    Api &a=api();
    Class bridged=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    bool hasBridge=bridged && [bridged instancesRespondToSelector:@selector(initWithWindows:spaceID:)]
        && [bridged instancesRespondToSelector:@selector(performWithWMBridgeDelegate)];
    return AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
        && a.conn && a.managed && a.windowSpaces && a.spaceWindows && a.spaceType
        && (hasBridge || a.legacyMove || (a.compat && a.workspace)) && a.axWindow && a.dock;
}
extern "C" int air_spaces_supported_for_cross_app_migration() {
    return migrationBlocker()==nullptr;
}
extern "C" int air_spaces_recover() {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown)return error("Remote Spaces host is shutting down");
    if(retryDisplayInFlight)return error("Spaces display recovery is still in progress");
    if(active || !saved.empty() || !wholeJournal.original.displays.empty())
        return error("Spaces recovery is already active in this host");
    if(![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])return 0;
    if(!acquireJournalLock())return error(("Spaces recovery ownership unavailable: "+journalIOError).c_str());
    if(!air_spaces_enabled())return error("Spaces recovery requires Accessibility and SkyLight APIs");
    if(!loadJournal())return error("Spaces recovery journal is invalid; it was retained for manual inspection");
    int result=restoreWithSettlingRetryLocked();
    if(!result)return 0;
    std::vector<std::string> topology;bool builtinOnline=false;
    if(pendingDisplayRecovery && callbackRegistered && journalIOError.empty()
        && [[NSFileManager defaultManager] fileExistsAtPath:journalPath()]
        && onlineTopology(topology,builtinUUID,builtinOnline)
        && (!builtinOnline || !originalDisplaysOnline(topology))) {
        NSLog(@"RustDesk Air: Spaces recovery deferred until all original displays return; recovery journal retained");
        air_set_error("");
        return 0;
    }
    return result;
}
#ifdef AIR_SPACES_EVIDENCE_RECOVERY
extern "C" int air_spaces_upgrade_v2_from_evidence_and_restore(const char *snapshotPath,
                                                                const char *capturedJournalPath) {
    std::lock_guard<std::mutex> lock(mutex);
    if(!snapshotPath || !*snapshotPath || !capturedJournalPath || !*capturedJournalPath)
        return error("Captured topology and journal evidence paths are required");
    if(active || !saved.empty() || !wholeJournal.original.displays.empty())
        return error("Spaces recovery is already active in this process");
    if(![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])
        return error("The retained Spaces recovery journal is unavailable");
    if(!acquireJournalLock())return error(("Spaces recovery ownership unavailable: "+journalIOError).c_str());
    struct RecoveryOnlyUnlock { ~RecoveryOnlyUnlock(){releaseJournalLock();} } recoveryOnlyUnlock;
    if(!air_spaces_enabled())return error("Spaces recovery requires Accessibility and SkyLight APIs");
    if(!loadJournal())return error("Spaces recovery journal is invalid; it was retained unchanged");
    NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:snapshotPath]];
    NSDictionary *snapshot=data ? dictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
    NSData *capturedData=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:capturedJournalPath]];
    NSDictionary *capturedRoot=capturedData
        ? dictionary([NSJSONSerialization JSONObjectWithData:capturedData options:0 error:nil]) : nil;
    std::string reason;
    if(!upgradeWholeJournalFromEvidence(snapshot,capturedRoot,&reason))
        return error(("Captured topology evidence was rejected: "+reason).c_str());
    if(!persist())return error(("Could not persist the evidence-upgraded recovery journal: "+journalIOError).c_str());
    return restoreLocked();
}
#endif
NSArray *completeWindowInventory(NSArray *displays,int cid) {
    NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    if(!cg || !api().spaceWindows)return nil;
    NSMutableDictionary *byID=NSMutableDictionary.dictionary;
    for(NSDictionary *info in cg) {
        NSNumber *wid=number(info[(id)kCGWindowNumber]);
        if(wid.unsignedIntValue)byID[wid]=info;
    }
    for(NSDictionary *display in displays)for(NSDictionary *space in array(display[@"Spaces"])) {
        uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
        int kind=api().spaceType(cid,sid);
        if(!sid || (kind!=0 && kind!=4))continue;
        uint64_t setTags=0,clearTags=0;
        NSArray *ids=CFBridgingRelease(api().spaceWindows(cid,0,(__bridge CFArrayRef)@[@(sid)],
            0x7,&setTags,&clearTags));
        if(!ids || ids.count>10000)return nil;
        for(id raw in ids) {
            NSNumber *wid=number(raw);
            if(!wid || !wid.unsignedIntValue)return nil;
            if(byID[wid])continue;
            NSArray *details=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                wid.unsignedIntValue));
            for(NSDictionary *info in details)
                if([number(info[(id)kCGWindowNumber]) unsignedIntValue]==wid.unsignedIntValue) {
                    byID[wid]=info;break;
                }
            if(!byID[wid])return nil;
        }
    }
    if(byID.count>10000)return nil;
    return byID.allValues;
}
bool absentFromCompleteWindowInventory(NSArray *inventory,NSArray *members,uint32_t wid) {
    if(!inventory || !members || !wid || members.count)return false;
    for(NSDictionary *info in inventory)
        if([number(info[(id)kCGWindowNumber]) unsignedIntValue]==wid)return false;
    return true;
}
NSArray *stableWindowMembership(uint32_t wid,int cid) {
    if(!wid || !cid || !api().windowSpaces)return nil;
    NSArray *members=nil;
    for(int sample=0;sample<3;sample++) {
        members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        if(members)return members;
        if(sample<2)usleep(25000);
    }
    return nil;
}
bool departedSnapshotSample(NSArray *cg,NSArray *members,uint32_t wid) {
    if(!cg || !members || !wid || members.count)return false;
    for(NSDictionary *info in cg)
        if([number(info[(id)kCGWindowNumber]) unsignedIntValue]==wid)return false;
    return true;
}
// completeWindowInventory deliberately includes inactive Spaces. A surface can
// retire between that snapshot and the per-window membership read. It is safe
// to omit only when two fresh WindowServer samples agree that both the surface
// and every Space membership are gone.
bool departedWindowAfterSnapshot(uint32_t wid,int cid) {
    if(!wid || !cid || !api().windowSpaces)return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        NSArray *members=stableWindowMembership(wid,cid);
        if(!departedSnapshotSample(cg,members,wid))return false;
        NSArray *details=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionIncludingWindow,wid));
        for(NSDictionary *info in details)
            if([number(info[(id)kCGWindowNumber]) unsignedIntValue]==wid)return false;
        if(sample==0)usleep(50000);
    }
    return true;
}
// A window can disappear between a window snapshot and identity inspection.
// Omit its exact ID only when two complete inventories and SkyLight membership
// reads agree that the ID is gone.
bool vanishedCompleteInventoryWindow(uint32_t wid,int cid,const char **reason=nullptr) {
    if(reason)*reason="invalid_query";
    if(!wid || !cid || !api().windowSpaces)return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *inventory=completeWindowInventory(managed(),cid);
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,
            (__bridge CFArrayRef)@[@(wid)]));
        if(!inventory) {if(reason)*reason="inventory_unavailable";return false;}
        if(!members) {if(reason)*reason="membership_unreadable";return false;}
        if(members.count) {if(reason)*reason="still_in_space";return false;}
        if(!absentFromCompleteWindowInventory(inventory,members,wid)) {
            if(reason)*reason="still_in_inventory";
            return false;
        }
        if(sample==0)usleep(50000);
    }
    if(reason)*reason="gone";
    return true;
}
struct WholeFrameBlocker {
    uint32_t id=0;
    pid_t pid=0;
    ProcessBirth birth;
    uint64_t space=0;
    CGRect frame={};
    double alpha=-1;
    int onscreen=-1;
    const char *kind="";
};
WholeFrameBlocker frameBlocker(NSDictionary *info,uint32_t wid,pid_t pid,ProcessBirth birth,
                              uint64_t sid,CGRect frame,const char *kind) {
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
    return {wid,pid,birth,sid,frame,alpha ? alpha.doubleValue : -1,
        onscreen ? int(onscreen.boolValue) : -1,kind};
}
void logWholeFrameBlocker(const WholeFrameBlocker &b,unsigned attempt,const char *resolution) {
    // WID, PID and geometry are enough to identify a persistent compositor
    // surface without logging window titles or other user content.
    fprintf(stderr,"air_whole_frame_blocker kind=%s wid=%u pid=%d sid=%llu "
        "frame=%.0f,%.0f,%.0f,%.0f alpha=%.2f onscreen=%d attempt=%u resolution=%s\n",
        b.kind,b.id,b.pid,(unsigned long long)b.space,b.frame.origin.x,b.frame.origin.y,
        b.frame.size.width,b.frame.size.height,b.alpha,b.onscreen,attempt,resolution);
}
bool journalableReadOnlyChromeSurface(NSDictionary *info,uint32_t wid,pid_t pid,
                                     NSString *bundle,ProcessBirth birth,CGRect frame,
                                     const std::vector<uint64_t> &memberships,
                                     const std::string &sourceUUID,
                                     const air::whole_space::Topology &topology,int cid,
                                     const DormantAXInventory &ax,uint64_t *tags) {
    if(tags)*tags=0;
    uint64_t observedTags=0;
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
    NSString *title=info[(id)kCGWindowName];
    ReadOnlyChromeEvidence evidence;
    evidence.chrome=[bundle isEqualToString:@"com.google.Chrome"];
    evidence.stableProcess=birth.valid() && birth==processBirth(pid) && ax.birth==birth;
    evidence.completeAX=ax.readable && ax.complete;
    evidence.absentAX=!ax.windows.count(wid);
    evidence.blankTitle=![title isKindOfClass:NSString.class] || title.length==0;
    evidence.alphaOne=alpha && alpha.doubleValue==1;
    evidence.offscreen=!onscreen || !onscreen.boolValue;
    evidence.stableAll=stableAllCGSurface(info,wid,pid,frame);
    evidence.exactDisplay=windowOnDisplay(wid,cid,sourceUUID);
    bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    evidence.rootParent=parentKnown && parent==0;
    evidence.exactTags=exactWindowTags(cid,wid,&observedTags)
        && observedTags==0x1400c0202ULL;
    evidence.singleOrdinaryMembership=memberships.size()==1
        && api().spaceType(cid,memberships[0])==0;
    evidence.selectedOrdinaryAnchor=false;
    if(topology.displays.size()==3 && memberships.size()==1)
        for(const auto &display:topology.displays)
            if(sourceUUID==display.uuid && memberships[0]==display.current
                && std::find(display.order.begin(),display.order.end(),memberships[0])
                    !=display.order.end())evidence.selectedOrdinaryAnchor=true;
    if(!readOnlyChromeDecision(evidence))return false;
    if(tags)*tags=observedTags;
    return true;
}
bool captureWholeFullScreensOnce(const air::whole_space::Topology &topology,int cid,
                                 std::vector<WholeFullScreenSpace> &result,std::string &reason) {
    NSArray *inventory=managed();
    if(!inventory){reason="managed fullscreen inventory is unavailable";return false;}
    result.clear();
    for(const auto &display:topology.displays) {
        NSDictionary *managedDisplay=nil;
        for(NSDictionary *candidate in inventory)
            if([managedDisplayUUID(candidate) isEqualToString:
                [NSString stringWithUTF8String:display.uuid.c_str()]])managedDisplay=candidate;
        if(!managedDisplay){reason="fullscreen source display is unavailable";return false;}
        for(size_t index=0;index<display.order.size();index++) {
            uint64_t sid=display.order[index];int type=api().spaceType(cid,sid);
            if(type==0)continue;
            if(type!=4){reason="an unsupported Space type is present";return false;}
            NSDictionary *space=managedSpace(managedDisplay,sid);
            uint32_t owner=[number(space[@"fs_wid"]) unsignedIntValue];
            pid_t pid=[number(space[@"pid"]) intValue];
            NSString *uuid=managedSpaceUUID(space);
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            ProcessBirth birth=processBirth(pid);double launch=stableLaunchTime(app,pid);
            if(!owner || pid<=0 || !uuid.length || !birth.valid() || !app || app.terminated
                || !app.bundleIdentifier || launch<=0 || !(birth==processBirth(pid))) {
                reason="a fullscreen Space lacks a stable managed owner";return false;
            }
            WholeFullScreenSpace captured;
            captured.sid=sid;captured.uuid=uuid.UTF8String;captured.sourceDisplay=display.uuid;
            captured.sourceIndex=(uint32_t)index;captured.owner=owner;captured.pid=pid;
            captured.bundle=app.bundleIdentifier.UTF8String;
            captured.birthSeconds=birth.seconds;captured.birthMicroseconds=birth.microseconds;
            captured.launchTime=launch;
            result.push_back(std::move(captured));
        }
    }
    if(result.empty())return true;
    NSArray *windows=completeWindowInventory(inventory,cid);
    if(!windows){reason="complete fullscreen window inventory is unavailable";return false;}
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        if(!wid || pid<=0)continue;
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!members){reason="fullscreen surface membership is unreadable";return false;}
        WholeFullScreenSpace *target=nullptr;
        for(id raw in members) {
            uint64_t sid=[number(raw) unsignedLongLongValue];
            if(api().spaceType(cid,sid)!=4)continue;
            if(members.count!=1 || target){reason="fullscreen surface has ambiguous memberships";return false;}
            for(auto &candidate:result)if(candidate.sid==sid)target=&candidate;
            if(!target){reason="a fullscreen surface is outside the recorded topology";return false;}
        }
        if(!target)continue;
        CGRect frame={};
        if(pid!=target->pid || !(processBirth(pid)==ProcessBirth{target->birthSeconds,target->birthMicroseconds})
            || !windowOnDisplay(wid,cid,target->sourceDisplay)
            || !CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)
            || CGRectIsEmpty(frame)) {
            reason="a fullscreen surface has unstable ownership or bounds";return false;
        }
        target->surfaces.push_back({wid,frame});
        if(wid==target->owner)target->ownerFrame=frame;
    }
    for(auto &space:result) {
        if(space.surfaces.empty() || CGRectIsEmpty(space.ownerFrame)) {
            reason="a fullscreen Space owner is absent from the complete inventory";return false;
        }
        std::sort(space.surfaces.begin(),space.surfaces.end(),
            [](const WholeFullScreenSurface &a,const WholeFullScreenSurface &b){return a.wid<b.wid;});
        for(size_t i=1;i<space.surfaces.size();i++)if(space.surfaces[i-1].wid==space.surfaces[i].wid) {
            reason="a fullscreen Space contains duplicate surfaces";return false;
        }
    }
    return true;
}
bool sameWholeFullScreenLedger(const std::vector<WholeFullScreenSpace> &first,
                               const std::vector<WholeFullScreenSpace> &second,
                               std::string &reason) {
    if(first.size()!=second.size()){reason="fullscreen inventory changed during capture";return false;}
    for(size_t i=0;i<first.size();i++) {
        const auto &a=first[i],&b=second[i];
        if(a.sid!=b.sid || a.uuid!=b.uuid || a.sourceDisplay!=b.sourceDisplay
            || a.sourceIndex!=b.sourceIndex || a.owner!=b.owner || a.pid!=b.pid
            || a.bundle!=b.bundle || a.birthSeconds!=b.birthSeconds
            || a.birthMicroseconds!=b.birthMicroseconds || fabs(a.launchTime-b.launchTime)>1
            || a.surfaces.size()!=b.surfaces.size()) {
            reason="fullscreen identity changed during capture";return false;
        }
        for(size_t j=0;j<a.surfaces.size();j++)
            if(a.surfaces[j].wid!=b.surfaces[j].wid
                || !nearFrame(a.surfaces[j].frame,b.surfaces[j].frame)) {
                reason="fullscreen surfaces changed during capture";return false;
            }
    }
    return true;
}
bool captureWholeFullScreens(const air::whole_space::Topology &topology,int cid,
                             std::vector<WholeFullScreenSpace> &result,std::string &reason) {
    std::vector<WholeFullScreenSpace> first,second;
    if(!captureWholeFullScreensOnce(topology,cid,first,reason))return false;
    usleep(50000);
    if(!captureWholeFullScreensOnce(topology,cid,second,reason)
        || !sameWholeFullScreenLedger(first,second,reason))return false;
    result=std::move(second);return true;
}
bool wholeFullScreenSurfaceInLedger(uint64_t sid,uint32_t wid,pid_t pid,
                                   const std::vector<WholeFullScreenSpace> &ledger) {
    for(const auto &space:ledger)if(space.sid==sid && space.pid==pid)
        for(const auto &surface:space.surfaces)if(surface.wid==wid)return true;
    return false;
}
bool stationaryBuiltinUnmappedDecision(bool selectedBuiltin,bool fitsBuiltin,
                                      bool offscreen,bool stableRoot,bool completeEmptyAX,
                                      bool stableProcess) {
    // The selected built-in Space never changes display. A hidden root surface
    // with no AX window cannot be moved or frame-restored, so it may remain
    // untouched while external Spaces are migrated.
    return selectedBuiltin && fitsBuiltin && offscreen && stableRoot
        && completeEmptyAX && stableProcess;
}
bool stationaryBuiltinTransparentDecision(bool selectedBuiltin,bool fitsBuiltin,
                                          bool offscreen,bool stableRoot,bool completeAX,
                                          bool absentAX,bool stableProcess) {
    return selectedBuiltin && fitsBuiltin && offscreen && stableRoot
        && completeAX && absentAX && stableProcess;
}
bool stableTransparentCGSurface(uint32_t wid,pid_t pid,CGRect frame,ProcessBirth birth) {
    if(!birth.valid())return false;
    for(int sample=0;sample<2;sample++) {
        NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!all)return false;
        unsigned matches=0;
        for(NSDictionary *candidate in all)
            if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
                matches++;CGRect current={};
                NSNumber *alpha=number(candidate[(id)kCGWindowAlpha]);
                if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=pid
                    || [number(candidate[(id)kCGWindowLayer]) intValue]!=0
                    || !alpha || alpha.doubleValue!=0
                    || !CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)dictionary(candidate[(id)kCGWindowBounds]),&current)
                    || !CGRectEqualToRect(current,frame))return false;
            }
        if(matches!=1 || !(birth==processBirth(pid)))return false;
        if(sample==0)usleep(25000);
    }
    return true;
}
bool stationaryBuiltinUnmappedSurface(NSDictionary *info,uint32_t wid,pid_t pid,
                                      NSRunningApplication *app,ProcessBirth birth,
                                      CGRect frame,uint64_t sid,int slot,
                                      const air::whole_space::Topology &topology,int cid,
                                      DormantAXCache &cache) {
    if(!info || !app || app.terminated || topology.displays.empty()
        || slot!=0 || sid!=topology.displays[0].current
        || ![app.bundleIdentifier isKindOfClass:NSString.class]
        || !app.bundleIdentifier.length)return false;
    CGRect content=builtInContentBounds();
    if(CGRectIsNull(content) || !CGRectContainsRect(content,frame))return false;
    NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
    NSString *title=info[(id)kCGWindowName];
    if(!alpha)return false;
    auto found=cache.find(pid);
    if(found==cache.end())found=cache.emplace(pid,readDormantAXInventory(pid)).first;
    bool parentKnown=false;uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    NSArray *visible=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    if(!visible)return false;
    bool onscreen=false;
    for(NSDictionary *candidate in visible)
        if([number(candidate[(id)kCGWindowNumber]) unsignedIntValue]==wid)
            {onscreen=true;break;}
    bool stableProcess=birth.valid() && found->second.birth==birth
        && birth==processBirth(pid);
    if(alpha.doubleValue==0)
        return stationaryBuiltinTransparentDecision(true,true,!onscreen,
            parentKnown && !parent && stableTransparentCGSurface(wid,pid,frame,birth),
            found->second.readable && found->second.complete,
            !found->second.windows.count(wid),stableProcess);
    return alpha.doubleValue==1 && [title isKindOfClass:NSString.class]
        && title.length && stationaryBuiltinUnmappedDecision(true,true,!onscreen,
            parentKnown && !parent && stableTitledCGSurface(info,wid,pid,frame),
            found->second.readable && found->second.complete
                && found->second.windows.empty(),stableProcess);
}
bool captureWholeFrameSnapshot(const air::whole_space::Topology &topology,int cid,
                               std::vector<SavedWindow> &result,std::string &reason,
                               WholeFrameBlocker *blocker=nullptr,
                               const std::vector<WholeFullScreenSpace> *fullScreens=nullptr) {
    if(blocker)*blocker={};
    NSArray *inventory=managed();
    NSArray *windows=completeWindowInventory(inventory,cid);
    if(!inventory || !windows) {reason="complete window inventory is unavailable";return false;}
    result.clear();DormantAXCache axCache;DetachedMenuStripScan menuStrips;
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        if(!wid || !pid || pid==getpid())continue;
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(systemChrome(app.bundleIdentifier)
            || verifiedCursorUIOverlay(info,wid,pid,axCache)
            || verifiedCUAOverlay(info,wid,pid,cid)
            || verifiedTextKitAgentSurface(info,wid,pid,cid)
            || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&menuStrips))continue;
        // Chrome's compositor windows change identity and Space without AX notice.
        // The user chose to exclude Chrome from exact per-window restoration.
        if([app.bundleIdentifier isEqualToString:@"com.google.Chrome"])continue;
        ProcessBirth birth=processBirth(pid);CGRect cgFrame={};
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!members || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&cgFrame)) {
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,0,cgFrame,"membership_or_bounds");
            reason="a desktop window has unreadable membership or bounds";return false;
        }
        if(!members.count && dormantInventoryOnlyWindow(info,wid,pid,app.bundleIdentifier,
                                                         birth,cid,axCache))continue;
        if(members.count>128) {
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,0,cgFrame,"too_many_memberships");
            reason="a desktop window has more Space memberships than the recovery journal supports";return false;
        }
        if(!members.count && vanishedCompleteInventoryWindow(wid,cid)) {
            fprintf(stderr,"air_whole_frame_vanished wid=%u pid=%d\n",wid,pid);
            continue;
        }
        bool stableBirth=birth==processBirth(pid);
        if(!members.count || !birth.valid() || !stableBirth) {
            fprintf(stderr,"air_whole_frame_identity wid=%u pid=%d members=%lu birth_valid=%d birth_stable=%d\n",
                    wid,pid,(unsigned long)members.count,birth.valid(),stableBirth);
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,0,cgFrame,"space_or_process_identity");
            reason="a desktop window has ambiguous Space or process identity";return false;
        }
        std::vector<uint64_t> memberships;
        for(id value in members) {
            NSNumber *raw=number(value);uint64_t member=raw.unsignedLongLongValue;
            bool inTopology=false;
            for(const auto &display:topology.displays)
                if(std::find(display.order.begin(),display.order.end(),member)!=display.order.end())inTopology=true;
            if(raw && member && inTopology && api().spaceType(cid,member)==4
                && members.count==1 && fullScreens
                && wholeFullScreenSurfaceInLedger(member,wid,pid,*fullScreens)) {
                memberships.clear();memberships.push_back(member);break;
            }
            if(!raw || !member || !inTopology || api().spaceType(cid,member)!=0) {
                if(blocker)*blocker=frameBlocker(info,wid,pid,birth,member,cgFrame,"outside_ordinary_topology");
                reason="a desktop window has a membership outside the recorded ordinary Spaces";return false;
            }
            memberships.push_back(member);
        }
        if(memberships.size()==1 && api().spaceType(cid,memberships[0])==4)continue;
        std::sort(memberships.begin(),memberships.end());
        if(std::adjacent_find(memberships.begin(),memberships.end())!=memberships.end()) {
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,0,cgFrame,"duplicate_membership");
            reason="a desktop window has duplicate Space memberships";return false;
        }
        NSString *ownerUUID=api().windowDisplay
            ? CFBridgingRelease(api().windowDisplay(cid,wid)) : nil;
        int slot=-1;uint64_t sid=0;CGRect sourceBounds={};std::string sourceUUID;
        for(size_t index=0;index<topology.displays.size();index++) {
            const auto &display=topology.displays[index];
            if(!ownerUUID || ![ownerUUID isEqualToString:
                [NSString stringWithUTF8String:display.uuid.c_str()]])continue;
            bool found=false;sourceBounds=boundsForDisplayUUID(display.uuid,&found);
            if(!found)break;
            for(uint64_t candidate:display.order)
                if(std::binary_search(memberships.begin(),memberships.end(),candidate)) {sid=candidate;break;}
            if(!sid)break;
            slot=(int)index;sourceUUID=display.uuid;break;
        }
        if(slot<0 || !windowOnDisplay(wid,cid,sourceUUID)) {
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,sid,cgFrame,"source_display_or_space");
            reason="a desktop window has no exact source display and Space";return false;
        }
        double launch=stableLaunchTime(app,pid);
        if(!app || app.terminated || !app.bundleIdentifier || launch<=0) {
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,sid,cgFrame,"application_identity");
            reason="a desktop window has no stable application identity";return false;
        }
        if(memberships.size()==1 && stationaryBuiltinUnmappedSurface(
            info,wid,pid,app,birth,cgFrame,sid,slot,topology,cid,axCache))continue;
        if(cgFrame.size.width<20 || cgFrame.size.height<20) {
            if(auxiliaryTinyWindow(info,wid,pid,app.bundleIdentifier,birth,
                                   cgFrame,sid,cid,axCache))continue;
            if(blocker)*blocker=frameBlocker(info,wid,pid,birth,sid,cgFrame,"tiny");
            reason="a desktop window is too small to frame restore safely";return false;
        }
        AXUIElementRef ax=findAXWindow(pid,wid);CGRect frame={};bool cgOnly=false,readOnlyCG=false,axDialog=false;
        uint32_t followerParent=0;CGPoint followerOffset={};
        uint64_t surfaceTags=0;
        if(ax) {
            Boolean position=false,size=false;
            id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
            bool hasFrame=readAXFrame(ax,&frame);
            bool positionKnown=AXUIElementIsAttributeSettable(ax,kAXPositionAttribute,&position)
                ==kAXErrorSuccess;
            bool sizeKnown=AXUIElementIsAttributeSettable(ax,kAXSizeAttribute,&size)
                ==kAXErrorSuccess;
            bool chromeUnknown=[app.bundleIdentifier isEqual:@"com.google.Chrome"]
                && [role isEqual:(__bridge NSString *)kAXWindowRole]
                && [subrole isEqual:@"AXUnknown"];
            bool verifiedDialog=[subrole isEqual:@"AXDialog"]
                && memberships.size()==1 && memberships[0]==sid
                && exactRootAXDialog(ax,wid,pid,cid,&frame);
            bool afterEffectsFloating=[app.bundleIdentifier isEqual:@"com.adobe.AfterEffects.application"]
                && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXFloatingWindow"];
            bool premiereLayoutDialog=[app.bundleIdentifier isEqual:@"com.adobe.PremierePro.26"]
                && [role isEqual:@"AXLayoutArea"] && [subrole isEqual:@"AXDialog"];
            bool stableUnknown=!(chromeUnknown || afterEffectsFloating || premiereLayoutDialog)
                || (premiereLayoutDialog ? stableTitledCGSurface(info,wid,pid,cgFrame)
                    : stableCGSurface(info,wid,pid,cgFrame));
            bool readable=hasFrame && positionKnown && sizeKnown && stableUnknown
                && journalableAXFrame(app.bundleIdentifier,role,subrole,frame,cgFrame,
                    position,size,builtInContentBounds(),stableUnknown,verifiedDialog);
            if(!readable && memberships.size()==1 && memberships[0]==sid
                && stableCGSurface(info,wid,pid,cgFrame)
                && inspectAttachedFollower(wid,pid,cid,ax,&followerParent,&followerOffset,&frame)) {
                readable=true;
            }
            axDialog=verifiedDialog;
            CFRelease(ax);
            if(!readable) {
                if(blocker)*blocker=frameBlocker(info,wid,pid,birth,sid,cgFrame,"ax_unsettable");
                reason="a desktop window's Accessibility frame is not settable";return false;
            }
        } else {
            if(ordinaryCompanionSurface(info,windows,wid,pid,app.bundleIdentifier,birth,cgFrame,
                                        sourceBounds,sid,sourceUUID,cid,axCache)) {
                continue;
            }
            NSString *title=info[(id)kCGWindowName];
            NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
            auto found=axCache.find(pid);
            if(found==axCache.end())found=axCache.emplace(pid,readDormantAXInventory(pid)).first;
            readOnlyCG=journalableReadOnlyChromeSurface(info,wid,pid,app.bundleIdentifier,
                birth,cgFrame,memberships,sourceUUID,topology,cid,found->second,&surfaceTags);
            if(readOnlyCG)frame=cgFrame;
            CGRect builtinContent=builtInContentBounds();
            bool finder=!readOnlyCG && memberships.size()==1
                && journalableFinderCGWindow(info,wid,pid,app.bundleIdentifier,birth,
                    cgFrame,sid,slot,sourceUUID,sourceBounds,builtinContent,launch,cid,
                    found->second,&surfaceTags);
            bool identified=finder || (!readOnlyCG && cgOnlyFrameRestorableBundle(app.bundleIdentifier)
                && api().moveWindow && found->second.birth==birth
                && found->second.readable && found->second.complete
                && !found->second.windows.count(wid) && [title isKindOfClass:NSString.class]
                && title.length>0 && alpha && alpha.doubleValue==1
                && ([app.bundleIdentifier isEqual:@"com.lujjjh.LinearMouse"]
                    ? (!CGRectIsNull(builtinContent)
                        && cgFrame.size.width<=builtinContent.size.width
                        && cgFrame.size.height<=builtinContent.size.height
                        && stableTitledLinearMouseSurface(info,wid,pid,cgFrame,cid))
                    : stableCGSurface(info,wid,pid,cgFrame)));
            for(uint32_t rootID:found->second.windows)if(identified && !readOnlyCG) {
                AXUIElementRef root=findAXWindow(pid,rootID);CGRect rootFrame={};
                bool contains=root && readAXFrame(root,&rootFrame)
                    && CGRectContainsRect(CGRectInset(rootFrame,-2,-2),cgFrame);
                if(root)CFRelease(root);
                if(contains)identified=false;
            }
            if(!identified && !readOnlyCG) {
                if(blocker)*blocker=frameBlocker(info,wid,pid,birth,sid,cgFrame,"unclassified");
                reason="a desktop window cannot be classified for frame restoration";return false;
            }
            if(!readOnlyCG){frame=cgFrame;cgOnly=true;}
        }
        NSString *title=info[(id)kCGWindowName];
        if(![title isKindOfClass:NSString.class])title=@"";
        SavedWindow entry={wid,pid,app.bundleIdentifier.UTF8String,title.UTF8String,frame,
            sourceBounds,launch,sid,slot,sourceUUID,!cgOnly && !readOnlyCG};
        entry.cgOnly=cgOnly;entry.birthSeconds=birth.seconds;
        entry.birthMicroseconds=birth.microseconds;
        entry.memberships=std::move(memberships);
        entry.readOnlyCG=readOnlyCG;entry.surfaceTags=surfaceTags;
        entry.axDialog=axDialog;
        entry.followerParent=followerParent;entry.followerOffset=followerOffset;
        for(const SavedWindow &prior:result)if(prior.id==wid && prior.pid==pid) {
            reason="the desktop window inventory contains a duplicate identity";return false;
        }
        result.push_back(std::move(entry));
    }
    std::sort(result.begin(),result.end(),[](const SavedWindow &a,const SavedWindow &b) {
        return a.pid==b.pid ? a.id<b.id : a.pid<b.pid;
    });
    for(const SavedWindow &w:result)if(w.followerParent) {
        auto parent=std::find_if(result.begin(),result.end(),[&](const SavedWindow &entry) {
            return entry.id==w.followerParent && entry.pid==w.pid;
        });
        if(parent==result.end() || parent->followerParent || !parent->frameFromAX
            || parent->cgOnly || parent->readOnlyCG || parent->axDialog
            || parent->space!=w.space || parent->slot!=w.slot
            || parent->sourceUUID!=w.sourceUUID || parent->memberships!=w.memberships
            || !nearFrame(parent->sourceDisplay,w.sourceDisplay)
            || fabs(parent->launchTime-w.launchTime)>1
            || parent->birthSeconds!=w.birthSeconds
            || parent->birthMicroseconds!=w.birthMicroseconds
            || !attachedFollowerGeometry(parent->frame,w.frame,w.followerOffset)) {
            reason="an attached window has no exact settable parent in the frame journal";
            return false;
        }
    }
    return true;
}
bool sameWholeFrameSnapshot(const std::vector<SavedWindow> &first,
                            const std::vector<SavedWindow> &second) {
    if(first.size()!=second.size())return false;
    for(size_t index=0;index<first.size();index++) {
        const SavedWindow &a=first[index],&b=second[index];
        if(a.id!=b.id || a.pid!=b.pid || a.bundle!=b.bundle || a.space!=b.space
            || a.memberships!=b.memberships || a.readOnlyCG!=b.readOnlyCG
            || a.surfaceTags!=b.surfaceTags
            || a.sourceUUID!=b.sourceUUID || a.birthSeconds!=b.birthSeconds
            || a.birthMicroseconds!=b.birthMicroseconds || a.cgOnly!=b.cgOnly
            || a.axDialog!=b.axDialog || a.followerParent!=b.followerParent
            || fabs(a.followerOffset.x-b.followerOffset.x)>2
            || fabs(a.followerOffset.y-b.followerOffset.y)>2
            || fabs(a.launchTime-b.launchTime)>1 || !nearFrame(a.frame,b.frame)
            || !nearFrame(a.sourceDisplay,b.sourceDisplay))return false;
    }
    return true;
}
using WholeFrameCapture=std::function<bool(std::vector<SavedWindow> &,std::string &,
                                           WholeFrameBlocker *)>;
using WholeFrameGone=std::function<bool(uint32_t)>;
using WholeFramePause=std::function<void(unsigned)>;
bool captureWholeFrameLedgerWithRetry(const WholeFrameCapture &capture,
                                     const WholeFrameGone &gone,
                                     const WholeFramePause &pause,
                                     std::vector<SavedWindow> &result,std::string &reason) {
    // A window can close or resize while CG, AX and SkyLight are inspected.
    // Retry the entire read-only inventory; never assume the failed surface
    // was auxiliary.  A rejected WID must be journaled later or proven gone
    // in two complete CG/SkyLight inventories before we can activate Spaces.
    std::vector<WholeFrameBlocker> rejected;
    for(unsigned attempt=1;attempt<=4;attempt++) {
        std::vector<SavedWindow> first,second;
        WholeFrameBlocker blocker;
        if(!capture(first,reason,&blocker)) {
            if(attempt==1 && blocker.id)logWholeFrameBlocker(blocker,attempt,"first_refusal");
            if(!blocker.id || !blocker.birth.valid() || attempt==4) {
                if(blocker.id)logWholeFrameBlocker(blocker,attempt,"persistent");
                return false;
            }
            rejected.push_back(blocker);pause(125);continue;
        }
        pause(50);
        if(!capture(second,reason,&blocker)) {
            if(attempt==1 && blocker.id)logWholeFrameBlocker(blocker,attempt,"first_refusal");
            if(!blocker.id || !blocker.birth.valid() || attempt==4) {
                if(blocker.id)logWholeFrameBlocker(blocker,attempt,"persistent");
                return false;
            }
            rejected.push_back(blocker);pause(125);continue;
        }
        if(!sameWholeFrameSnapshot(first,second)) {
            reason="the desktop window inventory changed during capture";
            if(attempt==4)return false;
            pause(125);continue;
        }
        for(const WholeFrameBlocker &earlier:rejected) {
            bool journaled=false;
            for(const SavedWindow &w:second)
                if(w.id==earlier.id && w.pid==earlier.pid
                    && w.birthSeconds==earlier.birth.seconds
                    && w.birthMicroseconds==earlier.birth.microseconds) {
                    journaled=true;break;
                }
            if(!journaled && !gone(earlier.id)) {
                logWholeFrameBlocker(earlier,attempt,"still_present_outside_journal");
                reason="a previously ambiguous desktop window remains outside the frame journal";
                return false;
            }
        }
        result=std::move(second);reason.clear();return true;
    }
    return false;
}
bool captureWholeFrameLedger(const air::whole_space::Topology &topology,int cid,
                             std::vector<SavedWindow> &result,std::string &reason,
                             const std::vector<WholeFullScreenSpace> *fullScreens=nullptr) {
    return captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &sample,std::string &why,WholeFrameBlocker *blocker) {
            return captureWholeFrameSnapshot(topology,cid,sample,why,blocker,fullScreens);
        },
        [&](uint32_t wid) { return vanishedCompleteInventoryWindow(wid,cid); },
        [](unsigned milliseconds) { usleep(milliseconds*1000); },result,reason);
}
bool captureSelectedFullScreenInventory(int cid,NSArray **managedOut,NSArray **windowsOut,
                                        NSUInteger *selectedCount,std::string &signature,
                                        std::string &diagnostic) {
    signature.clear();diagnostic.clear();
    NSArray *displayInventory=managed();
    if(!displayInventory) {
        diagnostic=selectedFullScreenDiagnostic(0,0,"managed_space_inventory");
        return false;
    }
    std::map<uint64_t,std::string> selectedDisplays;
    std::set<std::string> facts;
    for(NSDictionary *display in displayInventory) {
        NSString *uuid=managedDisplayUUID(display);
        uint64_t sid=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(!uuid.length || !sid) {
            diagnostic=selectedFullScreenDiagnostic(0,0,"selected_display_identity");
            return false;
        }
        int kind=api().spaceType(cid,sid);
        if(kind!=0 && kind!=4) {
            diagnostic=selectedFullScreenDiagnostic(0,0,"selected_space_type");
            return false;
        }
        if(kind==4 && !selectedDisplays.emplace(sid,uuid.UTF8String).second) {
            diagnostic=selectedFullScreenDiagnostic(0,0,"unique_selected_space");
            return false;
        }
        facts.insert("display:"+std::string(uuid.UTF8String)+":"+std::to_string(sid)+":"+std::to_string(kind));
    }
    if(selectedCount)*selectedCount=selectedDisplays.size();
    NSArray *windows=completeWindowInventory(displayInventory,cid);
    if(!windows) {
        diagnostic=selectedFullScreenDiagnostic(0,0,"complete_cg_space_inventory");
        return false;
    }
    std::map<uint64_t,SelectedFullScreenOwner> owners;
    std::map<uint64_t,std::pair<uint32_t,pid_t>> selectedCandidates;
    DormantAXCache cursorAX;DetachedMenuStripScan firstMenuStrips;
    for(const auto &entry:selectedDisplays)owners[entry.first]={};
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        if(!wid || !pid || pid==getpid())continue;
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(systemChrome(app.bundleIdentifier)
            || verifiedCursorUIOverlay(info,wid,pid,cursorAX)
            || verifiedCUAOverlay(info,wid,pid,cid)
            || verifiedTextKitAgentSurface(info,wid,pid,cid)
            || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&firstMenuStrips))continue;
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!members) {
            if(vanishedCompleteInventoryWindow(wid,cid))continue;
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"space_membership_readable");
            return false;
        }
        if(members.count!=1)continue;
        uint64_t sid=[number(members[0]) unsignedLongLongValue];
        auto selected=owners.find(sid);if(selected==owners.end())continue;
        selectedCandidates.emplace(sid,std::make_pair(wid,pid));
        CGRect cgFrame={};
        if(!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&cgFrame)) {
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"cg_bounds");
            return false;
        }
        AXUIElementRef ax=findAXWindow(pid,wid);if(!ax)continue;
        id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
        id state=axAttribute(ax,CFSTR("AXFullScreen"));Boolean settable=false;CGRect axFrame={};
        bool standard=[role isEqual:(__bridge NSString *)kAXWindowRole]
            && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
            && state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
            && CFBooleanGetValue((__bridge CFBooleanRef)state)
            && AXUIElementIsAttributeSettable(ax,CFSTR("AXFullScreen"),&settable)==kAXErrorSuccess
            && settable && readAXFrame(ax,&axFrame) && nearFrame(axFrame,cgFrame);
        CFRelease(ax);if(!standard)continue;
        ProcessBirth birth=processBirth(pid);
        bool stable=app && !app.terminated && app.bundleIdentifier && birth.valid()
            && birth==processBirth(pid) && stableLaunchTime(app,pid)>0;
        if(!stable) {
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"process_identity");
            return false;
        }
        if(selected->second.id) {
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"unique_standard_owner");
            return false;
        }
        selected->second={wid,pid,app.bundleIdentifier,birth,cgFrame};
    }
    for(const auto &selected:owners)if(!selected.second.id) {
        auto candidate=selectedCandidates.find(selected.first);
        diagnostic=candidate==selectedCandidates.end()
            ? selectedFullScreenDiagnostic(0,0,"unique_standard_owner")
            : selectedFullScreenDiagnostic(candidate->second.first,candidate->second.second,
                "unique_standard_owner");
        return false;
    }
    DormantAXCache axCache;DetachedMenuStripScan secondMenuStrips;
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        if(!wid || !pid || pid==getpid())continue;
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(systemChrome(app.bundleIdentifier)
            || verifiedCursorUIOverlay(info,wid,pid,cursorAX)
            || verifiedCUAOverlay(info,wid,pid,cid)
            || verifiedTextKitAgentSurface(info,wid,pid,cid)
            || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&secondMenuStrips))continue;
        NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
        if(!members) {
            if(vanishedCompleteInventoryWindow(wid,cid))continue;
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"space_membership_readable");
            return false;
        }
        CGRect frame={};
        if(!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame)) {
            if(vanishedCompleteInventoryWindow(wid,cid))continue;
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"cg_bounds");
            return false;
        }
        ProcessBirth birth=processBirth(pid);
        std::string membership;
        for(id raw in members) {
            NSNumber *sid=number(raw);
            if(!sid) {
                diagnostic=selectedFullScreenDiagnostic(wid,pid,"space_membership_identity");
                return false;
            }
            membership+=":"+std::to_string(sid.unsignedLongLongValue)
                +":"+std::to_string(api().spaceType(cid,sid.unsignedLongLongValue));
        }
        char identity[512];
        snprintf(identity,sizeof(identity),"window:%u:%d:%llu:%llu:%.3f:%.3f:%.3f:%.3f%s",
            wid,pid,birth.seconds,birth.microseconds,frame.origin.x,frame.origin.y,
            frame.size.width,frame.size.height,membership.c_str());
        auto selected=members.count==1
            ? owners.find([number(members[0]) unsignedLongLongValue]) : owners.end();
        if(selected==owners.end()) { facts.insert(identity);continue; }
        if(!app || app.terminated || !app.bundleIdentifier || !birth.valid()
            || !(birth==processBirth(pid)) || stableLaunchTime(app,pid)<=0) {
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"process_identity");
            return false;
        }
        const std::string &sourceUUID=selectedDisplays[selected->first];
        if(!spaceOnDisplay(displayInventory,selected->first,sourceUUID)
            || !windowOnDisplay(wid,cid,sourceUUID)) {
            diagnostic=selectedFullScreenDiagnostic(wid,pid,"display_membership");
            return false;
        }
        std::string classification;
        if(wid==selected->second.id && pid==selected->second.pid)classification=":owner";
        else {
            std::string predicate;
            if(!selectedFullScreenCompanion(info,wid,pid,app.bundleIdentifier,birth,frame,
                selected->first,sourceUUID,selected->second,cid,axCache,&predicate)) {
                if(vanishedCompleteInventoryWindow(wid,cid))continue;
                diagnostic=selectedFullScreenDiagnostic(wid,pid,predicate.c_str());
                return false;
            }
            classification=":companion";
        }
        facts.insert(std::string(identity)+classification);
    }
    for(const std::string &fact:facts) { signature+=fact;signature.push_back('\n'); }
    if(managedOut)*managedOut=displayInventory;
    if(windowsOut)*windowsOut=windows;
    return true;
}
namespace {
enum class RuntimeLaunchState { Gone, Source, Destination, OtherRemote, Conflict };
RuntimeLaunchState runtimeLaunchState(const RuntimeLaunchWindow &w,int cid) {
    if(!w.id || w.pid<=0 || w.bundle.empty() || !w.sourceSpace || !w.destination
        || !api().windowSpaces)return RuntimeLaunchState::Conflict;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.pid];
    if(!app || app.terminated)return RuntimeLaunchState::Gone;
    ProcessBirth birth=processBirth(w.pid);
    if(!birth.valid())return RuntimeLaunchState::Conflict;
    if(birth.seconds!=w.birthSeconds || birth.microseconds!=w.birthMicroseconds)
        return RuntimeLaunchState::Gone;
    if(![app.bundleIdentifier isEqualToString:[NSString stringWithUTF8String:w.bundle.c_str()]]
        || fabs(stableLaunchTime(app,w.pid)-w.launchTime)>1)return RuntimeLaunchState::Conflict;
    NSDictionary *cg=windowLayerDescription(w.id);
    if(!cg)return oneWindowSpace(w.id,cid)==0
        ? RuntimeLaunchState::Gone : RuntimeLaunchState::Conflict;
    if([number(cg[(id)kCGWindowOwnerPID]) intValue]!=w.pid
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0)return RuntimeLaunchState::Gone;
    uint64_t sid=oneWindowSpace(w.id,cid);
    bool otherRemote=sid!=w.sourceSpace && sid!=w.destination
        && std::find(std::begin(wholeJournal.selected),std::end(wholeJournal.selected),sid)
            !=std::end(wholeJournal.selected);
    if(sid!=w.sourceSpace && sid!=w.destination && !otherRemote)
        return RuntimeLaunchState::Conflict;
    NSArray *inventory=managed();
    bool inKnownDisplay=(spaceOnDisplay(inventory,sid,w.sourceDisplay)
        && windowOnDisplay(w.id,cid,w.sourceDisplay))
        || (spaceOnDisplay(inventory,sid,builtinUUID)
            && windowOnDisplay(w.id,cid,builtinUUID));
    bool valid=inKnownDisplay && exactSingletonMembership(cid,w.id,sid);
    return valid ? (sid==w.sourceSpace ? RuntimeLaunchState::Source
        : sid==w.destination ? RuntimeLaunchState::Destination
        : RuntimeLaunchState::OtherRemote) : RuntimeLaunchState::Conflict;
}
SavedWindow runtimeLaunchAXWindow(const RuntimeLaunchWindow &w) {
    bool found=false;CGRect bounds=boundsForDisplayUUID(w.sourceDisplay,&found);
    SavedWindow ax={w.id,w.pid,w.bundle,"",w.originalFrame,bounds,w.launchTime,
        w.sourceSpace,w.slot,w.sourceDisplay,true};
    ax.birthSeconds=w.birthSeconds;ax.birthMicroseconds=w.birthMicroseconds;
    ax.memberships={w.sourceSpace};return ax;
}
bool settleRuntimeLaunchesBeforeReverse(int cid,std::string &reason) {
    for(const RuntimeLaunchWindow &w:runtimeLaunchWindows) {
        RuntimeLaunchState state=runtimeLaunchState(w,cid);
        if(state==RuntimeLaunchState::Gone)continue;
        if(state==RuntimeLaunchState::Conflict) {
            reason="window "+std::to_string(w.id)+" changed identity or Space";return false;
        }
        bool parking=w.sourceSpace==wholeJournal.parking[w.slot-1];
        uint64_t destination=parking ? w.destination : w.sourceSpace;
        uint64_t current=oneWindowSpace(w.id,cid);
        if(current!=destination && (!move(w.id,destination,cid)
            || oneWindowSpace(w.id,cid)!=destination)) {
            reason="window "+std::to_string(w.id)+" could not reach its restore Space";return false;
        }
    }
    return true;
}
bool restoreRuntimeLaunchFramesAfterReverse(int cid,std::string &reason) {
    for(const RuntimeLaunchWindow &w:runtimeLaunchWindows) {
        RuntimeLaunchState state=runtimeLaunchState(w,cid);
        if(state==RuntimeLaunchState::Gone)continue;
        bool parking=w.sourceSpace==wholeJournal.parking[w.slot-1];
        uint64_t expected=parking ? w.destination : w.sourceSpace;
        if(state==RuntimeLaunchState::Conflict || oneWindowSpace(w.id,cid)!=expected
            || !windowOnDisplay(w.id,cid,w.sourceDisplay)) {
            reason="window "+std::to_string(w.id)+" is not on its original monitor";return false;
        }
        SavedWindow ax=runtimeLaunchAXWindow(w);CGRect frame={};
        AXUIElementRef element=findAXWindow(w.pid,w.id);
        bool readable=element && readAXFrame(element,&frame);
        if(element)CFRelease(element);
        if(!readable || (!nearFrame(frame,w.originalFrame)
            && !setFrame(ax,w.originalFrame))) {
            reason="window "+std::to_string(w.id)+" could not regain its launch frame";return false;
        }
    }
    return true;
}
bool runtimeLaunchCandidate(NSDictionary *cg,int cid,RuntimeLaunchWindow &out) {
    uint32_t wid=[number(cg[(id)kCGWindowNumber]) unsignedIntValue];
    pid_t pid=[number(cg[(id)kCGWindowOwnerPID]) intValue];
    if(!wid || pid<=0 || pid==getpid() || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
        || std::any_of(saved.begin(),saved.end(),[&](const SavedWindow &w){
            return w.id==wid && w.pid==pid
                && processBirth(pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds};
        })
        || std::any_of(runtimeLaunchWindows.begin(),runtimeLaunchWindows.end(),
            [&](const RuntimeLaunchWindow &w){return w.id==wid;}))return false;
    for(const WholeFullScreenSpace &space:wholeFullScreens) {
        if(space.owner==wid)return false;
        for(const WholeFullScreenSurface &surface:space.surfaces)if(surface.wid==wid)return false;
    }
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *bundle=app.bundleIdentifier;ProcessBirth birth=processBirth(pid);
    if(!app || app.terminated || !bundle.length || !birth.valid()
        || systemChrome(bundle) || [bundle isEqualToString:@"com.google.Chrome"])return false;
    uint64_t sid=oneWindowSpace(wid,cid);int slot=0;std::string display;
    const auto &original=wholeJournal.original.displays;
    for(const auto &d:original)if(d.uuid!=builtinUUID) {
        int index=++slot;
        bool originalSpace=std::find(d.order.begin(),d.order.end(),sid)!=d.order.end();
        bool external=(originalSpace || sid==wholeJournal.parking[index-1])
            && spaceOnDisplay(managed(),sid,d.uuid) && windowOnDisplay(wid,cid,d.uuid);
        bool movedSelected=sid==wholeJournal.selected[index]
            && spaceOnDisplay(managed(),sid,builtinUUID)
            && windowOnDisplay(wid,cid,builtinUUID);
        if(external || movedSelected) {
            display=d.uuid;break;
        }
    }
    if(display.empty() || slot<1 || slot>2)return false;
    CGRect cgFrame={},axFrame={};bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    AXUIElementRef ax=findAXWindow(pid,wid);
    bool valid=ax && [axAttribute(ax,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]
        && [axAttribute(ax,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && readAXFrame(ax,&axFrame) && readCGFrame(wid,pid,&cgFrame)
        && nearFrame(axFrame,cgFrame) && parentKnown && parent==0
        && CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)dictionary(cg[(id)kCGWindowBounds]),&cgFrame)
        && stableCGSurface(cg,wid,pid,cgFrame)
        && exactSingletonMembership(cid,wid,sid);
    if(ax)CFRelease(ax);
    double launch=stableLaunchTime(app,pid);
    if(!valid || launch<=0 || (sid==wholeJournal.selected[slot]
        && CGRectContainsRect(CGRectInset(builtInContentBounds(),-2,-2),axFrame)))return false;
    out={wid,pid,bundle.UTF8String,display,launch,birth.seconds,birth.microseconds,
        sid,wholeJournal.selected[slot],slot,0,axFrame};
    return runtimeLaunchState(out,cid)==RuntimeLaunchState::Source;
}
bool advanceRuntimeLaunch(RuntimeLaunchWindow &w,int cid) {
    RuntimeLaunchState state=runtimeLaunchState(w,cid);
    if(state==RuntimeLaunchState::Gone)return true;
    if(state==RuntimeLaunchState::Conflict)return false;
    if(state==RuntimeLaunchState::Source) {
        if(w.sourceSpace!=w.destination
            && (!move(w.id,w.destination,cid) || oneWindowSpace(w.id,cid)!=w.destination))return false;
        w.stage=1;if(!persist())return false;
    }
    SavedWindow ax=runtimeLaunchAXWindow(w);
    CGRect content=builtInContentBounds();
    CGRect target=CGRectIsNull(content) ? CGRectNull : mappedFrame(ax,content);
    // AX can accept a size request before the app has repainted its actual
    // surface. Do not certify a launched window whose CG frame still differs.
    if(CGRectIsNull(target) || !CGRectContainsRect(content,target)
        || !setFrame(ax,target) || oneWindowSpace(w.id,cid)!=w.destination
        || !windowOnDisplay(w.id,cid,builtinUUID))return false;
    bool verified=false;
    for(int retry=0;retry<40 && !verified;retry++) {
        CGRect actualAX={},actualCG={};
        AXUIElementRef element=findAXWindow(w.pid,w.id);
        verified=element && readAXFrame(element,&actualAX)
            && readCGFrame(w.id,w.pid,&actualCG)
            && nearFrame(actualAX,target) && nearFrame(actualCG,target)
            && nearFrame(actualAX,actualCG);
        if(element)CFRelease(element);
        if(!verified)usleep(50000);
    }
    if(!verified)return false;
    w.stage=2;return persist();
}
void routeRuntimeLaunches(int cid) {
    static CFAbsoluteTime nextScan=0;
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(now<nextScan)return;
    nextScan=now+0.5;
    if(!active || wholeJournal.forwardDone!=4 || wholeJournal.reverseDone
        || wholeJournal.pending.active || wholeJournal.runtimeSelectionPending.active
        || wholeFullScreenRuntimeIndex>=0 || missionState()!=MissionState::Absent)return;
    air::whole_space::Topology observed;
    if(!wholeTopology(managed(),wholeDisplayOrder(),observed)
        || !wholeRuntimeTopologyWithFullScreens(observed,cid)
        || !spaceOnDisplay(managed(),wholeJournal.selected[1],builtinUUID)
        || !spaceOnDisplay(managed(),wholeJournal.selected[2],builtinUUID))return;
    std::vector<RuntimeLaunchWindow> prior=runtimeLaunchWindows;
    runtimeLaunchWindows.erase(std::remove_if(runtimeLaunchWindows.begin(),runtimeLaunchWindows.end(),
        [&](const RuntimeLaunchWindow &w){return runtimeLaunchState(w,cid)==RuntimeLaunchState::Gone;}),
        runtimeLaunchWindows.end());
    if(runtimeLaunchWindows.size()!=prior.size() && !persist()) {
        runtimeLaunchWindows=std::move(prior);return;
    }
    for(RuntimeLaunchWindow &w:runtimeLaunchWindows)if(w.stage<2) {
        if(!advanceRuntimeLaunch(w,cid))return;
    }
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll,kCGNullWindowID));
    if(!windows || windows.count>10000)return;
    for(NSDictionary *cg in windows) {
        RuntimeLaunchWindow candidate;
        if(!runtimeLaunchCandidate(cg,cid,candidate))continue;
        runtimeLaunchWindows.push_back(candidate);
        if(!persist()) {runtimeLaunchWindows.pop_back();return;}
        if(!advanceRuntimeLaunch(runtimeLaunchWindows.back(),cid))return;
    }
}
bool reusedRouteCandidate(NSDictionary *cg,int cid,SavedWindow &out,
                          bool includeBaseline=false,bool includeBuiltin=false) {
    uint32_t wid=[number(cg[(id)kCGWindowNumber]) unsignedIntValue];
    pid_t pid=[number(cg[(id)kCGWindowOwnerPID]) intValue];
    if(!wid || pid<=0 || pid==getpid() || (!includeBaseline && reusedRouteBaseline.count(wid))
        || [number(cg[(id)kCGWindowLayer]) intValue]!=0
        || [number(cg[(id)kCGWindowAlpha]) doubleValue]!=1
        || std::any_of(saved.begin(),saved.end(),[&](const SavedWindow &w){return w.id==wid;}))return false;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *bundle=app.bundleIdentifier;
    ProcessBirth birth=processBirth(pid);
    if(!app || app.terminated || !bundle.length || !birth.valid()
        || systemChrome(bundle))return false;
    uint64_t source=oneWindowSpace(wid,cid);
    if(!source || api().spaceType(cid,source)!=0 || !exactSingletonMembership(cid,wid,source))return false;
    NSString *owner=api().windowDisplay ? CFBridgingRelease(api().windowDisplay(cid,wid)) : nil;
    if(!owner.length)return false;
    int sourceSlot=nativeSlotForDisplayUUID(owner.UTF8String);
    if(sourceSlot<0 || sourceSlot>2 || (!includeBuiltin && sourceSlot==0)
        || (includeBuiltin && sourceSlot==0
            && std::find(std::begin(slots),std::end(slots),source)!=std::end(slots))
        || !spaceOnDisplay(managed(),source,owner.UTF8String)
        || !windowOnDisplay(wid,cid,owner.UTF8String))return false;
    bool found=false;CGRect sourceBounds=boundsForDisplayUUID(owner.UTF8String,&found);
    if(!found)return false;
    CGRect cgFrame={},axFrame={};bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,wid,&parentKnown);
    AXUIElementRef ax=findAXWindow(pid,wid);
    if(ax && verifiedWindowSharingCompanion(wid,pid,cid,ax)) {
        CFRelease(ax);return false;
    }
    bool minimized=false;
    bool valid=ax && [axAttribute(ax,kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]
        && [axAttribute(ax,kAXSubroleAttribute) isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && readAXFrame(ax,&axFrame) && readCGFrame(wid,pid,&cgFrame)
        && readWindowMinimized(ax,&minimized)
        && nearFrame(axFrame,cgFrame) && axFrame.size.width>=20 && axFrame.size.height>=20
        && parentKnown && parent==0 && stableCGSurface(cg,wid,pid,cgFrame)
        && exactSingletonMembership(cid,wid,source);
    if(ax)CFRelease(ax);
    double launch=stableLaunchTime(app,pid);
    if(!valid || launch<=0 || !(birth==processBirth(pid)))return false;
    NSString *title=cg[(id)kCGWindowName];
    if(![title isKindOfClass:NSString.class])title=@"";
    out={wid,pid,bundle.UTF8String,title.UTF8String,axFrame,sourceBounds,launch,
        source,sourceSlot,owner.UTF8String,true};
    out.birthSeconds=birth.seconds;out.birthMicroseconds=birth.microseconds;
    out.memberships={source};
    out.minimizedKnown=true;out.minimized=minimized;
    return true;
}
void routeOneReusedWindow(int cid) {
    if(!active || reusedSlots.size()!=3 || !ownedSlotsStillOrdered(builtInManaged(managed()),cid)
        || missionState()!=MissionState::Absent)return;
    uint64_t target=builtInCurrentSpace();
    if(std::find(std::begin(slots),std::end(slots),target)==std::end(slots))return;
    if(reusedRoutePending.empty()) {
        NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!windows || windows.count>10000)return;
        for(NSDictionary *cg in windows) {
            SavedWindow candidate={};
            if(!reusedRouteCandidate(cg,cid,candidate))continue;
            candidate.slot=(int)(std::find(std::begin(slots),std::end(slots),target)-std::begin(slots));
            saved.push_back(candidate);
            if(!persist()){saved.pop_back();return;}
            reusedRoutePending.push_back({candidate.id,target});
            break;
        }
    }
    if(reusedRoutePending.empty())return;
    ReusedRoute pending=reusedRoutePending.front();
    auto found=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &w){return w.id==pending.id;});
    if(found==saved.end()) {reusedRoutePending.erase(reusedRoutePending.begin());return;}
    if(!sameProcess(*found)
        || !(processBirth(found->pid)==ProcessBirth{found->birthSeconds,found->birthMicroseconds})
        || windowState(*found)==WindowState::Gone) {
        reusedRoutePending.erase(reusedRoutePending.begin());return;
    }
    if(windowState(*found)!=WindowState::Ready) {
        if(++reusedRoutePending.front().attempts>=3)reusedRoutePending.erase(reusedRoutePending.begin());
        return;
    }
    uint64_t current=oneWindowSpace(pending.id,cid);
    if(current!=found->space && current!=pending.target) {
        reusedRoutePending.erase(reusedRoutePending.begin());return;
    }
    if(current==found->space && !move(pending.id,pending.target,cid)) {
        if(++reusedRoutePending.front().attempts>=3)reusedRoutePending.erase(reusedRoutePending.begin());
        return;
    }
    CGRect content=builtInContentBounds();
    CGRect frame=CGRectIsNull(content) ? CGRectNull : mappedFrame(*found,content);
    CGRect observed={};
    if(CGRectIsNull(frame) || (found->minimized && !setWindowMinimizedState(*found,false))
        || !setFrame(*found,frame) || !restoreWindowMinimized(*found)
        || oneWindowSpace(pending.id,cid)!=pending.target
        || !windowOnDisplay(pending.id,cid,builtinUUID)
        || !readCGFrame(pending.id,found->pid,&observed)
        || !nearFrame(frame,observed)) {
        restoreWindowMinimized(*found);
        if(++reusedRoutePending.front().attempts>=3)reusedRoutePending.erase(reusedRoutePending.begin());
        return;
    }
    reusedRoutePending.erase(reusedRoutePending.begin());
}
bool edgeWindowEligible(const SavedWindow &w,uint64_t sid,int cid,bool requireBuiltin=true) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->edgeWindowEligible)
        return recoveryHooks->edgeWindowEligible(w,sid);
#endif
    if(!w.id || !w.frameFromAX || w.fullScreen || w.cgOnly || w.readOnlyCG
        || w.axDialog || w.followerParent || w.memberships.size()!=1
        || w.memberships[0]!=w.space || !w.birthSeconds || w.birthMicroseconds>=1000000
        || !sameProcess(w) || !(processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds})
        || windowState(w)!=WindowState::Ready || oneWindowSpace(w.id,cid)!=sid
        || (requireBuiltin && !windowOnDisplay(w.id,cid,builtinUUID)))return false;
    AXUIElementRef ax=findAXWindow(w.pid,w.id);
    id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
    id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
    CGRect axFrame={},cgFrame={};bool parentKnown=false;
    uint32_t parent=exactWindowParent(cid,w.id,&parentKnown);
    NSDictionary *cg=windowLayerDescription(w.id);
    bool root=ax && [role isEqual:(__bridge NSString *)kAXWindowRole]
        && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
        && readAXFrame(ax,&axFrame) && readCGFrame(w.id,w.pid,&cgFrame)
        && nearFrame(axFrame,cgFrame) && parentKnown && parent==0 && cg
        && [number(cg[(id)kCGWindowLayer]) intValue]==0
        && [number(cg[(id)kCGWindowAlpha]) doubleValue]==1;
    if(ax)CFRelease(ax);
    if(!root)return false;
    DormantAXInventory axWindows=readDormantAXInventory(w.pid);
    NSArray *cgWindows=completeWindowInventory(managed(),cid);
    if(!axWindows.readable || !axWindows.complete || !axWindows.windows.count(w.id)
        || !cgWindows || !(axWindows.birth==processBirth(w.pid)))return false;
    for(NSDictionary *candidate in cgWindows) {
        if([number(candidate[(id)kCGWindowOwnerPID]) intValue]!=w.pid
            || [number(candidate[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t other=[number(candidate[(id)kCGWindowNumber]) unsignedIntValue];
        if(!other)return false;
        if(!axWindows.windows.count(other)) {
            // Electron can retain detached layer-zero backing surfaces with
            // no AX window and no managed-Space membership. They cannot move
            // with this root window and must not block its exact restoration.
            bool parentKnown=false;uint32_t parent=exactWindowParent(cid,other,&parentKnown);
            NSArray *first=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(other)]));
            usleep(25000);
            NSArray *second=CFBridgingRelease(api().windowSpaces(cid,0x7,
                (__bridge CFArrayRef)@[@(other)]));
            if(!parentKnown || parent || !first || first.count || !second || second.count)
                return false;
            continue;
        }
        if(other!=w.id) {
            bool known=false;
            uint32_t owner=exactWindowParent(cid,other,&known);
            if(!known || owner==w.id)return false;
        }
    }
    return oneWindowSpace(w.id,cid)==sid
        && (!requireBuiltin || windowOnDisplay(w.id,cid,builtinUUID))
        && processBirth(w.pid)==ProcessBirth{w.birthSeconds,w.birthMicroseconds};
}
bool edgeObservedFrame(const SavedWindow &w,CGRect *frame) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->edgeWindowFrame)
        return recoveryHooks->edgeWindowFrame(w,frame);
#endif
    AXUIElementRef ax=findAXWindow(w.pid,w.id);
    CGRect currentAX={},currentCG={};
    bool valid=ax && readAXFrame(ax,&currentAX)
        && readCGFrame(w.id,w.pid,&currentCG) && nearFrame(currentAX,currentCG);
    if(ax)CFRelease(ax);
    if(valid && frame)*frame=currentAX;
    return valid;
}
std::string edgeObservedDisplay(uint32_t wid,int cid) {
    std::string found;
    for(const auto &display:wholeJournal.original.displays)
        if(windowOnDisplay(wid,cid,display.uuid)) {
            if(!found.empty())return {};
            found=display.uuid;
        }
    return found;
}
CGRect edgeRehomeFrame(CGRect frame,CGRect content) {
    if(CGRectIsNull(content) || !std::isfinite(frame.origin.x)
        || !std::isfinite(frame.origin.y) || !std::isfinite(frame.size.width)
        || !std::isfinite(frame.size.height) || frame.size.width<=0
        || frame.size.height<=0 || frame.size.width>content.size.width
        || frame.size.height>content.size.height)return CGRectNull;
    return CGRectMake(std::clamp(frame.origin.x,(double)CGRectGetMinX(content),
            (double)(CGRectGetMaxX(content)-frame.size.width)),
        std::clamp(frame.origin.y,(double)CGRectGetMinY(content),
            (double)(CGRectGetMaxY(content)-frame.size.height)),
        frame.size.width,frame.size.height);
}
bool edgeWindowVisible(uint32_t wid) {
#ifdef AIR_SPACES_JOURNAL_TEST
    if(recoveryHooks && recoveryHooks->edgeWindowVisible)
        return recoveryHooks->edgeWindowVisible(wid);
#endif
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    for(NSDictionary *window in windows)
        if([number(window[(id)kCGWindowNumber]) unsignedIntValue]==wid)return true;
    return false;
}
bool reconcileEdgeTransfers(int cid,std::string &reason) {
    if(edgeTransfers.empty())return true;
    for(const EdgeTransfer &entry:edgeTransfers) {
        auto found=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &w){
            return w.id==entry.window && w.space==entry.original;
        });
        if(found==saved.end()) {reason="the recorded window identity is missing";return false;}
        ProcessBirth birth=processBirth(found->pid);
        if(birth.valid() && (birth.seconds!=found->birthSeconds
            || birth.microseconds!=found->birthMicroseconds))continue;
        if(!birth.valid() && kill(found->pid,0)<0 && errno==ESRCH)continue;
        uint64_t current=oneWindowSpace(entry.window,cid);
        if(!current || (current!=entry.original && current!=entry.from
            && current!=entry.target && current!=entry.releaseSpace)
            || !edgeWindowEligible(*found,current,cid,false)) {
            reason="window "+std::to_string(entry.window)+" changed identity or membership";
            return false;
        }
        uint64_t runtimeSource=wholeJournal.selected[found->slot];
        if(!runtimeSource || (current!=runtimeSource
            && !move(entry.window,runtimeSource,cid))) {
            reason="window "+std::to_string(entry.window)+" could not return to its runtime source Space";
            return false;
        }
        CGRect content=builtInContentBounds();
        CGRect runtime=edgeRehomeFrame(entry.releaseFrame,content);
        if(CGRectIsNull(runtime) || !setFrame(*found,runtime)
            || oneWindowSpace(entry.window,cid)!=runtimeSource
            || !windowOnDisplay(entry.window,cid,builtinUUID)) {
            reason="window "+std::to_string(entry.window)+" did not reach its runtime source Space";
            return false;
        }
    }
    std::vector<EdgeTransfer> prior=std::move(edgeTransfers);
    edgeTransfers.clear();
    if(!persist()) {
        edgeTransfers=std::move(prior);
        reason="the completed edge-transfer recovery could not be recorded";
        return false;
    }
    return true;
}
bool reconcileUnjournaledEdgeMoves(int cid,std::string &reason) {
    for(const SavedWindow &w:saved) {
        if(!w.frameFromAX || w.fullScreen || w.cgOnly || w.readOnlyCG
            || w.axDialog || w.followerParent || w.memberships.size()!=1)continue;
        WindowState state=windowState(w);
        if(state==WindowState::Gone)continue;
        uint64_t expected=wholeJournal.selected[w.slot];
        uint64_t current=oneWindowSpace(w.id,cid);
        // During a failed partial activation, a hidden window may never have
        // left its original nonselected Space. Whole restore handles it there.
        if(current==expected || current==w.space)continue;
        if(!current || !expected || state!=WindowState::Ready) {
            reason="window "+std::to_string(w.id)+" has unknown native-drag membership";
            return false;
        }
        std::string display=edgeObservedDisplay(w.id,cid);
        bool known=display==builtinUUID
            && (current==wholeJournal.selected[std::max(0,w.slot-1)]
                || current==wholeJournal.selected[std::min(2,w.slot+1)]);
        for(const auto &original:wholeJournal.original.displays)
            if(original.uuid==display && original.uuid!=builtinUUID
                && std::find(original.order.begin(),original.order.end(),current)
                    !=original.order.end())known=true;
        // An app can keep its window on the physical external display while
        // macOS moves its original Space to the built-in panel. In that case
        // the window lands on this session's exact parking Space. It is still
        // a known recovery endpoint for that same external display.
        if(w.slot>0 && w.slot<3 && display==wholeJournal.original.displays[w.slot].uuid
            && current==wholeJournal.parking[w.slot-1])known=true;
        CGRect observed={};
        if(!known || !edgeWindowEligible(w,current,cid,false)
            || !edgeObservedFrame(w,&observed)) {
            reason="window "+std::to_string(w.id)+" cannot be identified for native-drag recovery";
            return false;
        }
        CGRect runtime=edgeRehomeFrame(observed,builtInContentBounds());
        bool onExternalParking=w.slot>0 && w.slot<3
            && current==wholeJournal.parking[w.slot-1]
            && display==wholeJournal.original.displays[w.slot].uuid;
        // An app may leave its window on the physical display's parking
        // Space while its original Space is on the built-in panel. Move the
        // window to that panel before asking AppKit to fit its frame there.
        if(onExternalParking && !move(w.id,expected,cid)) {
            reason="window "+std::to_string(w.id)+" could not leave its external parking Space";
            return false;
        }
        if(CGRectIsNull(runtime) || !setFrame(w,runtime)
            || !windowOnDisplay(w.id,cid,builtinUUID)
            || (!onExternalParking && !move(w.id,expected,cid))
            || oneWindowSpace(w.id,cid)!=expected
            || !windowOnDisplay(w.id,cid,builtinUUID)) {
            reason="window "+std::to_string(w.id)+" did not return to its saved runtime Space";
            return false;
        }
    }
    return true;
}
} // namespace
int rollbackFailedFullScreenPrepare(size_t index,const SavedWindow &original,
                                    AXUIElementRef retained,bool mocked,int cid) {
    CGWindowID rollbackID=0;
    if(mocked)rollbackID=resolvedWindowID(original);
    else if(retained && api().axWindow(retained,&rollbackID)!=kAXErrorSuccess)rollbackID=0;
    saved[index]=original;
    if(rollbackID)saved[index].id=rollbackID;
    int before=mocked ? fullScreenState(saved[index]) : -1;
    if(retained) {
        id raw=axAttribute(retained,CFSTR("AXFullScreen"));
        if(raw && CFGetTypeID((__bridge CFTypeRef)raw)==CFBooleanGetTypeID())
            before=CFBooleanGetValue((__bridge CFBooleanRef)raw) ? 1 : 0;
    }
    if(before==0)saved[index].fullScreenPhase=4;
    if(!persist()) {
        if(before==0 && retained)setFullScreenElement(retained,true);
        if(retained)CFRelease(retained);
        return error(("A full-screen transition failed and its rollback stage could not be journaled: "+journalIOError).c_str());
    }
    bool rolledBack=before==1 || (before==0 && (mocked
        ? setFullScreen(saved[index],true) : retained && setFullScreenElement(retained,true)));
    if(retained) {
        CGWindowID latest=0;
        if(api().axWindow(retained,&latest)==kAXErrorSuccess && latest && latest!=saved[index].id) {
            saved[index].id=latest;
            if(!persist())rolledBack=false;
        }
        CFRelease(retained);
    }
    if(rolledBack && awaitFullScreenMembership(saved[index],cid)) {
        uint64_t sid=fullScreenSpaceID(saved[index],cid);
        DisplaySelection *display=selectionForDisplay(saved[index].sourceUUID);
        if(sid && display && currentSpaceForDisplay(managed(),saved[index].sourceUUID)==sid) {
            uint64_t oldHost=display->hostSpace;SelectionPending old=selectionPending;
            display->hostSpace=sid;selectionPending={};
            if(!persist()){display->hostSpace=oldHost;selectionPending=std::move(old);}
        }
    }
    int rollback=restoreLocked();
    (void)rollback;
    return error("A full-screen window could not be exited, verified, or journaled; Spaces recovery journal retained if rollback is incomplete");
}
extern "C" int air_spaces_prepare() {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown)return error("Remote Spaces host is shutting down");
    if(retryDisplayInFlight)return error("Spaces display recovery is still in progress");
    if(!saved.empty() || !wholeJournal.original.displays.empty() || !reusedSlots.empty() || !edgeTransfers.empty()
        || !runtimeLaunchWindows.empty() || active)
        return error("Spaces migration is already active");
    air::whole_space::Topology wholeCandidate;
    // Cross-display desktop swaps retain WindowServer display transforms and
    // can corrupt backing scale/menu surfaces. Create native built-in Spaces
    // and move windows instead. Keep whole-Space recovery for existing journals.
    const char *wholeBlocked="whole-Space display swaps are disabled";
    if(wholeBlocked)if(const char *blocked=migrationBlocker())
        return error((std::string("Remote Spaces unavailable: ")+blocked).c_str());
    bool alreadyOwned=journalLockFD>=0;
    if(!acquireJournalLock())return error(("Remote Spaces unavailable: "+journalIOError).c_str());
    struct UnlockWithoutJournal {
        bool alreadyOwned;
        ~UnlockWithoutJournal() {
            if(!alreadyOwned && ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])releaseJournalLock();
        }
    } unlockWithoutJournal{alreadyOwned};
    if([[NSFileManager defaultManager] fileExistsAtPath:journalPath()]) {
        if(!alreadyOwned)releaseJournalLock();
        return error("A previous Spaces recovery journal needs restoration first");
    }
    Api &a=api();int cid=a.conn();
    if(!wholeBlocked) {
        std::vector<WholeFullScreenSpace> fullScreens;
        std::string fullScreenReason;
        if(!captureWholeFullScreens(wholeCandidate,cid,fullScreens,fullScreenReason))
            return error(("Whole-Space fullscreen inventory unavailable: "+fullScreenReason).c_str());
        if(fullScreens.size()>6)
            return error("More than six fullscreen Spaces cannot be shown in the Remote Spaces chooser");
        std::vector<SavedWindow> frameLedger;std::string frameReason;
        if(!captureWholeFrameLedger(wholeCandidate,cid,frameLedger,frameReason,&fullScreens))
            return error(("Whole-Space frame inventory unavailable: "+frameReason).c_str());
        air::whole_space::Topology verified;
        if(wholeModeBlocker(&verified) || verified.displays.size()!=wholeCandidate.displays.size())
            return error("Whole-Space display and Space topology changed during frame capture");
        for(size_t index=0;index<verified.displays.size();index++) {
            const auto &a=verified.displays[index],&b=wholeCandidate.displays[index];
            if(a.uuid!=b.uuid || a.order!=b.order || a.spaceUUIDs!=b.spaceUUIDs
                || a.current!=b.current)
                return error("Whole-Space display and Space topology changed during frame capture");
        }
        if(!fullScreens.empty()) {
            std::vector<WholeFullScreenSpace> confirmed;
            std::string reason;
            if(!captureWholeFullScreens(verified,cid,confirmed,reason)
                || !sameWholeFullScreenLedger(fullScreens,confirmed,reason))
                return error(("Fullscreen identity changed during frame capture: "+reason).c_str());
        }
        air::whole_space::Topology anchored;
        if(!wholeFullScreenAnchorTopology(wholeCandidate,cid,anchored))
            return error("A selected fullscreen Space has no verified ordinary anchor");
        std::vector<WholeFullScreenSelection> selections;
        for(size_t displayIndex=0;displayIndex<wholeCandidate.displays.size();displayIndex++) {
            const auto &original=wholeCandidate.displays[displayIndex];
            if(original.current==anchored.displays[displayIndex].current)continue;
            auto found=std::find_if(fullScreens.begin(),fullScreens.end(),
                [&](const WholeFullScreenSpace &space){return space.sid==original.current
                    && space.sourceDisplay==original.uuid;});
            if(found==fullScreens.end())
                return error("A selected fullscreen Space lacks a recorded owner");
            selections.push_back({(uint32_t)(found-fullScreens.begin()),
                anchored.displays[displayIndex].current});
        }
        wholeFullScreens=std::move(fullScreens);wholeFullScreenMoves.clear();
        wholeFullScreenSelections=std::move(selections);
        for(size_t i=0;i<wholeFullScreens.size();i++)
            if(wholeFullScreens[i].sourceDisplay!=wholeCandidate.displays[0].uuid)
                wholeFullScreenMoves.push_back((uint32_t)i);
        std::sort(wholeFullScreenMoves.begin(),wholeFullScreenMoves.end(),
            [&](uint32_t left,uint32_t right) {
                const auto &a=wholeFullScreens[left],&b=wholeFullScreens[right];
                return a.sourceDisplay==b.sourceDisplay ? a.sourceIndex>b.sourceIndex
                    : a.sourceDisplay<b.sourceDisplay;
            });
        wholeFullScreenForwardDone=wholeFullScreenReverseDone=0;wholeFullScreenPending={};
        wholeFullScreenAnchorDone=wholeFullScreenSelectionDone=0;
        wholeFullScreenSelectionRestoreStarted=false;wholeFullScreenSelectionPending={};
        wholeFullScreenRuntimeIndex=-1;wholeFullScreenRuntimePending={};
        saved=std::move(frameLedger);wholeFrameInventoryComplete=true;
        createdSpaces.clear();ownedSpaces.clear();initialSelections.clear();
        pendingCreateBefore.clear();pendingCreate=false;selectionPending={};
        initialFullScreenIndex=-1;initialFullScreenSpace=0;finalSelectionPending=false;
        active=false;windowInventoryComplete=true;switchVerified=false;slots[0]=slots[1]=slots[2]=0;
        builtinUUID=wholeCandidate.displays[0].uuid;
        initialSpace=anchored.displays[0].current;lastSelectedSpace=initialSpace;
        std::string reason;
        if(!air::whole_space::begin(wholeJournal,anchored,builtinUUID,
            [&](uint64_t sid){return a.spaceType(cid,sid);},&reason)) {
            wholeJournal={};parkingEvacuation={};saved.clear();wholeFrameInventoryComplete=false;
            wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeFullScreenPending={};
            wholeFullScreenSelections.clear();wholeFullScreenSelectionPending={};
            builtinUUID.clear();initialSpace=0;lastSelectedSpace=0;
            return error((std::string("Whole-Space preparation failed: ")+reason).c_str());
        }
        if(!persist()) {
            wholeJournal={};parkingEvacuation={};saved.clear();wholeFrameInventoryComplete=false;
            wholeFullScreens.clear();wholeFullScreenMoves.clear();wholeFullScreenPending={};
            wholeFullScreenSelections.clear();wholeFullScreenSelectionPending={};
            builtinUUID.clear();initialSpace=0;lastSelectedSpace=0;
            return error(("Cannot write whole-Space recovery journal: "+journalIOError).c_str());
        }
        while(wholeFullScreenAnchorDone<wholeFullScreenSelections.size())
            if(!advanceWholeFullScreenSelection(false,cid,reason))
                return error(("Could not anchor selected fullscreen Space: "+reason
                    +"; recovery journal retained").c_str());
        return 0;
    }
    NSDictionary *builtin=builtInManaged(managed());if(!builtin)return error("Built-in display Spaces unavailable");
    uint64_t startingSpace=[number(dictionary(builtin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    int startingType=startingSpace ? a.spaceType(cid,startingSpace) : -1;
    if(startingType!=0 && startingType!=4)
        return error("Initial built-in Space is not a supported ordinary or single-window full-screen Space");
    initialSpace=startingType==0 ? startingSpace : 0;
    initialFullScreenSpace=startingType==4 ? startingSpace : 0;
    initialFullScreenIndex=-1;finalSelectionPending=false;
    std::vector<RemotePhysicalDisplay> displays;
    if(!remotePhysicalDisplays(displays))
        return error("Spaces migration requires one built-in and exactly two identifiable external displays");
    builtinUUID=displays[0].uuid;
    NSArray *managedBefore=managed();
    bool deferOrdinaryInventory=false,hasSelectedFullScreen=false;
    for(NSDictionary *display in managedBefore)for(NSDictionary *space in array(display[@"Spaces"])) {
        uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
        if(sid && a.spaceType(cid,sid)==4)deferOrdinaryInventory=true;
    }
    for(NSDictionary *display in managedBefore) {
        uint64_t sid=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(sid && a.spaceType(cid,sid)==4)hasSelectedFullScreen=true;
    }
    NSArray *windows=nil;
    if(hasSelectedFullScreen) {
        SelectedFullScreenQuiescence gate;
        std::string signature,diagnostic,lastDiagnostic;
        NSArray *sampleManaged=nil,*sampleWindows=nil;
        bool accepted=false;
        for(int attempt=0;attempt<6;attempt++) {
            NSUInteger selectedCount=0;
            bool valid=captureSelectedFullScreenInventory(cid,&sampleManaged,&sampleWindows,
                &selectedCount,signature,diagnostic) && selectedCount>0;
            if(!valid && diagnostic.empty())
                diagnostic=selectedFullScreenDiagnostic(0,0,"selected_space_changed");
            if(!valid)lastDiagnostic=diagnostic;
            if(gate.observe(valid,signature)) { accepted=true;break; }
            if(valid)lastDiagnostic=selectedFullScreenDiagnostic(0,0,"snapshot_changed");
            usleep(50000);
        }
        if(!accepted)return error((lastDiagnostic.empty()
            ? selectedFullScreenDiagnostic(0,0,"bounded_quiescence") : lastDiagnostic).c_str());
        managedBefore=sampleManaged;windows=sampleWindows;
        deferOrdinaryInventory=false;
        for(NSDictionary *display in managedBefore)for(NSDictionary *space in array(display[@"Spaces"])) {
            uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
            if(sid && a.spaceType(cid,sid)==4)deferOrdinaryInventory=true;
        }
    } else windows=completeWindowInventory(managedBefore,cid);
    if(!windows)return error("Cannot completely enumerate ordinary and full-screen Space windows before migration");
    saved.clear();createdSpaces.clear();ownedSpaces.clear();reusedSlots.clear();ordinarySpaceIdentities.clear();
    reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();reusedRoutePending.clear();deferredInvisibleWindows.clear();retainedOrdinaryWindows.clear();reusedCachedSlot.store(0);
    reusedCachedCount.store(0);reusedCachedLoop.store(0);nextReusedRouteScan=0;
    pendingCreateBefore.clear();pendingCreate=false;lastSelectedSpace=0;switchVerified=false;
    std::vector<SavedWindow> snapshot;
    DormantAXCache dormantAX;DetachedMenuStripScan initialMenuStrips;
    int startingFullScreenOccupants=0;
    std::map<uint64_t,SelectedFullScreenOwner> selectedFullScreenOwners;
    for(NSDictionary *display in managedBefore) {
        uint64_t sid=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(sid && a.spaceType(cid,sid)==4)selectedFullScreenOwners[sid]={};
    }
    if(!selectedFullScreenOwners.empty()) {
        for(NSDictionary *info in windows) {
            if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
            uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
            pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
            if(!wid || !pid || pid==getpid())continue;
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if(systemChrome(app.bundleIdentifier)
                || verifiedCursorUIOverlay(info,wid,pid,dormantAX)
                || verifiedCUAOverlay(info,wid,pid,cid)
                || verifiedTextKitAgentSurface(info,wid,pid,cid)
                || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&initialMenuStrips))continue;
            NSArray *members=CFBridgingRelease(a.windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
            uint64_t sid=members.count==1 ? [number(members[0]) unsignedLongLongValue] : 0;
            auto selected=selectedFullScreenOwners.find(sid);
            if(selected==selectedFullScreenOwners.end())continue;
            CGRect cgFrame={};
            if(!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&cgFrame))continue;
            AXUIElementRef ax=findAXWindow(pid,wid);if(!ax)continue;
            id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
            id state=axAttribute(ax,CFSTR("AXFullScreen"));Boolean settable=false;CGRect axFrame={};
            bool standard=[role isEqual:(__bridge NSString *)kAXWindowRole]
                && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                && state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
                && CFBooleanGetValue((__bridge CFBooleanRef)state)
                && AXUIElementIsAttributeSettable(ax,CFSTR("AXFullScreen"),&settable)==kAXErrorSuccess
                && settable && readAXFrame(ax,&axFrame) && nearFrame(axFrame,cgFrame);
            CFRelease(ax);if(!standard)continue;
            ProcessBirth birth=processBirth(pid);
            bool stable=app && !app.terminated && app.bundleIdentifier && birth.valid()
                && birth==processBirth(pid) && stableLaunchTime(app,pid)>0;
            if(!stable)return error(selectedFullScreenDiagnostic(wid,pid,"process_identity").c_str());
            if(selected->second.id)
                return error(selectedFullScreenDiagnostic(wid,pid,"unique_standard_owner").c_str());
            selected->second={wid,pid,app.bundleIdentifier,birth,cgFrame};
        }
        for(const auto &selected:selectedFullScreenOwners)if(!selected.second.id)
            return error("A selected full-screen Space has no unique settable standard Accessibility window");
    }
    std::map<uint32_t,uint64_t> backgroundChromeCompanions;
    for(NSDictionary *display in managedBefore) {
        NSString *uuid=managedDisplayUUID(display);
        uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        if(!uuid.length)continue;
        for(NSDictionary *space in array(display[@"Spaces"])) {
            uint64_t sid=[number(space[@"id64"]) unsignedLongLongValue];
            if(!sid || sid==current || a.spaceType(cid,sid)!=4)continue;
            for(const auto &source:displays)if([uuid isEqual:[NSString stringWithUTF8String:source.uuid.c_str()]]) {
                auto companions=backgroundChromeFullScreenCompanions(windows,sid,source.bounds,
                    source.uuid,cid);
                for(uint32_t wid:companions)backgroundChromeCompanions[wid]=sid;
            }
        }
    }
    DetachedMenuStripScan ordinaryMenuStrips;
    air::whole_space::Topology nativeTopology;
    std::vector<std::string> nativeDisplayOrder;
    for(const auto &display:displays)nativeDisplayOrder.push_back(display.uuid);
    if(!wholeTopology(managedBefore,nativeDisplayOrder,nativeTopology))
        return error("Native window migration display inventory is unavailable");
    for(NSDictionary *info in windows) {
        if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
        uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
        if(!wid || !pid || pid==getpid())continue;
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if(systemChrome(app.bundleIdentifier)
            || verifiedCursorUIOverlay(info,wid,pid,dormantAX)
            || verifiedCUAOverlay(info,wid,pid,cid)
            || verifiedTextKitAgentSurface(info,wid,pid,cid)
            || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&ordinaryMenuStrips))continue;
        NSArray *members=stableWindowMembership(wid,cid);
        if(!members)return error("A desktop window's Space membership is unavailable; Remote Spaces cannot omit it");
        if(!members.count){
            ProcessBirth sourceBirth=processBirth(pid);
            if(dormantInventoryOnlyWindow(info,wid,pid,app.bundleIdentifier,sourceBirth,cid,dormantAX))continue;
            DeferredInvisibleWindow deferred;
            if(deferredUnmappedNoAXWindow(info,wid,pid,app.bundleIdentifier,cid,&deferred)) {
                NSLog(@"RustDesk Air: leaving unmapped AX-inaccessible WID %u untouched",wid);
                deferredInvisibleWindows.push_back(std::move(deferred));continue;
            }
            if(departedWindowAfterSnapshot(wid,cid))continue;
            return error("A desktop window's Space membership is unavailable; Remote Spaces cannot omit it");
        }
        CGRect frame={};
        if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame))
            return error("A desktop window has unreadable bounds; Remote Spaces cannot move every window");
        double launchTime=stableLaunchTime(app,pid);
        if(!app.bundleIdentifier || launchTime<=0)
            return error("A desktop window has no stable application identity; Remote Spaces cannot restore it safely");
        CGPoint center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));int slot=-1;CGRect sourceBounds={};std::string sourceUUID;
        NSString *ownerUUID=a.windowDisplay ? CFBridgingRelease(a.windowDisplay(cid,wid)) : nil;
        for(auto &d:displays)if(ownerUUID && [ownerUUID isEqualToString:[NSString stringWithUTF8String:d.uuid.c_str()]]) {
            slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;break;
        }
        if(slot<0)for(auto &d:displays)if(CGRectContainsPoint(d.bounds,center)) {
            slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;break;
        }
        if(slot<0) {
            for(auto &d:displays)if(CGRectIntersectsRect(frame,d.bounds)) {
                if(slot>=0)return error("A desktop window spans displays without a readable owner; Remote Spaces cannot assign it safely");
                slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;
            }
        }
        if(slot<0)return error("A desktop window's source display is unknown; Remote Spaces cannot move every window");
        if(members.count!=1)return error(membershipBlocker(Membership::Multiple));
        uint64_t sid=[number(members[0]) unsignedLongLongValue];
        int kind=sid ? a.spaceType(cid,sid) : -1;
        if(kind!=0 && kind!=4)return error(membershipBlocker(Membership::NonOrdinary));
        auto backgroundCompanion=backgroundChromeCompanions.find(wid);
        if(kind==4 && backgroundCompanion!=backgroundChromeCompanions.end()
            && backgroundCompanion->second==sid)continue;
        // While the built-in display is showing a full-screen Space, macOS
        // can hide ordinary AX windows on every other Space.  Phase A records
        // only full-screen identities; ordinary windows are enumerated again
        // after the selected full-screen window has exited.
        if(deferOrdinaryInventory && kind==0)continue;
        if(!spaceOnDisplay(managed(),sid,sourceUUID)) {
            // Hidden compositor surfaces may retain an old display association.
            // Their unique Space membership is still valid. Never move one or
            // infer a new frame: retain it only after complete AX absence and
            // two stable identity/membership reads, and only while offscreen.
            DeferredInvisibleWindow deferred;
            if(kind==0 && deferredStaleDisplaySurface(info,wid,pid,app.bundleIdentifier,
                frame,sid,cid,&deferred)) {
                NSLog(@"RustDesk Air: retaining hidden stale-display surface WID %u",wid);
                deferredInvisibleWindows.push_back(std::move(deferred));continue;
            }
            return error((std::string("A window's Space is not on its verified source display: WID ")
                +std::to_string(wid)+" PID "+std::to_string(pid)).c_str());
        }
        // Windows already on the first built-in desktop need no mutation.
        // Other built-in ordinary desktops are captured for slot 1.
        if(kind==0 && slot==0 && sid==initialSpace)continue;
        auto selectedOwner=selectedFullScreenOwners.find(sid);
        if(selectedOwner!=selectedFullScreenOwners.end() && wid!=selectedOwner->second.id) {
            ProcessBirth birth=processBirth(pid);
            std::string predicate;
            if(selectedFullScreenCompanion(info,wid,pid,app.bundleIdentifier,birth,frame,sid,
                sourceUUID,selectedOwner->second,cid,dormantAX,&predicate)) {
                NSLog(@"RustDesk Air: leaving verified full-screen companion surface WID %u with its owner",wid);
                continue;
            }
            if(vanishedCompleteInventoryWindow(wid,cid))continue;
            return error(selectedFullScreenDiagnostic(wid,pid,predicate.c_str()).c_str());
        }
        if(frame.size.width<20 || frame.size.height<20) {
            ProcessBirth birth=processBirth(pid);
            if(kind==0 && stationaryBuiltinUnmappedSurface(info,wid,pid,app,birth,
                frame,sid,slot,nativeTopology,cid,dormantAX))continue;
            if(kind==0&&auxiliaryTinyWindow(info,wid,pid,app.bundleIdentifier,birth,frame,sid,cid,dormantAX)) {
                NSLog(@"RustDesk Air: leaving verified invisible auxiliary surface WID %u in its original Space",wid);
                continue;
            }
            return error((std::string("A desktop window is too small to place safely in Remote Spaces: ")
                +app.bundleIdentifier.UTF8String+" WID "+std::to_string(wid)
                +" size "+std::to_string(frame.size.width)+"x"+std::to_string(frame.size.height)).c_str());
        }
        if(initialFullScreenSpace && sid==initialFullScreenSpace)startingFullScreenOccupants++;
        bool fullscreen=kind==4;
        bool backgroundFullScreen=fullscreen && currentSpaceForDisplay(managed(),sourceUUID)!=sid;
        AXUIElementRef ax=findAXWindow(pid,wid);
        if(kind==0 && ax && verifiedWindowSharingCompanion(wid,pid,cid,ax)) {
            CFRelease(ax);continue;
        }
        if(!ax && !backgroundFullScreen) {
            ProcessBirth birth=processBirth(pid);
            if(ordinaryCompanionSurface(info,windows,wid,pid,app.bundleIdentifier,birth,
                frame,sourceBounds,sid,sourceUUID,cid,dormantAX)
                || stationaryBuiltinUnmappedSurface(info,wid,pid,app,birth,frame,
                    sid,slot,nativeTopology,cid,dormantAX))continue;
            if(vanishedCompleteInventoryWindow(wid,cid))continue;
            DeferredInvisibleWindow deferred;
            if(kind==0 && deferredInvisibleWindow(info,wid,pid,app.bundleIdentifier,frame,
                sid,sourceUUID,cid,&deferred)) {
                NSLog(@"RustDesk Air: retaining inaccessible ordinary WID %u on its original Space",wid);
                deferredInvisibleWindows.push_back(std::move(deferred));continue;
            }
            if(kind==0 && deferredUninspectableOrdinaryWindow(info,wid,pid,app.bundleIdentifier,
                frame,sid,sourceUUID,cid,&deferred)) {
                NSLog(@"RustDesk Air: retaining AX-inaccessible ordinary WID %u on its original Space",wid);
                deferredInvisibleWindows.push_back(std::move(deferred));continue;
            }
            DormantAXInventory inactive=readDormantAXInventory(pid);
            NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
            // A titled window with a real ordinary Space cannot be omitted
            // merely because its app has temporarily hidden its AX element.
            return error((std::string("Accessibility cannot inspect a live desktop window: ")
                +app.bundleIdentifier.UTF8String+" WID "+std::to_string(wid)
                +" on="+std::to_string(onscreen ? onscreen.intValue : -1)
                +" ax="+std::to_string(inactive.readable)+","+std::to_string(inactive.complete)
                +","+std::to_string(inactive.windows.size())+" titled="
                +std::to_string(stableTitledCGSurface(info,wid,pid,frame))
                +" frame="+std::to_string(frame.size.width)+"x"+std::to_string(frame.size.height)).c_str());
        }
        if(ax && [axAttribute(ax,kAXSubroleAttribute) isEqual:@"AXDialog"]) {
            CFRelease(ax);return error("A dialog requires the complete whole-Space recovery journal");
        }
        CGRect axFrame={};bool hasFrame=ax && readAXFrame(ax,&axFrame);
        bool minimized=false,minimizedKnown=kind==0 && ax
            && readWindowMinimized(ax,&minimized);
        if(kind==0 && !minimizedKnown) {
            if(ax)CFRelease(ax);
            return error("An ordinary window's minimized state is unreadable; no Spaces migration started");
        }
        NSString *identifier=@"";
        if(fullscreen && ax) {
            id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
            id state=axAttribute(ax,CFSTR("AXFullScreen"));
            id rawIdentifier=axAttribute(ax,kAXIdentifierAttribute);
            if([rawIdentifier isKindOfClass:NSString.class])identifier=rawIdentifier;
            Boolean settable=false;
            bool supported=[role isEqual:(__bridge NSString *)kAXWindowRole]
                && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                && state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
                && CFBooleanGetValue((__bridge CFBooleanRef)state)
                && AXUIElementIsAttributeSettable(ax,CFSTR("AXFullScreen"),&settable)==kAXErrorSuccess
                && settable && launchTime>0 && identifier.length<=256;
            if(!supported) { CFRelease(ax);return error(selectedFullScreenDiagnostic(
                wid,pid,"settable_fullscreen_ax_identity").c_str()); }
        }
        if(ax)CFRelease(ax);
        if(!hasFrame && !backgroundFullScreen)return error("Accessibility cannot read a live desktop window frame; no Spaces migration started");
        if(backgroundFullScreen)axFrame=frame;
        NSString *title=info[(id)kCGWindowName];if(![title isKindOfClass:NSString.class])title=@"";
        SavedWindow candidate={wid,pid,app.bundleIdentifier.UTF8String,title.UTF8String,axFrame,sourceBounds,
            launchTime,sid,slot,sourceUUID,true};
        candidate.minimizedKnown=minimizedKnown;candidate.minimized=minimized;
        if(fullscreen) {
            ProcessBirth birth=processBirth(pid);
            if(!birth.valid() || !(birth==processBirth(pid)))
                return error("A full-screen window's process birth is unstable; no Spaces migration started");
            candidate.birthSeconds=birth.seconds;candidate.birthMicroseconds=birth.microseconds;
            candidate.fullScreen=true;candidate.fullScreenPhase=1;candidate.fullScreenSpace=sid;
            candidate.axIdentifier=identifier.UTF8String;
            AXUIElementRef identity=backgroundFullScreen ? nullptr : findIdentifiedAXWindow(candidate,nullptr);
            if(!backgroundFullScreen && !identity)
                return error(selectedFullScreenDiagnostic(wid,pid,"unique_ax_identity").c_str());
            if(identity)CFRelease(identity);
            if(sid==initialFullScreenSpace)initialFullScreenIndex=(int)snapshot.size();
        }
        snapshot.push_back(std::move(candidate));
    }
    if(initialFullScreenSpace && (startingFullScreenOccupants!=1 || initialFullScreenIndex<0))
        return error("Initial full-screen Space is not one verifiable standard window");
    for(const auto &w:snapshot)if(w.fullScreen) {
        int occupants=0;
        for(const auto &other:snapshot)
            if(other.fullScreen && other.fullScreenSpace==w.fullScreenSpace)occupants++;
        if(occupants!=1)return error("A tiled or shared full-screen Space cannot be restored as one window");
    }
    if(!captureOrdinarySpaceIdentities(managedBefore,cid,ordinarySpaceIdentities))
        return error("Ordinary Space UUID inventory has duplicate or invalid identities");
    saved=std::move(snapshot);
    initialSelections.clear();
    for(NSDictionary *display in managed()) {
        NSString *uuid=managedDisplayUUID(display);
        uint64_t sid=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
        int type=sid ? api().spaceType(cid,sid) : -1;int window=-1;
        if(!uuid.length || !sid || (type!=0 && type!=4)) { saved.clear();return error("A display's selected Space cannot be journaled safely"); }
        if(type==4)for(size_t i=0;i<saved.size();i++)if(saved[i].fullScreen && saved[i].fullScreenSpace==sid) {
            if(window>=0){saved.clear();return error("A selected full-screen Space is not uniquely owned by one window");}
            window=(int)i;
        }
        if(type==4 && window<0){saved.clear();return error("A selected full-screen Space has no exact window identity");}
        initialSelections.push_back({uuid.UTF8String,sid,type,window,sid});
    }
    windowInventoryComplete=!deferOrdinaryInventory;
    if(!persist()){
        windowInventoryComplete=true;
        saved.clear();createdSpaces.clear();
        return error(("Cannot write Spaces recovery journal: "+journalIOError).c_str());
    }
    std::vector<size_t> fullScreenOrder;
    if(initialFullScreenIndex>=0)fullScreenOrder.push_back((size_t)initialFullScreenIndex);
    for(size_t index=0;index<saved.size();index++)if(saved[index].fullScreen
        && (int)index!=initialFullScreenIndex)fullScreenOrder.push_back(index);
    for(size_t index:fullScreenOrder) {
        SavedWindow original=saved[index];
        if(currentSpaceForDisplay(managed(),original.sourceUUID)!=original.fullScreenSpace
            && !beginHostSelection(original.sourceUUID,original.fullScreenSpace,(int)index,SelectionPurpose::Prepare,cid))
            return error("A full-screen window's exact Space could not be selected from the last Host-controlled Space; recovery journal retained");
        if(original.fullScreenPhase==1) {
            if(original.axIdentifier.empty()) {
                AXUIElementRef observed=findAXWindow(original.pid,original.id);
                id role=observed ? axAttribute(observed,kAXRoleAttribute) : nil;
                id subrole=observed ? axAttribute(observed,kAXSubroleAttribute) : nil;
                id state=observed ? axAttribute(observed,CFSTR("AXFullScreen")) : nil;
                id identifier=observed ? axAttribute(observed,kAXIdentifierAttribute) : nil;
                Boolean settable=false;CGRect frame={};
                bool okay=observed && sameProcess(original)
                    && [role isEqual:(__bridge NSString *)kAXWindowRole]
                    && [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole]
                    && state && CFGetTypeID((__bridge CFTypeRef)state)==CFBooleanGetTypeID()
                    && CFBooleanGetValue((__bridge CFBooleanRef)state)
                    && AXUIElementIsAttributeSettable(observed,CFSTR("AXFullScreen"),&settable)==kAXErrorSuccess && settable
                    && (!identifier || ([identifier isKindOfClass:NSString.class] && [identifier length]<=256))
                    && readAXFrame(observed,&frame);
                if(observed)CFRelease(observed);
                if(!okay)return error("A selected background full-screen window could not be uniquely reacquired through Accessibility; recovery journal retained");
                original.axIdentifier=[identifier isKindOfClass:NSString.class] ? [identifier UTF8String] : "";
                original.frame=frame;original.frameFromAX=true;saved[index]=original;
            }
            saved[index].fullScreenPhase=4;original.fullScreenPhase=4;
            selectionPending={true,original.sourceUUID,original.fullScreenSpace,0,(int)index,SelectionPurpose::Prepare,1};
            if(!persist())return error(("Cannot journal a pending full-screen exit: "+journalIOError).c_str());
        }
        AXUIElementRef retained=nullptr;
#ifdef AIR_SPACES_JOURNAL_TEST
        bool mocked=recoveryHooks && recoveryHooks->setFullScreen;
#else
        bool mocked=false;
#endif
        if(!mocked)retained=findIdentifiedAXWindow(original,nullptr);
        bool exited=retained || mocked;
        if(exited)exited=mocked ? setFullScreen(original,false) : setFullScreenElement(retained,false);
        SavedWindow after=original;
        if(exited) {
            CGWindowID current=0;
            if(mocked)current=resolvedWindowID(original);
            else if(api().axWindow(retained,&current)!=kAXErrorSuccess)current=0;
            if(!current)exited=false;
            else after.id=current;
        }
        uint64_t ordinary=exited ? awaitOrdinaryAfterExit(after,cid) : 0;
        CGRect first={},second={};
        bool stable=ordinary && afterExitFrame(after,&first);
        if(stable) {
            usleep(50000);
            stable=afterExitFrame(after,&second) && nearFrame(first,second);
        }
        if(ordinary && stable) {
            after.space=ordinary;after.frame=second;after.fullScreenPhase=2;
            uint64_t priorInitial=initialSpace;
            if(after.slot>0 && !sourceCurrentIs(after,ordinary))
                return rollbackFailedFullScreenPrepare(index,original,retained,mocked,cid);
            if((int)index==initialFullScreenIndex) {
                NSDictionary *currentBuiltin=builtInManaged(managed());
                uint64_t current=[number(dictionary(currentBuiltin[@"Current Space"])[@"id64"]) unsignedLongLongValue];
                if(![managedDisplayUUID(currentBuiltin) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]]
                    || current!=ordinary || api().spaceType(cid,ordinary)!=0
                    || !spaceOnDisplay(managed(),ordinary,builtinUUID))
                    return rollbackFailedFullScreenPrepare(index,original,retained,mocked,cid);
                initialSpace=ordinary;
            }
            DisplaySelection *display=selectionForDisplay(after.sourceUUID);
            uint64_t priorHost=display ? display->hostSpace : 0;
            saved[index]=after;if(display)display->hostSpace=ordinary;selectionPending={};
            if(display && persist()) {if(retained)CFRelease(retained);continue;}
            if(display)display->hostSpace=priorHost;
            selectionPending={true,original.sourceUUID,original.fullScreenSpace,0,(int)index,SelectionPurpose::Prepare,1};
            initialSpace=priorInitial;
        }
        return rollbackFailedFullScreenPrepare(index,original,retained,mocked,cid);
    }
    if(!windowInventoryComplete) {
        const size_t fullScreenPrefix=saved.size();
        DormantAXCache phaseBCursorAX;
        auto inventorySignature=[&](NSArray *inventory,std::set<std::string> &result)->bool {
            result.clear();if(!inventory)return false;
            DetachedMenuStripScan signatureMenuStrips;
            for(NSDictionary *info in inventory) {
                if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
                uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
                pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
                if(!wid || !pid || pid==getpid())continue;
                NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                if(systemChrome(app.bundleIdentifier)
                    || verifiedCursorUIOverlay(info,wid,pid,phaseBCursorAX)
                    || verifiedCUAOverlay(info,wid,pid,cid)
                    || verifiedTextKitAgentSurface(info,wid,pid,cid)
                    || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&signatureMenuStrips))continue;
                ProcessBirth birth=processBirth(pid);CGRect frame={};
                NSArray *members=CFBridgingRelease(a.windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
                if(!members || !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame))return false;
                NSMutableString *line=[NSMutableString stringWithFormat:@"%u:%d:%llu:%llu:%.3f:%.3f:%.3f:%.3f",
                    wid,pid,birth.seconds,birth.microseconds,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height];
                for(id member in members) {
                    NSNumber *sid=number(member);if(!sid)return false;
                    [line appendFormat:@":%llu:%d",sid.unsignedLongLongValue,a.spaceType(cid,sid.unsignedLongLongValue)];
                }
                result.insert(line.UTF8String);
            }
            return true;
        };
        NSArray *ordinaryWindows=nil;std::set<std::string> prior,current;
        for(int attempt=0;attempt<6;attempt++) {
            NSArray *first=completeWindowInventory(managed(),cid);
            if(!inventorySignature(first,prior)){usleep(50000);continue;}
            usleep(50000);
            NSArray *second=completeWindowInventory(managed(),cid);
            if(inventorySignature(second,current) && prior==current){ordinaryWindows=second;break;}
        }
        auto failPhaseB=[&](const char *message)->int {
            std::string original=message;int restored=restoreLocked();
            if(restored==0)return error((original+"; full-screen state restored").c_str());
            return error((original+"; recovery journal retained").c_str());
        };
        if(!ordinaryWindows)return failPhaseB("The post-full-screen window inventory did not become stable");
        std::vector<SavedWindow> merged=saved;
        std::vector<bool> seen(fullScreenPrefix,false);
        DormantAXCache phaseBAX;DetachedMenuStripScan finalMenuStrips;
        for(NSDictionary *info in ordinaryWindows) {
            if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
            uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
            pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
            if(!wid || !pid || pid==getpid())continue;
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if(systemChrome(app.bundleIdentifier)
                || verifiedCursorUIOverlay(info,wid,pid,phaseBCursorAX)
                || verifiedCUAOverlay(info,wid,pid,cid)
                || verifiedTextKitAgentSurface(info,wid,pid,cid)
                || verifiedDetachedMenuStripSurface(info,wid,pid,cid,&finalMenuStrips))continue;
            NSArray *members=CFBridgingRelease(a.windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
            if(!members)return failPhaseB("A post-full-screen window's Space membership is unreadable");
            if(!members.count) {
                ProcessBirth birth=processBirth(pid);
                if(dormantInventoryOnlyWindow(info,wid,pid,app.bundleIdentifier,birth,cid,phaseBAX))continue;
                // Full-screen exit can retire a Chrome CG surface after the
                // stable inventory was sampled. Omit only an exact WID absent
                // from two fresh complete inventories and Space queries.
                if(vanishedCompleteInventoryWindow(wid,cid))continue;
                DeferredInvisibleWindow deferred;
                if(deferredUnmappedNoAXWindow(info,wid,pid,app.bundleIdentifier,cid,&deferred)) {
                    NSLog(@"RustDesk Air: leaving unmapped AX-inaccessible WID %u untouched",wid);
                    deferredInvisibleWindows.push_back(std::move(deferred));continue;
                }
                auto axInventory=phaseBAX.find(pid);
                AXUIElementRef ax=findAXWindow(pid,wid);
                id role=ax ? axAttribute(ax,kAXRoleAttribute) : nil;
                id subrole=ax ? axAttribute(ax,kAXSubroleAttribute) : nil;
                uint64_t tags=0;bool tagsKnown=exactWindowTags(cid,wid,&tags);
                CGRect frame={};CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame);
                NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
                fprintf(stderr,"air_phase_b_no_members wid=%u pid=%d bundle=%s ax=%d "
                    "role=%s subrole=%s inventory=%d,%d,%d on=%d alpha=%.1f "
                    "tags=%d:0x%llx frame=%.0f,%.0f,%.0f,%.0f\n",wid,pid,
                    app.bundleIdentifier.UTF8String ?: "?",ax!=nullptr,
                    [role UTF8String] ?: "?",[subrole UTF8String] ?: "?",
                    axInventory!=phaseBAX.end() && axInventory->second.readable,
                    axInventory!=phaseBAX.end() && axInventory->second.complete,
                    axInventory!=phaseBAX.end() && axInventory->second.windows.count(wid),
                    onscreen ? onscreen.intValue : -1,
                    [number(info[(id)kCGWindowAlpha]) doubleValue],tagsKnown,
                    (unsigned long long)tags,frame.origin.x,frame.origin.y,
                    frame.size.width,frame.size.height);
                if(ax)CFRelease(ax);
                return failPhaseB("A post-full-screen window has no Space membership");
            }
            if(members.count!=1)return failPhaseB(membershipBlocker(Membership::Multiple));
            uint64_t sid=[number(members[0]) unsignedLongLongValue];
            if(!sid || a.spaceType(cid,sid)!=0)
                return failPhaseB("A new full-screen or non-ordinary Space appeared during window preparation");
            CGRect frame={};
            if(!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame))
                return failPhaseB("A post-full-screen window has unreadable bounds");
            double launchTime=stableLaunchTime(app,pid);
            if(!app.bundleIdentifier || launchTime<=0)
                return failPhaseB("A post-full-screen window has no stable application identity");
            CGPoint center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
            int slot=-1;CGRect sourceBounds={};std::string sourceUUID;
            NSString *ownerUUID=a.windowDisplay ? CFBridgingRelease(a.windowDisplay(cid,wid)) : nil;
            for(auto &d:displays)if(ownerUUID && [ownerUUID isEqualToString:[NSString stringWithUTF8String:d.uuid.c_str()]]) {
                slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;break;
            }
            if(slot<0)for(auto &d:displays)if(CGRectContainsPoint(d.bounds,center)) {
                slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;break;
            }
            if(slot<0)for(auto &d:displays)if(CGRectIntersectsRect(frame,d.bounds)) {
                if(slot>=0)return failPhaseB("A post-full-screen window spans displays without a readable owner");
                slot=d.slot;sourceBounds=d.bounds;sourceUUID=d.uuid;
            }
            if(slot<0 || !spaceOnDisplay(managed(),sid,sourceUUID))
                return failPhaseB("A post-full-screen window's source display is not verifiable");
            bool exitedMatch=false;
            for(size_t index=0;index<fullScreenPrefix;index++)if(saved[index].id==wid) {
                const SavedWindow &w=saved[index];
                bool exact=w.fullScreen && w.fullScreenPhase==2 && !seen[index]
                    && w.pid==pid && w.bundle==app.bundleIdentifier.UTF8String
                    && fabs(w.launchTime-launchTime)<=1 && w.space==sid && w.sourceUUID==sourceUUID;
                if(!exact)return failPhaseB("An exited full-screen window no longer has its exact journaled identity");
                seen[index]=true;exitedMatch=true;break;
            }
            if(exitedMatch)continue;
            if(slot==0 && sid==initialSpace)continue;
            if(frame.size.width<20 || frame.size.height<20) {
                ProcessBirth birth=processBirth(pid);
                if(auxiliaryTinyWindow(info,wid,pid,app.bundleIdentifier,birth,frame,sid,cid,phaseBAX))continue;
                return failPhaseB("A post-full-screen desktop window is too small to place safely");
            }
            AXUIElementRef ax=findAXWindow(pid,wid);
            if(ax && verifiedWindowSharingCompanion(wid,pid,cid,ax)) {
                CFRelease(ax);continue;
            }
            if(!ax) {
                ProcessBirth birth=processBirth(pid);
                if(ordinaryCompanionSurface(info,ordinaryWindows,wid,pid,app.bundleIdentifier,birth,frame,
                    sourceBounds,sid,sourceUUID,cid,phaseBAX))continue;
                if(vanishedCompleteInventoryWindow(wid,cid))continue;
                DeferredInvisibleWindow deferred;
                if(deferredInvisibleWindow(info,wid,pid,app.bundleIdentifier,frame,
                    sid,sourceUUID,cid,&deferred)) {
                    NSLog(@"RustDesk Air: retaining inaccessible ordinary WID %u on its original Space",wid);
                    deferredInvisibleWindows.push_back(std::move(deferred));continue;
                }
                if(deferredUninspectableOrdinaryWindow(info,wid,pid,app.bundleIdentifier,
                    frame,sid,sourceUUID,cid,&deferred)) {
                    NSLog(@"RustDesk Air: retaining AX-inaccessible ordinary WID %u on its original Space",wid);
                    deferredInvisibleWindows.push_back(std::move(deferred));continue;
                }
                NSString *cgTitle=info[(id)kCGWindowName];
                NSNumber *alpha=number(info[(id)kCGWindowAlpha]);
                auto found=phaseBAX.find(pid);
                if(found==phaseBAX.end())found=phaseBAX.emplace(pid,readDormantAXInventory(pid)).first;
                bool identified=birth.valid() && birth==processBirth(pid)
                    && found->second.birth==birth && found->second.readable
                    && found->second.complete && !found->second.windows.count(wid)
                    && [cgTitle isKindOfClass:NSString.class] && cgTitle.length>0
                    && alpha && alpha.doubleValue==1 && stableCGSurface(info,wid,pid,frame)
                    && windowOnDisplay(wid,cid,sourceUUID);
                for(uint32_t rootID:found->second.windows)if(identified) {
                    AXUIElementRef root=findAXWindow(pid,rootID);CGRect rootFrame={};
                    bool contains=root && readAXFrame(root,&rootFrame)
                        && CGRectContainsRect(CGRectInset(rootFrame,-2,-2),frame);
                    if(root)CFRelease(root);
                    if(contains)identified=false;
                }
                if(!identified) {
                    const char *recheck="not_attempted";
                    if([app.bundleIdentifier isEqual:@"com.google.Chrome"]
                        && (![cgTitle isKindOfClass:NSString.class] || !cgTitle.length)
                        && vanishedCompleteInventoryWindow(wid,cid,&recheck))continue;
                    // Preserve the refusal, but identify the transient CG surface
                    // before restoration removes the evidence.  Window titles and
                    // other user content are deliberately excluded from this log.
                    char detail[448];uint64_t tags=0;unsigned containingRoots=0;
                    bool tagsReadable=exactWindowTags(cid,wid,&tags);
                    NSNumber *onscreen=number(info[(id)kCGWindowIsOnscreen]);
                    for(uint32_t rootID:found->second.windows) {
                        AXUIElementRef root=findAXWindow(pid,rootID);CGRect rootFrame={};
                        if(root && readAXFrame(root,&rootFrame)
                            && CGRectContainsRect(CGRectInset(rootFrame,-2,-2),frame))containingRoots++;
                        if(root)CFRelease(root);
                    }
                    snprintf(detail,sizeof(detail),
                        "Accessibility cannot inspect post-full-screen window [wid=%u pid=%d sid=%llu slot=%d chrome=%d "
                        "frame=%.0f,%.0f,%.0f,%.0f titleLen=%lu alpha=%.2f onscreen=%d "
                        "stable=%d birthSame=%d axBirthSame=%d axReadable=%d axComplete=%d axCount=%zu "
                        "containingRoots=%u displaySame=%d tagsReadable=%d tags=0x%llx parent=%u recheck=%s]",
                        wid,pid,(unsigned long long)sid,slot,
                        [app.bundleIdentifier isEqual:@"com.google.Chrome"],frame.origin.x,frame.origin.y,
                        frame.size.width,frame.size.height,
                        (unsigned long)([cgTitle isKindOfClass:NSString.class] ? cgTitle.length : 0),
                        alpha ? alpha.doubleValue : -1.0,onscreen ? onscreen.boolValue : -1,
                        stableCGSurface(info,wid,pid,frame),birth==processBirth(pid),
                        found->second.birth==birth,found->second.readable,
                        found->second.complete,found->second.windows.size(),containingRoots,
                        windowOnDisplay(wid,cid,sourceUUID),tagsReadable,
                        (unsigned long long)tags,exactWindowParent(cid,wid),recheck);
                    std::string message=detail;
                    unsigned peers=0;
                    for(NSDictionary *peer in ordinaryWindows) {
                        if(peers==8)break;
                        if([number(peer[(id)kCGWindowLayer]) intValue]!=0
                            || [number(peer[(id)kCGWindowOwnerPID]) intValue]!=pid)continue;
                        uint32_t peerID=[number(peer[(id)kCGWindowNumber]) unsignedIntValue];
                        if(!peerID)continue;
                        CGRect peerFrame={};
                        if(!CGRectMakeWithDictionaryRepresentation(
                            (__bridge CFDictionaryRef)dictionary(peer[(id)kCGWindowBounds]),&peerFrame))continue;
                        NSArray *peerSpaces=CFBridgingRelease(a.windowSpaces(cid,0x7,
                            (__bridge CFArrayRef)@[@(peerID)]));
                        if(peerSpaces.count!=1 || [number(peerSpaces[0]) unsignedLongLongValue]!=sid)continue;
                        uint64_t peerTags=0;bool peerTagsReadable=exactWindowTags(cid,peerID,&peerTags);
                        NSString *peerTitle=peer[(id)kCGWindowName];
                        NSNumber *peerAlpha=number(peer[(id)kCGWindowAlpha]);
                        NSNumber *peerOnscreen=number(peer[(id)kCGWindowIsOnscreen]);
                        char row[224];
                        snprintf(row,sizeof(row)," peer=%u:%u:%.0f,%.0f,%.0f,%.0f:%lu:%.2f:%d:%d:0x%llx",
                            peerID,exactWindowParent(cid,peerID),peerFrame.origin.x,peerFrame.origin.y,
                            peerFrame.size.width,peerFrame.size.height,
                            (unsigned long)([peerTitle isKindOfClass:NSString.class] ? peerTitle.length : 0),
                            peerAlpha ? peerAlpha.doubleValue : -1.0,
                            peerOnscreen ? peerOnscreen.boolValue : -1,
                            peerTagsReadable,(unsigned long long)peerTags);
                        message+=row;peers++;
                    }
                    fprintf(stderr,"air_phase_b_unknown=%s\n",message.c_str());
                    fflush(stderr);
                    return failPhaseB("Accessibility cannot inspect an unverified post-full-screen desktop window");
                }
                for(const SavedWindow &priorWindow:merged)
                    if(priorWindow.id==wid && priorWindow.pid==pid)
                        return failPhaseB("The post-full-screen inventory contains a duplicate window identity");
                SavedWindow candidate={wid,pid,app.bundleIdentifier.UTF8String,cgTitle.UTF8String,
                    frame,sourceBounds,launchTime,sid,slot,sourceUUID,false};
                candidate.cgOnly=true;candidate.birthSeconds=birth.seconds;
                candidate.birthMicroseconds=birth.microseconds;
                merged.push_back(std::move(candidate));
                continue;
            }
            if([axAttribute(ax,kAXSubroleAttribute) isEqual:@"AXDialog"]) {
                CFRelease(ax);return failPhaseB("A dialog requires the complete whole-Space recovery journal");
            }
            CGRect axFrame={};bool hasFrame=readAXFrame(ax,&axFrame);
            bool minimized=false,minimizedKnown=readWindowMinimized(ax,&minimized);
            CFRelease(ax);
            if(!hasFrame)return failPhaseB("Accessibility cannot read a post-full-screen desktop window frame");
            if(!minimizedKnown)return failPhaseB("A post-full-screen window's minimized state is unreadable");
            NSString *title=info[(id)kCGWindowName];if(![title isKindOfClass:NSString.class])title=@"";
            for(const SavedWindow &priorWindow:merged)
                if(priorWindow.id==wid && priorWindow.pid==pid)
                    return failPhaseB("The post-full-screen inventory contains a duplicate window identity");
            SavedWindow candidate={wid,pid,app.bundleIdentifier.UTF8String,title.UTF8String,
                axFrame,sourceBounds,launchTime,sid,slot,sourceUUID,true};
            candidate.minimizedKnown=true;candidate.minimized=minimized;
            merged.push_back(std::move(candidate));
        }
        for(size_t index=0;index<fullScreenPrefix;index++)
            if(saved[index].fullScreen && saved[index].fullScreenPhase==2 && !seen[index])
                return failPhaseB("An exited full-screen window is missing from the complete ordinary inventory");
        std::vector<SavedWindow> incomplete=saved;
        saved=std::move(merged);windowInventoryComplete=true;
        if(!persist()) {
            saved=std::move(incomplete);windowInventoryComplete=false;
            return failPhaseB("The complete post-full-screen window inventory could not be journaled");
        }
    }
    return 0;
}
std::string activationPlacementFailure(const char *stage,const SavedWindow &w,uint64_t target) {
    char message[256];
    snprintf(message,sizeof(message),
        "Activation placement failed stage=%s wid=%u slot=%d target=%llu; recovery journal retained",
        stage ? stage : "preflight",w.id,w.slot+1,(unsigned long long)target);
    return message;
}
// A native app may accept AXSize but clamp to a minimum wider than the built-in
// panel. Remove it from the migration journal only after its original endpoint
// has been fully restored and the smaller journal is durable.
bool retainRefusedOrdinaryWindow(size_t index,int cid,uint64_t target,std::string *reason) {
    if(index>=saved.size())return false;
    SavedWindow w=saved[index];ProcessBirth birth=processBirth(w.pid);
    if(w.fullScreen || w.cgOnly || w.readOnlyCG || w.axDialog || w.followerParent
        || !w.frameFromAX || !w.minimizedKnown || !birth.valid()
        || !sameProcess(w) || api().spaceType(cid,w.space)!=0
        || !spaceOnDisplay(managed(),w.space,w.sourceUUID)
        || !(exactSingletonMembership(cid,w.id,target)
            || (exactSingletonMembership(cid,w.id,w.space)
                && windowOnDisplay(w.id,cid,w.sourceUUID)))
        || std::any_of(saved.begin(),saved.end(),[&](const SavedWindow &child) {
            return child.followerParent==w.id;
        })) {
        if(reason)*reason=activationPlacementFailure("refusal_identity",w,target);
        return false;
    }
    if(!move(w.id,w.space,cid) || !exactSingletonMembership(cid,w.id,w.space)) {
        if(reason)*reason=activationPlacementFailure("refusal_rollback_space",w,target);
        return false;
    }
    std::string accessReason;
    if(prepareOriginalWindowAccess(w,cid,&accessReason)==RecoverySpaceAccess::Failed
        || (w.minimized && !setWindowMinimizedState(w,false))) {
        if(reason)*reason=activationPlacementFailure("refusal_rollback_frame",w,target);
        return false;
    }
    bool restoredFrame=false;
    for(int attempt=0;attempt<3;attempt++) {
        if(setFrame(w)){restoredFrame=true;break;}
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if(!restoredFrame) {
        if(reason)*reason=activationPlacementFailure("refusal_rollback_frame",w,target);
        return false;
    }
    CGRect originalAX={},originalCG={},secondCG={};
    bool frameOkay=false;
    for(int settle=0;settle<40;settle++) {
        AXUIElementRef ax=findAXWindow(w.pid,w.id);
        frameOkay=ax && readAXFrame(ax,&originalAX)
            && readCGFrame(w.id,w.pid,&originalCG)
            && nearFrame(originalAX,w.frame) && nearFrame(originalCG,originalAX);
        if(ax)CFRelease(ax);
        if(frameOkay)break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if(!restoreWindowMinimized(w) || !frameOkay
        || !readCGFrame(w.id,w.pid,&secondCG)
        || !nearFrame(secondCG,originalCG)
        || !sameProcess(w) || !(birth==processBirth(w.pid))
        || !exactSingletonMembership(cid,w.id,w.space)
        || !windowOnDisplay(w.id,cid,w.sourceUUID)) {
        if(reason)*reason=activationPlacementFailure("refusal_rollback_verify",w,target);
        return false;
    }
    if(initialFullScreenIndex==(int)index || selectionPending.windowIndex==(int)index
        || std::any_of(initialSelections.begin(),initialSelections.end(),[&](const DisplaySelection &selection) {
            return selection.fullScreenWindow==(int)index;
        })) {
        if(reason)*reason=activationPlacementFailure("refusal_referenced_index",w,target);
        return false;
    }
    auto priorSaved=saved;auto priorSelections=initialSelections;
    int priorInitial=initialFullScreenIndex;SelectionPending priorPending=selectionPending;
    saved.erase(saved.begin()+index);
    auto rebase=[&](int &value) {
        if(value>(int)index)--value;
    };
    rebase(initialFullScreenIndex);
    for(auto &selection:initialSelections)rebase(selection.fullScreenWindow);
    rebase(selectionPending.windowIndex);
    if(!persist()) {
        saved=std::move(priorSaved);initialSelections=std::move(priorSelections);
        initialFullScreenIndex=priorInitial;selectionPending=std::move(priorPending);
        if(reason)*reason=activationPlacementFailure("refusal_journal",w,target);
        return false;
    }
    recordRetainedOrdinary(w.id,w.pid,w.space,w.sourceUUID,originalCG,"native placement refused; original restored");
    return true;
}
bool placeActivationWindowsPass(int cid,CGRect content,std::string *reason,bool *restart) {
    *restart=false;
    std::vector<size_t> live;
    for(size_t index=0;index<saved.size();index++) {
        const SavedWindow &w=saved[index];
        WindowState state=windowState(w);
        if(state==WindowState::Gone)continue;
        if(w.slot<0 || w.slot>2 || !slots[w.slot] || state==WindowState::AXUnavailable) {
            if(reason)*reason=activationPlacementFailure("preflight",w,
                w.slot>=0 && w.slot<3 ? slots[w.slot] : 0);
            return false;
        }
        live.push_back(index);
    }
    // An attached child has no independent frame controller. Reject any
    // placement that would clip it before moving the first window in this phase.
    for(size_t index:live)if(saved[index].followerParent) {
        const SavedWindow &w=saved[index];
        auto parent=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &entry) {
            return entry.id==w.followerParent && entry.pid==w.pid;
        });
        if(parent==saved.end() || parent->slot!=w.slot || parent->followerParent
            || !attachedFollowerGeometry(parent->frame,w.frame,w.followerOffset)) {
            if(reason)*reason=activationPlacementFailure("follower_parent",w,slots[w.slot]);
            return false;
        }
        CGRect mapped=mappedFrame(*parent,content);
        CGRect child=CGRectMake(mapped.origin.x+w.followerOffset.x,
            mapped.origin.y+w.followerOffset.y,w.frame.size.width,w.frame.size.height);
        if(CGRectIsNull(mapped) || !CGRectContainsRect(content,child)) {
            if(reason)*reason=activationPlacementFailure("follower_bounds",w,slots[w.slot]);
            return false;
        }
    }
    for(int slot=0;slot<3;slot++) {
        uint64_t target=slots[slot];std::vector<size_t> group;
        for(size_t index:live)if(saved[index].slot==slot) {
            SavedWindow &w=saved[index];group.push_back(index);
            if(w.followerParent)continue;
            bool finder=exactFinderJournal(w);
            if(w.cgOnly && w.bundle=="com.apple.finder" && !finder) {
                if(reason)*reason=activationPlacementFailure("finder_journal_identity",w,target);
                return false;
            }
            bool exactSurface=finder || w.axDialog || (w.cgOnly && w.bundle=="com.lujjjh.LinearMouse"
                && w.title=="LinearMouse");
            if(exactSurface && windowState(w)!=WindowState::Ready) {
                if(reason)*reason=activationPlacementFailure("identity_before_move",w,target);
                return false;
            }
            if(!finder && !move(w.id,target,cid)) {
                if(reason)*reason=activationPlacementFailure("move",w,target);
                return false;
            }
            if(!finder && oneWindowSpace(w.id,cid)!=target) {
                if(reason)*reason=activationPlacementFailure("membership",w,target);
                return false;
            }
        }
        if(group.empty())continue;
        std::stable_sort(group.begin(),group.end(),[](size_t a,size_t b) {
            return saved[a].followerParent==0 && saved[b].followerParent!=0;
        });
        for(size_t index:group)if(saved[index].followerParent) {
            const SavedWindow &w=saved[index];
            bool ready=false;
            for(int retry=0;retry<20;retry++) {
                if(windowState(w)==WindowState::Ready && oneWindowSpace(w.id,cid)==target) {
                    ready=true;break;
                }
                usleep(25000);
            }
            if(!ready) {
                if(reason)*reason=activationPlacementFailure("follower_move",w,target);
                return false;
            }
        }
        if(lastSelectedSpace!=target) {
            uint64_t previous=lastSelectedSpace;lastSelectedSpace=target;
            if(!persist()) {
                lastSelectedSpace=previous;
                if(reason)*reason=activationPlacementFailure("select",saved[group.front()],target);
                return false;
            }
        }
        if((builtInCurrentSpace()!=target && !switchSpace(target,cid))
            || builtInCurrentSpace()!=target) {
            if(reason)*reason=activationPlacementFailure("select",saved[group.front()],target);
            return false;
        }
        for(size_t index:group) {
            SavedWindow &w=saved[index];
            if(w.followerParent)continue;
            if(!exactFinderJournal(w) && oneWindowSpace(w.id,cid)!=target) {
                if(reason)*reason=activationPlacementFailure("membership",w,target);
                return false;
            }
            CGRect expected=exactFinderJournal(w)
                ? mappedFinderFrame(w,content) : mappedFrame(w,content);
            if(CGRectIsNull(expected)) {
                if(reason)*reason=activationPlacementFailure("frame_mapping",w,target);
                return false;
            }
            bool canPlace=!w.minimized || setWindowMinimizedState(w,false);
            bool placed=false;
            for(int attempt=0;canPlace && attempt<3;attempt++) {
                if(setFrame(w,expected)){placed=true;break;}
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if(!canPlace || !placed || !restoreWindowMinimized(w)) {
                if(!retainRefusedOrdinaryWindow(index,cid,target,reason)) {
                    if(reason && reason->empty())*reason=activationPlacementFailure("frame",w,target);
                    return false;
                }
                *restart=true;
                return true;
            }
            if(oneWindowSpace(w.id,cid)!=target) {
                if(reason)*reason=activationPlacementFailure("membership",w,target);
                return false;
            }
            bool onBuiltin=false;
            for(int retry=0;retry<20;retry++) {
                if(windowOnDisplay(w.id,cid,builtinUUID)){onBuiltin=true;break;}
                usleep(25000);
            }
            if(!onBuiltin) {
                if(reason)*reason=activationPlacementFailure("display",w,target);
                return false;
            }
        }
        for(size_t index:group)if(saved[index].followerParent) {
            const SavedWindow &w=saved[index];
            auto parent=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &entry) {
                return entry.id==w.followerParent && entry.pid==w.pid;
            });
            bool okay=false;
            for(int retry=0;retry<20;retry++) {
                CGRect parentFrame={},childAX={},childCG={};
                AXUIElementRef parentAX=parent==saved.end() ? nullptr : findAXWindow(w.pid,parent->id);
                AXUIElementRef child=findAXWindow(w.pid,w.id);
                okay=parentAX && child && readAXFrame(parentAX,&parentFrame)
                    && readAXFrame(child,&childAX) && readCGFrame(w.id,w.pid,&childCG)
                    && nearFrame(childAX,childCG)
                    && attachedFollowerGeometry(parentFrame,childCG,w.followerOffset)
                    && windowState(w)==WindowState::Ready
                    && oneWindowSpace(w.id,cid)==target
                    && windowOnDisplay(w.id,cid,builtinUUID)
                    && CGRectContainsRect(content,childCG);
                if(parentAX)CFRelease(parentAX);
                if(child)CFRelease(child);
                if(okay)break;
                usleep(25000);
            }
            if(!okay) {
                if(reason)*reason=activationPlacementFailure("follower_frame",w,target);
                return false;
            }
        }
    }
    return true;
}
bool placeActivationWindows(int cid,CGRect content,std::string *reason) {
    for(size_t remaining=saved.size()+1;remaining>0;--remaining) {
        bool restart=false;
        if(!placeActivationWindowsPass(cid,content,reason,&restart))return false;
        if(!restart)return true;
    }
    if(reason)*reason="Too many ordinary windows refused native placement; recovery journal retained";
    return false;
}
// Moving an entire external Space preserves its 1920-point window frames even
// when the built-in desktop is much smaller. Ask each app to lay out its window
// at a native size that fits the built-in screen after the Space has moved.
// The original frames remain in the durable journal for restoration.
bool placeWholeRuntimeWindows(int cid,CGRect content,std::string *reason) {
    if(CGRectIsNull(content) || content.size.width<100 || content.size.height<100
        || !wholeFrameInventoryComplete || wholeJournal.forwardDone!=4)return false;
    std::vector<CGRect> targets(saved.size(),CGRectNull);
    for(size_t index=0;index<saved.size();index++) {
        const SavedWindow &w=saved[index];
        if(w.slot<0 || w.slot>2 || !wholeJournal.selected[w.slot])return false;
        if(w.slot==0 || w.space!=wholeJournal.selected[w.slot]
            || w.readOnlyCG || w.followerParent)continue;
        CGRect target=exactFinderJournal(w)
            ? mappedFinderFrame(w,content) : mappedFrame(w,content);
        if(CGRectIsNull(target) || !CGRectContainsRect(content,target)) {
            if(reason)*reason=activationPlacementFailure("whole_frame_plan",w,wholeJournal.selected[w.slot]);
            return false;
        }
        targets[index]=target;
    }
    for(const SavedWindow &w:saved)if(w.slot>0
        && w.space==wholeJournal.selected[w.slot] && w.followerParent) {
        auto parent=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &entry) {
            return entry.id==w.followerParent && entry.pid==w.pid;
        });
        if(parent==saved.end() || parent->slot!=w.slot || parent->followerParent) {
            if(reason)*reason=activationPlacementFailure("whole_follower_parent",w,wholeJournal.selected[w.slot]);
            return false;
        }
        CGRect target=targets[parent-saved.begin()];
        CGRect child=CGRectMake(target.origin.x+w.followerOffset.x,
            target.origin.y+w.followerOffset.y,w.frame.size.width,w.frame.size.height);
        if(CGRectIsNull(target) || !CGRectContainsRect(content,child)) {
            if(reason)*reason=activationPlacementFailure("whole_follower_bounds",w,wholeJournal.selected[w.slot]);
            return false;
        }
    }
    auto hooks=wholeHooks(cid);
    for(int slot=1;slot<3;slot++) {
        bool occupied=std::any_of(saved.begin(),saved.end(),[&](const SavedWindow &w) {
            return w.slot==slot && w.space==wholeJournal.selected[slot];
        });
        if(!occupied)continue;
        uint64_t selected=wholeJournal.selected[slot];std::string selectionReason;
        if(!air::whole_space::selectRuntime(wholeJournal,hooks,selected,&selectionReason)) {
            if(reason)*reason="Could not select external window Space for native placement: "+selectionReason;
            return false;
        }
        lastSelectedSpace=wholeJournal.runtimeCurrent;
        for(size_t index=0;index<saved.size();index++) {
            const SavedWindow &w=saved[index];
            if(w.slot!=slot || w.space!=selected || w.followerParent)continue;
            WindowState state=WindowState::AXUnavailable;
            bool membership=false;
            for(int settle=0;settle<40;settle++) {
                state=windowState(w);
                membership=state==WindowState::Ready && wholeWindowMembershipMatches(w,cid);
                if(state==WindowState::Gone || membership)break;
                usleep(50000);
            }
            if(state==WindowState::Gone)continue;
            if(state!=WindowState::Ready || !membership) {
                fprintf(stderr,"air_whole_identity_wait wid=%u pid=%d state=%d membership=%d\n",
                    w.id,w.pid,(int)state,(int)membership);
                if(reason)*reason=activationPlacementFailure("whole_identity",w,selected);
                return false;
            }
            if(w.readOnlyCG) {
                CGRect observed={};
                if(!readCGFrame(w.id,w.pid,&observed)
                    || !CGRectContainsRect(CGRectInset(content,-2,-2),observed)) {
                    if(reason)*reason=activationPlacementFailure("whole_read_only_bounds",w,selected);
                    return false;
                }
                continue;
            }
            CGRect observed={};
            bool frameSet=setFrame(w,targets[index]);
            bool settled=false;
            for(int retry=0;frameSet && retry<80;retry++) {
                CGRect axFrame={};
                bool nativeFrame=false;
                if(w.cgOnly) {
                    nativeFrame=exactCGOnlyWindow(w,&axFrame)
                        && nearFrame(axFrame,targets[index]);
                } else {
                    AXUIElementRef ax=findAXWindow(w.pid,w.id);
                    nativeFrame=ax && readAXFrame(ax,&axFrame)
                        && nearFrame(axFrame,targets[index]);
                    if(ax)CFRelease(ax);
                }
                settled=nativeFrame && readCGFrame(w.id,w.pid,&observed)
                    && nearFrame(observed,axFrame)
                    && nearFrame(observed,targets[index])
                    && CGRectContainsRect(CGRectInset(content,-2,-2),observed)
                    && wholeWindowMembershipMatches(w,cid)
                    && windowOnDisplay(w.id,cid,builtinUUID);
                if(settled)break;
                usleep(50000);
            }
            if(!settled) {
                fprintf(stderr,"air_whole_fit_failed wid=%u pid=%d target=%g,%g,%g,%g observed=%g,%g,%g,%g\n",
                    w.id,w.pid,targets[index].origin.x,targets[index].origin.y,
                    targets[index].size.width,targets[index].size.height,
                    observed.origin.x,observed.origin.y,observed.size.width,observed.size.height);
                if(reason)*reason=activationPlacementFailure("whole_native_frame",w,selected);
                return false;
            }
        }
        for(const SavedWindow &w:saved)if(w.slot==slot && w.space==selected && w.followerParent
            && windowState(w)!=WindowState::Gone) {
            CGRect observed={};
            if(!readCGFrame(w.id,w.pid,&observed)
                || !CGRectContainsRect(CGRectInset(content,-2,-2),observed)
                || !wholeWindowMembershipMatches(w,cid)
                || !windowOnDisplay(w.id,cid,builtinUUID)) {
                if(reason)*reason=activationPlacementFailure("whole_follower_frame",w,selected);
                return false;
            }
        }
    }
    return true;
}
extern "C" int air_spaces_activate() {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown)return error("Remote Spaces host is shutting down");
    if(!wholeJournal.original.displays.empty()) {
        int cid=api().conn();
        if(!cid || !api().managed || !api().spaceType || !api().spaceWindows || !api().windowSpaces)
            return error("Whole-Space activation APIs are unavailable; recovery journal retained");
        std::string parkingFailure;
        if(wholeJournal.parkingCount<2 && !ensureWholeParking(cid,&parkingFailure)) {
            if(!journalIOError.empty())return error(("Could not persist whole-Space parking identity: "+journalIOError).c_str());
            return error(("Could not create two verified parking Spaces: "+parkingFailure+
                "; recovery journal retained").c_str());
        }
        auto hooks=wholeHooks(cid);std::string reason;
        while(wholeJournal.forwardDone<4)
            if(!air::whole_space::advanceForward(wholeJournal,hooks,&reason))
                return error((std::string("Whole-Space migration failed: ")+reason).c_str());
        while(wholeFullScreenForwardDone<wholeFullScreenMoves.size())
            if(!advanceWholeFullScreen(false,cid,reason))
                return error((std::string("Fullscreen Space migration failed: ")+reason).c_str());
        air::whole_space::Topology migrated;
        if(!wholeTopology(managed(),wholeDisplayOrder(),migrated)
            || !wholeRuntimeTopologyWithFullScreens(migrated,cid))
            return error("Fullscreen Space migration did not preserve each original owner on the built-in display");
        for(int index=0;index<3;index++)slots[index]=wholeJournal.selected[index];
        lastSelectedSpace=wholeJournal.runtimeCurrent;
        if(!persist())return error(("Could not persist whole-Space slot identities: "+journalIOError).c_str());
        CGRect content=builtInContentBounds();
        if(!placeWholeRuntimeWindows(cid,content,&reason))
            return error((std::string("Whole-Space native window placement failed: ")+reason
                +"; recovery journal retained").c_str());
        uint64_t before=wholeJournal.runtimeCurrent;
        if(!air::whole_space::selectRuntime(wholeJournal,hooks,wholeJournal.selected[0],&reason))
            return error((std::string("Could not select whole-Space slot 1: ")+reason).c_str());
        lastSelectedSpace=wholeJournal.runtimeCurrent;active=true;
        if(before!=wholeJournal.runtimeCurrent)switchVerified=true;
        return 0;
    }
    if(const char *blocked=migrationBlocker())
        return error((std::string("Remote Spaces unavailable: ")+blocked).c_str());
    if(!windowInventoryComplete)
        return error("Spaces preparation window inventory is incomplete; restore before activation");
    // An all-built-in workspace has no windows to migrate; reuse still works.
    int cid=api().conn();
    if(!ensureSlots(cid)) {
        if(!journalIOError.empty())return error(("Could not persist reusable Space identity: "+journalIOError).c_str());
        return error("Could not verify three reusable built-in Spaces within the four-desktop limit");
    }
    if(!ownedSlotsStillOrdered(builtInManaged(managed()),cid))
        return error("A reusable Remote Space changed identity; recovery journal retained");
    if(!persist())return error(("Could not persist Remote Spaces slot identities: "+journalIOError).c_str());
    CGRect content=builtInContentBounds();
    if(CGRectIsNull(content) || content.size.width<100 || content.size.height<100)
        return error("Built-in display content area unavailable");
    std::string placementFailure;
    if(!placeActivationWindows(cid,content,&placementFailure))return error(placementFailure.c_str());
    if(!retainedOrdinaryStillOriginal(cid))
        return error("A retained window left its verified original Space, display, or frame; recovery journal retained");
    if(!ownedSlotsStillOrdered(builtInManaged(managed()),cid))
        return error("A reusable Remote Space changed identity; recovery journal retained");
    uint64_t from=builtInCurrentSpace();
    if(!from)return error("The current built-in Space is unavailable before Remote Space selection");
    if(from!=initialSpace && from!=slots[1] && from!=slots[2])
        return error("The user selected another Space during setup; recovery journal retained");
    lastSelectedSpace=slots[0];
    if(!persist())return error(("Could not record Remote Space 3 before selection: "+journalIOError).c_str());
    if(!switchSpace(slots[0],cid))
        return error("macOS did not select Remote Space 3; recovery journal retained");
    if(from!=slots[0])switchVerified=true;
    NSArray *routeBaseline=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll,kCGNullWindowID));
    if(!routeBaseline || routeBaseline.count>10000)
        return error("Cannot snapshot existing windows for runtime routing; recovery journal retained");
    reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();reusedRoutePending.clear();
    for(NSDictionary *cg in routeBaseline) {
        uint32_t wid=[number(cg[(id)kCGWindowNumber]) unsignedIntValue];
        pid_t pid=[number(cg[(id)kCGWindowOwnerPID]) intValue];
        bool deferred=std::any_of(deferredInvisibleWindows.begin(),deferredInvisibleWindows.end(),
            [&](const DeferredInvisibleWindow &entry) {
                return entry.id==wid && entry.pid==pid && entry.birth==processBirth(pid)
                    && (!entry.space || (exactSingletonMembership(cid,wid,entry.space)
                        && spaceOnDisplay(managed(),entry.space,entry.displayUUID)));
            });
        if(wid && !deferred)reusedRouteBaseline.insert(wid);
    }
    for(NSRunningApplication *running in [NSWorkspace sharedWorkspace].runningApplications)
        if([running.bundleIdentifier isEqualToString:@"com.google.Chrome"])
            reusedRouteBaselineChromePIDs.insert(running.processIdentifier);
    reusedCachedCount.store(3);
    reusedCachedSlot.store(logicalSlotForNativeIndex(0,true));
    reusedCachedLoop.store(loopSupportedLocked() ? 1 : 0);
    nextReusedRouteScan=CFAbsoluteTimeGetCurrent();
    active=true;return 0;
}
extern "C" int air_spaces_reload() {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown)return error("Remote Spaces host is shutting down");
    if(!active || reusedSlots.size()!=3 || !wholeJournal.original.displays.empty())
        return error("An active reusable three-Space session is required");
    int cid=api().conn();
    NSDictionary *display=builtInManaged(managed());
    if(!cid || !ownedSlotsStillOrdered(display,cid))
        return error("A reusable Remote Space changed identity; recovery journal retained");
    CGRect content=builtInContentBounds();
    if(CGRectIsNull(content) || content.size.width<100 || content.size.height<100)
        return error("Built-in display content area unavailable");
    uint64_t returnSpace=builtInCurrentSpace();
    if(std::find(std::begin(slots),std::end(slots),returnSpace)==std::end(slots))
        returnSpace=slots[0];

    // First repair every already journaled window. This is idempotent and
    // preserves its original display/frame for exact disconnect restoration.
    std::string placementFailure;
    if(!placeActivationWindows(cid,content,&placementFailure))
        return error(("Reload Spaces could not repair a journaled window: "+placementFailure).c_str());
    reusedRoutePending.clear();

    // Then sweep all physical displays for windows that the initial pass or a
    // later app launch left behind. Baseline windows are deliberately included.
    for(unsigned pass=0;pass<4;pass++) {
        NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll,kCGNullWindowID));
        if(!windows || windows.count>10000)
            return error("Reload Spaces cannot read the complete window inventory");
        std::vector<SavedWindow> candidates;
        for(NSDictionary *cg in windows) {
            SavedWindow candidate={};
            if(reusedRouteCandidate(cg,cid,candidate,true,true))
                candidates.push_back(std::move(candidate));
        }
        if(candidates.empty())break;
        for(SavedWindow &candidate:candidates) {
            if(std::any_of(saved.begin(),saved.end(),[&](const SavedWindow &w) {
                return w.id==candidate.id;
            }))continue;
            if(candidate.slot<0 || candidate.slot>2 || !slots[candidate.slot])
                return error("Reload Spaces found a window with no physical-display mapping");
            uint64_t target=slots[candidate.slot];
            saved.push_back(candidate);
            if(!persist()) {
                saved.pop_back();
                return error(("Reload Spaces could not journal a window before moving it: "+journalIOError).c_str());
            }
            SavedWindow &record=saved.back();
            if(!sameProcess(record)
                || !(processBirth(record.pid)==ProcessBirth{record.birthSeconds,record.birthMicroseconds})
                || windowState(record)!=WindowState::Ready
                || oneWindowSpace(record.id,cid)!=record.space
                || !move(record.id,target,cid)
                || oneWindowSpace(record.id,cid)!=target) {
                return error("Reload Spaces could not move an exact window; recovery journal retained");
            }
            if(builtInCurrentSpace()!=target) {
                uint64_t prior=lastSelectedSpace;lastSelectedSpace=target;
                if(!persist()) {
                    lastSelectedSpace=prior;
                    return error(("Reload Spaces could not journal its destination Space: "+journalIOError).c_str());
                }
                if(!switchSpace(target,cid))
                    return error("Reload Spaces could not select a destination Space; recovery journal retained");
            }
            CGRect frame=mappedFrame(record,content),observed={};
            bool canPlace=!record.minimized || setWindowMinimizedState(record,false);
            if(CGRectIsNull(frame) || !canPlace || !setFrame(record,frame)
                || !restoreWindowMinimized(record)
                || oneWindowSpace(record.id,cid)!=target
                || !windowOnDisplay(record.id,cid,builtinUUID)
                || !readCGFrame(record.id,record.pid,&observed)
                || !nearFrame(frame,observed)) {
                restoreWindowMinimized(record);
                return error("Reload Spaces could not place an exact window on the built-in display; recovery journal retained");
            }
        }
    }
    if(!retainedOrdinaryStillOriginal(cid))
        return error("A retained window changed while Spaces reloaded; recovery journal retained");
    uint64_t prior=lastSelectedSpace;lastSelectedSpace=returnSpace;
    if(!persist()) {
        lastSelectedSpace=prior;
        return error(("Reload Spaces repaired windows but could not journal the selected Space: "+journalIOError).c_str());
    }
    if(builtInCurrentSpace()!=returnSpace && !switchSpace(returnSpace,cid))
        return error("Reload Spaces repaired windows but could not restore the selected Space");

    NSArray *baseline=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll,kCGNullWindowID));
    if(!baseline || baseline.count>10000)
        return error("Reload Spaces repaired windows but could not refresh its launch baseline");
    reusedRouteBaseline.clear();reusedRouteBaselineChromePIDs.clear();
    for(NSDictionary *cg in baseline) {
        uint32_t wid=[number(cg[(id)kCGWindowNumber]) unsignedIntValue];
        if(wid)reusedRouteBaseline.insert(wid);
    }
    for(NSRunningApplication *running in [NSWorkspace sharedWorkspace].runningApplications)
        if([running.bundleIdentifier isEqualToString:@"com.google.Chrome"])
            reusedRouteBaselineChromePIDs.insert(running.processIdentifier);
    int physical=(int)(std::find(std::begin(slots),std::end(slots),returnSpace)-std::begin(slots));
    reusedCachedSlot.store(logicalSlotForNativeIndex(physical,true));
    reusedCachedCount.store(3);
    return 0;
}
extern "C" int air_spaces_select(int slot) {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown)return error("Remote Spaces host is shutting down");
    if(!wholeJournal.original.displays.empty()) {
        if(!active || slot<1 || slot>3+(int)wholeFullScreens.size())
            return error("Whole-Space slot is not active");
        int cid=api().conn();std::string reason;
        if(!reconcileWholeFullScreenRuntimePending(cid,reason)
            || !adoptObservedWholeRuntimeSelection(cid))
            return error("Whole-Space selection topology or fullscreen owner changed");
        if(slot>3) {
            int index=slot-4;
            if(wholeFullScreenRuntimeIndex>=0 && wholeFullScreenRuntimeIndex!=index
                && !selectWholeFullScreenRuntime(-1,cid,reason))
                return error(("Could not leave the selected fullscreen Space: "+reason).c_str());
            if(!selectWholeFullScreenRuntime(index,cid,reason))
                return error(("Could not select the fullscreen Space: "+reason).c_str());
            switchVerified=true;
            return 0;
        }
        if(wholeFullScreenRuntimeIndex>=0
            && !selectWholeFullScreenRuntime(-1,cid,reason))
            return error(("Could not leave the selected fullscreen Space: "+reason).c_str());
        auto hooks=wholeHooks(cid);
        uint64_t before=wholeJournal.runtimeCurrent,target=wholeJournal.selected[slot-1];
        if(!air::whole_space::selectRuntime(wholeJournal,hooks,target,&reason))
            return error((std::string("Whole-Space selection failed: ")+reason).c_str());
        lastSelectedSpace=wholeJournal.runtimeCurrent;
        if(before!=wholeJournal.runtimeCurrent)switchVerified=true;
        return 0;
    }
    if(const char *blocked=migrationBlocker())
        return error((std::string("Remote Spaces unavailable: ")+blocked).c_str());
    if(!active || slot<1 || slot>3)return error("Spaces slot is not active");
    int nativeSlot=nativeIndexForLogicalSlot(slot,!reusedSlots.empty());
    if(nativeSlot<0)return error("Spaces slot mapping is invalid");
    uint64_t sid=slots[nativeSlot];int cid=api().conn();
    NSDictionary *display=builtInManaged(managed());
    if(!ownedSlotsStillOrdered(display,cid))
        return error("A reusable Remote Space changed identity");
    uint64_t prior=lastSelectedSpace;
    uint64_t from=builtInCurrentSpace();
    lastSelectedSpace=sid;
    if(!persist()) {
        lastSelectedSpace=prior;
        return error(("Cannot record the selected Space for recovery: "+journalIOError).c_str());
    }
    if(!switchSpace(sid,cid))return error("macOS did not switch to the selected built-in Space; recovery journal retained");
    if(from && from!=sid)switchVerified=true;
    return 0;
}
extern "C" int air_spaces_transfer_window_edge(uint32_t windowID,int startingSlot,int direction) {
    std::lock_guard<std::mutex> lock(mutex);
    if(shuttingDown || !active || !wholeFrameInventoryComplete
        || wholeJournal.original.displays.empty() || journalLockFD<0
        || !api().conn || !api().managed || !api().windowSpaces
        || !api().spaceType || !api().axWindow)
        return error("Edge transfer requires an active, fully journaled three-Space session");
    if(!windowID || (direction!=-1 && direction!=1) || startingSlot<1
        || startingSlot>3 || startingSlot+direction<1 || startingSlot+direction>3)
        return error("Edge transfer requires one adjacent Remote Space");
    int cid=api().conn();
    if(wholeFullScreenRuntimeIndex>=0 || wholeFullScreenRuntimePending.active
        || wholeJournal.pending.active || wholeJournal.runtimeSelectionPending.active
        || wholeJournal.reverseDone || wholeJournal.forwardDone!=4
        || missionState()!=MissionState::Absent
        || !adoptObservedWholeRuntimeSelection(cid))
        return error("Edge transfer cannot verify the current ordinary Remote Space");
    uint64_t from=wholeJournal.selected[startingSlot-1];
    uint64_t target=wholeJournal.selected[startingSlot+direction-1];
    if(!from || !target || from==target
        || (wholeJournal.runtimeCurrent!=from && wholeJournal.runtimeCurrent!=target)
        || currentSpaceForDisplay(managed(),builtinUUID)!=wholeJournal.runtimeCurrent
        || api().spaceType(cid,from)!=0 || api().spaceType(cid,target)!=0
        || !spaceOnDisplay(managed(),from,builtinUUID)
        || !spaceOnDisplay(managed(),target,builtinUUID))
        return error("Edge transfer source or adjacent Space changed");
    auto window=std::find_if(saved.begin(),saved.end(),[&](const SavedWindow &w){
        return w.id==windowID;
    });
    uint64_t releaseSpace=window==saved.end() ? 0 : oneWindowSpace(windowID,cid);
    std::string releaseDisplay=window==saved.end() ? "" : edgeObservedDisplay(windowID,cid);
    CGRect releaseFrame={};
    bool releaseKnown=false;
    for(const auto &display:wholeJournal.original.displays)
        if(display.uuid==releaseDisplay && std::find(display.order.begin(),display.order.end(),
            releaseSpace)!=display.order.end())releaseKnown=true;
    if(releaseDisplay==builtinUUID && (releaseSpace==from || releaseSpace==target))
        releaseKnown=true;
    if(window==saved.end() || !releaseKnown
        || (wholeJournal.runtimeCurrent==from && releaseSpace!=from
            && releaseSpace!=target && releaseDisplay==builtinUUID)
        || (wholeJournal.runtimeCurrent==target && releaseSpace!=target)
        || !edgeObservedFrame(*window,&releaseFrame)
        || !edgeWindowEligible(*window,releaseSpace,cid,false))
        return error("Edge transfer window is not an exact journaled ordinary window without unknown companions");
    CGRect runtime=edgeRehomeFrame(releaseFrame,builtInContentBounds());
    if(CGRectIsNull(runtime))
        return error("Edge transfer window cannot fit within the built-in display");
    auto record=std::find_if(edgeTransfers.begin(),edgeTransfers.end(),
        [&](const EdgeTransfer &entry){return entry.window==windowID;});
    if(record!=edgeTransfers.end() && (record->stage!=3 || record->target!=from
        || record->original!=window->space))
        return error("An earlier edge transfer needs reconciliation before another move");
    EdgeTransfer intent={windowID,window->space,from,target,1,
        releaseSpace,releaseDisplay,releaseFrame};
    std::vector<EdgeTransfer> priorTransfers=edgeTransfers;
    if(record==edgeTransfers.end())edgeTransfers.push_back(intent);
    else *record=intent;
    if(!persist()) {
        edgeTransfers=std::move(priorTransfers);
        return error(("Could not journal edge transfer intent: "+journalIOError).c_str());
    }
    CGRect still={};
    if(!edgeWindowEligible(*window,releaseSpace,cid,false)
        || edgeObservedDisplay(windowID,cid)!=releaseDisplay
        || !edgeObservedFrame(*window,&still) || !nearFrame(still,releaseFrame)
        || CGRectIsNull(runtime) || !setFrame(*window,runtime)
        || !windowOnDisplay(windowID,cid,builtinUUID)
        || (oneWindowSpace(windowID,cid)!=releaseSpace
            && oneWindowSpace(windowID,cid)!=from
            && oneWindowSpace(windowID,cid)!=target)
        || !move(windowID,target,cid)
        || oneWindowSpace(windowID,cid)!=target
        || !windowOnDisplay(windowID,cid,builtinUUID))
        return error("The exact window did not move to the adjacent Space; recovery journal retained");
    record=std::find_if(edgeTransfers.begin(),edgeTransfers.end(),
        [&](const EdgeTransfer &entry){return entry.window==windowID;});
    record->stage=2;
    if(!persist())return error(("Could not journal completed window move: "+journalIOError).c_str());
    auto hooks=wholeHooks(cid);std::string reason;
    if(!air::whole_space::selectRuntime(wholeJournal,hooks,target,&reason))
        return error(("The adjacent Space could not be selected: "+reason
            +"; recovery journal retained").c_str());
    lastSelectedSpace=wholeJournal.runtimeCurrent;
    bool visible=false;
    for(int retry=0;retry<40;retry++) {
        if(oneWindowSpace(windowID,cid)==target
            && windowOnDisplay(windowID,cid,builtinUUID)
            && edgeWindowVisible(windowID)) {visible=true;break;}
        usleep(50000);
    }
    if(!visible || currentSpaceForDisplay(managed(),builtinUUID)!=target)
        return error("The moved window is not visible in the selected adjacent Space; recovery journal retained");
    record->stage=3;
    if(!persist())return error(("Could not journal selected edge-transfer destination: "+journalIOError).c_str());
    return 0;
}
extern "C" int air_spaces_loop_supported() {
    std::unique_lock<std::mutex> lock(mutex,std::defer_lock);
    if(reusedCachedCount.load()>0) {
        if(!lock.try_lock())return reusedCachedLoop.load();
    } else lock.lock();
    int result=loopSupportedLocked() ? 1 : 0;
    if(active && !reusedSlots.empty())reusedCachedLoop.store(result);
    return result;
}
extern "C" int air_spaces_wrap_boundary(int startingSlot,int direction) {
    std::lock_guard<std::mutex> lock(mutex);
    if(!loopSupportedLocked())return error("Remote Space looping has no verified switch in this session");
    if(direction!=-1 && direction!=1)return error("Invalid Remote Space loop direction");
    if((startingSlot!=1 || direction!=-1) && (startingSlot!=3 || direction!=1))return 0;
    if(missionState()!=MissionState::Absent)return error("Mission Control must be verified closed before looping Spaces");
    if(!wholeJournal.original.displays.empty()) {
        if(wholeJournal.runtimeCurrent!=wholeJournal.selected[startingSlot-1])return 0;
        uint64_t target=direction<0 ? wholeJournal.selected[2] : wholeJournal.selected[0];
        auto hooks=wholeHooks(api().conn());std::string reason;
        if(!air::whole_space::selectRuntime(wholeJournal,hooks,target,&reason))
            return error((std::string("Whole-Space wrap failed: ")+reason).c_str());
        lastSelectedSpace=wholeJournal.runtimeCurrent;return 1;
    }
    NSDictionary *display=builtInManaged(managed());
    if(![managedDisplayUUID(display) isEqualToString:[NSString stringWithUTF8String:builtinUUID.c_str()]])
        return error("The original built-in display is unavailable for Space looping");
    if(!ownedSlotsStillOrdered(display,api().conn()))
        return error("A reusable Remote Space changed identity");
    bool reversed=!reusedSlots.empty();
    int startingNative=nativeIndexForLogicalSlot(startingSlot,reversed);
    int targetLogical=direction<0 ? 3 : 1;
    int targetNative=nativeIndexForLogicalSlot(targetLogical,reversed);
    uint64_t current=[number(dictionary(display[@"Current Space"])[@"id64"]) unsignedLongLongValue];
    if(startingNative<0 || targetNative<0 || current!=slots[startingNative])return 0;
    uint64_t target=slots[targetNative];
    uint64_t prior=lastSelectedSpace;
    lastSelectedSpace=target;
    if(!persist()) {
        lastSelectedSpace=prior;
        return error(("Cannot journal the wrapped Space: "+journalIOError).c_str());
    }
    if(builtInCurrentSpace()!=slots[startingNative]) {
        lastSelectedSpace=prior;
        if(!persist())return error(("Cannot restore the prior Space journal after a changed desktop: "+journalIOError).c_str());
        return 0;
    }
    if(!switchSpace(target,api().conn()))return error("macOS did not wrap to the verified built-in Space; recovery journal retained");
    return 1;
}
extern "C" int air_spaces_restore() {
    std::lock_guard<std::mutex> lock(mutex);
    if(saved.empty() && ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()])return 0;
    if(!acquireJournalLock())return error(("Spaces recovery ownership unavailable: "+journalIOError).c_str());
    if(saved.empty() && !loadJournal())return error("Spaces recovery journal is invalid; it was retained for manual inspection");
    return restoreWithSettlingRetryLocked();
}
extern "C" int air_spaces_shutdown() {
    std::lock_guard<std::mutex> lock(mutex);
    shuttingDown=true;switchVerified=false;pendingDisplayRecovery=false;++recoveryGeneration;++retryBurst;
    if(saved.empty() && ![[NSFileManager defaultManager] fileExistsAtPath:journalPath()]) {
        releaseJournalLock();return 0;
    }
    if(!acquireJournalLock())return error(("Spaces recovery ownership unavailable: "+journalIOError).c_str());
    if(saved.empty() && !loadJournal())
        return error("Spaces recovery journal is invalid; it was retained for manual inspection");
    return restoreWithSettlingRetryLocked();
}
extern "C" uint64_t air_spaces_slot_id(int slot) {
    std::lock_guard<std::mutex> lock(mutex);
    if(slot<1 || !active || !api().conn)return 0;
    if(!wholeJournal.original.displays.empty()) {
        if(slot>3+(int)wholeFullScreens.size()
            || !adoptObservedWholeRuntimeSelection(api().conn()))return 0;
        air::whole_space::Topology topology;
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeRuntimeTopologyWithFullScreens(topology,api().conn()))return 0;
        return slot<=3 ? wholeJournal.selected[slot-1] : wholeFullScreens[slot-4].sid;
    }
    if(slot>3)return 0;
    if(!ownedSlotsStillOrdered(builtInManaged(managed()),api().conn()))return 0;
    int nativeSlot=nativeIndexForLogicalSlot(slot,!reusedSlots.empty());
    return nativeSlot<0 ? 0 : slots[nativeSlot];
}
extern "C" int air_spaces_current_slot() {
    std::unique_lock<std::mutex> lock(mutex,std::defer_lock);
    if(reusedCachedCount.load()>0) {
        if(!lock.try_lock())return reusedCachedSlot.load();
    } else lock.lock();
    if(shuttingDown || !active || !api().conn || !api().managed)return 0;
    NSDictionary *display=builtInManaged(managed());
    if(!wholeJournal.original.displays.empty()) {
        routeRuntimeLaunches(api().conn());
        if(!adoptObservedWholeRuntimeSelection(api().conn()))return 0;
        air::whole_space::Topology topology;
        if(!wholeTopology(managed(),wholeDisplayOrder(),topology)
            || !wholeRuntimeTopologyWithFullScreens(topology,api().conn()))return 0;
        if(wholeFullScreenRuntimeIndex>=0)return 4+wholeFullScreenRuntimeIndex;
    } else if(!ownedSlotsStillOrdered(display,api().conn()))return 0;
    NSDictionary *current=dictionary(display[@"Current Space"]);
    uint64_t sid=[number(current[@"id64"]) unsignedLongLongValue];
    for(int slot=0;slot<3;slot++)if(sid && sid==slots[slot]) {
        if(lastSelectedSpace!=sid) {
            uint64_t prior=lastSelectedSpace;
            lastSelectedSpace=sid;
            if(!persist()) {
                lastSelectedSpace=prior;
                error(("Could not persist current Remote Space: "+journalIOError).c_str());
                return 0;
            }
        }
        int result=logicalSlotForNativeIndex(slot,!reusedSlots.empty());
        if(!reusedSlots.empty()) {
            reusedCachedSlot.store(result);
            reusedCachedLoop.store(loopSupportedLocked() ? 1 : 0);
            CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
            if(now>=nextReusedRouteScan && !reusedRouteBusy.exchange(true)) {
                nextReusedRouteScan=now+0.5;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                    @autoreleasepool {
                        struct BusyReset { ~BusyReset(){reusedRouteBusy.store(false);} } reset;
                        {
                            std::lock_guard<std::mutex> routeLock(mutex);
                            if(active && !shuttingDown && reusedSlots.size()==3 && api().conn)
                                routeOneReusedWindow(api().conn());
                        }
                    }
                });
            }
        }
        return result;
    }
    if(!reusedSlots.empty())reusedCachedSlot.store(0);
    return 0;
}
extern "C" int air_spaces_slot_count() {
    std::unique_lock<std::mutex> lock(mutex,std::defer_lock);
    if(reusedCachedCount.load()>0) {
        if(!lock.try_lock())return reusedCachedCount.load();
    } else lock.lock();
    if(!active)return 0;
    int result=wholeJournal.original.displays.empty() ? 3 : 3+(int)wholeFullScreens.size();
    if(!reusedSlots.empty())reusedCachedCount.store(result);
    return result;
}
