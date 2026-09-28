#define main fullscreen_fixture_main
#include "spaces_fullscreen_own_window_fixture.mm"
#undef main
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <fcntl.h>

static NSArray *processBirth(pid_t pid) {
    struct proc_bsdinfo info={};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return nil;
    return @[@(info.pbi_start_tvsec),@(info.pbi_start_tvusec)];
}
static bool ownerMatches(pid_t pid,uint32_t wid) {
    if(!sameFixtureBinary(pid))return false;
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    for(NSDictionary *window in all)
        if([window[(id)kCGWindowNumber] unsignedIntValue]==wid
            && [window[(id)kCGWindowOwnerPID] intValue]==pid)return true;
    return false;
}
static uint64_t currentFor(NSString *uuid) {
    return [managedDisplay(uuid)[@"Current Space"][@"id64"] unsignedLongLongValue];
}
static bool bridgeTo(NSString *uuid,uint64_t sid) {
    Class cls=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    if(!cls || ![cls instancesRespondToSelector:@selector(initWithDisplayIdentifier:spaceID:)]
        || ![cls instancesRespondToSelector:@selector(performWithWMBridgeDelegate)])return false;
    id operation=[[cls alloc] initWithDisplayIdentifier:uuid spaceID:sid];
    if(!operation)return false;
    [operation performWithWMBridgeDelegate];
    for(int i=0;i<80;i++){usleep(25000);if(currentFor(uuid)==sid)return true;}
    return false;
}
static bool validObservation(NSDictionary *record) {
    pid_t pid=[record[@"pid"] intValue];uint32_t wid=[record[@"wid"] unsignedIntValue];
    NSDictionary *members=record[@"membership"];
    NSString *uuid=members[@"display_uuid"];
    if(!ownerMatches(pid,wid) || ![processBirth(pid) isEqual:record[@"birth"]]
        || ![members isEqual:membership(wid)] || [members[@"ids"] count]!=1
        || ![members[@"types"] isEqual:@[@4]] || ![uuid isKindOfClass:NSString.class])return false;
    bool external=false,anchor=false;
    for(NSScreen *screen in NSScreen.screens){
        uint32_t did=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef id=CGDisplayCreateUUIDFromDisplayID(did);
        NSString *name=id ? CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault,id)) : nil;
        if(id)CFRelease(id);
        if([name isEqual:uuid]&&!CGDisplayIsBuiltin(did))external=true;
    }
    for(NSDictionary *space in managedDisplay(uuid)[@"Spaces"])
        if([space[@"id64"] isEqual:record[@"anchor"]]&&[space[@"type"] intValue]==0)anchor=true;
    uint64_t current=currentFor(uuid);
    return external&&anchor&&(current==[record[@"anchor"] unsignedLongLongValue]
        || current==[members[@"ids"][0] unsignedLongLongValue]);
}
static bool saveObservation(const char *path,NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return false;
    bool okay=data&&write(fd,data.bytes,data.length)==(ssize_t)data.length&&fsync(fd)==0;
    close(fd);if(!okay)unlink(path);return okay;
}
static NSDictionary *readObservation(const char *path) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW);if(fd<0)return nil;
    struct stat st={};
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600
        ||st.st_size<2||st.st_size>4096){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:st.st_size];
    bool okay=read(fd,data.mutableBytes,data.length)==(ssize_t)data.length;close(fd);
    id record=okay ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}
static int recoverObservation(const char *path) {
    NSDictionary *record=readObservation(path);
    if(!record||!validObservation(record))return 20;
    NSString *uuid=record[@"membership"][@"display_uuid"];
    uint64_t anchor=[record[@"anchor"] unsignedLongLongValue];
    if(currentFor(uuid)!=anchor && !bridgeTo(uuid,anchor))return 21;
    if(!validObservation(record)||currentFor(uuid)!=anchor)return 22;
    emit(@{@"phase":@"observation_recovered",@"record":record,@"current":@(currentFor(uuid))});
    return unlink(path)==0 ? 0 : 23;
}
static int observe(pid_t pid,uint32_t wid,uint64_t anchor,const char *path,const char *mode) {
    NSArray *birth=processBirth(pid);NSDictionary *members=membership(wid);
    if(!birth)return 10;
    NSDictionary *record=@{@"pid":@(pid),@"wid":@(wid),@"birth":birth,
        @"anchor":@(anchor),@"membership":members};
    if(!validObservation(record)||currentFor(members[@"display_uuid"])!=anchor)return 11;
    if(!saveObservation(path,record))return 12;
    emit(@{@"phase":@"observation_journaled",@"record":record,@"ax_before":axSnapshot(pid)});
    if(strcmp(mode,"crash-before")==0)_exit(75);
    if(!validObservation(record)||!bridgeTo(members[@"display_uuid"],[members[@"ids"][0] unsignedLongLongValue]))return 13;
    if(strcmp(mode,"crash-after")==0)_exit(76);
    bool identified=false;
    for(int i=0;i<40;i++){
        NSDictionary *snapshot=axSnapshot(pid);
        if([snapshot[@"window_id"] unsignedIntValue]==wid
            &&[snapshot[@"identifier"] isEqual:fixtureIdentifier]
            &&[snapshot[@"ax_fullscreen"] isEqual:@YES]&&[snapshot[@"settable"] isEqual:@YES]){
            emit(@{@"phase":@"hidden_ax_reacquired",@"snapshot":snapshot});identified=true;break;
        }
        usleep(50000);
    }
    int restored=recoverObservation(path);
    return restored ? restored : (identified ? 0 : 14);
}
int main(int argc,char **argv){ @autoreleasepool {
    if(argc==3&&strcmp(argv[1],"--recover-observation")==0)return recoverObservation(argv[2]);
    if(argc==7&&strcmp(argv[1],"--observe")==0)
        return observe((pid_t)strtol(argv[2],nullptr,10),(uint32_t)strtoul(argv[3],nullptr,10),
            strtoull(argv[4],nullptr,10),argv[5],argv[6]);
    return fullscreen_fixture_main(argc,argv);
} }
