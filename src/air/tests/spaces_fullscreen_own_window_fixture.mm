#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <dlfcn.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

@interface NSObject (FixtureSpaceSelection)
- (id)initWithDisplayIdentifier:(NSString *)displayIdentifier spaceID:(unsigned long long)spaceID;
- (void)performWithWMBridgeDelegate;
@end

// Disposable, single-window fixture. Compile only until the coordinator schedules
// a visible test. The controller refuses every target except this exact binary.
static NSString *const fixtureTitle=@"RustDesk Air Fullscreen Fixture";
static NSString *const fixtureIdentifier=@"rustdesk-air.fullscreen-fixture.window";
static NSWindow *fixtureWindow=nil;
using AXWindowID=AXError (*)(AXUIElementRef,CGWindowID *);
using Connection=int (*)();
using WindowSpaces=CFArrayRef (*)(int,int,CFArrayRef);
using SpaceType=int (*)(int,uint64_t);
using WindowDisplay=CFStringRef (*)(int,uint32_t);
using ManagedDisplays=CFArrayRef (*)(int);

static NSDictionary *managedDisplay(NSString *uuid) {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    Connection connection=sky ? (Connection)dlsym(sky,"SLSMainConnectionID") : nullptr;
    ManagedDisplays copy=sky ? (ManagedDisplays)dlsym(sky,"SLSCopyManagedDisplaySpaces") : nullptr;
    if(!connection || !copy)return nil;
    NSArray *all=CFBridgingRelease(copy(connection()));
    for(NSDictionary *display in all)
        if([display[@"Display Identifier"] isEqual:uuid])return display;
    return nil;
}

