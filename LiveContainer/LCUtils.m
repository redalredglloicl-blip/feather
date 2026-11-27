// Modified for Zenith from LiveContainer upstream (khanhduytran0/LiveContainer, commit b0f53e89), 2026-11-27.
// Licensed under the GNU Affero General Public License v3.0 (see LICENSE-AGPL).

@import Darwin;
@import MachO;
@import UIKit;
@import UniformTypeIdentifiers;
@import Security;
#import <IOKit/IOKitLib.h>

#import <objc/runtime.h>
#import <objc/message.h>

#import "LCUtils.h"
#import "LCSharedUtils.h"
#import "LCAppInfo.h"
#import "FoundationPrivate.h" // Declares NSExtension +extensionWithIdentifier:error: (used below in liveProcessBundleIdentifier). The public Foundation umbrella does not expose NSExtension here; LCBootstrap.m already relies on this header for the same reason.

// Zenith: NO Zenith-Swift.h import here, ever. The signing shims
// (ZenithGuestSigner / ZenithSingleFileSigner) are @objc Swift classes in
// the Zenith app target, and this file lives in the LiveContainerShared
// framework target, which compiles BEFORE the app target — so the app's
// generated Swift header does not exist yet at framework compile time
// and importing it is a build blocker. The shims are resolved at runtime
// instead (NSClassFromString, helpers below): at launch the framework
// runs inside the app process, where the classes exist. A missing class
// fails closed (nil / NO), exactly like "no certificate". No behaviour
// change when the classes are present: same host cert, same sign calls.
//
// The PREFERRED fix — calling the ZSign C API (zsign/checkCert) directly
// from here — is not available: the framework target links neither Zsign
// nor ZsignC (only the app target links the Zsign product), adding that
// link would need a pbxproj change, and the cert material the C API
// needs (p12 path + password) lives in LCZenithCertificate, an
// app-target Swift enum with no @objc exposure, so framework ObjC
// cannot read it. The runtime-resolved shim keeps the exact same
// underlying signer (base Zsign package, via the shim) with no new
// linkage and no behaviour change.

// Zenith: NO ZSign.dylib, NO ZSigner. Upstream dlopen'd
// @executable_path/Frameworks/ZSign.dylib and resolved the ZSigner class from
// it; Zenith has no such dylib (the snapshot push cannot carry binaries) and
// the ported ZSigner lives only in the Zsign submodule working tree, which
// never reaches the cloud build. Signing goes through the already-linked
// base Zsign package instead, via ZenithGuestSigner (Swift shim over the
// same Zsign.sign API the install flow uses). The two imports removed here
// were for code that is not vendored and is out of Phase 1: MultitaskSupport
// (DecoratedAppSceneViewController) and the LiveContainer SwiftUI module
// (LiveContainerSwiftUI-Swift.h, which supplied MultitaskWindowManager /
// MultitaskDockManager).

// make SFSafariView happy and open data: URLs
@implementation NSURL(hack)
- (BOOL)safari_isHTTPFamilyURL {
    // Screw it, Apple
    return YES;
}
@end

// Runtime-resolved access to the app-target signing shims (see the
// header comment above: no Zenith-Swift.h in this framework target).
// performSelector is used where the return is an object or void;
// the two BOOL-returning calls go through a typed objc_msgSend
// instead, because performSelector cannot return a BOOL.
static Class ZenithGuestSignerClass(void) {
    return NSClassFromString(@"ZenithGuestSigner");
}

static NSData *ZenithGuestCertificateData(void) {
    Class cls = ZenithGuestSignerClass();
    if (!cls) {
        return nil;
    }
    return [cls performSelector:@selector(guestCertificateData)];
}

static BOOL ZenithSignGuestAppAtPath(NSString *appPath, void (^completion)(BOOL)) {
    Class cls = ZenithGuestSignerClass();
    if (!cls) {
        return NO;
    }
    typedef BOOL (*SignFn)(id, SEL, NSString *, void (^)(BOOL));
    return ((SignFn)objc_msgSend)(cls, @selector(signGuestAppAtPath:completion:), appPath, completion);
}

