//
//  ZenithValueEditor.m
//  Zenith
//
//  Zenith v2.12, item 24 (#120): Value Editor — in-game value
//  search & edit, the flagship modding feature.
//
//  THE CORE FACT (design around it): on iOS a separate app CANNOT
//  read or write another app's memory — the sandbox forbids it. So
//  this is an INJECTED DYLIB that runs INSIDE the game process, where
//  it can read and write the game's own memory. It is staged into
//  the game with the existing TweakHandler + Zsign.injectDyLib path
//  (LC_LOAD_DYLIB, Frameworks), exactly like the FPS counter and
//  the translation overlay.
//
//  WHAT IT REALLY DOES (all inside the game process):
//  * Exact search: scan every readable memory region (mach_vm_region
//    + vm_read) for an int32 / int64 / float / double value.
//  * Refine: re-read the found addresses and keep only the ones that
//    still match the new value (exact), or that changed / did not
//    change / increased / decreased (fuzzy, after an exact search).
//  * Edit: write a new value to a found address with vm_write
//    (v2.26: on failure, vm_protect the page writable, retry,
//    then restore the original protection).
//  * Encrypted search (v2.27): a DIFFERENTIAL search for values
//    the game stores transformed, not plainly. "خذ لقطة" walks the
//    same writable regions as the exact search and writes their raw
//    bytes to a snapshot file (NSTemporaryDirectory /
//    ZenithVESnapshot.bin, plain C stdio, capped at 512MB — past
//    the cap the snapshot stops and says so honestly), recording
//    each region's start / size / file offset in a table. "دوّر"
//    re-reads the regions fresh and compares each aligned word
//    with its snapshot word: XOR — (sA ^ sB) == (A ^ B), the key
//    is (sA ^ A); multiply — sA*B == sB*A in __int128 signed
//    math, the constant is sA / A when it divides evenly. A
//    multiply hit that does not divide evenly is stored but
//    NOT editable (its K cannot be derived). The edit panel and
//    the result rows always show the DISPLAYED value and convert
//    it back to stored bits before writing; freeze and the saved
//    list keep writing the stored bits, unchanged.
//  * Freeze: a background thread re-writes frozen addresses every
//    0.25s, so the value stays put (the freeze).
//  * Saved list: found/edited values saved per game, in the game's
//    own NSUserDefaults, so they survive a relaunch of the game.
//  * Floating in-game menu: two states that toggle — a small
//    draggable floating button showing the Zenith ringed-planet
//    logo, and the full menu panel with its own close button.
//    v2.15: the menu opens inside the game's own key window, not
//    as a second UIWindow — the second window crashed the game
//    on tap, before the menu drew a single frame. The button's
//    own window refuses key-window status, so tapping it can
//    never steal the key window from the game.
//    Closing the menu collapses it back to the floating button,
//    which stays on screen; tapping it reopens the menu. The
//    button snaps to the nearest screen edge when the drag ends,
//    so it never blocks gameplay. The planet is drawn in code
//    with CoreGraphics (peach disc #FFC06B + tilted ring on a
//    dark circle — the approved Zenith icon look): the dylib runs
//    inside the game and cannot load Zenith's asset catalog, so
//    the art is self-contained and no image bytes are embedded.
//
//  HONEST LIMITS (stated here and in the Zenith UI — never faked):
//  * Offline games ONLY. Values the game checks against a server
//    cannot be changed from the phone, and no memory scan will
//    change that.
//  * The first scan is an EXACT search. A "search for an unknown
//    value" first scan is not offered: snapshotting every readable
//    byte of a game's memory would need gigabytes of storage. Fuzzy
//    works as a refine step (changed / unchanged / bigger /
//    smaller) on a result set that started from an exact search.
//  * If the game's anti-tamper blocks the injection (the menu never
//    appears, or the game crashes on launch), the menu simply is not
//    there. Zenith says so plainly and points at the backup/restore
//    path — there is no fake working menu.
//  * Float exact search matches the exact bit pattern, so 0.0 and
//    -0.0 are different values. Refine usually clears that up.
//  * A protected page is retried, not faked: if vm_write fails,
//    writeBits flips the page writable with vm_protect, retries,
//    and restores the protection. If the address is dead (the
//    game freed it or moved the value) or the kernel refuses
//    to make the mapping writable, the edit honestly says it
//    failed — re-search to find the live address.
//  * Encrypted search finds only two transforms, both with a
//    FIXED key/constant: XOR with a fixed key, and multiply by
//    a fixed constant. NOT found: values encrypted with a key
//    that CHANGES every frame/read, values stored as float/double
//    transforms (encrypted search is integers only), values the
//    game keeps server-side, and values in memory that moved
//    between snapshot and compare (that region is skipped).
//    The snapshot is only valid in the same game session —
//    if the game restarts, take a fresh snapshot. A multiply
//    hit whose stored value does not divide evenly by the
//    displayed value cannot be edited (its K is not derivable),
//    only frozen — the panel says so instead of writing a
//    wrong value.
//
//  BUILD (not part of the Xcode app target — a dylib needs its own
//  build step; this file ships as source only until that step
//  exists, and ValueEditorInjector reports the dylib as missing):
//
//    clang -dynamiclib -arch arm64 -miphoneos-version-min=14.0 \
//      -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//      -framework Foundation -framework UIKit \
//      -o ZenithValueEditor.dylib ZenithValueEditor.m
//
//  The resulting ZenithValueEditor.dylib is then bundled in the app
//  (the coordinator adds it as a resource) so ValueEditorInjector
//  can find it as Bundle.main "ZenithValueEditor.dylib" and stage
//  it for injection at signing time.
//
//  STRINGS: the menu labels are baked into this file in Iraqi Arabic.
//  The dylib runs inside the game and cannot read Zenith's string
//  catalog, so there is no Localizable lookup here. Keep it Iraqi.
//
//  NO CydiaSubstrate / ElleKit dependency: there is no hooking here,
//  only mach VM calls + UIKit, so the dylib loads with plain
//  LC_LOAD_DYLIB injection.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <stdio.h>
#import <unistd.h>
// NOTE: <mach/mach_vm.h> is stubbed out in the iOS SDK (its first line is
// `#error mach_vm.h unsupported.`), so declare the one function we need
// ourselves. mach_vm_region lives in libSystem at runtime, so this links.
extern kern_return_t mach_vm_region(vm_map_t target_task,
                                    mach_vm_address_t *address,
                                    mach_vm_size_t *size,
                                    vm_region_flavor_t flavor,
                                    vm_region_info_t info,
                                    mach_msg_type_number_t *infoCnt,
                                    mach_port_t *object_name);
// vm_page_size is the host page size (16K on arm64 iOS); needed
// to round addresses down for vm_protect in writeBits:.
extern vm_size_t vm_page_size;

@class ZenithValueEditorOverlay;

// First scan keeps at most this many addresses. Past it the scan
// stops and the menu says so — refine from a smaller set instead
// of pretending the list is complete.
static const NSUInteger kZenithVEMaxResults = 100000;
// A scan reads memory in chunks of this size.
static const vm_size_t kZenithVEChunkSize = 1024 * 1024;
// The freeze thread re-writes frozen addresses this often.
static const NSTimeInterval kZenithVEFreezeInterval = 0.25;
// NSUserDefaults key (inside the GAME's defaults, so the saved
// list is per game automatically) for the saved values.
static NSString * const kZenithVESavedDefaultsKey = @"ZenithValueEditorSaved";
// Encrypted search (v2.27): the snapshot file name inside
// NSTemporaryDirectory(), and the cap on snapshot bytes. Past
// the cap the snapshot stops adding regions and reports the
// truncation honestly instead of pretending it is complete.
static NSString * const kZenithVESnapshotFileName = @"ZenithVESnapshot.bin";
static const uint64_t kZenithVESnapshotMaxBytes = 512ULL * 1024ULL * 1024ULL;

typedef NS_ENUM(NSInteger, VEValueType) {
	VEValueTypeInt32 = 0,
	VEValueTypeInt64 = 1,
	VEValueTypeFloat = 2,
	VEValueTypeDouble = 3,
};

typedef NS_ENUM(NSInteger, VERefineMode) {
	VERefineChanged = 0,
	VERefineUnchanged = 1,
	VERefineIncreased = 2,
	VERefineDecreased = 3,
};

// How a found value is stored in the game (v2.27). Plain is the
// old behaviour (bits ARE the displayed value). XOR means the
// game stores (displayed ^ key), Multiply means it stores
// (displayed * K). transformParam holds the key, or K. A
// Multiply hit whose K could not be derived stores param 0
// and is NOT editable — see VEStoredBitsForDisplayed.
typedef NS_ENUM(NSInteger, VEValueTransform) {
	VEValueTransformPlain = 0,
	VEValueTransformXOR = 1,
	VEValueTransformMultiply = 2,
};

// MARK: - VEResult

/// One found address. `bits` holds the raw value bits (4 bytes for
/// int32/float, 8 bytes for int64/double, stored in the low bytes),
/// so one field covers every type.
@interface VEResult : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) uint64_t bits;
@property (nonatomic, assign) VEValueType type;
@property (nonatomic, assign) BOOL frozen;
@property (nonatomic, copy) NSString *label;
// v2.27: how the value is stored (Plain by default — every
// pre-2.27 result is Plain/0, so old saved lists load unchanged).
@property (nonatomic, assign) VEValueTransform transform;
@property (nonatomic, assign) uint64_t transformParam;
@end

@implementation VEResult
@end

// MARK: - Value helpers (plain C, no object state)

static size_t VESizeForType(VEValueType type) {
	switch (type) {
		case VEValueTypeInt32: return 4;
		case VEValueTypeInt64: return 8;
		case VEValueTypeFloat: return 4;
		case VEValueTypeDouble: return 8;
	}
	return 4;
}

static BOOL VEParseBits(NSString *text, VEValueType type, uint64_t *bitsOut) {
	if (text == nil || text.length == 0 || bitsOut == NULL) {
		return NO;
	}
	const char *cText = [text UTF8String];
	char *end = NULL;
	switch (type) {
		case VEValueTypeInt32: {
			long long v = strtoll(cText, &end, 10);
			if (end == cText || v < INT32_MIN || v > INT32_MAX) {
				return NO;
			}
			int32_t i = (int32_t)v;
			*bitsOut = 0;
			memcpy(bitsOut, &i, 4);
			return YES;
		}
		case VEValueTypeInt64: {
			long long v = strtoll(cText, &end, 10);
			if (end == cText) {
				return NO;
			}
			*bitsOut = (uint64_t)v;
			return YES;
		}
		case VEValueTypeFloat: {
			float f = strtof(cText, &end);
			if (end == cText) {
				return NO;
			}
			*bitsOut = 0;
			memcpy(bitsOut, &f, 4);
			return YES;
		}
		case VEValueTypeDouble: {
			double d = strtod(cText, &end);
			if (end == cText) {
				return NO;
			}
			*bitsOut = 0;
			memcpy(&(*bitsOut), &d, 8);
			return YES;
		}
	}
	return NO;
}

static NSString *VEStringForBits(uint64_t bits, VEValueType type) {
	switch (type) {
		case VEValueTypeInt32: {
			int32_t v = 0;
			memcpy(&v, &bits, 4);
			return [NSString stringWithFormat:@"%d", (int)v];
		}
		case VEValueTypeInt64: {
			return [NSString stringWithFormat:@"%lld", (long long)bits];
		}
		case VEValueTypeFloat: {
			float f = 0;
			memcpy(&f, &bits, 4);
			return [NSString stringWithFormat:@"%g", (double)f];
		}
		case VEValueTypeDouble: {
			double d = 0;
			memcpy(&d, &bits, 8);
			return [NSString stringWithFormat:@"%g", d];
		}
	}
	return @"?";
}

/// The short Iraqi name of a value type, for the result rows
/// and the edit panel (v2.28: the subtitle used to be empty for
/// every unfrozen, unlabelled result). Switch, not an array
/// index — a corrupt saved list could hold an out-of-range
/// type and an index would crash the game.
static NSString *VETypeName(VEValueType type) {
	switch (type) {
		case VEValueTypeInt32: return @"صحيح";
		case VEValueTypeInt64: return @"كبير";
		case VEValueTypeFloat: return @"فلوت";
		case VEValueTypeDouble: return @"دبل";
	}
	return @"صحيح";
}

