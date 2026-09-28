#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    OrdinaryOwnedChildEvidence child;
    child.finder=child.process=child.space=child.display=child.stableCG=true;
    child.completeAX=child.candidateAbsentAX=child.exactParent=child.parentRoot=child.parentInAX=true;
    child.parentStandard=child.blankTitle=child.alphaOne=child.onscreen=child.contained=true;
    assert(ordinaryOwnedChildDecision(child));
    auto rejectChild=[&](void (*change)(OrdinaryOwnedChildEvidence &)) {
        OrdinaryOwnedChildEvidence bad=child;change(bad);assert(!ordinaryOwnedChildDecision(bad));
    };
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.finder=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.process=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.space=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.display=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.stableCG=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.completeAX=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.candidateAbsentAX=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.exactParent=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.parentRoot=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.parentInAX=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.parentStandard=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.blankTitle=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.alphaOne=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.onscreen=false;});
    rejectChild([](OrdinaryOwnedChildEvidence &e){e.contained=false;});

    OrdinaryChromeStripEvidence chrome;
    chrome.chrome=chrome.process=chrome.space=chrome.display=chrome.stableAll=true;
    chrome.completeAX=chrome.candidateAbsentAX=chrome.blankTitle=chrome.alphaOne=true;
    chrome.standardRootCohort=chrome.offscreen=chrome.surfaceTags=true;
    CGRect display=CGRectMake(-3840,0,1920,1080);
    CGRect root=CGRectMake(-3840,30,1920,1050);
    assert(ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3741,55,1614,89)));
    assert(ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3741,55,1578,538)));
    assert(ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3840,-47,1920,47)));
    assert(ordinaryChromeStripDecision(chrome,display,root,CGRectMake(0,-41,1920,41)));
    CGRect builtinDisplay=CGRectMake(0,0,1147,745);
    CGRect builtinRoot=CGRectMake(0,26,1147,719);
    assert(ordinaryChromeStripKind(builtinDisplay,builtinRoot,CGRectMake(99,51,841,89),true)
        ==OrdinaryChromeGeometry::Contained);
    assert(ordinaryChromeStripKind(builtinDisplay,builtinRoot,CGRectMake(0,-71,1147,47),true)
        ==OrdinaryChromeGeometry::Edge);
    assert(ordinaryChromeStripKind(builtinDisplay,builtinRoot,CGRectMake(0,-65,1147,41),true)
        ==OrdinaryChromeGeometry::Edge);
    assert(ordinaryChromeStripKind(display,root,CGRectMake(-3741,55,1614,178),true)
        ==OrdinaryChromeGeometry::Contained);
    assert(ordinaryChromeStripKind(builtinDisplay,builtinRoot,CGRectMake(99,51,790,89),true)
        ==OrdinaryChromeGeometry::None);
    assert(ordinaryChromeStripKind(builtinDisplay,builtinRoot,CGRectMake(99,51,841,89),false)
        ==OrdinaryChromeGeometry::None);
    OrdinaryChromeStripEvidence badCohort=chrome;badCohort.standardRootCohort=false;
    assert(!ordinaryChromeStripDecision(badCohort,display,root,CGRectMake(0,-41,1920,41)));
    OrdinaryChromeStripEvidence badTags=chrome;badTags.surfaceTags=false;
    assert(!ordinaryChromeStripDecision(badTags,display,root,CGRectMake(-3741,55,1578,178)));
    assert(ordinaryChromeSurfaceTagDecision(0x1400c0402ULL,OrdinaryChromeGeometry::Contained));
    assert(ordinaryChromeSurfaceTagDecision(0x1400c0202ULL,OrdinaryChromeGeometry::Edge));
    assert(!ordinaryChromeSurfaceTagDecision(0x300000100082401ULL,OrdinaryChromeGeometry::Contained));
    assert(!ordinaryChromeSurfaceTagDecision(0x1400c0402ULL,OrdinaryChromeGeometry::Edge));
    // Saved live WID271 pattern: an AX-absent Chrome compositor surface
    // contained in WID269 on the same ordinary external Space. Classification
    // alone cannot allow it to vanish from whole-mode restoration accounting.
    CGRect chromeDisplay=CGRectMake(-1920,0,1920,1080);
    CGRect chromeRoot=CGRectMake(-1920,30,1920,1050);
    CGRect chrome271=CGRectMake(-1821,55,1650,538);
    assert(ordinaryChromeStripKind(chromeDisplay,chromeRoot,chrome271,true)
        ==OrdinaryChromeGeometry::Contained);
    assert(ordinaryChromeSurfaceTagDecision(0x1400c0402ULL,
        ordinaryChromeStripKind(chromeDisplay,chromeRoot,chrome271,true)));
    assert(ordinaryChromeStripDecision(chrome,chromeDisplay,chromeRoot,chrome271));
    assert(wholeFrameCompanionRequiresJournal(@"com.google.Chrome"));
    assert(!wholeFrameCompanionRequiresJournal(@"com.apple.finder"));
    assert(!wholeFrameCompanionRequiresJournal(@"com.apple.Safari"));
    assert(!ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3000,-47,1920,47)));
    assert(!ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3840,-200,1920,47)));
    assert(!ordinaryChromeStripDecision(chrome,display,root,CGRectMake(-3840,-47,1920,129)));
    assert(!ordinaryChromeStripDecision(chrome,CGRectMake(-1920,0,1920,1080),root,
        CGRectMake(-3840,-47,1920,47)));
    CGRect builtin=CGRectMake(0,0,1147,745);
    CGRect aligned=CGRectMake(-3840,-47,1920,47);
    CGRect displaced=CGRectMake(0,-41,1920,41);
    assert(ordinaryChromeCrossDisplayPairGeometry(builtin,display,root,aligned,displaced));
    assert(!ordinaryChromeCrossDisplayPairGeometry(builtin,display,root,aligned,
        CGRectMake(-1920,-41,1920,41)));
    assert(!ordinaryChromeCrossDisplayPairGeometry(builtin,display,root,aligned,
        CGRectMake(0,-41,1920,129)));
    assert(!ordinaryChromeCrossDisplayPairGeometry(builtin,display,
        CGRectMake(-3840,30,1920,900),aligned,displaced));
    assert(!ordinaryChromeCrossDisplayPairGeometry(builtin,display,root,
        CGRectMake(-3840,-47,1000,47),displaced));
    assert(!ordinaryChromeCrossDisplayPairGeometry(builtin,display,root,aligned,
        CGRectMake(0,0,1920,41)));
    assert(!ordinaryChromeCrossDisplayPairGeometry(CGRectMake(0,-50,1147,795),display,
        root,aligned,displaced));
    NSString *windowNumber=(__bridge NSString *)kCGWindowNumber;
    NSArray *otherVisible=@[@{windowNumber:@(7)}];
    assert(ordinaryChromePairAbsentFromOnscreenInventory(otherVisible,149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(
        @[@{windowNumber:@(149)}],149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(
        @[@{windowNumber:@(150)}],149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(nil,149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(@[],149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(@[@{}],149,150));
    assert(!ordinaryChromePairAbsentFromOnscreenInventory(otherVisible,149,149));

    puts("ordinary Finder child and Chrome contained/edge companion gates passed");
}}
