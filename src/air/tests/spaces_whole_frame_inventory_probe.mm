#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 || strcmp(argv[1],"--read-only")!=0)return 2;
    Api &a=api();
    NSMutableDictionary *report=[@{@"source":@"spaces.mm whole frame inventory",
        @"mutations":@0} mutableCopy];
    if(!a.conn || !a.managed || !a.spaceType || !a.spaceWindows || !a.windowSpaces
        || !a.windowDisplay || !a.axWindow) {
        report[@"error"]=@"required inspection API unavailable";
    } else {
        int cid=a.conn();
        CGDirectDisplayID ids[32];uint32_t count=0;
        NSMutableArray *order=[NSMutableArray array];
        if(CGGetOnlineDisplayList(32,ids,&count)==kCGErrorSuccess) {
            for(uint32_t index=0;index<count;index++)if(CGDisplayIsBuiltin(ids[index])) {
                NSString *uuid=displayUUID(ids[index]);if(uuid)[order addObject:uuid];
            }
            for(uint32_t index=0;index<count;index++)if(!CGDisplayIsBuiltin(ids[index])) {
                NSString *uuid=displayUUID(ids[index]);if(uuid)[order addObject:uuid];
            }
        }
        std::vector<std::string> displayOrder;
        for(NSString *uuid in order)displayOrder.push_back(uuid.UTF8String);
        air::whole_space::Topology topology;
        bool complete=displayOrder.size()==3 && wholeTopology(managed(),displayOrder,topology);
        report[@"topology_complete"]=@(complete);
        NSMutableArray *multiple=[NSMutableArray array];
        NSMutableArray *unreadable=[NSMutableArray array];
        NSMutableArray *nonordinary=[NSMutableArray array];
        NSArray *rows=completeWindowInventory(managed(),cid);
        report[@"cg_inventory_complete"]=@(rows!=nil);
        for(NSDictionary *info in rows) {
            if([number(info[(id)kCGWindowLayer]) intValue]!=0)continue;
            uint32_t wid=[number(info[(id)kCGWindowNumber]) unsignedIntValue];
            pid_t pid=[number(info[(id)kCGWindowOwnerPID]) intValue];
            if(!wid || !pid || pid==getpid())continue;
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if(systemChrome(app.bundleIdentifier))continue;
            NSArray *members=CFBridgingRelease(a.windowSpaces(cid,0x7,(__bridge CFArrayRef)@[@(wid)]));
            if(!members) {[unreadable addObject:@{@"wid":@(wid),@"pid":@(pid)}];continue;}
            if(members.count>1) {
                NSMutableArray *spaces=[NSMutableArray array];
                for(id member in members)if(number(member))[spaces addObject:member];
                [multiple addObject:@{@"wid":@(wid),@"pid":@(pid),
                    @"bundle":app.bundleIdentifier?:NSNull.null,@"spaces":spaces}];
            } else if(members.count==1) {
                uint64_t sid=[number(members[0]) unsignedLongLongValue];
                int type=sid ? a.spaceType(cid,sid) : -1;
                if(type!=0)[nonordinary addObject:@{@"wid":@(wid),@"pid":@(pid),
                    @"bundle":app.bundleIdentifier?:NSNull.null,@"sid":@(sid),
                    @"type":@(type)}];
            }
        }
        report[@"multiple_membership_windows"]=multiple;
        report[@"unreadable_membership_windows"]=unreadable;
        report[@"nonordinary_windows"]=nonordinary;
        if(complete) {
            std::vector<SavedWindow> ledger;std::string why;
            bool captured=captureWholeFrameLedger(topology,cid,ledger,why);
            report[@"frame_ledger_ready"]=@(captured);
            report[@"frame_ledger_reason"]=[NSString stringWithUTF8String:why.c_str()];
            report[@"captured_windows"]=@(ledger.size());
        }
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    if(!json)return 3;
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
    return 0;
} }
