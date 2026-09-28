#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main(int argc,char **argv) { @autoreleasepool {
    CUAOverlayEvidence good;
    good.signedProcess=good.stableBirth=good.exactCG=good.completeAX=true;
    good.parentRoot=good.ordinarySpace=good.exactDisplay=true;
    good.positionSettable=good.sizeUnsettable=true;
    CGRect frame=CGRectMake(-1149,887,126,126);
    auto valid=[&](const CUAOverlayEvidence &e,CGRect cg,CGRect ax,
                   NSString *title,id role,id subrole,uint64_t tags) {
        return cuaOverlayDecision(e,cg,ax,title,role,subrole,tags);
    };
    assert(valid(good,frame,frame,@"Software Cursor",@"AXWindow",@"AXUnknown",
        0x2001000c0202ULL));
    assert(valid(good,frame,frame,@"Software Cursor",@"AXWindow",@"AXUnknown",
        0x2001000c2202ULL));
    for(bool CUAOverlayEvidence::*field:{
        &CUAOverlayEvidence::signedProcess,&CUAOverlayEvidence::stableBirth,
        &CUAOverlayEvidence::exactCG,&CUAOverlayEvidence::completeAX,
        &CUAOverlayEvidence::parentRoot,&CUAOverlayEvidence::ordinarySpace,
        &CUAOverlayEvidence::exactDisplay,&CUAOverlayEvidence::positionSettable,
        &CUAOverlayEvidence::sizeUnsettable}) {
        CUAOverlayEvidence bad=good;bad.*field=false;
        assert(!valid(bad,frame,frame,@"Software Cursor",@"AXWindow",@"AXUnknown",
            0x2001000c0202ULL));
    }
    assert(!valid(good,frame,frame,@"Document",@"AXWindow",@"AXUnknown",
        0x2001000c0202ULL));
    assert(!valid(good,frame,frame,@"Software Cursor",@"AXWindow",@"AXDialog",
        0x2001000c0202ULL));
    assert(!valid(good,frame,frame,@"Software Cursor",@"AXLayoutArea",@"AXUnknown",
        0x2001000c0202ULL));
    assert(!valid(good,frame,frame,@"Software Cursor",@"AXWindow",@"AXUnknown",0));
    assert(!valid(good,frame,CGRectOffset(frame,1,0),@"Software Cursor",
        @"AXWindow",@"AXUnknown",0x2001000c0202ULL));
    assert(!valid(good,CGRectMake(0,0,125,126),frame,@"Software Cursor",
        @"AXWindow",@"AXUnknown",0x2001000c0202ULL));
    assert(!valid(good,CGRectMake(NAN,0,126,126),frame,@"Software Cursor",
        @"AXWindow",@"AXUnknown",0x2001000c0202ULL));
    if(argc==1) {puts("CUA overlay metadata guards passed");return 0;}
    if(argc!=4 || strcmp(argv[1],"--read-only")!=0)return 2;
    uint32_t wid=atoi(argv[2]);pid_t pid=atoi(argv[3]);
    NSDictionary *cg=windowLayerDescription(wid);
    bool signedCode=signedCUAServiceExecutable(pid);
    bool verified=verifiedCUAOverlay(cg,wid,pid,api().conn());
    printf("cua_overlay_readonly wid=%u pid=%d signed=%d verified=%d mutations=0\n",
        wid,pid,signedCode,verified);
    return signedCode && verified ? 0 : 3;
} }