/// Numeric comparison of two values of the same type: -1 / 0 / 1.
/// Used by the fuzzy refine (changed / bigger / smaller).
static int VECompareBits(uint64_t a, uint64_t b, VEValueType type) {
	switch (type) {
		case VEValueTypeInt32: {
			int32_t x = 0, y = 0;
			memcpy(&x, &a, 4);
			memcpy(&y, &b, 4);
			if (x < y) return -1;
			if (x > y) return 1;
			return 0;
		}
		case VEValueTypeInt64: {
			int64_t x = (int64_t)a, y = (int64_t)b;
			if (x < y) return -1;
			if (x > y) return 1;
			return 0;
		}
		case VEValueTypeFloat: {
			float x = 0, y = 0;
			memcpy(&x, &a, 4);
			memcpy(&y, &b, 4);
			if (x < y) return -1;
			if (x > y) return 1;
			return 0;
		}
		case VEValueTypeDouble: {
			double x = 0, y = 0;
			memcpy(&x, &a, 8);
			memcpy(&y, &b, 8);
			if (x < y) return -1;
			if (x > y) return 1;
			return 0;
		}
	}
	return 0;
}

// MARK: - Encrypted-value transform helpers (v2.27, plain C)
//
// The game shows the player a DISPLAYED value but stores a
// TRANSFORMED one. These two convert between the two, so the
// menu always shows the displayed value and only ever writes
// stored bits. Plain is the identity. Float/double have no
// transform (encrypted search is integers only), so they also
// pass through unchanged here.
static uint64_t VEMaskForType(VEValueType type) {
	size_t size = VESizeForType(type);
	return (size == 8) ? UINT64_MAX : ((1ULL << (size * 8)) - 1);
}

// Displayed -> stored. Returns NO when the conversion is
// impossible: Multiply with param 0, i.e. a multiply hit whose
// K could not be derived (sA did not divide evenly by A).
// The caller must NOT write in that case.
static BOOL VEStoredBitsForDisplayed(uint64_t displayed, VEValueTransform transform, uint64_t param, VEValueType type, uint64_t *storedOut) {
	if (storedOut == NULL) {
		return NO;
	}
	uint64_t mask = VEMaskForType(type);
	switch (transform) {
		case VEValueTransformPlain:
			*storedOut = displayed & mask;
			return YES;
		case VEValueTransformXOR:
			*storedOut = (displayed ^ param) & mask;
			return YES;
		case VEValueTransformMultiply: {
			if (param == 0) {
				return NO;
			}
			if (type == VEValueTypeInt32) {
				int32_t d = 0, k = 0;
				uint64_t dp = displayed & mask, kp = param & mask;
				memcpy(&d, &dp, 4);
				memcpy(&k, &kp, 4);
				int32_t r = (int32_t)((__int128)d * (__int128)k);
				*storedOut = 0;
				memcpy(storedOut, &r, 4);
				return YES;
			}
			if (type == VEValueTypeInt64) {
				int64_t d = (int64_t)displayed;
				int64_t k = (int64_t)param;
				int64_t r = (int64_t)((__int128)d * (__int128)k);
				*storedOut = (uint64_t)r;
				return YES;
			}
			*storedOut = displayed & mask;
			return YES;
		}
	}
	*storedOut = displayed & mask;
	return YES;
}

// Stored -> displayed (the inverse, for showing values).
// Multiply: stored / param when it divides evenly; otherwise
// the stored bits as-is (the displayed value is not derivable,
// but showing the stored bits beats showing nothing — and the
// edit path above refuses to write for that case anyway).
static uint64_t VEDisplayedBitsForStored(uint64_t stored, VEValueTransform transform, uint64_t param, VEValueType type) {
	uint64_t mask = VEMaskForType(type);
	switch (transform) {
		case VEValueTransformPlain:
			return stored & mask;
		case VEValueTransformXOR:
			return (stored ^ param) & mask;
		case VEValueTransformMultiply: {
			if (param == 0) {
				return stored & mask;
			}
			if (type == VEValueTypeInt32) {
				int32_t s = 0, k = 0;
				uint64_t sp = stored & mask, kp = param & mask;
				memcpy(&s, &sp, 4);
				memcpy(&k, &kp, 4);
				if (k == 0 || (k == -1 && s == INT32_MIN) || (s % k) != 0) {
					return stored & mask;
				}
				int32_t r = (int32_t)(s / k);
				uint64_t out = 0;
				memcpy(&out, &r, 4);
				return out;
			}
			if (type == VEValueTypeInt64) {
				int64_t s = (int64_t)stored;
				int64_t k = (int64_t)param;
				if (k == 0 || (k == -1 && s == INT64_MIN) || (s % k) != 0) {
					return stored & mask;
				}
				return (uint64_t)(s / k);
			}
			return stored & mask;
		}
	}
	return stored & mask;
}

// Snapshot file path (v2.27): the game's temp directory.
static NSString *VEEncryptedSnapshotPath(void) {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:kZenithVESnapshotFileName];
}

// MARK: - ZenithValueEditor (scan engine + freeze + saved list)

@interface ZenithValueEditor : NSObject

+ (instancetype)shared;
- (void)setup;

// Memory access (own process — the dylib runs inside the game).
- (BOOL)readBitsAt:(uint64_t)address type:(VEValueType)type bitsOut:(uint64_t *)bitsOut;
- (BOOL)writeBits:(uint64_t)bits at:(uint64_t)address type:(VEValueType)type;

// Search / refine. Results live in _results; the menu reads them.
- (void)searchExact:(NSString *)text
			   type:(VEValueType)type
		 completion:(void (^)(NSUInteger count, BOOL capped, NSString *error))completion;
- (void)refineExact:(NSString *)text completion:(void (^)(NSUInteger count, NSString *error))completion;
- (void)refineFuzzy:(VERefineMode)mode completion:(void (^)(NSUInteger count))completion;

// Encrypted search (v2.27, differential — never guesses keys):
// takeEncryptedSnapshot writes the raw bytes of every writable
// region to the snapshot file and records the region table;
// searchEncrypted compares the snapshot words with a fresh
// re-read for the new displayed value. Snapshot completion
// reports (success, truncated, error); compare completion is
// identical to searchExact (count, capped, error).
- (void)takeEncryptedSnapshot:(NSString *)text
						 type:(VEValueType)type
				   completion:(void (^)(BOOL success, BOOL truncated, NSString *error))completion;
- (void)searchEncrypted:(NSString *)text completion:(void (^)(NSUInteger count, BOOL capped, NSString *error))completion;

// Safe count of the results list (v2.17): the results ivar was once
// seen holding a non-array object (crash log: -[OS_xpc_array count]),
// which aborts the game when the table asks for its row count.
// This reads the list defensively and repairs a corrupt ivar.
- (NSUInteger)safeResultsCount;

// Freeze: the background thread re-writes every frozen result.
- (void)setFrozen:(BOOL)frozen forResult:(VEResult *)result;
- (void)freezeLoop;

// Saved list (per game, in the game's own NSUserDefaults).
- (void)loadSaved;
- (void)persistSaved;
- (void)saveResult:(VEResult *)result;
- (void)removeSaved:(VEResult *)result;
- (void)applySaved:(VEResult *)result;

@property (nonatomic, strong) NSMutableArray<VEResult *> *results;
@property (nonatomic, strong) NSMutableArray<VEResult *> *saved;
@property (nonatomic, strong) NSMutableArray<VEResult *> *frozen;
@property (nonatomic, assign) VEValueType currentType;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL freezeRunning;

// Encrypted-search snapshot state (v2.27). snapshotRegions is
// an NSArray of NSDictionary @{@"start":@(addr),
// @"size":@(size), @"offset":@(fileOffset)}; snapshotBitsA is
// the parsed displayed value A the snapshot was taken for.
@property (nonatomic, assign) BOOL snapshotValid;
@property (nonatomic, assign) BOOL snapshotTruncated;
@property (nonatomic, assign) VEValueType snapshotType;
@property (nonatomic, assign) uint64_t snapshotBitsA;
@property (nonatomic, strong) NSArray<NSDictionary *> *snapshotRegions;

@end

@implementation ZenithValueEditor

+ (instancetype)shared {
	static ZenithValueEditor *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [[ZenithValueEditor alloc] init];
	});
	return shared;
}

- (instancetype)init {
	self = [super init];
	if (self != nil) {
		// v2.19: these MUST be owned (+1), not autoreleased.
		// This file is compiled by the Run Script with plain
		// clang (no -fobjc-arc, manual reference counting), so a
		// direct ivar assignment bypasses the `strong` setter
		// and retains NOTHING. `[NSMutableArray array]` is
		// autoreleased: it died when the launch runloop turn
		// ended, and all three ivars dangled from then on —
		// the freed memory was later reused by another object
		// (an OS_xpc_array in crash 1, a game NSArray of
		// NSNumbers in crash 2), so the table crashed the
		// instant it touched the list on the first menu open.
		// `[[NSMutableArray alloc] init]` owns the array.
		_results = [[NSMutableArray alloc] init];
		_saved = [[NSMutableArray alloc] init];
		_frozen = [[NSMutableArray alloc] init];
		_currentType = VEValueTypeInt32;
		[self loadSaved];
	}
	return self;
}

- (void)setup {
	// Nothing to start here: the floating-button window is created
	// by the overlay below, on the main queue, from the
	// constructor. Kept so the constructor reads like the other
	// overlays (shared -> setup).
}

// v2.17: defensive count of the results list. The results ivar
// was once seen holding a non-array object (crash log 2026-11-28:
// -[OS_xpc_array count]: unrecognized selector, SIGABRT, on the
// first menu open) — the table's numberOfRowsInSection: sends
// count to whatever the ivar holds, and a non-array aborts the
// game. If the ivar is ever not an NSArray, replace it with an
// empty array (self-healing: the next search rebuilds it) and
// report 0 instead of crashing.
- (NSUInteger)safeResultsCount {
	NSArray *list = self.results;
	if (![list isKindOfClass:[NSArray class]]) {
		self.results = [NSMutableArray array];
		return 0;
	}
	return list.count;
}

// MARK: Memory access

- (BOOL)readBitsAt:(uint64_t)address type:(VEValueType)type bitsOut:(uint64_t *)bitsOut {
	if (bitsOut == NULL) {
		return NO;
	}
	size_t size = VESizeForType(type);
	vm_offset_t data = 0;
	mach_msg_type_number_t dataCount = 0;
	kern_return_t kr = vm_read(mach_task_self(), (vm_address_t)address, (vm_size_t)size, &data, &dataCount);
	if (kr != KERN_SUCCESS || dataCount < size) {
		if (kr == KERN_SUCCESS) {
			vm_deallocate(mach_task_self(), data, dataCount);
		}
		return NO;
	}
	*bitsOut = 0;
	memcpy(bitsOut, (const void *)data, size);
	vm_deallocate(mach_task_self(), data, dataCount);
	return YES;
}

// v2.26: the write now fights back when the page is protected.
// vm_write alone fails on a read-only page, and some games flip
// their value pages to read-only between frames (or map them
// that way) — that is the "اللعبة حامية هاي الذاكرة" failure the
// user saw on 0x106f05b60 (frozen at 155, live read 0). This
// process OWNS this memory, so: try the plain write first, and
// only if it fails, make the page writable with vm_protect,
// retry, and restore the original protection either way. This
// is the standard value-editor approach. It cannot help a
// genuinely dead address (freed/reallocated — the game moved
// the value, the read already shows 0) or a shared/file
// mapping the kernel refuses to make writable: those still
// report NO, honestly.
- (BOOL)writeBits:(uint64_t)bits at:(uint64_t)address type:(VEValueType)type {
	size_t size = VESizeForType(type);
	kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)&bits, (mach_msg_type_number_t)size);
	if (kr == KERN_SUCCESS) {
		return YES;
	}
	// Find the region so we know the current protection to
	// restore afterwards (mach_vm_region is already declared
	// at the top of this file).
	mach_vm_address_t regionAddress = (mach_vm_address_t)address;
	mach_vm_size_t regionSize = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t objectName = MACH_PORT_NULL;
	if (mach_vm_region(mach_task_self(), &regionAddress, &regionSize,
						VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
						&infoCount, &objectName) != KERN_SUCCESS) {
		// No region there at all — dead/stale address.
		return NO;
	}
	if (objectName != MACH_PORT_NULL) {
		mach_port_deallocate(mach_task_self(), objectName);
	}
	vm_prot_t oldProtection = info.protection;
	if ((oldProtection & VM_PROT_WRITE) != 0) {
		// Already writable and vm_write still failed — the
		// address is dead or unmapped; protection is not the
		// problem, and flipping it would change nothing.
		return NO;
	}
	// vm_protect works on whole pages: round the value down to
	// its page and protect the page(s) it spans.
	vm_address_t page = (vm_address_t)address & ~(vm_address_t)(vm_page_size - 1);
	vm_size_t span = (vm_size_t)((address + size - page + vm_page_size - 1) & ~(vm_size_t)(vm_page_size - 1));
	if (vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
		// The kernel refuses to make this mapping writable
		// (shared/file mapping) — report it, do not fake it.
		return NO;
	}
	kr = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)&bits, (mach_msg_type_number_t)size);
	// Always restore the original protection, success or not,
	// so the game never notices the page was opened.
	vm_protect(mach_task_self(), page, span, FALSE, oldProtection);
	return kr == KERN_SUCCESS;
}

