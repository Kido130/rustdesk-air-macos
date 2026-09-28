#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "overlay.h"
#include <atomic>

extern "C" void air_input_local_ui(int active);

@interface AirSpacePanel : NSVisualEffectView
@end
@interface AirSpaceActions : NSObject
- (void)showSpaces:(NSButton *)sender;
- (void)choose:(NSButton *)sender;
- (void)toggleLoop:(NSButton *)sender;
- (void)reconnectSpaces:(NSButton *)sender;
@end

static NSView *remoteView;
static AirSpacePanel *panel;
static NSButton *slotButtons[9];
static NSButton *revealButton;
static NSButton *reconnectButton;
static NSButton *loopButton;
static NSTextField *exitHint;
static AirSpaceActions *actions;
static AirSpaceChoose chooseCallback;
static AirSpaceLoop loopCallback;
static AirSpaceReconnect reconnectCallback;
static bool available=false, loopSupported=false, loopEnabled=false;
static int currentSlot=0;
static int reportedCount=0,reportedCurrent=0,reportedFlags=0;
static std::atomic<bool> shown(false);

static void hidePanel(){
 if(!shown.exchange(false))return;
 panel.hidden=YES;
 revealButton.hidden=!(available||((reportedFlags&16)&&reconnectCallback));
 air_input_local_ui(0);
}
static bool layoutPanel(){
 if(!remoteView||!panel)return false;
 NSRect bounds=remoteView.bounds;
 CGFloat width=MIN(500,bounds.size.width-16);
 int extraRows=(MAX(0,reportedCount-3)+2)/3;
 CGFloat panelHeight=104+34*extraRows;
 if(width<220||bounds.size.height<panelHeight+30)return false;
 revealButton.frame=NSMakeRect((bounds.size.width-94)/2,bounds.size.height-28,94,26);
 panel.frame=NSMakeRect((bounds.size.width-width)/2,bounds.size.height-panelHeight-8,width,panelHeight);
 CGFloat loopWidth=loopSupported&&loopCallback?92:0;
 CGFloat gap=7,margin=12;
 CGFloat buttonsWidth=width-2*margin-loopWidth-(loopWidth?gap:0);
 CGFloat slotWidth=(buttonsWidth-2*gap)/3;
 CGFloat firstRowY=panelHeight-36;
 for(int i=0;i<3;i++)slotButtons[i].frame=NSMakeRect(margin+i*(slotWidth+gap),firstRowY,slotWidth,29);
 CGFloat extraWidth=(width-2*margin-2*gap)/3;
 for(int i=3;i<9;i++)slotButtons[i].frame=NSMakeRect(margin+((i-3)%3)*(extraWidth+gap),firstRowY-34*(1+(i-3)/3),extraWidth,29);
 loopButton.frame=NSMakeRect(width-margin-loopWidth,firstRowY,loopWidth,29);
 reconnectButton.frame=NSMakeRect(margin,34,width-2*margin,29);
 exitHint.frame=NSMakeRect(margin,5,width-2*margin,20);
 return true;
}
static void revealPanel(){
 if(!(available||((reportedFlags&16)&&reconnectCallback))||!layoutPanel())return;
 if(shown.exchange(true))return;
 revealButton.hidden=YES;
 panel.hidden=NO;
 air_input_local_ui(1);
}

@implementation AirSpacePanel
- (void)updateTrackingAreas {
 for(NSTrackingArea *area in self.trackingAreas)[self removeTrackingArea:area];
 [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]];
 [super updateTrackingAreas];
}
- (void)mouseMoved:(NSEvent *)event {
 NSPoint point=[remoteView convertPoint:event.locationInWindow fromView:nil];
 air_overlay_pointer(point.x,point.y);
}
- (void)mouseExited:(NSEvent *)event {
 NSPoint point=[remoteView convertPoint:event.locationInWindow fromView:nil];
 air_overlay_pointer(point.x,point.y);
}
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return YES; }
@end

