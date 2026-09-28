#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <time.h>
#include <cstring>
extern "C" {
#include "../TouchEvents.h"
CFTypeRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
CFTypeRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
void IOHIDEventAppendEvent(CFTypeRef,CFTypeRef,uint32_t);
void IOHIDEventSetSenderID(CFTypeRef,uint64_t);
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
}
#include <cstdio>

static CFDataRef oldWire;
static unsigned delivered,deliveredTouches,began,moved,ended,magnify,scroll;
static size_t deliveredBytes;
static NSUInteger touchCount(NSEvent *event){
 if(event.type==NSEventTypeScrollWheel)return 0;
 @try{return event.allTouches.count;}@catch(NSException*){return 0;}
}
extern "C" CGEventRef ProbeCGEventCreateFromData(CFAllocatorRef allocator,CFDataRef data){
 if(oldWire)CFRelease(oldWire);
 oldWire=CFDataCreateCopy(kCFAllocatorDefault,data);
 return CGEventCreateFromData(allocator,data);
}

@interface ModernProbeView : NSView
@end
@implementation ModernProbeView
- (void)touchesBeganWithEvent:(NSEvent *)event {began+=event.allTouches.count;}
- (void)touchesMovedWithEvent:(NSEvent *)event {moved+=event.allTouches.count;}
- (void)touchesEndedWithEvent:(NSEvent *)event {ended+=event.allTouches.count;}
- (void)magnifyWithEvent:(NSEvent *)event {(void)event;magnify++;}
- (void)scrollWheel:(NSEvent *)event {(void)event;scroll++;}
@end
@interface ModernProbeWindow : NSWindow
@end
@implementation ModernProbeWindow
- (void)sendEvent:(NSEvent *)event {
 if(event.type==NSEventTypeGesture||event.type==NSEventTypeMagnify||event.type==NSEventTypeScrollWheel){
  NSUInteger touches=touchCount(event);
  delivered++;deliveredTouches+=touches;
  auto cg=event.CGEvent;auto bytes=cg?CGEventCreateData(nullptr,cg):nullptr;
  if(bytes){deliveredBytes=CFDataGetLength(bytes);CFRelease(bytes);}
  fprintf(stdout,"delivered type=%lu touches=%lu phase=%lu magnification=%.4f\n",(unsigned long)event.type,(unsigned long)touches,(unsigned long)event.phase,event.type==NSEventTypeMagnify?event.magnification:0.0);
 }
 [super sendEvent:event];
}
@end

