#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    DetachedMenuStripEvidence exact;
    exact.layerZero=exact.blankTitle=exact.alphaOne=exact.onscreenKeyAbsent=true;
    exact.parentKnown=exact.parentRoot=exact.exactTags=exact.zeroMembership=true;
    exact.stableProcess=exact.absentVisible=true;
    CGRect external=CGRectMake(-3840,0,1920,1080);
    CGRect strip=CGRectMake(-3840,0,1920,30);
    assert(detachedMenuStripMetadata(exact,strip,external,false));
    assert(detachedMenuStripMetadata(exact,CGRectMake(0,0,1147,26),
        CGRectMake(0,0,1147,745),true));
    assert(!detachedMenuStripMetadata(exact,strip,external,true));
    for(bool DetachedMenuStripEvidence::*field:{
            &DetachedMenuStripEvidence::layerZero,
            &DetachedMenuStripEvidence::blankTitle,
            &DetachedMenuStripEvidence::alphaOne,
            &DetachedMenuStripEvidence::onscreenKeyAbsent,
            &DetachedMenuStripEvidence::parentKnown,
            &DetachedMenuStripEvidence::parentRoot,
            &DetachedMenuStripEvidence::exactTags,
            &DetachedMenuStripEvidence::zeroMembership,
            &DetachedMenuStripEvidence::stableProcess,
            &DetachedMenuStripEvidence::absentVisible}) {
        auto invalid=exact;invalid.*field=false;
        assert(!detachedMenuStripMetadata(invalid,strip,external,false));
    }
    for(CGRect invalid:{CGRectMake(-3839,0,1920,30),CGRectMake(-3840,1,1920,30),
            CGRectMake(-3840,0,1919,30),CGRectMake(-3840,0,1920,29),
            CGRectMake(-3840,0,1920,480)})
        assert(!detachedMenuStripMetadata(exact,invalid,external,false));
    puts("detached menu strip: exact metadata only; ordinary and moving windows remain guarded");
} }
