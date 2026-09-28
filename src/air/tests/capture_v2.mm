#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include "capture_v2.h"
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <mutex>
#include <cstdio>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <utility>
#include <vector>

extern "C" {
CFTypeRef IOHIDEventCreateWithData(CFAllocatorRef,CFDataRef);
uint64_t IOHIDEventGetSenderID(CFTypeRef);
uint64_t air_input_generation(void);
int air_input_grabbing(void);
int air_input_capture_mt(int);
int air_input_secure_active(void);
}

static constexpr uint32_t maxRecords=16384,maxPayloadBytes=16*1024*1024,maxCGBytes=65536,maxMTBytes=336;
static_assert(16+16*20==maxMTBytes,"Raw frame cap must match 16 contacts");
static constexpr uint32_t fileHeaderBytes=64,recordHeaderBytes=48;
static constexpr uint16_t kindCG=1,kindMT=2;
struct CaptureRecord {
 uint16_t kind=0,type=0;
 uint64_t monotonicNs=0,sourceTimestamp=0,sender=0;
 uint32_t phase=0,subtype=0,touches=0;
 std::vector<uint8_t> payload;
};
struct CaptureRing {
 std::deque<CaptureRecord> records;
 size_t bytes=0;
 uint64_t dropped=0;
 uint32_t cgCaptured=0,mtCaptured=0;
 bool add(CaptureRecord &&record){
  size_t size=recordHeaderBytes+record.payload.size();
  if(!record.payload.size()||size>maxPayloadBytes){dropped++;return false;}
  while(!records.empty()&&(records.size()>=maxRecords||bytes+size>maxPayloadBytes)){
   bytes-=recordHeaderBytes+records.front().payload.size();records.pop_front();dropped++;
  }
  bytes+=size;if(record.kind==kindCG)cgCaptured++;else if(record.kind==kindMT)mtCaptured++;
  records.push_back(std::move(record));return true;
 }
};
static void append16(std::vector<uint8_t> &out,uint16_t value){value=CFSwapInt16HostToLittle(value);auto p=(uint8_t *)&value;out.insert(out.end(),p,p+2);}
static void append32(std::vector<uint8_t> &out,uint32_t value){value=CFSwapInt32HostToLittle(value);auto p=(uint8_t *)&value;out.insert(out.end(),p,p+4);}
static void append64(std::vector<uint8_t> &out,uint64_t value){value=CFSwapInt64HostToLittle(value);auto p=(uint8_t *)&value;out.insert(out.end(),p,p+8);}
static std::vector<uint8_t> serialize(const CaptureRing &ring,uint32_t tapDisabled){
 std::vector<uint8_t> out;out.reserve(fileHeaderBytes+ring.bytes);
 const char magic[8]={'R','D','A','I','C','A','P','2'};out.insert(out.end(),magic,magic+8);
 append32(out,fileHeaderBytes);append32(out,(uint32_t)ring.records.size());append64(out,ring.dropped);
 append32(out,maxRecords);append32(out,maxPayloadBytes);
 append64(out,ring.records.empty()?0:ring.records.front().monotonicNs);
 append64(out,ring.records.empty()?0:ring.records.back().monotonicNs);
 append32(out,ring.cgCaptured);append32(out,ring.mtCaptured);append32(out,tapDisabled);append32(out,0);
 for(const auto &record:ring.records){
  append32(out,recordHeaderBytes+(uint32_t)record.payload.size());
  append16(out,record.kind);append16(out,record.type);
  append64(out,record.monotonicNs);append64(out,record.sourceTimestamp);append64(out,record.sender);
  append32(out,record.phase);append32(out,record.subtype);append32(out,record.touches);append32(out,(uint32_t)record.payload.size());
  out.insert(out.end(),record.payload.begin(),record.payload.end());
 }
 return out;
}
static bool save(int fd,const char *path,const CaptureRing &ring,uint32_t tapDisabled){
 auto bytes=serialize(ring,tapDisabled);
 struct stat owned{};bool haveOwned=fd>=0&&!fstat(fd,&owned);
 size_t left=bytes.size();const uint8_t *cursor=bytes.data();bool okay=true;
 while(left){ssize_t wrote=write(fd,cursor,left);if(wrote<0&&errno==EINTR)continue;if(wrote<=0){okay=false;break;}cursor+=wrote;left-=wrote;}
 struct stat current{};
 if(!haveOwned||lstat(path,&current)||owned.st_dev!=current.st_dev||owned.st_ino!=current.st_ino)okay=false;
 if(close(fd))okay=false;
 if(!okay&&haveOwned&&!lstat(path,&current)&&owned.st_dev==current.st_dev&&owned.st_ino==current.st_ino)unlink(path);
 return okay;
}
struct CaptureState {
 std::mutex mutex;
 CaptureRing ring;
 std::atomic<bool> active{false};
 std::atomic<int> status{0};
 std::atomic<uint64_t> generation{0};
 std::atomic<uint32_t> tapDisabled{0};
 NSString *path=nil;
 int fd=-1;
 CFMachPortRef tap=nullptr;
 CFRunLoopSourceRef source=nullptr;
};
static CaptureState capture;
static int abortStart(int error){
 if(capture.tap){CFMachPortInvalidate(capture.tap);CFRelease(capture.tap);capture.tap=nullptr;}
 if(capture.source){CFRunLoopRemoveSource(CFRunLoopGetMain(),capture.source,kCFRunLoopCommonModes);CFRelease(capture.source);capture.source=nullptr;}
 const char *path=capture.path.fileSystemRepresentation;
 if(capture.fd>=0){struct stat owned{},current{};bool remove=path&&!fstat(capture.fd,&owned)&&!lstat(path,&current)&&owned.st_dev==current.st_dev&&owned.st_ino==current.st_ino;close(capture.fd);capture.fd=-1;if(remove)unlink(path);}
 capture.path=nil;capture.status=error;return error;
}
static void markDropped(){std::lock_guard<std::mutex> lock(capture.mutex);if(capture.active)capture.ring.dropped++;}
static uint64_t senderFromCGData(const uint8_t *bytes,size_t size){
 for(size_t i=2;i+2<size;i++)if(bytes[i]==0x10&&bytes[i+1]==0x6d){
  uint16_t length=((uint16_t)bytes[i-2]<<8)|bytes[i-1];if(i+2+length>size)continue;
  auto data=CFDataCreate(kCFAllocatorDefault,bytes+i+2,length);
  auto event=data?IOHIDEventCreateWithData(kCFAllocatorDefault,data):nullptr;
  bool found=event!=nullptr;
  uint64_t sender=event?IOHIDEventGetSenderID(event):0;
  if(event)CFRelease(event);if(data)CFRelease(data);
  if(found)return sender;
 }
 return 0;
}
static bool allowedGesture(CGEventType type){return type==kCGEventScrollWheel||type==18||type==19||type==20||type==29||type==30||type==31||type==32||type==34;}
static CGEventRef captureEvent(CGEventTapProxy,CGEventType type,CGEventRef event,void *){
 if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){capture.tapDisabled++;if(capture.tap)CGEventTapEnable(capture.tap,true);return event;}
 if(!capture.active||!allowedGesture(type)||!air_input_grabbing()||!NSApp.isActive||air_input_secure_active())return event;
 auto data=CGEventCreateData(kCFAllocatorDefault,event);if(!data){markDropped();return event;}
 size_t length=CFDataGetLength(data);
 if(length&&length<=maxCGBytes){
  CaptureRecord record;record.kind=kindCG;record.type=(uint16_t)type;
  record.sourceTimestamp=CGEventGetTimestamp(event);
  record.payload.assign(CFDataGetBytePtr(data),CFDataGetBytePtr(data)+length);
  record.sender=senderFromCGData(record.payload.data(),record.payload.size());
  @try{NSEvent *native=[NSEvent eventWithCGEvent:event];record.phase=(uint32_t)native.phase;record.subtype=(uint32_t)native.subtype;if(type==29)record.touches=(uint32_t)native.allTouches.count;}@catch(NSException*){}
  std::lock_guard<std::mutex> lock(capture.mutex);if(capture.active){record.monotonicNs=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);capture.ring.add(std::move(record));}
 }else markDropped();
 CFRelease(data);return event;
}
extern "C" void air_capture_v2_record_mt(const unsigned char *packet,unsigned long length,double sourceTimestamp){
 if(!capture.active)return;
 if(!packet||length<16||length>maxMTBytes||memcmp(packet,"RDAF\x01",5)||packet[5]>16||length!=16+packet[5]*20){markDropped();return;}
 CaptureRecord record;record.kind=kindMT;record.touches=packet[5];record.payload.assign(packet,packet+length);
 memcpy(&record.sender,packet+8,8);record.sender=CFSwapInt64LittleToHost(record.sender);
 memcpy(&record.sourceTimestamp,&sourceTimestamp,8);
 std::lock_guard<std::mutex> lock(capture.mutex);if(capture.active){record.monotonicNs=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);capture.ring.add(std::move(record));}
}
extern "C" int air_capture_v2_start(int seconds,const char *path){
 if(capture.active)return -1;
 if(![NSThread isMainThread]||seconds<1||seconds>60||!path||path[0]!='/'||strlen(path)>4096){capture.status=-1;return -1;}
 if(!CGPreflightListenEventAccess()){capture.status=-2;return -2;}
 {std::lock_guard<std::mutex> lock(capture.mutex);capture.ring=CaptureRing();}
 capture.path=[NSString stringWithUTF8String:path];if(!capture.path){capture.status=-1;return -1;}
 capture.tapDisabled=0;capture.status=0;
 capture.fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
 if(capture.fd<0){capture.status=-5;capture.path=nil;return -5;}
 if(fchmod(capture.fd,0600))return abortStart(-5);
 CGEventMask mask=0;for(unsigned type=0;type<64;type++)if(allowedGesture((CGEventType)type))mask|=CGEventMaskBit(type);
 capture.tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,captureEvent,nullptr);
 if(!capture.tap)return abortStart(-3);
 capture.source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,capture.tap,0);
 if(!capture.source)return abortStart(-3);
 CFRunLoopAddSource(CFRunLoopGetMain(),capture.source,kCFRunLoopCommonModes);
 if(air_input_capture_mt(1))return abortStart(-7);
 capture.active=true;capture.status=1;
 fprintf(stderr,"air_native_session_capture_started=1 duration_seconds=%d started_unix_ms=%llu started_uptime_ns=%llu\n",seconds,(unsigned long long)(clock_gettime_nsec_np(CLOCK_REALTIME)/1000000),(unsigned long long)clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
 uint64_t generation=++capture.generation;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)seconds*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(capture.generation==generation)air_capture_v2_stop();});
 return 0;
}
extern "C" void air_capture_v2_stop(){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_capture_v2_stop();});return;}
 if(!capture.active.exchange(false))return;
 air_input_capture_mt(0);
 if(capture.tap){CGEventTapEnable(capture.tap,false);CFMachPortInvalidate(capture.tap);CFRelease(capture.tap);capture.tap=nullptr;}
 if(capture.source){CFRunLoopRemoveSource(CFRunLoopGetMain(),capture.source,kCFRunLoopCommonModes);CFRelease(capture.source);capture.source=nullptr;}
 CaptureRing snapshot;{std::lock_guard<std::mutex> lock(capture.mutex);snapshot=std::move(capture.ring);}
 capture.status=save(capture.fd,capture.path.fileSystemRepresentation,snapshot,capture.tapDisabled)?2:-4;
 fprintf(stderr,"air_native_session_capture_status=%d records=%zu dropped=%llu tap_disabled=%u\n",(int)capture.status.load(),snapshot.records.size(),(unsigned long long)snapshot.dropped,(unsigned)capture.tapDisabled.load());
 capture.fd=-1;
 capture.path=nil;
}
extern "C" int air_capture_v2_status(){return capture.status;}
extern "C" void air_capture_v2_schedule(int seconds,const char *path,unsigned long long generation){
 if(!path||strlen(path)>4096){capture.status=-1;fprintf(stderr,"air_native_session_capture_start_error=-1\n");return;}
 @autoreleasepool {
  NSString *destination=[NSString stringWithUTF8String:path];
  if(!destination){capture.status=-1;fprintf(stderr,"air_native_session_capture_start_error=-1\n");return;}
  dispatch_async(dispatch_get_main_queue(),^{
   if(air_input_generation()!=generation||!air_input_grabbing()||!NSApp.isActive){
    capture.status=-6;fprintf(stderr,"air_native_session_capture_start_error=-6\n");return;
   }
   int result=air_capture_v2_start(seconds,destination.fileSystemRepresentation);
   if(result)fprintf(stderr,"air_native_session_capture_start_error=%d\n",result);
  });
 }
}
