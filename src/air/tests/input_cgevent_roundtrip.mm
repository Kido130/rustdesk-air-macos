#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cassert>

static CGEventRef roundtrip(CGEventRef event){
 auto bytes=CGEventCreateData(kCFAllocatorDefault,event);
 auto result=bytes?CGEventCreateFromData(kCFAllocatorDefault,bytes):nullptr;
 if(bytes)CFRelease(bytes);
 return result;
}

int main(){
 @autoreleasepool {
  auto key=CGEventCreateKeyboardEvent(nullptr,12,true);assert(key);
  CGEventSetFlags(key,kCGEventFlagMaskCommand);
  auto decoded=roundtrip(key);assert(decoded);
  assert(CGEventGetType(decoded)==kCGEventKeyDown);
  assert(CGEventGetIntegerValueField(decoded,kCGKeyboardEventKeycode)==12);
  assert(CGEventGetFlags(decoded)&kCGEventFlagMaskCommand);
  CFRelease(decoded);CFRelease(key);

  auto scroll=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitPixel,2,100,50);assert(scroll);
  CGEventSetIntegerValueField(scroll,kCGScrollWheelEventScrollPhase,1);
  decoded=roundtrip(scroll);assert(decoded);
  assert(CGEventGetType(decoded)==kCGEventScrollWheel);
  assert(CGEventGetIntegerValueField(decoded,kCGScrollWheelEventPointDeltaAxis1)==100);
  assert(CGEventGetIntegerValueField(decoded,kCGScrollWheelEventScrollPhase)==1);
  CFRelease(decoded);CFRelease(scroll);

  NSEvent *media=[NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:10 timestamp:0 windowNumber:0 context:nil subtype:8 data1:(0<<16)|(10<<8) data2:-1];
  assert(media.CGEvent);decoded=roundtrip(media.CGEvent);assert(decoded);
  NSEvent *decodedMedia=[NSEvent eventWithCGEvent:decoded];
  assert(CGEventGetType(decoded)==14&&decodedMedia.subtype==8&&decodedMedia.data1==media.data1);
  CFRelease(decoded);
  puts("keyboard, scroll phase, and media event data roundtrips passed");return 0;
 }
}
