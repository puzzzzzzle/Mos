#ifndef MOS_MULTITOUCH_BRIDGE_H
#define MOS_MULTITOUCH_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

/// Value copies only; the framework-owned touch buffer never crosses this API.
typedef struct {
    int32_t identity;
    int32_t state;
    float x;
    float y;
} MosTrackpadContact;

typedef void (*MosTrackpadCallback)(uintptr_t device, const MosTrackpadContact *touches,
                                 int32_t count, double timestamp, double receivedAt,
                                 uint64_t generation);

// Main-thread lifecycle only. Callbacks run on framework threads.
bool MosTrackpadStart(MosTrackpadCallback callback, uint64_t generation);
void MosTrackpadStop(void);
int32_t MosTrackpadDeviceCount(void);
const char *MosTrackpadError(void);

#endif
