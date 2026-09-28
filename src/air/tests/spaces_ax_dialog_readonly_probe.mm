#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

static void surfaceSnapshot(const char *stage,uint32_t wid,int cid) {
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    NSArray *onScreen=CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    NSDictionary *found=nil;unsigned count=0,visible=0;
    for(NSDictionary *item in all)if([number(item[(id)kCGWindowNumber]) unsignedIntValue]==wid) {
        found=item;count++;
    }
    for(NSDictionary *item in onScreen)
        if([number(item[(id)kCGWindowNumber]) unsignedIntValue]==wid)visible++;
    NSArray *members=CFBridgingRelease(api().windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
    uint64_t tags=0;bool tagsKnown=exactWindowTags(cid,wid,&tags);
    CGRect bounds={};NSDictionary *rawBounds=dictionary(found[(id)kCGWindowBounds]);
    bool boundsKnown=rawBounds && CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)rawBounds,&bounds);
    printf("own_surface_%s cg=%u onscreen=%u layer=%d alpha=%.6f bounds=%d/%.0f,%.0f,%.0f,%.0f members=%s tags=%d/0x%llx\n",
        stage,count,visible,[number(found[(id)kCGWindowLayer]) intValue],
        [number(found[(id)kCGWindowAlpha]) doubleValue],boundsKnown,
        bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,
        [members description].UTF8String,tagsKnown,(unsigned long long)tags);
}

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4 || (strcmp(argv[1],"--read-only")!=0
        && strcmp(argv[1],"--own-window-restore")!=0
        && strcmp(argv[1],"--own-window-recovery")!=0
        && strcmp(argv[1],"--own-window-gone")!=0))return 2;
    bool ownRecovery=strcmp(argv[1],"--own-window-recovery")==0;
    bool ownGone=strcmp(argv[1],"--own-window-gone")==0;
    bool ownRestore=ownRecovery || ownGone || strcmp(argv[1],"--own-window-restore")==0;
    pid_t pid=atoi(argv[2]);uint32_t wid=(uint32_t)atoi(argv[3]);
    AXUIElementRef ax=findAXWindow(pid,wid);
    if(!ax)return 3;
    id role=axAttribute(ax,kAXRoleAttribute),subrole=axAttribute(ax,kAXSubroleAttribute);
    id modal=axAttribute(ax,CFSTR("AXModal"));
    Boolean position=false,size=false;
    AXError positionStatus=AXUIElementIsAttributeSettable(ax,kAXPositionAttribute,&position);
    AXError sizeStatus=AXUIElementIsAttributeSettable(ax,kAXSizeAttribute,&size);
    CGRect frame={};bool framed=readAXFrame(ax,&frame);
    CFTypeRef parentRaw=nullptr;AXError parentStatus=AXUIElementCopyAttributeValue(ax,kAXParentAttribute,&parentRaw);
    NSString *parentRole=nil;CGWindowID parentWid=0;
    if(parentStatus==kAXErrorSuccess && parentRaw && CFGetTypeID(parentRaw)==AXUIElementGetTypeID()) {
        parentRole=axAttribute((AXUIElementRef)parentRaw,kAXRoleAttribute);
        api().axWindow((AXUIElementRef)parentRaw,&parentWid);
    }
    if(parentRaw)CFRelease(parentRaw);
    bool cgParentKnown=false;uint32_t cgParent=exactWindowParent(api().conn(),wid,&cgParentKnown);
    printf("wid=%u role=%s subrole=%s modal=%s position=%d/%d size=%d/%d frame=%d parent=%d/%s/%u cgParent=%d/%u exact_root=%d mutations=0\n",
        wid,[role description].UTF8String,[subrole description].UTF8String,[modal description].UTF8String,
        positionStatus,position,sizeStatus,size,framed,parentStatus,
        [parentRole description].UTF8String,parentWid,cgParentKnown,cgParent,
        exactRootAXDialog(ax,wid,pid,api().conn()));
    if(ownRestore) {
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSDictionary *info=windowLayerDescription(wid);
        NSString *title=info[(id)kCGWindowName];
        if(![app.bundleIdentifier isEqual:@"air.test.axdialog"]
            || ![title isEqual:@"Own dialog fixture"]
            || ![role isEqual:(__bridge NSString *)kAXWindowRole]
            || ![subrole isEqual:@"AXDialog"] || ![modal isEqual:@NO]
            || positionStatus!=kAXErrorSuccess || !position
            || sizeStatus!=kAXErrorSuccess || !size || !framed
            || parentStatus!=kAXErrorSuccess || ![parentRole isEqual:(__bridge NSString *)kAXApplicationRole]
            || parentWid!=0 || !cgParentKnown || cgParent!=0) {CFRelease(ax);return 4;}
        ProcessBirth birth=processBirth(pid);double launch=stableLaunchTime(app,pid);
        NSArray *members=CFBridgingRelease(api().windowSpaces(api().conn(),0x7,(__bridge CFArrayRef)@[@(wid)]));
        NSString *display=CFBridgingRelease(api().windowDisplay(api().conn(),wid));
        if(!birth.valid() || launch<=0 || members.count!=1 || !display.length) {CFRelease(ax);return 5;}
        uint64_t sid=[number(members[0]) unsignedLongLongValue];
        bool boundsFound=false;
        CGRect displayBounds=boundsForDisplayUUID(display.UTF8String,&boundsFound);
        if(!boundsFound) {CFRelease(ax);return 5;}
        SavedWindow w={wid,pid,app.bundleIdentifier.UTF8String,title.UTF8String,frame,
            displayBounds,launch,sid,0,display.UTF8String,true};
        w.birthSeconds=birth.seconds;w.birthMicroseconds=birth.microseconds;w.memberships={sid};
        w.axDialog=true;
        SpaceType savedSpaceType=api().spaceType;
        api().spaceType=nullptr;
        bool missingSpaceTypeRejected=!exactJournaledAXDialog(w);
        api().spaceType=savedSpaceType;
        if(!missingSpaceTypeRejected) {CFRelease(ax);return 22;}
        if(windowState(w)!=WindowState::Ready) {CFRelease(ax);return 6;}
        CGRect moved=CGRectMake(frame.origin.x+24,frame.origin.y+24,
            frame.size.width+20,frame.size.height+10);
        bool movedOkay=setFrame(w,moved);CGRect observed={};
        bool atTarget=movedOkay && readAXFrame(ax,&observed) && nearFrame(observed,moved);
        bool restoreOkay=setFrame(w,frame);CGRect restored={};
        bool atOriginal=restoreOkay && readAXFrame(ax,&restored) && nearFrame(restored,frame);
        printf("own_ax_dialog_move_restore moved=%d at_target=%d restored=%d at_original=%d\n",
            movedOkay,atTarget,restoreOkay,atOriginal);
        if(!movedOkay || !atTarget || !restoreOkay || !atOriginal) {CFRelease(ax);return 7;}
        if(ownRecovery || ownGone) {
            char path[]="/tmp/air-axdialog-journal-XXXXXX";
            if(!mkdtemp(path)) {CFRelease(ax);return 8;}
            NSString *folder=[NSString stringWithUTF8String:path];
            journalTestPath=[folder stringByAppendingPathComponent:@"recovery.json"];
            air::whole_space::Topology topology={{{display.UTF8String,{sid,800001,800002},
                {"builtin-space","parking-a","parking-b"},sid},
                {"fixture-external-a",{700001},{"external-a"},700001},
                {"fixture-external-b",{700002},{"external-b"},700002}}};
            std::string why;
            bool prepared=air::whole_space::initialize(wholeJournal,topology,display.UTF8String,
                800001,800002,"parking-a","parking-b",[](uint64_t){return 0;},&why);
            if(!prepared) {CFRelease(ax);return 9;}
            builtinUUID=display.UTF8String;initialSpace=sid;lastSelectedSpace=sid;
            createdSpaces={800001,800002};
            ownedSpaces={{800001,"parking-a",builtinUUID},{800002,"parking-b",builtinUUID}};
            saved={w};wholeFrameInventoryComplete=true;
            if(!persist()) {CFRelease(ax);return 10;}
            NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:
                [NSData dataWithContentsOfFile:journalTestPath] options:0 error:nil];
            if([number(journal[@"version"]) intValue]!=18) {CFRelease(ax);return 11;}
            NSMutableDictionary *bad=[journal mutableCopy];
            NSMutableArray *windows=[journal[@"windows"] mutableCopy];
            NSMutableDictionary *entry=[windows[0] mutableCopy];
            entry[@"memberships"]=@[@(sid),@700001];windows[0]=entry;bad[@"windows"]=windows;
            if(parseJournal(bad)) {CFRelease(ax);return 12;}
            entry=[journal[@"windows"][0] mutableCopy];
            [entry removeObjectForKey:@"axDialog"];
            windows=[journal[@"windows"] mutableCopy];windows[0]=entry;bad[@"windows"]=windows;
            if(parseJournal(bad)) {CFRelease(ax);return 13;}
            if(ownGone) {
                surfaceSnapshot("open",wid,api().conn());
                NSString *closeSignal=[NSString stringWithFormat:@"/private/tmp/air-ax-dialog-close-%d",pid];
                int signalFD=open(closeSignal.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
                if(signalFD<0) {CFRelease(ax);return 17;}
                close(signalFD);
                WindowState closed=WindowState::AXUnavailable;
                for(int retry=0;retry<40;retry++) {
                    closed=windowState(w);
                    if(closed==WindowState::Gone)break;
                    usleep(50000);
                }
                surfaceSnapshot("closed",wid,api().conn());
                if(!sameProcess(w) || ![[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]) {
                    CFRelease(ax);return 18;
                }
                if(closed==WindowState::AXUnavailable) {
                    // AppKit can retain a closed panel's SkyLight WID. Its
                    // journal must stay until exact disappearance is proved.
                    DormantAXInventory inventory=readDormantAXInventory(pid);
                    if(!inventory.readable || !inventory.complete || inventory.windows.count(wid)
                        || ::vanishedCompleteInventoryWindow(wid,api().conn(),nullptr)) {
                        CFRelease(ax);return 18;
                    }
                    printf("own_ax_dialog_closed_retained journal_retained=1\n");
                    if(kill(pid,SIGTERM)!=0) {CFRelease(ax);return 20;}
                    bool gone=false;
                    for(int retry=0;retry<40;retry++) {
                        if(windowState(w)==WindowState::Gone
                            && ::vanishedCompleteInventoryWindow(wid,api().conn(),nullptr)) {
                            gone=true;break;
                        }
                        usleep(50000);
                    }
                    if(!gone) {CFRelease(ax);return 21;}
                    surfaceSnapshot("owner_exited",wid,api().conn());
                } else if(closed!=WindowState::Gone) {
                    CFRelease(ax);return 18;
                }
                saved.clear();wholeJournal={};wholeFrameInventoryComplete=false;
                if(!loadJournal() || saved.size()!=1 || !saved[0].axDialog
                    || !restoreWholeWindowFrames(api().conn(),why)
                    || !clearJournal()
                    || [[NSFileManager defaultManager] fileExistsAtPath:journalTestPath]) {
                    CFRelease(ax);return 19;
                }
                printf("own_ax_dialog_closed_recovery retained_until_exact_gone=1 journal_cleared=1\n");
                journalTestPath=nil;
                [[NSFileManager defaultManager] removeItemAtPath:folder error:nil];
                CFRelease(ax);return 0;
            }
            if(!setFrame(w,moved)) {CFRelease(ax);return 14;}
            saved.clear();wholeJournal={};wholeFrameInventoryComplete=false;
            if(!loadJournal() || saved.size()!=1 || !saved[0].axDialog
                || !restoreWholeWindowFrames(api().conn(),why)) {CFRelease(ax);return 15;}
            CGRect recovered={};bool exact=readAXFrame(ax,&recovered) && nearFrame(recovered,frame);
            printf("own_ax_dialog_interrupted_recovery journal_v18=1 rejected_sticky=1 rejected_missing_marker=1 restored=%d\n",exact);
            journalTestPath=nil;
            [[NSFileManager defaultManager] removeItemAtPath:folder error:nil];
            CFRelease(ax);return exact ? 0 : 16;
        }
        CFRelease(ax);return 0;
    }
    CFRelease(ax);return 0;
} }