@implementation AirSpaceActions
- (void)showSpaces:(NSButton *)sender {
 (void)sender;
 revealPanel();
}
- (void)choose:(NSButton *)sender {
 if(!available||sender.tag<1||sender.tag>reportedCount||!chooseCallback)return;
 int slot=(int)sender.tag;
 hidePanel();
 [remoteView.window makeFirstResponder:remoteView];
 chooseCallback(slot);
}
- (void)toggleLoop:(NSButton *)sender {
 (void)sender;
 if(!available||!loopSupported||!loopCallback)return;
 int requested=!loopEnabled;
 hidePanel();
 [remoteView.window makeFirstResponder:remoteView];
 loopCallback(requested);
}
- (void)reconnectSpaces:(NSButton *)sender {
 (void)sender;
 if(!reconnectCallback||!(reportedFlags&16)||(reportedFlags&8))return;
 hidePanel();
 [remoteView.window makeFirstResponder:remoteView];
 reconnectCallback();
}
@end

static void installPanel(void *host_view,AirSpaceChoose choose,AirSpaceLoop loop){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{installPanel(host_view,choose,loop);});return;}
 if(!host_view||!choose)return;
 if(panel&&panel.superview==(__bridge NSView *)host_view){chooseCallback=choose;loopCallback=loop;air_overlay_state(reportedCount,reportedCurrent,reportedFlags);return;}
 if(panel)air_overlay_shutdown();
 remoteView=(__bridge NSView *)host_view;chooseCallback=choose;loopCallback=loop;
 actions=[AirSpaceActions new];
 panel=[[AirSpacePanel alloc] initWithFrame:NSZeroRect];
 panel.material=NSVisualEffectMaterialHUDWindow;
 panel.blendingMode=NSVisualEffectBlendingModeWithinWindow;
 panel.state=NSVisualEffectStateActive;
 panel.wantsLayer=YES;panel.layer.cornerRadius=12;panel.layer.masksToBounds=YES;
 revealButton=[NSButton buttonWithTitle:@"Spaces ▾" target:actions action:@selector(showSpaces:)];
 revealButton.tag=100;revealButton.bezelStyle=NSBezelStyleRounded;
 revealButton.toolTip=@"Choose a remote Space";
 revealButton.hidden=!available;[remoteView addSubview:revealButton];
 reconnectButton=[NSButton buttonWithTitle:@"Reload Spaces" target:actions action:@selector(reconnectSpaces:)];
 reconnectButton.tag=101;reconnectButton.bezelStyle=NSBezelStyleRounded;
 reconnectButton.toolTip=@"Restore and rebuild Remote Spaces on the Pro";
 [panel addSubview:reconnectButton];
 for(int i=0;i<9;i++){
  NSString *title=i<3?[NSString stringWithFormat:@"Space %d",i+1]:[NSString stringWithFormat:@"Full Screen %d",i-2];
  slotButtons[i]=[NSButton buttonWithTitle:title target:actions action:@selector(choose:)];
  slotButtons[i].tag=i+1;slotButtons[i].bezelStyle=NSBezelStyleRounded;
  [panel addSubview:slotButtons[i]];
 }
 loopButton=[NSButton buttonWithTitle:@"Loop: Off" target:actions action:@selector(toggleLoop:)];
 loopButton.bezelStyle=NSBezelStyleRounded;[panel addSubview:loopButton];
 exitHint=[NSTextField labelWithString:@"⌃⌥⌘ Esc · Exit Remote Mode"];
 exitHint.alignment=NSTextAlignmentCenter;exitHint.font=[NSFont systemFontOfSize:11];
 exitHint.textColor=NSColor.secondaryLabelColor;[panel addSubview:exitHint];
 panel.hidden=YES;[remoteView addSubview:panel];
 panel.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin;
 air_overlay_state(reportedCount,reportedCurrent,reportedFlags);
}

