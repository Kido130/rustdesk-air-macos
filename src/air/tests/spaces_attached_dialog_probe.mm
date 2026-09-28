#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static bool capture(pid_t pid,uint32_t parentID,uint32_t childID,int cid,
                    CGRect *parent,CGRect *child,uint64_t *space,std::string *display) {
    AXUIElementRef parentAX=findAXWindow(pid,parentID);
    AXUIElementRef childAX=findAXWindow(pid,childID);
    bool known=false;
    uint32_t linked=exactWindowParent(cid,childID,&known);
    CGRect parentCG={},childCG={};
    NSArray *parentMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
        (__bridge CFArrayRef)@[@(parentID)]));
    NSArray *childMembership=CFBridgingRelease(api().windowSpaces(cid,0x7,
        (__bridge CFArrayRef)@[@(childID)]));
    NSString *parentDisplay=CFBridgingRelease(api().windowDisplay(cid,parentID));
    NSString *childDisplay=CFBridgingRelease(api().windowDisplay(cid,childID));
    uint32_t policyParent=0;CGPoint policyOffset={};
    bool productionPolicy=childAX && inspectAttachedFollower(childID,pid,cid,childAX,
        &policyParent,&policyOffset) && policyParent==parentID;
    bool okay=parentAX && known && linked==parentID
        && parentMembership.count==1 && childMembership.count==1
        && [parentMembership[0] isEqual:childMembership[0]]
        && parentDisplay.length && [parentDisplay isEqual:childDisplay]
        && readAXFrame(parentAX,parent)
        && readCGFrame(parentID,pid,&parentCG) && readCGFrame(childID,pid,&childCG)
        && nearFrame(*parent,parentCG);
    if(okay) {
        *child=childCG;
        if(childAX) {CGRect childFrame={};okay=readAXFrame(childAX,&childFrame)
            && nearFrame(childFrame,childCG);}
    }
    if(okay) {
        *space=[number(parentMembership[0]) unsignedLongLongValue];
        *display=parentDisplay.UTF8String;
    }
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    printf("snapshot linked=%d parent=%u child=%u same_space=%d same_display=%d "
        "ax_parent=%d ax_child=%d policy=%d bundle=%s role_parent=%s subrole_child=%s\n",
        known,linked,childID,parentMembership.count==1 && childMembership.count==1
            && [parentMembership[0] isEqual:childMembership[0]],
        parentDisplay.length && [parentDisplay isEqual:childDisplay],
        parentAX!=nullptr,childAX!=nullptr,productionPolicy,
        app.bundleIdentifier.UTF8String ?: "none",
        parentAX ? [axAttribute(parentAX,kAXRoleAttribute) description].UTF8String : "none",
        childAX ? [axAttribute(childAX,kAXSubroleAttribute) description].UTF8String : "none");
    if(parentAX)CFRelease(parentAX);
    if(childAX)CFRelease(childAX);
    return okay;
}

