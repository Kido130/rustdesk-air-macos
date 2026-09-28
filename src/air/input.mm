#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include "native.h"
#include "spaces.h"
#include "edge_drag_policy.h"
#include "dockswipe27.h"
#include "IOHIDEventTypes.h"
#include "tests/capture_v2.h"
#ifdef __cplusplus
extern "C" {
#endif
#include "TouchEvents.h"
#ifdef __cplusplus
}
#endif
#include <atomic>
#include <set>
#include <map>
#include <vector>
#include <mutex>
#include <cmath>
#include <algorithm>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <time.h>
#include <stdio.h>
#include <unistd.h>

static AirNativeEvent sendNative=nullptr;
static AirReleaseInput releaseRemote=nullptr;
static CFMachPortRef inputTap=nullptr;
static CFRunLoopSourceRef inputSource=nullptr;
static std::atomic<bool> connected(false), enabled(false);
static std::atomic<bool> localUI(false);
static std::atomic<bool> rawAllowed(false);
static std::atomic<bool> rawFullEnabled(true);
static std::atomic<int> rawProbeSeconds(0);
static std::atomic<uint64_t> clientRawDeadline(0);
static std::atomic<bool> clientRawSpent(false);
static std::atomic<bool> clientRawRejected(false);
static std::atomic<bool> diagnosticCapture(false);
static bool clientInput=false;
static IOPMAssertionID awakeAssertion=kIOPMNullAssertionID;
static std::atomic<uint64_t> forwarded(0), gestures(0), contacts(0), injected(0), escapes(0);
static std::atomic<uint64_t> rawFramesSent(0),rawFramesPosted(0),rawStaleRejected(0),rawContactDuplicates(0);
static std::mutex gestureSampleMutex;
static std::vector<uint8_t> gestureSample;
static NSUInteger gestureSampleTouches=0;
static std::vector<uint8_t> rawSample;
static std::atomic<bool> captureMode(false);
static std::atomic<uint64_t> captureGeneration(0),captureGestures(0),captureFrames(0),captureContacts(0),captureNSETouches(0);
static NSString *capturePath;
static bool captureOwnsSetup=false;
static std::atomic<unsigned> pendingPackets(0);
static std::atomic<uint64_t> inputGeneration(0);
static std::atomic<uint64_t> grabGeneration(0);
static std::atomic<uint64_t> lastTapTimeoutRecoveryNs(0);
static dispatch_queue_t sendQueue;
static void *mtLibrary;
static void *hitoolboxLibrary;
static unsigned char (*secureInputEnabled)();
typedef CFTypeRef MTDeviceRef;
struct MTPoint { float x,y; };
struct MTVector { MTPoint position,velocity; };
struct MTTouch { int32_t frame; double timestamp; int32_t pathIndex,state,fingerID,handID; MTVector normalizedVector; float zTotal; int32_t field9; float angle,majorAxis,minorAxis; MTVector absoluteVector; int32_t field14,field15; float zDensity; };
typedef void (*MTCallback)(MTDeviceRef,MTTouch *,size_t,double,size_t);
static CFArrayRef (*mtDevices)();
static int (*mtStart)(MTDeviceRef,int),(*mtStop)(MTDeviceRef);
static bool (*mtRegister)(MTDeviceRef,MTCallback);
static void (*mtUnregister)(MTDeviceRef,MTCallback);
static int (*mtDeviceID)(MTDeviceRef,uint64_t *);
static CFArrayRef mtDeviceList;
static std::atomic<bool> mtRunning(false);
static uint64_t mtID=0;
static std::mutex hostInputMutex;
static std::mutex edgeTransferMutex;
static uint64_t edgeTransferEpoch=0;
static int hostOwner=0;
static struct {int owner=0,slot=0,observedAdjacent=0;uint32_t wid=0;pid_t pid=0;CGRect display=CGRectNull;EdgeDragPolicy policy;} edgeDrag;
static bool hostShutdown=false;
static bool hostRawSpent=false,hostRawReady=false,hostRawExpired=false;
static bool hostRawFull=false;
static uint64_t hostRawDeadline=0;
static std::set<CGKeyCode> hostKeys;
static CGEventFlags hostFlags=0;
static std::set<int> hostMedia;
struct RawContact { uint32_t id,state; float x,y,pressure; int32_t pathIndex=0,handID=0,touchFrame=0; double touchTimestamp=0; float vx=0,vy=0,angle=0,major=0,minor=0,absoluteX=0,absoluteY=0,absoluteVX=0,absoluteVY=0,density=0; };
static std::map<uint32_t,RawContact> hostContacts;
static uint64_t hostTouchDevice=0;
static uint64_t hostLocalTouchDevice=0;
static uint64_t hostSourceAnchor=0,hostLocalAnchor=0,hostLastSource=0,hostLastSequence=0,hostLastTargetNs=0;
static std::atomic<uint64_t> rawSequence(0);
typedef void (*AirNativeSpaceSwipe)(int,int,uint64_t);
static std::atomic<AirNativeSpaceSwipe> spaceSwipeCallback(nullptr);
struct SwipeState {bool active=false;uint64_t device=0,generation=0,firstNs=0,lastNs=0,lastSequence=0;uint32_t ids[3]={0,0,0};double startX=0,startY=0,lastX=0,lastY=0;};
static std::mutex swipeMutex;
static SwipeState swipe;
static const int64_t inputTag=0x5244414952;
static const uint8_t rawMagic[8]={'R','D','A','F',1,0,0,0};
static const size_t rawV2Header=48,rawV2Contact=88,rawV2Max=rawV2Header+16*rawV2Contact;
static void releaseClient();
static void finishCapture();
static void stopMT();
static bool startMT();
extern "C" void air_input_shutdown();
static void abortInputSetup(){air_input_shutdown();sendNative=nullptr;releaseRemote=nullptr;sendQueue=nullptr;}
static uint64_t uptimeNs(){return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
static bool inputTrace(){static bool enabled=[](){const char *value=getenv("RUSTDESK_AIR_INPUT_TRACE");return value&&strcmp(value,"1")==0;}();return enabled;}
static void traceRaw(const char *stage,uint64_t sequence,unsigned count,uint64_t sourceNs,const char *reason="ok"){
 if(inputTrace())fprintf(stderr,"air_input_trace stage=%s seq=%llu count=%u source_ns=%llu local_ns=%llu reason=%s\n",stage,(unsigned long long)sequence,count,(unsigned long long)sourceNs,(unsigned long long)uptimeNs(),reason);
}
static bool clientRawActive(){if(!rawAllowed)return false;if(rawFullEnabled&&rawProbeSeconds==0)return true;uint64_t deadline=clientRawDeadline.load();return deadline&&uptimeNs()<deadline;}
static bool rawContactsAuthoritative(){return clientRawActive();}
static bool nativeTrackpadType(CGEventType type){return type==kCGEventScrollWheel||type==18||type==19||type==20||type==29||type==30||type==31||type==32||type==34;}
// The Air captures completed wheel events at the session tap. Re-inserting
// those events at the HID tap would send their deltas through WindowServer's
// device processing again on the Pro.
static CGEventTapLocation nativeReplayTap(CGEventType type,bool dockSwipe27){
 return type==kCGEventScrollWheel||dockSwipe27?kCGSessionEventTap:kCGHIDEventTap;
}
static bool contactOnlyCG29(CGEventRef event);
// Raw frames own finger contacts. The Air's scroll, magnify, swipe, and Dock
// events carry gesture meaning that a synthetic contact event need not recreate.
static bool suppressNativeTrackpadEvent(CGEventType type,CGEventRef event){
 return rawContactsAuthoritative()&&type==29&&contactOnlyCG29(event);
}
static void rawPut32(uint8_t *at,uint32_t value){value=CFSwapInt32HostToLittle(value);memcpy(at,&value,4);}
static void rawPut64(uint8_t *at,uint64_t value){value=CFSwapInt64HostToLittle(value);memcpy(at,&value,8);}
static uint32_t rawGet32(const uint8_t *at){uint32_t value;memcpy(&value,at,4);return CFSwapInt32LittleToHost(value);}
static uint64_t rawGet64(const uint8_t *at){uint64_t value;memcpy(&value,at,8);return CFSwapInt64LittleToHost(value);}
static void rawPutFloat(uint8_t *at,float value){uint32_t bits;memcpy(&bits,&value,4);rawPut32(at,bits);}
static void rawPutDouble(uint8_t *at,double value){uint64_t bits;memcpy(&bits,&value,8);rawPut64(at,bits);}
static float rawGetFloat(const uint8_t *at){uint32_t bits=rawGet32(at);float value;memcpy(&value,&bits,4);return value;}
static double rawGetDouble(const uint8_t *at){uint64_t bits=rawGet64(at);double value;memcpy(&value,&bits,8);return value;}
static void cancelSwipe(){AirNativeSpaceSwipe callback=nullptr;uint64_t generation=0;{std::lock_guard<std::mutex> lock(swipeMutex);if(!swipe.active)return;generation=swipe.generation;swipe.active=false;callback=spaceSwipeCallback.load();}if(callback)callback(3,0,generation);}
struct SwipeNotice {int phase=0,direction=0;uint64_t generation=0;AirNativeSpaceSwipe callback=nullptr;};
static SwipeNotice noteSwipe(uint64_t device,uint64_t sequence,uint64_t sourceNs,const MTTouch *touches,int count){
 uint32_t ids[3]={0,0,0};int active=0;double x=0,y=0;bool ended=false;
 for(int i=0;i<count;i++){const auto &touch=touches[i];if(touch.state==3||touch.state==4){if(active<3)ids[active]=(uint32_t)touch.fingerID;x+=touch.normalizedVector.position.x;y+=touch.normalizedVector.position.y;active++;}else if(touch.state==5||touch.state==6||touch.state==7)ended=true;}
 if(active==3){std::sort(ids,ids+3);x/=3;y/=3;}
 int phase=0,direction=0;uint64_t generation=0;AirNativeSpaceSwipe callback=nullptr;
 {std::lock_guard<std::mutex> lock(swipeMutex);
  if(swipe.active){
   generation=swipe.generation;
   bool same=swipe.device==device&&swipe.lastSequence+1==sequence&&sourceNs>swipe.lastNs&&sourceNs-swipe.firstNs<=1200000000ULL&&count<=3;
   for(int i=0;i<count;i++)if(!std::binary_search(swipe.ids,swipe.ids+3,(uint32_t)touches[i].fingerID))same=false;
   if(active==3)same=same&&std::equal(ids,ids+3,swipe.ids);
   if(!same||active>3){swipe.active=false;phase=3;}
   else if(active==3){swipe.lastX=x;swipe.lastY=y;swipe.lastNs=sourceNs;swipe.lastSequence=sequence;}
   else if(ended||count==0){double dx=swipe.lastX-swipe.startX,dy=swipe.lastY-swipe.startY;
    if(sourceNs-swipe.firstNs>=80000000ULL&&std::abs(dx)>=.18&&std::abs(dx)>=1.5*std::abs(dy)){phase=2;direction=dx<0?-1:1;}else phase=3;swipe.active=false;
   }else{swipe.active=false;phase=3;}
  }else if(active==3&&!ended){swipe.active=true;swipe.device=device;swipe.generation=inputGeneration.load();swipe.firstNs=sourceNs;swipe.lastNs=sourceNs;swipe.lastSequence=sequence;std::copy(ids,ids+3,swipe.ids);swipe.startX=swipe.lastX=x;swipe.startY=swipe.lastY=y;generation=swipe.generation;phase=1;}
  if(phase)callback=spaceSwipeCallback.load();
 }
 if(phase==1&&callback)callback(phase,direction,generation);
 return {phase==1?0:phase,direction,generation,callback};
}
static bool validTouch(const MTTouch &t){
 const float values[]={t.normalizedVector.position.x,t.normalizedVector.position.y,t.normalizedVector.velocity.x,t.normalizedVector.velocity.y,t.zTotal,t.angle,t.majorAxis,t.minorAxis,t.absoluteVector.position.x,t.absoluteVector.position.y,t.absoluteVector.velocity.x,t.absoluteVector.velocity.y,t.zDensity};
 for(float value:values)if(!std::isfinite(value)||std::abs(value)>1000000)return false;
 return t.fingerID>=0&&t.state>=0&&t.state<=7&&std::isfinite(t.timestamp)&&t.normalizedVector.position.x>=-.25&&t.normalizedVector.position.x<=1.25&&t.normalizedVector.position.y>=-.25&&t.normalizedVector.position.y<=1.25&&t.zTotal>=0&&t.zTotal<=10000;
}
static bool provisionalDuplicateBegins(const MTTouch *touches,int count){
 std::map<int32_t,int32_t> states;bool duplicate=false;
 for(int i=0;i<count;i++){
  auto found=states.find(touches[i].fingerID);
  if(found==states.end())states[touches[i].fingerID]=touches[i].state;
  else if(touches[i].fingerID==0&&found->second==1&&touches[i].state==1)duplicate=true;
  else return false;
 }
 return duplicate;
}
static size_t encodeRawV2(uint8_t *packet,size_t capacity,uint64_t device,uint64_t sequence,uint64_t sourceNs,double frameTimestamp,uint64_t frameIndex,const MTTouch *touches,int count){
 if(!packet||count<0||count>16||capacity<rawV2Header+(size_t)count*rawV2Contact||(!touches&&count)||!std::isfinite(frameTimestamp)||!sourceNs||!sequence)return 0;
 memset(packet,0,rawV2Header+(size_t)count*rawV2Contact);memcpy(packet,"RDAF",4);packet[4]=2;packet[5]=(uint8_t)count;rawPut64(packet+8,device);rawPut64(packet+16,sequence);rawPut64(packet+24,sourceNs);rawPutDouble(packet+32,frameTimestamp);rawPut64(packet+40,frameIndex);
 std::set<uint32_t> ids;
 for(int i=0;i<count;i++){
  const auto &t=touches[i];if(!validTouch(t)||!ids.insert((uint32_t)t.fingerID).second)return 0;
  uint8_t *at=packet+rawV2Header+(size_t)i*rawV2Contact;
  rawPut32(at,(uint32_t)t.fingerID);rawPut32(at+4,(uint32_t)t.state);rawPut32(at+8,(uint32_t)t.pathIndex);rawPut32(at+12,(uint32_t)t.handID);rawPut32(at+16,(uint32_t)t.frame);rawPutDouble(at+24,t.timestamp);
  const float values[]={t.normalizedVector.position.x,t.normalizedVector.position.y,t.normalizedVector.velocity.x,t.normalizedVector.velocity.y,t.zTotal,t.angle,t.majorAxis,t.minorAxis,t.absoluteVector.position.x,t.absoluteVector.position.y,t.absoluteVector.velocity.x,t.absoluteVector.velocity.y,t.zDensity};
  for(unsigned j=0;j<13;j++)rawPutFloat(at+32+j*4,values[j]);
 }
 return rawV2Header+(size_t)count*rawV2Contact;
}
static void expireClientRaw(){
 if(!rawAllowed.exchange(false))return;
 clientRawDeadline=0;
 fprintf(stderr,"air_raw_probe_client_expired=1\n");
 if(!diagnosticCapture&&!captureMode)stopMT();
 if(connected&&releaseRemote&&sendQueue){uint64_t generation=inputGeneration.load();dispatch_async(sendQueue,^{if(releaseRemote&&inputGeneration==generation)releaseRemote(generation);});}
}

static bool queueBytes(const uint8_t *bytes,size_t len) {
 if(!sendNative||!bytes||!len)return false;
 bool raw=len>=16&&!memcmp(bytes,"RDAF",4);
 uint64_t sequence=raw&&len>=32?rawGet64(bytes+16):0,sourceNs=raw&&len>=32?rawGet64(bytes+24):0;
 unsigned count=raw?bytes[5]:0;
 if(pendingPackets.fetch_add(1)>=256){pendingPackets.fetch_sub(1);if(raw)traceRaw("native_enqueue_reject",sequence,count,sourceNs,"queue_full");return false;}
 auto data=CFDataCreate(kCFAllocatorDefault,bytes,len);
 if(!data){pendingPackets.fetch_sub(1);if(raw)traceRaw("native_enqueue_reject",sequence,count,sourceNs,"allocation");return false;}
 uint64_t generation=inputGeneration.load(),grab=grabGeneration.load();
 if(raw)traceRaw("native_enqueued",sequence,count,sourceNs);
 dispatch_async(sendQueue,^{
  const char *reason=!sendNative?"no_callback":inputGeneration!=generation?"generation":grabGeneration!=grab?"grab_generation":raw&&!clientRawActive()?"raw_inactive":raw&&localUI?"local_ui":raw&&!enabled?"disabled":raw&&!connected?"disconnected":raw&&secureInputEnabled&&secureInputEnabled()?"secure_input":nullptr;
  if(reason){if(raw)traceRaw("native_dispatch_drop",sequence,count,sourceNs,reason);}
  else{if(raw)traceRaw("native_callback",sequence,count,sourceNs);sendNative(CFDataGetBytePtr(data),CFDataGetLength(data),generation);}
  CFRelease(data);pendingPackets.fetch_sub(1);
 });
 return true;
}
static void mtFrame(MTDeviceRef device,MTTouch *touches,size_t count,double frameTimestamp,size_t frameIndex) {
 if(secureInputEnabled&&secureInputEnabled()){cancelSwipe();if(!captureMode)dispatch_async(dispatch_get_main_queue(),^{releaseClient();});return;}
 if((!captureMode&&(!connected||!enabled||(!rawAllowed&&!diagnosticCapture)))||(!touches&&count)||count>16)return;
 uint8_t legacy[16+16*20];memcpy(legacy,rawMagic,8);legacy[5]=(uint8_t)count;
 uint64_t deviceID=mtID;if(mtDeviceID)mtDeviceID(device,&deviceID);
 rawPut64(legacy+8,deviceID);
 for(size_t i=0;i<count;i++){
  auto &t=touches[i];
  if(!validTouch(t))return;
  rawPut32(legacy+16+i*20,(uint32_t)t.fingerID);rawPut32(legacy+20+i*20,(uint32_t)t.state);
  rawPutFloat(legacy+24+i*20,t.normalizedVector.position.x);rawPutFloat(legacy+28+i*20,t.normalizedVector.position.y);rawPutFloat(legacy+32+i*20,t.zTotal);
 }
 if(captureMode){std::lock_guard<std::mutex> lock(gestureSampleMutex);if(count||rawSample.empty())rawSample.assign(legacy,legacy+16+count*20);captureFrames++;captureContacts+=count;return;}
 if(diagnosticCapture)air_capture_v2_record_mt(legacy,16+count*20,frameTimestamp);
 if(localUI){cancelSwipe();return;}
 if(rawAllowed&&rawProbeSeconds>0&&!clientRawActive())dispatch_async(dispatch_get_main_queue(),^{if(!clientRawActive())expireClientRaw();});
 if(!clientRawActive())return;
 if(provisionalDuplicateBegins(touches,(int)count))return;
 uint64_t sourceNs=uptimeNs(),sequence=++rawSequence;
 uint8_t packet[rawV2Max];size_t length=encodeRawV2(packet,sizeof(packet),deviceID,sequence,sourceNs,frameTimestamp,(uint64_t)frameIndex,touches,(int)count);
 if(!length){cancelSwipe();dispatch_async(dispatch_get_main_queue(),^{releaseClient();});return;}
 auto notice=spaceSwipeCallback.load()?noteSwipe(deviceID,sequence,sourceNs,touches,(int)count):SwipeNotice{};
 if(rawContactsAuthoritative()){
  if(!queueBytes(packet,length)){if(notice.phase&&notice.callback)notice.callback(3,0,notice.generation);dispatch_async(dispatch_get_main_queue(),^{releaseClient();});return;}
  contacts+=count;rawFramesSent++;
 }
 if(notice.phase&&notice.callback)dispatch_async(sendQueue,^{if(inputGeneration==notice.generation)notice.callback(notice.phase,notice.direction,notice.generation);});
 return;
}
static void stopMT(){if(mtRunning.exchange(false)&&mtDeviceList){for(CFIndex i=0;i<CFArrayGetCount(mtDeviceList);i++)mtStop((MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,i));}}
static bool startMT(){
 if(mtRunning)return true;
 if(!mtDeviceList||!mtStart||!mtStop||!CFArrayGetCount(mtDeviceList))return false;
 CFIndex started=0;
 for(CFIndex i=0;i<CFArrayGetCount(mtDeviceList);i++){
  if(mtStart((MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,i),0)!=0){for(CFIndex j=0;j<started;j++)mtStop((MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,j));return false;}
  started++;
 }
 mtRunning=true;return true;
}
static void failRawStart(){fprintf(stderr,"air_input_intentional_stop reason=native_trackpad_start_failed\n");air_set_error("Cannot start the native trackpad; Remote Mode stopped");releaseClient();air_app_stop();}
extern "C" int air_input_capture_mt(int value){
 diagnosticCapture=value!=0;
 if(value){
  if(!connected||!enabled||!mtDeviceList||!CFArrayGetCount(mtDeviceList)){diagnosticCapture=false;return -1;}
  if(!startMT()){diagnosticCapture=false;air_set_error("Cannot start native trackpad capture");return -1;}
 }else if(!rawAllowed&&!captureMode)stopMT();
 return 0;
}
static bool registerMTDevices(){
 if(!mtDeviceList||!mtRegister||!mtUnregister||!mtDeviceID)return false;
 CFIndex registered=0;bool okay=CFArrayGetCount(mtDeviceList)>0;
 for(CFIndex i=0;i<CFArrayGetCount(mtDeviceList);i++){
  auto device=(MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,i);uint64_t id=0;
  if(mtDeviceID(device,&id)!=0||!id||!mtRegister(device,mtFrame)){okay=false;break;}
  mtID=id;registered++;
 }
 if(!okay){for(CFIndex i=0;i<registered;i++)mtUnregister((MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,i),mtFrame);CFRelease(mtDeviceList);mtDeviceList=nullptr;mtID=0;air_set_error("Cannot register native trackpad contact capture");}
 return okay;
}
static void setupMT(){
 if(!hitoolboxLibrary)hitoolboxLibrary=dlopen("/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/HIToolbox",RTLD_LAZY|RTLD_LOCAL);
 if(hitoolboxLibrary)secureInputEnabled=(unsigned char(*)())dlsym(hitoolboxLibrary,"IsSecureEventInputEnabled");
 if(!mtLibrary)mtLibrary=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY|RTLD_LOCAL);
 if(!mtLibrary)return;
 mtDevices=(CFArrayRef(*)())dlsym(mtLibrary,"MTDeviceCreateList");
 mtStart=(int(*)(MTDeviceRef,int))dlsym(mtLibrary,"MTDeviceStart");
 mtStop=(int(*)(MTDeviceRef))dlsym(mtLibrary,"MTDeviceStop");
 mtRegister=(bool(*)(MTDeviceRef,MTCallback))dlsym(mtLibrary,"MTRegisterContactFrameCallback");
 mtUnregister=(void(*)(MTDeviceRef,MTCallback))dlsym(mtLibrary,"MTUnregisterContactFrameCallback");
 mtDeviceID=(int(*)(MTDeviceRef,uint64_t *))dlsym(mtLibrary,"MTDeviceGetDeviceID");
 if(!mtDevices||!mtStart||!mtStop||!mtRegister||!mtUnregister||!mtDeviceID)return;
 mtDeviceList=mtDevices();if(!mtDeviceList)return;
 registerMTDevices();
}