// MARK: Search

- (void)searchExact:(NSString *)text
			   type:(VEValueType)type
		 completion:(void (^)(NSUInteger count, BOOL capped, NSString *error))completion {
	uint64_t targetBits = 0;
	if (!VEParseBits(text, type, &targetBits)) {
		if (completion != NULL) {
			completion(0, NO, @"الرقم مو صحيح — اكتب رقم يناسب النوع.");
		}
		return;
	}
	if (self.scanning) {
		if (completion != NULL) {
			completion(0, NO, @"البحث شغال بعد — انتظر يخلص.");
		}
		return;
	}
	self.scanning = YES;
	self.currentType = type;
	size_t valueSize = VESizeForType(type);

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *found = [[NSMutableArray alloc] init];
		BOOL capped = NO;

		mach_vm_address_t address = 0;
		mach_vm_size_t size = 0;
		vm_region_basic_info_data_64_t info;
		mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t objectName = MACH_PORT_NULL;

		while (mach_vm_region(mach_task_self(), &address, &size,
							  VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
							  &infoCount, &objectName) == KERN_SUCCESS) {
			mach_vm_address_t regionStart = address;
			mach_vm_size_t regionSize = size;
			if (objectName != MACH_PORT_NULL) {
				mach_port_deallocate(mach_task_self(), objectName);
				objectName = MACH_PORT_NULL;
			}
			if (regionSize == 0) {
				break;
			}
			// Next region: mach_vm_region keeps scanning from the
			// address we pass in, so advance past this one now.
			address += size;
			infoCount = VM_REGION_BASIC_INFO_COUNT_64;

			// Only readable+WRITABLE regions can hold a value the
			// player can change. Read-only mappings (__TEXT,
			// __LINKEDIT, the dyld shared cache) can only hold
			// constants — and they are the biggest, most exotic
			// mappings in the task, the ones vm_read is most
			// likely to fault on. Skipping them also makes the
			// scan orders of magnitude faster.
			if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
				continue;
			}

			mach_vm_address_t offset = 0;
			while (offset < regionSize && !capped) {
				vm_size_t chunk = (vm_size_t)MIN((uint64_t)kZenithVEChunkSize, (uint64_t)(regionSize - offset));
				vm_offset_t data = 0;
				mach_msg_type_number_t dataCount = 0;
				kern_return_t kr = vm_read(mach_task_self(), regionStart + offset, chunk, &data, &dataCount);
				if (kr != KERN_SUCCESS) {
					offset += chunk;
					continue;
				}
				const uint8_t *bytes = (const uint8_t *)data;
				// Step one byte at a time: a value can sit at ANY
				// address, not only at a multiple of its size.
				// Stepping by the value size would miss most hits.
				for (vm_size_t i = 0; i + valueSize <= dataCount; i += 1) {
					uint64_t bits = 0;
					memcpy(&bits, bytes + i, valueSize);
					if (bits != targetBits) {
						continue;
					}
					// A match whose low bytes equal the target: for
					// 4-byte types the high bytes of `bits` are
					// zero, so compare only the value bytes.
					uint64_t mask = (valueSize == 8) ? UINT64_MAX : ((1ULL << (valueSize * 8)) - 1);
					if ((bits & mask) != (targetBits & mask)) {
						continue;
					}
					VEResult *result = [[VEResult alloc] init];
					result.address = (uint64_t)(regionStart + offset + i);
					result.bits = targetBits;
					result.type = type;
					[found addObject:result];
					[result release];
					if (found.count >= kZenithVEMaxResults) {
						capped = YES;
						break;
					}
				}
				vm_deallocate(mach_task_self(), data, dataCount);
				offset += chunk;
			}
			if (capped) {
				break;
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			self.results = found;
			self.scanning = NO;
			if (completion != NULL) {
				NSString *error = nil;
				if (found.count == 0) {
					error = @"ما لگيت هاي القيمة — جرّب نوع ثاني أو رقم ثاني.";
				} else if (capped) {
					error = @"النتائج هواي (فوق 100 ألف) — غيّر القيمة باللعبة وبعدين ضيّق البحث.";
				}
				completion(found.count, capped, error);
			}
		});
		[found release];
	});
}

// Re-read every stored address and keep only the ones that now
// hold the new exact value.
- (void)refineExact:(NSString *)text completion:(void (^)(NSUInteger count, NSString *error))completion {
	uint64_t targetBits = 0;
	if (!VEParseBits(text, self.currentType, &targetBits)) {
		if (completion != NULL) {
			completion([self safeResultsCount], @"الرقم مو صحيح — اكتب رقم يناسب النوع.");
		}
		return;
	}
	if (self.scanning) {
		if (completion != NULL) {
			completion([self safeResultsCount], @"البحث شغال بعد — انتظر يخلص.");
		}
		return;
	}
	self.scanning = YES;
	VEValueType type = self.currentType;
	NSArray<VEResult *> *previous = [self.results copy];
	size_t valueSize = VESizeForType(type);
	uint64_t mask = (valueSize == 8) ? UINT64_MAX : ((1ULL << (valueSize * 8)) - 1);

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *kept = [[NSMutableArray alloc] init];
		for (VEResult *result in previous) {
			uint64_t now = 0;
			if (![self readBitsAt:result.address type:type bitsOut:&now]) {
				continue;
			}
			if ((now & mask) != (targetBits & mask)) {
				continue;
			}
			result.bits = now;
			[kept addObject:result];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			self.results = kept;
			self.scanning = NO;
			if (completion != NULL) {
				NSString *error = nil;
				if (kept.count == 0) {
					error = @"ما بقى ولا نتيجة — ابدأ بحث جديد.";
				}
				completion(kept.count, error);
			}
		});
		[kept release];
		[previous release];
	});
}

// Fuzzy refine: compare each stored address's CURRENT value with
// the value it held when it was found (or last refined).
- (void)refineFuzzy:(VERefineMode)mode completion:(void (^)(NSUInteger count))completion {
	if (self.scanning) {
		if (completion != NULL) {
			completion([self safeResultsCount]);
		}
		return;
	}
	self.scanning = YES;
	VEValueType type = self.currentType;
	NSArray<VEResult *> *previous = [self.results copy];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *kept = [[NSMutableArray alloc] init];
		for (VEResult *result in previous) {
			uint64_t now = 0;
			if (![self readBitsAt:result.address type:type bitsOut:&now]) {
				continue;
			}
			int cmp = VECompareBits(now, result.bits, type);
			BOOL keep = NO;
			switch (mode) {
				case VERefineChanged: keep = (cmp != 0); break;
				case VERefineUnchanged: keep = (cmp == 0); break;
				case VERefineIncreased: keep = (cmp > 0); break;
				case VERefineDecreased: keep = (cmp < 0); break;
			}
			if (!keep) {
				continue;
			}
			result.bits = now;
			[kept addObject:result];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			self.results = kept;
			self.scanning = NO;
			if (completion != NULL) {
				completion(kept.count);
			}
		});
		[kept release];
		[previous release];
	});
}

// MARK: Encrypted search (v2.27)
//
// DIFFERENTIAL, never guessing: the game stores the displayed
// value A transformed (XOR key, or * K). The snapshot freezes
// the raw stored bytes at A; the compare re-reads them live at
// B and tests, per aligned word, whether the SAME transform
// explains both stored words. No key is ever guessed — the
// key/constant is DERIVED from the two stored words and the
// two displayed values.

- (void)takeEncryptedSnapshot:(NSString *)text
						 type:(VEValueType)type
				   completion:(void (^)(BOOL success, BOOL truncated, NSString *error))completion {
	// Integers only: XOR / multiply are integer rules.
	if (type == VEValueTypeFloat || type == VEValueTypeDouble) {
		if (completion != NULL) {
			completion(NO, NO, @"البحث المشفّر يشتغل على صحيح وكبير بس — بدّل النوع.");
		}
		return;
	}
	uint64_t bitsA = 0;
	if (!VEParseBits(text, type, &bitsA)) {
		if (completion != NULL) {
			completion(NO, NO, @"الرقم مو صحيح — اكتب رقم يناسب النوع.");
		}
		return;
	}
	if (self.scanning) {
		if (completion != NULL) {
			completion(NO, NO, @"البحث شغال بعد — انتظر يخلص.");
		}
		return;
	}
	self.scanning = YES;
	NSString *path = VEEncryptedSnapshotPath();

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		// A new snapshot replaces the old one: delete it first,
		// so a failed snapshot never leaves a stale file that
		// a later compare would mistake for a fresh one.
		[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
		NSMutableArray<NSDictionary *> *regions = [[NSMutableArray alloc] init];
		BOOL truncated = NO;
		BOOL wroteAnything = NO;
		uint64_t totalWritten = 0;
		NSString *error = nil;

		FILE *file = fopen([path UTF8String], "wb");
		if (file == NULL) {
			dispatch_async(dispatch_get_main_queue(), ^{
				self.scanning = NO;
				if (completion != NULL) {
					completion(NO, NO, @"ما قدرت أحفظ اللقطة — جرّب مرة ثانية.");
				}
			});
			[regions release];
			return;
		}

		mach_vm_address_t address = 0;
		mach_vm_size_t size = 0;
		vm_region_basic_info_data_64_t info;
		mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t objectName = MACH_PORT_NULL;

		while (mach_vm_region(mach_task_self(), &address, &size,
							  VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
							  &infoCount, &objectName) == KERN_SUCCESS) {
			mach_vm_address_t regionStart = address;
			mach_vm_size_t regionSize = size;
			if (objectName != MACH_PORT_NULL) {
				mach_port_deallocate(mach_task_self(), objectName);
				objectName = MACH_PORT_NULL;
			}
			if (regionSize == 0) {
				break;
			}
			address += size;
			infoCount = VM_REGION_BASIC_INFO_COUNT_64;

			// Same writable-only rule as searchExact.
			if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
				continue;
			}
			// Cap: stop adding regions past 512MB. The region
			// is skipped whole (never half-written), so the
			// table stays exact: every recorded region is
			// fully present in the file.
			if (totalWritten + (uint64_t)regionSize > kZenithVESnapshotMaxBytes) {
				truncated = YES;
				break;
			}

			uint64_t regionOffset = totalWritten;
			uint64_t regionWritten = 0;
			BOOL regionOK = YES;
			mach_vm_address_t offset = 0;
			while (offset < regionSize) {
				vm_size_t chunk = (vm_size_t)MIN((uint64_t)kZenithVEChunkSize, (uint64_t)(regionSize - offset));
				vm_offset_t data = 0;
				mach_msg_type_number_t dataCount = 0;
				kern_return_t kr = vm_read(mach_task_self(), regionStart + offset, chunk, &data, &dataCount);
				if (kr != KERN_SUCCESS) {
					// A chunk that cannot be read breaks the
					// region's byte-for-byte alignment: drop
					// the whole region, not just the chunk.
					regionOK = NO;
					break;
				}
				size_t written = fwrite((const void *)data, 1, dataCount, file);
				vm_deallocate(mach_task_self(), data, dataCount);
				if (written != dataCount) {
					regionOK = NO;
					break;
				}
				regionWritten += (uint64_t)written;
				offset += chunk;
			}
			if (!regionOK) {
				// Roll the file back to the region's start so
				// the next region still lands at a known offset.
				fseek(file, (long)regionOffset, SEEK_SET);
				if (ftruncate(fileno(file), (off_t)regionOffset) != 0) {
					// Truncate failed: the file is unusable.
					error = @"ما قدرت أحفظ اللقطة — جرّب مرة ثانية.";
					break;
				}
				continue;
			}
			[regions addObject:@{
				@"start": @(regionStart),
				@"size": @(regionSize),
				@"offset": @(regionOffset),
			}];
			totalWritten += regionWritten;
			wroteAnything = YES;
		}
		fclose(file);

		if (error == nil && !wroteAnything) {
			error = @"ما قدرت أقرأ ذاكرة اللعبة — جرّب مرة ثانية.";
		}
		if (error != nil) {
			[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
		}
		NSArray<NSDictionary *> *keptRegions = [regions copy];
		[regions release];
		dispatch_async(dispatch_get_main_queue(), ^{
			self.scanning = NO;
			if (error == nil) {
				self.snapshotValid = YES;
				self.snapshotTruncated = truncated;
				self.snapshotType = type;
				self.snapshotBitsA = bitsA;
				self.snapshotRegions = keptRegions;
			} else {
				self.snapshotValid = NO;
				self.snapshotTruncated = NO;
				self.snapshotRegions = nil;
			}
			if (completion != NULL) {
				completion(error == nil, truncated, error);
			}
		});
		[keptRegions release];
	});
}

