#import <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <cassert>
#include <cstdio>

extern "C" {
CFTypeRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
CFTypeRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
void IOHIDEventAppendEvent(CFTypeRef,CFTypeRef,uint32_t);
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
CFTypeRef IOHIDEventCreateWithData(CFAllocatorRef,CFDataRef);
CFArrayRef IOHIDEventGetChildren(CFTypeRef);
}

int main(){
 uint64_t stamp=mach_absolute_time();
 auto parent=IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,stamp,3,0,0,7,0,0,0,0,0,0,true,true,0);
 if(!parent){puts("Cannot create digitizer parent");return 1;}
 for(uint32_t id=1;id<=2;id++){
  auto finger=IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,stamp,id,id,7,id==1?.45:.55,.5,0,.5,0,true,true,0);
  if(!finger){CFRelease(parent);puts("Cannot create digitizer finger");return 1;}
  IOHIDEventAppendEvent(parent,finger,0);CFRelease(finger);
 }
 auto bytes=IOHIDEventCreateData(kCFAllocatorDefault,parent);
 auto copy=bytes?IOHIDEventCreateWithData(kCFAllocatorDefault,bytes):nullptr;
 auto children=IOHIDEventGetChildren(parent);
 auto decoded=copy?IOHIDEventGetChildren(copy):nullptr;
 fprintf(stdout,"modern_hid_bytes=%ld original_children=%ld decoded_children=%ld\n",bytes?(long)CFDataGetLength(bytes):0,children?(long)CFArrayGetCount(children):0,decoded?(long)CFArrayGetCount(decoded):0);
 bool valid=bytes&&CFDataGetLength(bytes)>0&&children&&CFArrayGetCount(children)==2&&decoded&&CFArrayGetCount(decoded)==2;
 if(copy)CFRelease(copy);if(bytes)CFRelease(bytes);CFRelease(parent);
 return valid?0:2;
}
