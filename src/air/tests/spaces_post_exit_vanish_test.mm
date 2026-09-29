#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
#include <spawn.h>
#include <sys/wait.h>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    const uint32_t candidate=10493;
    id key=(__bridge id)kCGWindowNumber;
    NSArray *other=@[@{key:@(6129)},@{key:@(10491)}];
    NSArray *present=@[@{key:@(6129)},@{key:@(candidate)}];
    assert(absentFromCompleteWindowInventory(other,@[],candidate));
    assert(!absentFromCompleteWindowInventory(present,@[],candidate));
    assert(!absentFromCompleteWindowInventory(other,@[@(388)],candidate));
    assert(!absentFromCompleteWindowInventory(nil,@[],candidate));
    assert(!absentFromCompleteWindowInventory(other,nil,candidate));
    assert(!absentFromCompleteWindowInventory(other,@[],0));
    assert(departedSnapshotSample(other,@[],candidate));
    assert(!departedSnapshotSample(present,@[],candidate));
    assert(!departedSnapshotSample(other,@[@(388)],candidate));
    assert(!departedSnapshotSample(nil,@[],candidate));
    assert(logicalSlotForNativeIndex(0,true)==3);
    assert(logicalSlotForNativeIndex(1,true)==2);
    assert(logicalSlotForNativeIndex(2,true)==1);
    assert(nativeIndexForLogicalSlot(1,true)==2);
    assert(nativeIndexForLogicalSlot(2,true)==1);
    assert(nativeIndexForLogicalSlot(3,true)==0);
    assert(logicalSlotForNativeIndex(0,false)==1);
    TextKitAgentSurfaceEvidence textKit={true,true,true,true,true,true,true,
        true,true,true,true,true,true,true};
    assert(textKitAgentSurfaceDecision(textKit));
    textKit.zeroMembership=false;
    assert(!textKitAgentSurfaceDecision(textKit));
    textKit.zeroMembership=true;textKit.zeroFrame=false;
    assert(!textKitAgentSurfaceDecision(textKit));
    textKit.zeroFrame=true;textKit.signedSystemProcess=false;
    assert(!textKitAgentSurfaceDecision(textKit));
    char command[]="/bin/sleep",seconds[]="10";
    char *arguments[]={command,seconds,nullptr};
    pid_t child=0;
    assert(posix_spawn(&child,command,nullptr,nullptr,arguments,nullptr)==0);
    ProcessBirth birth=processBirth(child);
    assert(birth.valid());
    assert(![NSRunningApplication runningApplicationWithProcessIdentifier:child]);
    SavedWindow dialog={candidate,child,"air.test.axdialog","fixture",
        CGRectMake(0,0,300,200),CGRectMake(0,0,1000,800),1,42,0,"builtin",true};
    dialog.axDialog=true;dialog.birthSeconds=birth.seconds;
    dialog.birthMicroseconds=birth.microseconds;dialog.memberships={42};
    assert(windowState(dialog)==WindowState::AXUnavailable);
    assert(kill(child,SIGTERM)==0);
    int status=0;assert(waitpid(child,&status,0)==child);
    assert(windowState(dialog)==WindowState::Gone);
    puts("post-exit disappearance and same-birth AX dialog fail-closed checks passed");
} }
