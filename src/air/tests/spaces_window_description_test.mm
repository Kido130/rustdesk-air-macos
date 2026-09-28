#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
extern "C" void air_set_error(const char*){}
extern "C" int air_display_restore(){return 0;}
int main(){@autoreleasepool{
 assert(exactWindowLayerDescription(@[@{(id)kCGWindowNumber:@2711,(id)kCGWindowLayer:@-2147483602}],2711));
 assert(!exactWindowLayerDescription(@[@{(id)kCGWindowNumber:@2712,(id)kCGWindowLayer:@0}],2711));
 assert(!exactWindowLayerDescription(@[@{(id)kCGWindowNumber:@2711}],2711));
 assert(!exactWindowLayerDescription(@[@{(id)kCGWindowNumber:@"2711",(id)kCGWindowLayer:@0}],2711));
 puts("exact WID/layer description guards passed");
}}