extern "C" void air_overlay_state(int active_count,int current_slot,int flags){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_overlay_state(active_count,current_slot,flags);});return;}
 reportedCount=active_count;reportedCurrent=current_slot;reportedFlags=flags;
 available=active_count>=3&&active_count<=9&&current_slot>=0&&current_slot<=active_count;
 currentSlot=available?current_slot:0;
 loopSupported=available&&(flags&2)!=0&&loopCallback;
 loopEnabled=loopSupported&&(flags&4)!=0;
 if(!panel)return;
 bool canReveal=available||((flags&16)&&reconnectCallback);
 if(!canReveal)hidePanel();
 for(int i=0;i<9;i++){
  slotButtons[i].hidden=!available||i>=active_count;
  slotButtons[i].state=(i+1==currentSlot)?NSControlStateValueOn:NSControlStateValueOff;
  slotButtons[i].bezelColor=i+1==currentSlot?NSColor.controlAccentColor:nil;
 }
 loopButton.hidden=!loopSupported;
 reconnectButton.hidden=!(flags&16)||!reconnectCallback;
 reconnectButton.enabled=!(flags&8);
 reconnectButton.title=(flags&8)?@"Reloading Spaces…":@"Reload Spaces";
 revealButton.hidden=shown||!canReveal;
 loopButton.title=loopEnabled?@"Loop: On":@"Loop: Off";
 if(!layoutPanel())hidePanel();
}

extern "C" int air_overlay_pointer(double x,double y){
 if(![NSThread isMainThread]||!(available||((reportedFlags&16)&&reconnectCallback))||!panel||!remoteView)return 0;
 if(!shown){
  NSEventType type=NSApp.currentEvent.type;
  bool ending=type==NSEventTypeLeftMouseUp||type==NSEventTypeRightMouseUp||type==NSEventTypeOtherMouseUp;
  bool dragging=type==NSEventTypeLeftMouseDragged||type==NSEventTypeRightMouseDragged||type==NSEventTypeOtherMouseDragged;
  if([NSEvent pressedMouseButtons]||ending||dragging)return 0;
 }
 if(!layoutPanel()){hidePanel();return 0;}
 NSRect bounds=remoteView.bounds;
 bool hot=x>=0&&x<bounds.size.width&&y>=bounds.size.height-10&&y<bounds.size.height;
 bool inside=shown&&NSPointInRect(NSMakePoint(x,y),panel.frame);
 if(hot)revealPanel();else if(shown&&!inside)hidePanel();
 return hot||inside;
}
extern "C" int air_overlay_visible(){return shown?1:0;}
extern "C" void air_overlay_shutdown(){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_overlay_shutdown();});return;}
 hidePanel();available=false;loopSupported=false;loopEnabled=false;currentSlot=0;
 reportedCount=0;reportedCurrent=0;reportedFlags=0;
 [revealButton removeFromSuperview];revealButton=nil;
 [reconnectButton removeFromSuperview];reconnectButton=nil;
 [panel removeFromSuperview];panel=nil;remoteView=nil;actions=nil;loopButton=nil;exitHint=nil;
 for(auto &button:slotButtons)button=nil;
 chooseCallback=nullptr;loopCallback=nullptr;reconnectCallback=nullptr;
}

extern "C" void air_overlay_attach(void *host_view){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_overlay_attach(host_view);});return;}
 remoteView=(__bridge NSView *)host_view;
 if(remoteView&&chooseCallback)installPanel(host_view,chooseCallback,loopCallback);
}
extern "C" void air_overlay_setup(AirSpaceChoose choose,AirSpaceLoop loop){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_overlay_setup(choose,loop);});return;}
 chooseCallback=choose;loopCallback=loop;
 if(remoteView&&choose)installPanel((__bridge void *)remoteView,choose,loop);
}
extern "C" void air_overlay_setup_reconnect(AirSpaceReconnect reconnect){
 if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(),^{air_overlay_setup_reconnect(reconnect);});return;}
 reconnectCallback=reconnect;
 if(remoteView&&chooseCallback)air_overlay_state(reportedCount,reportedCurrent,reportedFlags);
}
