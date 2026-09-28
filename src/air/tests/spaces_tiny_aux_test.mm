#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
extern "C" void air_set_error(const char*){}
extern "C" int air_display_restore(){return 0;}
int main(){@autoreleasepool{
 CGRect cg=CGRectMake(0,744,1,1),ax=cg;id role=(__bridge NSString*)kAXWindowRole,unknown=@"AXUnknown";
 assert(exactInvisibleOnePixelMetadata(cg,@0,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(CGRectMake(0,744,0,1),@0,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(CGRectMake(0,744,NAN,1),@0,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(CGRectMake(0,744,2,1),@0,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,nil,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@1,role,unknown,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@0,role,(__bridge NSString*)kAXStandardWindowSubrole,(id)kCFBooleanFalse,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@0,role,unknown,(id)kCFBooleanTrue,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@0,role,unknown,@0.5,true,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@0,role,unknown,(id)kCFBooleanFalse,false,ax));
 assert(!exactInvisibleOnePixelMetadata(cg,@0,role,unknown,(id)kCFBooleanFalse,true,CGRectMake(0,743,1,1)));
 puts("tiny auxiliary metadata: concrete CG/AX parsing and exact one-pixel transparent AXUnknown boundary guards passed");
}}
