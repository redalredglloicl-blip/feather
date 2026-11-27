// Modified for Zenith from LiveContainer upstream (khanhduytran0/LiveContainer, commit b0f53e89), 2026-11-27.
// Licensed under the GNU Affero General Public License v3.0 (see LICENSE-AGPL).

#import <Foundation/Foundation.h>
#import "LCMachOUtils.h"
#import "utils.h"
@import UIKit;

typedef NS_ENUM(NSInteger, Store){
    SideStore = 0,
    AltStore = 1,
    ADP = 2,
    Unknown = -1
};

void refreshFile(NSString* execPath);
int dyld_get_program_sdk_version(void);
uint32_t dyld_get_sdk_version(const struct mach_header* mh);

@interface PKZipArchiver : NSObject

- (NSData *)zippedDataForURL:(NSURL *)url;

@end

@interface UIDevice(private)
@property(readonly) NSString* buildVersion;
@end

@interface LCUtils : NSObject

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error;
+ (NSData *)certificateData;
// Zenith: declared here so Swift (the certificate adapter) can fill the LC password stores — standard defaults AND the LC
// suite — that LCSharedUtils.certificatePassword reads. That password is
// the JITLess switch: without it, the bootstrap demands JIT and no guest
// launches on a non-debugger phone. Implemented in LCUtils.m (upstream).
+ (void)setCertificatePassword:(NSString *)certPassword;
+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler API_AVAILABLE(ios(16.0));


+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password;
+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler;

+ (BOOL)isTXMScriptRequired;
+ (NSString *)base64EncodedUniversalJITScript;

+ (BOOL)isAppGroupAltStoreLike;
+ (Store)store;
+ (NSString *)appUrlScheme;
+ (NSString *)storeInstallURLScheme;
+ (NSString *)getVersionInfo;
+ (NSString *)liveProcessBundleIdentifier;
+ (NSData*)bookmarkForURL:(NSURL*) url;
@end

@interface NSUserDefaults(LiveContainer)
+ (bool)sideStoreExist;
@end

@interface LCP12CertHelper : NSObject

- (instancetype)initWithP12Data:(NSData*)p12Data password:(NSString*)password error:(NSError**)error;
- (NSDate*)getNotValidityNotAfterWithError:(NSError**)error;
- (NSString*)getOrgnizationUnitWithError:(NSError**)error;

@end

typedef NS_ENUM(NSInteger, GeneratedIconStyle){
    Original = -1,
    Light = 0,
    Dark = 1
};

@interface UIImage(LiveContainer)
+ (instancetype)generateIconForBundleURL:(NSURL*)url style:(GeneratedIconStyle)style hasBorder:(BOOL)hasBorder;
@end
BOOL saveCGImage(CGImageRef image, NSURL *url);
CGImageRef loadCGImageFromURL(NSURL *url);
NSNumber *LCGetDefaultClassicMode(NSURL *appURL);
