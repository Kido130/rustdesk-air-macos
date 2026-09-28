// No event tap, AppKit activation, input posting, or display changes.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cassert>
#include <cstring>
#include <vector>

static std::vector<int> actions;
static const char *lastError;
static const char *lastStatus;
static int statusSeverity;
static int tapReenabled;
static bool tapEnabled,tapCanEnable=true;
static bool blockRelease;
static dispatch_semaphore_t releaseEntered,releaseResume;
@interface FixtureActiveApp : NSObject
@property(nonatomic, readonly, getter=isActive) BOOL active;
@end
@implementation FixtureActiveApp
- (BOOL)isActive { return YES; }
@end
static FixtureActiveApp *fixtureApp;
#define NSApp fixtureApp
#define CGEventTapEnable(tap, enable) (++tapReenabled, tapEnabled=(enable)&&tapCanEnable)
#define CGEventTapIsEnabled(tap) tapEnabled
#include "../input.mm"
#undef CGEventTapEnable
#undef CGEventTapIsEnabled
#undef NSApp

CGEventRef air_dockswipe27_cancel(uint64_t) { return nullptr; }
CGEventRef air_dockswipe27_convert(CGEventRef,uint64_t) { return nullptr; }
extern "C" uint32_t air_builtin_display(void) { return 0; }
extern "C" int air_spaces_current_slot(void) { return 0; }
extern "C" int air_spaces_slot_count(void) { return 0; }
extern "C" int air_spaces_transfer_window_edge(uint32_t,int,int) { return 0; }
extern "C" CFDataRef tl_CGEventCreateGestureData(CFDictionaryRef,CFArrayRef,CFIndex *) { return nullptr; }

extern "C" void air_capture_v2_record_mt(const unsigned char *,unsigned long,double) {}
extern "C" void air_set_error(const char *value) { lastError=value; }
extern "C" void air_status(const char *value,int error) { lastStatus=value;statusSeverity=error; }
extern "C" void air_app_stop(void) { assert(NSThread.isMainThread);actions.push_back(2); }
extern "C" void air_keyboard_probe_ready(int) {}
extern "C" void air_keyboard_probe_shutdown(void) {}
extern "C" void air_cursor_probe_ready(int) {}
extern "C" void air_cursor_probe_shutdown(void) {}
static void onPacket(const uint8_t *,size_t,uint64_t) { actions.push_back(3); }
static void onRelease(uint64_t) {
 if(blockRelease){dispatch_semaphore_signal(releaseEntered);dispatch_semaphore_wait(releaseResume,DISPATCH_TIME_FOREVER);}
 actions.push_back(1);
}
static unsigned char secureInputOn() { return 1; }

static void finishQueuedStop() {
 dispatch_sync(sendQueue,^{});
 for(int i=0;i<50&&actions.size()<2;i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
int main() { @autoreleasepool {
 fixtureApp=[FixtureActiveApp new];
 sendQueue=dispatch_queue_create("fixture.tap-failure",DISPATCH_QUEUE_SERIAL);
 sendNative=onPacket;releaseRemote=onRelease;clientInput=true;
 connected=true;enabled=true;
 inputTap=reinterpret_cast<CFMachPortRef>(1);tapEnabled=false;
 auto key=CGEventCreateKeyboardEvent(nullptr,12,true);assert(key);
 blockRelease=true;releaseEntered=dispatch_semaphore_create(0);releaseResume=dispatch_semaphore_create(0);
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 assert(dispatch_semaphore_wait(releaseEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 assert(!enabled&&actions.empty());
 dispatch_semaphore_signal(releaseResume);blockRelease=false;
 dispatch_sync(sendQueue,^{});
 for(int i=0;i<50&&!enabled;i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert((actions==std::vector<int>{1}));
 assert(enabled&&tapEnabled&&tapReenabled==1);
 assert(!lastError);
 actions.clear();
 // A second timeout inside the recovery interval must stop instead of spin.
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2}));
 assert(!enabled&&connected&&clientInput);
 assert(lastError&&strstr(lastError,"timed out"));
 assert(lastStatus&&strstr(lastStatus,"Remote Mode stopped")&&statusSeverity==1);
 assert(tapReenabled==1);
 assert(tapEvent(nullptr,kCGEventKeyDown,key,nullptr)==key);
 dispatch_sync(sendQueue,^{});
 assert((actions==std::vector<int>{1,2}));
 actions.clear();enabled=true;
 assert(tapEvent(nullptr,kCGEventTapDisabledByUserInput,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2}));
 assert(lastError&&strstr(lastError,"was disabled"));
 assert(tapReenabled==1);
 actions.clear();enabled=true;lastTapTimeoutRecoveryNs=0;tapCanEnable=false;tapEnabled=false;
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2}));
 assert(!enabled&&!tapEnabled&&tapReenabled==2);
 tapCanEnable=true;
 actions.clear();enabled=false;lastTapTimeoutRecoveryNs=0;
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{2})&&tapReenabled==2);
 actions.clear();enabled=true;localUI=true;lastTapTimeoutRecoveryNs=0;
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2})&&tapReenabled==2);
 actions.clear();enabled=true;localUI=false;secureInputEnabled=secureInputOn;lastTapTimeoutRecoveryNs=0;
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2})&&tapReenabled==2);
 secureInputEnabled=nullptr;
 actions.clear();enabled=true;localUI=false;lastTapTimeoutRecoveryNs=0;blockRelease=true;
 assert(tapEvent(nullptr,kCGEventTapDisabledByTimeout,key,nullptr)==key);
 assert(dispatch_semaphore_wait(releaseEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 localUI=true;
 dispatch_semaphore_signal(releaseResume);blockRelease=false;
 dispatch_sync(sendQueue,^{});
 for(int i=0;i<20;i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert((actions==std::vector<int>{1})&&!enabled&&tapReenabled==3);
 CFRelease(key);
 actions.clear();enabled=true;localUI=true;blockRelease=true;
 releaseEntered=dispatch_semaphore_create(0);releaseResume=dispatch_semaphore_create(0);
 auto escape=CGEventCreateKeyboardEvent(nullptr,53,true);assert(escape);
 CGEventSetFlags(escape,kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand);
 auto previousEscapes=escapes.load();
 assert(tapEvent(nullptr,kCGEventKeyDown,escape,nullptr)==nullptr);
 assert(dispatch_semaphore_wait(releaseEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 __block bool mainQueueDrained=false;
 dispatch_async(dispatch_get_main_queue(),^{mainQueueDrained=true;});
 for(int i=0;i<50&&!mainQueueDrained;i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert(mainQueueDrained&&actions.empty());
 dispatch_semaphore_signal(releaseResume);
 finishQueuedStop();
 assert((actions==std::vector<int>{1,2}));
 assert(!enabled&&escapes==previousEscapes+1);
 blockRelease=false;
 CFRelease(escape);
 actions.clear();enabled=true;localUI=true;blockRelease=true;
 auto stalledEscape=CGEventCreateKeyboardEvent(nullptr,53,true);assert(stalledEscape);
 CGEventSetFlags(stalledEscape,kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand);
 assert(tapEvent(nullptr,kCGEventKeyDown,stalledEscape,nullptr)==nullptr);
 assert(dispatch_semaphore_wait(releaseEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 for(int i=0;i<150&&actions.empty();i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert((actions==std::vector<int>{2}));
 dispatch_semaphore_signal(releaseResume);
 dispatch_sync(sendQueue,^{});
 blockRelease=false;
 for(int i=0;i<10;i++)
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert((actions==std::vector<int>{2,1}));
 CFRelease(stalledEscape);
 return 0;
} }
