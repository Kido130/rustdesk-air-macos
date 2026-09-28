// Offline read-only timestamp inspection. No event tap, window, or CGEventPost.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <time.h>

extern "C" {
CFTypeRef CGEventCopyIOHIDEvent(CGEventRef);
CFTypeRef IOHIDEventCreateWithData(CFAllocatorRef,CFDataRef);
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
CFArrayRef IOHIDEventGetChildren(CFTypeRef);
uint64_t IOHIDEventGetTimeStamp(CFTypeRef);
void IOHIDEventSetTimeStamp(CFTypeRef,uint64_t);
}

static uint32_t little32(const uint8_t *bytes){uint32_t value;memcpy(&value,bytes,4);return CFSwapInt32LittleToHost(value);}
static bool hidField(const uint8_t *bytes,size_t size,size_t *offset,uint16_t *length){
 for(size_t i=2;i+2<size;i++)if(bytes[i]==0x10&&bytes[i+1]==0x6d){
  uint16_t n=((uint16_t)bytes[i-2]<<8)|bytes[i-1];
  if(i+2+n<=size){auto data=CFDataCreate(kCFAllocatorDefault,bytes+i+2,n);
   auto hid=data?IOHIDEventCreateWithData(kCFAllocatorDefault,data):nullptr;
   bool found=hid!=nullptr;
   if(hid)CFRelease(hid);if(data)CFRelease(data);
   if(found){*offset=i-2;*length=n;return true;}
  }
 }
 return false;
}
static CFTypeRef hidFromCGData(CFDataRef data){
 if(!data)return nullptr;
 size_t offset;uint16_t length;auto bytes=CFDataGetBytePtr(data);size_t size=CFDataGetLength(data);
 if(!hidField(bytes,size,&offset,&length))return nullptr;
 auto fragment=CFDataCreate(kCFAllocatorDefault,bytes+offset+4,length);
 auto hid=fragment?IOHIDEventCreateWithData(kCFAllocatorDefault,fragment):nullptr;
 if(fragment)CFRelease(fragment);return hid;
}
static void report(const char *label,CGEventRef cg){
 auto encoded=cg?CGEventCreateData(kCFAllocatorDefault,cg):nullptr;
 auto hid=hidFromCGData(encoded);
 auto copied=cg?CGEventCopyIOHIDEvent(cg):nullptr;
 auto children=hid?IOHIDEventGetChildren(hid):nullptr;
 printf("%s outer_ns=%llu parent_hid_ticks=%llu child_count=%ld",label,
  (unsigned long long)(cg?CGEventGetTimestamp(cg):0),
  (unsigned long long)(hid?IOHIDEventGetTimeStamp(hid):0),
  children?(long)CFArrayGetCount(children):0L);
 if(children)for(CFIndex i=0;i<CFArrayGetCount(children);i++)
  printf(" child%ld_ticks=%llu",(long)i,(unsigned long long)IOHIDEventGetTimeStamp(CFArrayGetValueAtIndex(children,i)));
 printf(" copied_hid=%d copied_ticks=%llu encoded_bytes=%ld\n",copied!=nullptr,
  (unsigned long long)(copied?IOHIDEventGetTimeStamp(copied):0),encoded?(long)CFDataGetLength(encoded):0L);
 if(copied)CFRelease(copied);if(hid)CFRelease(hid);if(encoded)CFRelease(encoded);
}
int main(int argc,const char **argv){
 @autoreleasepool {
  if(argc!=2){fprintf(stderr,"usage: inspect_capture_timestamps RDAICAP1.bin\n");return 2;}
  NSData *file=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  auto bytes=(const uint8_t *)file.bytes;
  if(file.length<48||memcmp(bytes,"RDAICAP1",8)){fprintf(stderr,"invalid capture\n");return 2;}
  uint32_t cgLength=little32(bytes+8),rawLength=little32(bytes+12);
  if(!cgLength||cgLength>65536||rawLength>336||file.length!=48ULL+cgLength+rawLength){fprintf(stderr,"invalid packet lengths\n");return 2;}
  auto input=CFDataCreate(kCFAllocatorDefault,bytes+48,cgLength);
  auto cg=CGEventCreateFromData(kCFAllocatorDefault,input);CFRelease(input);
  if(!cg){fprintf(stderr,"CGEventCreateFromData failed\n");return 1;}
  mach_timebase_info_data_t timebase{};mach_timebase_info(&timebase);
  uint64_t localTicks=mach_absolute_time(),localNs=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  printf("pro_now mach_ticks=%llu uptime_ns=%llu mach_timebase=%u/%u\n",
   (unsigned long long)localTicks,(unsigned long long)localNs,timebase.numer,timebase.denom);
  report("air_packet",cg);
  CGEventSetTimestamp(cg,localNs);
  report("outer_rewritten_only",cg);
  auto attached=CGEventCopyIOHIDEvent(cg);
  if(attached){
   IOHIDEventSetTimeStamp(attached,localTicks);
   auto children=IOHIDEventGetChildren(attached);
   if(children)for(CFIndex i=0;i<CFArrayGetCount(children);i++)IOHIDEventSetTimeStamp(CFArrayGetValueAtIndex(children,i),localTicks);
   report("mutated_copy_only",cg);
   CFRelease(attached);
   report("after_copy_release",cg);
  }

  auto normalized=CGEventCreateData(kCFAllocatorDefault,cg);
  size_t offset;uint16_t length;
  if(normalized&&hidField(CFDataGetBytePtr(normalized),CFDataGetLength(normalized),&offset,&length)){
   auto hid=hidFromCGData(normalized);
   if(hid){
    IOHIDEventSetTimeStamp(hid,localTicks);
    auto children=IOHIDEventGetChildren(hid);
    if(children)for(CFIndex i=0;i<CFArrayGetCount(children);i++)IOHIDEventSetTimeStamp(CFArrayGetValueAtIndex(children,i),localTicks);
    auto encoded=IOHIDEventCreateData(kCFAllocatorDefault,hid);
    if(encoded&&CFDataGetLength(encoded)<=UINT16_MAX){
     auto replaced=CFDataCreateMutableCopy(kCFAllocatorDefault,0,normalized);
     uint16_t newLength=CFSwapInt16HostToBig((uint16_t)CFDataGetLength(encoded));
     CFDataReplaceBytes(replaced,CFRangeMake(offset,2),(const uint8_t *)&newLength,2);
     CFDataReplaceBytes(replaced,CFRangeMake(offset+4,length),CFDataGetBytePtr(encoded),CFDataGetLength(encoded));
     auto rewritten=CGEventCreateFromData(kCFAllocatorDefault,replaced);
     report("outer_and_nested_rewritten",rewritten);
     if(rewritten)CFRelease(rewritten);CFRelease(replaced);
    }
    if(encoded)CFRelease(encoded);CFRelease(hid);
   }
  }
  if(normalized)CFRelease(normalized);CFRelease(cg);
  return 0;
 }
}
