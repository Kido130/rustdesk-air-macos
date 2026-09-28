// Disposable two-contact delivery probe. Run only with explicit UI coordination.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cstdio>
#include <map>
#include "../input.mm"

extern "C" void air_set_error(const char *){}
extern "C" void air_app_stop(void){}
extern "C" void air_capture_v2_record_mt(const unsigned char *,unsigned long,double){}

static unsigned probeGestures,began,moved,ended,maxTouches;
@interface RawProbeView:NSView
@end
@implementation RawProbeView
- (void)touchesBeganWithEvent:(NSEvent *)event {began+=event.allTouches.count;}
- (void)touchesMovedWithEvent:(NSEvent *)event {moved+=event.allTouches.count;}
- (void)touchesEndedWithEvent:(NSEvent *)event {ended+=event.allTouches.count;}
@end
@interface RawProbeWindow:NSWindow
@end
@implementation RawProbeWindow
- (void)sendEvent:(NSEvent *)event {
 if(event.type==NSEventTypeGesture){
  probeGestures++;@try{maxTouches=std::max(maxTouches,(unsigned)event.allTouches.count);}@catch(NSException*){}
 }
 [super sendEvent:event];
}
@end
static void pump(double seconds){
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(deadline.timeIntervalSinceNow>0){
  NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
  if(event)[NSApp sendEvent:event];
 }
}
int main(){
 setvbuf(stdout,nullptr,_IONBF,0);
 if(!CGPreflightPostEventAccess()){puts("post_event_access=0; no window or input");return 2;}
 uint64_t localID=localTouchDeviceID();
 if(!localID){puts("local_trackpad_id=0; no window or input");return 3;}
 @autoreleasepool {
  NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication;
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
  NSScreen *screen=NSScreen.mainScreen;if(!screen){puts("screen_unavailable");return 4;}
  NSRect frame=NSMakeRect(NSMidX(screen.visibleFrame)-180,NSMidY(screen.visibleFrame)-120,360,240);
  RawProbeWindow *window=[[RawProbeWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  window.title=@"Raw Contact Probe";
  RawProbeView *view=[[RawProbeView alloc] initWithFrame:NSMakeRect(0,0,360,240)];
  view.allowedTouchTypes=NSTouchTypeMaskIndirect;view.wantsRestingTouches=YES;window.contentView=view;
  auto cursor=CGEventCreate(nullptr);CGPoint original=cursor?CGEventGetLocation(cursor):CGPointZero;if(cursor)CFRelease(cursor);
  [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];pump(.5);
  if(!window.isKeyWindow||!NSApp.isActive){puts("probe_window_inactive; no input");[window orderOut:nil];if(prior)[prior activateWithOptions:0];return 5;}
  CGPoint target={NSMidX(frame),CGDisplayBounds(CGMainDisplayID()).size.height-NSMidY(frame)};
  bool sent=false;
  @try {
   CGWarpMouseCursorPosition(target);pump(.1);
   std::map<uint32_t,RawContact> contacts={{2,{2,3,.46f,.5f,.5f}},{3,{3,3,.54f,.5f,.5f}}};
   hostTouchDevice=42;
   sent=postContacts(contacts,1);pump(.16);
   if(sent){contacts[2].state=contacts[3].state=4;contacts[2].x=.43f;contacts[3].x=.57f;sent=postContacts(contacts,2);pump(.16);}
   if(sent){contacts[2].x=.40f;contacts[3].x=.60f;sent=postContacts(contacts,2);pump(.16);}
   contacts[2].state=contacts[3].state=5;
   postContacts(contacts,4);pump(.4);
  } @finally {
   CGWarpMouseCursorPosition(original);[window orderOut:nil];if(prior)[prior activateWithOptions:0];
  }
  printf("result sent=%d gestures=%u max_touches=%u began=%u moved=%u ended=%u\n",sent,probeGestures,maxTouches,began,moved,ended);
  return sent&&probeGestures>=4&&began>=2&&moved>=2&&ended>=2?0:6;
 }
}
