// Modified for Zenith from LiveContainer upstream (khanhduytran0/LiveContainer, commit b0f53e89), 2026-11-27.
// Licensed under the GNU Affero General Public License v3.0 (see LICENSE-AGPL).

// main.c — Zenith entry point.
//
// Adapted from LiveContainer's main.c (khanhduytran0/LiveContainer, main
// commit b0f53e89), verbatim except for the Zenith additions marked below.
//
// ENTRY WIRING (route: C main.c, same as upstream LiveContainer):
// The executable's linker entry point is LiveContainerMainC, set with
// `-e _LiveContainerMainC` in OTHER_LDFLAGS (pbxproj worker). The SwiftUI
// @main entry point generated for ZenithApp (ZenithApp.swift, untouched)
// still exists as the ordinary `main` symbol; it is simply not the process
// entry point. LiveContainerMainC decides, per launch, whether to jump to
// a guest (via the LiveContainerShared framework) or to run the normal
// Zenith launcher by calling main() itself.
//
// This is fully generic: the guest is whatever bundle the launcher stored
// under the `selected` key — the first test guest is only a test. There
// are no bundle-ID checks, no guest names and no single-guest assumptions
// anywhere in this file.
//
// GATES (a guest launch IS a Zenith launch, so the gates guard it too):
// Before jumping to a guest, two tiny SYNCHRONOUS checks run — no async
// work in the entry path:
//  1. Cached forced-update decision (ZenithCachedUpdateBlocks): replicates
//     ForcedUpdateManager._applyCachedDecision exactly — blocked when the
//     cached kill flag is set, or when a cached minimum build exists and
//     the installed ZenithBuildNumber is smaller. Keys, same as
//     ForcedUpdateManager.swift: "Zenith.cachedMinVersion" (number, or a
//     numeric string from the old string-based cache) and
//     "Zenith.cachedKilled" (bool). A cached block wins even though the
//     launcher passed the gates seconds earlier: the relaunch is a fresh
//     process and the cache may have changed since.
//  2. No-internet gate (ZenithIsOffline): synchronous SCNetworkReachability
//     zero-address query — reachable iff some interface (Wi-Fi or mobile
//     data) is up, matching NetworkMonitor's definition (path.status !=
//     .satisfied). No DNS, no network traffic. A failed query fails closed
//     (treated as offline).
// On either failure the pending guest request (`selected` /
// `selectedContainer` / `launchAppUrlScheme`) is CONSUMED (removed, same as
// LCBootstrap consumes them) and control falls through to main(), so the
// launcher starts clean and its own gates show the block screen
// (ForcedUpdateView / OfflineBlockView). A stale cached block therefore
// falls through to the normal Zenith launch instead of launching the guest.
//
// RELAUNCH: the launcher triggers a guest launch exactly as upstream —
// LCSharedUtils.launchToGuestAppWithURL: writes `selected` = guest bundle
// ID and `selectedContainer` = container folder name (optionally
// `launchAppUrlScheme`) to standard UserDefaults, then relaunches this same
// bundle via LSApplicationWorkspace openApplicationWithBundleIdentifier:.
// This file reads those same keys with the same semantics LCBootstrap
// expects, and never removes them on the guest path (LCBootstrap consumes
// them itself before invokeAppMain). The special value `selected` == "ui"
// means "show the launcher" (LCBootstrap convention) and is consumed here.
//
// DEVIATIONS from upstream main.c (all Zenith-only, all marked above):
//  * The gate check + fall-through to main() (upstream's no-guest path
//    dlopen'd the LiveContainerSwiftUI framework and called its `main`;
//    Zenith's launcher IS the app itself, so the no-guest path calls the
//    app's own main() instead).
//  * If the framework dlopen/dlsym fails, fall through to main() instead
//    of tail-calling NULL (upstream would crash). A guest launch then
//    degrades to the launcher rather than killing the app at startup.
//  * Pure C (CoreFoundation + SystemConfiguration only) — no Foundation
//    import, so the file stays main.c.
//
// What the pbxproj worker must add for this file (see the Worker C report):
//  * LiveContainer/main.c to the Zenith app target's Sources.
//  * OTHER_LDFLAGS: "-e", "_LiveContainerMainC" (Debug + Release).
//  * SystemConfiguration.framework to the app target (SCNetworkReachability).
//  * LiveContainerShared.framework embedded (Embed Frameworks) — the dlopen
//    path below only resolves if the framework is in the bundle.

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

void* lcShared = 0;

// Declared, not defined here: the SwiftUI @main entry point generated for
// ZenithApp. The linker entry point of the executable is LiveContainerMainC
// (-e _LiveContainerMainC), so this symbol is an ordinary function we can
// call to run the normal Zenith launcher.
extern int main(int argc, char *argv[]);

// ---------------------------------------------------------------------------
// Zenith gates (synchronous; see the header comment)
// ---------------------------------------------------------------------------