static void ZenithCheckGuestCertificate(void (^handler)(int, NSDate *, NSString *, NSString *)) {
    Class cls = ZenithGuestSignerClass();
    if (!cls) {
        // Same answer the shim gives with no selected certificate.
        handler(-6, nil, nil, @"No certificate is available.");
        return;
    }
    [cls performSelector:@selector(checkGuestCertificateWithCompletionHandler:) withObject:handler];
}

static BOOL ZenithSignFilesWithURLs(NSArray<NSURL *> *urls) {
    Class cls = NSClassFromString(@"ZenithSingleFileSigner");
    if (!cls) {
        return NO;
    }
    typedef BOOL (*SignFilesFn)(id, SEL, NSArray<NSURL *> *);
    return ((SignFilesFn)objc_msgSend)(cls, @selector(signFilesWithURLs:), urls);
}

@implementation LCUtils
#pragma mark Certificate & password

+ (NSData *)certificateData {
    // Zenith: the host certificate comes from the LCZenithCertificate
    // adapter (Zenith's own storage) first, via the shim. The LC
    // shared-defaults mirror (LCCertificateData) is not populated — the
    // adapter deliberately does not mirror into it — so fall back to it
    // only for anything that may have written it directly.
    NSData *adapterData = ZenithGuestCertificateData();
    if (adapterData) {
        return adapterData;
    }
    NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    if(!nud) {
        nud = NSUserDefaults.standardUserDefaults;
    }
    return [nud objectForKey:@"LCCertificateData"];
}


+ (void)setCertificatePassword:(NSString *)certPassword {
    [NSUserDefaults.standardUserDefaults setObject:certPassword forKey:@"LCCertificatePassword"];
    [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]] setObject:certPassword forKey:@"LCCertificatePassword"];
}


#pragma mark Multitasking
+ (NSString *)liveProcessBundleIdentifier {
    // first check if we have LiveProcess extension in our own bundle
    NSBundle *liveProcessBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
    if(liveProcessBundle) {
        return liveProcessBundle.bundleIdentifier;
    }
    
    // in LC2, attempt to guess LC1's LiveProcess extension
    NSString *bundleID = [[@"com.kdt.livecontainer" stringByAppendingPathExtension:LCSharedUtils.teamIdentifier]
                          stringByAppendingPathExtension:@"LiveProcess"];
    if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
        return bundleID;
    }
    
    return nil;
}

+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler {
    if(!self.liveProcessBundleIdentifier) {
        NSError *error = [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"LiveProcess extension not found. Please reinstall LiveContainer and select Keep Extensions"}];
        if (completionHandler) completionHandler(nil, error);
        return;
    }
    
    // Consume the pending launch request, exactly as before: the keys are
    // cleared whether or not multitasking is available.
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults removeObjectForKey:@"selected"];
    [lcUserDefaults removeObjectForKey:@"selectedContainer"];

    // Zenith Phase 1: no multitask window support (no LiveProcess extension,
    // no MultitaskSupport vendored). A LiveProcess bundle should not exist
    // here at all; if one is ever found, fail closed instead of touching
    // the unvendored MultitaskWindowManager / DecoratedAppSceneViewController.
    if (completionHandler) {
        completionHandler(nil, [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"Multitasking is not available in this build."}]);
    }
}

#pragma mark Code signing


// Zenith: the ZSign.dylib dlopen (loadStoreFrameworksWithError2) is deleted
// outright — there is no ZSign.dylib in the bundle and no ZSigner to load.
// Signing now goes through ZenithGuestSigner (base Zsign package, statically
// linked); see signAppBundleWithZSign below. The helpers below replace the
// other half of what LC's ZSigner did: the kernel signature-cache refresh.

