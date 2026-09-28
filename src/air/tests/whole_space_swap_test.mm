#import <Foundation/Foundation.h>
#include "../whole_space_swap.h"

#include <algorithm>
#include <cassert>
#include <cstdio>

using namespace air::whole_space;

static Topology originalTopology() {
    return {{{"external-a",{40,41},{"a40","a41"},41},
             {"builtin",{10,11,12},{"b10","b11","b12"},11},
             {"external-b",{50,51,52},{"c50","c51","c52"},50}}};
}

static Topology preparedTopology() {
    Topology topology=originalTopology();
    Display &builtin=topology.displays[1];
    builtin.order.insert(builtin.order.end(),{901,902});
    builtin.spaceUUIDs.insert(builtin.spaceUUIDs.end(),{"p901","p902"});
    return topology;
}

static void move(Topology &topology,uint64_t sid,const std::string &destination,uint32_t index) {
    Display *source=nullptr,*target=nullptr;
    size_t sourceIndex=0;
    for(auto &display:topology.displays) {
        if(display.uuid==destination)target=&display;
        for(size_t candidate=0;candidate<display.order.size();candidate++)if(display.order[candidate]==sid) {
            assert(!source);source=&display;sourceIndex=candidate;
        }
    }
    assert(source && target && index<=target->order.size());
    std::string uuid=source->spaceUUIDs[sourceIndex];
    source->order.erase(source->order.begin()+sourceIndex);
    source->spaceUUIDs.erase(source->spaceUUIDs.begin()+sourceIndex);
    if(source->current==sid) {
        assert(!source->order.empty());
        source->current=source->order[std::min(sourceIndex,source->order.size()-1)];
    }
    target->order.insert(target->order.begin()+index,sid);
    target->spaceUUIDs.insert(target->spaceUUIDs.begin()+index,uuid);
}

static void insertSpace(Topology &topology,const std::string &display,size_t index,
                        uint64_t sid,const std::string &uuid,bool select=false) {
    for(auto &candidate:topology.displays)if(candidate.uuid==display) {
        assert(index<=candidate.order.size());
        candidate.order.insert(candidate.order.begin()+index,sid);
        candidate.spaceUUIDs.insert(candidate.spaceUUIDs.begin()+index,uuid);
        if(select)candidate.current=sid;
        return;
    }
    assert(false);
}

static Topology backgroundFullscreenTopology() {
    Topology topology=originalTopology();
    insertSpace(topology,"builtin",1,137,"fullscreen-137");
    return topology;
}

static bool containsSpace(const Topology &topology,uint64_t sid) {
    for(const auto &display:topology.displays)
        if(std::find(display.order.begin(),display.order.end(),sid)!=display.order.end())return true;
    return false;
}

static void eraseSpace(Topology &topology,uint64_t sid) {
    for(auto &display:topology.displays) {
        auto found=std::find(display.order.begin(),display.order.end(),sid);
        if(found==display.order.end())continue;
        size_t index=(size_t)(found-display.order.begin());
        assert(display.current!=sid);
        display.order.erase(found);display.spaceUUIDs.erase(display.spaceUUIDs.begin()+index);return;
    }
    assert(false);
}

static std::vector<std::string> extraLayout(const Topology &topology) {
    std::vector<std::string> result;
    for(const auto &display:topology.displays)for(size_t index=0;index<display.order.size();index++)
        if(display.order[index]>=700 && display.order[index]<800)
            result.push_back(display.uuid+":"+std::to_string(display.order[index])+":"+display.spaceUUIDs[index]);
    return result;
}

static Hooks hooksFor(Topology &topology,Journal &disk,int &writes) {
    return {[&](const Journal &journal){disk=journal;writes++;return true;},
            [&]{return topology;},
            [&](uint64_t sid,const std::string &display,uint32_t index){move(topology,sid,display,index);return true;},
            [&](const std::string &uuid,uint64_t sid){
                for(auto &display:topology.displays)if(display.uuid==uuid) {
                    assert(std::find(display.order.begin(),display.order.end(),sid)!=display.order.end());
                    display.current=sid;return true;
                }
                return false;
            }};
}

