// Read-only CG/HID mutation probe using the saved physical Air packet.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

extern "C" {
CFTypeRef CGEventCopyIOHIDEvent(CGEventRef);
void IOHIDEventSetSenderID(CFTypeRef,uint64_t);
uint64_t IOHIDEventGetSenderID(CFTypeRef);
}
static uint32_t little32(const uint8_t *bytes){uint32_t value;memcpy(&value,bytes,4);return CFSwapInt32LittleToHost(value);}
static void report(const char *name,CGEventRef event){
 NSUInteger touches=0;NSUInteger phase=0;NSInteger subtype=0;
 @try{NSEvent *native=[NSEvent eventWithCGEvent:event];touches=native.allTouches.count;phase=native.phase;subtype=native.subtype;}@catch(NSException*){}
 auto wire=CGEventCreateData(nullptr,event);
 auto hid=CGEventCopyIOHIDEvent(event);
 printf("%s cg_type=%u cg_subtype=%lld cg_phase=%lld ns_subtype=%ld ns_phase=%lu touches=%lu sender=%llu wire=%ld\n",
  name,(unsigned)CGEventGetType(event),(long long)CGEventGetIntegerValueField(event,(CGEventField)0x6e),
  (long long)CGEventGetIntegerValueField(event,(CGEventField)0x84),(long)subtype,(unsigned long)phase,
  (unsigned long)touches,(unsigned long long)(hid?IOHIDEventGetSenderID(hid):0),wire?(long)CFDataGetLength(wire):0);
 if(hid)CFRelease(hid);if(wire)CFRelease(wire);
}
int main(int argc,const char **argv){
 if(argc!=3){fprintf(stderr,"usage: air_gesture_metadata_probe PHYSICAL_RDAICAP1.bin LOCAL_TRACKPAD_ID\n");return 2;}
 char *end=nullptr;uint64_t local=strtoull(argv[2],&end,10);if(!local||!end||*end)return 2;
 @autoreleasepool {
  NSData *file=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  const uint8_t *bytes=(const uint8_t *)file.bytes;
  if(file.length<48||memcmp(bytes,"RDAICAP1",8))return 2;
  uint32_t length=little32(bytes+8);if(!length||length>65536||file.length<48ULL+length)return 2;
  auto packet=CFDataCreate(nullptr,bytes+48,length);
  auto original=CGEventCreateFromData(nullptr,packet);CFRelease(packet);if(!original||CGEventGetType(original)!=29)return 2;
  report("original",original);
  const struct {const char *name;int subtype,phase;bool retarget;} variants[]={
   {"subtype11",11,0,false},{"phase1",0,1,false},{"contact_begin",11,1,false},
   {"retarget_only",0,0,true},{"retarget_begin",11,1,true}
  };
  for(const auto &variant:variants){
   auto event=CGEventCreateCopy(original);
   if(variant.subtype)CGEventSetIntegerValueField(event,(CGEventField)0x6e,variant.subtype);
   if(variant.phase)CGEventSetIntegerValueField(event,(CGEventField)0x84,variant.phase);
   if(variant.retarget){auto hid=CGEventCopyIOHIDEvent(event);if(hid){IOHIDEventSetSenderID(hid,local);CFRelease(hid);}}
   report(variant.name,event);
   auto wire=CGEventCreateData(nullptr,event);
   auto copy=wire?CGEventCreateFromData(nullptr,wire):nullptr;
   if(copy){char label[64];snprintf(label,sizeof(label),"%s_roundtrip",variant.name);report(label,copy);CFRelease(copy);}
   if(wire)CFRelease(wire);CFRelease(event);
  }
  CFRelease(original);
 }
}