static int ZenithIntFromPlistValue(CFPropertyListRef value) {
    // -1 = absent/unreadable (no constraint). Handles the number form the
    // current cache writes and the numeric-string form the old string-based
    // cache wrote — same defensive read as ForcedUpdateManager.cachedMinVersion.
    if (!value) {
        return -1;
    }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        return number;
    }
    if (type == CFStringGetTypeID()) {
        return (int)CFStringGetIntValue((CFStringRef)value);
    }
    return -1;
}

static bool ZenithBoolFromPlistValue(CFPropertyListRef value) {
    if (!value) {
        return false;
    }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)value);
    }
    if (type == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        return number != 0;
    }
    return false;
}

static bool ZenithCachedUpdateBlocks(void) {
    // Mirrors ForcedUpdateManager._applyCachedDecision exactly.
    CFPropertyListRef killedValue = CFPreferencesCopyAppValue(CFSTR("Zenith.cachedKilled"), kCFPreferencesCurrentApplication);
    bool killed = ZenithBoolFromPlistValue(killedValue);
    if (killedValue) {
        CFRelease(killedValue);
    }
    if (killed) {
        return true;
    }
    CFPropertyListRef minVersionValue = CFPreferencesCopyAppValue(CFSTR("Zenith.cachedMinVersion"), kCFPreferencesCurrentApplication);
    int cachedMinVersion = ZenithIntFromPlistValue(minVersionValue);
    if (minVersionValue) {
        CFRelease(minVersionValue);
    }
    if (cachedMinVersion < 0) {
        return false; // No cached minimum: no cached block.
    }
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    CFPropertyListRef buildValue = NULL;
    if (mainBundle) {
        buildValue = CFBundleGetValueForInfoDictionaryKey(mainBundle, CFSTR("ZenithBuildNumber"));
    }
    int installedBuild = ZenithIntFromPlistValue(buildValue);
    if (installedBuild < 0) {
        installedBuild = 0; // No key reads as 0 — older than any minVersion >= 1.
    }
    return installedBuild < cachedMinVersion;
}

static bool ZenithIsOffline(void) {
    // Synchronous zero-address reachability: no DNS, no traffic. Reachable
    // iff an interface is up; a failed query fails closed (offline).
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&address);
    if (!reachability) {
        return true;
    }
    SCNetworkReachabilityFlags flags = 0;
    bool ok = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    if (!ok) {
        return true;
    }
    bool reachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    bool needsConnection = (flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0;
    return !(reachable && !needsConnection);
}

static void ZenithConsumePendingGuestLaunch(void) {
    CFPreferencesSetAppValue(CFSTR("selected"), NULL, kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("selectedContainer"), NULL, kCFPreferencesCurrentApplication);
    CFPreferencesSetAppValue(CFSTR("launchAppUrlScheme"), NULL, kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

int LiveContainerMainC(int argc, char *argv[], char *envp[]) {
    const char *home = getenv("HOME");

    int (*lcMain)(int argc, char *argv[], char *envp[]) = 0;

    if (!home) {
        abort();
    }

    // Zenith gate check (see the header comment): a selected guest launches
    // only when both gates pass. Anything else falls through to main().
    bool launchGuest = false;
    CFPropertyListRef selectedValue = CFPreferencesCopyAppValue(CFSTR("selected"), kCFPreferencesCurrentApplication);
    if (selectedValue && CFGetTypeID(selectedValue) == CFStringGetTypeID()) {
        CFStringRef selected = (CFStringRef)selectedValue;
        if (CFStringCompare(selected, CFSTR("ui"), 0) == kCFCompareEqualTo) {
            // "ui" means "show the launcher": consume and run normally.
            ZenithConsumePendingGuestLaunch();
        } else if (!ZenithCachedUpdateBlocks() && !ZenithIsOffline()) {
            launchGuest = true;
        } else {
            // Cached block or offline: consume the request so the launcher
            // starts clean and its own gates show the block screen.
            ZenithConsumePendingGuestLaunch();
        }
    } else if (selectedValue) {
        // Corrupted `selected` (not a string): LCBootstrap's stringForKey
        // would read nil for it, so treat it as no guest and clear it.
        ZenithConsumePendingGuestLaunch();
    }
    if (selectedValue) {
        CFRelease(selectedValue);
    }

    if (!launchGuest) {
        return main(argc, argv);
    }

    // --- Below is upstream LiveContainer main.c, verbatim. ---
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library/preloadLibraries.txt", home);
    FILE *file = fopen(path, "r");
    if (!file) {
        goto loadlc;
    }
    char line[PATH_MAX];
    while (fgets(line, sizeof(line), file)) {
        // Remove trailing newline if present
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
        }
        dlopen(line, RTLD_LAZY|RTLD_GLOBAL);
    }

    fclose(file);
    remove(path);

loadlc:
    lcShared = dlopen("@executable_path/Frameworks/LiveContainerShared.framework/LiveContainerShared", RTLD_LAZY|RTLD_GLOBAL);
    if (!lcShared) {
        // Zenith deviation: a missing framework degrades to the launcher
        // instead of tail-calling NULL and crashing at startup.
        return main(argc, argv);
    }
    lcMain = dlsym(lcShared, "LiveContainerMain");
    if (!lcMain) {
        return main(argc, argv);
    }
    __attribute__((musttail)) return lcMain(argc, argv, envp);
}