- (void)searchEncrypted:(NSString *)text completion:(void (^)(NSUInteger count, BOOL capped, NSString *error))completion {
	if (!self.snapshotValid) {
		if (completion != NULL) {
			completion(0, NO, @"خذ لقطة أول شي.");
		}
		return;
	}
	// Capture the snapshot state now: the compare runs on a
	// background queue, and a new snapshot cannot start while
	// scanning, so these cannot change under it.
	VEValueType type = self.snapshotType;
	uint64_t bitsA = self.snapshotBitsA;
	NSArray<NSDictionary *> *regions = [self.snapshotRegions copy];
	NSString *path = VEEncryptedSnapshotPath();
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		[regions release];
		if (completion != NULL) {
			completion(0, NO, @"اللقطة راحت — خذ لقطة جديدة.");
		}
		return;
	}
	uint64_t bitsB = 0;
	if (!VEParseBits(text, type, &bitsB)) {
		[regions release];
		if (completion != NULL) {
			completion(0, NO, @"الرقم مو صحيح — اكتب رقم يناسب النوع.");
		}
		return;
	}
	// A zero delta matches EVERYTHING (sA ^ sB == 0 for any word
	// that did not change, and 0*B == 0*A), so it is refused
	// outright instead of flooding the results list.
	if (bitsB == bitsA) {
		[regions release];
		if (completion != NULL) {
			completion(0, NO, @"ما غيّرت الرقم — غيّر القيمة باللعبة وبعدين دوس دوّر.");
		}
		return;
	}
	if (self.scanning) {
		[regions release];
		if (completion != NULL) {
			completion(0, NO, @"البحث شغال بعد — انتظر يخلص.");
		}
		return;
	}
	self.scanning = YES;
	self.currentType = type;
	size_t valueSize = VESizeForType(type);
	uint64_t mask = VEMaskForType(type);
	uint64_t delta = (bitsA ^ bitsB) & mask;
	// Lookup table: snapshot region by its start address.
	NSMutableDictionary<NSNumber *, NSDictionary *> *byStart = [[NSMutableDictionary alloc] init];
	for (NSDictionary *region in regions) {
		byStart[region[@"start"]] = region;
	}
	[regions release];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *found = [[NSMutableArray alloc] init];
		BOOL capped = NO;

		FILE *file = fopen([path UTF8String], "rb");
		if (file == NULL) {
			dispatch_async(dispatch_get_main_queue(), ^{
				self.scanning = NO;
				if (completion != NULL) {
					completion(0, NO, @"اللقطة راحت — خذ لقطة جديدة.");
				}
			});
			[byStart release];
			[found release];
			return;
		}

		mach_vm_address_t address = 0;
		mach_vm_size_t size = 0;
		vm_region_basic_info_data_64_t info;
		mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
		mach_port_t objectName = MACH_PORT_NULL;

		while (mach_vm_region(mach_task_self(), &address, &size,
							  VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
							  &infoCount, &objectName) == KERN_SUCCESS && !capped) {
			mach_vm_address_t regionStart = address;
			mach_vm_size_t regionSize = size;
			if (objectName != MACH_PORT_NULL) {
				mach_port_deallocate(mach_task_self(), objectName);
				objectName = MACH_PORT_NULL;
			}
			if (regionSize == 0) {
				break;
			}
			address += size;
			infoCount = VM_REGION_BASIC_INFO_COUNT_64;

			if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
				continue;
			}
			// Exact start match only. A region that moved or
			// resized between snapshot and compare is skipped
			// silently — its words no longer line up, and
			// guessing an offset would fake results.
			NSDictionary *snapRegion = byStart[@(regionStart)];
			if (snapRegion == nil) {
				continue;
			}
			if ([snapRegion[@"size"] unsignedLongLongValue] != (uint64_t)regionSize) {
				continue;
			}
			uint64_t fileOffset = [snapRegion[@"offset"] unsignedLongLongValue];

			mach_vm_address_t offset = 0;
			while (offset < regionSize && !capped) {
				vm_size_t chunk = (vm_size_t)MIN((uint64_t)kZenithVEChunkSize, (uint64_t)(regionSize - offset));
				// Snapshot bytes for this chunk.
				uint8_t *snapBytes = (uint8_t *)malloc(chunk);
				if (snapBytes == NULL) {
					offset += chunk;
					continue;
				}
				fseek(file, (long)(fileOffset + (uint64_t)offset), SEEK_SET);
				size_t snapRead = fread(snapBytes, 1, chunk, file);
				vm_offset_t data = 0;
				mach_msg_type_number_t dataCount = 0;
				kern_return_t kr = vm_read(mach_task_self(), regionStart + offset, chunk, &data, &dataCount);
				if (kr != KERN_SUCCESS || snapRead < chunk || dataCount < chunk) {
					if (kr == KERN_SUCCESS) {
						vm_deallocate(mach_task_self(), data, dataCount);
					}
					free(snapBytes);
					offset += chunk;
					continue;
				}
				const uint8_t *nowBytes = (const uint8_t *)data;
				// Aligned words only: region starts are
				// page-aligned, so stepping by valueSize from
				// the region start keeps absolute alignment.
				for (vm_size_t i = 0; i + valueSize <= dataCount; i += valueSize) {
					uint64_t sA = 0, sB = 0;
					memcpy(&sA, snapBytes + i, valueSize);
					memcpy(&sB, nowBytes + i, valueSize);
					sA &= mask;
					sB &= mask;
					VEResult *result = nil;
					// (a) XOR first: (sA ^ sB) == (A ^ B).
					// This also covers plain storage (key 0).
					if (((sA ^ sB) & mask) == delta) {
						result = [[VEResult alloc] init];
						result.transform = VEValueTransformXOR;
						result.transformParam = (sA ^ bitsA) & mask;
					} else if (bitsA != 0 && bitsB != 0) {
						// (b) Multiply, ONLY when A and B are
						// both non-zero — with A == 0 every
						// word satisfies sA*0 == sB*0. Signed
						// __int128 so no overflow can fake a
						// match on 64-bit values.
						BOOL mulMatch = NO;
						BOOL divisible = NO;
						uint64_t k = 0;
						if (valueSize == 4) {
							int32_t sa = 0, sb = 0, av = 0, bv = 0;
							uint64_t saB = sA, sbB = sB, aB = bitsA & mask, bB = bitsB & mask;
							memcpy(&sa, &saB, 4);
							memcpy(&sb, &sbB, 4);
							memcpy(&av, &aB, 4);
							memcpy(&bv, &bB, 4);
							mulMatch = ((__int128)sa * (__int128)bv == (__int128)sb * (__int128)av);
							if (mulMatch && av != 0 && (sa % av) == 0) {
								divisible = YES;
								int32_t kv = (int32_t)(sa / av);
								k = 0;
								memcpy(&k, &kv, 4);
							}
						} else {
							int64_t sa = (int64_t)sA, sb = (int64_t)sB;
							int64_t av = (int64_t)bitsA, bv = (int64_t)bitsB;
							mulMatch = ((__int128)sa * (__int128)bv == (__int128)sb * (__int128)av);
							if (mulMatch && av != 0 && (sa % av) == 0) {
								divisible = YES;
								k = (uint64_t)(sa / av);
							}
						}
						if (mulMatch) {
							result = [[VEResult alloc] init];
							result.transform = VEValueTransformMultiply;
							// K derivable only when it divides
							// evenly; otherwise param 0 marks
							// the result non-editable (see
							// VEStoredBitsForDisplayed).
							result.transformParam = divisible ? k : 0;
						}
					}
					if (result == nil) {
						continue;
					}
					result.address = (uint64_t)(regionStart + offset + i);
					result.bits = sB;
					result.type = type;
					[found addObject:result];
					[result release];
					if (found.count >= kZenithVEMaxResults) {
						capped = YES;
						break;
					}
				}
				vm_deallocate(mach_task_self(), data, dataCount);
				free(snapBytes);
				offset += chunk;
			}
		}
		fclose(file);

		dispatch_async(dispatch_get_main_queue(), ^{
			self.results = found;
			self.scanning = NO;
			if (completion != NULL) {
				NSString *error = nil;
				if (found.count == 0) {
					error = @"ما لگينا شي — جرّب غيّر الرقم أكثر.";
				} else if (capped) {
					error = @"النتائج هواي (فوق 100 ألف) — غيّر الرقم أكثر وبعدين دوّر من جديد.";
				}
				completion(found.count, capped, error);
			}
		});
		[found release];
		[byStart release];
	});
}

// MARK: Freeze

- (void)setFrozen:(BOOL)frozen forResult:(VEResult *)result {
	@synchronized (self.frozen) {
		result.frozen = frozen;
		if (frozen) {
			if (![self.frozen containsObject:result]) {
				[self.frozen addObject:result];
			}
			if (!self.freezeRunning) {
				self.freezeRunning = YES;
				[NSThread detachNewThreadSelector:@selector(freezeLoop)
										 toTarget:self
									   withObject:nil];
			}
		} else {
			[self.frozen removeObject:result];
			if (self.frozen.count == 0) {
				// The loop sees the empty list and exits on its own.
				self.freezeRunning = NO;
			}
		}
	}
	[self persistSaved];
}

- (void)freezeLoop {
	@autoreleasepool {
		while (self.freezeRunning) {
			NSArray<VEResult *> *snapshot = nil;
			@synchronized (self.frozen) {
				snapshot = [self.frozen copy];
			}
			if (snapshot.count == 0) {
				[snapshot release];
				break;
			}
			for (VEResult *result in snapshot) {
				uint64_t now = 0;
				if (![self readBitsAt:result.address type:result.type bitsOut:&now]) {
					continue;
				}
				[self writeBits:result.bits at:result.address type:result.type];
			}
			[snapshot release];
			snapshot = nil;
			[NSThread sleepForTimeInterval:kZenithVEFreezeInterval];
		}
		self.freezeRunning = NO;
	}
}

// MARK: Saved list

