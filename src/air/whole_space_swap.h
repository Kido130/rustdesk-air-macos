#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#ifdef __OBJC__
@class NSDictionary;
#endif

namespace air::whole_space {

struct Display {
    std::string uuid;
    std::vector<uint64_t> order;
    std::vector<std::string> spaceUUIDs;
    uint64_t current=0;
};

struct Topology {
    std::vector<Display> displays;
};

struct Endpoint {
    std::string display;
    uint32_t index=0;
};

struct Move {
    uint64_t sid=0;
    Endpoint from,to;
};

enum class Direction : uint8_t { Forward=1, Reverse=2 };

struct Pending {
    bool active=false;
    Direction direction=Direction::Forward;
    uint8_t ordinal=0;
    Move move;
};

struct SelectionPending {
    bool active=false;
    uint8_t ordinal=0;
    std::string display;
    uint64_t from=0,target=0;
};

struct Journal {
    uint32_t version=3;
    bool active=false;
    std::string builtin;
    Topology original;
    Topology prepared;
    uint64_t selected[3]{};
    uint64_t parking[2]{};
    std::string parkingUUID[2];
    uint8_t parkingCount=0;
    uint8_t forwardDone=0;
    uint8_t reverseDone=0;
    Pending pending;
    uint64_t runtimeCurrent=0;
    SelectionPending runtimeSelectionPending;
    uint8_t selectionDone=0;
    SelectionPending selectionPending;
    bool legacyTerminalCleanup=false;
};

struct Hooks {
    std::function<bool(const Journal&)> persist;
    std::function<Topology()> topology;
    std::function<bool(uint64_t,const std::string&,uint32_t)> move;
    std::function<bool(const std::string&,uint64_t)> select;
};

bool eligible(const Topology&,const std::string &builtin,
              const std::function<int(uint64_t)> &spaceType,std::string *why);
bool begin(Journal&,const Topology&,const std::string &builtin,
           const std::function<int(uint64_t)> &spaceType,std::string *why);
bool addParking(Journal&,const Topology&,uint64_t parking,const std::string &parkingUUID,
                const std::function<int(uint64_t)> &spaceType,std::string *why);
bool initialize(Journal&,const Topology&,const std::string &builtin,
                uint64_t parking1,uint64_t parking2,
                const std::string &parkingUUID1,const std::string &parkingUUID2,
                const std::function<int(uint64_t)> &spaceType,std::string *why);
bool upgradeLegacyFullscreenJournal(Journal&,const Topology &capturedOriginal,
                                    const std::function<int(uint64_t)> &capturedSpaceType,
                                    std::string *why);
bool advanceForward(Journal&,Hooks&,std::string *why);
bool selectRuntime(Journal&,Hooks&,uint64_t target,std::string *why);
bool normalizeForReverse(Journal&,Hooks&,std::string *why);
bool advanceReverse(Journal&,Hooks&,std::string *why);
bool advanceSelections(Journal&,Hooks&,std::string *why);
bool restoreLegacyTerminalSelections(Journal&,Hooks&,std::string *why);
bool reconcile(Journal&,const Topology&,std::string *why);
bool preservesKnownTopology(const Journal&,const Topology &expected,const Topology &actual);
bool preparationTopology(const Journal&,const Topology&);
bool normalizePreparationCleanup(const Journal&,const std::vector<uint64_t> &remaining,
                                 Hooks&,std::string *why);
bool preparationCleanupTopology(const Journal&,const Topology&,const std::vector<uint64_t> &remaining);
bool runtimeTopology(const Journal&,const Topology&);
bool cleanupTopology(const Journal&,const Topology&,const std::vector<uint64_t> &remaining);
bool cleanupTopologyPreservingExtras(const Journal&,const Topology&,const std::vector<uint64_t> &remaining);
bool legacyTerminalCleanupTopology(const Journal&,const Topology&,
                                   const std::vector<uint64_t> &remaining);
bool finalPrepared(const Journal&,const Topology&);
bool finalOriginal(const Journal&,const Topology&);
bool finalOriginalPreservingExtras(const Journal&,const Topology&);
bool parkingRemovalEndpoint(const Journal&,const Topology &before,uint64_t removed,
                            const Topology &after,std::string *why);

#ifdef __OBJC__
NSDictionary *encode(const Journal&);
bool decode(NSDictionary *,Journal&,std::string *why);
#endif

}
