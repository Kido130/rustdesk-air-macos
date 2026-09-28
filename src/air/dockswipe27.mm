#include "dockswipe27.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <cmath>

namespace {
// ABI/constants independently transcribed from Apple SkyLight.tbd and Apple's
// APSL IOHIDFamily IOHIDEventTypes/IOHIDEventFieldDefs. Behavioral reference:
// noah-nuebling/mac-mouse-fix commit f92d2d53a. No implementation copied.
using HID=CFTypeRef;
constexpr uint32_t TypeVelocity=9,TypeDockSwipe=23;
constexpr uint32_t PhaseBegan=1,PhaseChanged=2,PhaseEnded=4,PhaseCancelled=8;
constexpr uint32_t FieldVelocityX=(TypeVelocity<<16)|0;
constexpr uint32_t FieldVelocityY=(TypeVelocity<<16)|1;
constexpr uint32_t FieldVelocityZ=(TypeVelocity<<16)|2;
constexpr uint32_t FieldMotion=(TypeDockSwipe<<16)|1;
constexpr uint32_t FieldProgress=(TypeDockSwipe<<16)|2;
constexpr uint32_t FieldFlavor=(TypeDockSwipe<<16)|5;
constexpr uint32_t FlavorDockPrimary=3,PhaseShift=24;
AirDockSwipe27Fields active{};bool activeValid=false;
struct API {
 HID(*create)(CFAllocatorRef,uint32_t,uint64_t,uint32_t)=nullptr;
 void(*setInteger)(HID,uint32_t,CFIndex)=nullptr;
 void(*setFloat)(HID,uint32_t,double)=nullptr;
 void(*append)(HID,HID,uint32_t)=nullptr;
 void(*attach)(CGEventRef,HID)=nullptr;
 bool ready()const{return create&&setInteger&&setFloat&&append&&attach;}
};
const API &api(){static API a=[] {API x;
 void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY|RTLD_LOCAL);
 void *sl=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
 if(io){x.create=(decltype(x.create))dlsym(io,"IOHIDEventCreate");x.setInteger=(decltype(x.setInteger))dlsym(io,"IOHIDEventSetIntegerValue");x.setFloat=(decltype(x.setFloat))dlsym(io,"IOHIDEventSetFloatValue");x.append=(decltype(x.append))dlsym(io,"IOHIDEventAppendEvent");}
 if(sl)x.attach=(decltype(x.attach))dlsym(sl,"SLEventSetIOHIDEvent");return x;}();return a;}
bool phaseOK(uint32_t p){return p==PhaseBegan||p==PhaseChanged||p==PhaseEnded||p==PhaseCancelled;}
}

bool air_dockswipe27_decode(CGEventRef source,AirDockSwipe27Fields *out){
 if(!source||!out||CGEventGetType(source)!=30)return false;
 int64_t subtype=CGEventGetIntegerValueField(source,(CGEventField)110);
 int64_t phase=CGEventGetIntegerValueField(source,(CGEventField)132);
 int64_t motion=CGEventGetIntegerValueField(source,(CGEventField)123);
 double progress=CGEventGetDoubleValueField(source,(CGEventField)124);
 double vx=CGEventGetDoubleValueField(source,(CGEventField)129);
 double vy=CGEventGetDoubleValueField(source,(CGEventField)130);
 if(subtype!=TypeDockSwipe||phase<0||phase>UINT32_MAX||!phaseOK((uint32_t)phase)
    ||motion<1||motion>3||!std::isfinite(progress)||fabs(progress)>16
    ||!std::isfinite(vx)||!std::isfinite(vy))return false;
 if(motion==3 && fabs(vx-vy)>1e-6)return false;
 out->phase=(uint32_t)phase;out->motion=(uint32_t)motion;out->progress=progress;
 out->velocity=motion==2?vy:vx;return true;
}

bool air_dockswipe27_available(){
 if(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<27)return false;
 return api().ready();
}

CGEventRef air_dockswipe27_convert(CGEventRef source,uint64_t timestamp){
 AirDockSwipe27Fields f;if(!air_dockswipe27_available()||!air_dockswipe27_decode(source,&f))return nullptr;
 if((f.phase==PhaseBegan && activeValid)
    ||(f.phase!=PhaseBegan && (!activeValid||active.motion!=f.motion)))return nullptr;
 const API &a=api();uint64_t ts=timestamp?timestamp:mach_absolute_time();
 HID dock=a.create(kCFAllocatorDefault,TypeDockSwipe,ts,f.phase<<PhaseShift);if(!dock)return nullptr;
 a.setInteger(dock,FieldMotion,f.motion);a.setInteger(dock,FieldFlavor,FlavorDockPrimary);a.setFloat(dock,FieldProgress,f.progress);
 if(f.phase==PhaseEnded||f.phase==PhaseCancelled){HID velocity=a.create(kCFAllocatorDefault,TypeVelocity,ts,0);if(!velocity){CFRelease(dock);return nullptr;}
  a.setFloat(velocity,FieldVelocityX,f.velocity);a.setFloat(velocity,FieldVelocityY,f.velocity);a.setFloat(velocity,FieldVelocityZ,0);a.append(dock,velocity,0);CFRelease(velocity);}
 CGEventRef result=CGEventCreate(nullptr);if(result){CGEventSetType(result,(CGEventType)30);CGEventSetTimestamp(result,CGEventGetTimestamp(source));CGEventSetFlags(result,CGEventGetFlags(source));a.attach(result,dock);}
 CFRelease(dock);
 if(result){if(f.phase==PhaseBegan||f.phase==PhaseChanged){active=f;activeValid=true;}else activeValid=false;}
 return result;
}

CGEventRef air_dockswipe27_cancel(uint64_t timestamp){
 if(!activeValid)return nullptr;
 CGEventRef source=CGEventCreate(nullptr);if(!source)return nullptr;
 CGEventSetType(source,(CGEventType)30);CGEventSetIntegerValueField(source,(CGEventField)110,TypeDockSwipe);
 CGEventSetIntegerValueField(source,(CGEventField)132,PhaseCancelled);CGEventSetIntegerValueField(source,(CGEventField)123,active.motion);
 CGEventSetDoubleValueField(source,(CGEventField)124,active.progress);CGEventSetDoubleValueField(source,(CGEventField)129,0);
 CGEventRef result=air_dockswipe27_convert(source,timestamp);CFRelease(source);return result;
}