// Copy-remove-rename a file so the kernel drops its cached code signature
// for that path. Same idea as LC's refreshFile (ZSign/zsign.mm, which the
// base Zsign package does NOT do): the kernel caches signatures by vnode,
// so a path re-signed in place can keep its stale signature or crash on
// exec. Safer than LC's version: a stale *.tmp is removed first, and the
// original is only removed after the copy succeeded, so a failed copy can
// never delete the file. Implements the refreshFile declaration in LCUtils.h.
void refreshFile(NSString* path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        return;
    }
    NSString *tmpPath = [path stringByAppendingString:@".tmp"];
    [fm removeItemAtPath:tmpPath error:nil];
    NSError *error = nil;
    if (![fm copyItemAtPath:path toPath:tmpPath error:&error]) {
        return;
    }
    if (![fm removeItemAtPath:path error:&error]) {
        [fm removeItemAtPath:tmpPath error:nil];
        return;
    }
    if (![fm moveItemAtPath:tmpPath toPath:path error:&error]) {
        // The original is gone but the copy survived: put it back.
        [fm moveItemAtPath:tmpPath toPath:path error:nil];
    }
}

static BOOL ZenithIsMachOAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < 4) {
        return NO;
    }
    uint32_t magic = 0;
    [data getBytes:&magic length:4];
    return magic == 0xfeedface || magic == 0xfeedfacf
        || magic == 0xcafebabe || magic == 0xcafebabf
        || magic == 0xcefaedfe || magic == 0xcffaedfe
        || magic == 0xbebafeca || magic == 0xbfbafeca;
}

static void ZenithRefreshMachOFilesInDirectory(NSString *dirPath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:dirPath];
    NSString *relativePath = nil;
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:relativePath];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) {
            continue;
        }
        if (ZenithIsMachOAtPath(fullPath)) {
            refreshFile(fullPath);
        }
    }
}

// Refresh every Mach-O in a guest bundle (main executable, Frameworks,
// PlugIns, top-level dylibs) so the kernel drops any stale signature for
// those paths. Called immediately before signing and again after a
// successful sign, mirroring LC's before+after refresh in its ZSigner path.
static void ZenithRefreshMachOFilesInBundle(NSString *bundlePath) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *execName = info[@"CFBundleExecutable"];
    if ([execName isKindOfClass:NSString.class]) {
        refreshFile([bundlePath stringByAppendingPathComponent:execName]);
    }
    ZenithRefreshMachOFilesInDirectory([bundlePath stringByAppendingPathComponent:@"Frameworks"]);
    ZenithRefreshMachOFilesInDirectory([bundlePath stringByAppendingPathComponent:@"PlugIns"]);
    NSArray *topLevel = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *name in topLevel) {
        if ([name.pathExtension isEqualToString:@"dylib"]) {
            NSString *fullPath = [bundlePath stringByAppendingPathComponent:name];
            if (ZenithIsMachOAtPath(fullPath)) {
                refreshFile(fullPath);
            }
        }
    }
}

+ (NSURL *)storeBundlePath {
    if ([self store] == SideStore) {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.SideStore.SideStore/App.app"];
    } else {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.rileytestut.AltStore/App.app"];
    }
}

+ (NSString *)storeInstallURLScheme {
    if ([self store] == SideStore) {
        return @"sidestore://install?url=%@";
    } else {
        return @"altstore://install?url=%@";
    }
}

