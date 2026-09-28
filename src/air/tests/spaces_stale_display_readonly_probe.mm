// Live read-only regression: requires an existing stale-display surface.
// No windows, desktop selection, or display settings are mutated.
#include "../spaces.mm"
#include <cassert>
extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(){return 0;}
int main(){ @autoreleasepool {
 Api &a=api();int cid=a.conn();unsigned stale=0,retained=0,visibleRejected=0;
 for(NSDictionary *info in completeWindowInventory(managed(),cid)) {
  if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
  uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
  pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
  NSString *owner=CFBridgingRelease(a.windowDisplay(cid,wid));
  uint64_t sid=oneWindowSpace(wid,cid);
  if(!sid || !owner.length || spaceOnDisplay(managed(),sid,owner.UTF8String))continue;
  NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if(systemChrome(app.bundleIdentifier))continue;
  CGRect frame={};CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary(info[(id)kCGWindowBounds]),&frame);
  DeferredInvisibleWindow deferred;
  bool accepted=deferredStaleDisplaySurface(info,wid,pid,app.bundleIdentifier,frame,sid,cid,&deferred);
  stale++;retained+=accepted;
  NSMutableDictionary *visible=[info mutableCopy];visible[(id)kCGWindowIsOnscreen]=@YES;
  bool rejected=!deferredStaleDisplaySurface(visible,wid,pid,app.bundleIdentifier,frame,sid,cid,nullptr);
  visibleRejected+=rejected;assert(rejected);
  printf("wid=%u stale=1 retained=%d visible_rejected=%d\n",wid,accepted,rejected);
 }
 printf("stale=%u retained=%u visible_rejected=%u mutations=0\n",stale,retained,visibleRejected);
 return stale && stale==retained ? 0:1;
}}
