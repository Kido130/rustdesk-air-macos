// Tests receiver attribution and JSON fields without a window or event posting.
#define main receiver_window_main
#include "live_receiver_window.mm"
#undef main
#include <cassert>
#include <cfloat>

int main(){
 @autoreleasepool {
  auto cg=CGEventCreate(nullptr);assert(cg);
  CGEventSetType(cg,(CGEventType)29);
  CGEventSetIntegerValueField(cg,kCGEventSourceUserData,remoteInputTag);
  NSEvent *tagged=[NSEvent eventWithCGEvent:cg];assert(tagged&&remoteEvent(tagged));
  noteTouchCallback(tagged,metrics.began,metrics.remoteBegan);
  assert(metrics.began==1&&metrics.remoteBegan==1);
  auto localCG=CGEventCreate(nullptr);assert(localCG);
  CGEventSetType(localCG,(CGEventType)29);
  NSEvent *local=[NSEvent eventWithCGEvent:localCG];assert(local&&!remoteEvent(local));
  noteTouchCallback(local,metrics.moved,metrics.remoteMoved);
  assert(metrics.moved==1&&metrics.remoteMoved==0);
  CFRelease(cg);
  CFRelease(localCG);
  double movement=0;
  assert(addFinite(movement,.25)&&addFinite(movement,.25)&&movement==.5);
  double nearLimit=DBL_MAX;assert(!addFinite(nearLimit,DBL_MAX)&&std::isfinite(nearLimit));
  metrics.remoteMagnificationAbs=movement;
  metrics.remoteScrollTravel=6;
  NSString *path=[NSString stringWithFormat:@"/tmp/air_receiver_metrics_%d.json",getpid()];
  unlink(path.fileSystemRepresentation);
  assert(saveJSON(path.fileSystemRepresentation,@"offline",1.0));
  NSData *data=[NSData dataWithContentsOfFile:path];assert(data);
  NSDictionary *report=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];assert(report);
  assert([report[@"touch_callbacks"][@"air_tagged_began"] unsignedIntValue]==1);
  assert([report[@"touch_callbacks"][@"air_tagged_moved"] unsignedIntValue]==0);
  assert([report[@"magnify"][@"air_tagged_absolute_movement"] doubleValue]==.5);
  assert([report[@"scroll_callbacks"][@"air_tagged_absolute_travel"] doubleValue]==6);
  unlink(path.fileSystemRepresentation);
 }
 puts("receiver metric attribution passed");
}
