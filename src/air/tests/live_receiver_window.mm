#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <cmath>
#include <fcntl.h>
#include <map>
#include <unistd.h>

static constexpr int64_t remoteInputTag=0x5244414952;
struct ReceiverMetrics {
 unsigned gesture=0,magnify=0,scroll=0,maxTouches=0,touchReadErrors=0;
 unsigned remoteGesture=0,otherGesture=0,remoteMagnify=0,remoteScroll=0;
 unsigned remoteNonzeroSubtype=0,remoteNonzeroCGPhase=0;
 unsigned began=0,moved=0,ended=0,cancelled=0,touchSamples=0;
 unsigned remoteBegan=0,remoteMoved=0,remoteEnded=0,remoteCancelled=0,remoteTouchSamples=0;
 unsigned documentMagnify=0,scrollViewMagnify=0,documentScroll=0,scrollViewScroll=0;
 double magnificationSum=0,magnificationMin=0,magnificationMax=0,scrollX=0,scrollY=0;
 double remoteMagnificationAbs=0,remoteScrollTravel=0;
 unsigned validMagnification=0,invalidMagnification=0,invalidScroll=0;
 std::map<unsigned,unsigned> eventPhases,touchPhases;
};
static ReceiverMetrics metrics;
static NSTextField *feedbackLabel;
struct FocusMetrics {
 bool initialized=false,initiallyActive=false,active=false;
 unsigned losses=0,regains=0;
 double lastElapsed=0,activeSeconds=0,firstLoss=-1,lastRegain=-1;
 void sample(bool value,double elapsed){
  if(!initialized){initialized=true;initiallyActive=active=value;lastElapsed=elapsed;return;}
  if(active)activeSeconds+=MAX(0.0,elapsed-lastElapsed);
  if(value!=active){if(value){regains++;lastRegain=elapsed;}else{losses++;if(firstLoss<0)firstLoss=elapsed;}active=value;}
  lastElapsed=elapsed;
 }
};
static FocusMetrics focus;
static void updateFeedback(){
 if(!feedbackLabel)return;
 feedbackLabel.stringValue=[NSString stringWithFormat:@"%@  |  gestures %u (Air %u)  |  pinch %u  |  scroll %u  |  touches %u/%u/%u",
  focus.active?@"ACTIVE":@"FOCUS LOST: click this window",metrics.gesture,metrics.remoteGesture,metrics.magnify,metrics.scroll,
  metrics.began,metrics.moved,metrics.ended];
}

static unsigned countTouches(NSEvent *event,bool phases){
 @try {
  NSSet<NSTouch *> *touches=event.allTouches;
  if(phases)for(NSTouch *touch in touches)metrics.touchPhases[(unsigned)touch.phase]++;
  return (unsigned)touches.count;
 } @catch(NSException *){metrics.touchReadErrors++;return 0;}
}
static bool remoteEvent(NSEvent *event){CGEventRef cg=event.CGEvent;return cg&&CGEventGetIntegerValueField(cg,kCGEventSourceUserData)==remoteInputTag;}
static bool addFinite(double &total,double value){double next=total+value;if(!std::isfinite(next))return false;total=next;return true;}
static void noteTouchCallback(NSEvent *event,unsigned &counter,unsigned &remoteCounter){
 counter++;unsigned count=countTouches(event,true);metrics.touchSamples+=count;
 if(remoteEvent(event)){remoteCounter++;metrics.remoteTouchSamples+=count;}
 updateFeedback();
}
static void noteMagnify(NSEvent *,unsigned &counter){counter++;updateFeedback();}