+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Zenith: signs a guest .app with the host certificate through the
    // already-linked base Zsign package (Zsign.sign / SignFolder — the same
    // call the install flow makes in ZsignHandler.sign), via the
    // ZenithGuestSigner shim (resolved at runtime — see top of file).
    // No dlopen, no ZSigner, no dylib injection.
    //
    // Cert material comes from the LCZenithCertificate adapter (Zenith's own
    // storage — the selected certificate's on-disk p12 + provision paths
    // and password), read inside ZenithGuestSigner. No temp-file copy of the
    // p12 is needed: the file-path signing API reads the p12 file in place.
    // The only adapter read in this file is the pre-check below
    // (ZenithGuestCertificateData()) for the "no certificate"
    // error; the password itself is never read here.
    //
    // Call parameters (deliberate):
    // - customIdentifier is left EMPTY: a non-empty value makes Zsign
    //   REWRITE the bundle's CFBundleIdentifier (bundle.cpp
    //   ModifyBundleInfo). Passing the host ID would rename the guest to
    //   com.zenith.app and break LiveContainer's guest identity (selected /
    //   LCAppInfo.plist / container lookup all key on the guest's own
    //   bundle ID). Empty keeps the guest's own ID from its Info.plist as
    //   the signature identifier; the host cert's team still comes from
    //   the p12. (LC's ZSigner never rewrote the plist either — its bundleId
    //   only set the signature identifier / entitlements.)
    // - The host provision (when the selected cert has one) is passed so
    //   Zsign can derive the signing identity/entitlements from it, but
    //   removeProvision stays YES: the guest's stale embedded
    //   .mobileprovision is stripped and none is embedded, matching LC's
    //   ZSigner flow (which embedded no provision). Guests run dlopen'd
    //   inside Zenith and are never launched by SpringBoard, so no
    //   provision file is needed in the bundle. When the selected cert has
    //   no provision file, "" is passed instead. If the phone test shows
    //   the provision metadata itself is the problem, the fallback is
    //   provisionPath "".
    // - entitlementsPath is empty: Zsign reuses the entitlements already in
    //   the guest binary, as the install flow does when no custom file is set.
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    progress.completedUnitCount = 0;

    if (!ZenithGuestCertificateData()) {
        // No selected host certificate (the adapter's lookup). LCAppInfo
        // already guards certificateData, but never sign blind.
        dispatch_async(dispatch_get_main_queue(), ^{
            progress.completedUnitCount = 1;
            completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: @"No certificate is available for signing."}]);
        });
        return progress;
    }

    NSString *appPath = path.path;
    NSLog(@"[LC] starting signing...");
    // The synchronous Zsign.sign blocks for seconds (whole-bundle signing),
    // so it runs off the calling thread; the progress object is returned
    // immediately, exactly as LCAppInfo expects (it forwards it to its
    // progressHandler when non-nil).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Refresh the kernel signature cache for every Mach-O in the guest
        // before signing (and again after a successful sign) — see
        // ZenithRefreshMachOFilesInBundle. The base Zsign package does not
        // do this; without it a re-signed guest can keep its stale
        // signature (or crash on launch).
        ZenithRefreshMachOFilesInBundle(appPath);

        __block BOOL finished = NO;
        void (^finish)(BOOL) = ^(BOOL success) {
            if (finished) {
                return;
            }
            finished = YES;
            if (success) {
                ZenithRefreshMachOFilesInBundle(appPath);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                progress.completedUnitCount = 1;
                if (success) {
                    completionHandler(YES, nil);
                } else {
                    completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: @"Signing the guest app failed."}]);
                }
            });
        };

        // Zsign.sign is synchronous: its completion fires on this thread
        // when signing finishes — except on early failure (bad path or
        // unusable p12/password), where it returns NO without ever
        // invoking the completion. The return value is therefore the
        // fast-fail signal; finish() is guarded so the caller's completion
        // runs exactly once either way.
    BOOL started = ZenithSignGuestAppAtPath(appPath, ^(BOOL success) {
            finish(success);
        });
        if (!started) {
            finish(NO);
        }
    });

    return progress;
}

+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Zenith Phase 1: single-file signing via a temp-bundle wrapper.
    // The base Zsign package only signs whole bundles, so each file is
    // wrapped in a throwaway .app (minimal Info.plist, the file as its
    // executable), signed with the host cert through ZenithGuestSigner,
    // and copied back signed — implemented in ZenithSingleFileSigner
    // (Swift); this method only delegates. The only caller is
    // validateJITLessSetupWithCompletionHandler (test-sign of
    // TestJITLess.dylib). NOTE: that dylib is not in the app bundle yet
    // (no TestJITLess target vendored), so validation still fails at its
    // copy step until the file is added — the route itself is real, the
    // test asset is the remaining gap.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = ZenithSignFilesWithURLs(urls);
        NSError *error = ok ? nil : [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: @"Single-file signing failed."}];
        completionHandler(ok, error);
    });
    return nil;
}

+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password {
    // No base-Zsign equivalent: LC read the team ID through ZSigner's
    // getTeamIdWithCert. No caller in this build.
    return nil;
}