static void pump(double seconds){
 NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(limit.timeIntervalSinceNow>0){auto event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:limit inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];}
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
static CGEventRef makeEvent(float separation,uint32_t phase,uint64_t deviceID,int subtype,float magnification,size_t *wireBytes){
 uint64_t stamp=mach_absolute_time();
 bool touching=phase!=4;
 uint32_t mask=phase==1?7:phase==4?3:4;
 auto parent=IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,stamp,3,0,0,mask,0,0,0,0,0,0,touching,touching,0);
 if(!parent)return nullptr;
 IOHIDEventSetSenderID(parent,deviceID);
 for(uint32_t id=1;id<=2;id++){
  auto finger=IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,stamp,id,id,mask,id==1?.5-separation/2:.5+separation/2,.5,0,.5,0,touching,touching,0);
  if(!finger){CFRelease(parent);return nullptr;}
  IOHIDEventAppendEvent(parent,finger,0);CFRelease(finger);
 }
 auto modern=IOHIDEventCreateData(kCFAllocatorDefault,parent);CFRelease(parent);
 if(!modern)return nullptr;
 NSNumber *options=@(0x10000|(touching?0x20000:0));
 NSArray *touches=@[
  @{ @"type":@11,@"transducerType":@2,@"identity":@1,@"transducerIndex":@1,@"options":options,@"eventMask":@(mask),@"position.x":@(.5-separation/2),@"position.y":@.5,@"tipPressure":@.5 },
  @{ @"type":@11,@"transducerType":@2,@"identity":@2,@"transducerIndex":@2,@"options":options,@"eventMask":@(mask),@"position.x":@(.5+separation/2),@"position.y":@.5,@"tipPressure":@.5 }
 ];
  auto old=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)@{ @"deviceID":@(deviceID),@"gestureSubtype":@(subtype),@"gesturePhase":@(phase),@"magnification":@(magnification) },(__bridge CFArrayRef)touches);
 if(old)CFRelease(old);
 if(!oldWire){CFRelease(modern);return nullptr;}
 auto raw=CFDataGetBytePtr(oldWire);CFIndex offset=-1;
 for(CFIndex i=0;i+4<CFDataGetLength(oldWire);i++)if(raw[i+2]==0x10&&raw[i+3]==0x6d){offset=i;break;}
 if(offset<0){CFRelease(modern);return nullptr;}
 uint16_t oldSize=(uint16_t(raw[offset])<<8)|raw[offset+1];
 if(offset+4+oldSize>CFDataGetLength(oldWire)||CFDataGetLength(modern)>UINT16_MAX){CFRelease(modern);return nullptr;}
 auto spliced=CFDataCreateMutableCopy(kCFAllocatorDefault,0,oldWire);
 uint16_t newSize=CFSwapInt16HostToBig((uint16_t)CFDataGetLength(modern));
 CFDataReplaceBytes(spliced,CFRangeMake(offset,2),(const UInt8 *)&newSize,2);
 CFDataReplaceBytes(spliced,CFRangeMake(offset+4,oldSize),CFDataGetBytePtr(modern),CFDataGetLength(modern));
 auto event=CGEventCreateFromData(kCFAllocatorDefault,spliced);
 if(wireBytes)*wireBytes=CFDataGetLength(spliced);
 CFRelease(spliced);CFRelease(modern);
 if(event){auto cursor=CGEventCreate(nullptr);if(cursor){CGEventSetLocation(event,CGEventGetLocation(cursor));CFRelease(cursor);}CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));}
 return event;
}
int main(int argc,char **argv){
 setvbuf(stdout,nullptr,_IONBF,0);
 enum class Mode { Contacts,Magnify,Scroll };
 Mode mode=Mode::Contacts;
 if(argc==2&&!strcmp(argv[1],"--magnify"))mode=Mode::Magnify;
 else if(argc==2&&!strcmp(argv[1],"--scroll"))mode=Mode::Scroll;
 else if(argc!=1){puts("usage: modern_cg_window_probe [--magnify|--scroll]");return 1;}
 if(!CGPreflightPostEventAccess()){puts("AX post permission unavailable; no window or injection");return 2;}
 @autoreleasepool {
  NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication;
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
  NSRect visible=NSScreen.screens.firstObject.visibleFrame;
  NSRect frame=NSMakeRect(NSMidX(visible)-180,NSMidY(visible)-120,360,240);
  ModernProbeWindow *window=[[ModernProbeWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  window.title=@"Modern Touch Probe";
  ModernProbeView *view=[[ModernProbeView alloc] initWithFrame:NSMakeRect(0,0,360,240)];
  view.allowedTouchTypes=NSTouchTypeMaskIndirect;view.wantsRestingTouches=YES;window.contentView=view;
  auto cursor=CGEventCreate(nullptr);CGPoint original=cursor?CGEventGetLocation(cursor):CGPointZero;if(cursor)CFRelease(cursor);
  [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];pump(.5);
  if(!window.isKeyWindow||!NSApp.isActive){puts("Probe window inactive; no injection");[window orderOut:nil];if(prior)[prior activateWithOptions:0];return 3;}
  uint64_t deviceID=mode==Mode::Scroll?0:localDeviceID();
  if(mode!=Mode::Scroll&&!deviceID){puts("No local trackpad ID; no injection");[window orderOut:nil];if(prior)[prior activateWithOptions:0];return 4;}
  CGPoint target={NSMidX(frame),CGDisplayBounds(CGMainDisplayID()).size.height-NSMidY(frame)};
  fprintf(stdout,"saved_cursor x=%.1f y=%.1f\n",original.x,original.y);
  @try {
  CGWarpMouseCursorPosition(target);pump(.1);
  float separations[]={.08f,.12f,.16f,.16f};uint32_t phases[]={1,2,2,4};
  bool started=false,finished=false;
  for(int i=0;i<4;i++){
   size_t wire=0;
   auto event=mode==Mode::Scroll?CGEventCreateScrollWheelEvent2(nullptr,kCGScrollEventUnitPixel,2,i==1||i==2?-15:0,0,0):makeEvent(separations[i],phases[i],deviceID,mode==Mode::Magnify?8:11,mode==Mode::Magnify&&(i==1||i==2)?.03f:0.f,&wire);
   if(!event){fprintf(stdout,"construction_failed phase=%u\n",phases[i]);break;}
   if(mode==Mode::Scroll){CGEventSetIntegerValueField(event,kCGScrollWheelEventIsContinuous,1);CGEventSetIntegerValueField(event,kCGScrollWheelEventScrollPhase,phases[i]);auto cursor=CGEventCreate(nullptr);if(cursor){CGEventSetLocation(event,CGEventGetLocation(cursor));CFRelease(cursor);}CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));}
   auto native=[NSEvent eventWithCGEvent:event];
   auto encoded=CGEventCreateData(nullptr,event);
   NSUInteger preTouches=touchCount(native);
   fprintf(stdout,"posted phase=%u type=%lu wire=%zu normalized=%ld pre_touches=%lu\n",phases[i],(unsigned long)native.type,wire,encoded?(long)CFDataGetLength(encoded):0,(unsigned long)preTouches);
   if(encoded)CFRelease(encoded);
   if(mode!=Mode::Scroll&&preTouches!=2){CFRelease(event);break;}
   CGEventPost(kCGHIDEventTap,event);CFRelease(event);
   if(i==0)started=true;if(i==3)finished=true;
   pump(i==3?.35:.16);
  }
  if(started&&!finished){auto end=mode==Mode::Scroll?CGEventCreateScrollWheelEvent2(nullptr,kCGScrollEventUnitPixel,2,0,0,0):makeEvent(.16f,4,deviceID,mode==Mode::Magnify?8:11,0.f,nullptr);if(end){if(mode==Mode::Scroll){CGEventSetIntegerValueField(end,kCGScrollWheelEventIsContinuous,1);CGEventSetIntegerValueField(end,kCGScrollWheelEventScrollPhase,4);}CGEventPost(kCGHIDEventTap,end);CFRelease(end);pump(.2);}}
  pump(.4);
  } @finally {
   CGWarpMouseCursorPosition(original);[window orderOut:nil];if(prior)[prior activateWithOptions:0];
  }
  fprintf(stdout,"result mode=%s device=%llu delivered=%u delivered_touches=%u delivered_bytes=%zu began=%u moved=%u ended=%u magnify=%u scroll=%u\n",mode==Mode::Magnify?"magnify":mode==Mode::Scroll?"scroll":"contacts",(unsigned long long)deviceID,delivered,deliveredTouches,deliveredBytes,began,moved,ended,magnify,scroll);
  if(oldWire)CFRelease(oldWire);
 }
}