int main() { @autoreleasepool {
    auto type=[](uint64_t){return 0;};
    std::string why;
    Topology topology=preparedTopology();
    Journal journal;
    assert(initialize(journal,topology,"builtin",901,902,"p901","p902",type,&why));
    assert(journal.selected[0]==11 && journal.selected[1]==41 && journal.selected[2]==50);
    NSDictionary *encoded=encode(journal);
    Journal decoded;
    assert(decode(encoded,decoded,&why));
    assert(journal.version==3 && decoded.version==3);
    Journal legacySchema=journal;legacySchema.version=2;
    NSDictionary *legacyEncoded=encode(legacySchema);
    Journal legacyDecoded;
    assert(decode(legacyEncoded,legacyDecoded,&why) && legacyDecoded.version==2);

    // A background full-screen Space remains outside the four ordinary moves;
    // the root recovery journal moves and restores its exact type-4 identity.
    auto backgroundType=[](uint64_t sid){return sid==137 ? 4 : 0;};
    Topology backgroundPrepared=backgroundFullscreenTopology();
    insertSpace(backgroundPrepared,"builtin",backgroundPrepared.displays[1].order.size(),901,"p901");
    insertSpace(backgroundPrepared,"builtin",backgroundPrepared.displays[1].order.size(),902,"p902");
    Journal backgroundJournal;
    assert(initialize(backgroundJournal,backgroundPrepared,"builtin",901,902,"p901","p902",
        backgroundType,&why));
    assert(!containsSpace(backgroundJournal.original,137));
    assert(containsSpace(backgroundPrepared,137));

    // A retained v2 journal can be upgraded only with an exact captured
    // original snapshot and captured type evidence. Pending move indexes are
    // recomputed in the filtered known-space coordinate system.
    auto allOrdinary=[](uint64_t){return 0;};
    Journal legacyFullscreen;
    assert(initialize(legacyFullscreen,backgroundPrepared,"builtin",901,902,"p901","p902",
        allOrdinary,&why));
    legacyFullscreen.version=2;
    Topology legacyLive=backgroundPrepared;Journal legacyDisk=legacyFullscreen;int legacyWrites=0;
    Hooks legacyHooks=hooksFor(legacyLive,legacyDisk,legacyWrites);
    legacyHooks.move=[](uint64_t,const std::string&,uint32_t){return false;};
    assert(!advanceForward(legacyFullscreen,legacyHooks,&why) && legacyFullscreen.pending.active);
    Journal rejectedLegacy=legacyFullscreen;
    Topology wrongCapture=backgroundFullscreenTopology();
    wrongCapture.displays[0].spaceUUIDs[1]="wrong-fullscreen-137";
    assert(!upgradeLegacyFullscreenJournal(rejectedLegacy,wrongCapture,backgroundType,&why)
        && rejectedLegacy.version==2 && containsSpace(rejectedLegacy.original,137));
    assert(upgradeLegacyFullscreenJournal(legacyFullscreen,backgroundFullscreenTopology(),backgroundType,&why));
    assert(legacyFullscreen.version==3 && legacyFullscreen.pending.active
        && !containsSpace(legacyFullscreen.original,137));
    legacyDisk=legacyFullscreen;legacyHooks=hooksFor(legacyLive,legacyDisk,legacyWrites);
    assert(advanceForward(legacyFullscreen,legacyHooks,&why)
        && legacyFullscreen.forwardDone==1 && !legacyFullscreen.pending.active);

    // The retained incident shape had completed reverse/selection counters,
    // recreated fullscreen ID 208 selected, and parking Spaces reordered
    // around otherwise exact ordinary Spaces. Evidence upgrade durably reopens
    // selection restoration and cleanup removes only owned parking identities.
    Journal terminalLegacy;
    assert(initialize(terminalLegacy,backgroundPrepared,"builtin",901,902,"p901","p902",
        allOrdinary,&why));
    terminalLegacy.version=2;terminalLegacy.forwardDone=4;terminalLegacy.reverseDone=4;
    terminalLegacy.selectionDone=3;
    assert(upgradeLegacyFullscreenJournal(terminalLegacy,backgroundFullscreenTopology(),backgroundType,&why));
    assert(terminalLegacy.version==3 && terminalLegacy.legacyTerminalCleanup
        && terminalLegacy.selectionDone==0);
    Topology terminalLive=backgroundPrepared;
    eraseSpace(terminalLive,137);eraseSpace(terminalLive,901);eraseSpace(terminalLive,902);
    insertSpace(terminalLive,"builtin",1,208,"fullscreen-208",true);
    insertSpace(terminalLive,"builtin",2,902,"p902");
    insertSpace(terminalLive,"builtin",terminalLive.displays[1].order.size(),901,"p901");
    terminalLive.displays[2].current=51;
    Journal terminalDisk=terminalLegacy;int terminalWrites=0;
    Hooks terminalHooks=hooksFor(terminalLive,terminalDisk,terminalWrites);
    terminalHooks.move=[](uint64_t,const std::string&,uint32_t){assert(false);return false;};
    assert(restoreLegacyTerminalSelections(terminalLegacy,terminalHooks,&why));
    assert(terminalLegacy.selectionDone==3
        && legacyTerminalCleanupTopology(terminalLegacy,terminalLive,{901,902}));
    for(uint64_t parking:{901ULL,902ULL}) {
        Topology after=terminalLive;eraseSpace(after,parking);
        assert(parkingRemovalEndpoint(terminalLegacy,terminalLive,parking,after,&why));
        assert(legacyTerminalCleanupTopology(terminalLegacy,after,
            parking==901 ? std::vector<uint64_t>{902} : std::vector<uint64_t>{}));
        terminalLive=after;
    }
    assert(finalOriginalPreservingExtras(terminalLegacy,terminalLive)
        && containsSpace(terminalLive,208));

    // Additive Spaces created while parking is prepared remain untouched and
    // do not prevent preparation recovery or cleanup.
    Topology preparing=originalTopology();Journal preparingJournal;
    assert(begin(preparingJournal,preparing,"builtin",type,&why));
    insertSpace(preparing,"external-a",1,700,"extra-700");
    insertSpace(preparing,"builtin",preparing.displays[1].order.size(),901,"p901");
    assert(addParking(preparingJournal,preparing,901,"p901",type,&why));
    insertSpace(preparing,"builtin",1,701,"extra-701");
    insertSpace(preparing,"builtin",preparing.displays[1].order.size(),902,"p902");
    assert(addParking(preparingJournal,preparing,902,"p902",type,&why));
    assert(preparationTopology(preparingJournal,preparing));
    preparing.displays[0].current=700;
    preparing.displays[1].current=701;
    insertSpace(preparing,"external-b",1,702,"extra-702",true);
    eraseSpace(preparing,901);
    auto preparingExtras=extraLayout(preparing);
    Journal preparingDisk=preparingJournal;int preparingWrites=0;
    Hooks preparingHooks=hooksFor(preparing,preparingDisk,preparingWrites);
    preparingHooks.move=[](uint64_t,const std::string&,uint32_t){assert(false);return false;};
    assert(normalizePreparationCleanup(preparingJournal,{902},preparingHooks,&why));
    assert(preparationCleanupTopology(preparingJournal,preparing,{902}));
    assert(extraLayout(preparing)==preparingExtras);
    eraseSpace(preparing,902);
    assert(preparationCleanupTopology(preparingJournal,preparing,{}));

    Journal disk=journal;
    int writes=0;
    Hooks hooks=hooksFor(topology,disk,writes);
    while(journal.forwardDone<4)assert(advanceForward(journal,hooks,&why));
    assert(runtimeTopology(journal,topology));
    assert((topology.displays[1].order==std::vector<uint64_t>{10,11,41,50,12}));
    assert((topology.displays[0].order==std::vector<uint64_t>{40,901}));
    assert((topology.displays[2].order==std::vector<uint64_t>{902,51,52}));

    // macOS may select a Space on its destination display as part of a whole
    // Space move.  The transaction restores its deterministic selection
    // before committing the move, including when every move drifts.
    Topology driftTopology=preparedTopology();Journal driftJournal;
    assert(initialize(driftJournal,driftTopology,"builtin",901,902,"p901","p902",type,&why));
    Journal driftDisk=driftJournal;int driftWrites=0;
    Hooks driftHooks=hooksFor(driftTopology,driftDisk,driftWrites);
    driftHooks.move=[&](uint64_t sid,const std::string &display,uint32_t index) {
        move(driftTopology,sid,display,index);
        for(auto &candidate:driftTopology.displays)if(candidate.uuid==display)candidate.current=sid;
        return true;
    };
    while(driftJournal.forwardDone<4)assert(advanceForward(driftJournal,driftHooks,&why));
    assert(runtimeTopology(driftJournal,driftTopology));

    // Absolute indexes may shift around a durable pending move.  The retry
    // translates its journal-known relative endpoint into the live topology.
    Topology shifted=preparedTopology();Journal shiftedJournal;
    assert(initialize(shiftedJournal,shifted,"builtin",901,902,"p901","p902",type,&why));
    insertSpace(shifted,"external-a",0,700,"extra-700");
    insertSpace(shifted,"external-a",2,701,"extra-701");
    Journal shiftedDisk=shiftedJournal;int shiftedWrites=0;
    Hooks shiftedHooks=hooksFor(shifted,shiftedDisk,shiftedWrites);
    shiftedHooks.move=[&](uint64_t,const std::string&,uint32_t){return false;};
    assert(!advanceForward(shiftedJournal,shiftedHooks,&why) && shiftedDisk.pending.active);
    shiftedJournal=shiftedDisk;
    insertSpace(shifted,"external-a",1,702,"extra-702");
    auto shiftedExtras=extraLayout(shifted);
    shiftedHooks=hooksFor(shifted,shiftedDisk,shiftedWrites);
    assert(advanceForward(shiftedJournal,shiftedHooks,&why));
    assert(shiftedJournal.forwardDone==1 && !shiftedJournal.pending.active
        && extraLayout(shifted)==shiftedExtras);
    while(shiftedJournal.forwardDone<4)assert(advanceForward(shiftedJournal,shiftedHooks,&why));
    assert(runtimeTopology(shiftedJournal,shifted));

    // Additive fullscreen-like Spaces can appear during runtime and even be
    // selected.  Recovery selects deterministic known Spaces, reverses only
    // journal moves, restores selections, and leaves every extra in place.
    insertSpace(shifted,"builtin",2,703,"extra-703",true);
    insertSpace(shifted,"external-b",1,704,"extra-704",true);
    shiftedExtras=extraLayout(shifted);
    assert(normalizeForReverse(shiftedJournal,shiftedHooks,&why));
    assert(extraLayout(shifted)==shiftedExtras);
    assert(advanceReverse(shiftedJournal,shiftedHooks,&why));
    insertSpace(shifted,"external-a",shifted.displays[0].order.size(),705,"extra-705",true);
    shiftedExtras=extraLayout(shifted);
    while(shiftedJournal.reverseDone<4)assert(advanceReverse(shiftedJournal,shiftedHooks,&why));
    while(shiftedJournal.selectionDone<3)assert(advanceSelections(shiftedJournal,shiftedHooks,&why));
    assert(finalPrepared(shiftedJournal,shifted) && extraLayout(shifted)==shiftedExtras);
    for(uint64_t parking:{901ULL,902ULL}) {
        Topology after=shifted;
        eraseSpace(after,parking);
        assert(parkingRemovalEndpoint(shiftedJournal,shifted,parking,after,&why));
        assert(cleanupTopologyPreservingExtras(shiftedJournal,after,parking==901
            ? std::vector<uint64_t>{902} : std::vector<uint64_t>{}));
        shifted=after;
    }
    assert(finalOriginalPreservingExtras(shiftedJournal,shifted));
    assert(extraLayout(shifted)==shiftedExtras);

    // Moving an unrelated Space as a side effect is rejected while the
    // durable known-Space move remains pending for safe recovery.
    Topology collateral=preparedTopology();Journal collateralJournal;
    assert(initialize(collateralJournal,collateral,"builtin",901,902,"p901","p902",type,&why));
    insertSpace(collateral,"external-a",0,700,"extra-700");
    Journal collateralDisk=collateralJournal;int collateralWrites=0;
    Hooks collateralHooks=hooksFor(collateral,collateralDisk,collateralWrites);
    collateralHooks.move=[&](uint64_t sid,const std::string &display,uint32_t index) {
        move(collateral,sid,display,index);move(collateral,700,"external-b",0);return true;
    };
    assert(!advanceForward(collateralJournal,collateralHooks,&why));
    assert(collateralJournal.pending.active && collateralDisk.pending.active);

    assert(selectRuntime(journal,hooks,50,&why));
    assert(journal.runtimeCurrent==50 && runtimeTopology(journal,topology));
    assert(normalizeForReverse(journal,hooks,&why));
    while(journal.reverseDone<4)assert(advanceReverse(journal,hooks,&why));
    while(journal.selectionDone<3)assert(advanceSelections(journal,hooks,&why));
    assert(finalPrepared(journal,topology));
    Topology before=topology;
    move(topology,901,"external-a",0); // Build an invalid deletion endpoint without deleting data.
    assert(!parkingRemovalEndpoint(journal,before,901,topology,&why));
    topology=before;
    for(uint64_t parking:{901ULL,902ULL}) {
        Topology after=topology;
        for(auto &display:after.displays) {
            auto found=std::find(display.order.begin(),display.order.end(),parking);
            if(found==display.order.end())continue;
            size_t index=(size_t)(found-display.order.begin());
            display.order.erase(found);
            display.spaceUUIDs.erase(display.spaceUUIDs.begin()+index);
        }
        assert(parkingRemovalEndpoint(journal,topology,parking,after,&why));
        assert(cleanupTopology(journal,after,parking==901
            ? std::vector<uint64_t>{902} : std::vector<uint64_t>{}));
        topology=after;
    }
    assert(finalOriginal(journal,topology));

    // Recovery preserves unrelated Spaces created after the journal began,
    // while every journal-known ID, UUID, order, and selection remains exact.
    Topology withExtra=topology;
    withExtra.displays[2].order.push_back(777);
    withExtra.displays[2].spaceUUIDs.push_back("unrelated-777");
    assert(!finalOriginal(journal,withExtra));
    assert(finalOriginalPreservingExtras(journal,withExtra));
    Topology wrongKnownOrder=withExtra;
    std::swap(wrongKnownOrder.displays[2].order[0],wrongKnownOrder.displays[2].order[1]);
    std::swap(wrongKnownOrder.displays[2].spaceUUIDs[0],wrongKnownOrder.displays[2].spaceUUIDs[1]);
    assert(!finalOriginalPreservingExtras(journal,wrongKnownOrder));
    Topology identityCollision=withExtra;
    identityCollision.displays[2].spaceUUIDs[0]="replacement-50";
    identityCollision.displays[2].spaceUUIDs.back()="c50";
    assert(!preservesKnownTopology(journal,topology,identityCollision));

    // Crash after the first move action, before its completion record: reconciliation adopts it once.
    topology=preparedTopology();journal={};
    assert(initialize(journal,topology,"builtin",901,902,"p901","p902",type,&why));
    disk=journal;writes=0;hooks=hooksFor(topology,disk,writes);
    bool failCompletion=false;
    hooks.persist=[&](const Journal &value) {
        writes++;
        if(value.pending.active){disk=value;return true;}
        if(!failCompletion){failCompletion=true;return false;}
        disk=value;
        return true;
    };
    assert(!advanceForward(journal,hooks,&why));
    assert(disk.pending.active
        && std::find(topology.displays[0].order.begin(),topology.displays[0].order.end(),901)
            !=topology.displays[0].order.end());
    insertSpace(topology,"external-b",1,700,"extra-700");
    auto recoveredExtras=extraLayout(topology);
    journal=disk;
    bool reconciledPersisted=false;
    hooks=hooksFor(topology,disk,writes);
    hooks.persist=[&](const Journal &value) {
        if(value.forwardDone==1 && !value.pending.active)reconciledPersisted=true;
        disk=value;return true;
    };
    assert(advanceForward(journal,hooks,&why));
    assert(reconciledPersisted && journal.forwardDone==2 && !disk.pending.active);
    while(journal.forwardDone<4)assert(advanceForward(journal,hooks,&why));
    assert(extraLayout(topology)==recoveredExtras);

    // Runtime selection completion also becomes durable when recovered at its exact endpoint.
    disk=journal;bool failedSelectionCompletion=false;
    hooks.persist=[&](const Journal &value) {
        if(value.runtimeSelectionPending.active){disk=value;return true;}
        if(!failedSelectionCompletion){failedSelectionCompletion=true;return false;}
        disk=value;return true;
    };
    assert(!selectRuntime(journal,hooks,50,&why));
    assert(disk.runtimeSelectionPending.active);
    journal=disk;bool selectionReconciledPersisted=false;
    hooks.persist=[&](const Journal &value) {
        if(!value.runtimeSelectionPending.active && value.runtimeCurrent==50)
            selectionReconciledPersisted=true;
        disk=value;return true;
    };
    assert(selectRuntime(journal,hooks,50,&why));
    assert(selectionReconciledPersisted && !disk.runtimeSelectionPending.active
        && disk.runtimeCurrent==50);

    // Corrupt cross-stage journals and prepared identities fail atomically.
    Journal sentinel=decoded;
    NSMutableDictionary *bad=[encoded mutableCopy];
    bad[@"reverseDone"]=@1;
    assert(!decode(bad,sentinel,&why) && sentinel.selected[0]==11);
    bad=[encoded mutableCopy];
    NSMutableDictionary *prepared=[bad[@"prepared"] mutableCopy];
    NSMutableArray *displays=[prepared[@"displays"] mutableCopy];
    NSMutableDictionary *builtin=[displays[1] mutableCopy];
    NSMutableArray *uuids=[builtin[@"spaceUUIDs"] mutableCopy];
    uuids[3]=@"wrong-parking-identity";
    builtin[@"spaceUUIDs"]=uuids;displays[1]=builtin;prepared[@"displays"]=displays;bad[@"prepared"]=prepared;
    assert(!decode(bad,sentinel,&why));

    puts("whole Space ordering, forward/reverse, selection, crash reconciliation and journal validation passed");
    return 0;
} }