- (void)loadSaved {
	NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kZenithVESavedDefaultsKey];
	if (stored == nil) {
		return;
	}
	for (NSDictionary *dict in stored) {
		if (![dict isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		VEResult *result = [[VEResult alloc] init];
		NSString *addressHex = dict[@"address"];
		result.address = strtoull([addressHex UTF8String], NULL, 0);
		result.bits = strtoull([dict[@"bits"] UTF8String], NULL, 0);
		result.type = (VEValueType)[dict[@"type"] integerValue];
		result.label = dict[@"label"];
		result.frozen = [dict[@"frozen"] boolValue];
		// v2.27: missing keys mean Plain/0 (pre-2.27 saved lists).
		result.transform = (VEValueTransform)[dict[@"transform"] integerValue];
		NSString *paramHex = dict[@"transformParam"];
		result.transformParam = (paramHex != nil) ? strtoull([paramHex UTF8String], NULL, 0) : 0;
		[self.saved addObject:result];
		if (result.frozen) {
			[self.frozen addObject:result];
		}
		[result release];
	}
	if (self.frozen.count > 0 && !self.freezeRunning) {
		self.freezeRunning = YES;
		[NSThread detachNewThreadSelector:@selector(freezeLoop)
								 toTarget:self
							   withObject:nil];
	}
}

- (void)persistSaved {
	NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
	NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
	for (VEResult *result in self.saved) {
		NSNumber *key = @(result.address);
		if ([seen containsObject:key]) {
			continue;
		}
		[seen addObject:key];
		[stored addObject:@{
			@"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)result.address],
			@"bits": [NSString stringWithFormat:@"0x%llx", (unsigned long long)result.bits],
			@"type": @(result.type),
			@"label": result.label ?: @"",
			@"frozen": @(result.frozen),
			@"transform": @(result.transform),
			@"transformParam": [NSString stringWithFormat:@"0x%llx", (unsigned long long)result.transformParam],
		}];
	}
	[[NSUserDefaults standardUserDefaults] setObject:stored forKey:kZenithVESavedDefaultsKey];
}

- (void)saveResult:(VEResult *)result {
	for (VEResult *existing in self.saved) {
		if (existing.address == result.address) {
			existing.bits = result.bits;
			existing.type = result.type;
			existing.transform = result.transform;
			existing.transformParam = result.transformParam;
			// v2.28: the frozen flag used to be dropped here —
			// freeze a result, then save it, and the saved row
			// showed unfrozen (and a relaunch never re-froze
			// it), while the search-tab row still showed
			// "مثبّت". The live freeze loop keeps holding the
			// search-tab instance; the flag only makes the
			// saved row and the relaunch agree with it.
			existing.frozen = result.frozen;
			[self persistSaved];
			return;
		}
	}
	VEResult *copy = [[VEResult alloc] init];
	copy.address = result.address;
	copy.bits = result.bits;
	copy.type = result.type;
	copy.transform = result.transform;
	copy.transformParam = result.transformParam;
	copy.frozen = result.frozen;
	copy.label = result.label ?: VEStringForBits(VEDisplayedBitsForStored(result.bits, result.transform, result.transformParam, result.type), result.type);
	[self.saved addObject:copy];
	[copy release];
	[self persistSaved];
}

- (void)removeSaved:(VEResult *)result {
	[self.saved removeObject:result];
	@synchronized (self.frozen) {
		[self.frozen removeObject:result];
	}
	[self persistSaved];
}

- (void)applySaved:(VEResult *)result {
	[self writeBits:result.bits at:result.address type:result.type];
}

@end

// MARK: - ZenithValueEditorMenuViewController (the in-game menu)

/// The menu itself. One screen with two tabs ("بحث" / "المحفوظات"):
/// type picker, value field, search / refine / fuzzy buttons, a
/// results table, and tap-a-row to edit / freeze / save. Built with
/// plain UIKit, no storyboards — the dylib has no bundle of its own.
@interface ZenithValueEditorMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property (nonatomic, strong) UISegmentedControl *typeSeg;
@property (nonatomic, strong) UITextField *valueField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISegmentedControl *tabSeg;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *searchButton;
@property (nonatomic, strong) UIButton *refineButton;
@property (nonatomic, strong) UIStackView *fuzzyRow;
// v2.28: the fuzzy row's height constraint, kept so encrypted
// mode can collapse the row to 0 (see updateEncryptedUI).
// hidden=YES alone does NOT collapse it — the height
// constraint stays active and leaves a dead 34pt gap that
// eats the results table in landscape.
@property (nonatomic, strong) NSLayoutConstraint *fuzzyHeightConstraint;
// v2.27: encrypted mode — the "مشفّر" toggle at the leading
// side of the title row (mirroring "إغلاق" on the trailing
// side). ON: search becomes "خذ لقطة", refine becomes "دوّر",
// the fuzzy row hides. The snapshot survives turning the mode
// off (it only gates the compare).
// v2.28: the label stays "مشفّر" in both states — the FILL
// shows the state (peach = ON, dark = OFF), instead of the
// old label that flipped to the other mode's name and read
// like a different button.
@property (nonatomic, strong) UIButton *encryptedToggleButton;
@property (nonatomic, assign) BOOL encryptedMode;

/// v2.26: the edit panel lives INSIDE the menu (see
/// showEditPanelForResult:). Two alert generations (2.24
/// key-window presenter, 2.25 fresh key-window presenter)
/// both failed on device the same way — the alert's field
/// showed a blinking caret and the keyboard, but typed keys
/// never landed and the prefill never appeared (video
/// 2026-11-28 07:10, on 2.25). The alert approach is dead:
/// no UIAlertController is used for editing any more, so
/// there is no presenter to track and no presentingHost.
@property (nonatomic, strong) UIView *editPanel;
@property (nonatomic, strong) UILabel *editAddressLabel;
@property (nonatomic, strong) UITextField *editField;
@property (nonatomic, strong) UILabel *editStatusLabel;
@property (nonatomic, strong) UIButton *editApplyButton;
@property (nonatomic, strong) UIButton *editFreezeButton;
@property (nonatomic, strong) UIButton *editSaveButton;
@property (nonatomic, strong) UIButton *editRemoveButton;
@property (nonatomic, strong) VEResult *editingResult;
@property (nonatomic, assign) BOOL editingIsSavedTab;

- (void)refreshTable;
- (void)setStatus:(NSString *)text;
- (void)hideEditPanel;
- (NSArray<VEResult *> *)currentList;
- (VEResult *)resultAtIndex:(NSInteger)index;

@end

@implementation ZenithValueEditorMenuViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
	self.view.layer.cornerRadius = 16;
	self.view.clipsToBounds = YES;

	UILabel *title = [[UILabel alloc] init];
	title.text = @"محرر القيم";
	title.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	title.font = [UIFont boldSystemFontOfSize:18];
	title.textAlignment = NSTextAlignmentCenter;
	title.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:title];

	UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
	[close setTitle:@"إغلاق" forState:UIControlStateNormal];
	close.titleLabel.font = [UIFont systemFontOfSize:15];
	[close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	// v2.28: the title-row buttons used to be bare text on the
	// dark menu — no fill, and a tap target barely bigger than
	// the glyphs. Same dark fill (white 0.12) as the other
	// secondary buttons, same 8pt radius, and insets so the
	// target is a real button, not just the letters. No white
	// stroke anywhere (v2.10 rule) — fill only.
	close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
	close.layer.cornerRadius = 8;
	close.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
	[close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
	close.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:close];

	// v2.27: the encrypted-mode toggle, leading side of the
	// title row, mirroring "إغلاق" on the trailing side.
	// v2.28: same dark fill + 8pt radius + insets as "إغلاق",
	// so the two title controls match. The ON state is a peach
	// fill with black text (set in updateEncryptedUI); the
	// label itself never changes.
	self.encryptedToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.encryptedToggleButton setTitle:@"مشفّر" forState:UIControlStateNormal];
	self.encryptedToggleButton.titleLabel.font = [UIFont systemFontOfSize:15];
	[self.encryptedToggleButton setTitleColor:[UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0] forState:UIControlStateNormal];
	self.encryptedToggleButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
	self.encryptedToggleButton.layer.cornerRadius = 8;
	self.encryptedToggleButton.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
	[self.encryptedToggleButton addTarget:self action:@selector(encryptedToggleTapped) forControlEvents:UIControlEventTouchUpInside];
	self.encryptedToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.encryptedToggleButton];

	self.typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"صحيح", @"كبير", @"فلوت", @"دبل"]];
	self.typeSeg.selectedSegmentIndex = 0;
	// v2.28: the selected segment is peach with black text, so
	// it matches the peach primary buttons. The unselected
	// segments keep their default look on purpose — white text
	// over the default light pill would be unreadable.
	self.typeSeg.selectedSegmentTintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	[self.typeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]} forState:UIControlStateSelected];
	self.typeSeg.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.typeSeg];

	self.valueField = [[UITextField alloc] init];
	self.valueField.placeholder = @"اكتب الرقم هنا";
	self.valueField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	// v2.28: borderStyle None + our own 8pt radius, so the
	// field has exactly one border: the peach focus ring set
	// in textFieldDidBeginEditing (never a white stroke, v2.10
	// rule). Clear button while editing, no autocorrect on a
	// numbers field, Search return key.
	self.valueField.borderStyle = UITextBorderStyleNone;
	self.valueField.layer.cornerRadius = 8;
	self.valueField.clearButtonMode = UITextFieldViewModeWhileEditing;
	self.valueField.autocorrectionType = UITextAutocorrectionTypeNo;
	self.valueField.spellCheckingType = UITextSpellCheckingTypeNo;
	self.valueField.returnKeyType = UIReturnKeySearch;
	self.valueField.backgroundColor = [UIColor whiteColor];
	self.valueField.textColor = [UIColor blackColor];
	self.valueField.delegate = self;
	self.valueField.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.valueField];

	self.searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.searchButton setTitle:@"بحث" forState:UIControlStateNormal];
	self.searchButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
	[self.searchButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	self.searchButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	self.searchButton.layer.cornerRadius = 8;
	[self.searchButton addTarget:self action:@selector(searchTapped) forControlEvents:UIControlEventTouchUpInside];
	self.searchButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.searchButton];

	self.refineButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.refineButton setTitle:@"تضييق" forState:UIControlStateNormal];
	self.refineButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
	[self.refineButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	self.refineButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
	self.refineButton.layer.cornerRadius = 8;
	[self.refineButton addTarget:self action:@selector(refineTapped) forControlEvents:UIControlEventTouchUpInside];
	self.refineButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.refineButton];

	// Fuzzy refine row: what happened to the value since the last
	// search. Only meaningful after an exact search seeded the list.
	NSArray<NSString *> *fuzzyTitles = @[@"تغيّر", @"ما تغيّر", @"زاد", @"قلّ"];
	self.fuzzyRow = [[UIStackView alloc] init];
	self.fuzzyRow.axis = UILayoutConstraintAxisHorizontal;
	self.fuzzyRow.distribution = UIStackViewDistributionFillEqually;
	self.fuzzyRow.spacing = 6;
	self.fuzzyRow.translatesAutoresizingMaskIntoConstraints = NO;
	for (NSInteger i = 0; i < (NSInteger)fuzzyTitles.count; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
		[b setTitle:fuzzyTitles[i] forState:UIControlStateNormal];
		b.titleLabel.font = [UIFont systemFontOfSize:14];
		[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
		b.layer.cornerRadius = 8;
		b.tag = i;
		[b addTarget:self action:@selector(fuzzyTapped:) forControlEvents:UIControlEventTouchUpInside];
		[self.fuzzyRow addArrangedSubview:b];
	}
	[self.view addSubview:self.fuzzyRow];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.text = @"اكتب الرقم ودوس بحث.";
	self.statusLabel.textColor = [UIColor lightGrayColor];
	self.statusLabel.font = [UIFont systemFontOfSize:13];
	// v2.28: capped at 2 lines. Uncapped, a long status (the
	// old truncated-snapshot message ran to 4 lines) pushed
	// the tabs and the results table down — in landscape the
	// table lost the height the 2.22 fix had won back.
	self.statusLabel.numberOfLines = 2;
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.statusLabel];

	self.tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"بحث", @"المحفوظات"]];
	self.tabSeg.selectedSegmentIndex = 0;
	// v2.28: same peach selected segment as the type picker.
	self.tabSeg.selectedSegmentTintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	[self.tabSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]} forState:UIControlStateSelected];
	[self.tabSeg addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
	self.tabSeg.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.tabSeg];

	self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.tableView.backgroundColor = [UIColor clearColor];
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.tableView];

	// v2.28: the fuzzy row's height lives in a property so
	// encrypted mode can collapse it to 0 (see
	// updateEncryptedUI) — hidden=YES alone does NOT collapse
	// it: the 34pt height constraint stays active and leaves
	// a dead gap that eats the results table in landscape.
	self.fuzzyHeightConstraint = [self.fuzzyRow.heightAnchor constraintEqualToConstant:34];

	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
		[title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
		[close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.encryptedToggleButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
		[self.encryptedToggleButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.typeSeg.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
		[self.typeSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.typeSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.valueField.topAnchor constraintEqualToAnchor:self.typeSeg.bottomAnchor constant:8],
		[self.valueField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.valueField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.valueField.heightAnchor constraintEqualToConstant:36],
		[self.searchButton.topAnchor constraintEqualToAnchor:self.valueField.bottomAnchor constant:8],
		[self.searchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.searchButton.trailingAnchor constraintEqualToAnchor:self.refineButton.leadingAnchor constant:-8],
		[self.searchButton.heightAnchor constraintEqualToConstant:40],
		[self.refineButton.topAnchor constraintEqualToAnchor:self.valueField.bottomAnchor constant:8],
		[self.refineButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		// v2.28: the two buttons used to be 0.48 / 0.44 of the
		// menu width — visibly uneven. Equal widths with one
		// 8pt gap between them, matching the 8pt rhythm below.
		[self.refineButton.widthAnchor constraintEqualToAnchor:self.searchButton.widthAnchor],
		[self.refineButton.heightAnchor constraintEqualToConstant:40],
		[self.fuzzyRow.topAnchor constraintEqualToAnchor:self.searchButton.bottomAnchor constant:8],
		[self.fuzzyRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.fuzzyRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		self.fuzzyHeightConstraint,
		[self.statusLabel.topAnchor constraintEqualToAnchor:self.fuzzyRow.bottomAnchor constant:8],
		[self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.tabSeg.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
		[self.tabSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.tabSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.tableView.topAnchor constraintEqualToAnchor:self.tabSeg.bottomAnchor constant:8],
	[self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:0],
	[self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:0],
	[self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:0],
	]];

	// v2.26: the inline edit panel. It replaces the
	// UIAlertController edit sheet entirely (see the interface
	// note): it is a plain subview of the menu's own view, and
	// its field is built exactly like valueField above — the
	// one field that accepts typing on every phone test — so
	// it types. It covers the whole menu (opaque, so the search
	// controls behind it do not bleed through) and is
	// top-anchored, so the field and both button rows stay
	// above the landscape keyboard. Hidden until a result row
	// is tapped.
	self.editPanel = [[UIView alloc] init];
	// v2.28: near-black (white 0.06) instead of pure black —
	// the menu behind it is black at 0.92, so the panel used
	// to read as a pasted pure-black slab. Still fully opaque,
	// so the search controls behind it do not bleed through.
	self.editPanel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
	self.editPanel.layer.cornerRadius = 16;
	self.editPanel.clipsToBounds = YES;
	self.editPanel.hidden = YES;
	self.editPanel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.editPanel];

	UILabel *editTitle = [[UILabel alloc] init];
	editTitle.text = @"تعديل القيمة";
	editTitle.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	editTitle.font = [UIFont boldSystemFontOfSize:18];
	editTitle.textAlignment = NSTextAlignmentCenter;
	editTitle.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:editTitle];

	self.editAddressLabel = [[UILabel alloc] init];
	self.editAddressLabel.textColor = [UIColor whiteColor];
	self.editAddressLabel.font = [UIFont systemFontOfSize:15];
	self.editAddressLabel.textAlignment = NSTextAlignmentCenter;
	self.editAddressLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:self.editAddressLabel];

	self.editStatusLabel = [[UILabel alloc] init];
	self.editStatusLabel.textColor = [UIColor lightGrayColor];
	self.editStatusLabel.font = [UIFont systemFontOfSize:13];
	// v2.28: capped at 2 lines like the menu status — a long
	// message used to push the field and both button rows
	// down toward the landscape keyboard.
	self.editStatusLabel.numberOfLines = 2;
	self.editStatusLabel.textAlignment = NSTextAlignmentCenter;
	self.editStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:self.editStatusLabel];

	// Same construction as valueField: plain UITextField,
	// white background, black text, numbers keyboard, delegate
	// self. That field types on his phone every day; this one
	// is built the same way, in the same view, in the same
	// window, so it types too.
	self.editField = [[UITextField alloc] init];
	self.editField.placeholder = @"اكتب الرقم هنا";
	self.editField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	// v2.28: same treatment as valueField — borderStyle None
	// with our own 8pt radius (one border only: the peach
	// focus ring), clear button while editing, no autocorrect,
	// Done return key.
	self.editField.borderStyle = UITextBorderStyleNone;
	self.editField.layer.cornerRadius = 8;
	self.editField.clearButtonMode = UITextFieldViewModeWhileEditing;
	self.editField.autocorrectionType = UITextAutocorrectionTypeNo;
	self.editField.spellCheckingType = UITextSpellCheckingTypeNo;
	self.editField.returnKeyType = UIReturnKeyDone;
	self.editField.backgroundColor = [UIColor whiteColor];
	self.editField.textColor = [UIColor blackColor];
	self.editField.delegate = self;
	self.editField.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:self.editField];

	self.editApplyButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.editApplyButton setTitle:@"تعديل" forState:UIControlStateNormal];
	self.editApplyButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
	[self.editApplyButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	self.editApplyButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
	self.editApplyButton.layer.cornerRadius = 8;
	[self.editApplyButton addTarget:self action:@selector(editApplyTapped) forControlEvents:UIControlEventTouchUpInside];
	self.editApplyButton.translatesAutoresizingMaskIntoConstraints = NO;

	self.editFreezeButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.editFreezeButton setTitle:@"تثبيت القيمة" forState:UIControlStateNormal];
	self.editFreezeButton.titleLabel.font = [UIFont systemFontOfSize:16];
	[self.editFreezeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	self.editFreezeButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
	self.editFreezeButton.layer.cornerRadius = 8;
	[self.editFreezeButton addTarget:self action:@selector(editFreezeTapped) forControlEvents:UIControlEventTouchUpInside];
	self.editFreezeButton.translatesAutoresizingMaskIntoConstraints = NO;

	UIStackView *editRow1 = [[UIStackView alloc] initWithArrangedSubviews:@[self.editApplyButton, self.editFreezeButton]];
	editRow1.axis = UILayoutConstraintAxisHorizontal;
	editRow1.distribution = UIStackViewDistributionFillEqually;
	editRow1.spacing = 8;
	editRow1.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:editRow1];

	self.editSaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.editSaveButton setTitle:@"حفظ" forState:UIControlStateNormal];
	self.editSaveButton.titleLabel.font = [UIFont systemFontOfSize:16];
	[self.editSaveButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	self.editSaveButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
	self.editSaveButton.layer.cornerRadius = 8;
	[self.editSaveButton addTarget:self action:@selector(editSaveTapped) forControlEvents:UIControlEventTouchUpInside];
	self.editSaveButton.translatesAutoresizingMaskIntoConstraints = NO;

	self.editRemoveButton = [UIButton buttonWithType:UIButtonTypeSystem];
	// v2.28: was a 17-character title at 14pt — in the
	// 3-equal second row (~114pt per button in portrait) it
	// truncated. "حذف" fits, and the saved context is obvious
	// already.
	[self.editRemoveButton setTitle:@"حذف" forState:UIControlStateNormal];
	self.editRemoveButton.titleLabel.font = [UIFont systemFontOfSize:16];
	[self.editRemoveButton setTitleColor:[UIColor colorWithRed:1.0 green:0.35 blue:0.3 alpha:1.0] forState:UIControlStateNormal];
	self.editRemoveButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
	self.editRemoveButton.layer.cornerRadius = 8;
	[self.editRemoveButton addTarget:self action:@selector(editRemoveTapped) forControlEvents:UIControlEventTouchUpInside];
	self.editRemoveButton.translatesAutoresizingMaskIntoConstraints = NO;

	UIButton *editBackButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[editBackButton setTitle:@"رجوع" forState:UIControlStateNormal];
	editBackButton.titleLabel.font = [UIFont systemFontOfSize:16];
	[editBackButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	editBackButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
	editBackButton.layer.cornerRadius = 8;
	[editBackButton addTarget:self action:@selector(editBackTapped) forControlEvents:UIControlEventTouchUpInside];
	editBackButton.translatesAutoresizingMaskIntoConstraints = NO;

	UIStackView *editRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[self.editSaveButton, self.editRemoveButton, editBackButton]];
	editRow2.axis = UILayoutConstraintAxisHorizontal;
	editRow2.distribution = UIStackViewDistributionFillEqually;
	editRow2.spacing = 8;
	editRow2.translatesAutoresizingMaskIntoConstraints = NO;
	[self.editPanel addSubview:editRow2];

	[NSLayoutConstraint activateConstraints:@[
		[self.editPanel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0],
		[self.editPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:0],
		[self.editPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:0],
		[self.editPanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:0],
		[editTitle.topAnchor constraintEqualToAnchor:self.editPanel.topAnchor constant:12],
		[editTitle.centerXAnchor constraintEqualToAnchor:self.editPanel.centerXAnchor],
		[self.editAddressLabel.topAnchor constraintEqualToAnchor:editTitle.bottomAnchor constant:6],
		[self.editAddressLabel.leadingAnchor constraintEqualToAnchor:self.editPanel.leadingAnchor constant:12],
		[self.editAddressLabel.trailingAnchor constraintEqualToAnchor:self.editPanel.trailingAnchor constant:-12],
		[self.editStatusLabel.topAnchor constraintEqualToAnchor:self.editAddressLabel.bottomAnchor constant:6],
		[self.editStatusLabel.leadingAnchor constraintEqualToAnchor:self.editPanel.leadingAnchor constant:12],
		[self.editStatusLabel.trailingAnchor constraintEqualToAnchor:self.editPanel.trailingAnchor constant:-12],
		[self.editField.topAnchor constraintEqualToAnchor:self.editStatusLabel.bottomAnchor constant:8],
		[self.editField.leadingAnchor constraintEqualToAnchor:self.editPanel.leadingAnchor constant:12],
		[self.editField.trailingAnchor constraintEqualToAnchor:self.editPanel.trailingAnchor constant:-12],
		[self.editField.heightAnchor constraintEqualToConstant:36],
		[editRow1.topAnchor constraintEqualToAnchor:self.editField.bottomAnchor constant:8],
		[editRow1.leadingAnchor constraintEqualToAnchor:self.editPanel.leadingAnchor constant:12],
		[editRow1.trailingAnchor constraintEqualToAnchor:self.editPanel.trailingAnchor constant:-12],
		[editRow1.heightAnchor constraintEqualToConstant:40],
		[editRow2.topAnchor constraintEqualToAnchor:editRow1.bottomAnchor constant:8],
		[editRow2.leadingAnchor constraintEqualToAnchor:self.editPanel.leadingAnchor constant:12],
		[editRow2.trailingAnchor constraintEqualToAnchor:self.editPanel.trailingAnchor constant:-12],
		[editRow2.heightAnchor constraintEqualToConstant:40],
	]];
}

