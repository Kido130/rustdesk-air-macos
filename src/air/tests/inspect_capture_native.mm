#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdint.h>
#include <dlfcn.h>
#include "../IOHIDEventTypes.h"

extern "C" {
CFTypeRef IOHIDEventCreateWithData(CFAllocatorRef,CFDataRef);
CFArrayRef IOHIDEventGetChildren(CFTypeRef);
uint32_t IOHIDEventGetType(CFTypeRef);
uint64_t IOHIDEventGetSenderID(CFTypeRef);
CFIndex IOHIDEventGetIntegerValue(CFTypeRef,uint32_t);
void IOHIDEventSetSenderID(CFTypeRef,uint64_t);
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
}

static uint32_t little32(const uint8_t *bytes){uint32_t value;memcpy(&value,bytes,4);return CFSwapInt32LittleToHost(value);}
static void reportHID(const char *label,const uint8_t *gesture,CFIndex size){
 for(CFIndex i=2;i+2<size;i++)if(gesture[i]==0x10&&gesture[i+1]==0x6d){
  uint16_t fieldSize=((uint16_t)gesture[i-2]<<8)|gesture[i-1];
  if(i+2+fieldSize>size)continue;
  auto payload=CFDataCreate(kCFAllocatorDefault,gesture+i+2,fieldSize);
  auto hid=payload?IOHIDEventCreateWithData(kCFAllocatorDefault,payload):nullptr;
  auto children=hid?IOHIDEventGetChildren(hid):nullptr;
  printf("%s_hid_field offset=%ld bytes=%u decoded=%d hid_type=%u sender=%llu children=%ld",label,(long)(i-2),fieldSize,hid!=nullptr,hid?IOHIDEventGetType(hid):0,(unsigned long long)(hid?IOHIDEventGetSenderID(hid):0),children?(long)CFArrayGetCount(children):0);
  if(children)for(CFIndex n=0;n<CFArrayGetCount(children);n++){
   auto child=CFArrayGetValueAtIndex(children,n);auto type=IOHIDEventGetType(child);
   printf(" child_type=%u",type);
   if(type==kIOHIDEventTypeDigitizer)printf(" id=%ld mask=%ld range=%ld touch=%ld",(long)IOHIDEventGetIntegerValue(child,kIOHIDEventFieldDigitizerIdentity),(long)IOHIDEventGetIntegerValue(child,kIOHIDEventFieldDigitizerEventMask),(long)IOHIDEventGetIntegerValue(child,kIOHIDEventFieldDigitizerRange),(long)IOHIDEventGetIntegerValue(child,kIOHIDEventFieldDigitizerTouch));
  }
  puts("");
  if(hid)CFRelease(hid);if(payload)CFRelease(payload);
  return;
 }
 printf("%s_hid_field absent\n",label);
}

int main(int argc,const char **argv){
 @autoreleasepool {
  bool retarget=argc==3&&!strcmp(argv[2],"--retarget-local");
  if((argc!=2&&!retarget)){fprintf(stderr,"usage: inspect_capture_native CAPTURE.bin [--retarget-local]\n");return 2;}
  NSData *data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  const uint8_t *bytes=(const uint8_t *)data.bytes;
  if(data.length<48||memcmp(bytes,"RDAICAP1",8)){fprintf(stderr,"invalid capture header\n");return 2;}
  uint32_t size=little32(bytes+8),raw=little32(bytes+12);
  if(size>65536||raw>336||data.length!=48ULL+size+raw){fprintf(stderr,"invalid capture length\n");return 2;}
  if(!size){puts("gesture sample absent");return 1;}
  CFDataRef packet=CFDataCreate(kCFAllocatorDefault,bytes+48,size);
  CGEventRef event=packet?CGEventCreateFromData(kCFAllocatorDefault,packet):nullptr;
  if(packet)CFRelease(packet);
  if(!event){puts("CGEventCreateFromData failed");return 1;}
  NSUInteger touches=0;NSInteger nativeSubtype=0;NSEventPhase nativePhase=NSEventPhaseNone;
  @try{NSEvent *native=[NSEvent eventWithCGEvent:event];touches=native.allTouches.count;nativeSubtype=native.subtype;nativePhase=native.phase;}@catch(NSException*){}
  auto normalized=CGEventCreateData(kCFAllocatorDefault,event);
  printf("CGEvent type=%u input_bytes=%u normalized_bytes=%ld timestamp=%llu touches=%lu cg_subtype=%lld cg_phase=%lld ns_subtype=%ld ns_phase=%lu\n",(unsigned)CGEventGetType(event),size,normalized?(long)CFDataGetLength(normalized):0,(unsigned long long)CGEventGetTimestamp(event),(unsigned long)touches,(long long)CGEventGetIntegerValueField(event,(CGEventField)0x6e),(long long)CGEventGetIntegerValueField(event,(CGEventField)0x84),(long)nativeSubtype,(unsigned long)nativePhase);
  reportHID("input",bytes+48,size);
  if(normalized)reportHID("normalized",CFDataGetBytePtr(normalized),CFDataGetLength(normalized));
  if(retarget){
   uint64_t localID=0;
   void *library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY|RTLD_LOCAL);
   if(library){auto create=(CFArrayRef(*)())dlsym(library,"MTDeviceCreateList");auto getID=(int(*)(CFTypeRef,uint64_t *))dlsym(library,"MTDeviceGetDeviceID");
    if(create&&getID){auto devices=create();if(devices){if(CFArrayGetCount(devices))getID(CFArrayGetValueAtIndex(devices,0),&localID);CFRelease(devices);}}dlclose(library);}
   const uint8_t *original=bytes+48;
   for(CFIndex i=2;localID&&i+2<size;i++)if(original[i]==0x10&&original[i+1]==0x6d){
    uint16_t oldSize=((uint16_t)original[i-2]<<8)|original[i-1];if(i+2+oldSize>size)continue;
    auto field=CFDataCreate(kCFAllocatorDefault,original+i+2,oldSize);
    auto hid=field?IOHIDEventCreateWithData(kCFAllocatorDefault,field):nullptr;
    if(field)CFRelease(field);if(!hid)break;
    IOHIDEventSetSenderID(hid,localID);
    auto updated=IOHIDEventCreateData(kCFAllocatorDefault,hid);CFRelease(hid);
    if(updated&&CFDataGetLength(updated)<=UINT16_MAX){
     auto copy=CFDataCreateMutable(kCFAllocatorDefault,0);CFDataAppendBytes(copy,original,size);
     uint16_t newSize=CFSwapInt16HostToBig((uint16_t)CFDataGetLength(updated));
     CFDataReplaceBytes(copy,CFRangeMake(i-2,2),(const uint8_t *)&newSize,2);
     CFDataReplaceBytes(copy,CFRangeMake(i+2,oldSize),CFDataGetBytePtr(updated),CFDataGetLength(updated));
     auto changed=CGEventCreateFromData(kCFAllocatorDefault,copy);NSUInteger retargetTouches=0;
     if(changed){@try{retargetTouches=[NSEvent eventWithCGEvent:changed].allTouches.count;}@catch(NSException*){} }
     printf("retarget_local sender=%llu bytes=%ld decoded=%d touches=%lu\n",(unsigned long long)localID,(long)CFDataGetLength(copy),changed!=nullptr,(unsigned long)retargetTouches);
     if(changed)CFRelease(changed);CFRelease(copy);
    }
    if(updated)CFRelease(updated);break;
   }
  }
  if(normalized)CFRelease(normalized);
  CFRelease(event);
  return 0;
 }
}
