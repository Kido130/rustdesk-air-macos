#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }
static int fixtureType(int,uint64_t sid) { return sid==800 ? 4 : 0; }

int main(int argc,char **argv) { @autoreleasepool {
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-order-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];
    api().spaceType=fixtureType;
    initialSpace=639;builtinUUID="builtin-uuid";
    createdSpaces={1503,1501,1502};
    ownedSpaces={{1503,"owned-3","builtin-uuid"},{1501,"owned-1","builtin-uuid"},
        {1502,"owned-2","builtin-uuid"}};
    NSDictionary *display=@{@"Display Identifier":@"builtin-uuid",
        @"Current Space":@{@"id64":@639},
        @"Spaces":@[@{@"id64":@100,@"type":@0},
            @{@"id64":@800,@"type":@4},
            @{@"id64":@639,@"type":@0},
            @{@"id64":@900,@"type":@0},
            @{@"id64":@1501,@"uuid":@"owned-1",@"type":@0},
            @{@"id64":@1502,@"uuid":@"owned-2",@"type":@0},
            @{@"id64":@1503,@"uuid":@"owned-3",@"type":@0},
            @{@"id64":@777,@"type":@0}]};
    std::vector<uint64_t> order;
    assert(fullSpaceOrder(display,order));
    assert((order==std::vector<uint64_t>{100,800,639,900,1501,1502,1503,777}));
    assert(additionPreservesOrder({100,800,639,900},{100,800,639,900,1501},1501));
    assert(!additionPreservesOrder({100,800,639,900},{100,639,800,900,1501},1501));
    assert(assignOwnedSlots(display,7));
    assert(initialSpace==639 && slots[0]==1501 && slots[1]==1502 && slots[2]==1503);
    assert(ownedSlotsStillOrdered(display,7));
    saved.push_back({73,42,"test.bundle","fixture",CGRectMake(-1600,85,420,300),
        CGRectMake(-1920,0,1920,1080),1234567890,189,1,"external-uuid",true});
    assert(persist());
    slots[0]=slots[1]=slots[2]=0;createdSpaces.clear();ownedSpaces.clear();
    assert(loadJournal());
    assert(initialSpace==639 && slots[0]==1501 && slots[1]==1502 && slots[2]==1503);
    assert(createdSpaces.size()==3 && ownedSpaces.size()==3);
    NSDictionary *interleaved=@{@"Display Identifier":@"builtin-uuid",
        @"Spaces":@[@{@"id64":@100,@"type":@0},@{@"id64":@639,@"type":@0},
            @{@"id64":@1501,@"uuid":@"owned-1",@"type":@0},
            @{@"id64":@800,@"type":@4},
            @{@"id64":@1502,@"uuid":@"owned-2",@"type":@0},
            @{@"id64":@1503,@"uuid":@"owned-3",@"type":@0}]};
    assert(!ownedSlotsStillOrdered(interleaved,7));
    assert(slots[0]==1501 && slots[1]==1502 && slots[2]==1503);
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    recoveryHooks=nullptr;journalTestPath=nil;
    puts("Spaces slot order: new owned triplet, non-first initial desktop, fullscreen order, reorder refusal and v4 roundtrip passed");
    return 0;
} }
