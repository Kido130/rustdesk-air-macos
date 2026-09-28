#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
extern "C" {
#include "../TouchEvents.h"
}
#include <cstdio>
#include <cstring>

extern "C" {
CFTypeRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
CFTypeRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
void IOHIDEventAppendEvent(CFTypeRef,CFTypeRef,uint32_t);
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
}

static CFDataRef oldWire;
extern "C" CGEventRef ProbeCGEventCreateFromData(CFAllocatorRef allocator,CFDataRef data){
 oldWire=CFDataCreateCopy(kCFAllocatorDefault,data);
 return CGEventCreateFromData(allocator,data);
}
static NSUInteger touchCount(CGEventRef event){
 if(!event)return 0;
 @try{return [NSEvent eventWithCGEvent:event].allTouches.count;}@catch(NSException*){return 0;}
}
static void report(const char *label,CGEventRef event){
 auto encoded=event?CGEventCreateData(nullptr,event):nullptr;
 fprintf(stdout,"%s valid=%d type=%u normalized_bytes=%ld touches=%lu\n",label,event!=nullptr,event?(unsigned)CGEventGetType(event):0,encoded?(long)CFDataGetLength(encoded):0,(unsigned long)touchCount(event));
 if(encoded)CFRelease(encoded);
}

int main(){
 @autoreleasepool {
  uint64_t stamp=mach_absolute_time();
  auto parent=IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,stamp,3,0,0,7,0,0,0,0,0,0,true,true,0);
  if(!parent)return 1;
  for(uint32_t id=1;id<=2;id++){
   auto finger=IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,stamp,id,id,7,id==1?.45:.55,.5,0,.5,0,true,true,0);
   if(!finger){CFRelease(parent);return 1;}
   IOHIDEventAppendEvent(parent,finger,0);CFRelease(finger);
  }
  auto modern=IOHIDEventCreateData(kCFAllocatorDefault,parent);CFRelease(parent);
  if(!modern)return 1;
  auto direct=CGEventCreateFromData(kCFAllocatorDefault,modern);
  fprintf(stdout,"modern_hid_bytes=%ld\n",(long)CFDataGetLength(modern));
  report("direct_hid_as_cg",direct);
  if(direct)CFRelease(direct);

  NSArray *touches=@[
   @{ @"type":@11,@"transducerType":@2,@"identity":@1,@"transducerIndex":@1,@"options":@(0x30000),@"eventMask":@7,@"position.x":@.45,@"position.y":@.5,@"tipPressure":@.5 },
   @{ @"type":@11,@"transducerType":@2,@"identity":@2,@"transducerIndex":@2,@"options":@(0x30000),@"eventMask":@7,@"position.x":@.55,@"position.y":@.5,@"tipPressure":@.5 }
  ];
  auto old=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)@{ @"deviceID":@0,@"gestureSubtype":@11,@"gesturePhase":@1 },(__bridge CFArrayRef)touches);
  fprintf(stdout,"old_wire_bytes=%ld\n",oldWire?(long)CFDataGetLength(oldWire):0);
  report("old_decoded",old);
  if(old)CFRelease(old);

  if(!oldWire||CFDataGetLength(modern)>UINT16_MAX){puts("No compatible old CG field");CFRelease(modern);if(oldWire)CFRelease(oldWire);return 2;}
  auto raw=CFDataGetBytePtr(oldWire);
  CFIndex fieldOffset=-1;
  for(CFIndex i=0;i+4<CFDataGetLength(oldWire);i++)if(raw[i+2]==0x10&&raw[i+3]==0x6d){fieldOffset=i;break;}
  if(fieldOffset<0){puts("No HID queue field");CFRelease(modern);CFRelease(oldWire);return 2;}
  uint16_t oldSize=(uint16_t(raw[fieldOffset])<<8)|raw[fieldOffset+1];
  if(raw[fieldOffset+2]!=0x10||raw[fieldOffset+3]!=0x6d||fieldOffset+4+oldSize>CFDataGetLength(oldWire)){puts("Old queue field invalid");CFRelease(modern);CFRelease(oldWire);return 2;}
  auto replaced=CFDataCreateMutableCopy(kCFAllocatorDefault,0,oldWire);
  uint16_t newSize=CFSwapInt16HostToBig((uint16_t)CFDataGetLength(modern));
  CFDataReplaceBytes(replaced,CFRangeMake(fieldOffset,2),(const UInt8 *)&newSize,2);
  CFDataReplaceBytes(replaced,CFRangeMake(fieldOffset+4,oldSize),CFDataGetBytePtr(modern),CFDataGetLength(modern));
  auto splice=CGEventCreateFromData(kCFAllocatorDefault,replaced);
  fprintf(stdout,"field_offset=%ld old_field_bytes=%u spliced_wire_bytes=%ld\n",(long)fieldOffset,oldSize,(long)CFDataGetLength(replaced));
  report("modern_hid_in_old_cg_field",splice);
  if(splice)CFRelease(splice);
  CFRelease(replaced);CFRelease(modern);CFRelease(oldWire);
 }
}