- (VEValueType)selectedType {
	return (VEValueType)self.typeSeg.selectedSegmentIndex;
}

- (NSArray<VEResult *> *)currentList {
	// v2.17: the list ivar was once seen holding a non-array
	// object (crash log 2026-11-28: -[OS_xpc_array count] on the
	// first menu open) — sending count to it aborts the game.
	// Never hand the table a non-array: replace a corrupt ivar
	// with an empty array (self-healing) and return an empty list.
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	BOOL useSaved = (self.tabSeg.selectedSegmentIndex == 1);
	NSArray *list = useSaved ? engine.saved : engine.results;
	if (![list isKindOfClass:[NSArray class]]) {
		if (useSaved) {
			engine.saved = [NSMutableArray array];
		} else {
			engine.results = [NSMutableArray array];
		}
		return @[];
	}
	return list;
}

- (VEResult *)resultAtIndex:(NSInteger)index {
	NSArray<VEResult *> *list = [self currentList];
	if (index < 0 || index >= (NSInteger)list.count) {
		return nil;
	}
	// v2.19: never hand the table a non-VEResult element. If a
	// list ever holds a foreign object again, show an empty row
	// instead of aborting the game on `result.address`.
	id obj = list[index];
	if (![obj isKindOfClass:[VEResult class]]) {
		return nil;
	}
	return obj;
}

- (void)refreshTable {
	[self.tableView reloadData];
}

- (void)setStatus:(NSString *)text {
	self.statusLabel.text = text;
}

- (void)closeTapped {
	[[ZenithValueEditorOverlay shared] hideMenu];
}

- (void)tabChanged {
	// v2.28: the keyboard used to stay up over the results
	// when switching tabs, and the status line kept
	// describing the other tab ("النتائج: …" while looking at
	// the saved list). Dismiss the keyboard and re-sync the
	// status to the list now on screen. Programmatic
	// setSelectedSegmentIndex: (search/refine completions)
	// does NOT fire this action, so no loop.
	[self.valueField resignFirstResponder];
	[self refreshTable];
	NSUInteger count = [self currentList].count;
	if (self.tabSeg.selectedSegmentIndex == 1) {
		[self setStatus:(count > 0)
			? [NSString stringWithFormat:@"المحفوظات: %lu قيمة محفوظة — دوس على وحدة وعدّلها.", (unsigned long)count]
			: @"ما عندك شي محفوظ بعد — دوس على نتيجة ودوس حفظ."];
		return;
	}
	if (self.encryptedMode) {
		[self updateEncryptedUI];
		return;
	}
	[self setStatus:(count > 0)
		? [NSString stringWithFormat:@"النتائج: %lu — دوس على وحدة وعدّلها.", (unsigned long)count]
		: @"اكتب الرقم ودوس بحث."];
}

- (void)encryptedToggleTapped {
	self.encryptedMode = !self.encryptedMode;
	[self updateEncryptedUI];
}

- (void)updateEncryptedUI {
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	// v2.28: the toggle label stays "مشفّر" — the FILL is the
	// state (peach + black text = ON, dark + peach text =
	// OFF). And the fuzzy row COLLAPSES (height 0), not just
	// hides: hidden=YES alone leaves its 34pt height
	// constraint active, a dead gap that shrank the results
	// table to under 2 rows in landscape.
	if (self.encryptedMode) {
		[self.encryptedToggleButton setTitle:@"مشفّر" forState:UIControlStateNormal];
		[self.encryptedToggleButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
		self.encryptedToggleButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0];
		self.valueField.placeholder = engine.snapshotValid
			? @"القيمة الثانية — اكتب الرقم الجديد"
			: @"القيمة الأولى — اكتب الرقم الحالي";
		[self.searchButton setTitle:@"خذ لقطة" forState:UIControlStateNormal];
		[self.refineButton setTitle:@"دوّر" forState:UIControlStateNormal];
		// "دوّر" stays disabled until a snapshot exists.
		self.refineButton.enabled = engine.snapshotValid;
		self.refineButton.alpha = engine.snapshotValid ? 1.0 : 0.4;
		self.fuzzyRow.hidden = YES;
		self.fuzzyHeightConstraint.constant = 0;
		[self setStatus:engine.snapshotValid
			? @"تم أخذ اللقطة — غيّر الرقم باللعبة ودوس دوّر."
			: @"اكتب الرقم الحالي ودوس خذ لقطة، بعدين غيّره باللعبة."];
	} else {
		[self.encryptedToggleButton setTitle:@"مشفّر" forState:UIControlStateNormal];
		[self.encryptedToggleButton setTitleColor:[UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0] forState:UIControlStateNormal];
		self.encryptedToggleButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
		self.valueField.placeholder = @"اكتب الرقم هنا";
		[self.searchButton setTitle:@"بحث" forState:UIControlStateNormal];
		[self.refineButton setTitle:@"تضييق" forState:UIControlStateNormal];
		self.refineButton.enabled = YES;
		self.refineButton.alpha = 1.0;
		self.fuzzyRow.hidden = NO;
		self.fuzzyHeightConstraint.constant = 34;
		// The snapshot is KEPT (it only gates the compare),
		// so turning the mode back on later resumes it.
		[self setStatus:@"اكتب الرقم ودوس بحث."];
	}
}

