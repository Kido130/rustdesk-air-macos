#include "../edge_drag_policy.h"
#include <cassert>

int main(){
 assert(edgeDragDirection(2,400,0,0,1440,900)==-1);
 assert(edgeDragDirection(-32,400,0,0,1440,900)==-1);
 assert(edgeDragDirection(-33,400,0,0,1440,900)==0);
 assert(edgeDragDirection(1439,400,0,0,1440,900)==1);
 assert(edgeDragDirection(1472,400,0,0,1440,900)==1);
 assert(edgeDragDirection(1473,400,0,0,1440,900)==0);
 assert(edgeDragDirection(600,400,0,0,1440,900)==0);
 assert(edgeDragDirection(-10,-1,0,0,1440,900)==0);
 assert(edgeDragDirection(-10,900,0,0,1440,900)==0);
 int nativeAdjacent=0;
 assert(edgeDragSlotTransition(2,2,0,nativeAdjacent)&&nativeAdjacent==0);
 assert(!edgeDragSlotTransition(2,1,1,nativeAdjacent)&&nativeAdjacent==0);
 assert(edgeDragSlotTransition(2,1,-1,nativeAdjacent)&&nativeAdjacent==-1);
 assert(edgeDragSlotTransition(2,1,0,nativeAdjacent));
 assert(!edgeDragSlotTransition(2,2,0,nativeAdjacent)); // More than one switch.
 nativeAdjacent=0;assert(!edgeDragSlotTransition(1,3,-1,nativeAdjacent)); // No wrap.
 EdgeDragPolicy drag;
 EdgeDragSample start{300,200,200,150,800,600,1000000000ULL,0};
 drag.begin(start);
 auto moved=start;moved.pointerX+=120;moved.windowX+=120;moved.timeNs+=100000000;
 assert(drag.observe(moved)&&drag.movedWindow);
 auto edge=moved;edge.pointerX=0;edge.windowX=0;edge.edge=-1;edge.timeNs+=100000000;
 assert(drag.observe(edge));
 edge.timeNs+=350000000;assert(drag.release(edge)==-1);

 drag.begin(start);auto text=start;text.pointerX=0;text.edge=-1;text.timeNs+=400000000;
 assert(drag.release(text)==0); // Text selection never moves its window.
 drag.begin(start);auto resize=moved;resize.width+=100;resize.edge=1;
 assert(!drag.observe(resize)&&drag.release(resize)==0);
 drag.begin(start);assert(drag.observe(moved));edge.timeNs=start.timeNs+200000000;
 assert(drag.observe(edge));edge.timeNs+=299000000;assert(drag.release(edge)==0);
 drag.begin(start);assert(drag.observe(moved));edge.timeNs=start.timeNs+200000000;
 assert(drag.observe(edge));edge.edge=1;edge.timeNs+=400000000;
 assert(drag.release(edge)==0); // Switching edges restarts the dwell.
 drag.begin(start);auto unrelated=moved;unrelated.windowX+=60;
 assert(drag.observe(unrelated)&&!drag.movedWindow);
 unrelated.edge=1;unrelated.timeNs+=400000000;assert(drag.release(unrelated)==0);
 drag.begin(start);auto queued=start;queued.pointerX=0;queued.edge=-1;
 queued.timeNs+=200000000;assert(drag.observe(queued)&&!drag.movedWindow);
 queued.timeNs+=350000000;queued.windowX=-100;
 assert(drag.release(queued)==-1); // WindowServer may apply the posted drag later.
 drag.begin(start);auto seam=start;seam.pointerX=100;seam.windowX=0;
 seam.timeNs+=100000000;assert(drag.observe(seam)&&drag.movedWindow);
 seam.pointerX=-20;seam.windowX=-120;
 seam.edge=edgeDragDirection(seam.pointerX,seam.pointerY,0,0,1440,900);
 seam.timeNs+=100000000;assert(drag.observe(seam));
 seam.timeNs+=350000000;assert(drag.release(seam)==-1);
 drag.begin(start);auto slow=start;
 for(int i=1;i<=8;i++){slow.pointerX=start.pointerX+i*20;slow.windowX=start.windowX+i*20;
  slow.timeNs=start.timeNs+(uint64_t)i*1000000000ULL;assert(drag.observe(slow));}
 slow.edge=1;slow.timeNs+=100000000;assert(drag.observe(slow));
 slow.timeNs+=350000000;assert(drag.release(slow)==1); // Slow drags can exceed five seconds.
 drag.begin(start);auto stale=moved;stale.timeNs+=31000000000ULL;
 assert(!drag.observe(stale)&&drag.release(stale)==0);
 drag.begin(start);assert(drag.observe(moved));
 auto native=moved;native.timeNs+=400000000;native.edge=0;
 assert(drag.releaseAfterNativeSwitch(native));
 drag.begin(start);assert(drag.observe(moved));
 native.timeNs+=40000000000ULL;assert(drag.releaseAfterNativeSwitch(native));
}
