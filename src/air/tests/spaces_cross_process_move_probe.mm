#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <libproc.h>
#include <poll.h>
#include <unistd.h>
#include <cmath>
#include <cstdio>

// A disposable second process owns the window. The controller never touches
// any other WID, Space, display mode, or application window.
using Connection = int (*)();
using MoveWindow = CGError (*)(int,uint32_t,const CGPoint *);
using WindowSpaces = CFArrayRef (*)(int,int,CFArrayRef);
using WindowDisplay = CFStringRef (*)(int,uint32_t);
using Managed = CFArrayRef (*)(int);

static Connection connection;
static MoveWindow moveWindow;
static WindowSpaces windowSpaces;
static WindowDisplay windowDisplay;
static Managed managed;

static NSArray *topology() {
    NSArray *all=CFBridgingRelease(managed(connection()));
    if(!all)return nil;
    NSMutableArray *out=NSMutableArray.array;
    for(NSDictionary *item in all) {
        NSString *display=item[@"Display Identifier"];
        NSNumber *current=item[@"Current Space"][@"id64"];
        NSArray *spaces=item[@"Spaces"];
        if(!display.length || !current || ![spaces isKindOfClass:NSArray.class])return nil;
        NSMutableArray *ids=NSMutableArray.array;
        for(NSDictionary *space in spaces) {
            NSNumber *sid=space[@"id64"];
            if(!sid)return nil;
            [ids addObject:sid];
        }
        [out addObject:@{@"display":display,@"selected":current,@"spaces":ids}];
    }
    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"display" ascending:YES]]];
    return out;
}

static NSArray *displayModes() {
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,ids,&count)!=kCGErrorSuccess)return nil;
    NSMutableArray *out=NSMutableArray.array;
    for(uint32_t i=0;i<count;i++) {
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if(!uuid)return nil;
        NSString *name=CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,uuid));
        CFRelease(uuid);
        CGDisplayModeRef mode=CGDisplayCopyDisplayMode(ids[i]);
        if(!mode)return nil;
        [out addObject:@{@"display":name,@"width":@(CGDisplayModeGetWidth(mode)),
            @"height":@(CGDisplayModeGetHeight(mode)),
            @"pixelWidth":@(CGDisplayModeGetPixelWidth(mode)),
            @"pixelHeight":@(CGDisplayModeGetPixelHeight(mode))}];
        CGDisplayModeRelease(mode);
    }
    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"display" ascending:YES]]];
    return out;
}

static bool birth(pid_t pid,uint64_t *seconds,uint64_t *micros) {
    proc_bsdinfo info={};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return false;
    *seconds=info.pbi_start_tvsec;*micros=info.pbi_start_tvusec;
    return *seconds!=0;
}

static NSDictionary *sample(uint32_t wid,pid_t expectedPid) {
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow,wid));
    NSDictionary *found=nil;
    for(NSDictionary *item in list) {
        if([item[(id)kCGWindowNumber] unsignedIntValue]==wid &&
            [item[(id)kCGWindowOwnerPID] intValue]==expectedPid) {found=item;break;}
    }
    CGRect frame={};
    if(!found || !CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)found[(id)kCGWindowBounds],&frame))return nil;
    int cid=connection();
    NSArray *members=CFBridgingRelease(windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    NSString *owner=CFBridgingRelease(windowDisplay(cid,wid));
    uint64_t seconds=0,micros=0;
    if(!members.count || !owner.length || !birth(expectedPid,&seconds,&micros))return nil;
    NSArray *sorted=[members sortedArrayUsingSelector:@selector(compare:)];
    return @{@"wid":@(wid),@"pid":@(expectedPid),@"birth":@[@(seconds),@(micros)],
             @"frame":@[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)],
             @"display":owner,@"spaces":sorted,
             @"layer":found[(id)kCGWindowLayer] ?: @(-1)};
}

static bool sameIdentity(NSDictionary *a,NSDictionary *b) {
    return [a[@"wid"] isEqual:b[@"wid"]] && [a[@"pid"] isEqual:b[@"pid"]] &&
        [a[@"birth"] isEqual:b[@"birth"]] && [a[@"display"] isEqual:b[@"display"]] &&
        [a[@"spaces"] isEqual:b[@"spaces"]] && [a[@"layer"] isEqual:b[@"layer"]];
}

static bool sameFrame(NSDictionary *sample,CGPoint origin) {
    NSArray *frame=sample[@"frame"];
    return frame.count==4 && fabs([frame[0] doubleValue]-origin.x)<0.1 &&
        fabs([frame[1] doubleValue]-origin.y)<0.1;
}