- (void)searchTapped {
	[self.valueField resignFirstResponder];
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	if (self.encryptedMode) {
		[self setStatus:@"جاري أخذ اللقطة…"];
		[engine takeEncryptedSnapshot:self.valueField.text type:[self selectedType] completion:^(BOOL success, BOOL truncated, NSString *error) {
			if (!success) {
				[self setStatus:error];
				return;
			}
			self.valueField.text = nil;
			self.valueField.placeholder = @"القيمة الثانية — اكتب الرقم الجديد";
			self.refineButton.enabled = YES;
			self.refineButton.alpha = 1.0;
			if (truncated) {
				[self setStatus:@"تم أخذ اللقطة، بس انقطعت (الذاكرة فوق 512 ميغا) — النتائج ممكن تكون ناقصة. غيّر الرقم ودوس دوّر."];
			} else {
				[self setStatus:@"تم أخذ اللقطة — غيّر الرقم باللعبة ودوس دوّر."];
			}
			[self.tabSeg setSelectedSegmentIndex:0];
			[self refreshTable];
		}];
		return;
	}
	[self setStatus:@"جاري البحث…"];
	[engine searchExact:self.valueField.text type:[self selectedType] completion:^(NSUInteger count, BOOL capped, NSString *error) {
		if (error != nil) {
			[self setStatus:error];
		} else {
			[self setStatus:[NSString stringWithFormat:@"النتائج: %lu — غيّر الرقم باللعبة وبعدين دوس تضييق.", (unsigned long)count]];
		}
		[self.tabSeg setSelectedSegmentIndex:0];
		[self refreshTable];
	}];
}

- (void)refineTapped {
	[self.valueField resignFirstResponder];
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	if (self.encryptedMode) {
		if (!engine.snapshotValid) {
			[self setStatus:@"خذ لقطة أول شي."];
			return;
		}
		[self setStatus:@"جاري التدوير…"];
		[engine searchEncrypted:self.valueField.text completion:^(NSUInteger count, BOOL capped, NSString *error) {
			if (error != nil) {
				[self setStatus:error];
			} else {
				[self setStatus:[NSString stringWithFormat:@"النتائج: %lu — دوس على وحدة وعدّلها.", (unsigned long)count]];
			}
			[self.tabSeg setSelectedSegmentIndex:0];
			[self refreshTable];
		}];
		return;
	}
	if ([engine safeResultsCount] == 0) {
		[self setStatus:@"ما عندك نتائج — ابحث أول شي."];
		return;
	}
	[self setStatus:@"جاري التضييق…"];
	[engine refineExact:self.valueField.text completion:^(NSUInteger count, NSString *error) {
		if (error != nil) {
			[self setStatus:error];
		} else {
			[self setStatus:[NSString stringWithFormat:@"النتائج: %lu — إذا بقى رقم واحد، دوس عليه وعدّله.", (unsigned long)count]];
		}
		[self refreshTable];
	}];
}

- (void)fuzzyTapped:(UIButton *)sender {
	// v2.28: dismiss the keyboard — search/refine already did,
	// but a fuzzy tap left it up over the bottom of the table.
	[self.valueField resignFirstResponder];
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	if ([engine safeResultsCount] == 0) {
		[self setStatus:@"ما عندك نتائج — ابحث أول شي."];
		return;
	}
	[self setStatus:@"جاري التضييق…"];
	[engine refineFuzzy:(VERefineMode)sender.tag completion:^(NSUInteger count) {
		[self setStatus:[NSString stringWithFormat:@"النتائج: %lu — إذا بقى رقم واحد، دوس عليه وعدّله.", (unsigned long)count]];
		[self refreshTable];
	}];
}

// MARK: Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)[self currentList].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *cellId = @"ZenithValueEditorCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
	if (cell == nil) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
		cell.backgroundColor = [UIColor clearColor];
		cell.textLabel.textColor = [UIColor whiteColor];
		cell.detailTextLabel.textColor = [UIColor lightGrayColor];
		// v2.28: explicit fonts on the menu's rhythm (15/13)
		// instead of the cell defaults (17/12).
		cell.textLabel.font = [UIFont systemFontOfSize:15];
		cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
	}
	VEResult *result = [self resultAtIndex:indexPath.row];
	if (result == nil) {
		cell.textLabel.text = @"";
		cell.detailTextLabel.text = @"";
		return cell;
	}
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	uint64_t now = 0;
	BOOL readable = [engine readBitsAt:result.address type:result.type bitsOut:&now];
	// v2.27: show the DISPLAYED value, not the stored bits —
	// for an encrypted result the stored bits are the XORed /
	// multiplied form, not the number the player sees.
	uint64_t displayed = readable ? VEDisplayedBitsForStored(now, result.transform, result.transformParam, result.type) : 0;
	NSString *valueText = readable ? VEStringForBits(displayed, result.type) : @"؟";
	cell.textLabel.text = [NSString stringWithFormat:@"0x%llx  —  %@", (unsigned long long)result.address, valueText];
	NSString *frozenMark = result.frozen ? @"مثبّت • " : @"";
	// v2.28: the subtitle used to be empty for every
	// unfrozen, unlabelled result — an empty second line on
	// every row. Fall back to the value type, so each row
	// always says something useful.
	NSString *label = (result.label != nil && result.label.length > 0) ? result.label : VETypeName(result.type);
	cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", frozenMark, label];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	VEResult *result = [self resultAtIndex:indexPath.row];
	if (result == nil) {
		return;
	}
	BOOL isSavedTab = (self.tabSeg.selectedSegmentIndex == 1);
	[self showEditPanelForResult:result isSavedTab:isSavedTab];
}

/// v2.26: the inline edit panel. A result row tap opens this
/// panel INSIDE the menu — no UIAlertController, no presenter,
/// no key-window walk. Two alert generations proved on device
/// (2.24, 2.25; video 2026-11-28 07:10 on 2.25) that an
/// alert's field never accepts typing in this game: caret
/// blinking, keyboard up, digits inserting nothing, prefill
/// never landing — even presented from the live key window
/// with a completion backstop. The menu's own valueField
/// types fine every day, so the panel's field is built
/// exactly like it, in the same view, in the same window.
- (void)showEditPanelForResult:(VEResult *)result isSavedTab:(BOOL)isSavedTab {
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	self.editingResult = result;
	self.editingIsSavedTab = isSavedTab;

	self.editAddressLabel.text = [NSString stringWithFormat:@"0x%llx  •  %@", (unsigned long long)result.address, VETypeName(result.type)];

	// Fresh read at tap time. Never fake a value: an
	// unreadable address gets the honest placeholder and a
	// disabled تعديل button, not a silent "0".
	uint64_t now = 0;
	BOOL readable = [engine readBitsAt:result.address type:result.type bitsOut:&now];
	if (readable) {
		// v2.27: prefill the DISPLAYED value (see cellForRow).
		uint64_t displayed = VEDisplayedBitsForStored(now, result.transform, result.transformParam, result.type);
		self.editField.text = VEStringForBits(displayed, result.type);
		// v2.28: the placeholder used to be nil here, so
		// clearing the field left it with no hint at all. A
		// placeholder only shows while the field is empty.
		self.editField.placeholder = @"اكتب الرقم الجديد";
		self.editApplyButton.enabled = YES;
		self.editApplyButton.alpha = 1.0;
	} else {
		self.editField.text = nil;
		self.editField.placeholder = @"ما گدرت أقرأ القيمة";
		self.editApplyButton.enabled = NO;
		self.editApplyButton.alpha = 0.4;
	}

	[self.editFreezeButton setTitle:(result.frozen ? @"إلغاء التثبيت" : @"تثبيت القيمة") forState:UIControlStateNormal];
	if (isSavedTab) {
		// v2.28: was a 21-character title — ~158pt at 16pt
		// in a ~114pt third of the row, so it truncated.
		[self.editSaveButton setTitle:@"كتابة القيمة" forState:UIControlStateNormal];
		self.editRemoveButton.hidden = NO;
	} else {
		[self.editSaveButton setTitle:@"حفظ" forState:UIControlStateNormal];
		self.editRemoveButton.hidden = YES;
	}
	self.editStatusLabel.text = @"";
	self.editPanel.hidden = NO;
	// The panel's field is a plain subview of the menu's own
	// view — the same responder chain as valueField — so the
	// keyboard comes up for it and typed keys land in it.
	[self.editField becomeFirstResponder];
}

- (void)hideEditPanel {
	[self.editField resignFirstResponder];
	self.editPanel.hidden = YES;
	self.editingResult = nil;
}

// The panel's status line is the one the user sees while
// editing; mirror it onto the menu's own status line too,
// so the last message is still there when the panel closes.
- (void)setEditStatus:(NSString *)text {
	self.editStatusLabel.text = text;
	[self setStatus:text];
}

// Edit / freeze / save logic, unchanged from the old alert
// handlers — only the trigger moved from the alert's buttons
// to the panel's buttons.
- (void)editApplyTapped {
	VEResult *result = self.editingResult;
	if (result == nil) {
		return;
	}
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	NSString *text = self.editField.text;
	uint64_t displayedBits = 0;
	if (!VEParseBits(text, result.type, &displayedBits)) {
		[self setEditStatus:@"الرقم مو صحيح — اكتب رقم يناسب النوع."];
		return;
	}
	// v2.27: the typed value is the DISPLAYED value — convert
	// it back to STORED bits before writing. If the conversion
	// is impossible (Multiply with an underivable K), do NOT
	// write: freezing still works, editing does not.
	uint64_t storedBits = 0;
	if (!VEStoredBitsForDisplayed(displayedBits, result.transform, result.transformParam, result.type, &storedBits)) {
		[self setEditStatus:@"هاي القيمة مشفّرة بطريقة ما نگدر نعدّلها — بس نگدر نثبّتها."];
		return;
	}
	if ([engine writeBits:storedBits at:result.address type:result.type]) {
		result.bits = storedBits;
		[self setEditStatus:@"تم التعديل."];
	} else {
		[self setEditStatus:@"ما قدرت أعدّل هاي القيمة — اللعبة حامية هاي الذاكرة."];
	}
	[self refreshTable];
}

- (void)editFreezeTapped {
	VEResult *result = self.editingResult;
	if (result == nil) {
		return;
	}
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	[engine setFrozen:!result.frozen forResult:result];
	[self setEditStatus:result.frozen ? @"القيمة مثبّتة — راح تبقى مثل ما هي." : @"تم إلغاء التثبيت."];
	[self.editFreezeButton setTitle:(result.frozen ? @"إلغاء التثبيت" : @"تثبيت القيمة") forState:UIControlStateNormal];
	[self refreshTable];
}

- (void)editSaveTapped {
	VEResult *result = self.editingResult;
	if (result == nil) {
		return;
	}
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	if (self.editingIsSavedTab) {
		[engine applySaved:result];
		[self setEditStatus:@"انكتبت القيمة المحفوظة."];
	} else {
		[engine saveResult:result];
		[self setEditStatus:@"انحفظت بقائمة المحفوظات."];
	}
	[self refreshTable];
}

- (void)editRemoveTapped {
	VEResult *result = self.editingResult;
	if (result == nil) {
		return;
	}
	[[ZenithValueEditor shared] removeSaved:result];
	// The result is gone — close the panel instead of
	// leaving it pointing at a deleted row.
	[self hideEditPanel];
	[self refreshTable];
}

- (void)editBackTapped {
	[self hideEditPanel];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[textField resignFirstResponder];
	return YES;
}

// v2.28: the focused field gets a peach ring — the only
// border in the menu, and it is never white (v2.10 rule).
// Both fields start with no border (borderStyle None,
// borderWidth 0), so the ring is the whole focus state.
- (void)textFieldDidBeginEditing:(UITextField *)textField {
	textField.layer.borderWidth = 2.0;
	textField.layer.borderColor = [[UIColor colorWithRed:1.0 green:0.78 blue:0.47 alpha:1.0] CGColor];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
	textField.layer.borderWidth = 0.0;
}

@end