+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler {
    // Zenith: thin pass-through to the shim, which reads the cert from the
    // LCZenithCertificate adapter and checks it via the base Zsign
    // checkRevokage (OCSP status + expiry). It maps onto LC's (status,
    // expirationDate, organizationalUnitName, error); the base API has no
    // organisational-unit output, so that field is always nil. Unlike
    // Zsign.sign, checkRevokage answers asynchronously (OCSP network
    // round-trip). (Also fixes LC's bug here: it read an uninitialised
    // NSError and returned -6 before even loading the signer.)
    if (!ZenithGuestCertificateData()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(-6, nil, nil, @"No certificate is available.");
        });
        return -6;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ZenithCheckGuestCertificate(^(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(status, expirationDate, organizationalUnitName, error);
            });
        });
    });
    return 0;
}

#pragma mark JIT

+ (BOOL)isTXMScriptRequired {
    if (@available(iOS 19.0, *)) {
        // https://github.com/opa334/Dopamine/commit/e8438b4a64ead3997d2c70a575431cb1b4070fb9
        io_registry_entry_t memory_map = IORegistryEntryFromPath(0, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)
            return NO;
        NSArray *keys = (__bridge NSArray *)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), 0, 0);
        IOObjectRelease(memory_map);
        return keys && [keys containsObject:@"TXM"];
    }
    return NO;
}

+ (NSString *)base64EncodedUniversalJITScript {
    static dispatch_once_t onceToken;
    static NSString *script;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"universal" ofType:@"js"]];
        script = [data base64EncodedStringWithOptions:0];
    });
    return script;
}

#pragma mark Setup

+ (Store) store {
    static Store ans;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // use uttype to accurately detect store
        if([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.sidestore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = SideStore;
        } else if ([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.altstore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = AltStore;
        } else {
            ans = Unknown;
        }
        
        if(ans != Unknown) {
            return;
        }
        
        if([[LCSharedUtils appGroupID] containsString:@"AltStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.rileytestut.AltStore"]) {
            ans = AltStore;
        } else if ([[LCSharedUtils appGroupID] containsString:@"SideStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.SideStore.SideStore"]) {
            ans = SideStore;
        } else if (![[LCSharedUtils appGroupID] containsString:@"Unknown"] ) {
            ans = ADP;
        } else {
            ans = Unknown;
        }
    });
    return ans;
}

+ (NSString *)appUrlScheme {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
}

+ (BOOL)isAppGroupAltStoreLike {
    return [LCSharedUtils.appGroupID containsString:@"SideStore"] || [LCSharedUtils.appGroupID containsString:@"AltStore"];
}

+ (void)changeMainExecutableTo:(NSString *)exec error:(NSError **)error {
    NSURL *infoPath = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.kdt.livecontainer/App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return;

    infoDict[@"CFBundleExecutable"] = exec;
    [infoDict writeToURL:infoPath error:error];
}

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Verify that the certificate is usable
    // Create a test app bundle
    NSString *path = NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpLibPath = [path stringByAppendingPathComponent:@"TestJITLess.dylib"];
    [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toPath:tmpLibPath error:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block bool signSuccess = false;
    __block NSError* signError = nil;
    
    // Sign the test app bundle

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:tmpLibPath]]
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
        signSuccess = success;
        signError = error;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!signSuccess) {
            completionHandler(NO, signError);
        } else if (checkCodeSignature([tmpLibPath UTF8String])) {
            completionHandler(YES, signError);
        } else {
            completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: @"lc.signer.latestCertificateInvalidErr"}]);
        }
        [NSFileManager.defaultManager removeItemAtPath:tmpLibPath error:nil];
    });
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error {
    // Zenith Phase 1: stubbed. LC's "share a copy of the app" flow needs
    // ZSigner adhoc signing plus PKZipArchiver (not vendored), and hardcodes
    // the SideStore/AltStore store-bundle layout. Not part of Phase 1;
    // fail closed instead of half-running it.
    if (error) {
        *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: @"Archiving a copy of the app is not available in this build."}];
    }
    return nil;
}

+ (NSString *)getVersionInfo {
    return [NSString stringWithFormat:@"Version %@-%@",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"]];
}

+ (NSData*)bookmarkForURL:(NSURL*) url {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}


@end