static NSDictionary *waitFor(uint32_t wid,pid_t pid,CGPoint target) {
    for(int i=0;i<30;i++) {
        NSDictionary *current=sample(wid,pid);
        if(current && sameFrame(current,target))return current;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }
    return nil;
}

static void emit(NSString *phase,NSDictionary *value) {
    NSDictionary *line=@{@"phase":phase,@"sample":value ?: NSNull.null};
    NSData *data=[NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:nil];
    if(data) {fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);}
}

static int childMain() {
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    CGDirectDisplayID displays[32];uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return 10;
    bool found=false;
    for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(displays[i])) {
        found=true;break;
    }
    if(!found)return 11;
    // AppKit uses a bottom-left y origin; place a tiny ordinary root window
    // entirely on the built-in panel, with room for a 24-point probe move.
    NSScreen *screen=nil;
    for(NSScreen *candidate in NSScreen.screens) {
        NSNumber *number=candidate.deviceDescription[@"NSScreenNumber"];
        if(number && CGDisplayIsBuiltin(number.unsignedIntValue)) {screen=candidate;break;}
    }
    if(!screen)return 12;
    NSRect sf=screen.frame;
    NSWindow *window=[[NSWindow alloc] initWithContentRect:
        NSMakeRect(sf.origin.x+100,sf.origin.y+sf.size.height-220,180,90)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"Disposable cross-process move probe";
    window.releasedWhenClosed=NO;
    [window orderFrontRegardless];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    if(!window.windowNumber)return 13;
    printf("%u\n",(unsigned)window.windowNumber);fflush(stdout);
    // Keep the owning app's main run loop alive. SkyLight can acknowledge the
    // request before the client has processed its window geometry update.
    for(;;) {
        struct pollfd pfd={STDIN_FILENO,POLLIN,0};
        if(poll(&pfd,1,0)>0) {char c=0;read(STDIN_FILENO,&c,1);break;}
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    [window close];
    return 0;
}

static int selfControlMain() {
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    NSScreen *screen=nil;
    for(NSScreen *candidate in NSScreen.screens) {
        NSNumber *number=candidate.deviceDescription[@"NSScreenNumber"];
        if(number && CGDisplayIsBuiltin(number.unsignedIntValue)) {screen=candidate;break;}
    }
    if(!screen)return 30;
    NSRect sf=screen.frame;
    NSWindow *window=[[NSWindow alloc] initWithContentRect:
        NSMakeRect(sf.origin.x+100,sf.origin.y+sf.size.height-220,180,90)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"Disposable same-process move control";
    window.releasedWhenClosed=NO;
    [window orderFrontRegardless];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    uint32_t wid=(uint32_t)window.windowNumber;
    NSDictionary *before=sample(wid,getpid());
    if(!before) {[window close];return 31;}
    emit(@"self_before",before);
    NSArray *frame=before[@"frame"];
    CGPoint original=CGPointMake([frame[0] doubleValue],[frame[1] doubleValue]);
    CGPoint target=CGPointMake(original.x+24,original.y+16);
    CGError code=moveWindow(connection(),wid,&target);
    NSDictionary *moved=waitFor(wid,getpid(),target);
    emit(@"self_after_move_call",sample(wid,getpid()));
    fprintf(stderr,"self_move_code=%d\n",(int)code);
    CGPoint reverse=original;
    CGError reverseCode=moveWindow(connection(),wid,&reverse);
    NSDictionary *restored=waitFor(wid,getpid(),original);
    emit(@"self_restored",restored);
    [window close];
    return code==kCGErrorSuccess && moved && sameIdentity(before,moved) &&
        reverseCode==kCGErrorSuccess && restored && sameIdentity(before,restored) &&
        [before[@"frame"] isEqual:restored[@"frame"]] ? 0 : 32;
}

static int readWid(int fd,uint32_t *wid) {
    struct pollfd pfd={fd,POLLIN,0};
    if(poll(&pfd,1,10000)<=0)return 20;
    char buf[64]={};size_t count=0;
    while(count<sizeof(buf)-1) {
        ssize_t n=read(fd,buf+count,1);
        if(n!=1)return 21;
        if(buf[count++]=='\n')break;
    }
    unsigned parsed=0;
    if(sscanf(buf,"%u",&parsed)!=1 || !parsed)return 22;
    *wid=parsed;return 0;
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2 && strcmp(argv[1],"--child")==0)return childMain();
    if(argc!=2 || (strcmp(argv[1],"--execute")!=0 && strcmp(argv[1],"--self-control")!=0)) {
        fprintf(stderr,"Usage: spaces_cross_process_move_probe --execute|--self-control\n");return 2;
    }
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    connection=sky ? (Connection)dlsym(sky,"SLSMainConnectionID") : nullptr;
    moveWindow=sky ? (MoveWindow)dlsym(sky,"SLSMoveWindow") : nullptr;
    windowSpaces=sky ? (WindowSpaces)dlsym(sky,"SLSCopySpacesForWindows") : nullptr;
    windowDisplay=sky ? (WindowDisplay)dlsym(sky,"SLSCopyManagedDisplayForWindow") : nullptr;
    managed=sky ? (Managed)dlsym(sky,"SLSCopyManagedDisplaySpaces") : nullptr;
    if(!connection || !moveWindow || !windowSpaces || !windowDisplay || !managed)return 3;
    if(strcmp(argv[1],"--self-control")==0)return selfControlMain();
    NSArray *beforeTopology=topology(),*beforeModes=displayModes();
    if(!beforeTopology || !beforeModes)return 14;
    emit(@"topology_before",@{@"selection":beforeTopology,@"modes":beforeModes});
    fprintf(stderr,"controller_accessibility_trusted=%d\n",AXIsProcessTrusted());
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:
        [NSString stringWithUTF8String:argv[0]]];task.arguments=@[@"--child"];
    NSPipe *input=[NSPipe pipe],*output=[NSPipe pipe];
    task.standardInput=input;task.standardOutput=output;
    NSError *error=nil;
    if(![task launchAndReturnError:&error]) {
        fprintf(stderr,"Fixture launch failed: %s\n",error.localizedDescription.UTF8String);return 4;
    }
    pid_t child=task.processIdentifier;
    uint32_t wid=0;
    int result=readWid(output.fileHandleForReading.fileDescriptor,&wid);
    NSDictionary *before=nil,*moved=nil,*restored=nil;
    CGPoint original={};bool didMove=false;
    if(result==0) {
        before=sample(wid,child);
        if(!before || [before[@"layer"] intValue]!=0)result=5;
    }
    if(result==0) {
        emit(@"before",before);
        NSArray *frame=before[@"frame"];
        original=CGPointMake([frame[0] doubleValue],[frame[1] doubleValue]);
        // Fail closed on process identity mismatch; no private move call.
        NSDictionary *wrong=[before mutableCopy];
        NSMutableDictionary *bad=[before mutableCopy];bad[@"pid"]=@(child+1);
        if(sameIdentity(wrong,bad))result=6;
        emit(@"rejected_wrong_pid",sample(wid,child));
    }
    if(result==0) {
        CGPoint target=CGPointMake(original.x+24,original.y+16);
        CGError code=moveWindow(connection(),wid,&target);
        moved=waitFor(wid,child,target);
        emit(@"after_move_call",sample(wid,child));
        if(code!=kCGErrorSuccess || !moved || !sameIdentity(before,moved))result=7;
        else didMove=true;
        emit(@"moved",moved);
        fprintf(stderr,"cross_process_move_code=%d\n",(int)code);
    }
    // Always attempt the exact rollback after any successful move, including
    // verification failure. The disposable owner stays alive until this ends.
    if(didMove || (before && !sameFrame(sample(wid,child),original))) {
        CGError code=moveWindow(connection(),wid,&original);
        restored=waitFor(wid,child,original);
        emit(@"restored",restored);
        if(code!=kCGErrorSuccess || !restored || !sameIdentity(before,restored) ||
            ![before[@"frame"] isEqual:restored[@"frame"]])result=8;
    }
    if(before) {
        CGPoint bogus=CGPointMake(original.x+99,original.y+99);
        CGError code=moveWindow(connection(),UINT32_MAX,&bogus);
        NSDictionary *unchanged=sample(wid,child);
        emit(@"invalid_wid_unchanged",unchanged);
        fprintf(stderr,"invalid_wid_code=%d\n",(int)code);
        if(!sameIdentity(before,unchanged) ||
            ![before[@"frame"] isEqual:unchanged[@"frame"]])result=9;
    }
    char close='x';write(input.fileHandleForWriting.fileDescriptor,&close,1);
    [task waitUntilExit];
    NSArray *afterTopology=topology(),*afterModes=displayModes();
    emit(@"topology_after",afterTopology && afterModes
        ? @{@"selection":afterTopology,@"modes":afterModes} : nil);
    if(![beforeTopology isEqual:afterTopology] || ![beforeModes isEqual:afterModes])result=15;
    fprintf(stderr,"fixture_child_pid=%d fixture_exit=%d result=%d\n",
        child,task.terminationStatus,result);
    return result ?: task.terminationStatus;
}}