static bool forwardType(CGEventType type) {
 return type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged
     ||type==kCGEventScrollWheel||type==14||type==18||type==19||type==20||type==29||type==30||type==31||type==32||type==34;
}
static bool keyboardType(CGEventType type) {
 return type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged||type==14;
}
struct HIDTimestampAPI {
 CFTypeRef (*copy)(CGEventRef)=nullptr;
 CFTypeID (*typeID)()=nullptr;
 CFArrayRef (*children)(CFTypeRef)=nullptr;
 void (*remove)(CFTypeRef,CFTypeRef)=nullptr;
 CFDataRef (*data)(CFAllocatorRef,CFTypeRef)=nullptr;
 uint64_t (*timestamp)(CFTypeRef)=nullptr;
 void (*setTimestamp)(CFTypeRef,uint64_t)=nullptr;
 uint32_t (*type)(CFTypeRef)=nullptr;
 uint64_t (*sender)(CFTypeRef)=nullptr;
 void (*setSender)(CFTypeRef,uint64_t)=nullptr;
 bool ready() const {return copy&&typeID&&children&&timestamp&&setTimestamp&&type&&sender&&setSender;}
};
static const HIDTimestampAPI &hidTimestampAPI(){
 static const HIDTimestampAPI api=[](){
  HIDTimestampAPI value;
  // Keep the frameworks loaded for the lifetime of the function pointers.
  void *cg=dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",RTLD_LAZY|RTLD_LOCAL);
  void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY|RTLD_LOCAL);
  if(cg)value.copy=(CFTypeRef(*)(CGEventRef))dlsym(cg,"CGEventCopyIOHIDEvent");
  if(io){
   value.typeID=(CFTypeID(*)())dlsym(io,"IOHIDEventGetTypeID");
   value.children=(CFArrayRef(*)(CFTypeRef))dlsym(io,"IOHIDEventGetChildren");
   value.remove=(void(*)(CFTypeRef,CFTypeRef))dlsym(io,"IOHIDEventRemoveEvent");
   value.data=(CFDataRef(*)(CFAllocatorRef,CFTypeRef))dlsym(io,"IOHIDEventCreateData");
   value.timestamp=(uint64_t(*)(CFTypeRef))dlsym(io,"IOHIDEventGetTimeStamp");
   value.setTimestamp=(void(*)(CFTypeRef,uint64_t))dlsym(io,"IOHIDEventSetTimeStamp");
   value.type=(uint32_t(*)(CFTypeRef))dlsym(io,"IOHIDEventGetType");
   value.sender=(uint64_t(*)(CFTypeRef))dlsym(io,"IOHIDEventGetSenderID");
   value.setSender=(void(*)(CFTypeRef,uint64_t))dlsym(io,"IOHIDEventSetSenderID");
  }
  return value;
 }();
 return api;
}
static unsigned hidScrollNodes(const HIDTimestampAPI &api,CFTypeRef node,unsigned depth=0){
 if(!node||depth>8||CFGetTypeID(node)!=api.typeID())return 0;
 unsigned count=api.type(node)==6;
 auto children=api.children(node);
 if(children&&CFGetTypeID(children)==CFArrayGetTypeID())for(CFIndex i=0;i<CFArrayGetCount(children);i++)
  count+=hidScrollNodes(api,(CFTypeRef)CFArrayGetValueAtIndex(children,i),depth+1);
 return count;
}
static void traceNativeScroll(const char *stage,CGEventRef event){
 if(!inputTrace())return;
 auto type=CGEventGetType(event);if(type!=kCGEventScrollWheel&&type!=29)return;
 const auto &api=hidTimestampAPI();auto hid=api.ready()?api.copy(event):nullptr;
 unsigned embedded=hid?hidScrollNodes(api,hid):0;if(hid)CFRelease(hid);
 fprintf(stderr,"air_scroll_trace stage=%s type=%u source_ts=%llu point_y=%lld point_x=%lld phase=%lld momentum=%lld embedded_hid_scroll_nodes=%u\n",
  stage,(unsigned)type,(unsigned long long)CGEventGetTimestamp(event),
  (long long)CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis1),
  (long long)CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis2),
  (long long)CGEventGetIntegerValueField(event,kCGScrollWheelEventScrollPhase),
  (long long)CGEventGetIntegerValueField(event,kCGScrollWheelEventMomentumPhase),embedded);
}
struct HIDNodeShape {uint32_t type;uint64_t sender;CFIndex children;};
static bool inspectHIDTree(const HIDTimestampAPI &api,CFTypeRef node,uint64_t expectedTimestamp,
                           std::vector<HIDNodeShape> &shape,unsigned depth){
 if(!node||depth>8||shape.size()>=32||CFGetTypeID(node)!=api.typeID()||api.timestamp(node)!=expectedTimestamp)return false;
 auto children=api.children(node);
 if(children&&CFGetTypeID(children)!=CFArrayGetTypeID())return false;
 CFIndex count=children?CFArrayGetCount(children):0;
 if(count<0||count>32||(size_t)count+shape.size()>=33)return false;
 shape.push_back({api.type(node),api.sender(node),count});
 for(CFIndex i=0;i<count;i++)if(!inspectHIDTree(api,(CFTypeRef)CFArrayGetValueAtIndex(children,i),expectedTimestamp,shape,depth+1))return false;
 return true;
}
static void setHIDTreeIdentity(const HIDTimestampAPI &api,CFTypeRef node,uint64_t timestamp,uint64_t sender){
 api.setTimestamp(node,timestamp);
 if(sender)api.setSender(node,sender);
 auto children=api.children(node);
 if(children)for(CFIndex i=0;i<CFArrayGetCount(children);i++)setHIDTreeIdentity(api,(CFTypeRef)CFArrayGetValueAtIndex(children,i),timestamp,sender);
}
static void setHIDTreeTimestamp(const HIDTimestampAPI &api,CFTypeRef node,uint64_t timestamp){setHIDTreeIdentity(api,node,timestamp,0);}
static bool sameHIDShape(const std::vector<HIDNodeShape> &before,const std::vector<HIDNodeShape> &after){
 if(before.size()!=after.size())return false;
 for(size_t i=0;i<before.size();i++)if(before[i].type!=after[i].type||before[i].sender!=after[i].sender||before[i].children!=after[i].children)return false;
 return true;
}
// Only the receiver's mach ticks are meaningful inside its IOHID events.
// Missing APIs or a malformed attached tree fail; events without HID retain their CG-only path.
static bool normalizeNativeHIDTimestamp(CGEventRef event,uint64_t localSender=0){
 const auto &api=hidTimestampAPI();if(!api.ready())return false;
 auto hid=api.copy(event);
 if(!hid)return true;
 if(CFGetTypeID(hid)!=api.typeID()){CFRelease(hid);return false;}
 std::vector<HIDNodeShape> before,after;
 uint64_t original=api.timestamp(hid);
 bool valid=inspectHIDTree(api,hid,original,before,0);
 uint64_t local=mach_absolute_time();
 if(valid&&localSender)for(auto &node:before)node.sender=localSender;
 if(valid)setHIDTreeIdentity(api,hid,local,localSender);
 CFRelease(hid);
 if(!valid)return false;
 // Confirm the retained HID object really was the CGEvent's mutable backing.
 auto attached=api.copy(event);
 bool okay=attached&&inspectHIDTree(api,attached,local,after,0)&&sameHIDShape(before,after);
 if(attached)CFRelease(attached);
 return okay;
}
static bool contactOnlyCG29(CGEventRef event){
 NSInteger subtype=-1;@try{subtype=[NSEvent eventWithCGEvent:event].subtype;}@catch(NSException*){return false;}
 if(subtype!=0&&subtype!=11)return false;
 const auto &api=hidTimestampAPI();if(!api.ready())return false;
 auto hid=api.copy(event);if(!hid)return false;
 bool only=CFGetTypeID(hid)==api.typeID()&&api.type(hid)==11;
 auto children=only?api.children(hid):nullptr;
 only=only&&children&&CFGetTypeID(children)==CFArrayGetTypeID()&&CFArrayGetCount(children)>0&&CFArrayGetCount(children)<=16;
 if(only)for(CFIndex i=0;i<CFArrayGetCount(children);i++){auto child=(CFTypeRef)CFArrayGetValueAtIndex(children,i);if(!child||CFGetTypeID(child)!=api.typeID()||api.type(child)!=11){only=false;break;}}
 CFRelease(hid);return only;
}
static bool hidChildBytes(const HIDTimestampAPI &api,CFTypeRef child,std::vector<uint8_t> &bytes){
 auto data=api.data(kCFAllocatorDefault,child);if(!data)return false;
 auto length=CFDataGetLength(data);bool okay=length>0&&length<=65536;
 if(okay)bytes.assign(CFDataGetBytePtr(data),CFDataGetBytePtr(data)+length);
 CFRelease(data);return okay;
}
// Keep a mixed event's scroll/gesture HID children, but let raw v2 own its fingers.
// The Air's captured type-29 scroll event contains both kinds under one digitizer root.
static CFDataRef serializeNativeCG29WithoutDuplicateFingers(CGEventRef event){
 const auto &api=hidTimestampAPI();if(!api.ready()||!api.remove||!api.data)return nullptr;
 auto hid=api.copy(event);if(!hid)return CGEventCreateData(kCFAllocatorDefault,event);
 if(CFGetTypeID(hid)!=api.typeID()){CFRelease(hid);return nullptr;}
 if(api.type(hid)!=11){CFRelease(hid);return CGEventCreateData(kCFAllocatorDefault,event);}
 auto children=api.children(hid);
 if(!children||CFGetTypeID(children)!=CFArrayGetTypeID()||CFArrayGetCount(children)<1||CFArrayGetCount(children)>32){CFRelease(hid);return nullptr;}
 std::vector<CFTypeRef> fingers;std::vector<std::vector<uint8_t>> semantic;
 bool valid=true;
 for(CFIndex i=0;i<CFArrayGetCount(children);i++){
  auto child=(CFTypeRef)CFArrayGetValueAtIndex(children,i);
  if(!child||CFGetTypeID(child)!=api.typeID()){valid=false;break;}
  if(api.type(child)==11){CFRetain(child);fingers.push_back(child);}
  else{std::vector<uint8_t> bytes;if(!hidChildBytes(api,child,bytes)){valid=false;break;}semantic.push_back(std::move(bytes));}
 }
 if(!valid||semantic.empty()){
  for(auto finger:fingers)CFRelease(finger);
  CFRelease(hid);return nullptr;
 }
 if(fingers.empty()){CFRelease(hid);return CGEventCreateData(kCFAllocatorDefault,event);}
 for(auto finger:fingers){api.remove(hid,finger);CFRelease(finger);}
 CFRelease(hid);
 auto attached=api.copy(event);valid=attached&&CFGetTypeID(attached)==api.typeID()&&api.type(attached)==11;
 auto remaining=valid?api.children(attached):nullptr;
 valid=valid&&remaining&&CFGetTypeID(remaining)==CFArrayGetTypeID()&&CFArrayGetCount(remaining)==(CFIndex)semantic.size();
 // Intel can change sibling HID bytes in memory; compare them after serialization below.
 if(valid)for(CFIndex i=0;i<CFArrayGetCount(remaining);i++){
  auto child=(CFTypeRef)CFArrayGetValueAtIndex(remaining,i);
  if(!child||CFGetTypeID(child)!=api.typeID()||api.type(child)==11){valid=false;break;}
 }
 if(attached)CFRelease(attached);
 if(!valid)return nullptr;
 auto wire=CGEventCreateData(kCFAllocatorDefault,event);if(!wire)return nullptr;
 auto roundtrip=CGEventCreateFromData(kCFAllocatorDefault,wire);
 auto roundHID=roundtrip&&CGEventGetType(roundtrip)==29?api.copy(roundtrip):nullptr;
 valid=roundHID&&CFGetTypeID(roundHID)==api.typeID()&&api.type(roundHID)==11;
 remaining=valid?api.children(roundHID):nullptr;
 valid=valid&&remaining&&CFGetTypeID(remaining)==CFArrayGetTypeID()&&CFArrayGetCount(remaining)==(CFIndex)semantic.size();
 if(valid)for(CFIndex i=0;i<CFArrayGetCount(remaining);i++){
  auto child=(CFTypeRef)CFArrayGetValueAtIndex(remaining,i);std::vector<uint8_t> bytes;
  if(!child||CFGetTypeID(child)!=api.typeID()||api.type(child)==11||!hidChildBytes(api,child,bytes)||bytes!=semantic[(size_t)i]){valid=false;break;}
 }
 if(roundHID)CFRelease(roundHID);if(roundtrip)CFRelease(roundtrip);
 if(!valid){CFRelease(wire);return nullptr;}
 return wire;
}
static CGEventFlags modifierMask(CGKeyCode key){
 return key==54||key==55?kCGEventFlagMaskCommand:key==56||key==60?kCGEventFlagMaskShift:key==58||key==61?kCGEventFlagMaskAlternate:key==59||key==62?kCGEventFlagMaskControl:key==63?kCGEventFlagMaskSecondaryFn:key==57?kCGEventFlagMaskAlphaShift:0;
}
static CGEventFlags deviceModifierMask(CGKeyCode key){
 return key==55?0x8:key==54?0x10:key==56?0x2:key==60?0x4:key==58?0x20:key==61?0x40:key==59?0x1:key==62?0x2000:0;
}
static void noteModifier(CGKeyCode key,CGEventFlags flags){
 auto device=deviceModifierMask(key);
 bool down=device&&(flags|hostFlags)&device?flags&device:flags&modifierMask(key);
 if(down)hostKeys.insert(key);else hostKeys.erase(key);
}
struct ModernTouchAPI {
 CFTypeRef (*create)(CFAllocatorRef,uint32_t,uint64_t,uint32_t)=nullptr;
 CFTypeRef (*parent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t)=nullptr;
 CFTypeRef (*finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t)=nullptr;
 void (*append)(CFTypeRef,CFTypeRef,uint32_t)=nullptr;
 void (*sender)(CFTypeRef,uint64_t)=nullptr;
 void (*floating)(CFTypeRef,uint32_t,double)=nullptr;
 CFDataRef (*data)(CFAllocatorRef,CFTypeRef)=nullptr;
 bool ready() const {return create&&parent&&finger&&append&&sender&&floating&&data;}
};
static const ModernTouchAPI &modernTouchAPI(){
 static const ModernTouchAPI api=[](){ModernTouchAPI value;
  void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY|RTLD_LOCAL);
  if(io){
   value.create=(decltype(value.create))dlsym(io,"IOHIDEventCreate");
   value.parent=(decltype(value.parent))dlsym(io,"IOHIDEventCreateDigitizerEvent");
   value.finger=(decltype(value.finger))dlsym(io,"IOHIDEventCreateDigitizerFingerEvent");
   value.append=(decltype(value.append))dlsym(io,"IOHIDEventAppendEvent");
   value.sender=(decltype(value.sender))dlsym(io,"IOHIDEventSetSenderID");
   value.floating=(decltype(value.floating))dlsym(io,"IOHIDEventSetFloatValue");
   value.data=(decltype(value.data))dlsym(io,"IOHIDEventCreateData");
  }return value;
 }();return api;
}
static uint64_t localTouchDeviceID(){
 if(hostLocalTouchDevice)return hostLocalTouchDevice;
 static void *library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LAZY|RTLD_LOCAL);
 if(!library)return 0;
 auto create=(CFArrayRef(*)())dlsym(library,"MTDeviceCreateList");
 auto getID=(int(*)(CFTypeRef,uint64_t *))dlsym(library,"MTDeviceGetDeviceID");
 if(!create||!getID)return 0;
 auto devices=create();if(!devices)return 0;
 uint64_t id=0;
 for(CFIndex i=0;i<CFArrayGetCount(devices)&&!id;i++)getID(CFArrayGetValueAtIndex(devices,i),&id);
 CFRelease(devices);hostLocalTouchDevice=id;return id;
}
static bool contactTicks(const RawContact &contact,double callbackTimestamp,uint64_t frameTicks,uint64_t &ticks){
 if(!std::isfinite(callbackTimestamp)||callbackTimestamp==0||contact.touchTimestamp==0){ticks=frameTicks;return true;}
 double delta=contact.touchTimestamp-callbackTimestamp;if(!std::isfinite(delta)||std::abs(delta)>1)return false;
 mach_timebase_info_data_t timebase={};mach_timebase_info(&timebase);
 if(!timebase.numer||!timebase.denom)return false;
 uint64_t deltaNs=(uint64_t)llround(std::abs(delta)*NSEC_PER_SEC);
 uint64_t deltaTicks=(uint64_t)(((__uint128_t)deltaNs*timebase.denom)/timebase.numer);
 if(delta<0){if(deltaTicks>=frameTicks)return false;ticks=frameTicks-deltaTicks;}
 else{if(deltaTicks>UINT64_MAX-frameTicks)return false;ticks=frameTicks+deltaTicks;}
 return true;
}
static CGEventRef modernContactEvent(const std::map<uint32_t,RawContact> &items,uint32_t phase,uint64_t targetNs=0,uint64_t targetTicks=0,double callbackTimestamp=0){
 const auto &api=modernTouchAPI();uint64_t localID=localTouchDeviceID();
 if(!api.ready()||!localID||items.size()>16||!(phase==1||phase==2||phase==4))return nullptr;
 uint64_t ticks=targetTicks?targetTicks:mach_absolute_time();uint32_t parentMask=0;double parentX=0,parentY=0,parentPressure=0;unsigned parentCount=0;
 for(const auto &entry:items){const auto &t=entry.second;auto state=t.state;parentMask|=state==3?7:state==4?4:state==5||state==7?3:0;parentX+=std::clamp(t.x,0.f,1.f);parentY+=std::clamp(t.y,0.f,1.f);parentPressure+=t.pressure;parentCount++;}
 if(parentCount){parentX/=parentCount;parentY/=parentCount;}
 auto parent=api.parent(kCFAllocatorDefault,ticks,3,0,0,parentMask,0,parentX,parentY,0,parentPressure,0,phase!=4,phase!=4,0);
 if(!parent)return nullptr;api.sender(parent,localID);
 NSMutableArray *touches=[NSMutableArray arrayWithCapacity:items.size()];
 std::vector<uint64_t> fingerTimes;fingerTimes.reserve(items.size());
 for(const auto &entry:items){const auto &t=entry.second;bool touching=t.state==3||t.state==4;
  if(!touching&&t.state!=5&&t.state!=7){CFRelease(parent);return nullptr;}
  uint32_t mask=t.state==3?7:touching?4:3;
  double x=std::clamp(t.x,0.f,1.f),y=std::clamp(t.y,0.f,1.f),pressure=t.pressure;uint64_t fingerTicks=0;
  if(t.pathIndex<0||!contactTicks(t,callbackTimestamp,ticks,fingerTicks)){CFRelease(parent);return nullptr;}
  fingerTimes.push_back(fingerTicks);
  uint32_t index=t.id;
  auto finger=api.finger(kCFAllocatorDefault,fingerTicks,index,t.id,mask,x,y,0,pressure,0,touching,touching,0);
  if(!finger){CFRelease(parent);return nullptr;}
  api.floating(finger,kIOHIDEventFieldDigitizerDensity,t.density);api.floating(finger,kIOHIDEventFieldDigitizerMajorRadius,t.major);api.floating(finger,kIOHIDEventFieldDigitizerMinorRadius,t.minor);
  if(t.vx!=0||t.vy!=0){auto velocity=api.create(kCFAllocatorDefault,kIOHIDEventTypeVelocity,fingerTicks,0);
   if(!velocity){CFRelease(finger);CFRelease(parent);return nullptr;}
   api.floating(velocity,kIOHIDEventFieldVelocityX,t.vx);api.floating(velocity,kIOHIDEventFieldVelocityY,t.vy);api.floating(velocity,kIOHIDEventFieldVelocityZ,0);api.append(finger,velocity,0);CFRelease(velocity);}
  api.append(parent,finger,0);CFRelease(finger);
  [touches addObject:@{@"type":@11,@"timestamp":@(fingerTicks),@"transducerType":@2,@"identity":@(t.id),@"transducerIndex":@(index),@"options":@(0x10000|(touching?0x20000:0)),@"eventMask":@(mask),@"position.x":@(x),@"position.y":@(y),@"tipPressure":@(pressure),@"density":@(t.density),@"majorRadius":@(t.major),@"minorRadius":@(t.minor)}];
 }
 auto hid=api.data(kCFAllocatorDefault,parent);CFRelease(parent);
 if(!hid||CFDataGetLength(hid)<=0||CFDataGetLength(hid)>UINT16_MAX){if(hid)CFRelease(hid);return nullptr;}
 CFIndex field=-1;
 auto templateData=tl_CGEventCreateGestureData((__bridge CFDictionaryRef)@{@"deviceID":@(localID),@"gestureSubtype":@11,@"gesturePhase":@(phase)},(__bridge CFArrayRef)touches,&field);
 if(!templateData){CFRelease(hid);return nullptr;}
 const auto *bytes=CFDataGetBytePtr(templateData);CFIndex length=CFDataGetLength(templateData);
 if(field<0||field+4>length||bytes[field+2]!=0x10||bytes[field+3]!=0x6d){CFRelease(templateData);CFRelease(hid);return nullptr;}
 uint16_t oldSize=((uint16_t)bytes[field]<<8)|bytes[field+1];
 if(oldSize<16||field+4+oldSize>length){CFRelease(templateData);CFRelease(hid);return nullptr;}
 auto wire=CFDataCreateMutableCopy(kCFAllocatorDefault,0,templateData);CFRelease(templateData);
 uint16_t hidSize=CFSwapInt16HostToBig((uint16_t)CFDataGetLength(hid));
 CFDataReplaceBytes(wire,CFRangeMake(field,2),(const UInt8 *)&hidSize,2);
 CFDataReplaceBytes(wire,CFRangeMake(field+4,oldSize),CFDataGetBytePtr(hid),CFDataGetLength(hid));CFRelease(hid);
 CGEventRef event=CFDataGetLength(wire)<=65536?CGEventCreateFromData(kCFAllocatorDefault,wire):nullptr;CFRelease(wire);
 if(event){
  CGEventSetTimestamp(event,targetNs?targetNs:clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
  // CGEventCreateFromData makes every HID child inherit the root time. Restore
  // the individual contact times on its mutable HID attachment before posting.
  const auto &hidApi=hidTimestampAPI();auto attached=hidApi.ready()?hidApi.copy(event):nullptr;
  auto children=attached?hidApi.children(attached):nullptr;
  bool valid=attached&&children&&CFGetTypeID(children)==CFArrayGetTypeID()&&CFArrayGetCount(children)==(CFIndex)fingerTimes.size();
  if(valid)for(CFIndex i=0;i<CFArrayGetCount(children);i++){
   auto child=(CFTypeRef)CFArrayGetValueAtIndex(children,i);
   if(!child||CFGetTypeID(child)!=hidApi.typeID()||hidApi.type(child)!=11){valid=false;break;}
   setHIDTreeTimestamp(hidApi,child,fingerTimes[(size_t)i]);
  }
  if(attached)CFRelease(attached);
  attached=valid?hidApi.copy(event):nullptr;children=attached?hidApi.children(attached):nullptr;
  valid=attached&&children&&CFGetTypeID(children)==CFArrayGetTypeID()&&CFArrayGetCount(children)==(CFIndex)fingerTimes.size();
  if(valid)for(CFIndex i=0;i<CFArrayGetCount(children);i++){
   auto child=(CFTypeRef)CFArrayGetValueAtIndex(children,i);
   if(!child||hidApi.timestamp(child)!=fingerTimes[(size_t)i]){valid=false;break;}
  }
  if(attached)CFRelease(attached);
  if(!valid){CFRelease(event);event=nullptr;}
 }
 return event;
}
static bool postContacts(const std::map<uint32_t,RawContact> &items,uint32_t phase,uint64_t targetNs=0,uint64_t targetTicks=0,double callbackTimestamp=0) {
 auto event=modernContactEvent(items,phase,targetNs,targetTicks,callbackTimestamp);
 if(!event)return false;
 auto cursor=CGEventCreate(nullptr);if(cursor){CGEventSetLocation(event,CGEventGetLocation(cursor));CFRelease(cursor);}
 CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);
 CGEventPost(kCGHIDEventTap,event);CFRelease(event);injected++;rawFramesPosted++;return true;
}
static bool decodeContacts(const uint8_t *bytes,size_t len,std::map<uint32_t,RawContact> &items,uint64_t &device) {
 if(len<16||memcmp(bytes,rawMagic,5)||bytes[6]||bytes[7]||bytes[5]>16||len!=16+bytes[5]*20)return false;
 memcpy(&device,bytes+8,8);device=CFSwapInt64LittleToHost(device);
 for(size_t i=0;i<bytes[5];i++){
  uint32_t fields[5];for(int j=0;j<5;j++){memcpy(&fields[j],bytes+16+i*20+j*4,4);fields[j]=CFSwapInt32LittleToHost(fields[j]);}
  RawContact t; t.id=fields[0];t.state=fields[1];memcpy(&t.x,&fields[2],4);memcpy(&t.y,&fields[3],4);memcpy(&t.pressure,&fields[4],4);
  if(t.state>7||!std::isfinite(t.x)||!std::isfinite(t.y)||!std::isfinite(t.pressure)||t.x<-.25||t.x>1.25||t.y<-.25||t.y>1.25||t.pressure<0||t.pressure>10000||items.count(t.id))return false;
  items[t.id]=t;
 }
 return true;
}
static RawContact endingContact(const RawContact &previous,const RawContact *incoming){
 auto ended=incoming&&(incoming->state==5||incoming->state==7)?*incoming:previous;
 if(ended.state!=7)ended.state=5;
 return ended;
}
static bool receiveContactItems(const std::map<uint32_t,RawContact> &incoming,uint64_t device,uint64_t targetNs=0,uint64_t targetTicks=0,double callbackTimestamp=0) {
 if(hostTouchDevice&&hostTouchDevice!=device&&!hostContacts.empty()){
  auto ending=hostContacts;for(auto &entry:ending)entry.second.state=5;
  if(!postContacts(ending,4,targetNs,targetTicks,callbackTimestamp))return false;
  hostContacts.clear();
  hostLocalTouchDevice=0;
 }
 hostTouchDevice=device;
 std::map<uint32_t,RawContact> active,items;
 for(const auto &entry:incoming)if(entry.second.state==3||entry.second.state==4){
  active[entry.first]=entry.second;
  auto touch=entry.second;touch.state=hostContacts.count(entry.first)?4:3;
  items[entry.first]=touch;
 }
 for(const auto &old:hostContacts)if(!active.count(old.first)){
  // Keep the final contact position and timestamp when the Air supplies an
  // explicit up/cancel record. An omitted contact still needs a local release.
  auto found=incoming.find(old.first);
  items[old.first]=endingContact(old.second,found==incoming.end()?nullptr:&found->second);
 }
 unsigned was=hostContacts.size(), now=active.size();
 if(!was&&!now)return true;
 uint32_t phase=!was&&now?1:was&&!now?4:2;
 if(!postContacts(items,phase,targetNs,targetTicks,callbackTimestamp))return false;
 hostContacts=std::move(active);if(!now)hostLocalTouchDevice=0;return true;
}
static bool receiveContacts(const uint8_t *bytes,size_t len,uint64_t targetNs=0,uint64_t targetTicks=0) {
 std::map<uint32_t,RawContact> incoming;uint64_t device=0;
 return decodeContacts(bytes,len,incoming,device)&&receiveContactItems(incoming,device,targetNs,targetTicks);
}
static void releaseHostContacts(){
 if(!hostContacts.empty()){
  auto ending=hostContacts;for(auto &entry:ending)entry.second.state=5;
  postContacts(ending,4);hostContacts.clear();
 }
 hostLocalTouchDevice=0;
 hostTouchDevice=0;hostSourceAnchor=0;hostLocalAnchor=0;hostLastSource=0;hostLastSequence=0;hostLastTargetNs=0;
}
struct RawFrameV2 {uint64_t device=0,sequence=0,sourceNs=0,frameIndex=0;double callbackTimestamp=0;std::map<uint32_t,RawContact> items;};
static bool decodeRawV2(const uint8_t *bytes,size_t len,RawFrameV2 &frame){
 if(!bytes||len<rawV2Header||memcmp(bytes,"RDAF",4)||bytes[4]!=2||bytes[5]>16||bytes[6]||bytes[7]||len!=rawV2Header+(size_t)bytes[5]*rawV2Contact)return false;
 frame.device=rawGet64(bytes+8);frame.sequence=rawGet64(bytes+16);frame.sourceNs=rawGet64(bytes+24);frame.callbackTimestamp=rawGetDouble(bytes+32);frame.frameIndex=rawGet64(bytes+40);
 if(!frame.sequence||!frame.sourceNs||!std::isfinite(frame.callbackTimestamp))return false;
 for(unsigned i=0;i<bytes[5];i++){
  const uint8_t *at=bytes+rawV2Header+i*rawV2Contact;RawContact t;
  if(rawGet32(at+20)||rawGet32(at+84))return false;
  t.id=rawGet32(at);t.state=rawGet32(at+4);t.pathIndex=(int32_t)rawGet32(at+8);t.handID=(int32_t)rawGet32(at+12);t.touchFrame=(int32_t)rawGet32(at+16);t.touchTimestamp=rawGetDouble(at+24);
  float *fields[]={&t.x,&t.y,&t.vx,&t.vy,&t.pressure,&t.angle,&t.major,&t.minor,&t.absoluteX,&t.absoluteY,&t.absoluteVX,&t.absoluteVY,&t.density};
  for(unsigned j=0;j<13;j++)*fields[j]=rawGetFloat(at+32+j*4);
  if(t.id>INT32_MAX||t.state>7||!std::isfinite(t.touchTimestamp)||!std::isfinite(t.x)||!std::isfinite(t.y)||t.x<-.25||t.x>1.25||t.y<-.25||t.y>1.25||t.pressure<0||t.pressure>10000||frame.items.count(t.id))return false;
  for(auto field:fields)if(!std::isfinite(*field)||std::abs(*field)>1000000)return false;
  frame.items[t.id]=t;
 }
 return true;
}
static bool receiveContactsV2(const RawFrameV2 &frame){
 uint64_t nowNs=uptimeNs();
 if(hostLastSequence&&(frame.sequence<=hostLastSequence||frame.sourceNs<=hostLastSource)){rawStaleRejected++;traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"sequence_or_source_order");return false;}
 if(hostTouchDevice&&hostTouchDevice!=frame.device)releaseHostContacts();
 if(hostLastSequence&&frame.sequence!=hostLastSequence+1){traceRaw("host_reset",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"sequence_gap");releaseHostContacts();}
 if(hostLastSource&&frame.sourceNs-hostLastSource>1000000000ULL&&!hostContacts.empty()){rawStaleRejected++;traceRaw("host_reset",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"source_gap");releaseHostContacts();}
 if(!hostSourceAnchor){hostSourceAnchor=frame.sourceNs;hostLocalAnchor=nowNs;}
 uint64_t sourceElapsed=frame.sourceNs-hostSourceAnchor;
 if(sourceElapsed>UINT64_MAX-hostLocalAnchor){rawStaleRejected++;traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"anchor_overflow");releaseHostContacts();return true;}
 uint64_t targetNs=hostLocalAnchor+sourceElapsed;
 // The first packet anchors the independent Air and Pro uptime clocks. Later lag is bounded.
 if(nowNs>targetNs&&nowNs-targetNs>250000000ULL){rawStaleRejected++;traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"late_250ms");releaseHostContacts();return true;}
 if(targetNs>nowNs&&targetNs-nowNs>250000000ULL){rawStaleRejected++;traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"future_250ms");releaseHostContacts();return true;}
 if(targetNs>nowNs)targetNs=nowNs;
 if(targetNs<=hostLastTargetNs)targetNs=hostLastTargetNs+1;
 mach_timebase_info_data_t timebase={};mach_timebase_info(&timebase);
 if(!timebase.numer||!timebase.denom){traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"timebase");return false;}
 uint64_t nowTicks=mach_absolute_time(),lagNs=nowNs>targetNs?nowNs-targetNs:0;
 uint64_t lagTicks=(uint64_t)(((__uint128_t)lagNs*timebase.denom)/timebase.numer);
 uint64_t ticks=nowTicks>lagTicks?nowTicks-lagTicks:1;
 uint64_t postedBefore=rawFramesPosted.load();
 if(!receiveContactItems(frame.items,frame.device,targetNs,ticks,frame.callbackTimestamp)){traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"post_contacts");return false;}
 hostLastSource=frame.sourceNs;hostLastSequence=frame.sequence;hostLastTargetNs=targetNs;
 traceRaw("host_accepted",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,rawFramesPosted.load()>postedBefore?"posted":"no_active_contacts");
 return true;
}
static void expireHostRaw(){
 if(hostRawExpired)return;
 hostRawDeadline=0;hostRawExpired=true;releaseHostContacts();
 fprintf(stderr,"air_raw_probe_host_expired=1\n");
}
static void resetEdgeDrag(){edgeDrag={};}
static bool edgePointer(CGPoint &point,int x,int y,int kind){
 // Enigo posts moves asynchronously. Their authenticated target point is the
 // observation; down and release must also agree with the actual Pro cursor.
 if(kind==2){point=CGPointMake(x,y);return true;}
 for(int attempt=0;attempt<5;attempt++){
  auto event=CGEventCreate(nullptr);if(!event)return false;
  point=CGEventGetLocation(event);CFRelease(event);
  if(std::isfinite(point.x)&&std::isfinite(point.y)
     &&std::abs(point.x-x)<=16&&std::abs(point.y-y)<=16)return true;
  if(attempt<4)usleep(5000);
 }
 return false;
}
static bool edgeWindowInfo(uint32_t wid,pid_t pid,CGPoint point,CGRect &frame,bool topmost){
 NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(
     topmost?kCGWindowListOptionOnScreenOnly:kCGWindowListOptionAll,kCGNullWindowID));
 if(!list)return false;
 for(NSDictionary *info in list){
  if(![info isKindOfClass:NSDictionary.class]||[info[(id)kCGWindowLayer] intValue]!=0)continue;
  CGRect current=CGRectNull;
  if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&current))continue;
  if(topmost&&!CGRectContainsPoint(current,point))continue;
  uint32_t candidate=[info[(id)kCGWindowNumber] unsignedIntValue];
  if(topmost&&candidate!=wid)return false;
  if(candidate!=wid)continue;
  if([info[(id)kCGWindowOwnerPID] intValue]!=pid)return false;
  frame=current;return CGRectGetWidth(frame)>100&&CGRectGetHeight(frame)>100;
 }
 return false;
}
static bool edgeHitWindow(CGPoint point,uint32_t &wid,pid_t &pid){
 AXUIElementRef hit=nullptr,window=nullptr;
 auto system=AXUIElementCreateSystemWide();if(!system)return false;
 AXError status=AXUIElementCopyElementAtPosition(system,point.x,point.y,&hit);CFRelease(system);
 if(status!=kAXErrorSuccess||!hit)return false;
 CFTypeRef role=nullptr;
 if(AXUIElementCopyAttributeValue(hit,kAXRoleAttribute,&role)==kAXErrorSuccess&&role
    &&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,kAXWindowRole))window=(AXUIElementRef)CFRetain(hit);
 if(role)CFRelease(role);
 if(!window){CFTypeRef candidate=nullptr;
  if(AXUIElementCopyAttributeValue(hit,kAXWindowAttribute,&candidate)==kAXErrorSuccess&&candidate
     &&CFGetTypeID(candidate)==AXUIElementGetTypeID())window=(AXUIElementRef)candidate;
  else if(candidate)CFRelease(candidate);
 }
 CFRelease(hit);if(!window)return false;
 static auto axWindow=[](){
  void *app=dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",RTLD_LAZY|RTLD_LOCAL);
  return app?(AXError (*)(AXUIElementRef,CGWindowID *))dlsym(app,"_AXUIElementGetWindow"):nullptr;
 }();
 CGWindowID actual=0;bool okay=axWindow&&axWindow(window,&actual)==kAXErrorSuccess&&actual
     &&AXUIElementGetPid(window,&pid)==kAXErrorSuccess&&pid>0;
 CFRelease(window);wid=okay?actual:0;return okay;
}
static int edgeAt(CGRect display,CGPoint point){
 return edgeDragDirection(point.x,point.y,CGRectGetMinX(display),CGRectGetMinY(display),
     CGRectGetMaxX(display),CGRectGetMaxY(display));
}
// Called after Enigo has applied a remote mouse action. Only an Air Remote Mode
// owner can arm the gesture; AX and CG must name the same frontmost window.
extern "C" void air_host_edge_drag_event(int id,int kind,int x,int y){
 if(kind==0)return;
 std::lock_guard<std::mutex> lock(hostInputMutex);
 if(!id||hostOwner!=id||hostShutdown||kind==4){resetEdgeDrag();return;}
 @autoreleasepool {
  CGPoint point={};if(!edgePointer(point,x,y,kind)){resetEdgeDrag();return;}
  if(kind==1){
   resetEdgeDrag();int slot=air_spaces_current_slot(),count=air_spaces_slot_count();
   CGDirectDisplayID builtin=air_builtin_display();
   if(slot<1||slot>count||count<2||!builtin)return;
   CGRect display=CGDisplayBounds(builtin);
   if(!CGRectContainsPoint(display,point))return;
   uint32_t wid=0;pid_t pid=0;CGRect frame=CGRectNull;
   if(!edgeHitWindow(point,wid,pid)||!edgeWindowInfo(wid,pid,point,frame,true))return;
   // A drag beginning in content, a resize handle, or window controls never arms.
   if(point.y<CGRectGetMinY(frame)+4||point.y>CGRectGetMinY(frame)+72
      ||point.x<CGRectGetMinX(frame)+80)return;
   edgeDrag.owner=id;edgeDrag.slot=slot;edgeDrag.wid=wid;edgeDrag.pid=pid;edgeDrag.display=display;
   edgeDrag.policy.begin({point.x,point.y,frame.origin.x,frame.origin.y,
       frame.size.width,frame.size.height,uptimeNs(),0});
   return;
  }
  if(edgeDrag.owner!=id||!edgeDrag.wid||!edgeDrag.policy.active)return;
  if(kind!=2&&kind!=3){resetEdgeDrag();return;}
  int currentSlot=air_spaces_current_slot();
  int edge=edgeAt(edgeDrag.display,point);
  if(!edgeDragSlotTransition(edgeDrag.slot,currentSlot,edge?edge:edgeDrag.policy.edge,
      edgeDrag.observedAdjacent)){resetEdgeDrag();return;}
  CGRect frame=CGRectNull;
  if(!edgeWindowInfo(edgeDrag.wid,edgeDrag.pid,point,frame,false)){resetEdgeDrag();return;}
  EdgeDragSample sample={point.x,point.y,frame.origin.x,frame.origin.y,
      frame.size.width,frame.size.height,uptimeNs(),edge};
  if(kind==2){if(!edgeDrag.policy.observe(sample,edgeDrag.observedAdjacent!=0))resetEdgeDrag();return;}
  int direction=edgeDrag.observedAdjacent
      ?(edgeDrag.policy.releaseAfterNativeSwitch(sample)?edgeDrag.observedAdjacent:0)
      :edgeDrag.policy.release(sample);
  int slot=edgeDrag.slot;uint32_t wid=edgeDrag.wid;uint64_t epoch=edgeTransferEpoch;
  resetEdgeDrag();
  if(direction&&hostOwner==id)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
   std::lock_guard<std::mutex> transferLock(edgeTransferMutex);
   {std::lock_guard<std::mutex> ownerLock(hostInputMutex);
    if(hostShutdown||hostOwner!=id||edgeTransferEpoch!=epoch)return;
   }
   air_spaces_transfer_window_edge(wid,slot,direction);
  });
 }
}
static void releaseHost() {
 edgeTransferEpoch++;
 resetEdgeDrag();
 auto swipeCancel=air_dockswipe27_cancel(mach_absolute_time());
 if(swipeCancel){
  auto cursor=CGEventCreate(nullptr);if(cursor){CGEventSetLocation(swipeCancel,CGEventGetLocation(cursor));CFRelease(cursor);}
  CGEventSetTimestamp(swipeCancel,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
  CGEventSetIntegerValueField(swipeCancel,kCGEventSourceUserData,inputTag);
  CGEventPost(kCGSessionEventTap,swipeCancel);CFRelease(swipeCancel);
 }
 releaseHostContacts();
 for(auto key:hostMedia){NSEvent *up=[NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:11 timestamp:0 windowNumber:0 context:nil subtype:8 data1:(key<<16)|(11<<8) data2:-1];auto event=up.CGEvent;if(event){CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);CGEventPost(kCGHIDEventTap,event);}}
 hostMedia.clear();
 auto remaining=hostKeys;
 for(auto key:hostKeys){
  CGEventFlags mask=modifierMask(key);remaining.erase(key);
  auto event=CGEventCreateKeyboardEvent(nullptr,key,false);
  if(event){if(mask){hostFlags&=~deviceModifierMask(key);bool stillDown=false;for(auto other:remaining)if(modifierMask(other)==mask){stillDown=true;break;}if(!stillDown)hostFlags&=~mask;CGEventSetType(event,kCGEventFlagsChanged);}CGEventSetFlags(event,hostFlags);CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);CGEventPost(kCGHIDEventTap,event);CFRelease(event);}
 }
 const struct {CGEventFlags flag;CGKeyCode key;} remainingFlags[]={
  {kCGEventFlagMaskCommand,55},{kCGEventFlagMaskShift,56},{kCGEventFlagMaskAlternate,58},
  {kCGEventFlagMaskControl,59},{kCGEventFlagMaskSecondaryFn,63},{kCGEventFlagMaskAlphaShift,57}
 };
 for(const auto &entry:remainingFlags)if(hostFlags&entry.flag){
  auto event=CGEventCreateKeyboardEvent(nullptr,entry.key,false);
  if(event){CGEventSetType(event,kCGEventFlagsChanged);CGEventSetFlags(event,0);CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);CGEventPost(kCGHIDEventTap,event);CFRelease(event);}
 }
 const CGKeyCode deviceKeys[]={55,54,56,60,58,61,59,62};
 for(auto key:deviceKeys)if(hostFlags&deviceModifierMask(key)){
  auto event=CGEventCreateKeyboardEvent(nullptr,key,false);
  if(event){CGEventSetType(event,kCGEventFlagsChanged);CGEventSetFlags(event,0);CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);CGEventPost(kCGHIDEventTap,event);CFRelease(event);}
 }
 hostKeys.clear();hostFlags=0;
}
static void releaseClient() {
 air_keyboard_probe_ready(0);
 air_cursor_probe_ready(0);
 cancelSwipe();
 grabGeneration++;
 bool wasEnabled=enabled.exchange(false);
 stopMT();
 uint64_t generation=inputGeneration.load();
 if(wasEnabled&&releaseRemote)dispatch_async(sendQueue,^{if(releaseRemote&&inputGeneration==generation)releaseRemote(generation);});
}
static void append32(NSMutableData *data,uint32_t value){value=CFSwapInt32HostToLittle(value);[data appendBytes:&value length:4];}
static void append64(NSMutableData *data,uint64_t value){value=CFSwapInt64HostToLittle(value);[data appendBytes:&value length:8];}
static void finishCapture(){
 if(!captureMode.exchange(false))return;
 stopMT();
 std::vector<uint8_t> gesture,raw;
 {std::lock_guard<std::mutex> lock(gestureSampleMutex);gesture=gestureSample;raw=rawSample;}
 NSString *path=capturePath;capturePath=nil;
 uint64_t g=captureGestures,r=captureFrames,c=captureContacts,n=captureNSETouches;
 bool owns=captureOwnsSetup;captureOwnsSetup=false;
 dispatch_async(sendQueue,^{
  NSMutableData *out=[NSMutableData data];const char magic[8]={'R','D','A','I','C','A','P','1'};[out appendBytes:magic length:8];
  append32(out,(uint32_t)gesture.size());append32(out,(uint32_t)raw.size());append64(out,g);append64(out,r);append64(out,c);append64(out,n);
  if(!gesture.empty())[out appendBytes:gesture.data() length:gesture.size()];
  if(!raw.empty())[out appendBytes:raw.data() length:raw.size()];
  int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
  if(fd<0)air_set_error("Cannot create private native input capture");
  else{const uint8_t *bytes=(const uint8_t *)out.bytes;size_t remaining=out.length;bool okay=true;
   while(remaining){ssize_t done=write(fd,bytes,remaining);if(done<=0){okay=false;break;}bytes+=done;remaining-=done;}
   if(close(fd)||!okay){unlink(path.fileSystemRepresentation);air_set_error("Cannot save native input capture");}
  }
  if(owns)dispatch_async(dispatch_get_main_queue(),^{air_input_shutdown();});
 });
}
static void stopAfterRemoteReleaseOrTimeout(){
 if(!sendQueue){dispatch_async(dispatch_get_main_queue(),^{air_app_stop();});return;}
 __block bool stopped=false;
 void (^stop)(void)=^{if(!stopped){stopped=true;air_app_stop();}};
 dispatch_async(sendQueue,^{dispatch_async(dispatch_get_main_queue(),stop);});
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),stop);
}
static CGEventRef tapEvent(CGEventTapProxy,CGEventType type,CGEventRef event,void*) {
 // The display being viewed belongs to the Air. Preserve both edges and
 // repeats of its brightness keys for macOS, even while remote input is grabbed.
 // F1/F2 keyboard events remain remote; only the display-brightness media
 // actions stay local (including Option-Shift fine adjustment).
 if(type==NX_SYSDEFINED&&event){
  @try {
   NSEvent *native=[NSEvent eventWithCGEvent:event];
   if(native.subtype==NX_SUBTYPE_AUX_CONTROL_BUTTONS){
    const unsigned key=(static_cast<unsigned>(native.data1)>>16)&0xffff;
    if(key==NX_KEYTYPE_BRIGHTNESS_UP||key==NX_KEYTYPE_BRIGHTNESS_DOWN)return event;
   }
  } @catch(NSException*) {}
 }
 if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){
  if(captureMode){finishCapture();if(inputTap)CGEventTapEnable(inputTap,true);return event;}
  bool activeSession=clientInput&&connected;
  bool wasForwarding=enabled.load();
  releaseClient();
  if(activeSession&&wasForwarding&&!localUI&&!(secureInputEnabled&&secureInputEnabled())
     &&type==kCGEventTapDisabledByTimeout&&inputTap&&sendQueue){
   // One recovery per 30 seconds. A second timeout indicates an unhealthy tap;
   // stop instead of repeatedly capturing and releasing remote keys.
   uint64_t now=uptimeNs(),previous=lastTapTimeoutRecoveryNs.load();
   if(!previous||now-previous>=30*NSEC_PER_SEC){
    lastTapTimeoutRecoveryNs=now;
    CGEventTapEnable(inputTap,true);
    if(CGEventTapIsEnabled(inputTap)){
     uint64_t generation=inputGeneration.load(),grab=grabGeneration.load();
     // releaseClient queued the Pro's key/contact release on this serial queue.
     // Resume forwarding only after that callback has completed.
     dispatch_async(sendQueue,^{dispatch_async(dispatch_get_main_queue(),^{
      if(inputGeneration!=generation||grabGeneration!=grab||!connected||!clientInput||!NSApp.isActive
         ||localUI||(secureInputEnabled&&secureInputEnabled())
         ||!inputTap||!CGEventTapIsEnabled(inputTap))return;
      if((rawAllowed||diagnosticCapture)&&!startMT()){failRawStart();return;}
      enabled=true;air_keyboard_probe_ready(1);air_cursor_probe_ready(1);
      fprintf(stderr,"air_input_tap_timeout_recovered=1\n");
     });});
     return event;
    }
   }
  }
  if(activeSession){
   const char *reason=type==kCGEventTapDisabledByTimeout
    ?"Native input tap timed out; Remote Mode stopped"
    :"Native input tap was disabled; Remote Mode stopped";
   fprintf(stderr,"air_input_intentional_stop reason=%s\n",reason);
   air_set_error(reason);air_status(reason,1);
   // releaseClient queued the Pro's held-key/contact release first. Keep the
   // session worker alive until that callback has run, then stop AppKit.
   if(sendQueue)dispatch_async(sendQueue,^{dispatch_async(dispatch_get_main_queue(),^{air_app_stop();});});
   else dispatch_async(dispatch_get_main_queue(),^{air_app_stop();});
  }else if(inputTap)CGEventTapEnable(inputTap,true);
  return event;
 }
 if(captureMode){
  if(type==kCGEventKeyDown&&CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53){auto flags=CGEventGetFlags(event);if((flags&(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand))==(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand)){finishCapture();return event;}}
  if(type==29&&!(secureInputEnabled&&secureInputEnabled())){auto data=CGEventCreateData(kCFAllocatorDefault,event);if(data){auto len=CFDataGetLength(data);if(len>0&&len<=65536){NSUInteger touchCount=0;@try{NSEvent *native=[NSEvent eventWithCGEvent:event];touchCount=native.allTouches.count;}@catch(NSException*){}std::lock_guard<std::mutex> lock(gestureSampleMutex);if(touchCount>gestureSampleTouches||(touchCount==gestureSampleTouches&&len>gestureSample.size())){gestureSample.assign(CFDataGetBytePtr(data),CFDataGetBytePtr(data)+len);gestureSampleTouches=touchCount;}captureGestures++;captureNSETouches+=touchCount;}CFRelease(data);}}
  return event;
 }
 if(!enabled||!connected||!NSApp.isActive)return event;
 if(secureInputEnabled&&secureInputEnabled()){releaseClient();return event;}
 auto flags=CGEventGetFlags(event);
 if(type==kCGEventKeyDown&&CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53
    &&(flags&(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand))==(kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand)){
  fprintf(stderr,"air_input_intentional_stop reason=control_option_command_escape\n");
  escapes++;releaseClient();stopAfterRemoteReleaseOrTimeout();
  return nullptr;
 }
 if(localUI&&!keyboardType(type))return event;
 if(!forwardType(type))return event;
 traceNativeScroll("air_captured",event);
 if(suppressNativeTrackpadEvent(type,event)){rawContactDuplicates++;return nullptr;}
 auto data=rawContactsAuthoritative()&&type==29?serializeNativeCG29WithoutDuplicateFingers(event):CGEventCreateData(kCFAllocatorDefault,event);
 if(!data){releaseClient();air_set_error("Cannot preserve native input event without duplicate fingers");return nullptr;}
 auto length=CFDataGetLength(data);
 if(length>65536){CFRelease(data);releaseClient();return nullptr;}
 bool queued=queueBytes(CFDataGetBytePtr(data),length);
 CFRelease(data);if(!queued){releaseClient();return nullptr;}forwarded++;
 if(type==29||type==30||type==31)gestures++;
 return nullptr;
}
@interface AirInputObserver:NSObject
@end
@implementation AirInputObserver
 - (void)active:(NSNotification*)n { if(clientInput&&connected){enabled=true;if((rawAllowed||diagnosticCapture)&&!startMT())failRawStart();else {air_keyboard_probe_ready(1);air_cursor_probe_ready(1);}} }
