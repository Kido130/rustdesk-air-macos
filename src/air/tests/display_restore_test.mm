// Isolated Core Graphics fixture: never calls real display configuration APIs.
#import <AppKit/AppKit.h>
#include "../native.h"
#include <cassert>
#include <cstring>
#include <string>

#define CGDisplayModeGetWidth fakeModeWidth
#define CGDisplayModeGetHeight fakeModeHeight
#define CGDisplayModeGetPixelWidth fakeModePixelWidth
#define CGDisplayModeGetPixelHeight fakeModePixelHeight
#define CGDisplayModeGetIODisplayModeID fakeModeID
#define CGDisplayModeGetRefreshRate fakeModeRefresh
#define CGDisplayModeIsUsableForDesktopGUI fakeModeUsable
#define CGDisplayModeRetain fakeModeRetain
#define CGDisplayModeRelease fakeModeRelease
#define CGDisplayCopyDisplayMode fakeCopyMode
#define CGDisplayCopyAllDisplayModes fakeAllModes
#define CGDisplayCreateUUIDFromDisplayID fakeUUID
#define CGGetOnlineDisplayList fakeOnline
#define CGDisplayBounds fakeBounds
#define CGDisplayIsBuiltin fakeBuiltin
#define CGDisplayIsInMirrorSet fakeMirror
#define CGDisplayRegisterReconfigurationCallback fakeRegister
#define CGBeginDisplayConfiguration fakeBegin
#define CGConfigureDisplayWithDisplayMode fakeConfigureMode
#define CGConfigureDisplayOrigin fakeConfigureOrigin
#define CGCancelDisplayConfiguration fakeCancel
#define CGCompleteDisplayConfiguration fakeComplete

struct FakeMode { size_t w,h,pw,ph; int32_t id; };
static FakeMode original{1000,700,2000,1400,10};
static FakeMode applied{1200,800,2400,1600,11};
static FakeMode thirdParty{1100,750,2200,1500,12};
static FakeMode nearScale{1180,786,2400,1600,13};
static FakeMode skewedScale{1100,900,2400,1600,14};
static FakeMode *currentMode=&original, *stagedMode=nullptr;
static bool builtinOnline=true, failComplete=false, mismatchAfterComplete=false;
static bool externalOnline=true, extraOnline=false;
static int configureCount=0, completeCount=0, errorCount=0;
static int builtInOriginCalls=0, externalOriginCalls=0;
static CGFloat builtInX=0, externalX=-1920, stagedBuiltInX=0, stagedExternalX=-1920;
static CGFloat extraX=4000, stagedExtraX=4000;
static CGDirectDisplayID builtinID=1;
static std::string lastError;
static CGDisplayReconfigurationCallBack registeredCallback=nullptr;

