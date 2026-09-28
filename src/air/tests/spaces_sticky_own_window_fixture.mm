#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <unistd.h>

using Connection = int (*)();
using WindowSpaces = CFArrayRef (*)(int,int,CFArrayRef);
using WindowDisplay = CFStringRef (*)(int,uint32_t);
using Managed = CFArrayRef (*)(int);

static NSWindow *fixtureWindow;
static NSDictionary *baseline;
static NSDictionary *lastSample;
static NSDate *started;
static NSString *targetDisplay;
static NSString *builtinDisplay;
static bool sawTopologyChange=false;
static bool sawBuiltinOwner=false;
static Connection connection;
static WindowSpaces windowSpaces;
static WindowDisplay windowDisplay;
static Managed managed;

static NSString *uuidForDisplay(CGDirectDisplayID display) {
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);
    if(!uuid)return nil;
    CFStringRef text=CFUUIDCreateString(kCFAllocatorDefault,uuid);
    CFRelease(uuid);
    return CFBridgingRelease(text);
}

static void emit(NSString *event,NSDictionary *sample) {
    NSDictionary *line=@{@"event":event,@"sample":sample ?: (id)NSNull.null};
    NSData *data=[NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:nil];
    if(data) {
        fwrite(data.bytes,1,data.length,stdout);
        fputc('\n',stdout);fflush(stdout);
    }
}

static NSDictionary *snapshot() {
    if(!fixtureWindow || !connection || !windowSpaces || !windowDisplay || !managed)return nil;
    uint32_t wid=(uint32_t)fixtureWindow.windowNumber;
    int cid=connection();
    NSArray *members=CFBridgingRelease(windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    NSString *owner=CFBridgingRelease(windowDisplay(cid,wid));
    NSArray *managedDisplays=CFBridgingRelease(managed(cid));
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow,wid));
    NSDictionary *info=nil;
    for(NSDictionary *candidate in windows)
        if([candidate[(id)kCGWindowNumber] unsignedIntValue]==wid
            && [candidate[(id)kCGWindowOwnerPID] intValue]==getpid()) {info=candidate;break;}
    CGRect frame={};
    if(!members || !owner || managedDisplays.count!=3 || !info || !CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&frame))return nil;
    NSMutableArray *topology=NSMutableArray.array;
    for(NSDictionary *display in managedDisplays) {
        NSString *uuid=display[@"Display Identifier"];
        NSArray *spaces=display[@"Spaces"];
        if(![uuid isKindOfClass:NSString.class] || ![spaces isKindOfClass:NSArray.class])return nil;
        NSMutableArray *order=NSMutableArray.array;
        for(NSDictionary *space in spaces) {
            NSNumber *sid=space[@"id64"];
            if(![sid isKindOfClass:NSNumber.class] || !sid.unsignedLongLongValue)return nil;
            [order addObject:sid];
        }
        [topology addObject:@{@"display":uuid,@"order":order}];
    }
    [topology sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"display" ascending:YES]]];
    NSMutableArray *ids=NSMutableArray.array;
    for(id raw in members) {
        if(![raw isKindOfClass:NSNumber.class] || ![raw unsignedLongLongValue])return nil;
        [ids addObject:raw];
    }
    [ids sortUsingSelector:@selector(compare:)];
    for(NSUInteger index=1;index<ids.count;index++)if([ids[index] isEqual:ids[index-1]])return nil;
    return @{@"wid":@(wid),@"pid":@(getpid()),@"memberships":ids,@"topology":topology,
        @"ownerDisplay":owner,@"frame":@[@(frame.origin.x),@(frame.origin.y),
            @(frame.size.width),@(frame.size.height)]};
}

static bool sameFrame(NSArray *left,NSArray *right) {
    if(left.count!=4 || right.count!=4)return false;
    for(int index=0;index<4;index++)
        if(fabs([left[index] doubleValue]-[right[index] doubleValue])>2)return false;
    return true;
}

