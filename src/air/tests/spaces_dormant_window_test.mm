#include "../spaces.mm"
#include <cassert>
#include <cstdio>
extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(){return 0;}
int main(){
 ProcessBirth own=processBirth(getpid());assert(own.valid()&&own==processBirth(getpid()));
 assert(dormantExclusionDecision(true,true,true,false,true,true,true,true,true));
 assert(!dormantExclusionDecision(false,true,true,false,true,true,true,true,true)); // initial onscreen
 assert(!dormantExclusionDecision(true,true,true,false,true,false,true,true,true)); // now onscreen
 assert(!dormantExclusionDecision(true,true,true,false,false,true,true,true,true)); // live WID/owner absent
 assert(!dormantExclusionDecision(true,true,true,false,true,true,false,true,true)); // missing live identity
 assert(!dormantExclusionDecision(true,false,true,false,true,true,true,true,true));
 assert(!dormantExclusionDecision(true,true,false,false,true,true,true,true,true)); // unknown role/incomplete
 assert(!dormantExclusionDecision(true,true,true,true,true,true,true,true,true)); // matched AX window, including minimized
 assert(!dormantExclusionDecision(true,true,true,false,true,true,true,false,true));
 assert(!dormantExclusionDecision(true,true,true,false,true,true,true,true,false));
 assert(dormantAXRoleKind(@"AXScrollArea")==0);
 assert(dormantAXRoleKind((id)nil)==-1);
 assert(dormantAXRoleKind(@"AXUnknownRole")==-1);
 assert(dormantAXRoleKind((__bridge NSString *)kAXWindowRole)==1);
 DormantAXInventory mappedLayout; mappedLayout.complete=true;
 recordDormantAXElement(mappedLayout,@"AXLayoutArea",kAXErrorSuccess,10865);
 assert(mappedLayout.complete&&mappedLayout.windows.count(10865));
 recordDormantAXElement(mappedLayout,@"AXScrollArea",kAXErrorFailure,0);
 assert(mappedLayout.complete&&mappedLayout.windows.size()==1);
 recordDormantAXElement(mappedLayout,@"AXWindow",kAXErrorFailure,0);
 assert(!mappedLayout.complete);
 DormantAXInventory unknown; unknown.complete=true;
 recordDormantAXElement(unknown,@"AXLayoutArea",kAXErrorFailure,0);
 assert(!unknown.complete);
 DormantAXInventory missingRole; missingRole.complete=true;
 recordDormantAXElement(missingRole,nil,kAXErrorSuccess,10865);
 assert(!missingRole.complete&&missingRole.windows.empty());
 assert(systemChrome(@"com.apple.universalcontrol"));
 puts("PASS: only fresh-CG-owned, currently offscreen windows with exact process identity, complete AX absence and confirmed empty membership are excluded");
}