static AXWindowID axWindowID() {
    void *app=dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",RTLD_LAZY);
    return app ? (AXWindowID)dlsym(app,"_AXUIElementGetWindow") : nullptr;
}
static NSDictionary *membership(CGWindowID wid) {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    Connection connection=sky ? (Connection)dlsym(sky,"SLSMainConnectionID") : nullptr;
    WindowSpaces spaces=sky ? (WindowSpaces)dlsym(sky,"SLSCopySpacesForWindows") : nullptr;
    SpaceType type=sky ? (SpaceType)dlsym(sky,"SLSSpaceGetType") : nullptr;
    WindowDisplay display=sky ? (WindowDisplay)dlsym(sky,"SLSCopyManagedDisplayForWindow") : nullptr;
    if(!wid || !connection || !spaces)return @{@"status":@"unavailable"};
    int cid=connection();
    NSArray *ids=CFBridgingRelease(spaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    if(!ids)return @{@"status":@"unreadable"};
    NSMutableArray *kinds=[NSMutableArray array];
    for(NSNumber *sid in ids)[kinds addObject:type ? @(type(cid,sid.unsignedLongLongValue)) : (id)NSNull.null];
    NSString *uuid=display ? CFBridgingRelease(display(cid,wid)) : nil;
    return @{@"status":@"ok",@"ids":ids,@"types":kinds,@"display_uuid":uuid ?: (id)NSNull.null};
}
static id axValue(AXUIElementRef element,CFStringRef key) {
    CFTypeRef raw=nullptr;
    return AXUIElementCopyAttributeValue(element,key,&raw)==kAXErrorSuccess ? CFBridgingRelease(raw) : nil;
}
static id axFrame(AXUIElementRef window) {
    id rawPosition=axValue(window,kAXPositionAttribute),rawSize=axValue(window,kAXSizeAttribute);
    CGPoint point={};CGSize size={};
    if(!rawPosition || !rawSize || CFGetTypeID((__bridge CFTypeRef)rawPosition)!=AXValueGetTypeID()
        || CFGetTypeID((__bridge CFTypeRef)rawSize)!=AXValueGetTypeID()
        || !AXValueGetValue((__bridge AXValueRef)rawPosition,kAXValueTypeCGPoint,&point)
        || !AXValueGetValue((__bridge AXValueRef)rawSize,kAXValueTypeCGSize,&size))return NSNull.null;
    return @[@(point.x),@(point.y),@(size.width),@(size.height)];
}
static AXUIElementRef uniqueWindow(pid_t pid,CGWindowID *wid) {
    if(wid)*wid=0;
    AXUIElementRef app=AXUIElementCreateApplication(pid);
    if(!app)return nullptr;
    AXUIElementSetMessagingTimeout(app,0.5);
    NSArray *windows=(NSArray *)axValue(app,kAXWindowsAttribute);
    CFRelease(app);
    AXUIElementRef match=nullptr;
    unsigned count=0;
    for(id candidate in windows) {
        AXUIElementRef window=(__bridge AXUIElementRef)candidate;
        if(![(NSString *)axValue(window,kAXTitleAttribute) isEqualToString:fixtureTitle])continue;
        count++;
        if(count==1) {
            match=(AXUIElementRef)CFRetain(window);
            AXWindowID getID=axWindowID();
            if(wid && getID)getID(window,wid);
        }
    }
    if(count==1)return match;
    if(match)CFRelease(match);
    return nullptr;
}
static void emit(NSDictionary *value) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if(json) { fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);fflush(stdout); }
}
static NSDictionary *axSnapshot(pid_t pid) {
    CGWindowID wid=0;
    AXUIElementRef window=uniqueWindow(pid,&wid);
    if(!window)return @{@"pid":@(pid),@"ax_window":@"missing_or_ambiguous",@"trusted":@(AXIsProcessTrusted())};
    Boolean settable=false;
    AXError setError=AXUIElementIsAttributeSettable(window,CFSTR("AXFullScreen"),&settable);
    id fullscreen=axValue(window,CFSTR("AXFullScreen"));
    id title=axValue(window,kAXTitleAttribute);
    id identifier=axValue(window,kAXIdentifierAttribute);
    id role=axValue(window,kAXRoleAttribute);
    id subrole=axValue(window,kAXSubroleAttribute);
    id document=axValue(window,kAXDocumentAttribute);
    NSDictionary *result=@{@"pid":@(pid),@"trusted":@(AXIsProcessTrusted()),
        @"ax_window":@"unique",@"window_id":@(wid),@"ax_fullscreen":fullscreen ?: (id)NSNull.null,
        @"settable":@(setError==kAXErrorSuccess && settable),@"settable_error":@(setError),
        @"title":title ?: (id)NSNull.null,@"role":role ?: (id)NSNull.null,
        @"identifier":identifier ?: (id)NSNull.null,
        @"subrole":subrole ?: (id)NSNull.null,@"document":document ?: (id)NSNull.null,
        @"ax_frame":axFrame(window),
        @"membership":membership(wid)};
    CFRelease(window);
    return result;
}
static bool sameFixtureBinary(pid_t pid) {
    char target[PROC_PIDPATHINFO_MAXSIZE]={},own[PROC_PIDPATHINFO_MAXSIZE]={};
    return proc_pidpath(pid,target,sizeof(target))>0 && proc_pidpath(getpid(),own,sizeof(own))>0
        && strcmp(target,own)==0 && pid!=getpid();
}
static int probe(pid_t pid,const char *action) {
    if(!sameFixtureBinary(pid)) { emit(@{@"error":@"target_is_not_own_fixture_binary"});return 2; }
    NSDictionary *before=axSnapshot(pid);
    emit(@{@"phase":@"before",@"snapshot":before});
    if(strcmp(action,"read")==0)return 0;
    if(strcmp(action,"enter")!=0 && strcmp(action,"exit")!=0)return 2;
    if(!AXIsProcessTrusted() || ![before[@"ax_window"] isEqualToString:@"unique"]
        || ![before[@"identifier"] isEqualToString:fixtureIdentifier]
        || ![before[@"settable"] boolValue])return 3;
    bool desired=strcmp(action,"enter")==0;
    if(before[@"ax_fullscreen"]==NSNull.null || [before[@"ax_fullscreen"] boolValue]==desired)return 3;
    CGWindowID wid=0;
    AXUIElementRef window=uniqueWindow(pid,&wid);
    if(!window)return 3;
    AXError status=AXUIElementSetAttributeValue(window,CFSTR("AXFullScreen"),desired?kCFBooleanTrue:kCFBooleanFalse);
    CFRelease(window);
    emit(@{@"phase":@"set",@"status":@(status),@"requested":@(desired)});
    if(status!=kAXErrorSuccess)return 4;
    for(int i=0;i<80;i++) {
        usleep(100000);
        NSDictionary *after=axSnapshot(pid);
        if([after[@"ax_window"] isEqualToString:@"unique"]
            && after[@"ax_fullscreen"]!=NSNull.null
            && [after[@"ax_fullscreen"] boolValue]==desired) {
            emit(@{@"phase":@"verified",@"snapshot":after});return 0;
        }
    }
    emit(@{@"phase":@"timeout",@"snapshot":axSnapshot(pid)});
    return 5;
}
static int selectOwnFullScreen(pid_t pid,uint64_t anchor,const char *action) {
    if(!sameFixtureBinary(pid) || !anchor || !AXIsProcessTrusted())return 2;
    NSDictionary *before=axSnapshot(pid),*members=before[@"membership"];
    if(![before[@"ax_window"] isEqual:@"unique"]
        || ![before[@"identifier"] isEqual:fixtureIdentifier]
        || ![before[@"ax_fullscreen"] isEqual:@YES]
        || [members[@"ids"] count]!=1 || [members[@"types"] count]!=1
        || ![members[@"types"][0] isEqual:@4])return 3;
    NSString *uuid=members[@"display_uuid"];
    if(![uuid isKindOfClass:NSString.class])return 3;
    // Only the fixture's observed external display is eligible.
    bool external=false;
    for(NSScreen *screen in NSScreen.screens) {
        uint32_t did=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef id=CGDisplayCreateUUIDFromDisplayID(did);
        NSString *candidate=id ? CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,id)) : nil;
        if(id)CFRelease(id);
        if([candidate isEqual:uuid] && !CGDisplayIsBuiltin(did))external=true;
    }
    NSDictionary *display=managedDisplay(uuid);
    uint64_t full=[members[@"ids"][0] unsignedLongLongValue];
    uint64_t current=[display[@"Current Space"][@"id64"] unsignedLongLongValue];
    bool foundAnchor=false,foundFull=false;
    for(NSDictionary *space in display[@"Spaces"]) {
        uint64_t sid=[space[@"id64"] unsignedLongLongValue];
        if(sid==anchor && [space[@"type"] intValue]==0)foundAnchor=true;
        if(sid==full && [space[@"type"] intValue]==4)foundFull=true;
    }
    bool toFull=strcmp(action,"fullscreen")==0;
    bool roundtrip=strcmp(action,"roundtrip")==0;
    if(!toFull && !roundtrip && strcmp(action,"anchor")!=0)return 2;
    if(!external || !foundAnchor || !foundFull || (current!=anchor && current!=full))return 3;
    Class cls=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    if(!cls || ![cls instancesRespondToSelector:@selector(initWithDisplayIdentifier:spaceID:)]
        || ![cls instancesRespondToSelector:@selector(performWithWMBridgeDelegate)])return 4;
    NSArray *targets=roundtrip ? @[@(anchor),@(full)] : @[@(toFull ? full : anchor)];
    CGWindowID observedWID=[before[@"window_id"] unsignedIntValue];
    for(NSNumber *targetID in targets) {
    uint64_t target=targetID.unsignedLongLongValue;
    // AX may omit a hidden fullscreen window. Revalidate the exact PID/WID
    // against WindowServer; no title matching or replacement-window search.
    bool ownerMatches=false;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    for(NSDictionary *window in windows)
        if([window[(id)kCGWindowNumber] unsignedIntValue]==observedWID
            && [window[(id)kCGWindowOwnerPID] intValue]==pid)ownerMatches=true;
    if(!sameFixtureBinary(pid) || !ownerMatches || ![membership(observedWID) isEqual:members])return 6;
    NSDictionary *now=managedDisplay(uuid);
    uint64_t selected=[now[@"Current Space"][@"id64"] unsignedLongLongValue];
    if(selected!=anchor && selected!=full)return 6;
    emit(@{@"phase":@"select_before",@"snapshot":before,@"display":now,@"target":@(target)});
    id operation=[[cls alloc] initWithDisplayIdentifier:uuid spaceID:target];
    if(!operation)return 4;
    [operation performWithWMBridgeDelegate];
    bool reached=false;
    for(int i=0;i<80;i++) {
        usleep(25000);
        NSDictionary *after=managedDisplay(uuid);
        if([after[@"Current Space"][@"id64"] unsignedLongLongValue]==target) {
            NSDictionary *snapshot=axSnapshot(pid);
            bool intact=[membership(observedWID) isEqual:members];
            emit(@{@"phase":@"select_after",@"display":after,@"snapshot":snapshot,@"window_intact":@(intact)});
            if(!intact)return 6;
            reached=true;break;
        }
    }
    if(reached)continue;
    emit(@{@"phase":@"select_timeout",@"display":managedDisplay(uuid) ?: @{},@"snapshot":axSnapshot(pid)});
    return 5;
    }
    if(roundtrip) {
        for(int i=0;i<40;i++) {
            NSDictionary *last=axSnapshot(pid);
            if([last[@"window_id"] isEqual:before[@"window_id"]]
                && [last[@"ax_fullscreen"] isEqual:@YES]
                && [last[@"membership"] isEqual:members]) {
                emit(@{@"phase":@"roundtrip_verified",@"snapshot":last});return 0;
            }
            usleep(50000);
        }
        return 7;
    }
    return 0;
}
static void appSnapshot(NSString *phase) {
    NSScreen *screen=fixtureWindow.screen;
    NSNumber *displayID=screen.deviceDescription[@"NSScreenNumber"];
    NSRect frame=fixtureWindow.frame;
    emit(@{@"phase":phase,@"pid":@(getpid()),@"window_id":@(fixtureWindow.windowNumber),
        @"appkit_fullscreen":@((fixtureWindow.styleMask & NSWindowStyleMaskFullScreen)!=0),
        @"frame":@[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)],
        @"display_id":displayID ?: (id)NSNull.null,
        @"membership":membership((CGWindowID)fixtureWindow.windowNumber)});
}
static void finishFixture() {
    if((fixtureWindow.styleMask & NSWindowStyleMaskFullScreen)!=0) {
        [fixtureWindow toggleFullScreen:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            [fixtureWindow close];[NSApp terminate:nil];
        });
    } else {
        [fixtureWindow close];[NSApp terminate:nil];
    }
}
static int appMain(uint32_t selectedDisplay) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSScreen *chosen=nil;
    for(NSScreen *screen in NSScreen.screens) {
        uint32_t did=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if(did && !CGDisplayIsBuiltin(did) && (!selectedDisplay || did==selectedDisplay)) {
            chosen=screen;break;
        }
    }
    if(!chosen) { emit(@{@"error":@"external_display_unavailable"});return 2; }
    NSRect area=chosen.visibleFrame;
    NSRect frame=NSMakeRect(NSMidX(area)-230,NSMidY(area)-150,460,300);
    fixtureWindow=[[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO screen:chosen];
    fixtureWindow.title=fixtureTitle;
    fixtureWindow.releasedWhenClosed=NO;
    fixtureWindow.accessibilityIdentifier=fixtureIdentifier;
    fixtureWindow.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    NSTextField *label=[NSTextField labelWithString:@"Disposable fullscreen identity test"]; 
    label.frame=NSMakeRect(30,125,400,40);
    [fixtureWindow.contentView addSubview:label];
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    for(NSString *event in @[NSWindowDidEnterFullScreenNotification,NSWindowDidExitFullScreenNotification]) {
        [center addObserverForName:event object:fixtureWindow queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            appSnapshot(note.name);
        }];
    }
    [fixtureWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    appSnapshot(@"opened");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        char command[32];
        while(fgets(command,sizeof(command),stdin)) {
            char op=command[0];
            dispatch_async(dispatch_get_main_queue(),^{
                if(op=='f' || op=='n') {
                    bool fullscreen=(fixtureWindow.styleMask & NSWindowStyleMaskFullScreen)!=0;
                    if(fullscreen!=(op=='f'))[fixtureWindow toggleFullScreen:nil];
                } else if(op=='q') {
                    finishFixture();
                } else if(op=='s')appSnapshot(@"requested_snapshot");
            });
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        appSnapshot(@"deadline");
        finishFixture();
    });
    [NSApp run];
    return 0;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc>=3 && strcmp(argv[1],"--app")==0)return appMain((uint32_t)strtoul(argv[2],nullptr,10));
    if(argc==4 && strcmp(argv[1],"--probe")==0)return probe((pid_t)strtol(argv[2],nullptr,10),argv[3]);
    if(argc==5 && strcmp(argv[1],"--select")==0)
        return selectOwnFullScreen((pid_t)strtol(argv[2],nullptr,10),strtoull(argv[3],nullptr,10),argv[4]);
    fprintf(stderr,"usage: %s --app EXTERNAL_DISPLAY_ID | --probe FIXTURE_PID read|enter|exit\n",argv[0]);
    return 2;
} }
