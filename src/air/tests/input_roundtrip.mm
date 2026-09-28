#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
extern "C" {
#include "../TouchEvents.h"
}

int main() {
 @autoreleasepool {
  NSArray *touches=@[
   @{@"type":@11,@"transducerType":@2,@"identity":@1,@"transducerIndex":@1,@"options":@(0x30000),@"eventMask":@7,@"position.x":@0.25,@"position.y":@0.5,@"tipPressure":@0.5},
   @{@"type":@11,@"transducerType":@2,@"identity":@2,@"transducerIndex":@2,@"options":@(0x30000),@"eventMask":@7,@"position.x":@0.75,@"position.y":@0.5,@"tipPressure":@0.5}
  ];
  auto gesture=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)@{@"deviceID":@0,@"gestureSubtype":@11,@"gesturePhase":@1},(__bridge CFArrayRef)touches);
  if(!gesture){fprintf(stderr,"synthesis failed\n");return 1;}
  auto bytes=CGEventCreateData(kCFAllocatorDefault,gesture);
  auto copy=bytes?CGEventCreateFromData(kCFAllocatorDefault,bytes):nullptr;
  NSUInteger observed=0,original=0;
  @try{original=[NSEvent eventWithCGEvent:gesture].allTouches.count;}@catch(NSException*){}
  if(copy){@try{NSEvent *event=[NSEvent eventWithCGEvent:copy];observed=event.allTouches.count;}@catch(NSException*){}}
  fprintf(stdout,"type=%u bytes=%ld decoded=%u touches=%lu original=%lu\n",(unsigned)CGEventGetType(gesture),bytes?(long)CFDataGetLength(bytes):0,copy?(unsigned)CGEventGetType(copy):0,(unsigned long)observed,(unsigned long)original);
  if(copy)CFRelease(copy);if(bytes)CFRelease(bytes);CFRelease(gesture);
  return observed==2?0:2;
 }
}