- (void)inactive:(NSNotification*)n { if(captureMode)finishCapture();else releaseClient(); }
@end
static AirInputObserver *inputObserver;
extern "C" int air_input_setup(AirNativeEvent callback,AirReleaseInput release) {
 sendNative=callback;releaseRemote=release;clientInput=true;
 sendQueue=dispatch_queue_create("io.rustdesk.air.native-input",DISPATCH_QUEUE_SERIAL);
 setupMT();
 if(!CGPreflightListenEventAccess())CGRequestListenEventAccess();
 if(!AXIsProcessTrusted()){
  NSDictionary *options=@{(__bridge NSString*)kAXTrustedCheckOptionPrompt:@YES};AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
 }
 CGEventMask mask=0;for(unsigned type=0;type<64;type++)if(forwardType((CGEventType)type))mask|=CGEventMaskBit(type);
 inputTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,mask,tapEvent,nullptr);
 if(!inputTap){abortInputSetup();air_set_error("Allow RustDesk Air Client in Accessibility and Input Monitoring, then reopen it to capture keyboard and trackpad input.");return -1;}
 inputSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,inputTap,0);
 if(!inputSource){abortInputSetup();air_set_error("Cannot create native input tap run loop source");return -1;}
 CFRunLoopAddSource(CFRunLoopGetMain(),inputSource,kCFRunLoopCommonModes);CGEventTapEnable(inputTap,true);
 inputObserver=[AirInputObserver new];
 auto center=NSNotificationCenter.defaultCenter;
 [center addObserver:inputObserver selector:@selector(active:) name:NSApplicationDidBecomeActiveNotification object:nil];
 [center addObserver:inputObserver selector:@selector(inactive:) name:NSApplicationDidResignActiveNotification object:nil];
 auto status=IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,kIOPMAssertionLevelOn,CFSTR("RustDesk Air remote session"),&awakeAssertion);
 if(status!=kIOReturnSuccess){abortInputSetup();air_set_error("Cannot keep the Air display awake during Remote Mode");return -1;}
 return 0;
}
extern "C" int air_input_capture_test(int seconds,const char *path){
 if(seconds<1||seconds>60||!path||!*path||strlen(path)>4096||captureMode||connected||!NSApp.isActive){air_set_error("Activate RustDesk Air and choose a 1–60 second native input capture");return -1;}
 NSString *destination=[NSString stringWithUTF8String:path];if(!destination||!destination.isAbsolutePath){air_set_error("Native input capture path must be absolute");return -1;}
 bool owns=!inputTap;if(owns&&air_input_setup(nullptr,nullptr))return -1;
 captureOwnsSetup=owns;capturePath=[destination copy];
 {std::lock_guard<std::mutex> lock(gestureSampleMutex);gestureSample.clear();gestureSampleTouches=0;rawSample.clear();}
 captureGestures=0;captureFrames=0;captureContacts=0;captureNSETouches=0;
 uint64_t generation=++captureGeneration;captureMode=true;if(!startMT()){captureMode=false;capturePath=nil;captureOwnsSetup=false;air_set_error("Cannot start native trackpad capture");if(owns)air_input_shutdown();return -1;}
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)seconds*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(captureMode&&captureGeneration==generation)finishCapture();});
 return 0;
}
extern "C" void air_input_connected(int value) {
 cancelSwipe();
 inputGeneration++;
 connected=value!=0;
 if(!value){rawAllowed=false;clientRawDeadline=0;localUI=false;}
 dispatch_async(dispatch_get_main_queue(), ^{if(connected&&NSApp.isActive){enabled=true;if((rawAllowed||diagnosticCapture)&&!startMT())failRawStart();else {air_keyboard_probe_ready(1);air_cursor_probe_ready(1);}}else releaseClient();});
}
extern "C" uint64_t air_input_generation(){return inputGeneration.load();}
extern "C" int air_raw_probe_configure(int seconds){
 if(seconds<0||seconds>60){air_set_error("Raw contact probe duration must be 1–60 seconds");return -1;}
 std::lock_guard<std::mutex> lock(hostInputMutex);
 if(clientInput||hostOwner||clientRawSpent||hostRawSpent){air_set_error("Raw contact probe must be configured before a session");return -1;}
 rawProbeSeconds=seconds;return 0;
}
extern "C" int air_raw_full_configure(int enabledValue){
 if(enabledValue!=0&&enabledValue!=1){air_set_error("Raw contact setting must be 0 or 1");return -1;}
 std::lock_guard<std::mutex> lock(hostInputMutex);
 if(clientInput||hostOwner||clientRawSpent||hostRawSpent){air_set_error("Raw contacts must be configured before a session");return -1;}
 rawFullEnabled=enabledValue!=0;return 0;
}
extern "C" int air_raw_wire_version(){return 2;}
extern "C" void air_input_space_swipe_callback(AirNativeSpaceSwipe callback){spaceSwipeCallback=callback;}
extern "C" int air_client_raw_supported(){
 if(clientRawActive())return 1;
 bool secure=secureInputEnabled&&secureInputEnabled();
 if(clientInput&&!secure&&!mtDeviceList){
  if([NSThread isMainThread])setupMT();
  else dispatch_sync(dispatch_get_main_queue(),^{if(!mtDeviceList)setupMT();});
 }
 bool permitted=(rawProbeSeconds>0&&!clientRawSpent)||(rawProbeSeconds==0&&rawFullEnabled);
 bool devices=mtDeviceList&&CFArrayGetCount(mtDeviceList)>0;
 bool symbols=mtStart&&mtStop&&mtRegister&&mtUnregister&&mtDeviceID;
 bool supported=permitted&&clientInput&&devices&&symbols&&!secure;
 if(!supported)fprintf(stderr,"air_raw_client_capability permitted=%d input=%d devices=%ld symbols=%d secure=%d\n",
  permitted,clientInput,mtDeviceList?(long)CFArrayGetCount(mtDeviceList):-1L,symbols,secure);
 return supported?1:0;
}
extern "C" void air_input_raw_enabled(int value){
 if(value&&air_client_raw_supported()){
  if(rawProbeSeconds>0){
   if(!clientRawSpent.exchange(true)){clientRawDeadline=uptimeNs()+(uint64_t)rawProbeSeconds.load()*NSEC_PER_SEC;fprintf(stderr,"air_raw_probe_client_started=1 duration_seconds=%d\n",rawProbeSeconds.load());}
   rawAllowed=true;uint64_t deadline=clientRawDeadline.load(),now=uptimeNs();
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(deadline>now?deadline-now:0)),dispatch_get_main_queue(),^{if(rawAllowed&&clientRawDeadline==deadline&&!clientRawActive())expireClientRaw();});
  }else{rawAllowed=true;clientRawDeadline=0;fprintf(stderr,"air_raw_full_client_started=1 version=2\n");}
 }else{
  if(value&&rawProbeSeconds>0)fprintf(stderr,"air_raw_probe_client_unavailable=1\n");
  if(!value&&rawProbeSeconds>0&&connected&&!clientRawSpent&&!clientRawRejected.exchange(true))fprintf(stderr,"air_raw_probe_client_rejected=1\n");
  rawAllowed=false;clientRawDeadline=0;cancelSwipe();
 }
 dispatch_async(dispatch_get_main_queue(),^{if((rawAllowed||diagnosticCapture)&&connected&&enabled){if(!startMT())failRawStart();}else if(!captureMode)stopMT();});
}
extern "C" void air_input_local_ui(int value){
 bool active=value!=0;
 if(active)cancelSwipe();
 bool previous=localUI.exchange(active);
 if(active&&!previous)grabGeneration++;
 uint64_t generation=inputGeneration.load();
 if(active&&!previous&&enabled&&releaseRemote&&sendQueue)dispatch_async(sendQueue,^{if(releaseRemote&&inputGeneration==generation)releaseRemote(generation);});
}
extern "C" int air_host_raw_supported(){
 std::lock_guard<std::mutex> lock(hostInputMutex);
 return hostOwner&&hostRawReady&&(hostRawFull||(hostRawDeadline&&uptimeNs()<hostRawDeadline))?1:0;
}
extern "C" void air_input_shutdown() {
 air_keyboard_probe_shutdown();
 air_cursor_probe_shutdown();
 releaseClient();connected=false;localUI=false;clientInput=false;
 stopMT();if(mtDeviceList){for(CFIndex i=0;i<CFArrayGetCount(mtDeviceList);i++)mtUnregister((MTDeviceRef)CFArrayGetValueAtIndex(mtDeviceList,i),mtFrame);CFRelease(mtDeviceList);mtDeviceList=nullptr;}
 if(inputTap){CGEventTapEnable(inputTap,false);CFMachPortInvalidate(inputTap);CFRelease(inputTap);inputTap=nullptr;}
 if(inputSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),inputSource,kCFRunLoopCommonModes);CFRelease(inputSource);inputSource=nullptr;}
 if(inputObserver){[NSNotificationCenter.defaultCenter removeObserver:inputObserver];inputObserver=nil;}
 if(awakeAssertion!=kIOPMNullAssertionID){IOPMAssertionRelease(awakeAssertion);awakeAssertion=kIOPMNullAssertionID;}
}
extern "C" int air_input_grabbing(){return clientInput&&connected&&enabled;}
extern "C" int air_input_secure_active(){return secureInputEnabled&&secureInputEnabled();}
extern "C" int air_host_input_begin(int id,int requestedRaw) {
 std::lock_guard<std::mutex> lock(hostInputMutex);
 if(hostShutdown){air_set_error("Remote input host is shutting down");return -1;}
 if(hostOwner&&hostOwner!=id){air_set_error("Another Air already controls Remote Mode");return -1;}
 if(!CGPreflightPostEventAccess()){air_set_error("Allow RustDesk Air Host in Accessibility to receive native input");return -1;}
 if(!hostOwner){hostRawDeadline=0;hostRawExpired=false;hostRawReady=false;hostRawFull=false;}
 if(!hostOwner&&requestedRaw){
  bool probe=rawProbeSeconds>0;
  if((probe&&hostRawSpent)||(!probe&&!rawFullEnabled)||!modernTouchAPI().ready()||!localTouchDeviceID()){
   air_set_error("Native raw contacts are unavailable on this Mac");return -1;
  }
  hostRawReady=true;hostRawFull=!probe;
  if(probe){
   hostRawSpent=true;hostRawDeadline=uptimeNs()+(uint64_t)rawProbeSeconds.load()*NSEC_PER_SEC;
   uint64_t deadline=hostRawDeadline;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)rawProbeSeconds.load()*NSEC_PER_SEC),dispatch_get_main_queue(),^{
    std::lock_guard<std::mutex> timerLock(hostInputMutex);
    if(hostOwner==id&&hostRawDeadline==deadline&&uptimeNs()>=deadline)expireHostRaw();
   });
   fprintf(stderr,"air_raw_probe_host_started=1 duration_seconds=%d\n",rawProbeSeconds.load());
  }else fprintf(stderr,"air_raw_full_host_started=1 version=2\n");
 }
 hostOwner=id;return 0;
}
extern "C" int air_host_input_event(int id,const uint8_t *bytes,size_t len) {
 if(!bytes||!len||len>65536){air_set_error("Invalid native input packet");return -1;}
 std::lock_guard<std::mutex> lock(hostInputMutex);
 if(hostShutdown){air_set_error("Remote input host is shutting down");return -1;}
 if(!hostOwner||hostOwner!=id){air_set_error("Remote input session is not active");return -1;}
 if(len>=5&&!memcmp(bytes,"RDAF",4)){
  RawFrameV2 frame;if(!decodeRawV2(bytes,len,frame)){traceRaw("host_drop",len>=24?rawGet64(bytes+16):0,len>=6?bytes[5]:0,len>=32?rawGet64(bytes+24):0,"decode");air_set_error("Invalid native touch frame v2");return -1;}
  traceRaw("host_decoded",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs);
  if(hostRawDeadline&&uptimeNs()>=hostRawDeadline)expireHostRaw();
  if(hostRawExpired){traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"probe_expired");return 0;}
  if(!hostRawReady||(!hostRawFull&&!hostRawDeadline)){traceRaw("host_drop",frame.sequence,(unsigned)frame.items.size(),frame.sourceNs,"not_negotiated");air_set_error("Native raw contacts were not negotiated");return -1;}
  if(!receiveContactsV2(frame)){air_set_error("Invalid or out-of-order native touch frame");return -1;}
  return 0;
 }
 auto data=CFDataCreate(kCFAllocatorDefault,bytes,len);
 auto event=CGEventCreateFromData(kCFAllocatorDefault,data);CFRelease(data);
 if(!event){air_set_error("Cannot decode native input packet");return -1;}
 auto type=CGEventGetType(event);
 if(!forwardType(type)){CFRelease(event);air_set_error("Unrequested native input event type");return -1;}
 traceNativeScroll("pro_decoded",event);
 bool convertedDockSwipe=false,dockSwipe27=false;
 if(type==30 && CGEventGetIntegerValueField(event,(CGEventField)110)==23
    && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27){
  const auto &api=hidTimestampAPI();auto hid=api.ready()?api.copy(event):nullptr;
  bool modern=hid&&CFGetTypeID(hid)==api.typeID()&&api.type(hid)==23;
  if(hid)CFRelease(hid);
  if(!modern){
   auto converted=air_dockswipe27_convert(event,mach_absolute_time());CFRelease(event);
   if(!converted){releaseHost();air_set_error("Cannot translate this Air system gesture for the Pro's macOS version");return -1;}
   event=converted;convertedDockSwipe=true;
  }
  dockSwipe27=true;
 }
 if(nativeTrackpadType(type)){
  if(!normalizeNativeHIDTimestamp(event,localTouchDeviceID())){
   CFRelease(event);if(convertedDockSwipe)releaseHost();air_set_error("Cannot normalize native trackpad timestamps on this Mac");return -1;
  }
 }
 auto key=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
 if(type==14){@try{NSEvent *native=[NSEvent eventWithCGEvent:event];if(native.subtype==8){int data=(int)native.data1;int media=(data>>16)&0xffff;if(((data>>8)&0xff)==11)hostMedia.erase(media);else if(((data>>8)&0xff)==10)hostMedia.insert(media);}}@catch(NSException*){}}
 if(type==kCGEventKeyDown||type==kCGEventKeyUp||type==kCGEventFlagsChanged){
  if(key<0||key>0xffff){CFRelease(event);air_set_error("Invalid native key code");return -1;}
  if(type==kCGEventKeyDown)hostKeys.insert((CGKeyCode)key);
  if(type==kCGEventKeyUp)hostKeys.erase((CGKeyCode)key);
  if(type==kCGEventFlagsChanged){
   noteModifier((CGKeyCode)key,CGEventGetFlags(event));
  }
  hostFlags=CGEventGetFlags(event);
 }
 // Absolute event locations belong to the Air; dispatch gestures at the Pro cursor.
 auto cursor=CGEventCreate(nullptr);if(cursor){CGEventSetLocation(event,CGEventGetLocation(cursor));CFRelease(cursor);}
 CGEventSetTimestamp(event,clock_gettime_nsec_np(CLOCK_UPTIME_RAW));CGEventSetIntegerValueField(event,kCGEventSourceUserData,inputTag);
 traceNativeScroll("pro_posted",event);
 CGEventPost(nativeReplayTap(type,dockSwipe27),event);CFRelease(event);injected++;return 0;
}
extern "C" void air_host_input_release(int id){
 bool owned=false;
 {std::lock_guard<std::mutex> lock(hostInputMutex);owned=hostOwner==id;if(owned)releaseHost();}
 if(owned){std::lock_guard<std::mutex> wait(edgeTransferMutex);}
}
extern "C" void air_host_input_end(int id){
 bool owned=false;
 {std::lock_guard<std::mutex> lock(hostInputMutex);owned=hostOwner==id;
  if(owned){hostRawDeadline=0;hostRawExpired=false;hostRawReady=false;hostRawFull=false;releaseHost();hostOwner=0;}}
 if(owned){std::lock_guard<std::mutex> wait(edgeTransferMutex);}
}
extern "C" void air_host_input_shutdown(){
 {std::lock_guard<std::mutex> lock(hostInputMutex);
  if(!hostShutdown){hostShutdown=true;hostRawDeadline=0;hostRawExpired=false;hostRawReady=false;hostRawFull=false;releaseHost();hostOwner=0;}}
 std::lock_guard<std::mutex> wait(edgeTransferMutex);
}
extern "C" void air_input_metrics(uint64_t *sent,uint64_t *gesture,uint64_t *touch,uint64_t *posted,uint64_t *escaped){*sent=forwarded;*gesture=gestures;*touch=contacts;*posted=injected;*escaped=escapes;}
extern "C" void air_raw_metrics(uint64_t *sent,uint64_t *posted,uint64_t *stale,uint64_t *contactDuplicates){*sent=rawFramesSent;*posted=rawFramesPosted;*stale=rawStaleRejected;*contactDuplicates=rawContactDuplicates;}
