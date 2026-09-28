#import <Foundation/Foundation.h>
#include "whole_space_swap.h"

#include <algorithm>
#include <map>
#include <set>

namespace air::whole_space {
namespace {

const Display *findDisplay(const Topology &topology,const std::string &uuid) {
    for(const auto &display:topology.displays)if(display.uuid==uuid)return &display;
    return nullptr;
}

Display *findDisplay(Topology &topology,const std::string &uuid) {
    for(auto &display:topology.displays)if(display.uuid==uuid)return &display;
    return nullptr;
}

bool fail(std::string *why,const char *message) {
    if(why)*why=message;
    return false;
}

bool equal(const Topology &left,const Topology &right) {
    if(left.displays.size()!=right.displays.size())return false;
    for(const auto &display:left.displays) {
        const Display *other=findDisplay(right,display.uuid);
        if(!other || other->order!=display.order || other->spaceUUIDs!=display.spaceUUIDs
            || other->current!=display.current)return false;
    }
    return true;
}

bool validTopology(const Topology &topology) {
    if(topology.displays.size()!=3)return false;
    std::set<std::string> displays;
    std::set<uint64_t> spaces;
    std::set<std::string> spaceUUIDs;
    for(const auto &display:topology.displays) {
        if(display.uuid.empty() || !displays.insert(display.uuid).second || display.order.empty()
            || display.order.size()!=display.spaceUUIDs.size() || !display.current)return false;
        bool current=false;
        for(size_t index=0;index<display.order.size();index++) {
            uint64_t sid=display.order[index];
            if(!sid || !spaces.insert(sid).second)return false;
            if(display.spaceUUIDs[index].empty() || !spaceUUIDs.insert(display.spaceUUIDs[index]).second)return false;
            if(sid==display.current)current=true;
        }
        if(!current)return false;
    }
    return true;
}

bool locate(const Topology &topology,uint64_t sid,Endpoint &endpoint) {
    unsigned found=0;
    for(const auto &display:topology.displays)for(size_t index=0;index<display.order.size();index++)
        if(display.order[index]==sid) {
            endpoint={display.uuid,(uint32_t)index};
            found++;
        }
    return found==1;
}

bool apply(const Topology &input,const Move &move,Topology &output) {
    output=input;
    Display *from=findDisplay(output,move.from.display);
    Display *to=findDisplay(output,move.to.display);
    if(!from || !to || move.from.index>=from->order.size()
        || from->order[move.from.index]!=move.sid || move.to.index>to->order.size())return false;
    std::string movedUUID=from->spaceUUIDs[move.from.index];
    from->order.erase(from->order.begin()+move.from.index);
    from->spaceUUIDs.erase(from->spaceUUIDs.begin()+move.from.index);
    uint32_t target=move.to.index;
    if(from==to && target>move.from.index)target--;
    if(target>to->order.size())return false;
    to->order.insert(to->order.begin()+target,move.sid);
    to->spaceUUIDs.insert(to->spaceUUIDs.begin()+target,std::move(movedUUID));
    if(from->current==move.sid) {
        if(from->order.empty())return false;
        from->current=from->order[std::min<size_t>(move.from.index,from->order.size()-1)];
    }
    return validTopology(output);
}

bool knownIdentities(const Journal &journal,std::map<uint64_t,std::string> &byID,
                     std::map<std::string,uint64_t> &byUUID) {
    auto add=[&](uint64_t sid,const std::string &uuid) {
        if(!sid || uuid.empty())return false;
        auto id=byID.find(sid);auto name=byUUID.find(uuid);
        if((id!=byID.end() && id->second!=uuid) || (name!=byUUID.end() && name->second!=sid))return false;
        byID[sid]=uuid;byUUID[uuid]=sid;return true;
    };
    for(const auto &display:journal.original.displays)
        for(size_t index=0;index<display.order.size();index++)
            if(!add(display.order[index],display.spaceUUIDs[index]))return false;
    for(uint8_t index=0;index<journal.parkingCount;index++)
        if(!add(journal.parking[index],journal.parkingUUID[index]))return false;
    return true;
}

bool splitKnown(const Display &display,const std::map<uint64_t,std::string> &byID,
                const std::map<std::string,uint64_t> &byUUID,
                std::vector<uint64_t> &ids,std::vector<std::string> &uuids,
                std::vector<std::pair<uint64_t,std::string>> *extras=nullptr) {
    for(size_t index=0;index<display.order.size();index++) {
        uint64_t sid=display.order[index];const std::string &uuid=display.spaceUUIDs[index];
        auto knownID=byID.find(sid);auto knownUUID=byUUID.find(uuid);
        if(knownID!=byID.end() || knownUUID!=byUUID.end()) {
            if(knownID==byID.end() || knownUUID==byUUID.end()
                || knownID->second!=uuid || knownUUID->second!=sid)return false;
            ids.push_back(sid);uuids.push_back(uuid);
        } else if(extras)extras->push_back({sid,uuid});
    }
    return true;
}

bool knownTopologyMatches(const Journal &journal,const Topology &expected,const Topology &actual,
                          bool compareCurrents) {
    if(!validTopology(expected) || !validTopology(actual))return false;
    std::map<uint64_t,std::string> byID;std::map<std::string,uint64_t> byUUID;
    if(!knownIdentities(journal,byID,byUUID))return false;
    for(const auto &display:expected.displays) {
        const Display *candidate=findDisplay(actual,display.uuid);
        if(!candidate || (compareCurrents && candidate->current!=display.current))return false;
        std::vector<uint64_t> expectedIDs,actualIDs;
        std::vector<std::string> expectedUUIDs,actualUUIDs;
        if(!splitKnown(display,byID,byUUID,expectedIDs,expectedUUIDs)
            || expectedIDs!=display.order || expectedUUIDs!=display.spaceUUIDs
            || !splitKnown(*candidate,byID,byUUID,actualIDs,actualUUIDs)
            || actualIDs!=display.order || actualUUIDs!=display.spaceUUIDs)return false;
    }
    return true;
}

bool extrasMatch(const Journal &journal,const Topology &before,const Topology &after) {
    if(!validTopology(before) || !validTopology(after))return false;
    std::map<uint64_t,std::string> byID;std::map<std::string,uint64_t> byUUID;
    if(!knownIdentities(journal,byID,byUUID))return false;
    for(const auto &display:before.displays) {
        const Display *candidate=findDisplay(after,display.uuid);
        std::vector<uint64_t> beforeKnown,afterKnown;
        std::vector<std::string> beforeUUIDs,afterUUIDs;
        std::vector<std::pair<uint64_t,std::string>> beforeExtras,afterExtras;
        if(!candidate || !splitKnown(display,byID,byUUID,beforeKnown,beforeUUIDs,&beforeExtras)
            || !splitKnown(*candidate,byID,byUUID,afterKnown,afterUUIDs,&afterExtras)
            || beforeExtras!=afterExtras)return false;
    }
    return true;
}

bool sameLayout(const Topology &before,const Topology &after) {
    if(!validTopology(before) || !validTopology(after))return false;
    for(const auto &display:before.displays) {
        const Display *candidate=findDisplay(after,display.uuid);
        if(!candidate || candidate->order!=display.order
            || candidate->spaceUUIDs!=display.spaceUUIDs)return false;
    }
    return true;
}

bool legacyTerminalTopologyMatches(const Journal &journal,const Topology &actual,
                                   const std::vector<uint64_t> &remaining,bool compareCurrents) {
    if(!journal.legacyTerminalCleanup || !validTopology(actual))return false;
    std::set<uint64_t> keep(remaining.begin(),remaining.end()),seenParking;
    if(keep.size()!=remaining.size())return false;
    std::map<uint64_t,std::string> ordinaryByID;std::map<std::string,uint64_t> ordinaryByUUID;
    for(const auto &display:journal.original.displays)
        for(size_t index=0;index<display.order.size();index++) {
            ordinaryByID[display.order[index]]=display.spaceUUIDs[index];
            ordinaryByUUID[display.spaceUUIDs[index]]=display.order[index];
        }
    for(uint64_t sid:keep)if(sid!=journal.parking[0] && sid!=journal.parking[1])return false;
    for(const auto &expected:journal.original.displays) {
        const Display *display=findDisplay(actual,expected.uuid);
        if(!display || (compareCurrents && display->current!=expected.current))return false;
        std::vector<uint64_t> ordinaryIDs;std::vector<std::string> ordinaryUUIDs;
        for(size_t index=0;index<display->order.size();index++) {
            uint64_t sid=display->order[index];const std::string &uuid=display->spaceUUIDs[index];
            auto knownID=ordinaryByID.find(sid);auto knownUUID=ordinaryByUUID.find(uuid);
            if(knownID!=ordinaryByID.end() || knownUUID!=ordinaryByUUID.end()) {
                if(knownID==ordinaryByID.end() || knownUUID==ordinaryByUUID.end()
                    || knownID->second!=uuid || knownUUID->second!=sid)return false;
                ordinaryIDs.push_back(sid);ordinaryUUIDs.push_back(uuid);continue;
            }
            bool parking=false;
            for(uint8_t parkingIndex=0;parkingIndex<2;parkingIndex++) {
                bool idMatch=sid==journal.parking[parkingIndex];
                bool uuidMatch=uuid==journal.parkingUUID[parkingIndex];
                if(idMatch || uuidMatch) {
                    if(!idMatch || !uuidMatch || display->uuid!=journal.builtin
                        || !keep.count(sid) || !seenParking.insert(sid).second)return false;
                    parking=true;break;
                }
            }
            if(parking)continue;
        }
        if(ordinaryIDs!=expected.order || ordinaryUUIDs!=expected.spaceUUIDs)return false;
    }
    return seenParking==keep;
}

bool normalizeCurrents(const Journal &journal,const Topology &expected,Hooks &hooks,std::string *why) {
    if(!hooks.topology || !hooks.select)return fail(why,"whole-Space selection normalization is unavailable");
    Topology current=hooks.topology();
    if(!knownTopologyMatches(journal,expected,current,false))return fail(why,"whole-Space move changed Space identity or ordering");
    for(const auto &display:expected.displays) {
        const Display *actual=findDisplay(current,display.uuid);
        if(!actual)return false;
        if(actual->current==display.current)continue;
        if(!hooks.select(display.uuid,display.current))
            return fail(why,"whole-Space move selection could not be normalized");
        Topology after=hooks.topology();
        if(!knownTopologyMatches(journal,expected,after,false) || !extrasMatch(journal,current,after))
            return fail(why,"selection normalization changed Space identity or ordering");
        current=std::move(after);
    }
    return knownTopologyMatches(journal,expected,current,true)
        || fail(why,"whole-Space move retained an unexpected selection");
}

std::vector<std::string> externalDisplays(const Journal &journal) {
    std::vector<std::string> result;
    for(const auto &display:journal.original.displays)
        if(display.uuid!=journal.builtin)result.push_back(display.uuid);
    return result;
}

bool makeMove(const Journal &journal,bool reverse,uint8_t ordinal,
              const Topology &current,Move &move) {
    auto external=externalDisplays(journal);
    if(external.size()!=2 || ordinal>3)return false;
    uint64_t sid=0;
    std::string destination;
    uint32_t index=0;
    if(!reverse) {
        if(ordinal==0){sid=journal.parking[0];destination=external[0];}
        if(ordinal==1) {
            sid=journal.selected[1];destination=journal.builtin;
            Endpoint anchor;
            if(!locate(current,journal.selected[0],anchor) || anchor.display!=journal.builtin)return false;
            index=anchor.index+1;
        }
        if(ordinal==2){sid=journal.parking[1];destination=external[1];}
        if(ordinal==3) {
            sid=journal.selected[2];destination=journal.builtin;
            Endpoint anchor;
            if(!locate(current,journal.selected[1],anchor) || anchor.display!=journal.builtin)return false;
            index=anchor.index+1;
        }
        if(destination!=journal.builtin) {
            const Display *original=findDisplay(journal.original,destination);
            uint64_t selectedSID=ordinal==0 ? journal.selected[1] : journal.selected[2];
            auto found=original ? std::find(original->order.begin(),original->order.end(),selectedSID)
                                : std::vector<uint64_t>::const_iterator{};
            if(!original || found==original->order.end())return false;
            index=(uint32_t)(found-original->order.begin());
        }
    } else {
        if(ordinal==0){sid=journal.selected[2];destination=external[1];}
        if(ordinal==1) {
            sid=journal.parking[1];destination=journal.builtin;
            const Display *display=findDisplay(current,journal.builtin);
            if(!display)return false;
            index=(uint32_t)display->order.size();
        }
        if(ordinal==2){sid=journal.selected[1];destination=external[0];}
        if(ordinal==3) {
            sid=journal.parking[0];destination=journal.builtin;
            Endpoint parking2;
            if(!locate(current,journal.parking[1],parking2) || parking2.display!=journal.builtin)return false;
            index=parking2.index;
        }
        if(ordinal==0 || ordinal==2) {
            const Display *original=findDisplay(journal.original,destination);
            if(!original)return false;
            auto found=std::find(original->order.begin(),original->order.end(),sid);
            if(found==original->order.end())return false;
            index=(uint32_t)(found-original->order.begin());
        }
    }
    Endpoint from;
    if(!locate(current,sid,from))return false;
    move={sid,from,{destination,index}};
    return true;
}

bool stageTopology(const Journal &journal,Direction direction,uint8_t ordinal,Topology &output) {
    if(!journal.active || journal.parkingCount!=2 || ordinal>4)return false;
    output=journal.prepared;
    if(direction==Direction::Reverse) {
        for(uint8_t step=0;step<4;step++) {
            Move move;
            if(!makeMove(journal,false,step,output,move) || !apply(output,move,output))return false;
        }
        Display *builtin=findDisplay(output,journal.builtin);
        if(!builtin || std::find(builtin->order.begin(),builtin->order.end(),journal.selected[0])==builtin->order.end())return false;
        builtin->current=journal.selected[0];
    }
    for(uint8_t step=0;step<ordinal;step++) {
        Move move;
        if(!makeMove(journal,direction==Direction::Reverse,step,output,move)
            || !apply(output,move,output))return false;
    }
    return true;
}

bool sameMove(const Move &left,const Move &right) {
    return left.sid==right.sid && left.from.display==right.from.display
        && left.from.index==right.from.index && left.to.display==right.to.display
        && left.to.index==right.to.index;
}

bool liveMove(const Journal &journal,const Topology &before,const Topology &expected,
              const Topology &current,const Move &known,Move &live) {
    if(!knownTopologyMatches(journal,before,current,false))return false;
    Endpoint actualFrom,expectedTo;
    if(!locate(current,known.sid,actualFrom) || !locate(expected,known.sid,expectedTo)
        || actualFrom.display==expectedTo.display)return false;
    const Display *knownDestination=findDisplay(expected,expectedTo.display);
    const Display *liveDestination=findDisplay(current,expectedTo.display);
    if(!knownDestination || !liveDestination)return false;
    auto moved=std::find(knownDestination->order.begin(),knownDestination->order.end(),known.sid);
    if(moved==knownDestination->order.end())return false;
    uint32_t target=(uint32_t)liveDestination->order.size();
    if(++moved!=knownDestination->order.end()) {
        auto next=std::find(liveDestination->order.begin(),liveDestination->order.end(),*moved);
        if(next==liveDestination->order.end())return false;
        target=(uint32_t)(next-liveDestination->order.begin());
    }
    live={known.sid,actualFrom,{expectedTo.display,target}};
    return true;
}

bool advance(Journal &journal,Hooks &hooks,bool reverse,std::string *why) {
    if(!journal.active || journal.parkingCount!=2 || !hooks.persist || !hooks.topology
        || !hooks.move || !hooks.select)
        return fail(why,"whole-Space transaction hooks are incomplete");
    Topology current=hooks.topology();
    bool hadPending=journal.pending.active;
    if(hadPending) {
        Topology before,after;
        Move pending;
        if(!stageTopology(journal,journal.pending.direction,journal.pending.ordinal,before)
            || !makeMove(journal,journal.pending.direction==Direction::Reverse,
                journal.pending.ordinal,before,pending) || !apply(before,pending,after))return false;
        if(knownTopologyMatches(journal,before,current,false)) {
            if(!normalizeCurrents(journal,before,hooks,why))return false;
        } else if(knownTopologyMatches(journal,after,current,false)) {
            if(!normalizeCurrents(journal,after,hooks,why))return false;
        } else return fail(why,"pending whole-Space move has unrelated topology changes");
        current=hooks.topology();
        if(!reconcile(journal,current,why))return false;
    }
    if(hadPending && !hooks.persist(journal))
        return fail(why,"reconciled whole-Space move could not be persisted");
    uint8_t &done=reverse ? journal.reverseDone : journal.forwardDone;
    if(done==4)return true;
    if(reverse && (journal.forwardDone!=4 || journal.runtimeSelectionPending.active
        || journal.runtimeCurrent!=journal.selected[0]))
        return fail(why,"runtime selection must be normalized before reverse migration");
    Topology before;
    if(!stageTopology(journal,reverse ? Direction::Reverse : Direction::Forward,done,before))return false;
    if(!normalizeCurrents(journal,before,hooks,why))return false;
    current=hooks.topology();
    Move move;
    if(!makeMove(journal,reverse,done,before,move))
        return fail(why,"current topology cannot produce the exact next whole-Space move");
    Topology expected;
    if(!apply(before,move,expected))return fail(why,"next whole-Space endpoint is invalid");
    Move actual;
    if(!liveMove(journal,before,expected,current,move,actual))
        return fail(why,"current topology cannot translate the exact next whole-Space move");
    journal.pending={true,reverse ? Direction::Reverse : Direction::Forward,done,move};
    if(!hooks.persist(journal)) {
        journal.pending={};
        return fail(why,"pending whole-Space move was not persisted");
    }
    if(!hooks.move(actual.sid,actual.to.display,actual.to.index))
        return fail(why,"whole-Space move failed with durable pending intent");
    Topology moved=hooks.topology();
    if(!extrasMatch(journal,current,moved) || !knownTopologyMatches(journal,expected,moved,false))
        return fail(why,"whole-Space move changed an unrelated Space");
    if(!normalizeCurrents(journal,expected,hooks,why))return false;
    done++;
    journal.pending={};
    if(!hooks.persist(journal))return fail(why,"completed whole-Space move retained its durable pending record");
    return true;
}

NSDictionary *encodeEndpoint(const Endpoint &endpoint) {
    return @{ @"display":[NSString stringWithUTF8String:endpoint.display.c_str()],
              @"index":@(endpoint.index) };
}

NSDictionary *encodeTopology(const Topology &topology) {
    NSMutableArray *displays=NSMutableArray.array;
    for(const auto &display:topology.displays) {
        NSMutableArray *order=NSMutableArray.array;
        NSMutableArray *spaceUUIDs=NSMutableArray.array;
        for(uint64_t sid:display.order)[order addObject:@(sid)];
        for(const auto &uuid:display.spaceUUIDs)[spaceUUIDs addObject:[NSString stringWithUTF8String:uuid.c_str()]];
        [displays addObject:@{@"display":[NSString stringWithUTF8String:display.uuid.c_str()],
                              @"order":order,@"spaceUUIDs":spaceUUIDs,@"current":@(display.current)}];
    }
    return @{@"displays":displays};
}

bool parseString(id value,std::string &output) {
    if(![value isKindOfClass:NSString.class] || ![value length])return false;
    output=[value UTF8String];
    return !output.empty();
}

bool parseNumber(id value,uint64_t &output,bool allowZero=false) {
    if(![value isKindOfClass:NSNumber.class])return false;
    output=[value unsignedLongLongValue];
    return allowZero || output!=0;
}

bool parseTopology(id value,Topology &output,bool allowEmpty=false) {
    if(allowEmpty && value==NSNull.null)return true;
    if(![value isKindOfClass:NSDictionary.class])return false;
    id rawDisplays=value[@"displays"];
    if(![rawDisplays isKindOfClass:NSArray.class] || [rawDisplays count]!=3)return false;
    Topology parsed;
    for(id raw in rawDisplays) {
        if(![raw isKindOfClass:NSDictionary.class])return false;
        Display display;
        uint64_t current=0;
        if(!parseString(raw[@"display"],display.uuid) || !parseNumber(raw[@"current"],current))return false;
        id rawOrder=raw[@"order"];
        id rawUUIDs=raw[@"spaceUUIDs"];
        if(![rawOrder isKindOfClass:NSArray.class] || ![rawOrder count]
            || ![rawUUIDs isKindOfClass:NSArray.class] || [rawUUIDs count]!=[rawOrder count])return false;
        display.current=current;
        for(id value in rawOrder) {
            uint64_t sid=0;
            if(!parseNumber(value,sid))return false;
            display.order.push_back(sid);
        }
        for(id value in rawUUIDs) {
            std::string uuid;
            if(!parseString(value,uuid))return false;
            display.spaceUUIDs.push_back(std::move(uuid));
        }
        parsed.displays.push_back(std::move(display));
    }
    if(!validTopology(parsed))return false;
    output=std::move(parsed);
    return true;
}

bool parseSelection(id value,SelectionPending &output,bool runtime) {
    if(value==NSNull.null)return true;
    if(![value isKindOfClass:NSDictionary.class])return false;
    uint64_t ordinal=0,from=0,target=0;
    std::string display;
    if(![value[@"ordinal"] isKindOfClass:NSNumber.class]
        || !parseNumber(value[@"from"],from) || !parseNumber(value[@"target"],target)
        || !parseString(value[@"display"],display))return false;
    ordinal=[value[@"ordinal"] unsignedLongLongValue];
    if((runtime && ordinal!=0) || (!runtime && ordinal>2))return false;
    output={true,(uint8_t)ordinal,display,from,target};
    return true;
}

bool validateJournal(const Journal &journal,std::string *why) {
    if((journal.version!=2 && journal.version!=3) || journal.builtin.empty() || !validTopology(journal.original)
        || !findDisplay(journal.original,journal.builtin) || journal.parkingCount>2
        || journal.forwardDone>4 || journal.reverseDone>4 || journal.selectionDone>3)
        return fail(why,"invalid whole-Space journal header");
    const Display *builtin=findDisplay(journal.original,journal.builtin);
    if(!builtin || journal.selected[0]!=builtin->current)
        return fail(why,"whole-Space built-in selection does not match the original topology");
    int selectedIndex=1;
    for(const auto &display:journal.original.displays)if(display.uuid!=journal.builtin)
        if(selectedIndex>2 || journal.selected[selectedIndex++]!=display.current)
            return fail(why,"whole-Space selected identities do not match the original topology");
    if(selectedIndex!=3)return fail(why,"whole-Space external selection count is invalid");
    for(uint8_t index=0;index<journal.parkingCount;index++)
        if(!journal.parking[index] || journal.parkingUUID[index].empty())
            return fail(why,"whole-Space parking identity is incomplete");
    for(uint8_t index=journal.parkingCount;index<2;index++)
        if(journal.parking[index] || !journal.parkingUUID[index].empty())
            return fail(why,"whole-Space parking count is inconsistent");
    if(journal.parkingCount==2) {
        if(!journal.active || !validTopology(journal.prepared))return fail(why,"whole-Space prepared topology is invalid");
        Topology expected=journal.original;
        Display *preparedBuiltin=findDisplay(expected,journal.builtin);
        if(!preparedBuiltin)return fail(why,"whole-Space prepared built-in display is unavailable");
        for(uint8_t index=0;index<2;index++) {
            preparedBuiltin->order.push_back(journal.parking[index]);
            preparedBuiltin->spaceUUIDs.push_back(journal.parkingUUID[index]);
        }
        if(!equal(expected,journal.prepared))return fail(why,"whole-Space prepared topology does not match its parking identities");
    } else if(journal.active || !journal.prepared.displays.empty() || journal.forwardDone || journal.reverseDone
        || journal.pending.active || journal.runtimeSelectionPending.active || journal.selectionDone
        || journal.selectionPending.active)return fail(why,"whole-Space preparation stages are inconsistent");
    if(journal.legacyTerminalCleanup && (journal.version!=3 || !journal.active
        || journal.parkingCount!=2 || journal.forwardDone!=4 || journal.reverseDone!=4
        || journal.pending.active || journal.runtimeSelectionPending.active
        || journal.selectionPending.active || journal.runtimeCurrent!=journal.selected[0]))
        return fail(why,"legacy terminal cleanup stage is inconsistent");
    if(journal.runtimeCurrent!=journal.selected[0] && journal.runtimeCurrent!=journal.selected[1]
        && journal.runtimeCurrent!=journal.selected[2])return fail(why,"whole-Space runtime selection is not a designated Space");
    if(journal.pending.active) {
        uint8_t done=journal.pending.direction==Direction::Forward ? journal.forwardDone : journal.reverseDone;
        if(journal.pending.ordinal!=done || done>=4)return fail(why,"whole-Space pending move ordinal is invalid");
        if((journal.pending.direction==Direction::Forward && journal.reverseDone)
            || (journal.pending.direction==Direction::Reverse
                && (journal.forwardDone!=4 || journal.runtimeCurrent!=journal.selected[0])))
            return fail(why,"whole-Space pending move stage is inconsistent");
        Topology stage;
        Move exact;
        if(!stageTopology(journal,journal.pending.direction,journal.pending.ordinal,stage)
            || !makeMove(journal,journal.pending.direction==Direction::Reverse,
                journal.pending.ordinal,stage,exact) || !sameMove(exact,journal.pending.move))
            return fail(why,"whole-Space pending move does not match its deterministic stage");
    }
    if((journal.reverseDone && journal.forwardDone!=4)
        || (journal.selectionDone && journal.reverseDone!=4)
        || (journal.forwardDone<4 && journal.runtimeCurrent!=journal.selected[0]))
        return fail(why,"whole-Space transaction stages are inconsistent");
    if(journal.runtimeSelectionPending.active) {
        bool target=false;
        for(uint64_t sid:journal.selected)if(sid==journal.runtimeSelectionPending.target)target=true;
        if(journal.forwardDone!=4 || journal.reverseDone
            || journal.runtimeSelectionPending.display!=journal.builtin
            || journal.runtimeSelectionPending.from!=journal.runtimeCurrent
            || journal.runtimeSelectionPending.target==journal.runtimeCurrent || !target)
            return fail(why,"whole-Space runtime selection pending stage is invalid");
    }
    if(journal.selectionPending.active && (journal.reverseDone!=4
        || journal.selectionPending.ordinal!=journal.selectionDone))
        return fail(why,"whole-Space restore selection pending stage is invalid");
    if(journal.selectionPending.active) {
        const Display &original=journal.original.displays[journal.selectionDone];
        Topology stage;
        if(journal.selectionPending.display!=original.uuid
            || journal.selectionPending.target!=original.current
            || !stageTopology(journal,Direction::Reverse,4,stage))
            return fail(why,"whole-Space restore selection identity is invalid");
        for(uint8_t ordinal=0;ordinal<journal.selectionDone;ordinal++) {
            const Display &prior=journal.original.displays[ordinal];
            Display *display=findDisplay(stage,prior.uuid);
            if(!display)return fail(why,"whole-Space restore selection topology is invalid");
            display->current=prior.current;
        }
        const Display *display=findDisplay(stage,original.uuid);
        if(!display || journal.selectionPending.from!=display->current)
            return fail(why,"whole-Space restore selection source is invalid");
    }
    return true;
}

}

bool preservesKnownTopology(const Journal &journal,const Topology &expected,const Topology &actual) {
    return knownTopologyMatches(journal,expected,actual,true);
}

bool eligible(const Topology &topology,const std::string &builtin,
              const std::function<int(uint64_t)> &spaceType,std::string *why) {
    if(!validTopology(topology) || !findDisplay(topology,builtin))
        return fail(why,"exactly three complete managed display inventories are required");
    if(!spaceType)return fail(why,"Space type inspection is unavailable");
    std::set<uint64_t> selectedSpaces;
    for(const auto &display:topology.displays) {
        if(spaceType(display.current)!=0 || !selectedSpaces.insert(display.current).second)
            return fail(why,"each selected Space must be distinct and type 0");
        for(uint64_t sid:display.order)
            if(spaceType(sid)!=0 && spaceType(sid)!=4)
                return fail(why,"whole-Space migration supports only ordinary and background full-screen Spaces");
    }
    return true;
}

bool begin(Journal &journal,const Topology &original,const std::string &builtin,
           const std::function<int(uint64_t)> &spaceType,std::string *why) {
    if(!eligible(original,builtin,spaceType,why))return false;
    Journal next;
    next.builtin=builtin;
    for(const auto &display:original.displays) {
        Display ordinary;
        ordinary.uuid=display.uuid;ordinary.current=display.current;
        for(size_t index=0;index<display.order.size();index++)if(spaceType(display.order[index])==0) {
            ordinary.order.push_back(display.order[index]);
            ordinary.spaceUUIDs.push_back(display.spaceUUIDs[index]);
        }
        next.original.displays.push_back(std::move(ordinary));
    }
    if(!validTopology(next.original))return fail(why,"ordinary managed Space inventory is incomplete");
    next.runtimeCurrent=findDisplay(next.original,builtin)->current;
    next.selected[0]=next.runtimeCurrent;
    int index=1;
    for(const auto &display:next.original.displays)if(display.uuid!=builtin)next.selected[index++]=display.current;
    journal=std::move(next);
    return true;
}

bool addParking(Journal &journal,const Topology &topology,uint64_t parking,
                const std::string &parkingUUID,const std::function<int(uint64_t)> &spaceType,
                std::string *why) {
    if(journal.active || journal.parkingCount>1 || !parking || parkingUUID.empty() || !spaceType
        || spaceType(parking)!=0)return fail(why,"new parking Space identity is invalid");
    for(uint8_t index=0;index<journal.parkingCount;index++)if(journal.parking[index]==parking)
        return fail(why,"parking Space identity is duplicated");
    Topology expected=journal.original;
    Display *builtin=findDisplay(expected,journal.builtin);
    const Display *actual=findDisplay(topology,journal.builtin);
    if(!builtin || !actual)return fail(why,"built-in parking topology is unavailable");
    for(uint8_t index=0;index<journal.parkingCount;index++) {
        builtin->order.push_back(journal.parking[index]);
        builtin->spaceUUIDs.push_back(journal.parkingUUID[index]);
    }
    builtin->order.push_back(parking);
    builtin->spaceUUIDs.push_back(parkingUUID);
    uint8_t index=journal.parkingCount;
    Journal next=journal;
    next.parking[index]=parking;
    next.parkingUUID[index]=parkingUUID;
    next.parkingCount++;
    if(!knownTopologyMatches(next,expected,topology,true))
        return fail(why,"parking creation changed the original display topology");
    if(next.parkingCount==2) {
        next.prepared=expected;
        next.active=true;
    }
    journal=std::move(next);
    return true;
}

bool initialize(Journal &journal,const Topology &prepared,const std::string &builtin,
                uint64_t parking1,uint64_t parking2,const std::string &parkingUUID1,
                const std::string &parkingUUID2,const std::function<int(uint64_t)> &spaceType,
                std::string *why) {
    if(!validTopology(prepared))return fail(why,"prepared whole-Space topology is invalid");
    Topology original=prepared;
    Display *display=findDisplay(original,builtin);
    if(!display)return false;
    for(uint64_t parking:{parking1,parking2}) {
        auto found=std::find(display->order.begin(),display->order.end(),parking);
        if(found==display->order.end())return fail(why,"parking Space is not on the built-in display");
        size_t index=(size_t)(found-display->order.begin());
        display->order.erase(found);
        display->spaceUUIDs.erase(display->spaceUUIDs.begin()+index);
    }
    if(!begin(journal,original,builtin,spaceType,why))return false;
    Topology first=original;
    findDisplay(first,builtin)->order.push_back(parking1);
    findDisplay(first,builtin)->spaceUUIDs.push_back(parkingUUID1);
    if(!addParking(journal,first,parking1,parkingUUID1,spaceType,why))return false;
    return addParking(journal,prepared,parking2,parkingUUID2,spaceType,why);
}

bool upgradeLegacyFullscreenJournal(Journal &journal,const Topology &capturedOriginal,
                                    const std::function<int(uint64_t)> &capturedSpaceType,
                                    std::string *why) {
    if(journal.version!=2 || !capturedSpaceType || !validateJournal(journal,why))
        return fail(why,"legacy whole-Space journal is not eligible for evidence upgrade");
    if(!equal(journal.original,capturedOriginal))
        return fail(why,"captured topology does not exactly match the legacy journal");
    Journal next=journal;
    bool terminalCleanup=journal.active && journal.parkingCount==2
        && journal.forwardDone==4 && journal.reverseDone==4 && journal.selectionDone==3
        && !journal.pending.active && !journal.runtimeSelectionPending.active
        && !journal.selectionPending.active && journal.runtimeCurrent==journal.selected[0];
    Topology ordinary;
    for(const auto &display:capturedOriginal.displays) {
        Display filtered;
        filtered.uuid=display.uuid;filtered.current=display.current;
        for(size_t index=0;index<display.order.size();index++) {
            int kind=capturedSpaceType(display.order[index]);
            if(kind!=0 && kind!=4)return fail(why,"captured Space type evidence is incomplete");
            if(kind==0) {
                filtered.order.push_back(display.order[index]);
                filtered.spaceUUIDs.push_back(display.spaceUUIDs[index]);
            }
        }
        ordinary.displays.push_back(std::move(filtered));
    }
    if(!validTopology(ordinary))return fail(why,"captured ordinary topology is incomplete");
    for(uint64_t selected:journal.selected)if(capturedSpaceType(selected)!=0)
        return fail(why,"captured evidence reclassifies a designated Space");
    next.version=3;next.original=std::move(ordinary);
    if(terminalCleanup) {
        next.selectionDone=0;
        next.legacyTerminalCleanup=true;
    }
    if(next.parkingCount==2) {
        next.prepared=next.original;
        Display *builtin=findDisplay(next.prepared,next.builtin);
        if(!builtin)return fail(why,"upgraded built-in topology is unavailable");
        for(uint8_t index=0;index<2;index++) {
            builtin->order.push_back(next.parking[index]);
            builtin->spaceUUIDs.push_back(next.parkingUUID[index]);
        }
    }
    if(next.pending.active) {
        Topology stage;Move exact;
        if(!stageTopology(next,next.pending.direction,next.pending.ordinal,stage)
            || !makeMove(next,next.pending.direction==Direction::Reverse,
                next.pending.ordinal,stage,exact)
            || exact.sid!=journal.pending.move.sid
            || exact.from.display!=journal.pending.move.from.display
            || exact.to.display!=journal.pending.move.to.display)
            return fail(why,"legacy pending move cannot be preserved by evidence upgrade");
        next.pending.move=std::move(exact);
    }
    if(!validateJournal(next,why))return false;
    journal=std::move(next);return true;
}

bool reconcile(Journal &journal,const Topology &current,std::string *why) {
    if(!journal.pending.active)return true;
    uint8_t &done=journal.pending.direction==Direction::Forward ? journal.forwardDone : journal.reverseDone;
    if(done!=journal.pending.ordinal)return fail(why,"pending whole-Space move does not match its durable stage");
    Topology before;
    if(!stageTopology(journal,journal.pending.direction,journal.pending.ordinal,before))return false;
    Move exact;
    if(!makeMove(journal,journal.pending.direction==Direction::Reverse,journal.pending.ordinal,before,exact)
        || !sameMove(exact,journal.pending.move))return fail(why,"pending whole-Space move is not deterministic");
    Topology after;
    if(!apply(before,exact,after))return false;
    if(knownTopologyMatches(journal,before,current,true)){journal.pending={};return true;}
    if(knownTopologyMatches(journal,after,current,true)){done++;journal.pending={};return true;}
    return fail(why,"pending whole-Space move has unrelated topology changes");
}

bool advanceForward(Journal &journal,Hooks &hooks,std::string *why) {
    return advance(journal,hooks,false,why);
}

bool selectRuntime(Journal &journal,Hooks &hooks,uint64_t target,std::string *why) {
    if(!journal.active || journal.forwardDone!=4 || journal.reverseDone || journal.pending.active
        || !hooks.persist || !hooks.topology || !hooks.select)
        return fail(why,"whole-Space runtime selection is unavailable");
    bool designated=false;
    for(uint64_t sid:journal.selected)if(sid==target)designated=true;
    if(!designated)return fail(why,"runtime selection is not a designated Space");
    Topology expected;
    if(!stageTopology(journal,Direction::Forward,4,expected))return false;
    Display *builtin=findDisplay(expected,journal.builtin);
    if(!builtin)return false;
    builtin->current=journal.runtimeCurrent;
    if(journal.runtimeSelectionPending.active) {
        if(journal.runtimeSelectionPending.display!=journal.builtin
            || journal.runtimeSelectionPending.from!=journal.runtimeCurrent)
            return fail(why,"pending runtime selection identity is invalid");
        Topology current=hooks.topology();
        if(!knownTopologyMatches(journal,expected,current,false))
            return fail(why,"pending runtime selection has unrelated topology changes");
        Topology after=expected;
        findDisplay(after,journal.builtin)->current=journal.runtimeSelectionPending.target;
        const Display *liveBuiltin=findDisplay(current,journal.builtin);
        if(!liveBuiltin)return false;
        if(liveBuiltin->current==journal.runtimeSelectionPending.target) {
            if(!normalizeCurrents(journal,after,hooks,why))return false;
        } else {
            if(!normalizeCurrents(journal,expected,hooks,why)
                || !hooks.select(journal.builtin,journal.runtimeSelectionPending.target)
                || !normalizeCurrents(journal,after,hooks,why))
                return fail(why,"pending runtime selection could not be completed");
        }
        journal.runtimeCurrent=journal.runtimeSelectionPending.target;
        journal.runtimeSelectionPending={};
        if(!hooks.persist(journal))return fail(why,"reconciled runtime selection could not be persisted");
        builtin->current=journal.runtimeCurrent;
    }
    if(!normalizeCurrents(journal,expected,hooks,why))
        return fail(why,"whole-Space topology changed before runtime selection");
    if(journal.runtimeCurrent==target)return true;
    journal.runtimeSelectionPending={true,0,journal.builtin,journal.runtimeCurrent,target};
    if(!hooks.persist(journal)){journal.runtimeSelectionPending={};return fail(why,"runtime selection intent was not persisted");}
    if(!hooks.select(journal.builtin,target))return fail(why,"runtime selection failed with durable pending intent");
    Topology after=expected;findDisplay(after,journal.builtin)->current=target;
    if(!normalizeCurrents(journal,after,hooks,why))return fail(why,"runtime selection reached an unexpected topology");
    journal.runtimeCurrent=target;
    journal.runtimeSelectionPending={};
    if(!hooks.persist(journal))return fail(why,"completed runtime selection retained its durable pending record");
    return true;
}

bool normalizeForReverse(Journal &journal,Hooks &hooks,std::string *why) {
    return selectRuntime(journal,hooks,journal.selected[0],why);
}

bool advanceReverse(Journal &journal,Hooks &hooks,std::string *why) {
    return advance(journal,hooks,true,why);
}

bool advanceSelections(Journal &journal,Hooks &hooks,std::string *why) {
    if(journal.reverseDone!=4 || journal.pending.active || journal.selectionDone>2
        || !hooks.persist || !hooks.topology || !hooks.select)
        return fail(why,"whole-Space selection restoration is unavailable");
    Topology expected;
    if(!stageTopology(journal,Direction::Reverse,4,expected))return false;
    for(uint8_t ordinal=0;ordinal<journal.selectionDone;ordinal++) {
        const Display &original=journal.original.displays[ordinal];
        Display *display=findDisplay(expected,original.uuid);
        if(!display)return false;
        display->current=original.current;
    }
    if(journal.selectionPending.active) {
        if(journal.selectionPending.ordinal!=journal.selectionDone)
            return fail(why,"pending restore selection ordinal is invalid");
        Topology current=hooks.topology();
        if(!knownTopologyMatches(journal,expected,current,false))
            return fail(why,"pending restore selection has unrelated topology changes");
        Topology after=expected;
        Display *afterDisplay=findDisplay(after,journal.selectionPending.display);
        const Display *liveDisplay=findDisplay(current,journal.selectionPending.display);
        if(!afterDisplay || !liveDisplay)return false;
        afterDisplay->current=journal.selectionPending.target;
        if(liveDisplay->current==journal.selectionPending.target) {
            if(!normalizeCurrents(journal,after,hooks,why))return false;
        } else {
            if(!normalizeCurrents(journal,expected,hooks,why)
                || !hooks.select(journal.selectionPending.display,journal.selectionPending.target)
                || !normalizeCurrents(journal,after,hooks,why))
                return fail(why,"pending restore selection could not be completed");
        }
        journal.selectionDone++;
        journal.selectionPending={};
        if(!hooks.persist(journal))return fail(why,"reconciled restore selection could not be persisted");
        return true;
    }
    if(!normalizeCurrents(journal,expected,hooks,why))
        return fail(why,"topology changed before exact selection restoration");
    if(journal.selectionDone==3)return true;
    const Display &original=journal.original.displays[journal.selectionDone];
    const Display *display=findDisplay(expected,original.uuid);
    if(!display)return false;
    journal.selectionPending={true,journal.selectionDone,original.uuid,display->current,original.current};
    if(!hooks.persist(journal)){journal.selectionPending={};return fail(why,"selection restore intent was not persisted");}
    if(!hooks.select(original.uuid,original.current))return fail(why,"selection restore failed with durable pending intent");
    Topology after=expected;findDisplay(after,original.uuid)->current=original.current;
    if(!normalizeCurrents(journal,after,hooks,why))return fail(why,"selection restore reached an unexpected topology");
    journal.selectionDone++;
    journal.selectionPending={};
    if(!hooks.persist(journal))return fail(why,"completed selection restore retained its durable pending record");
    return true;
}

bool restoreLegacyTerminalSelections(Journal &journal,Hooks &hooks,std::string *why) {
    if(!journal.legacyTerminalCleanup || journal.selectionDone>3 || journal.selectionPending.active
        || !hooks.persist || !hooks.topology || !hooks.select)
        return fail(why,"legacy terminal selection restoration is unavailable");
    Topology current=hooks.topology();
    if(!legacyTerminalTopologyMatches(journal,current,{journal.parking[0],journal.parking[1]},false))
        return fail(why,"legacy terminal topology changed outside fullscreen extras or parking order");
    for(const auto &original:journal.original.displays) {
        const Display *display=findDisplay(current,original.uuid);
        if(!display)return false;
        if(display->current==original.current)continue;
        if(!hooks.select(original.uuid,original.current))
            return fail(why,"legacy terminal selection restoration failed");
        Topology after=hooks.topology();
        if(!sameLayout(current,after)
            || !legacyTerminalTopologyMatches(journal,after,{journal.parking[0],journal.parking[1]},false))
            return fail(why,"legacy terminal selection changed Space identity or order");
        current=std::move(after);
    }
    if(!legacyTerminalTopologyMatches(journal,current,{journal.parking[0],journal.parking[1]},true))
        return fail(why,"legacy terminal selections remain unexpected");
    journal.selectionDone=3;
    if(!hooks.persist(journal)) {
        journal.selectionDone=0;
        return fail(why,"legacy terminal selection completion could not be persisted");
    }
    return true;
}

bool preparationTopology(const Journal &journal,const Topology &topology) {
    if(journal.forwardDone || journal.reverseDone || journal.pending.active
        || journal.runtimeSelectionPending.active || journal.selectionDone
        || journal.selectionPending.active || journal.parkingCount>2)return false;
    Topology expected=journal.original;
    Display *builtin=findDisplay(expected,journal.builtin);
    if(!builtin)return false;
    for(uint8_t index=0;index<journal.parkingCount;index++) {
        builtin->order.push_back(journal.parking[index]);
        builtin->spaceUUIDs.push_back(journal.parkingUUID[index]);
    }
    return knownTopologyMatches(journal,expected,topology,true);
}

bool preparationCleanupExpected(const Journal &journal,const std::vector<uint64_t> &remaining,
                                Topology &expected) {
    if(journal.forwardDone || journal.reverseDone || journal.pending.active
        || journal.runtimeSelectionPending.active || journal.selectionDone
        || journal.selectionPending.active || journal.parkingCount>2)return false;
    std::set<uint64_t> keep(remaining.begin(),remaining.end());
    if(keep.size()!=remaining.size())return false;
    expected=journal.original;
    Display *builtin=findDisplay(expected,journal.builtin);
    if(!builtin)return false;
    for(uint8_t index=0;index<journal.parkingCount;index++)if(keep.count(journal.parking[index])) {
        builtin->order.push_back(journal.parking[index]);
        builtin->spaceUUIDs.push_back(journal.parkingUUID[index]);
        keep.erase(journal.parking[index]);
    }
    return keep.empty();
}

bool normalizePreparationCleanup(const Journal &journal,const std::vector<uint64_t> &remaining,
                                 Hooks &hooks,std::string *why) {
    Topology expected;
    if(!preparationCleanupExpected(journal,remaining,expected))
        return fail(why,"parking preparation cleanup state is invalid");
    return normalizeCurrents(journal,expected,hooks,why);
}

bool preparationCleanupTopology(const Journal &journal,const Topology &topology,
                                const std::vector<uint64_t> &remaining) {
    Topology expected;
    return preparationCleanupExpected(journal,remaining,expected)
        && knownTopologyMatches(journal,expected,topology,true);
}

bool runtimeTopology(const Journal &journal,const Topology &topology) {
    if(journal.forwardDone!=4 || journal.reverseDone || journal.pending.active
        || journal.runtimeSelectionPending.active)return false;
    Topology expected;
    if(!stageTopology(journal,Direction::Forward,4,expected))return false;
    Display *builtin=findDisplay(expected,journal.builtin);
    if(!builtin)return false;
    builtin->current=journal.runtimeCurrent;
    return knownTopologyMatches(journal,expected,topology,true);
}

bool cleanupTopology(const Journal &journal,const Topology &topology,
                     const std::vector<uint64_t> &remaining) {
    if(journal.reverseDone!=4 || journal.selectionDone!=3 || journal.pending.active
        || journal.runtimeSelectionPending.active || journal.selectionPending.active)return false;
    std::set<uint64_t> keep(remaining.begin(),remaining.end());
    if(keep.size()!=remaining.size())return false;
    for(uint64_t sid:keep)if(sid!=journal.parking[0] && sid!=journal.parking[1])return false;
    Topology expected;
    if(!stageTopology(journal,Direction::Reverse,4,expected))return false;
    for(const auto &original:journal.original.displays) {
        Display *display=findDisplay(expected,original.uuid);
        if(!display)return false;
        display->current=original.current;
    }
    for(uint64_t sid:journal.parking)if(!keep.count(sid)) {
        Endpoint endpoint;
        if(!locate(expected,sid,endpoint) || endpoint.display!=journal.builtin)return false;
        Display *display=findDisplay(expected,endpoint.display);
        display->order.erase(display->order.begin()+endpoint.index);
        display->spaceUUIDs.erase(display->spaceUUIDs.begin()+endpoint.index);
    }
    return equal(expected,topology);
}

bool cleanupTopologyPreservingExtras(const Journal &journal,const Topology &topology,
                                     const std::vector<uint64_t> &remaining) {
    if(journal.reverseDone!=4 || journal.selectionDone!=3 || journal.pending.active
        || journal.runtimeSelectionPending.active || journal.selectionPending.active)return false;
    std::set<uint64_t> keep(remaining.begin(),remaining.end());
    if(keep.size()!=remaining.size())return false;
    for(uint64_t sid:keep)if(sid!=journal.parking[0] && sid!=journal.parking[1])return false;
    Topology expected;
    if(!stageTopology(journal,Direction::Reverse,4,expected))return false;
    for(const auto &original:journal.original.displays) {
        Display *display=findDisplay(expected,original.uuid);
        if(!display)return false;
        display->current=original.current;
    }
    for(uint64_t sid:journal.parking)if(!keep.count(sid)) {
        Endpoint endpoint;
        if(!locate(expected,sid,endpoint) || endpoint.display!=journal.builtin)return false;
        Display *display=findDisplay(expected,endpoint.display);
        display->order.erase(display->order.begin()+endpoint.index);
        display->spaceUUIDs.erase(display->spaceUUIDs.begin()+endpoint.index);
    }
    return knownTopologyMatches(journal,expected,topology,true);
}

bool legacyTerminalCleanupTopology(const Journal &journal,const Topology &topology,
                                   const std::vector<uint64_t> &remaining) {
    return journal.selectionDone==3 && !journal.selectionPending.active
        && legacyTerminalTopologyMatches(journal,topology,remaining,true);
}

bool finalPrepared(const Journal &journal,const Topology &topology) {
    Topology expected;
    if(!stageTopology(journal,Direction::Reverse,4,expected))return false;
    for(const auto &original:journal.original.displays) {
        Display *display=findDisplay(expected,original.uuid);
        if(!display)return false;
        display->current=original.current;
    }
    return knownTopologyMatches(journal,expected,topology,true);
}

bool finalOriginal(const Journal &journal,const Topology &topology) {
    return equal(journal.original,topology);
}

bool finalOriginalPreservingExtras(const Journal &journal,const Topology &topology) {
    return knownTopologyMatches(journal,journal.original,topology,true);
}

bool parkingRemovalEndpoint(const Journal &journal,const Topology &before,uint64_t removed,
                            const Topology &after,std::string *why) {
    if(removed!=journal.parking[0] && removed!=journal.parking[1])
        return fail(why,"removed Space is not an owned parking identity");
    Topology expected=before;
    Endpoint endpoint;
    if(!locate(expected,removed,endpoint) || endpoint.display!=journal.builtin)
        return fail(why,"owned parking Space is not uniquely on the built-in display");
    Display *display=findDisplay(expected,endpoint.display);
    if(display->current==removed)return fail(why,"selected parking Space cannot be removed");
    display->order.erase(display->order.begin()+endpoint.index);
    display->spaceUUIDs.erase(display->spaceUUIDs.begin()+endpoint.index);
    return validTopology(expected) && equal(expected,after);
}

NSDictionary *encode(const Journal &journal) {
    id pending=journal.pending.active ? @{
        @"direction":@((int)journal.pending.direction),@"ordinal":@(journal.pending.ordinal),
        @"sid":@(journal.pending.move.sid),@"from":encodeEndpoint(journal.pending.move.from),
        @"to":encodeEndpoint(journal.pending.move.to)} : (id)NSNull.null;
    auto selection=[](const SelectionPending &value)->id {
        return value.active ? @{@"ordinal":@(value.ordinal),
            @"display":[NSString stringWithUTF8String:value.display.c_str()],
            @"from":@(value.from),@"target":@(value.target)} : (id)NSNull.null;
    };
    return @{@"version":@(journal.version),@"active":@(journal.active),
        @"builtin":[NSString stringWithUTF8String:journal.builtin.c_str()],
        @"original":encodeTopology(journal.original),
        @"prepared":journal.prepared.displays.empty() ? (id)NSNull.null : encodeTopology(journal.prepared),
        @"selected":@[@(journal.selected[0]),@(journal.selected[1]),@(journal.selected[2])],
        @"parking":@[@(journal.parking[0]),@(journal.parking[1])],
        @"parkingUUID":@[[NSString stringWithUTF8String:journal.parkingUUID[0].c_str()],
                          [NSString stringWithUTF8String:journal.parkingUUID[1].c_str()]],
        @"parkingCount":@(journal.parkingCount),@"forwardDone":@(journal.forwardDone),
        @"reverseDone":@(journal.reverseDone),@"pending":pending,
        @"runtimeCurrent":@(journal.runtimeCurrent),
        @"runtimeSelectionPending":selection(journal.runtimeSelectionPending),
        @"selectionDone":@(journal.selectionDone),@"selectionPending":selection(journal.selectionPending),
        @"legacyTerminalCleanup":@(journal.legacyTerminalCleanup)};
}

bool decode(NSDictionary *dictionary,Journal &output,std::string *why) {
    Journal parsed;
    if(![dictionary isKindOfClass:NSDictionary.class]
        || ![dictionary[@"version"] isKindOfClass:NSNumber.class]
        || ([dictionary[@"version"] unsignedIntValue]!=2
            && [dictionary[@"version"] unsignedIntValue]!=3)
        || ![dictionary[@"active"] isKindOfClass:NSNumber.class]
        || !parseString(dictionary[@"builtin"],parsed.builtin)
        || !parseTopology(dictionary[@"original"],parsed.original)
        || !parseTopology(dictionary[@"prepared"],parsed.prepared,true))
        return fail(why,"invalid whole-Space journal header");
    parsed.version=[dictionary[@"version"] unsignedIntValue];
    if(parsed.version==3 && ![dictionary[@"legacyTerminalCleanup"] isKindOfClass:NSNumber.class])
        return fail(why,"schema-v3 whole-Space cleanup state is missing");
    parsed.legacyTerminalCleanup=parsed.version==3 && [dictionary[@"legacyTerminalCleanup"] boolValue];
    parsed.active=[dictionary[@"active"] boolValue];
    NSArray *selected=dictionary[@"selected"],*parking=dictionary[@"parking"],*uuids=dictionary[@"parkingUUID"];
    if(![selected isKindOfClass:NSArray.class] || selected.count!=3
        || ![parking isKindOfClass:NSArray.class] || parking.count!=2
        || ![uuids isKindOfClass:NSArray.class] || uuids.count!=2)return false;
    for(int index=0;index<3;index++)if(!parseNumber(selected[index],parsed.selected[index]))return false;
    for(int index=0;index<2;index++) {
        if(!parseNumber(parking[index],parsed.parking[index],true)
            || ![uuids[index] isKindOfClass:NSString.class])return false;
        parsed.parkingUUID[index]=[uuids[index] UTF8String];
    }
    for(NSString *key in @[@"parkingCount",@"forwardDone",@"reverseDone",@"selectionDone"])
        if(![dictionary[key] isKindOfClass:NSNumber.class])return false;
    parsed.parkingCount=[dictionary[@"parkingCount"] unsignedCharValue];
    parsed.forwardDone=[dictionary[@"forwardDone"] unsignedCharValue];
    parsed.reverseDone=[dictionary[@"reverseDone"] unsignedCharValue];
    parsed.selectionDone=[dictionary[@"selectionDone"] unsignedCharValue];
    if(!parseNumber(dictionary[@"runtimeCurrent"],parsed.runtimeCurrent))return false;
    id rawPending=dictionary[@"pending"];
    if(rawPending!=NSNull.null) {
        uint64_t direction=0,ordinal=0,sid=0;
        if(![rawPending isKindOfClass:NSDictionary.class]
            || !parseNumber(rawPending[@"direction"],direction)
            || ![rawPending[@"ordinal"] isKindOfClass:NSNumber.class]
            || !parseNumber(rawPending[@"sid"],sid) || direction>2)return false;
        ordinal=[rawPending[@"ordinal"] unsignedLongLongValue];
        id from=rawPending[@"from"],to=rawPending[@"to"];
        std::string fromDisplay,toDisplay;
        if(ordinal>3 || ![from isKindOfClass:NSDictionary.class] || ![to isKindOfClass:NSDictionary.class]
            || !parseString(from[@"display"],fromDisplay) || !parseString(to[@"display"],toDisplay)
            || ![from[@"index"] isKindOfClass:NSNumber.class] || ![to[@"index"] isKindOfClass:NSNumber.class])return false;
        parsed.pending={true,(Direction)direction,(uint8_t)ordinal,
            {sid,{fromDisplay,[from[@"index"] unsignedIntValue]},
                 {toDisplay,[to[@"index"] unsignedIntValue]}}};
    }
    if(!parseSelection(dictionary[@"runtimeSelectionPending"],parsed.runtimeSelectionPending,true)
        || !parseSelection(dictionary[@"selectionPending"],parsed.selectionPending,false)
        || !validateJournal(parsed,why))return false;
    output=std::move(parsed);
    return true;
}

}
