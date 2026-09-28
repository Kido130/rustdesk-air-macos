#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cstdio>
#include <cstring>
#include <map>

static unsigned postedEvents,receivedEvents,beganEvents,movedEvents,endedEvents,magnifyEvents,scrollEvents;
extern "C" void air_capture_v2_record_mt(const unsigned char *,unsigned long,double){}
static size_t postedBytes,roundtripBytes,receivedBytes;
static void recordedPost(CGEventTapLocation location,CGEventRef event);
#define CGEventPost recordedPost
#include "../input.mm"
#undef CGEventPost

extern "C" void air_set_error(const char *){}
extern "C" void air_app_stop(void){}

static void recordedPost(CGEventTapLocation location,CGEventRef event){
 auto bytes=CGEventCreateData(nullptr,event);
 if(bytes){postedBytes=CFDataGetLength(bytes);auto copy=CGEventCreateFromData(nullptr,bytes);
  if(copy){auto roundtrip=CGEventCreateData(nullptr,copy);if(roundtrip){roundtripBytes=CFDataGetLength(roundtrip);CFRelease(roundtrip);}CFRelease(copy);}CFRelease(bytes);}
 postedEvents++;
 ::CGEventPost(location,event);
}

@interface ProbeView : NSView
@end
@implementation ProbeView
- (void)touchesBeganWithEvent:(NSEvent *)event {beganEvents+=event.allTouches.count;}
- (void)touchesMovedWithEvent:(NSEvent *)event {movedEvents+=event.allTouches.count;}
- (void)touchesEndedWithEvent:(NSEvent *)event {endedEvents+=event.allTouches.count;}
- (void)magnifyWithEvent:(NSEvent *)event {(void)event;magnifyEvents++;}
- (void)scrollWheel:(NSEvent *)event {(void)event;scrollEvents++;}
@end

@interface ProbeWindow : NSWindow
@end
@implementation ProbeWindow
- (void)sendEvent:(NSEvent *)event {
 if(event.type==NSEventTypeGesture){
  receivedEvents++;
  auto cg=event.CGEvent;
  auto bytes=cg?CGEventCreateData(nullptr,cg):nullptr;
  if(bytes){receivedBytes=CFDataGetLength(bytes);CFRelease(bytes);}
  fprintf(stdout,"delivered gesture touches=%lu phase=%lu\n",(unsigned long)event.allTouches.count,(unsigned long)event.phase);
 }
 [super sendEvent:event];
}
@end

static void pump(double seconds){
 NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(limit.timeIntervalSinceNow>0){
  NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:limit inMode:NSDefaultRunLoopMode dequeue:YES];
  if(event)[NSApp sendEvent:event];
 }
}
static std::map<uint32_t,RawContact> fingers(float separation,uint32_t state){
 return {{1,{1,state,.5f-separation/2,.5f,.5f}},{2,{2,state,.5f+separation/2,.5f,.5f}}};
}
static void sequence(uint64_t device){
 hostTouchDevice=device;
 postContacts(fingers(.08f,3),1);pump(.16);
 postContacts(fingers(.12f,4),2);pump(.16);
 postContacts(fingers(.16f,4),2);pump(.16);
 postContacts(fingers(.16f,5),4);pump(.35);
}
static uint64_t localDeviceID(){
 void *library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY|RTLD_LOCAL);
 if(!library)return 0;
 auto create=(CFArrayRef(*)())dlsym(library,"MTDeviceCreateList");
 auto getID=(int(*)(CFTypeRef,uint64_t *))dlsym(library,"MTDeviceGetDeviceID");
 uint64_t id=0;
 if(create&&getID){auto devices=create();if(devices){if(CFArrayGetCount(devices))getID(CFArrayGetValueAtIndex(devices,0),&id);CFRelease(devices);}}
 dlclose(library);return id;
}

int main(int argc,char **argv){
 if(argc>2||(argc==2&&strcmp(argv[1],"--local"))){puts("usage: raw_touch_window_probe [--local]");return 1;}
 if(!CGPreflightPostEventAccess()){puts("AX post permission unavailable; no window or injection");return 2;}
 @autoreleasepool {
  NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication;
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [NSApp finishLaunching];
  NSRect visible=NSScreen.screens.firstObject.visibleFrame;
  NSRect frame=NSMakeRect(NSMidX(visible)-180,NSMidY(visible)-120,360,240);
  ProbeWindow *window=[[ProbeWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  window.title=@"Raw Touch Probe";
  ProbeView *view=[[ProbeView alloc] initWithFrame:NSMakeRect(0,0,360,240)];
  view.allowedTouchTypes=NSTouchTypeMaskIndirect;view.wantsRestingTouches=YES;
  window.contentView=view;
  auto current=CGEventCreate(nullptr);
  CGPoint original=current?CGEventGetLocation(current):CGPointZero;
  if(current)CFRelease(current);
  [window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];pump(.5);
  if(!window.isKeyWindow||!NSApp.isActive){fprintf(stdout,"Probe window inactive: key=%d app=%d; no injection\n",window.isKeyWindow,NSApp.isActive);[window orderOut:nil];if(prior)[prior activateWithOptions:0];return 3;}
  CGPoint target={NSMidX(frame),CGDisplayBounds(CGMainDisplayID()).size.height-NSMidY(frame)};
  CGWarpMouseCursorPosition(target);pump(.1);
  uint64_t local=localDeviceID();
  if(argc==2&&!local){puts("No local trackpad device ID; no injection");CGWarpMouseCursorPosition(original);[window orderOut:nil];if(prior)[prior activateWithOptions:0];return 4;}
  sequence(argc==2?local:0);
  pump(.4);
  CGWarpMouseCursorPosition(original);
  [window orderOut:nil];
  if(prior)[prior activateWithOptions:0];
  fprintf(stdout,"posted=%u posted_bytes=%zu roundtrip_bytes=%zu received_gesture=%u received_bytes=%zu began=%u moved=%u ended=%u magnify=%u scroll=%u local_device=%llu\n",postedEvents,postedBytes,roundtripBytes,receivedEvents,receivedBytes,beganEvents,movedEvents,endedEvents,magnifyEvents,scrollEvents,(unsigned long long)local);
 }
 return 0;
}
