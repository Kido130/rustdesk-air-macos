#pragma once
#include <cmath>
#include <cstdint>

// Permit a short overshoot onto a physically adjacent monitor. The caller
// separately requires the drag to begin inside the built-in display.
inline int edgeDragDirection(double x,double y,double minX,double minY,double maxX,double maxY){
 if(!std::isfinite(x)||!std::isfinite(y)||y<minY||y>=maxY)return 0;
 if(x>=minX-32&&x<=minX+8)return -1;
 if(x>=maxX-8&&x<=maxX+32)return 1;
 return 0;
}
inline bool edgeDragSlotTransition(int start,int current,int edge,int &observedAdjacent){
 if(observedAdjacent)return current==start+observedAdjacent;
 if(current==start)return true;
 int direction=current==start-1?-1:current==start+1?1:0;
 if(!direction||edge!=direction)return false;
 observedAdjacent=direction;return true;
}

// Input observations are in Pro desktop points. Window identity and ownership
// are checked by the caller on every observation.
struct EdgeDragSample {
 double pointerX=0,pointerY=0,windowX=0,windowY=0,width=0,height=0;
 uint64_t timeNs=0;
 int edge=0;
};
struct EdgeDragPolicy {
 EdgeDragSample start;
 bool active=false,movedWindow=false;
 int edge=0;
 uint64_t edgeSince=0,lastNs=0;
 void reset(){*this={};}
 void begin(const EdgeDragSample &sample){reset();start=sample;lastNs=sample.timeNs;active=true;}
 bool observe(const EdgeDragSample &sample,bool nativeSwitched=false){
  if(!active||sample.timeNs<lastNs||(!nativeSwitched&&sample.timeNs-lastNs>30000000000ULL)
     ||std::abs(sample.width-start.width)>2||std::abs(sample.height-start.height)>2){reset();return false;}
  lastNs=sample.timeNs;
  double pointerDX=sample.pointerX-start.pointerX,pointerDY=sample.pointerY-start.pointerY;
  double windowDX=sample.windowX-start.windowX,windowDY=sample.windowY-start.windowY;
  if(std::hypot(windowDX,windowDY)>=32&&std::hypot(pointerDX,pointerDY)>=32
     &&std::abs(windowDX-pointerDX)<=24&&std::abs(windowDY-pointerDY)<=24)movedWindow=true;
  if(!sample.edge){edge=0;edgeSince=0;return true;}
  if(sample.edge!=edge){edge=sample.edge;edgeSince=sample.timeNs;}
  return true;
 }
 int release(const EdgeDragSample &sample){
  int result=0;
  if(observe(sample)&&movedWindow&&edge&&edge==sample.edge
     &&sample.timeNs>=edgeSince&&sample.timeNs-edgeSince>=300000000ULL
     &&sample.timeNs-edgeSince<=30000000000ULL)result=edge;
  reset();return result;
 }
 bool releaseAfterNativeSwitch(const EdgeDragSample &sample){
  // A native Space transition must be reconciled even after a long held drag.
  bool valid=observe(sample,true)&&movedWindow;
  reset();return valid;
 }
};