int main(int argc,const char **argv) { @autoreleasepool {
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    connection=sky ? (Connection)dlsym(sky,"SLSMainConnectionID") : nullptr;
    windowSpaces=sky ? (WindowSpaces)dlsym(sky,"SLSCopySpacesForWindows") : nullptr;
    windowDisplay=sky ? (WindowDisplay)dlsym(sky,"SLSCopyManagedDisplayForWindow") : nullptr;
    managed=sky ? (Managed)dlsym(sky,"SLSCopyManagedDisplaySpaces") : nullptr;
    if(!connection || !windowSpaces || !windowDisplay || !managed) {
        fprintf(stderr,"Required SkyLight observation APIs are unavailable\n");return 2;
    }
    NSMutableArray<NSString *> *external=NSMutableArray.array;
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess || count!=3) {
        fprintf(stderr,"Exactly three online displays are required\n");return 2;
    }
    for(uint32_t index=0;index<count;index++) {
        NSString *uuid=uuidForDisplay(displays[index]);
        if(CGDisplayIsBuiltin(displays[index]))builtinDisplay=uuid;
        else if(uuid)[external addObject:uuid];
    }
    [external sortUsingSelector:@selector(compare:)];
    if(external.count!=2 || !builtinDisplay) {
        fprintf(stderr,"One built-in and two external displays are required\n");return 2;
    }
    targetDisplay=argc>1 ? [NSString stringWithUTF8String:argv[1]] : external[0];
    if(![external containsObject:targetDisplay]) {
        fprintf(stderr,"The requested external display UUID is unavailable\n");return 2;
    }
    NSScreen *screen=nil;
    for(NSScreen *candidate in NSScreen.screens) {
        CGDirectDisplayID did=[candidate.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if([uuidForDisplay(did) isEqualToString:targetDisplay]) {screen=candidate;break;}
    }
    if(!screen) {fprintf(stderr,"Cannot place the fixture on its external display\n");return 2;}
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    NSRect visible=screen.visibleFrame;
    NSRect frame=NSMakeRect(NSMidX(visible)-260,NSMidY(visible)-170,520,340);
    fixtureWindow=[[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO screen:screen];
    fixtureWindow.title=@"RustDesk Air sticky fixture";
    fixtureWindow.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces;
    fixtureWindow.backgroundColor=NSColor.systemBlueColor;
    [fixtureWindow orderFrontRegardless];
    started=NSDate.date;
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        NSDictionary *sample=snapshot();
        if(!baseline) {
            if(sample && [sample[@"memberships"] count]>1
                && [sample[@"ownerDisplay"] isEqualToString:targetDisplay]
                && [sample isEqual:lastSample]) {
                baseline=sample;emit(@"before",sample);
                fprintf(stderr,"Run the whole-Space lifecycle, then press Return here after recovery.\n");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                    (void)getchar();
                    dispatch_async(dispatch_get_main_queue(),^{
                        NSDictionary *after=snapshot();emit(@"after",after);
                        bool exact=after && sawTopologyChange
                            && [baseline[@"memberships"] isEqual:after[@"memberships"]]
                            && [baseline[@"ownerDisplay"] isEqual:after[@"ownerDisplay"]]
                            && [baseline[@"topology"] isEqual:after[@"topology"]]
                            && sameFrame(baseline[@"frame"],after[@"frame"]);
                        emit(exact ? @"PASS" : @"FAIL",@{@"after":after ?: (id)NSNull.null,
                            @"sawTopologyChange":@(sawTopologyChange),
                            @"sawBuiltinOwner":@(sawBuiltinOwner)});
                        exit(exact ? 0 : 1);
                    });
                });
            } else if([NSDate.date timeIntervalSinceDate:started]>12) {
                emit(@"FAIL_no_stable_sticky_baseline",sample);exit(2);
            }
        } else if(sample) {
            if(![sample[@"topology"] isEqual:baseline[@"topology"]])sawTopologyChange=true;
            if([sample[@"ownerDisplay"] isEqualToString:builtinDisplay])sawBuiltinOwner=true;
            if(![sample isEqual:lastSample])emit(@"changed",sample);
        }
        lastSample=sample;
    }];
    [NSApp run];
    return 2;
} }
