#import <AppKit/AppKit.h>
#include "../overlay.h"
#include <cassert>
#include <cstdio>

static int chosenSlot;
static int loopChoice=-1;
static int localUI;
static int reconnectChoice;
static void choose(int slot){chosenSlot=slot;}
static void chooseLoop(int enabled){loopChoice=enabled;}
static void reconnect(){reconnectChoice++;}
extern "C" void air_input_local_ui(int active){localUI=active;}

static NSButton *buttonWithTag(NSView *parent,int tag){
 for(NSView *view in parent.subviews){
  if([view isKindOfClass:NSButton.class]&&view.tag==tag)return (NSButton *)view;
 }
 return nil;
}

int main(){
 @autoreleasepool {
  [NSApplication sharedApplication];
  NSView *host=[[NSView alloc] initWithFrame:NSMakeRect(0,0,500,400)];
  air_overlay_setup(choose,nullptr);
  air_overlay_setup_reconnect(reconnect);
  air_overlay_attach((__bridge void *)host);
  assert(host.window==nil&&host.subviews.count==2);
  NSView *panel=host.subviews.lastObject;
  NSButton *reveal=buttonWithTag(host,100);
  NSButton *reconnectButton=buttonWithTag(panel,101);
  assert(reveal&&reveal.hidden);
  assert(reconnectButton&&reconnectButton.hidden);
  assert(panel.hidden&&air_overlay_visible()==0);
  air_overlay_state(3,2,0);
  NSButton *second=buttonWithTag(panel,2);
  NSButton *loop=buttonWithTag(panel,-1);
  assert(second&&second.state==NSControlStateValueOn);
  assert(loop&&loop.hidden);
  assert(!reveal.hidden&&reveal.target&&reveal.action);
  [NSApp sendAction:reveal.action to:reveal.target from:reveal];
  assert(!panel.hidden&&reveal.hidden&&air_overlay_visible()==1&&localUI==1);
  NSPoint hitPoint=NSMakePoint(NSMidX(second.frame)+panel.frame.origin.x,NSMidY(second.frame)+panel.frame.origin.y);
  NSView *hit=[host hitTest:hitPoint];
  assert(hit==second);
  assert(second.target&&second.action);
  [NSApp sendAction:second.action to:second.target from:second];
  assert(chosenSlot==2&&panel.hidden&&!reveal.hidden&&air_overlay_visible()==0&&localUI==0);
  air_overlay_state(0,0,0);
  assert(air_overlay_pointer(250,395)==0&&panel.hidden&&reveal.hidden);
  air_overlay_state(3,1,16);
  assert(!reveal.hidden&&!reconnectButton.hidden&&reconnectButton.enabled&&panel.hidden);
  [NSApp sendAction:reveal.action to:reveal.target from:reveal];
  assert(!panel.hidden&&air_overlay_visible()==1);
  [NSApp sendAction:reconnectButton.action to:reconnectButton.target from:reconnectButton];
  assert(reconnectChoice==1&&panel.hidden&&air_overlay_visible()==0);
  air_overlay_state(3,1,24);
  [NSApp sendAction:reveal.action to:reveal.target from:reveal];
  assert(!reconnectButton.hidden&&!reconnectButton.enabled&&[reconnectButton.title isEqual:@"Reloading Spaces…"]);
  [NSApp sendAction:reconnectButton.action to:reconnectButton.target from:reconnectButton];
  assert(reconnectChoice==1);
  air_overlay_state(0,0,16);
  assert(!panel.hidden&&!reconnectButton.hidden&&reconnectButton.enabled);
  [NSApp sendAction:reconnectButton.action to:reconnectButton.target from:reconnectButton];
  assert(reconnectChoice==2);
  air_overlay_state(3,1,2);
  assert(reconnectButton.hidden);
  assert(loop.hidden&&!reveal.hidden);
  [NSApp sendAction:reveal.action to:reveal.target from:reveal];
  assert(!panel.hidden);
  [NSApp sendAction:second.action to:second.target from:second];
  assert(chosenSlot==2&&panel.hidden);
  air_overlay_setup(choose,chooseLoop);
  air_overlay_state(3,1,2);
  assert(!loop.hidden);
  assert(air_overlay_pointer(250,395)==1);
  [NSApp sendAction:loop.action to:loop.target from:loop];
  assert(loopChoice==1&&panel.hidden);
  air_overlay_shutdown();
  assert(host.subviews.count==0&&air_overlay_visible()==0&&host.window==nil);
 }
 puts("windowless overlay validation passed");
}
