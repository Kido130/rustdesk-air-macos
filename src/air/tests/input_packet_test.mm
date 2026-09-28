#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cassert>
#include <vector>
struct PostedEvent {CGEventTapLocation tap;CGEventType type;CGKeyCode key;CGEventFlags flags;CGEventTimestamp timestamp;uint64_t hidTimestamp;uint64_t sender;uint32_t hidType,phase;NSUInteger touches;int64_t subtype,motion;double progress,velocity;int64_t pointY,pointX,scrollPhase,momentumPhase;};
static std::vector<PostedEvent> posted;
static unsigned diagnosticFrames;
static unsigned long diagnosticBytes;
static std::vector<int> swipePhases,swipeDirections;
static void observeSwipe(int phase,int direction,uint64_t){swipePhases.push_back(phase);swipeDirections.push_back(direction);}
extern "C" void air_capture_v2_record_mt(const unsigned char *packet,unsigned long length,double){
 assert(packet&&length>=16);diagnosticFrames++;diagnosticBytes=length;
}
static void observePost(CGEventTapLocation,CGEventRef event);
@interface FixtureActiveApp : NSObject
@property(nonatomic, readonly, getter=isActive) BOOL active;
@end
@implementation FixtureActiveApp
- (BOOL)isActive { return YES; }
@end
static NSApplication *fixtureApp;
#define CGEventPost observePost
#define CGPreflightPostEventAccess() true
#define NSApp fixtureApp
#include "../input.mm"
#undef CGEventPost
#undef CGPreflightPostEventAccess
#undef NSApp
#include <sys/stat.h>
extern "C" {
CFDataRef IOHIDEventCreateData(CFAllocatorRef,CFTypeRef);
CFTypeRef IOHIDEventCreateWithData(CFAllocatorRef,CFDataRef);
CFArrayRef IOHIDEventGetChildren(CFTypeRef);
CFIndex IOHIDEventGetIntegerValue(CFTypeRef,uint32_t);
double IOHIDEventGetFloatValue(CFTypeRef,uint32_t);
uint64_t IOHIDEventGetTimeStamp(CFTypeRef);
}

extern "C" void air_set_error(const char *) {}
extern "C" void air_status(const char *,int) {}
extern "C" int air_spaces_current_slot(){return 0;}
extern "C" int air_spaces_slot_count(){return 0;}
extern "C" int air_spaces_transfer_window_edge(uint32_t,int,int){assert(false);return -1;}
extern "C" uint32_t air_builtin_display(){return 0;}
extern "C" void air_app_stop(void) {}
extern "C" void air_keyboard_probe_ready(int) {}
extern "C" void air_keyboard_probe_shutdown(void) {}
extern "C" void air_cursor_probe_ready(int) {}
extern "C" void air_cursor_probe_shutdown(void) {}
static int fixtureMTStart(MTDeviceRef,int){return 0;}
static int fixtureMTStartFail(MTDeviceRef,int){return -1;}
static int fixtureMTStop(MTDeviceRef){return 0;}
static bool fixtureMTRegister(MTDeviceRef,MTCallback){return true;}
static bool fixtureMTRegisterFail(MTDeviceRef,MTCallback){return false;}
static void fixtureMTUnregister(MTDeviceRef,MTCallback){}
static int fixtureMTID(MTDeviceRef,uint64_t *id){*id=1;return 0;}
static void observePost(CGEventTapLocation tap,CGEventRef event){
 auto &api=hidTimestampAPI();auto hid=api.ready()?api.copy(event):nullptr;
 uint64_t hidTime=hid?api.timestamp(hid):0,sender=hid?api.sender(hid):0;uint32_t hidType=hid?api.type(hid):0;
 if(hid)CFRelease(hid);
 NSUInteger touches=0;if(CGEventGetType(event)==29){@try{touches=[NSEvent eventWithCGEvent:event].allTouches.count;}@catch(NSException*){}}
 posted.push_back({tap,CGEventGetType(event),(CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode),CGEventGetFlags(event),CGEventGetTimestamp(event),hidTime,sender,hidType,(uint32_t)CGEventGetIntegerValueField(event,(CGEventField)0x84),touches,CGEventGetIntegerValueField(event,(CGEventField)110),CGEventGetIntegerValueField(event,(CGEventField)123),CGEventGetDoubleValueField(event,(CGEventField)124),CGEventGetDoubleValueField(event,(CGEventField)129),CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis1),CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis2),CGEventGetIntegerValueField(event,kCGScrollWheelEventScrollPhase),CGEventGetIntegerValueField(event,kCGScrollWheelEventMomentumPhase)});
}
static std::vector<int> sent;
static std::vector<uint8_t> lastRawPacket;
static std::vector<uint8_t> lastNativePacket;
static std::atomic<bool> blockEvent(false),blockRelease(false);
static dispatch_semaphore_t callbackEntered,callbackResume;
static void waitAtCallback(){dispatch_semaphore_signal(callbackEntered);dispatch_semaphore_wait(callbackResume,DISPATCH_TIME_FOREVER);}
static void onPacket(const uint8_t *bytes,size_t size,uint64_t generation){
 if(blockEvent)waitAtCallback();
 // Mirror Rust's final epoch check after the native queue's own check.
 if(size&&generation==air_input_generation()){
  sent.push_back(bytes[0]);
  if(size>=5&&!memcmp(bytes,"RDAF",4))lastRawPacket.assign(bytes,bytes+size);
  else lastNativePacket.assign(bytes,bytes+size);
 }
}
static void onRelease(uint64_t generation){
 if(blockRelease)waitAtCallback();
 if(generation==air_input_generation())sent.push_back(99);
}

static void put32(uint8_t *bytes,uint32_t value){value=CFSwapInt32HostToLittle(value);memcpy(bytes,&value,4);}
static void putFloat(uint8_t *bytes,float value){uint32_t bits;memcpy(&bits,&value,4);put32(bytes,bits);}

