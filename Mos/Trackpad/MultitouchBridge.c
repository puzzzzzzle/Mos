#include "MultitouchBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>
#include <mach/mach_time.h>
#include <stdio.h>

// Undocumented ABI, isolated to the opt-in trackpad bridge. Declaration
// references: MiddleClick/MoreTouch and OpenMultitouchSupport/OpenMTInternal.h.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identity, state, fingerID, handID;
    MTVector normalizedVector;
    float total, pressure, angle, majorAxis, minorAxis;
    MTVector absoluteVector;
    int32_t field14, field15;
    float density;
} MTTouch;

_Static_assert(sizeof(MTTouch) == 96, "Unexpected private contact layout");
_Static_assert(offsetof(MTTouch, normalizedVector) == 32, "Unexpected position offset");

typedef void (*MTCallback)(void *, MTTouch *, int32_t, double, int32_t);
static void *framework;
static CFArrayRef devices;
static CFArrayRef (*createList)(void);
static void (*registerCallback)(void *, MTCallback);
static void (*unregisterCallback)(void *, MTCallback);
static int32_t (*startDevice)(void *, int32_t);
static int32_t (*stopDevice)(void *);
static bool (*isBuiltIn)(void *);
static bool (*isOpaque)(void *);
static int32_t (*getFamily)(void *, int32_t *);
static pthread_mutex_t callbackLock = PTHREAD_MUTEX_INITIALIZER;
static MosTrackpadCallback observer;
static uint64_t currentGeneration;
static char errorMessage[160];
static mach_timebase_info_data_t timebase;

static void receiveFrame(void *device, MTTouch *touches, int32_t count,
                         double timestamp, int32_t frame) {
    (void)frame;
    // This host clock is independent of the device's sample timestamp, which
    // may start at zero on connection. Capture it before reading the generation.
    double receivedAt = (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
    pthread_mutex_lock(&callbackLock);
    MosTrackpadCallback callback = observer;
    uint64_t generation = currentGeneration;
    pthread_mutex_unlock(&callbackLock);
    if (!callback || count < 0 || count > 32 || (count > 0 && !touches)) return;
    MosTrackpadContact snapshot[32];
    for (int32_t i = 0; i < count; i++) {
        snapshot[i] = (MosTrackpadContact){ touches[i].identity, touches[i].state,
            touches[i].normalizedVector.position.x, touches[i].normalizedVector.position.y };
    }
    callback((uintptr_t)device, snapshot, count, timestamp, receivedAt, generation);
}

static bool loadFramework(void) {
    if (framework) return true;
    framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                       RTLD_NOW | RTLD_LOCAL);
    if (!framework) {
        snprintf(errorMessage, sizeof(errorMessage), "MultitouchSupport could not be loaded.");
        return false;
    }
    createList = dlsym(framework, "MTDeviceCreateList");
    registerCallback = dlsym(framework, "MTRegisterContactFrameCallback");
    unregisterCallback = dlsym(framework, "MTUnregisterContactFrameCallback");
    startDevice = dlsym(framework, "MTDeviceStart");
    stopDevice = dlsym(framework, "MTDeviceStop");
    isBuiltIn = dlsym(framework, "MTDeviceIsBuiltIn");
    isOpaque = dlsym(framework, "MTDeviceIsOpaqueSurface");
    getFamily = dlsym(framework, "MTDeviceGetFamilyID");
    if (!createList || !registerCallback || !unregisterCallback || !startDevice || !stopDevice ||
        !isBuiltIn || !isOpaque || !getFamily) {
        snprintf(errorMessage, sizeof(errorMessage), "Required MultitouchSupport symbols are missing.");
        dlclose(framework);
        framework = NULL;
        return false;
    }
    // Keep the framework loaded: late callbacks must not execute unloaded code.
    mach_timebase_info(&timebase);
    return true;
}

bool MosTrackpadStart(MosTrackpadCallback callback, uint64_t generation) {
    MosTrackpadStop();
    errorMessage[0] = '\0';
    if (!callback || !loadFramework()) return false;
    CFArrayRef discovered = createList();
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (!selected) { if (discovered) CFRelease(discovered); return false; }
    if (discovered) {
        for (CFIndex i = 0; i < CFArrayGetCount(discovered); i++) {
            void *device = (void *)CFArrayGetValueAtIndex(discovered, i);
            int32_t family = 0;
            // Conservative initial scope: built-in non-display surfaces and
            // family 129, verified locally with this user's Magic Trackpad.
            // Unknown external families remain disabled until verified.
            if (!isOpaque(device) && (isBuiltIn(device) ||
                (getFamily(device, &family) == 0 && family == 129))) {
                CFArrayAppendValue(selected, device);
            }
        }
        CFRelease(discovered);
    }
    devices = selected;
    if (CFArrayGetCount(devices) == 0) {
        snprintf(errorMessage, sizeof(errorMessage), "No supported trackpads were found.");
        if (devices) CFRelease(devices);
        devices = NULL;
        return false;
    }
    pthread_mutex_lock(&callbackLock);
    currentGeneration = generation;
    observer = callback;
    pthread_mutex_unlock(&callbackLock);
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        void *device = (void *)CFArrayGetValueAtIndex(devices, i);
        registerCallback(device, receiveFrame);
        if (startDevice(device, 0) != 0) {
            unregisterCallback(device, receiveFrame);
            CFArrayRemoveValueAtIndex(selected, i--);
        }
    }
    if (CFArrayGetCount(devices) == 0) {
        snprintf(errorMessage, sizeof(errorMessage), "Supported trackpads could not be started.");
        MosTrackpadStop();
        return false;
    }
    return true;
}

void MosTrackpadStop(void) {
    pthread_mutex_lock(&callbackLock);
    observer = NULL;
    pthread_mutex_unlock(&callbackLock);
    if (!devices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        void *device = (void *)CFArrayGetValueAtIndex(devices, i);
        unregisterCallback(device, receiveFrame);
        stopDevice(device);
    }
    // The Create-owned list retains its devices; releasing it balances ownership.
    CFRelease(devices);
    devices = NULL;
}

int32_t MosTrackpadDeviceCount(void) {
    return devices ? (int32_t)CFArrayGetCount(devices) : 0;
}

const char *MosTrackpadError(void) { return errorMessage; }