@interface ReceiverDocument : NSView
@end
@implementation ReceiverDocument
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {
 [[NSColor colorWithCalibratedRed:.11 green:.15 blue:.22 alpha:1] setFill];NSRectFill(dirty);
 [[NSColor colorWithCalibratedRed:.23 green:.30 blue:.39 alpha:1] setStroke];
 NSBezierPath *grid=[NSBezierPath bezierPath];grid.lineWidth=1;
 for(int coordinate=0;coordinate<=1100;coordinate+=50){
  [grid moveToPoint:NSMakePoint(coordinate,0)];[grid lineToPoint:NSMakePoint(coordinate,1100)];
  [grid moveToPoint:NSMakePoint(0,coordinate)];[grid lineToPoint:NSMakePoint(1100,coordinate)];
 }
 [grid stroke];
 [@"Air → Pro touch area" drawAtPoint:NSMakePoint(20,20) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:22],NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (void)touchesBeganWithEvent:(NSEvent *)event {noteTouchCallback(event,metrics.began,metrics.remoteBegan);}
- (void)touchesMovedWithEvent:(NSEvent *)event {noteTouchCallback(event,metrics.moved,metrics.remoteMoved);}
- (void)touchesEndedWithEvent:(NSEvent *)event {noteTouchCallback(event,metrics.ended,metrics.remoteEnded);}
- (void)touchesCancelledWithEvent:(NSEvent *)event {noteTouchCallback(event,metrics.cancelled,metrics.remoteCancelled);}
- (void)magnifyWithEvent:(NSEvent *)event {noteMagnify(event,metrics.documentMagnify);}
- (void)scrollWheel:(NSEvent *)event {metrics.documentScroll++;updateFeedback();[super scrollWheel:event];}
@end
@interface ReceiverScrollView : NSScrollView
@end
@implementation ReceiverScrollView
- (void)magnifyWithEvent:(NSEvent *)event {noteMagnify(event,metrics.scrollViewMagnify);[super magnifyWithEvent:event];}
- (void)scrollWheel:(NSEvent *)event {metrics.scrollViewScroll++;updateFeedback();[super scrollWheel:event];}
@end
@interface ReceiverWindow : NSWindow
@end
@implementation ReceiverWindow
- (void)sendEvent:(NSEvent *)event {
 if(event.type==NSEventTypeGesture||event.type==NSEventTypeMagnify||event.type==NSEventTypeScrollWheel){
  CGEventRef cg=event.CGEvent;
  bool remote=remoteEvent(event);
  metrics.eventPhases[(unsigned)event.phase]++;
  if(event.type==NSEventTypeGesture){
   metrics.gesture++;if(remote){metrics.remoteGesture++;if(CGEventGetIntegerValueField(cg,(CGEventField)0x6e))metrics.remoteNonzeroSubtype++;if(CGEventGetIntegerValueField(cg,(CGEventField)0x84))metrics.remoteNonzeroCGPhase++;}else metrics.otherGesture++;
   metrics.maxTouches=MAX(metrics.maxTouches,countTouches(event,false));
  }
  if(event.type==NSEventTypeMagnify){
   metrics.magnify++;if(remote)metrics.remoteMagnify++;metrics.maxTouches=MAX(metrics.maxTouches,countTouches(event,false));
   double value=event.magnification;
   if(std::isfinite(value)&&addFinite(metrics.magnificationSum,value)
      &&(!remote||addFinite(metrics.remoteMagnificationAbs,std::abs(value)))){
    if(++metrics.validMagnification==1)metrics.magnificationMin=metrics.magnificationMax=value;
    else {metrics.magnificationMin=MIN(metrics.magnificationMin,value);metrics.magnificationMax=MAX(metrics.magnificationMax,value);}
   }else metrics.invalidMagnification++;
  }
  if(event.type==NSEventTypeScrollWheel){
   metrics.scroll++;if(remote)metrics.remoteScroll++;
   double x=event.scrollingDeltaX,y=event.scrollingDeltaY;
   bool finite=std::isfinite(x)&&std::isfinite(y)&&addFinite(metrics.scrollX,x)&&addFinite(metrics.scrollY,y)
      &&(!remote||addFinite(metrics.remoteScrollTravel,std::abs(x)+std::abs(y)));
   if(!finite)metrics.invalidScroll++;
  }
  updateFeedback();
 }
 [super sendEvent:event];
}
@end

static NSScreen *builtinScreen(){
 CGDirectDisplayID displays[16];uint32_t count=0;
 if(CGGetActiveDisplayList(16,displays,&count)!=kCGErrorSuccess)return nil;
 for(uint32_t i=0;i<count;i++)if(CGDisplayIsBuiltin(displays[i])){
  for(NSScreen *screen in NSScreen.screens){NSNumber *number=screen.deviceDescription[@"NSScreenNumber"];if(number.unsignedIntValue==displays[i])return screen;}
 }
 return nil;
}
static void pump(double seconds){
 NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(until.timeIntervalSinceNow>0){NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];}
}
static NSDictionary *phaseDictionary(const std::map<unsigned,unsigned> &phases){
 NSMutableDictionary *out=[NSMutableDictionary dictionary];
 for(auto entry:phases)out[[NSString stringWithFormat:@"%u",entry.first]]=@(entry.second);
 return out;
}
static bool saveReport(const char *path,NSDictionary *report){
 NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
 if(!data)return false;
 int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return false;
 const uint8_t *bytes=(const uint8_t *)data.bytes;size_t left=data.length;bool okay=true;
 while(left){ssize_t written=write(fd,bytes,left);if(written<=0){okay=false;break;}bytes+=written;left-=written;}
 if(close(fd))okay=false;if(!okay)unlink(path);return okay;
}
static bool saveJSON(const char *path,NSString *reason,double duration){
 return saveReport(path,@{
  @"exit_reason":reason,@"duration_seconds":@(duration),
  @"focus":@{@"initially_active":@(focus.initiallyActive),@"losses":@(focus.losses),@"regains":@(focus.regains),@"active_seconds":@(focus.activeSeconds),@"collection_seconds":@(focus.lastElapsed),
    @"first_loss_seconds":focus.firstLoss<0?(id)NSNull.null:@(focus.firstLoss),@"last_regain_seconds":focus.lastRegain<0?(id)NSNull.null:@(focus.lastRegain),@"active_at_end":@(focus.active)},
  @"window_events":@{@"gesture":@(metrics.gesture),@"magnify":@(metrics.magnify),@"scroll":@(metrics.scroll),@"max_touches":@(metrics.maxTouches),@"touch_read_errors":@(metrics.touchReadErrors),@"phases":phaseDictionary(metrics.eventPhases),
    @"air_tagged_gesture":@(metrics.remoteGesture),@"other_gesture":@(metrics.otherGesture),@"air_tagged_magnify":@(metrics.remoteMagnify),@"air_tagged_scroll":@(metrics.remoteScroll),
    @"air_tagged_nonzero_cg_subtype":@(metrics.remoteNonzeroSubtype),@"air_tagged_nonzero_cg_phase":@(metrics.remoteNonzeroCGPhase)},
  @"touch_callbacks":@{@"began":@(metrics.began),@"moved":@(metrics.moved),@"ended":@(metrics.ended),@"cancelled":@(metrics.cancelled),@"samples":@(metrics.touchSamples),@"phases":phaseDictionary(metrics.touchPhases),
    @"air_tagged_began":@(metrics.remoteBegan),@"air_tagged_moved":@(metrics.remoteMoved),@"air_tagged_ended":@(metrics.remoteEnded),@"air_tagged_cancelled":@(metrics.remoteCancelled),@"air_tagged_samples":@(metrics.remoteTouchSamples)},
  @"magnify":@{@"document_callbacks":@(metrics.documentMagnify),@"scroll_view_callbacks":@(metrics.scrollViewMagnify),@"window_value_sum":@(metrics.magnificationSum),@"window_value_min":@(metrics.magnificationMin),@"window_value_max":@(metrics.magnificationMax),
    @"air_tagged_absolute_movement":@(metrics.remoteMagnificationAbs),@"invalid_values":@(metrics.invalidMagnification)},
  @"scroll_callbacks":@{@"document":@(metrics.documentScroll),@"scroll_view":@(metrics.scrollViewScroll),@"delta_x":@(metrics.scrollX),@"delta_y":@(metrics.scrollY),
    @"air_tagged_absolute_travel":@(metrics.remoteScrollTravel),@"invalid_values":@(metrics.invalidScroll)}
 });
}