static FakeMode *fake(CGDisplayModeRef mode) { return reinterpret_cast<FakeMode *>(mode); }
static size_t fakeModeWidth(CGDisplayModeRef m) { return fake(m)->w; }
static size_t fakeModeHeight(CGDisplayModeRef m) { return fake(m)->h; }
static size_t fakeModePixelWidth(CGDisplayModeRef m) { return fake(m)->pw; }
static size_t fakeModePixelHeight(CGDisplayModeRef m) { return fake(m)->ph; }
static int32_t fakeModeID(CGDisplayModeRef m) { return fake(m)->id; }
static double fakeModeRefresh(CGDisplayModeRef) { return 60; }
static bool fakeModeUsable(CGDisplayModeRef) { return true; }
static CGDisplayModeRef fakeModeRetain(CGDisplayModeRef m) { return m; }
static void fakeModeRelease(CGDisplayModeRef) {}
static CGDisplayModeRef fakeCopyMode(CGDirectDisplayID id) {
    return builtinOnline && id==builtinID ? reinterpret_cast<CGDisplayModeRef>(currentMode) : nullptr;
}
static CFArrayRef fakeAllModes(CGDirectDisplayID,CFDictionaryRef) {
    const void *values[]={&original,&applied,&thirdParty,&nearScale,&skewedScale};
    return CFArrayCreate(kCFAllocatorDefault,values,5,nullptr);
}
static CFUUIDRef fakeUUID(CGDirectDisplayID id) {
    auto value=CFSTR("00000000-0000-0000-0000-000000000001");
    if (id==2) value=CFSTR("00000000-0000-0000-0000-000000000002");
    if (id==4) value=CFSTR("00000000-0000-0000-0000-000000000004");
    return CFUUIDCreateFromString(kCFAllocatorDefault,value);
}
static CGError fakeOnline(uint32_t max,CGDirectDisplayID *ids,uint32_t *count) {
    *count=unsigned(builtinOnline)+unsigned(externalOnline)+unsigned(extraOnline);
    if (max<*count) return kCGErrorFailure;
    unsigned index=0;
    if (builtinOnline) ids[index++]=builtinID;
    if (externalOnline) ids[index++]=2;
    if (extraOnline) ids[index++]=4;
    return kCGErrorSuccess;
}
static CGRect fakeBounds(CGDirectDisplayID id) {
    return CGRectMake(id==2 ? externalX : id==4 ? extraX : builtInX,0,1920,1080);
}
static bool fakeBuiltin(CGDirectDisplayID id) { return builtinOnline && id==builtinID; }
static bool fakeMirror(CGDirectDisplayID) { return false; }
static CGError fakeRegister(CGDisplayReconfigurationCallBack callback,void *) {
    registeredCallback=callback;
    return kCGErrorSuccess;
}
static CGError fakeBegin(CGDisplayConfigRef *config) {
    *config=reinterpret_cast<CGDisplayConfigRef>(0x1234);
    stagedMode=nullptr; stagedBuiltInX=builtInX; stagedExternalX=externalX;
    stagedExtraX=extraX;
    return kCGErrorSuccess;
}
static CGError fakeConfigureMode(CGDisplayConfigRef,CGDirectDisplayID id,CGDisplayModeRef mode,CFDictionaryRef) {
    ++configureCount;
    if (!builtinOnline || id!=builtinID) return kCGErrorFailure;
    stagedMode=fake(mode);
    return kCGErrorSuccess;
}
static CGError fakeConfigureOrigin(CGDisplayConfigRef,CGDirectDisplayID id,int32_t x,int32_t) {
    if (id==2) { stagedExternalX=x; ++externalOriginCalls; }
    else if (id==4) stagedExtraX=x;
    else if (id==builtinID) { stagedBuiltInX=x; ++builtInOriginCalls; }
    else return kCGErrorFailure;
    return kCGErrorSuccess;
}
static CGError fakeCancel(CGDisplayConfigRef) { return kCGErrorSuccess; }
static CGError fakeComplete(CGDisplayConfigRef,CGConfigureOption) {
    ++completeCount;
    if (failComplete) { failComplete=false; return kCGErrorFailure; }
    if (stagedMode) currentMode=stagedMode;
    builtInX=stagedBuiltInX; externalX=stagedExternalX;
    extraX=stagedExtraX;
    if (mismatchAfterComplete) { externalX=-1800; mismatchAfterComplete=false; }
    return kCGErrorSuccess;
}

#include "../display.mm"

extern "C" uint32_t air_builtin_display() { return builtinOnline ? builtinID : 0; }
extern "C" void air_set_error(const char *message) { lastError=message; ++errorCount; }

