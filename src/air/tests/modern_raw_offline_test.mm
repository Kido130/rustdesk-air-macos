// Source-linked contact construction from a real Air RDAF frame; never posts input.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <map>
static void forbidPost(CGEventTapLocation,CGEventRef){abort();}
#define CGEventPost forbidPost
#include "../input.mm"
#undef CGEventPost
#include "../IOHIDEventTypes.h"

extern "C" void air_set_error(const char *){}
extern "C" void air_app_stop(void){}
extern "C" void air_capture_v2_record_mt(const unsigned char *,unsigned long,double){}
extern "C" CFArrayRef IOHIDEventGetChildren(CFTypeRef);
extern "C" CFIndex IOHIDEventGetIntegerValue(CFTypeRef,uint32_t);

static uint32_t little32(const uint8_t *p){uint32_t value;memcpy(&value,p,4);return CFSwapInt32LittleToHost(value);}
static void verify(const char *label,const std::map<uint32_t,RawContact> &contacts,uint32_t phase,bool requireTouches){
 auto event=modernContactEvent(contacts,phase);assert(event&&CGEventGetType(event)==29);
 auto data=CGEventCreateData(kCFAllocatorDefault,event);assert(data);
 auto decoded=CGEventCreateFromData(kCFAllocatorDefault,data);assert(decoded);
 auto hid=hidTimestampAPI().copy(decoded);assert(hid&&hidTimestampAPI().sender(hid)==localTouchDeviceID());
 auto children=IOHIDEventGetChildren(hid);assert(children&&CFArrayGetCount(children)==(CFIndex)contacts.size());
 unsigned count=0;
 for(CFIndex i=0;i<CFArrayGetCount(children);i++){
  auto child=(CFTypeRef)CFArrayGetValueAtIndex(children,i);
  auto id=(uint32_t)IOHIDEventGetIntegerValue(child,kIOHIDEventFieldDigitizerIdentity);
  assert(contacts.count(id));count++;
 }
 NSUInteger touches=0;NSInteger subtype=0;NSEventPhase nsPhase=NSEventPhaseNone;
 @try{NSEvent *native=[NSEvent eventWithCGEvent:decoded];touches=native.allTouches.count;subtype=native.subtype;nsPhase=native.phase;}@catch(NSException*){}
 printf("%s contacts=%zu hid_children=%u cg_bytes=%ld appkit_touches=%lu cg_subtype=%lld cg_phase=%lld ns_subtype=%ld ns_phase=%lu\n",label,contacts.size(),count,(long)CFDataGetLength(data),(unsigned long)touches,(long long)CGEventGetIntegerValueField(decoded,(CGEventField)0x6e),(long long)CGEventGetIntegerValueField(decoded,(CGEventField)0x84),(long)subtype,(unsigned long)nsPhase);
 assert((!requireTouches||touches==contacts.size())&&CGEventGetIntegerValueField(decoded,(CGEventField)0x84)==phase);
 CFRelease(hid);CFRelease(decoded);CFRelease(data);CFRelease(event);
}
int main(int argc,const char **argv){
 if(argc!=2)return 2;
 @autoreleasepool {
  NSData *file=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  const uint8_t *bytes=(const uint8_t *)file.bytes;
  if(file.length<48||memcmp(bytes,"RDAICAP1",8))return 2;
  uint32_t cg=little32(bytes+8),raw=little32(bytes+12);
  if(cg>65536||raw>336||file.length!=48ULL+cg+raw||raw<16)return 2;
  auto cgData=CFDataCreate(kCFAllocatorDefault,bytes+48,cg);
  auto airEvent=cgData?CGEventCreateFromData(kCFAllocatorDefault,cgData):nullptr;
  if(cgData)CFRelease(cgData);
  assert(airEvent&&CGEventGetType(airEvent)==29);
  auto airHID=hidTimestampAPI().copy(airEvent);assert(airHID);
  auto airChildren=IOHIDEventGetChildren(airHID);
  NSUInteger airTouches=0;NSInteger airSubtype=0;NSEventPhase airPhase=NSEventPhaseNone;
  @try{NSEvent *native=[NSEvent eventWithCGEvent:airEvent];airTouches=native.allTouches.count;airSubtype=native.subtype;airPhase=native.phase;}@catch(NSException*){}
  printf("physical_air_cg29 hid_children=%ld appkit_touches=%lu cg_subtype=%lld cg_phase=%lld ns_subtype=%ld ns_phase=%lu\n",airChildren?(long)CFArrayGetCount(airChildren):0,(unsigned long)airTouches,(long long)CGEventGetIntegerValueField(airEvent,(CGEventField)0x6e),(long long)CGEventGetIntegerValueField(airEvent,(CGEventField)0x84),(long)airSubtype,(unsigned long)airPhase);
  CFRelease(airHID);CFRelease(airEvent);
  std::map<uint32_t,RawContact> contacts;uint64_t airID=0;
  assert(decodeContacts(bytes+48+cg,raw,contacts,airID)&&contacts.size()==2&&airID);
  assert(air_host_raw_supported()==0);
  verify("physical_end_frame",contacts,4,false);
  for(auto &entry:contacts)entry.second.state=3;
  verify("synthetic_begin",contacts,1,true);
  for(auto &entry:contacts)entry.second.state=4;
  verify("synthetic_move",contacts,2,true);
  for(auto &entry:contacts)entry.second.state=5;
  verify("synthetic_end",contacts,4,true);
 }
}