int main(int argc,char **argv){
 if((argc!=5&&argc!=7)||strcmp(argv[1],"--seconds")||strcmp(argv[3],"--output")||argv[4][0]!='/'
  ||(argc==7&&(strcmp(argv[5],"--ready")||argv[6][0]!='/'))){fprintf(stderr,"usage: live_receiver_window --seconds 1..60 --output /absolute/new.json [--ready /absolute/new-ready.json]\n");return 2;}
 char *end=nullptr;long seconds=strtol(argv[2],&end,10);
 if(!end||*end||seconds<1||seconds>60)return 2;
 @autoreleasepool {
  NSScreen *screen=builtinScreen();if(!screen){fprintf(stderr,"built-in display unavailable\n");return 3;}
  NSRunningApplication *prior=NSWorkspace.sharedWorkspace.frontmostApplication;
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
  NSRect visible=screen.visibleFrame,frame=NSMakeRect(NSMidX(visible)-280,NSMidY(visible)-210,560,420);
  ReceiverWindow *window=[[ReceiverWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;
  window.title=@"Air Input Receiver";
  NSView *content=[[NSView alloc] initWithFrame:window.contentView.bounds];
  content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  NSTextField *instructions=[NSTextField labelWithString:@"On Air: two-finger scroll and pinch over this grid. If focus changes, click here; the 60 s timer continues."];
  instructions.frame=NSMakeRect(12,content.bounds.size.height-43,content.bounds.size.width-24,32);
  instructions.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  instructions.lineBreakMode=NSLineBreakByWordWrapping;
  [content addSubview:instructions];
  feedbackLabel=[NSTextField labelWithString:@"Waiting for Air trackpad gestures…"];
  feedbackLabel.frame=NSMakeRect(12,content.bounds.size.height-74,content.bounds.size.width-24,26);
  feedbackLabel.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  feedbackLabel.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
  [content addSubview:feedbackLabel];
  ReceiverScrollView *scrollView=[[ReceiverScrollView alloc] initWithFrame:NSMakeRect(0,0,content.bounds.size.width,content.bounds.size.height-82)];
  scrollView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  scrollView.hasVerticalScroller=YES;scrollView.hasHorizontalScroller=YES;
  ReceiverDocument *document=[[ReceiverDocument alloc] initWithFrame:NSMakeRect(0,0,1100,1100)];
  document.allowedTouchTypes=NSTouchTypeMaskIndirect;document.wantsRestingTouches=YES;
  scrollView.allowedTouchTypes=NSTouchTypeMaskIndirect;scrollView.documentView=document;
  [content addSubview:scrollView];window.contentView=content;
  CGEventRef cursor=CGEventCreate(nullptr);CGPoint original=cursor?CGEventGetLocation(cursor):CGPointZero;if(cursor)CFRelease(cursor);
  NSString *reason=@"timeout";double start=NSDate.timeIntervalSinceReferenceDate;bool warped=false;
  @try {
   [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];pump(.5);
   if(!window.isKeyWindow||!NSApp.isActive)reason=@"window_inactive";
   else {
    NSScreen *main=NSScreen.screens.firstObject;
    CGPoint target={NSMidX(frame),NSMaxY(main.frame)-NSMidY(frame)};
    if(CGWarpMouseCursorPosition(target)!=kCGErrorSuccess)reason=@"cursor_warp_failed";
    else {
     warped=true;pump(.1);
     NSPoint local=[window mouseLocationOutsideOfEventStream];
     if(!NSPointInRect(local,window.contentView.bounds))reason=@"cursor_outside_window";
     else {
      [window makeFirstResponder:document];
      // Readiness is observed, never inferred from a fixed launch delay. Do not
      // repeatedly reactivate after focus loss: that would hide the failure.
      bool stable=true;
      for(int i=0;i<6;i++){
       pump(.1);
       NSPoint point=[window mouseLocationOutsideOfEventStream];
       stable=stable&&window.isKeyWindow&&NSApp.isActive
        &&NSPointInRect(point,scrollView.frame);
      }
      if(!stable)reason=@"focus_or_pointer_unstable_before_collection";
      else if(argc==7&&!saveReport(argv[6],@{@"pid":@(getpid()),@"window_id":@(window.windowNumber),
       @"key_window":@(window.isKeyWindow),@"app_active":@(NSApp.isActive),
       @"frontmost_pid":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
       @"pointer_in_touch_area":@YES,@"stable_seconds":@.6,
       @"ready_uptime_seconds":@(NSProcessInfo.processInfo.systemUptime),@"collection_seconds":@(seconds)}))reason=@"ready_report_failed";
      else {
      double collectionStart=NSDate.timeIntervalSinceReferenceDate,deadline=collectionStart+seconds;
      focus.sample(window.isKeyWindow&&NSApp.isActive,0);updateFeedback();
      while(NSDate.timeIntervalSinceReferenceDate<deadline){
       pump(MIN(.1,deadline-NSDate.timeIntervalSinceReferenceDate));
       focus.sample(window.isKeyWindow&&NSApp.isActive,NSDate.timeIntervalSinceReferenceDate-collectionStart);
       updateFeedback();
      }
      }
     }
    }
   }
  } @catch(NSException *){reason=@"appkit_exception";}
    @finally {if(warped)CGWarpMouseCursorPosition(original);[window orderOut:nil];if(prior)[prior activateWithOptions:0];}
  if(!saveJSON(argv[4],reason,NSDate.timeIntervalSinceReferenceDate-start)){fprintf(stderr,"cannot save private receiver metrics\n");return 4;}
  fprintf(stdout,"receiver metrics saved: %s\n",argv[4]);
 }
}
