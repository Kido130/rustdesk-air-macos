#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore() { return 0; }

SavedWindow window(uint32_t id,pid_t pid,uint64_t birth) {
    SavedWindow result={};
    result.id=id;result.pid=pid;result.birthSeconds=birth;
    result.birthMicroseconds=123;result.bundle="example.app";
    result.frame=CGRectMake(50,50,400,300);
    result.sourceDisplay=CGRectMake(0,0,1920,1080);
    result.space=1234;result.sourceUUID="display";
    result.launchTime=double(birth)+0.000123;
    return result;
}
WholeFrameBlocker blocker(uint32_t id,pid_t pid,uint64_t birth,const char *kind) {
    WholeFrameBlocker result;
    result.id=id;result.pid=pid;result.birth={birth,123};
    result.space=1234;result.frame=CGRectMake(50,50,1,1);
    result.kind=kind;
    return result;
}
int main() { @autoreleasepool {
    std::vector<SavedWindow> result;std::string why;
    unsigned samples=0,pauses=0,vanishChecks=0;
    bool passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &out,std::string &reason,WholeFrameBlocker *bad) {
            samples++;
            if(samples==1) {
                *bad=blocker(100,10,111,"tiny");
                reason="too small";return false;
            }
            out={window(200,20,222)};return true;
        },
        [&](uint32_t id) { vanishChecks++;return id==100; },
        [&](unsigned) { pauses++; },result,why);
    assert(passed && result.size()==1 && result[0].id==200);
    assert(why.empty() && samples==3 && pauses==2 && vanishChecks==1);

    result.clear();why.clear();samples=pauses=vanishChecks=0;
    passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &out,std::string &reason,WholeFrameBlocker *bad) {
            samples++;
            if(samples==1) {
                *bad=blocker(100,10,111,"unclassified");
                reason="unclassified";return false;
            }
            out={window(100,10,111)};return true;
        },
        [&](uint32_t) { vanishChecks++;return false; },
        [&](unsigned) { pauses++; },result,why);
    assert(passed && result.size()==1 && result[0].id==100);
    assert(samples==3 && pauses==2 && vanishChecks==0);

    result.clear();why.clear();samples=pauses=vanishChecks=0;
    passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &out,std::string &reason,WholeFrameBlocker *bad) {
            samples++;
            if(samples==1) {
                *bad=blocker(100,10,111,"tiny");
                reason="too small";return false;
            }
            out={window(200,20,222)};return true;
        },
        [&](uint32_t) { vanishChecks++;return false; },
        [&](unsigned) { pauses++; },result,why);
    assert(!passed && result.empty() && vanishChecks==1);
    assert(why=="a previously ambiguous desktop window remains outside the frame journal");

    result.clear();why.clear();samples=pauses=vanishChecks=0;
    passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &,std::string &reason,WholeFrameBlocker *bad) {
            samples++;*bad=blocker(100,10,111,"tiny");
            reason="too small";return false;
        },
        [&](uint32_t) { vanishChecks++;return true; },
        [&](unsigned) { pauses++; },result,why);
    assert(!passed && result.empty() && samples==4 && pauses==3 && vanishChecks==0);
    assert(why=="too small");

    result.clear();why.clear();samples=pauses=vanishChecks=0;
    passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &,std::string &reason,WholeFrameBlocker *) {
            samples++;reason="membership unreadable";return false;
        },
        [&](uint32_t) { vanishChecks++;return true; },
        [&](unsigned) { pauses++; },result,why);
    assert(!passed && result.empty() && samples==1 && pauses==0 && vanishChecks==0);

    result.clear();why.clear();samples=pauses=vanishChecks=0;
    passed=captureWholeFrameLedgerWithRetry(
        [&](std::vector<SavedWindow> &out,std::string &reason,WholeFrameBlocker *bad) {
            samples++;
            if(samples==1) {
                *bad=blocker(100,10,111,"unclassified");
                reason="unclassified";return false;
            }
            // The WID reappeared with a different process birth.  It must
            // not satisfy the original rejected identity.
            out={window(100,10,333)};return true;
        },
        [&](uint32_t) { vanishChecks++;return false; },
        [&](unsigned) { pauses++; },result,why);
    assert(!passed && result.empty() && vanishChecks==1);

    puts("whole-frame retry: disappearance, exact recovery, persistent blocker, unreadable membership and reused WID guards passed");
} }