int main() {
    AirDisplaySpec fallback{1175,783,2400,1600};
    assert(air_display_match(&fallback)==0);
    assert(currentMode==&nearScale && savedMode && appliedKey.ioMode==nearScale.id);
    assert(air_display_restore()==0 && currentMode==&original && !savedMode);
    const int beforeUnsupported=configureCount;
    AirDisplaySpec wrongRaster{1175,783,2401,1600};
    AirDisplaySpec distantScale{700,500,2400,1600};
    AirDisplaySpec skewedTarget{1000,800,2400,1600};
    assert(air_display_match(&wrongRaster)!=0);
    assert(air_display_match(&distantScale)!=0);
    assert(air_display_match(&skewedTarget)!=0);
    assert(configureCount==beforeUnsupported && !savedMode);
    currentMode=&nearScale;
    assert(air_display_match(&fallback)==0 && !savedMode && configureCount==beforeUnsupported);
    currentMode=&original;
    AirDisplaySpec target{1200,800,2400,1600};
    assert(air_display_match(&target)==0);
    assert(currentMode==&applied && savedMode && !restorePending);
    assert(registeredCallback);
    const int afterMatch=configureCount;
    processDisplayChangedLocked(); // Air's own mode callback has unchanged UUID topology.
    assert(configureCount==afterMatch && !restorePending);
    builtInX=80; externalX=-1800; // Simulate a layout reflow while the built-in display disappears.

    builtinOnline=false;
    processDisplayChangedLocked();
    assert(air_display_restore()!=0);
    assert(savedMode && restorePending && !retryBurstArmed);
    assert(savedOrigins.size()==2 && savedOrigins[0].x==0 && savedOrigins[1].x==-1920);
    assert(configureCount==afterMatch);
    assert(air_display_match(&target)!=0);

    builtinOnline=true; builtinID=3; failComplete=true;
    processDisplayChangedLocked(); // Fresh numeric ID, same UUID, first restore fails.
    assert(savedMode && restorePending && currentMode==&applied);
    assert(retryBurstArmed);
    const auto generation=displayGeneration, burst=retryBurst;
    const int failedCount=configureCount;
    processDisplayChangedLocked(); // Own callback cannot create a second burst.
    assert(configureCount==failedCount && retryBurst==burst);

    currentMode=&thirdParty;
    retryStepLocked(generation,burst,1);
    assert(savedMode && restorePending && currentMode==&thirdParty);
    assert(configureCount==failedCount); // Never overwrite another mode.

    currentMode=&applied;
    mismatchAfterComplete=true;
    retryStepLocked(generation,burst,2);
    assert(savedMode && restorePending && currentMode==&original);
    assert(externalX==-1800 && builtInX==0);
    assert(savedOrigins.size()==2 && savedOrigins[0].x==0 && savedOrigins[1].x==-1920);
    assert(displayGeneration==generation); // A successful CG return cannot clear a mismatched snapshot.
    assert(air_display_restore()==0);
    assert(!savedMode && !restorePending && currentMode==&original);
    assert(builtInX==0 && externalX==-1920);
    assert(builtInOriginCalls>=2 && externalOriginCalls>=2);
    assert(displayGeneration!=generation);
    const int restoredCount=configureCount;
    assert(air_display_match(&target)==0); // New session may start only after verification.
    retryStepLocked(generation,burst,1); // Old timer cannot restore the new session.
    assert(configureCount==restoredCount+1 && currentMode==&applied);
    failComplete=true;
    assert(air_display_restore()!=0 && savedMode && retryBurstArmed);
    const auto secondGeneration=displayGeneration, secondBurst=retryBurst;
    failComplete=true;
    retryStepLocked(secondGeneration,secondBurst,1);
    assert(savedMode && retryBurstArmed);
    failComplete=true;
    retryStepLocked(secondGeneration,secondBurst,2);
    assert(savedMode && !retryBurstArmed); // The burst stops after three attempts.
    assert(air_display_restore()==0 && currentMode==&original);
    assert(air_display_match(&target)==0);
    externalOnline=false; extraOnline=true; builtInX=64; extraX=2500;
    const int priorExternalCalls=externalOriginCalls;
    assert(air_display_restore()!=0 && savedMode && restorePending);
    assert(currentMode==&original && builtInX==64 && extraX==2500);
    assert(externalOriginCalls==priorExternalCalls);
    assert(savedOrigins.size()==2 && savedOrigins[0].x==0 && savedOrigins[1].x==-1920);
    const int partialRestoreCount=configureCount;
    assert(air_display_restore()!=0 && configureCount==partialRestoreCount);
    assert(air_display_match(&target)!=0);
    externalOnline=true; extraOnline=false; builtInX=32; externalX=-1500;
    processDisplayChangedLocked();
    assert(!savedMode && currentMode==&original && builtInX==0 && externalX==-1920);
    assert(air_display_match(&target)==0);
    builtinOnline=false;
    assert(air_display_shutdown()!=0 && savedMode && displayShuttingDown);
    const int shutdownCount=configureCount;
    builtinOnline=true;
    assert(air_display_match(&target)!=0 && configureCount==shutdownCount);
    assert(air_display_restore()==0 && currentMode==&original);
    assert(air_display_match(&target)!=0 && !savedMode);
    assert(air_display_shutdown()==0);
    return 0;
}