int main(int argc,char **argv){
 assert(argc==1||argc==2);
 static_assert(sizeof(MTTouch)==96,"MultitouchSupport contact layout changed");
 MTTouch diagnosticTouch{};diagnosticTouch.fingerID=3;diagnosticTouch.state=4;
 diagnosticTouch.normalizedVector.position={.25f,.75f};diagnosticTouch.zTotal=1;
 connected=true;enabled=true;diagnosticCapture=true;
 mtFrame(nullptr,&diagnosticTouch,1,123.0,0);
 assert(diagnosticFrames==1&&diagnosticBytes==36);
 connected=false;mtFrame(nullptr,&diagnosticTouch,1,124.0,0);assert(diagnosticFrames==1);
 connected=true;diagnosticCapture=false;mtFrame(nullptr,&diagnosticTouch,1,125.0,0);assert(diagnosticFrames==1);
 captureMode=true;mtFrame(nullptr,&diagnosticTouch,1,125.0,10);
 auto firstRawFrame=rawSample;
 diagnosticTouch.timestamp=999.0;diagnosticTouch.frame=900;
 diagnosticTouch.normalizedVector.velocity={.5f,.4f};
 mtFrame(nullptr,&diagnosticTouch,1,999.0,900);
 assert(rawSample==firstRawFrame);
 captureMode=false;rawSample.clear();
 connected=false;enabled=false;
 uint8_t packet[56]={'R','D','A','F',1,2,0,0};
 uint64_t device=CFSwapInt64HostToLittle(42);memcpy(packet+8,&device,8);
 put32(packet+16,7);put32(packet+20,4);putFloat(packet+24,.25f);putFloat(packet+28,.75f);putFloat(packet+32,3.5f);
 put32(packet+36,8);put32(packet+40,3);putFloat(packet+44,.5f);putFloat(packet+48,.6f);putFloat(packet+52,0.f);
 std::map<uint32_t,RawContact> parsed;uint64_t decodedDevice=0;
 assert(decodeContacts(packet,sizeof(packet),parsed,decodedDevice));
 assert(decodedDevice==42&&parsed.size()==2&&parsed[7].x==.25f&&parsed[7].pressure==3.5f);
 assert(!decodeContacts(packet,sizeof(packet)-1,parsed,decodedDevice));
 packet[5]=17;parsed.clear();assert(!decodeContacts(packet,sizeof(packet),parsed,decodedDevice));packet[5]=2;
 put32(packet+36,7);parsed.clear();assert(!decodeContacts(packet,sizeof(packet),parsed,decodedDevice));put32(packet+36,8);
 putFloat(packet+24,NAN);parsed.clear();assert(!decodeContacts(packet,sizeof(packet),parsed,decodedDevice));putFloat(packet+24,.25f);
 hostContacts.clear();hostTouchDevice=0;hostLocalTouchDevice=0;posted.clear();
 assert(receiveContacts(packet,sizeof(packet))&&hostContacts.size()==2);
 assert(posted.size()==1&&posted.back().type==29&&posted.back().phase==1&&posted.back().touches==2);
 put32(packet+40,4);assert(receiveContacts(packet,sizeof(packet))&&hostContacts.size()==2);
 assert(posted.size()==2&&posted.back().phase==2&&posted.back().touches==2);
 put32(packet+20,2);assert(receiveContacts(packet,sizeof(packet))&&hostContacts.size()==1);
 assert(posted.size()==3&&posted.back().phase==2&&posted.back().touches==2);
 put32(packet+20,7);put32(packet+40,7);
 assert(receiveContacts(packet,sizeof(packet))&&hostContacts.empty());
 assert(posted.size()==4&&posted.back().phase==4&&posted.back().touches==1);
 assert(receiveContacts(packet,sizeof(packet))&&posted.size()==4);
 put32(packet+20,3);put32(packet+40,4);
 assert(receiveContacts(packet,sizeof(packet))&&hostContacts.size()==2&&posted.back().phase==1);
 size_t beforeEmpty=posted.size();packet[5]=0;
 assert(receiveContacts(packet,16)&&hostContacts.empty()&&posted.size()==beforeEmpty+1&&posted.back().phase==4&&posted.back().touches==2);
 assert(receiveContacts(packet,16)&&posted.size()==beforeEmpty+1);
 packet[5]=2;
 put32(packet+20,4);put32(packet+40,3);hostTouchDevice=0;hostLocalTouchDevice=0;posted.clear();
 assert(receiveContacts(packet,sizeof(packet))&&posted.size()==1&&posted.back().phase==1);
 uint64_t nextDevice=CFSwapInt64HostToLittle(43);memcpy(packet+8,&nextDevice,8);
 assert(receiveContacts(packet,sizeof(packet))&&hostTouchDevice==43&&hostContacts.size()==2);
 assert(posted.size()==3&&posted[1].phase==4&&posted[1].touches==2&&posted[2].phase==1&&posted[2].touches==2);
 posted.clear();hostContacts.clear();hostTouchDevice=0;hostLocalTouchDevice=0;
 assert(modifierMask(55)==kCGEventFlagMaskCommand&&modifierMask(60)==kCGEventFlagMaskShift);
 assert(keyboardType(kCGEventKeyDown)&&keyboardType(kCGEventKeyUp)&&keyboardType(kCGEventFlagsChanged)&&keyboardType((CGEventType)14));
 assert(!keyboardType(kCGEventScrollWheel)&&!keyboardType((CGEventType)29));
 assert(forwardType((CGEventType)29)&&!forwardType(kCGEventMouseMoved));
 assert(nativeTrackpadType(kCGEventScrollWheel)&&nativeTrackpadType((CGEventType)29)&&!nativeTrackpadType(kCGEventKeyDown));
 assert(nativeReplayTap(kCGEventScrollWheel,false)==kCGSessionEventTap);
 assert(nativeReplayTap((CGEventType)29,false)==kCGHIDEventTap);
 assert(nativeReplayTap((CGEventType)30,true)==kCGSessionEventTap);
 assert(nativeReplayTap(kCGEventKeyDown,false)==kCGHIDEventTap);
 rawAllowed=true;rawFullEnabled=true;rawProbeSeconds=0;assert(rawContactsAuthoritative());
 auto semanticWheel=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitPixel,2,8,-5);
 assert(semanticWheel&&!suppressNativeTrackpadEvent(kCGEventScrollWheel,semanticWheel));CFRelease(semanticWheel);
 auto semanticGesture=CGEventCreate(nullptr);assert(semanticGesture);
 for(CGEventType type:{(CGEventType)18,(CGEventType)19,(CGEventType)20,(CGEventType)30,(CGEventType)31,(CGEventType)32,(CGEventType)34}){
  CGEventSetType(semanticGesture,type);assert(!suppressNativeTrackpadEvent(type,semanticGesture));
 }
 CGEventSetType(semanticGesture,(CGEventType)30);CGEventSetIntegerValueField(semanticGesture,(CGEventField)110,23);
 CGEventSetIntegerValueField(semanticGesture,(CGEventField)132,2);CGEventSetDoubleValueField(semanticGesture,(CGEventField)124,-.4);
 CGEventSetDoubleValueField(semanticGesture,(CGEventField)129,-120);
 assert(!suppressNativeTrackpadEvent((CGEventType)30,semanticGesture)); // Three-finger Dock motion is semantic.
 CGEventSetType(semanticGesture,(CGEventType)29);assert(!suppressNativeTrackpadEvent((CGEventType)29,semanticGesture));
 assert(!suppressNativeTrackpadEvent(kCGEventKeyDown,semanticGesture)&&!suppressNativeTrackpadEvent((CGEventType)14,semanticGesture));
 rawProbeSeconds=3;clientRawDeadline=uptimeNs()+NSEC_PER_SEC;assert(rawContactsAuthoritative()&&!suppressNativeTrackpadEvent((CGEventType)30,semanticGesture));
 rawAllowed=false;rawProbeSeconds=0;clientRawDeadline=0;
 assert(!rawContactsAuthoritative());
 assert(!suppressNativeTrackpadEvent((CGEventType)29,semanticGesture));CFRelease(semanticGesture);
 edgeDrag.owner=43;edgeDrag.wid=100;edgeDrag.policy.begin({300,200,200,150,800,600,1000000000ULL,0});
 hostKeys={12};hostFlags=kCGEventFlagMaskCommand;releaseHost();
 assert(!edgeDrag.owner&&!edgeDrag.wid&&!edgeDrag.policy.active);
 assert(posted.size()==2&&posted[0].type==kCGEventKeyUp&&posted[0].key==12);
 assert(posted[1].type==kCGEventFlagsChanged&&posted[1].key==55&&posted[1].flags==0);
 posted.clear();hostKeys.clear();hostFlags=kCGEventFlagMaskCommand|kCGEventFlagMaskControl;releaseHost();
 assert(posted.size()==2&&posted[0].type==kCGEventFlagsChanged&&posted[1].type==kCGEventFlagsChanged);
 posted.clear();hostKeys.clear();hostFlags=0;
 noteModifier(55,kCGEventFlagMaskCommand|0x8);assert(hostKeys.count(55));hostFlags=kCGEventFlagMaskCommand|0x8;
 noteModifier(54,kCGEventFlagMaskCommand|0x18);assert(hostKeys.count(54));hostFlags=kCGEventFlagMaskCommand|0x18;
 noteModifier(54,kCGEventFlagMaskCommand|0x8);assert(!hostKeys.count(54)&&hostKeys.count(55));
 hostKeys.clear();hostFlags=0;
 auto keyboard=CGEventCreateKeyboardEvent(nullptr,12,true);
 const auto &hidAPI=hidTimestampAPI();assert(hidAPI.ready());
 auto keyHID=hidAPI.copy(keyboard);assert(!keyHID);
 auto wheel=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitPixel,1,5);
 assert(wheel&&normalizeNativeHIDTimestamp(wheel));CFRelease(wheel);
 auto magnify=CGEventCreate(nullptr);assert(magnify);
 CGEventSetType(magnify,(CGEventType)30);
 auto magnifyBytes=CGEventCreateData(kCFAllocatorDefault,magnify);assert(magnifyBytes);
 auto decodedMagnify=CGEventCreateFromData(kCFAllocatorDefault,magnifyBytes);
 assert(decodedMagnify&&CGEventGetType(decodedMagnify)==30);
 auto magnifyHID=hidAPI.copy(decodedMagnify);assert(!magnifyHID);
 assert(normalizeNativeHIDTimestamp(decodedMagnify));
 CFRelease(decodedMagnify);CFRelease(magnifyBytes);CFRelease(magnify);
 CGEventSetTimestamp(keyboard,123);
 auto data=CGEventCreateData(nullptr,keyboard);
 CGEventTimestamp earliest=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
 hostOwner=43;
 assert(air_host_input_event(43,CFDataGetBytePtr(data),CFDataGetLength(data))==0);
 CGEventTimestamp latest=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
 CFRelease(data);CFRelease(keyboard);
 assert(posted.size()==1&&posted[0].type==kCGEventKeyDown);
 assert(posted[0].timestamp>=earliest&&posted[0].timestamp<=latest);
 for(CGKeyCode keycode:{(CGKeyCode)63,(CGKeyCode)179}){
  auto extra=CGEventCreateKeyboardEvent(nullptr,keycode,true);assert(extra);
  if(keycode==63){CGEventSetType(extra,kCGEventFlagsChanged);CGEventSetFlags(extra,kCGEventFlagMaskSecondaryFn);}
  auto extraData=CGEventCreateData(kCFAllocatorDefault,extra);assert(extraData);
  assert(air_host_input_event(43,CFDataGetBytePtr(extraData),CFDataGetLength(extraData))==0);
  assert(posted.back().key==keycode);
  CFRelease(extraData);CFRelease(extra);
 }
 hostKeys.clear();posted.clear();
 auto sourceWheel=CGEventCreateScrollWheelEvent2(nullptr,kCGScrollEventUnitPixel,2,37,-19,0);assert(sourceWheel);
 CGEventSetIntegerValueField(sourceWheel,kCGScrollWheelEventIsContinuous,1);
 CGEventSetIntegerValueField(sourceWheel,kCGScrollWheelEventScrollPhase,2);
 CGEventSetIntegerValueField(sourceWheel,kCGScrollWheelEventMomentumPhase,0);
 auto wheelData=CGEventCreateData(kCFAllocatorDefault,sourceWheel);assert(wheelData);
 assert(air_host_input_event(43,CFDataGetBytePtr(wheelData),CFDataGetLength(wheelData))==0);
 assert(posted.size()==1&&posted[0].tap==kCGSessionEventTap&&posted[0].type==kCGEventScrollWheel);
 assert(posted[0].pointY==CGEventGetIntegerValueField(sourceWheel,kCGScrollWheelEventPointDeltaAxis1));
 assert(posted[0].pointX==CGEventGetIntegerValueField(sourceWheel,kCGScrollWheelEventPointDeltaAxis2));
 assert(posted[0].scrollPhase==CGEventGetIntegerValueField(sourceWheel,kCGScrollWheelEventScrollPhase));
 assert(posted[0].momentumPhase==CGEventGetIntegerValueField(sourceWheel,kCGScrollWheelEventMomentumPhase));
 CFRelease(wheelData);CFRelease(sourceWheel);posted.clear();
 auto sendLegacyDock=[&](uint32_t phase,double progress,double velocity){
  auto event=CGEventCreate(nullptr);assert(event);CGEventSetType(event,(CGEventType)30);
  CGEventSetIntegerValueField(event,(CGEventField)110,23);CGEventSetIntegerValueField(event,(CGEventField)132,phase);
  CGEventSetIntegerValueField(event,(CGEventField)123,1);CGEventSetDoubleValueField(event,(CGEventField)124,progress);
  CGEventSetDoubleValueField(event,(CGEventField)129,velocity);CGEventSetDoubleValueField(event,(CGEventField)130,velocity);
  auto bytes=CGEventCreateData(kCFAllocatorDefault,event);CFRelease(event);assert(bytes);
  int result=air_host_input_event(43,CFDataGetBytePtr(bytes),CFDataGetLength(bytes));CFRelease(bytes);return result;
 };
 bool dockBridgeExpected=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion>=27;
 uint64_t dockEarly=mach_absolute_time();CGEventTimestamp legacyEarly=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
 assert(sendLegacyDock(1,-.1,0)==0&&sendLegacyDock(2,-.5,0)==0&&sendLegacyDock(4,-.8,-120)==0);
 CGEventTimestamp legacyLate=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);uint64_t dockLate=mach_absolute_time();
 assert(posted.size()==3);
 if(dockBridgeExpected){
  for(const auto &event:posted)assert(event.tap==kCGSessionEventTap&&event.type==30&&event.hidType==23
      && event.hidTimestamp>=dockEarly&&event.hidTimestamp<=dockLate);
  posted.clear();assert(sendLegacyDock(1,.1,0)==0&&posted.size()==1);air_host_input_release(43);
  assert(posted.size()==2&&posted[0].tap==kCGSessionEventTap&&posted[1].tap==kCGSessionEventTap
      && posted[0].hidType==23&&posted[1].hidType==23);
  air_host_input_release(43);assert(posted.size()==2); // release cancellation is exactly once.
  posted.clear();
  auto modernSource=CGEventCreate(nullptr);assert(modernSource);CGEventSetType(modernSource,(CGEventType)30);
  CGEventSetIntegerValueField(modernSource,(CGEventField)110,23);CGEventSetIntegerValueField(modernSource,(CGEventField)132,1);
  CGEventSetIntegerValueField(modernSource,(CGEventField)123,1);CGEventSetDoubleValueField(modernSource,(CGEventField)124,-.1);
  auto modern=air_dockswipe27_convert(modernSource,mach_absolute_time());CFRelease(modernSource);assert(modern);
  // Attaching a modern HID root does not synthesize legacy field 110. Air packets
  // that retain both the legacy subtype and modern root must still use Session tap.
  assert(CGEventGetType(modern)==30&&CGEventGetIntegerValueField(modern,(CGEventField)110)==0);
  CGEventSetIntegerValueField(modern,(CGEventField)110,23);
  auto modernBytes=CGEventCreateData(kCFAllocatorDefault,modern);CFRelease(modern);assert(modernBytes);
  auto clearModernFixtureState=air_dockswipe27_cancel(mach_absolute_time());assert(clearModernFixtureState);CFRelease(clearModernFixtureState);
  dockEarly=mach_absolute_time();assert(air_host_input_event(43,CFDataGetBytePtr(modernBytes),CFDataGetLength(modernBytes))==0);dockLate=mach_absolute_time();CFRelease(modernBytes);
  assert(posted.size()==1&&posted[0].tap==kCGSessionEventTap&&posted[0].type==30&&posted[0].hidType==23
      && posted[0].hidTimestamp>=dockEarly&&posted[0].hidTimestamp<=dockLate);
 }else{
  const uint32_t phases[]={1,2,4};const double progress[]={-.1,-.5,-.8};const double velocity[]={0,0,-120};
  for(size_t i=0;i<posted.size();i++)assert(posted[i].tap==kCGHIDEventTap&&posted[i].type==30&&posted[i].hidType==0
      && posted[i].hidTimestamp==0&&posted[i].timestamp>=legacyEarly&&posted[i].timestamp<=legacyLate
      && posted[i].subtype==23&&posted[i].phase==phases[i]&&posted[i].motion==1
      && std::abs(posted[i].progress-progress[i])<1e-5&&std::abs(posted[i].velocity-velocity[i])<1e-5);
 }
 hostOwner=0;posted.clear();
 if(argc==2){
  NSData *file=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
  auto bytes=(const uint8_t *)file.bytes;
  assert(file.length>=48&&!memcmp(bytes,"RDAICAP1",8));
  uint32_t cgLength;memcpy(&cgLength,bytes+8,4);cgLength=CFSwapInt32LittleToHost(cgLength);
  assert(cgLength>0&&cgLength<=65536&&file.length>=48ULL+cgLength);
  auto packet=CFDataCreate(kCFAllocatorDefault,bytes+48,cgLength);
  auto native=CGEventCreateFromData(kCFAllocatorDefault,packet);CFRelease(packet);
  assert(native&&CGEventGetType(native)==29);
  assert(!contactOnlyCG29(native)); // Real Air packet includes scroll semantics alongside fingers.
  rawAllowed=true;rawFullEnabled=true;rawProbeSeconds=0;
  assert([NSEvent eventWithCGEvent:native].subtype==0); // This real Air contact packet has no subtype marker.
  auto mixedHID=hidAPI.copy(native);assert(mixedHID);
  auto mixedChildren=hidAPI.children(mixedHID);assert(mixedChildren&&CFArrayGetCount(mixedChildren)>0);
  bool hasFinger=false,hasScroll=false;
  for(CFIndex i=0;i<CFArrayGetCount(mixedChildren);i++){
   auto child=(CFTypeRef)CFArrayGetValueAtIndex(mixedChildren,i);
   hasFinger|=hidAPI.type(child)==11;hasScroll|=hidAPI.type(child)==6;
  }
  CFRelease(mixedHID);
  assert(hasFinger&&hasScroll&&!suppressNativeTrackpadEvent((CGEventType)29,native));
  auto filterEvent=CGEventCreateCopy(native);assert(filterEvent);
  auto filtered=serializeNativeCG29WithoutDuplicateFingers(filterEvent);assert(filtered);
  auto filteredEvent=CGEventCreateFromData(kCFAllocatorDefault,filtered);assert(filteredEvent&&CGEventGetType(filteredEvent)==29);
  auto filteredHID=hidAPI.copy(filteredEvent);assert(filteredHID&&hidAPI.type(filteredHID)==11);
  auto filteredChildren=hidAPI.children(filteredHID);assert(filteredChildren&&CFArrayGetCount(filteredChildren)==2);
  assert(hidAPI.type((CFTypeRef)CFArrayGetValueAtIndex(filteredChildren,0))==6);
  assert(hidAPI.type((CFTypeRef)CFArrayGetValueAtIndex(filteredChildren,1))==1);
  auto semanticOnly=serializeNativeCG29WithoutDuplicateFingers(filteredEvent);assert(semanticOnly);
  auto semanticRoundtrip=CGEventCreateFromData(kCFAllocatorDefault,semanticOnly);assert(semanticRoundtrip&&CGEventGetType(semanticRoundtrip)==29);
  auto semanticHID=hidAPI.copy(semanticRoundtrip);assert(semanticHID);
  auto semanticChildren=hidAPI.children(semanticHID);assert(semanticChildren&&CFArrayGetCount(semanticChildren)==2);
  assert(hidAPI.type((CFTypeRef)CFArrayGetValueAtIndex(semanticChildren,0))==6);
  assert(hidAPI.type((CFTypeRef)CFArrayGetValueAtIndex(semanticChildren,1))==1);
  CFRelease(semanticHID);CFRelease(semanticRoundtrip);CFRelease(semanticOnly);
  CFRelease(filteredHID);CFRelease(filteredEvent);CFRelease(filtered);CFRelease(filterEvent);
  rawAllowed=false;
  auto before=hidAPI.copy(native);assert(before);
  uint64_t sender=hidAPI.sender(before),airTicks=hidAPI.timestamp(before);
  std::vector<HIDNodeShape> beforeShape;assert(inspectHIDTree(hidAPI,before,airTicks,beforeShape,0));
  auto beforeData=IOHIDEventCreateData(kCFAllocatorDefault,before);assert(beforeData);
  CFRelease(before);
  auto originalFlags=CGEventGetFlags(native),originalTimestamp=CGEventGetTimestamp(native);
  uint64_t earlyTicks=mach_absolute_time();
  assert(normalizeNativeHIDTimestamp(native));
  uint64_t lateTicks=mach_absolute_time();
  auto updated=hidAPI.copy(native);assert(updated);
  uint64_t proTicks=hidAPI.timestamp(updated);
  assert(proTicks>=earlyTicks&&proTicks<=lateTicks&&proTicks!=airTicks);
  std::vector<HIDNodeShape> afterShape;
  assert(inspectHIDTree(hidAPI,updated,proTicks,afterShape,0)&&sameHIDShape(beforeShape,afterShape));
  assert(hidAPI.sender(updated)==sender&&CGEventGetFlags(native)==originalFlags&&CGEventGetTimestamp(native)==originalTimestamp);
  auto expected=IOHIDEventCreateWithData(kCFAllocatorDefault,beforeData);assert(expected);
  setHIDTreeTimestamp(hidAPI,expected,proTicks);
  auto expectedData=IOHIDEventCreateData(kCFAllocatorDefault,expected);
  auto actualData=IOHIDEventCreateData(kCFAllocatorDefault,updated);
  assert(expectedData&&actualData);
  if(dockBridgeExpected)assert(CFEqual(expectedData,actualData));
  auto roundData=CGEventCreateData(kCFAllocatorDefault,native);
  auto round=CGEventCreateFromData(kCFAllocatorDefault,roundData);
  auto roundHID=round?hidAPI.copy(round):nullptr;
  auto roundHIDData=roundHID?IOHIDEventCreateData(kCFAllocatorDefault,roundHID):nullptr;
  assert(round&&CGEventGetType(round)==29&&roundHIDData);
  if(dockBridgeExpected)assert(CFEqual(actualData,roundHIDData));
  std::vector<HIDNodeShape> roundShape;
  assert(inspectHIDTree(hidAPI,roundHID,proTicks,roundShape,0)&&sameHIDShape(afterShape,roundShape));
  assert(hidAPI.sender(roundHID)==sender&&hidAPI.timestamp(roundHID)==proTicks);
  CFRelease(roundHIDData);CFRelease(roundHID);CFRelease(round);CFRelease(roundData);
  CFRelease(actualData);CFRelease(expectedData);CFRelease(expected);CFRelease(beforeData);CFRelease(updated);CFRelease(native);
  posted.clear();hostOwner=43;
  uint64_t beforePostTicks=mach_absolute_time(),beforePostNs=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  assert(air_host_input_event(43,bytes+48,cgLength)==0);
  uint64_t afterPostTicks=mach_absolute_time(),afterPostNs=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  uint64_t localSender=localTouchDeviceID();assert(localSender);
  assert(posted.size()==1&&posted[0].type==29&&posted[0].sender==localSender);
  assert(posted[0].hidTimestamp>=beforePostTicks&&posted[0].hidTimestamp<=afterPostTicks);
  assert(posted[0].timestamp>=beforePostNs&&posted[0].timestamp<=afterPostNs);
  for(CGEventType gestureType:{(CGEventType)18,(CGEventType)19,(CGEventType)20}){
   auto physical=CFDataCreate(kCFAllocatorDefault,bytes+48,cgLength);
   auto variant=CGEventCreateFromData(kCFAllocatorDefault,physical);CFRelease(physical);assert(variant);
   CGEventSetType(variant,gestureType);
   auto variantData=CGEventCreateData(kCFAllocatorDefault,variant);assert(variantData);
   auto variantDecoded=CGEventCreateFromData(kCFAllocatorDefault,variantData);assert(variantDecoded);
   auto variantHID=hidAPI.copy(variantDecoded);bool hasHID=variantHID!=nullptr;if(variantHID)CFRelease(variantHID);CFRelease(variantDecoded);
   posted.clear();uint64_t early=mach_absolute_time();
   assert(air_host_input_event(43,CFDataGetBytePtr(variantData),CFDataGetLength(variantData))==0);
   uint64_t late=mach_absolute_time();
   assert(posted.size()==1&&posted[0].type==gestureType);
   if(hasHID)assert(posted[0].hidTimestamp>=early&&posted[0].hidTimestamp<=late);
   else assert(posted[0].hidTimestamp==0);
   CFRelease(variantData);CFRelease(variant);
  }
  hostOwner=0;posted.clear();
 }
 sendQueue=dispatch_queue_create("air.packet.test",DISPATCH_QUEUE_SERIAL);
 sendNative=onPacket;releaseRemote=onRelease;enabled=true;
 uint8_t first=1,second=2;
 assert(queueBytes(&first,1)&&queueBytes(&second,1));releaseClient();
 dispatch_sync(sendQueue,^{});
 assert((sent==std::vector<int>{99})&&pendingPackets==0);
 pendingPackets=256;assert(!queueBytes(&first,1));pendingPackets=0;
 sent.clear();enabled=true;
 auto oldQueueBlocked=dispatch_semaphore_create(0);
 dispatch_async(sendQueue,^{dispatch_semaphore_wait(oldQueueBlocked,DISPATCH_TIME_FOREVER);});
 assert(queueBytes(&first,1));releaseClient();
 air_input_connected(0);air_input_connected(1);
 dispatch_semaphore_signal(oldQueueBlocked);dispatch_sync(sendQueue,^{});
 assert(sent.empty()&&pendingPackets==0);
 assert(queueBytes(&second,1));dispatch_sync(sendQueue,^{});
 assert((sent==std::vector<int>{2}));
 sent.clear();callbackEntered=dispatch_semaphore_create(0);callbackResume=dispatch_semaphore_create(0);
 blockEvent=true;assert(queueBytes(&first,1));
 assert(dispatch_semaphore_wait(callbackEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 air_input_connected(0);air_input_connected(1);
 dispatch_semaphore_signal(callbackResume);dispatch_sync(sendQueue, ^{});blockEvent=false;
 assert(sent.empty());
 enabled=true;blockRelease=true;releaseClient();
 assert(dispatch_semaphore_wait(callbackEntered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 air_input_connected(0);air_input_connected(1);
 dispatch_semaphore_signal(callbackResume);dispatch_sync(sendQueue, ^{});blockRelease=false;
 assert(sent.empty());
 assert(queueBytes(&second,1));dispatch_sync(sendQueue,^{});
 assert((sent==std::vector<int>{2}));connected=false;
 sent.clear();rawAllowed=true;localUI=true;uint8_t gatedRaw[16]={'R','D','A','F',2};
 assert(queueBytes(gatedRaw,sizeof(gatedRaw)));dispatch_sync(sendQueue,^{});assert(sent.empty());
 localUI=false;rawAllowed=false;
 connected=true;enabled=true;rawAllowed=true;sent.clear();
 auto focusBlocked=dispatch_semaphore_create(0);dispatch_async(sendQueue,^{dispatch_semaphore_wait(focusBlocked,DISPATCH_TIME_FOREVER);});
 assert(queueBytes(gatedRaw,sizeof(gatedRaw)));releaseClient();enabled=true;
 dispatch_semaphore_signal(focusBlocked);dispatch_sync(sendQueue,^{});
 assert((sent==std::vector<int>{99}));rawAllowed=false;connected=false;enabled=false;

 @autoreleasepool {
  capturePath=[NSString stringWithFormat:@"/tmp/air_input_packet_capture_%d.bin",getpid()];
  unlink(capturePath.fileSystemRepresentation);
  gestureSample={1,2,3};rawSample.assign(packet,packet+sizeof(packet));
  captureGestures=2;captureFrames=3;captureContacts=4;captureNSETouches=5;captureMode=true;
  finishCapture();dispatch_sync(sendQueue,^{});
  struct stat info;
  NSString *path=[NSString stringWithFormat:@"/tmp/air_input_packet_capture_%d.bin",getpid()];
  assert(stat(path.fileSystemRepresentation,&info)==0);
  assert((info.st_mode&0777)==0600&&info.st_size==48+3+sizeof(packet));
  unlink(path.fileSystemRepresentation);
 }
 posted.clear();hostOwner=0;
 MTTouch rawTouches[2]{};rawTouches[0].fingerID=7;rawTouches[0].pathIndex=17;rawTouches[0].state=3;rawTouches[0].timestamp=123.005;rawTouches[0].normalizedVector.position={.25f,.75f};rawTouches[0].normalizedVector.velocity={.4f,-.2f};rawTouches[0].zTotal=.5f;rawTouches[0].angle=.3f;rawTouches[0].majorAxis=4;rawTouches[0].minorAxis=2;rawTouches[0].zDensity=.7f;
 rawTouches[1].fingerID=8;rawTouches[1].pathIndex=18;rawTouches[1].state=3;rawTouches[1].timestamp=123.;rawTouches[1].normalizedVector.position={.5f,.6f};rawTouches[1].zTotal=.6f;
 MTTouch provisional[3]{};for(auto &touch:provisional){touch.fingerID=0;touch.state=1;}
 assert(provisionalDuplicateBegins(provisional,3));
 provisional[2].state=4;assert(!provisionalDuplicateBegins(provisional,3));
 provisional[2].state=1;provisional[2].fingerID=2;assert(provisionalDuplicateBegins(provisional,3));
 provisional[0].fingerID=2;assert(!provisionalDuplicateBegins(provisional,3));
 provisional[0].fingerID=0;
 auto beforeProvisionalSequence=rawSequence.load(),beforeProvisionalFrames=rawFramesSent.load(),beforeProvisionalGeneration=inputGeneration.load();
 connected=true;enabled=true;localUI=false;rawAllowed=true;rawFullEnabled=true;rawProbeSeconds=0;diagnosticCapture=false;
 mtFrame(nullptr,provisional,3,123.0,8);
 assert(rawSequence==beforeProvisionalSequence&&rawFramesSent==beforeProvisionalFrames&&inputGeneration==beforeProvisionalGeneration);
 rawAllowed=false;connected=false;enabled=false;
 uint8_t rawPacket[rawV2Max];
 assert(encodeRawV2(rawPacket,sizeof(rawPacket),42,1,uptimeNs(),123.0,8,provisional,3)==0);
 rawTouches[1].fingerID=7;assert(!provisionalDuplicateBegins(rawTouches,2));
 assert(encodeRawV2(rawPacket,sizeof(rawPacket),42,1,uptimeNs(),123.0,8,rawTouches,2)==0);rawTouches[1].fingerID=8;
 size_t rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,1,uptimeNs(),123.0,9,rawTouches,2);
 assert(rawLength==48+2*88);
 RawFrameV2 decodedRaw;assert(decodeRawV2(rawPacket,rawLength,decodedRaw));
 assert(decodedRaw.device==42&&decodedRaw.sequence==1&&decodedRaw.frameIndex==9&&decodedRaw.items.size()==2&&decodedRaw.items[7].x==.25f&&decodedRaw.items[7].vx==.4f&&decodedRaw.items[7].major==4);
 uint64_t contactRootTicks=mach_absolute_time();auto richEvent=modernContactEvent(decodedRaw.items,1,uptimeNs(),contactRootTicks,123.);
 assert(richEvent);auto richHID=hidTimestampAPI().copy(richEvent);assert(richHID&&hidTimestampAPI().sender(richHID)==localTouchDeviceID());
 mach_timebase_info_data_t contactTimebase={};mach_timebase_info(&contactTimebase);
 assert(contactTimebase.numer&&contactTimebase.denom);
 uint64_t fiveMsTicks=(uint64_t)(((__uint128_t)5000000*contactTimebase.denom)/contactTimebase.numer);
 uint64_t fingerTicks=0;
 assert(contactTicks(decodedRaw.items[7],123.,contactRootTicks,fingerTicks));
 assert(fingerTicks>=contactRootTicks+fiveMsTicks-2&&fingerTicks<=contactRootTicks+fiveMsTicks+2);
 assert(contactTicks(decodedRaw.items[8],123.,contactRootTicks,fingerTicks)&&fingerTicks==contactRootTicks);
 auto earlyContact=decodedRaw.items[7];earlyContact.touchTimestamp=122.995;
 assert(contactTicks(earlyContact,123.,contactRootTicks,fingerTicks));
 assert(fingerTicks>=contactRootTicks-fiveMsTicks-2&&fingerTicks<=contactRootTicks-fiveMsTicks+2);
 assert(!contactTicks(earlyContact,123.,1,fingerTicks));
 rawAllowed=true;rawFullEnabled=true;rawProbeSeconds=0;
 assert(contactOnlyCG29(richEvent)&&suppressNativeTrackpadEvent((CGEventType)29,richEvent));
 rawAllowed=false;assert(!suppressNativeTrackpadEvent((CGEventType)29,richEvent));
 auto richChildren=IOHIDEventGetChildren(richHID);assert(richChildren&&CFArrayGetCount(richChildren)==2);bool foundRich=false;
 for(CFIndex i=0;i<CFArrayGetCount(richChildren);i++){
  auto finger=(CFTypeRef)CFArrayGetValueAtIndex(richChildren,i);
  if(IOHIDEventGetIntegerValue(finger,kIOHIDEventFieldDigitizerIdentity)!=7)continue;
  foundRich=true;assert(IOHIDEventGetIntegerValue(finger,kIOHIDEventFieldDigitizerIndex)==7);
  assert(std::abs(IOHIDEventGetFloatValue(finger,kIOHIDEventFieldDigitizerPressure)-.5)<1e-5);
  assert(std::abs(IOHIDEventGetFloatValue(finger,kIOHIDEventFieldDigitizerDensity)-.7)<1e-5);
  assert(std::abs(IOHIDEventGetFloatValue(finger,kIOHIDEventFieldDigitizerMajorRadius)-4)<1e-5);
  assert(std::abs(IOHIDEventGetFloatValue(finger,kIOHIDEventFieldDigitizerMinorRadius)-2)<1e-5);
  assert(IOHIDEventGetTimeStamp(finger)>=contactRootTicks+fiveMsTicks-2&&IOHIDEventGetTimeStamp(finger)<=contactRootTicks+fiveMsTicks+2);
  auto velocity=IOHIDEventGetChildren(finger);assert(velocity&&CFArrayGetCount(velocity)==1);auto node=(CFTypeRef)CFArrayGetValueAtIndex(velocity,0);
  assert(IOHIDEventGetTimeStamp(node)==IOHIDEventGetTimeStamp(finger));
  assert(hidTimestampAPI().type(node)==kIOHIDEventTypeVelocity&&hidTimestampAPI().sender(node)==localTouchDeviceID());
  assert(std::abs(IOHIDEventGetFloatValue(node,kIOHIDEventFieldVelocityX)-.4)<1e-5&&std::abs(IOHIDEventGetFloatValue(node,kIOHIDEventFieldVelocityY)+.2)<1e-5);
 }
 assert(foundRich);CFRelease(richHID);CFRelease(richEvent);
 auto invalidTiming=decodedRaw.items;invalidTiming[7].touchTimestamp=125.;assert(!modernContactEvent(invalidTiming,1,uptimeNs(),contactRootTicks,123.));
 rawTouches[0].normalizedVector.velocity={0,0};rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,1,uptimeNs(),123.0,9,rawTouches,2);assert(rawLength==48+2*88);
 rawPacket[6]=1;assert(!decodeRawV2(rawPacket,rawLength,decodedRaw));rawPacket[6]=0;
 assert(!decodeRawV2(rawPacket,rawLength-1,decodedRaw));
 rawPacket[4]=1;assert(!decodeRawV2(rawPacket,rawLength,decodedRaw));rawPacket[4]=2;
 assert(air_host_input_begin(43,1)==0&&air_host_raw_supported()&&hostRawFull);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostContacts.size()==2);
 assert(posted.back().type==29&&posted.back().phase==1&&posted.back().touches==2);
 auto fullFirstTimestamp=posted.back().timestamp;posted.clear();
 size_t emptyLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,2,uptimeNs()+1000,124.0,10,nullptr,0);
 assert(emptyLength==48&&air_host_input_event(43,rawPacket,emptyLength)==0&&hostContacts.empty());
 assert(posted.size()==1&&posted.back().phase==4&&posted.back().timestamp>=fullFirstTimestamp);
 rawTouches[0].timestamp=rawTouches[1].timestamp=125.0;
 rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,3,hostLastSource+1000,125.0,11,rawTouches,2);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostContacts.size()==2);
 auto beforeStale=rawStaleRejected.load();auto beforeRelease=posted.size();hostLocalAnchor=uptimeNs()-500000000ULL;
 rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,4,hostLastSource+1000,126.0,12,rawTouches,2);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostContacts.empty()&&rawStaleRejected==beforeStale+1);
 assert(posted.size()==beforeRelease+1&&posted.back().phase==4&&posted.back().touches==2);
 assert(!hostSourceAnchor&&!hostLocalAnchor&&!hostLastSource&&!hostLastSequence&&!hostLastTargetNs);
 auto afterRelease=posted.size();
 rawTouches[0].timestamp=rawTouches[1].timestamp=127.0;
 rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,5,uptimeNs(),127.0,13,rawTouches,2);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostContacts.size()==2);
 assert(posted.size()==afterRelease+1&&posted.back().phase==1&&posted.back().touches==2);
 assert(hostLastSequence==5&&hostSourceAnchor&&hostLocalAnchor);
 emptyLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,6,hostLastSource+1000,128.0,14,nullptr,0);
 assert(emptyLength==48&&air_host_input_event(43,rawPacket,emptyLength)==0&&hostContacts.empty());
 assert(posted.size()==afterRelease+2&&posted.back().phase==4&&posted.back().touches==2);
 air_host_input_end(43);posted.clear();
 air_input_space_swipe_callback(observeSwipe);
 MTTouch swipeTouches[3]{};for(int i=0;i<3;i++){swipeTouches[i].fingerID=i+1;swipeTouches[i].state=3;swipeTouches[i].normalizedVector.position={.2f,.5f};}
 auto beginNotice=noteSwipe(42,100,1000000000ULL,swipeTouches,3);
 assert(beginNotice.phase==0&&swipePhases.size()==1&&swipePhases.back()==1);
 for(auto &touch:swipeTouches){touch.state=4;touch.normalizedVector.position.x=.5f;}
 auto moveNotice=noteSwipe(42,101,1200000000ULL,swipeTouches,3);assert(moveNotice.phase==0);
 swipeTouches[2].state=7;auto endNotice=noteSwipe(42,102,1250000000ULL,swipeTouches,3);
 assert(endNotice.phase==2&&endNotice.direction==1&&endNotice.callback);endNotice.callback(endNotice.phase,endNotice.direction,endNotice.generation);
 assert(swipePhases.size()==2&&swipePhases.back()==2&&swipeDirections.back()==1);
 for(auto &touch:swipeTouches){touch.state=3;touch.normalizedVector.position.x=.5f;}
 noteSwipe(42,103,1300000000ULL,swipeTouches,3);auto cancelNotice=noteSwipe(43,104,1350000000ULL,swipeTouches,3);
 assert(cancelNotice.phase==3&&cancelNotice.callback);cancelNotice.callback(cancelNotice.phase,cancelNotice.direction,cancelNotice.generation);
 assert(swipePhases.size()==4&&swipePhases.back()==3);
 noteSwipe(42,105,1400000000ULL,swipeTouches,3);
 for(auto &touch:swipeTouches){touch.state=4;touch.normalizedVector.position.x=.8f;}
 noteSwipe(42,106,1600000000ULL,swipeTouches,3);
 swipeTouches[0].fingerID=4;swipeTouches[0].state=7;
 auto replacement=noteSwipe(42,107,1650000000ULL,swipeTouches,3);
 assert(replacement.phase==3&&replacement.direction==0);air_input_space_swipe_callback(nullptr);
 assert(air_raw_full_configure(0)==0);
 assert(air_host_input_begin(43,1)==-1&&!air_host_raw_supported());
 assert(air_host_input_event(43,packet,sizeof(packet))==-1);
 assert(air_raw_probe_configure(61)==-1&&air_raw_probe_configure(3)==0);
 assert(!air_client_raw_supported()&&!air_host_raw_supported());
 auto rejectedDevices=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
 CFArrayAppendValue(rejectedDevices,CFSTR("test trackpad"));mtDeviceList=rejectedDevices;mtRegister=fixtureMTRegisterFail;mtUnregister=fixtureMTUnregister;mtDeviceID=fixtureMTID;
 assert(!registerMTDevices()&&!mtDeviceList&&mtID==0);
 auto fixtureDevices=CFArrayCreateMutable(kCFAllocatorDefault,0,&kCFTypeArrayCallBacks);
 CFArrayAppendValue(fixtureDevices,CFSTR("test trackpad"));
 clientInput=true;mtDeviceList=fixtureDevices;mtStart=fixtureMTStart;mtStop=fixtureMTStop;
 mtRegister=fixtureMTRegister;mtUnregister=fixtureMTUnregister;mtDeviceID=fixtureMTID;assert(registerMTDevices()&&mtID==1);
 mtStart=fixtureMTStartFail;assert(!startMT()&&!mtRunning);
 connected=true;enabled=true;assert(air_input_capture_mt(1)==-1&&!diagnosticCapture&&!mtRunning);
 mtStart=fixtureMTStart;assert(startMT()&&mtRunning);stopMT();assert(!mtRunning);
 air_input_connected(0);assert(air_client_raw_supported());
 air_input_connected(1);air_input_raw_enabled(1);
 uint64_t firstDeadline=clientRawDeadline.load();assert(firstDeadline>uptimeNs()&&clientRawActive());
 lastRawPacket.clear();mtFrame(nullptr,&diagnosticTouch,1,123.0,(size_t)UINT32_MAX+77);dispatch_sync(sendQueue,^{});
 RawFrameV2 produced;assert(decodeRawV2(lastRawPacket.data(),lastRawPacket.size(),produced)&&produced.frameIndex==(size_t)UINT32_MAX+77);
 for(auto &touch:swipeTouches){touch.state=3;touch.normalizedVector.position.x=.2f;}
 auto beforeRaw=rawFramesSent.load();lastRawPacket.clear();
 mtFrame(nullptr,swipeTouches,3,124.0,(size_t)UINT32_MAX+78);dispatch_sync(sendQueue,^{});
 assert(rawFramesSent==beforeRaw+1&&!swipe.active);
 produced=RawFrameV2{};
 assert(decodeRawV2(lastRawPacket.data(),lastRawPacket.size(),produced)&&produced.items.size()==3);
 uint64_t beforeUI=rawFramesSent.load();localUI=true;mtFrame(nullptr,&diagnosticTouch,1,123.0,1);assert(rawFramesSent==beforeUI);localUI=false;
 air_input_connected(1);air_input_raw_enabled(1);assert(clientRawDeadline==firstDeadline);
 air_input_connected(0);assert(!air_client_raw_supported()&&!clientRawActive());
 clientInput=false;mtDeviceList=nullptr;CFRelease(fixtureDevices);
 mtStart=nullptr;mtStop=nullptr;mtRegister=nullptr;mtUnregister=nullptr;mtDeviceID=nullptr;
 posted.clear();assert(air_host_input_begin(43,0)==0&&!air_host_raw_supported()&&!hostRawSpent);
 assert(air_host_input_event(43,packet,sizeof(packet))==-1);
 assert(air_host_input_begin(43,1)==0&&!air_host_raw_supported()&&!hostRawSpent);
 air_host_input_end(43);
 assert(air_host_input_begin(43,1)==0);
 assert(air_host_raw_supported());
 uint64_t hostDeadline=hostRawDeadline;
 assert(air_host_input_begin(43,1)==0&&hostRawDeadline==hostDeadline);
 rawTouches[0].timestamp=rawTouches[1].timestamp=123.0;
 rawLength=encodeRawV2(rawPacket,sizeof(rawPacket),42,1,uptimeNs(),123.0,9,rawTouches,2);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostContacts.size()==2);
 size_t activePosts=posted.size();hostRawDeadline=uptimeNs()-1;
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&hostRawExpired&&hostOwner==43&&hostContacts.empty()&&posted.size()==activePosts+1&&posted.back().phase==4);
 assert(air_host_input_event(43,rawPacket,rawLength)==0&&posted.size()==activePosts+1&&!air_host_raw_supported());
 assert(air_host_input_event(44,rawPacket,rawLength)==-1&&posted.size()==activePosts+1);
 rawPacket[5]=3;assert(air_host_input_event(43,rawPacket,rawLength)==-1&&posted.size()==activePosts+1);rawPacket[5]=2;
 auto afterExpiryKey=CGEventCreateKeyboardEvent(nullptr,12,true);auto afterExpiryData=CGEventCreateData(kCFAllocatorDefault,afterExpiryKey);
 assert(afterExpiryData&&air_host_input_event(43,CFDataGetBytePtr(afterExpiryData),CFDataGetLength(afterExpiryData))==0&&hostOwner==43);
 CFRelease(afterExpiryData);CFRelease(afterExpiryKey);
 air_host_input_end(43);assert(air_host_input_begin(44,1)==-1&&!air_host_raw_supported()&&!hostRawExpired);
 assert(air_host_input_event(44,rawPacket,rawLength)==-1);
 assert(air_host_input_begin(43,0)==0&&!air_host_raw_supported());
 posted.clear();hostKeys.insert(12);hostFlags=kCGEventFlagMaskCommand;
 hostMedia.insert(1);hostContacts[1]={1,4,.5f,.5f,.5f};hostTouchDevice=42;
 air_host_input_shutdown();
 assert(hostShutdown&&hostOwner==0&&hostKeys.empty()&&hostMedia.empty()&&hostContacts.empty()&&hostFlags==0);
 bool contactUp=false,mediaUp=false,keyUp=false,modifierUp=false;
 for(const auto &event:posted){
  contactUp|=event.type==29;mediaUp|=event.type==14;
  keyUp|=event.type==kCGEventKeyUp&&event.key==12;
  modifierUp|=event.type==kCGEventFlagsChanged&&event.flags==0;
 }
 assert(contactUp&&mediaUp&&keyUp&&modifierUp);
 size_t released=posted.size();air_host_input_shutdown();air_host_input_release(43);air_host_input_end(43);
 assert(posted.size()==released&&air_host_input_begin(43,1)==-1&&air_host_input_event(43,packet,sizeof(packet))==-1);
 fixtureApp=(NSApplication *)[FixtureActiveApp new];connected=true;enabled=true;clientInput=true;localUI=true;rawAllowed=false;
 sent.clear();auto chooserKey=CGEventCreateKeyboardEvent(nullptr,49,true);assert(chooserKey);
 CGEventSetFlags(chooserKey,kCGEventFlagMaskCommand);
 assert(!tapEvent(nullptr,kCGEventKeyDown,chooserKey,nullptr));dispatch_sync(sendQueue,^{});
 assert(sent.size()==1);CFRelease(chooserKey);
 NSEvent *chooserMedia=[NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:10 timestamp:0 windowNumber:0 context:nil subtype:8 data1:(0<<16)|(10<<8) data2:-1];
 assert(chooserMedia.CGEvent&&!tapEvent(nullptr,(CGEventType)14,chooserMedia.CGEvent,nullptr));dispatch_sync(sendQueue,^{});
 assert(sent.size()==2);
 auto chooserWheel=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitPixel,1,5);assert(chooserWheel);
 assert(tapEvent(nullptr,kCGEventScrollWheel,chooserWheel,nullptr)==chooserWheel);dispatch_sync(sendQueue,^{});
 assert(sent.size()==2);CFRelease(chooserWheel);
 localUI=false;rawAllowed=true;rawFullEnabled=true;rawProbeSeconds=0;sent.clear();lastNativePacket.clear();
 size_t dockCount=0;
 for(int phase:{1,2,4}){
  auto dock=CGEventCreate(nullptr);assert(dock);CGEventSetType(dock,(CGEventType)30);
  CGEventSetIntegerValueField(dock,(CGEventField)110,23);
  CGEventSetIntegerValueField(dock,(CGEventField)123,1);
  CGEventSetIntegerValueField(dock,(CGEventField)132,phase);
  assert(!tapEvent(nullptr,(CGEventType)30,dock,nullptr));dispatch_sync(sendQueue,^{});
  assert(sent.size()==++dockCount&&!lastNativePacket.empty());
  auto data=CFDataCreate(kCFAllocatorDefault,lastNativePacket.data(),lastNativePacket.size());assert(data);
  auto decoded=CGEventCreateFromData(kCFAllocatorDefault,data);CFRelease(data);
  assert(decoded&&CGEventGetType(decoded)==30&&CGEventGetIntegerValueField(decoded,(CGEventField)110)==23
         &&CGEventGetIntegerValueField(decoded,(CGEventField)132)==phase);
  CFRelease(decoded);CFRelease(dock);
 }
 rawAllowed=false;
 // Display brightness belongs to the Air even while the remote grab is active.
 // Exercise the production tap callback, including release, repeat, and the
 // Option-Shift fine-adjustment form. Other media and F1/F2 still go remote.
 sent.clear();lastNativePacket.clear();localUI=false;enabled=true;connected=true;
 auto brightnessEvent=[&](int key,int edge,bool repeat,NSEventModifierFlags flags){
  int data1=(key<<16)|(edge<<8)|(repeat?1:0);
  NSEvent *native=[NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint
      modifierFlags:flags timestamp:0 windowNumber:0 context:nil
      subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS data1:data1 data2:-1];
  assert(native&&native.CGEvent&&native.subtype==NX_SUBTYPE_AUX_CONTROL_BUTTONS);
  return (CGEventRef)CFRetain(native.CGEvent);
 };
 auto beforeBrightness=forwarded.load();
 for(int key:{NX_KEYTYPE_BRIGHTNESS_UP,NX_KEYTYPE_BRIGHTNESS_DOWN}){
  for(auto edge:{0xA,0xB}){
   auto event=brightnessEvent(key,edge,false,0);
   assert(tapEvent(nullptr,(CGEventType)NX_SYSDEFINED,event,nullptr)==event);
   CFRelease(event);
  }
  NSEventModifierFlags fine=NSEventModifierFlagOption|NSEventModifierFlagShift;
  for(auto edge:{0xA,0xB}){
   auto event=brightnessEvent(key,edge,false,fine);
   assert((CGEventGetFlags(event)&(kCGEventFlagMaskAlternate|kCGEventFlagMaskShift))
      ==(kCGEventFlagMaskAlternate|kCGEventFlagMaskShift));
   assert(tapEvent(nullptr,(CGEventType)NX_SYSDEFINED,event,nullptr)==event);
   CFRelease(event);
  }
  auto repeated=brightnessEvent(key,0xA,true,fine);
  assert(tapEvent(nullptr,(CGEventType)NX_SYSDEFINED,repeated,nullptr)==repeated);
  CFRelease(repeated);
 }
 dispatch_sync(sendQueue,^{});
 assert(sent.empty()&&forwarded==beforeBrightness&&lastNativePacket.empty());
 auto volume=brightnessEvent(NX_KEYTYPE_SOUND_UP,0xA,false,0);
 assert(!tapEvent(nullptr,(CGEventType)NX_SYSDEFINED,volume,nullptr));dispatch_sync(sendQueue,^{});
 CFRelease(volume);
 assert(sent.size()==1&&!lastNativePacket.empty());
 for(CGKeyCode functionKey:{(CGKeyCode)122,(CGKeyCode)120}){
  for(bool down:{true,false}){
   auto event=CGEventCreateKeyboardEvent(nullptr,functionKey,down);assert(event);
   assert(!tapEvent(nullptr,down?kCGEventKeyDown:kCGEventKeyUp,event,nullptr));
   CFRelease(event);
  }
 }
 dispatch_sync(sendQueue,^{});
 assert(sent.size()==5&&forwarded==beforeBrightness+5);
 for(CGKeyCode keycode:{(CGKeyCode)63,(CGKeyCode)179}){
  auto event=CGEventCreateKeyboardEvent(nullptr,keycode,true);assert(event);
  if(keycode==63){CGEventSetType(event,kCGEventFlagsChanged);CGEventSetFlags(event,kCGEventFlagMaskSecondaryFn);}
  assert(!tapEvent(nullptr,CGEventGetType(event),event,nullptr));
  dispatch_sync(sendQueue,^{});
  auto packet=CFDataCreate(kCFAllocatorDefault,lastNativePacket.data(),lastNativePacket.size());assert(packet);
  auto decoded=CGEventCreateFromData(kCFAllocatorDefault,packet);assert(decoded);
  assert(CGEventGetIntegerValueField(decoded,kCGKeyboardEventKeycode)==keycode);
  CFRelease(decoded);CFRelease(packet);CFRelease(event);
 }
 localUI=false;sendNative=nullptr;auto failedShortcut=CGEventCreateKeyboardEvent(nullptr,49,true);assert(failedShortcut);
 CGEventSetFlags(failedShortcut,kCGEventFlagMaskCommand);
 assert(!tapEvent(nullptr,kCGEventKeyDown,failedShortcut,nullptr)&&!enabled);
 CFRelease(failedShortcut);dispatch_sync(sendQueue,^{});
 sendNative=onPacket;enabled=true;localUI=true;auto escapeKey=CGEventCreateKeyboardEvent(nullptr,53,true);assert(escapeKey);
 CGEventSetFlags(escapeKey,kCGEventFlagMaskControl|kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand);
 auto previousEscapes=escapes.load();assert(!tapEvent(nullptr,kCGEventKeyDown,escapeKey,nullptr)&&!enabled&&escapes==previousEscapes+1);
 CFRelease(escapeKey);dispatch_sync(sendQueue,^{});fixtureApp=nil;
 puts("input packet validation passed");return 0;
}