// MARK: - ZenithValueEditorPlanetView (the floating button's art)

/// The Zenith ringed planet, drawn in code with CoreGraphics.
/// The dylib runs inside the game process, so it cannot load
/// Zenith's asset catalog — the art must be self-contained. This
/// redraws the approved icon (Feather/Resources/icon-b64/
/// appicon-zenith.png.b64, sampled: disc #FFC06B on black) at any
/// size: a dark circular button, a peach disc, and a thin peach
/// ring tilted about -15 degrees, passing behind the disc at the
/// top and in front of it at the bottom.
///
/// The ring is built parametrically (not with a scaled CTM) so
/// its stroke stays a uniform width all the way round.
@interface ZenithValueEditorPlanetView : UIView
@end

/// Adds a tilted-ellipse arc to the context: centre `center`,
/// semi-axes `a` (horizontal) and `b` (vertical), rotated by
/// `tilt` radians in screen coordinates (y down, so a negative
/// tilt lifts the right-hand end, like the approved icon).
/// Angles run 0..2*PI; in UIKit's y-down space 0..PI is the
/// bottom half of the ellipse — the near side of the ring.
static void VEAddTiltedEllipseArc(CGContextRef ctx, CGPoint center, CGFloat a, CGFloat b, CGFloat tilt, CGFloat startAngle, CGFloat endAngle) {
	NSInteger steps = 48;
	for (NSInteger i = 0; i <= steps; i++) {
		CGFloat t = startAngle + (endAngle - startAngle) * (CGFloat)i / (CGFloat)steps;
		CGFloat x = a * cos(t);
		CGFloat y = b * sin(t);
		CGFloat rx = x * cos(tilt) - y * sin(tilt);
		CGFloat ry = x * sin(tilt) + y * cos(tilt);
		CGPoint p = CGPointMake(center.x + rx, center.y + ry);
		if (i == 0) {
			CGContextMoveToPoint(ctx, p.x, p.y);
		} else {
			CGContextAddLineToPoint(ctx, p.x, p.y);
		}
	}
}

@implementation ZenithValueEditorPlanetView

- (void)drawRect:(CGRect)rect {
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	if (ctx == NULL) {
		return;
	}
	CGFloat w = CGRectGetWidth(self.bounds);
	CGPoint center = CGPointMake(w / 2, CGRectGetHeight(self.bounds) / 2);
	// The approved icon, sampled: disc #FFC06B.
	UIColor *peach = [UIColor colorWithRed:1.0 green:192.0 / 255.0 blue:107.0 / 255.0 alpha:1.0];
	CGFloat discRadius = w * 0.30;
	CGFloat ringRadius = w * 0.44;
	CGFloat ringWidth = MAX(2.0, w * 0.045);
	CGFloat tilt = -0.26; // about -15 degrees, right end lifted

	// Dark circular button, dimmed (alpha 0.45) so the game shows through
	// the pill; the peach planet below stays fully opaque so it reads
	// clearly over both light and dark game scenes.
	CGContextSetFillColorWithColor(ctx, [[UIColor colorWithWhite:0.05 alpha:0.45] CGColor]);
	CGContextFillEllipseInRect(ctx, self.bounds);

	// The ring, drawn full first: the disc painted over it next
	// hides the back half where it passes behind the planet.
	CGContextSetStrokeColorWithColor(ctx, [peach CGColor]);
	CGContextSetLineWidth(ctx, ringWidth);
	CGContextSetLineCap(ctx, kCGLineCapRound);
	VEAddTiltedEllipseArc(ctx, center, ringRadius, ringRadius * 0.38, tilt, 0, 2 * M_PI);
	CGContextStrokePath(ctx);

	// The planet disc.
	CGContextSetFillColorWithColor(ctx, [peach CGColor]);
	CGContextFillEllipseInRect(ctx, CGRectMake(center.x - discRadius, center.y - discRadius, discRadius * 2, discRadius * 2));

	// The front half of the ring, over the disc.
	CGContextSetStrokeColorWithColor(ctx, [peach CGColor]);
	CGContextSetLineWidth(ctx, ringWidth);
	CGContextSetLineCap(ctx, kCGLineCapRound);
	VEAddTiltedEllipseArc(ctx, center, ringRadius, ringRadius * 0.38, tilt, 0, M_PI);
	CGContextStrokePath(ctx);
}

@end

// MARK: - ZenithValueEditorOverlay (floating button + menu)

/// Owns the floating button window (the Zenith planet) and the
/// menu panel. The menu is a plain subview of the game's own
/// view (v2.16): NOT a second window — opening it as its own
/// UIWindow (initWithWindowScene: + hidden = NO) crashed the
/// game on tap — and NOT a child view controller either: the
/// v2.15 containment version crashed the game on tap too, on a
/// 2.15-signed copy. The pill window is a
/// ZenithValueEditorOverlayWindow, which refuses key-window
/// status, so tapping it can never steal the key window from
/// the game.
@interface ZenithValueEditorOverlayWindow : UIWindow
@end

@implementation ZenithValueEditorOverlayWindow

// The floating button must stay tappable without ever stealing
// key-window status from the game: a tap inside a visible
// non-key window can make that window key, and a game that
// loses its key window mid-frame can crash. Refusing key
// status is the standard way to keep an overlay window
// non-key (the status bar window does the same thing).
- (BOOL)canBecomeKeyWindow {
	return NO;
}

@end

@interface ZenithValueEditorOverlay : NSObject

+ (instancetype)shared;
- (void)setup;
- (void)showMenu;
- (void)hideMenu;
- (void)pillTapped;
- (void)dragged:(UIPanGestureRecognizer *)gesture;
- (UIWindow *)keyWindow;

@end

@implementation ZenithValueEditorOverlay {
	UIWindow *_pillWindow;
	ZenithValueEditorMenuViewController *_menu;
}

+ (instancetype)shared {
	static ZenithValueEditorOverlay *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [[ZenithValueEditorOverlay alloc] init];
	});
	return shared;
}

- (UIWindowScene *)foregroundScene {
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (scene.activationState != UISceneActivationStateForegroundActive) {
			continue;
		}
		if ([scene isKindOfClass:[UIWindowScene class]]) {
			return (UIWindowScene *)scene;
		}
	}
	return nil;
}

- (void)setup {
	if (_pillWindow != nil) {
		return;
	}

	// The floating button: the Zenith ringed planet, drawn in
	// code (ZenithValueEditorPlanetView) — no image asset needed.
	// A clear button on top takes the tap; the pan gesture on the
	// window takes the drag. The button is a 52pt circle.
	UIViewController *host = [[UIViewController alloc] init];
	host.view.backgroundColor = [UIColor clearColor];

	ZenithValueEditorPlanetView *planet = [[ZenithValueEditorPlanetView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
	planet.backgroundColor = [UIColor clearColor];
	[host.view addSubview:planet];

	UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
	tap.frame = CGRectMake(0, 0, 52, 52);
	tap.backgroundColor = [UIColor clearColor];
	[tap addTarget:self action:@selector(pillTapped) forControlEvents:UIControlEventTouchUpInside];
	[host.view addSubview:tap];

	UIWindowScene *scene = [self foregroundScene];
	if (scene != nil) {
		_pillWindow = [[ZenithValueEditorOverlayWindow alloc] initWithWindowScene:scene];
	} else {
		_pillWindow = [[ZenithValueEditorOverlayWindow alloc] initWithFrame:CGRectMake(16, 160, 52, 52)];
	}
	_pillWindow.frame = CGRectMake(16, 160, 52, 52);
	_pillWindow.windowLevel = UIWindowLevelStatusBar + 1;
	_pillWindow.backgroundColor = [UIColor clearColor];
	_pillWindow.rootViewController = host;
	_pillWindow.hidden = NO;

	UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
		initWithTarget:self action:@selector(dragged:)];
	[_pillWindow addGestureRecognizer:drag];
}

/// The game's key window, found the same way
/// ZenithTranslateOverlay finds it: the foreground scene's
/// window whose isKeyWindow is YES. Nil if the game has no
/// key window right now — showMenu bails out instead of
/// opening the menu anywhere else.
- (UIWindow *)keyWindow {
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (scene.activationState != UISceneActivationStateForegroundActive) {
			continue;
		}
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (window.isKeyWindow) {
				return window;
			}
		}
	}
	return nil;
}

- (void)showMenu {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self showMenu];
		});
		return;
	}
	// Already open and on screen: nothing to do.
	if (_menu != nil && _menu.view.window != nil && !_menu.view.hidden) {
		return;
	}
	// Reopen after a close: the menu is still attached to the
	// game's window, just hidden. Drop any edit panel left
	// open from last time, so the menu reopens on the results
	// list, not on a stale row.
	if (_menu != nil && _menu.view.window != nil) {
		[_menu hideEditPanel];
		_menu.view.hidden = NO;
		return;
	}
	// First open, or the host view went away while the menu was
	// hidden (its screen dismissed): drop the stale menu and
	// rebuild it below.
	if (_menu != nil) {
		[_menu.view removeFromSuperview];
		_menu = nil;
	}
	// NO containment (v2.16): the menu used to open as a child
	// view controller of the game's topmost view controller
	// (v2.15), but tapping the pill still crashed the game on a
	// 2.15-signed copy — the same crash as the second-window
	// version before it. addChildViewController /
	// didMoveToParentViewController are the only steps that
	// invoke the foreign game view controller's own machinery,
	// and they are the last suspect left by elimination:
	// viewDidLoad is pure UIKit, keyWindow and the host walk
	// are pure reads, and addSubview is the same plain view op
	// ads and SDKs do inside games. So the menu is now a plain
	// subview of the game's view — no containment at all. The
	// The menu edits inline inside itself now (v2.26):
	// tapping a result row opens an edit panel that is a plain
	// subview of the menu — no UIAlertController anywhere,
	// because two alert generations (2.24, 2.25) both failed
	// on device with a dead, untypeable field. The game keeps
	// its key window, its scene and its runloop untouched.
	// No memory scan starts here: searching only starts when
	// the user taps بحث.
	UIWindow *keyWindow = [self keyWindow];
	if (keyWindow == nil) {
		return;
	}
	UIViewController *host = keyWindow.rootViewController;
	while (host.presentedViewController != nil) {
		host = host.presentedViewController;
	}
	if (host == nil) {
		return;
	}
	_menu = [[ZenithValueEditorMenuViewController alloc] init];
	// v2.22: the menu used to be inset 60pt top/bottom, which left
	// the results table only ~14pt tall in landscape — the result
	// rows were invisible and untappable, so the editor could
	// search but never edit. 16pt insets give the table ~100pt
	// (2+ rows, scrollable) on an iPhone 11 landscape screen.
	_menu.view.frame = CGRectInset(host.view.bounds, 16, 16);
	_menu.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[host.view addSubview:_menu.view];
}

- (void)hideMenu {
	// Dismiss the keyboard too if the value field was editing,
	// so it does not linger over the game after the menu closes.
	[_menu.view endEditing:YES];
	_menu.view.hidden = YES;
}

- (void)pillTapped {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self pillTapped];
		});
		return;
	}
	if (_menu != nil && _menu.view.window != nil && !_menu.view.hidden) {
		[self hideMenu];
	} else {
		[self showMenu];
	}
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
	if (gesture.state == UIGestureRecognizerStateChanged) {
		CGPoint translation = [gesture translationInView:_pillWindow];
		CGPoint center = _pillWindow.center;
		center.x += translation.x;
		center.y += translation.y;
		_pillWindow.center = center;
		[gesture setTranslation:CGPointZero inView:_pillWindow];
		return;
	}
	if (gesture.state != UIGestureRecognizerStateEnded &&
		gesture.state != UIGestureRecognizerStateCancelled) {
		return;
	}
	// Drag ended: snap to the nearest left/right screen edge and
	// clamp inside the screen, so the button never sits in the
	// middle of the play area blocking gameplay.
	CGRect bounds = [UIScreen mainScreen].bounds;
	CGPoint center = _pillWindow.center;
	CGFloat halfW = CGRectGetWidth(_pillWindow.frame) / 2;
	CGFloat halfH = CGRectGetHeight(_pillWindow.frame) / 2;
	CGFloat margin = 8;
	CGFloat targetX = (center.x < CGRectGetMidX(bounds))
		? (halfW + margin)
		: (CGRectGetWidth(bounds) - halfW - margin);
	CGFloat targetY = MIN(MAX(center.y, halfH + margin),
						  CGRectGetHeight(bounds) - halfH - margin);
	[UIView animateWithDuration:0.2 animations:^{
		_pillWindow.center = CGPointMake(targetX, targetY);
	}];
}

@end

__attribute__((constructor)) static void ZenithValueEditorInit(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[ZenithValueEditor shared] setup];
		[[ZenithValueEditorOverlay shared] setup];
	});
}
