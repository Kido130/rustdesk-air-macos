#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static uint64_t membershipSpace=10;
static CFArrayRef membershipStub(int,int,CFArrayRef) {
    return (__bridge_retained CFArrayRef)@[@(membershipSpace)];
}
static int typeStub(int,uint64_t) { return 0; }

int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);
    [NSApplication sharedApplication];
    NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(260,260,240,140)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.title=@"CG Only Fixture";
    [window orderFrontRegardless];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    uint32_t wid=(uint32_t)window.windowNumber;
    CGRect frame={};assert(readCGFrame(wid,getpid(),&frame));
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:getpid()];
    ProcessBirth birth=processBirth(getpid());
    assert(app.bundleIdentifier.length && birth.valid());
    double launch=stableLaunchTime(app,getpid());assert(launch>0);
    auto originalSpaces=api().windowSpaces;
    auto originalType=api().spaceType;
    api().windowSpaces=membershipStub;api().spaceType=typeStub;
    initialSpace=10;builtinUUID="builtin";slots[0]=0;
    SavedWindow value={wid,getpid(),app.bundleIdentifier.UTF8String,"CG Only Fixture",frame,
        CGRectMake(0,0,1600,1000),launch,10,0,"builtin",false};
    value.cgOnly=true;value.birthSeconds=birth.seconds;value.birthMicroseconds=birth.microseconds;
    saved={value};
    NSString *parent=[NSString stringWithUTF8String:argv[1]];
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-cg-only-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> path(bytes.begin(),bytes.end());path.push_back(0);
    assert(mkdtemp(path.data()));NSString *base=[NSString stringWithUTF8String:path.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    assert(persist());
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil];
    assert([journal[@"version"] intValue]==13);
    saved.clear();assert(loadJournal() && saved.size()==1 && saved[0].cgOnly
        && saved[0].birthSeconds==birth.seconds);
    assert(windowState(saved[0])==WindowState::Ready);
    CGRect moved=CGRectOffset(frame,40,40);
    assert(setFrame(saved[0],moved));
    membershipSpace=901;slots[0]=901;
    assert(windowState(saved[0])==WindowState::Ready);
    assert(setFrame(saved[0],frame));
    SavedWindow invalid=saved[0];invalid.birthSeconds++;
    assert(windowState(invalid)==WindowState::AXUnavailable && !setFrame(invalid,moved));
    invalid=saved[0];invalid.frame.size.width++;
    assert(windowState(invalid)==WindowState::AXUnavailable && !setFrame(invalid,moved));
    membershipSpace=999;
    assert(windowState(saved[0])==WindowState::AXUnavailable && !setFrame(saved[0],moved));
    NSMutableDictionary *bad=[journal mutableCopy];NSMutableArray *windows=[journal[@"windows"] mutableCopy];
    NSMutableDictionary *entry=[windows[0] mutableCopy];entry[@"birthSeconds"]=@0;
    windows[0]=entry;bad[@"windows"]=windows;assert(!parseJournal(bad));
    entry[@"birthSeconds"]=@(birth.seconds);entry[@"cgOnly"]=@"true";
    assert(!parseJournal(bad));
    api().windowSpaces=originalSpaces;api().spaceType=originalType;
    journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    [window close];
    puts("CG-only v13 journal, exact identity, source/destination, placement and conflict refusal passed");
    return 0;
}}
