#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <stdio.h>
extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }
static int fixtureSpaceType(int,uint64_t) { return 0; }

static bool journalIOTest(const char *root) {
    NSString *parent=root ? [NSString stringWithUTF8String:root] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-journal-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    if(!mkdtemp(directory.data()))return false;
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    NSString *path=[base stringByAppendingPathComponent:@"recovery.json"];
    journalTestPath=path;
    bool okay=false;
    @try {
        if(!persist()) { fprintf(stderr,"persist: %s\n",journalIOError.c_str());return false; }
        struct stat st={};
        if(stat(path.fileSystemRepresentation,&st)!=0 || (st.st_mode&0777)!=0600)return false;
        NSData *onDisk=[NSData dataWithContentsOfFile:path];
        if(!onDisk || ![NSJSONSerialization JSONObjectWithData:onDisk options:0 error:nil])return false;
        if(!loadJournal() || !pendingCreate || ownedSpaces.size()!=1 || slots[1]!=900)return false;
        pendingCreate=false;pendingCreateBefore.clear();
        createdSpaces.push_back(901);
        ownedSpaces.push_back({901,"second-owned-space","builtin-uuid"});
        if(!persist())return false;
        createdSpaces.erase(createdSpaces.begin());
        ownedSpaces.erase(ownedSpaces.begin());
        if(!persist())return false;
        createdSpaces.clear();ownedSpaces.clear();saved.clear();lastSelectedSpace=0;
        if(!loadJournal() || pendingCreate || createdSpaces.size()!=1 || createdSpaces[0]!=901
            || ownedSpaces.size()!=1 || ownedSpaces[0].uuid!="second-owned-space"
            || saved.size()!=1 || lastSelectedSpace!=900 || slots[1]!=900)return false;

        NSString *blocker=[base stringByAppendingPathComponent:@"blocker"];
        if(![@"block" writeToFile:blocker atomically:YES encoding:NSUTF8StringEncoding error:nil])return false;
        journalTestPath=[blocker stringByAppendingPathComponent:@"bad.json"];
        if(persist() || journalIOError.empty())return false;
        journalTestPath=path;
        if(chmod(directory.data(),0500)!=0)return false;
        bool removed=clearJournal();
        bool kept=stat(path.fileSystemRepresentation,&st)==0;
        chmod(directory.data(),0700);
        if(removed || !kept || journalIOError.empty())return false;
        if(!clearJournal())return false;
        okay=stat(path.fileSystemRepresentation,&st)!=0 && errno==ENOENT;
    } @finally {
        chmod(directory.data(),0700);
        journalTestPath=nil;
        [[NSFileManager defaultManager] removeItemAtPath:base error:nil];
    }
    return okay;
}