static bool moveParent(pid_t pid,uint32_t wid,CGPoint destination) {
    AXUIElementRef ax=findAXWindow(pid,wid);
    if(!ax)return false;
    AXValueRef value=AXValueCreate(kAXValueTypeCGPoint,&destination);
    AXError status=AXUIElementSetAttributeValue(ax,kAXPositionAttribute,value);
    CFRelease(value);CFRelease(ax);
    return status==kAXErrorSuccess;
}
static bool denyFollowerSet(const SavedWindow &,CGPoint) { return false; }
static bool observedFrame(pid_t pid,uint32_t wid,CGRect expected) {
    AXUIElementRef ax=findAXWindow(pid,wid);CGRect axFrame={},cgFrame={};
    bool okay=ax && readAXFrame(ax,&axFrame) && readCGFrame(wid,pid,&cgFrame)
        && nearFrame(axFrame,expected) && nearFrame(cgFrame,expected);
    if(ax)CFRelease(ax);
    return okay;
}
static int exerciseChildRecovery(pid_t pid,uint32_t parentID,uint32_t childID,int cid,
                                 CGRect parentFrame,CGRect childFrame,uint64_t sid,
                                 const std::string &displayUUID) {
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    ProcessBirth birth=processBirth(pid);double launch=stableLaunchTime(app,pid);
    bool found=false;CGRect display=boundsForDisplayUUID(displayUUID,&found);
    if(!app.bundleIdentifier.length || !birth.valid() || launch<=0 || !found)return 10;
    SavedWindow root={parentID,pid,app.bundleIdentifier.UTF8String,"fixture root",
        parentFrame,display,launch,sid,0,displayUUID,true};
    root.birthSeconds=birth.seconds;root.birthMicroseconds=birth.microseconds;
    root.memberships={sid};
    SavedWindow follower={childID,pid,app.bundleIdentifier.UTF8String,"fixture child",
        childFrame,display,launch,sid,0,displayUUID,true};
    follower.birthSeconds=birth.seconds;follower.birthMicroseconds=birth.microseconds;
    follower.memberships={sid};follower.followerParent=parentID;
    follower.followerOffset=CGPointMake(childFrame.origin.x-parentFrame.origin.x,
        childFrame.origin.y-parentFrame.origin.y);
    saved={root,follower};wholeFrameInventoryComplete=true;
    if(!exactJournaledAttachedFollower(follower) || setFrame(follower,childFrame))return 11;
    CGRect moved=CGRectOffset(childFrame,24,18);
    if(!moveParent(pid,childID,moved.origin))return 12;
    bool displaced=false;
    for(int retry=0;retry<20;retry++) {
        if(observedFrame(pid,childID,moved)){displaced=true;break;}
        usleep(25000);
    }
    if(!displaced || exactJournaledAttachedFollower(follower))return 13;
    auto rejectedWithoutMove=[&](SavedWindow altered) {
        return !restoreAttachedFollowerFrame(altered,cid)
            && observedFrame(pid,childID,moved);
    };
    SavedWindow invalid=follower;invalid.followerParent=parentID+999;
    bool wrongParent=rejectedWithoutMove(invalid);
    invalid=follower;invalid.memberships={sid+999};
    bool wrongSpace=rejectedWithoutMove(invalid);
    invalid=follower;invalid.sourceUUID="not-the-original-display";
    bool wrongDisplay=rejectedWithoutMove(invalid);
    RecoveryHooks hooks={};hooks.setAttachedFollowerPosition=denyFollowerSet;
    recoveryHooks=&hooks;
    bool failedSet=rejectedWithoutMove(follower);
    recoveryHooks=nullptr;
    std::string reason;
    bool restored=restoreWholeWindowFrames(cid,reason)
        && observedFrame(pid,childID,childFrame)
        && exactJournaledAttachedFollower(follower)
        && observedFrame(pid,parentID,parentFrame);
    printf("attached_child_recovery displaced=%d wrong_parent=%d wrong_space=%d "
        "wrong_display=%d denied_set=%d restored=%d reason=%s\n",
        displaced,wrongParent,wrongSpace,wrongDisplay,failedSet,restored,reason.c_str());
    saved.clear();wholeFrameInventoryComplete=false;
    return wrongParent && wrongSpace && wrongDisplay && failedSet && restored ? 0 : 14;
}

int main(int argc,char **argv) { @autoreleasepool {
    bool childRecovery=argc==5 && strcmp(argv[1],"--own-fixture-child-recovery")==0;
    if(argc!=5 || (!childRecovery && strcmp(argv[1],"--own-fixture")!=0))return 2;
    pid_t pid=atoi(argv[2]);uint32_t parentID=atoi(argv[3]),childID=atoi(argv[4]);
    if(pid<=0 || !parentID || !childID || !api().conn || !api().windowSpaces
        || !api().windowDisplay || !api().axWindow)return 3;
    int cid=api().conn();CGRect p0={},c0={};uint64_t s0=0;std::string d0;
    if(!capture(pid,parentID,childID,cid,&p0,&c0,&s0,&d0))return 4;
    if(childRecovery)return exerciseChildRecovery(pid,parentID,childID,cid,p0,c0,s0,d0);
    CGPoint target=CGPointMake(p0.origin.x+24,p0.origin.y+18);
    if(!moveParent(pid,parentID,target))return 5;
    CGRect pm={},cm={};uint64_t sm=0;std::string dm;
    bool moved=false;
    for(int n=0;n<20;n++) {
        if(capture(pid,parentID,childID,cid,&pm,&cm,&sm,&dm)
            && nearFrame(pm,CGRectMake(target.x,target.y,p0.size.width,p0.size.height))) {
            moved=true;break;
        }
        usleep(25000);
    }
    bool follower=moved && nearFrame(cm,CGRectOffset(c0,pm.origin.x-p0.origin.x,
        pm.origin.y-p0.origin.y)) && sm==s0 && dm==d0;
    bool restoreRequest=moveParent(pid,parentID,p0.origin);
    CGRect pr={},cr={};uint64_t sr=0;std::string dr;bool restored=false;
    for(int n=0;n<20 && restoreRequest;n++) {
        if(capture(pid,parentID,childID,cid,&pr,&cr,&sr,&dr)
            && nearFrame(pr,p0) && nearFrame(cr,c0) && sr==s0 && dr==d0) {
            restored=true;break;
        }
        usleep(25000);
    }
    printf("attached_parent_probe moved=%d child_followed=%d restored=%d "
        "delta_parent=%.0f,%.0f delta_child=%.0f,%.0f\n",moved,follower,restored,
        pm.origin.x-p0.origin.x,pm.origin.y-p0.origin.y,
        cm.origin.x-c0.origin.x,cm.origin.y-c0.origin.y);
    return restored ? (follower ? 0 : 7) : 6;
} }
