//
//  ZenithExtensionHookStubs.m
//  Zenith
//
//  Phase 1 container — LINK STUBS, no behaviour.
//
//  LCBootstrap.m calls two functions that are declared in
//  Tweaks/Tweaks.h but defined NOWHERE in the vendored tree
//  (verified by grep over the whole tree) and nowhere in
//  upstream LiveContainer's Tweaks/ at the vendored commit
//  b0f53e89 (verified: that directory's file list is identical
//  to the vendored one — no additional file defines them).
//  Without definitions the LiveContainerShared framework fails
//  to link (undefined symbols _GuestExtensionHooksInit and
//  _NSExtensionGuestHooksInit).
//
//  Both call sites are unreachable in Phase 1, so these no-ops
//  change nothing at runtime:
//  * GuestExtensionHooksInit — called only from
//    LCRunGuestExtension (LCBootstrap.m:294), the LiveProcess
//    extension entry. Phase 1 ships no LiveProcess.appex, so
//    that function never runs.
//  * NSExtensionGuestHooksInit — called only from invokeAppMain
//    when the guest sets helperProcessesSupport
//    (LCBootstrap.m:596). Zenith guests never set it
//    (ZenithGuestInfo.create writes no such key), so that
//    branch never runs.
//  If the real upstream definitions are ever vendored, DELETE
//  this file — keeping both would be a duplicate-symbol link
//  error.
//

// Tweaks.h imports nothing itself — it needs Foundation (NSString /
// NSURL / NSUUID / NSBundle), <stdbool.h> (bool), <stdint.h>
// (uint32_t / uint64_t) and <mach-o/loader.h> (struct mach_header_64)
// in scope BEFORE it. Every other Tweaks .m file imports these
// first; this file did not, which failed build #48 with 18
// "unknown type name" errors. Keep these imports above Tweaks.h.
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <mach-o/loader.h>

#import "Tweaks/Tweaks.h"

void GuestExtensionHooksInit(void) {
	// No-op: LiveProcess extension entry is not shipped in Phase 1.
}

void NSExtensionGuestHooksInit(NSURL *appURL, NSURL *containerURL) {
	// No-op: helper-process extension hooks are not used in Phase 1.
	(void)appURL;
	(void)containerURL;
}