int main(int argc,char **argv) { @autoreleasepool {
    NSDictionary *legacy=@{@"version":@2,@"initialSpace":@639,@"windows":@[@{
        @"id":@73,@"pid":@42,@"bundle":@"test.bundle",@"title":@"fixture",
        @"x":@(-1600),@"y":@85,@"w":@420,@"h":@300,
        @"dx":@(-1920),@"dy":@0,@"dw":@1920,@"dh":@1080,
        @"launch":@1234567890,@"space":@189,@"slot":@1}]};
    if(!parseJournal(legacy) || saved.size()!=1 || saved[0].frameFromAX
        || saved[0].frame.origin.x!=-1600 || initialSpace!=639 || !createdSpaces.empty())return 1;

    SavedWindow w={73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true};
    NSDictionary *modern=@{@"version":@3,@"initialSpace":@639,@"builtinUUID":@"builtin-uuid",
        @"createdSpaces":@[@512],@"windows":@[serialize(w)]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:modern options:0 error:nil];
    NSDictionary *roundtrip=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(!parseJournal(roundtrip) || saved.size()!=1 || !saved[0].frameFromAX
        || saved[0].sourceUUID!="external-uuid" || builtinUUID!="builtin-uuid"
        || createdSpaces.size()!=1 || createdSpaces[0]!=512)return 2;

    NSDictionary *invalid=@{@"version":@3,@"initialSpace":@639,@"builtinUUID":@"builtin-uuid",
        @"createdSpaces":@[@512,@512],@"windows":@[serialize(w)]};
    if(parseJournal(invalid) || saved.size()!=1 || saved[0].space!=189
        || createdSpaces.size()!=1 || createdSpaces[0]!=512)return 3;
    NSDictionary *owned=@{@"id":@900,@"uuid":@"owned-space-uuid",@"displayUUID":@"builtin-uuid"};
    NSDictionary *v4=@{@"version":@4,@"initialSpace":@639,@"builtinUUID":@"builtin-uuid",
        @"createdSpaces":@[owned],@"pendingCreate":@{@"before":@[@639,@512,@900],@"displayUUID":@"builtin-uuid"},
        @"lastSelectedSpace":@900,@"slotSpaceIDs":@[@639,@900,@512],@"windows":@[serialize(w)]};
    if(!parseJournal(v4) || saved.size()!=1 || !saved[0].frameFromAX
        || createdSpaces.size()!=1 || ownedSpaces.size()!=1 || ownedSpaces[0].uuid!="owned-space-uuid"
        || !pendingCreate || pendingCreateBefore.size()!=3 || lastSelectedSpace!=900 || slots[1]!=900)return 7;
    NSDictionary *v4Invalid=@{@"version":@4,@"initialSpace":@639,@"builtinUUID":@"builtin-uuid",
        @"createdSpaces":@[@{@"id":@639,@"uuid":@"original",@"displayUUID":@"builtin-uuid"}],
        @"pendingCreate":NSNull.null,@"lastSelectedSpace":@0,@"slotSpaceIDs":@[],@"windows":@[]};
    if(parseJournal(v4Invalid) || ownedSpaces.size()!=1 || !pendingCreate)return 8;
    NSDictionary *duplicateOwner=@{@"version":@4,@"initialSpace":@639,@"builtinUUID":@"builtin-uuid",
        @"createdSpaces":@[owned,owned],@"pendingCreate":NSNull.null,
        @"lastSelectedSpace":@0,@"slotSpaceIDs":@[],@"windows":@[]};
    if(parseJournal(duplicateOwner) || ownedSpaces.size()!=1 || !pendingCreate)return 10;
    auto originalType=api().spaceType;
    api().spaceType=fixtureSpaceType;
    NSArray *same=@[@{@"Display Identifier":@"builtin-uuid",
        @"Spaces":@[@{@"id64":@900,@"uuid":@"owned-space-uuid",@"type":@0}]}];
    NSArray *reused=@[@{@"Display Identifier":@"builtin-uuid",
        @"Spaces":@[@{@"id64":@900,@"uuid":@"someone-else",@"type":@0}]}];
    NSArray *missing=@[@{@"Display Identifier":@"builtin-uuid",@"Spaces":@[]}];
    NSArray *unknown=@[@{@"Display Identifier":@"builtin-uuid",
        @"Spaces":@[@{@"id64":@900,@"type":@0}]}];
    if(ownedStatus(same,ownedSpaces[0],0)!=OwnedStatus::Match
        || ownedStatus(reused,ownedSpaces[0],0)!=OwnedStatus::Conflict
        || ownedStatus(missing,ownedSpaces[0],0)!=OwnedStatus::Absent
        || ownedStatus(unknown,ownedSpaces[0],0)!=OwnedStatus::Conflict)return 9;
    if(!removalPreflight(OwnedStatus::Match,900,639,639,3,true)
        || removalPreflight(OwnedStatus::Match,639,639,900,3,true)
        || removalPreflight(OwnedStatus::Match,900,639,900,3,true)
        || removalPreflight(OwnedStatus::Match,900,639,639,1,true)
        || removalPreflight(OwnedStatus::Unknown,900,639,639,3,true)
        || removalPreflight(OwnedStatus::Match,900,639,639,3,false))return 11;
    api().spaceType=originalType;
    CGRect content=CGRectMake(0,38,1147,680);
    CGRect mapped=mappedFrame(w,content);
    if(!CGRectContainsRect(content,mapped) || mapped.size.width!=420 || mapped.size.height!=300)return 4;
    w.frame=CGRectMake(-4000,-200,2400,1400);
    mapped=mappedFrame(w,content);
    if(!CGRectContainsRect(content,mapped) || mapped.size.width!=content.size.width
        || mapped.size.height!=content.size.height)return 5;
    if(!journalIOTest(argc>1 ? argv[1] : nullptr))return 6;
    puts("v2/v3/v4 journal, pending add, ownership conflicts, clamping, private atomic I/O and failure handling passed");
    return 0;
} }
