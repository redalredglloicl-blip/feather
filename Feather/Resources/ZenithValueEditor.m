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
//  * Edit: write a new value to a found address with vm_write.
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
			long long v = strtoll(cText, &end, 0);
			if (end == cText || v < INT32_MIN || v > INT32_MAX) {
				return NO;
			}
			int32_t i = (int32_t)v;
			*bitsOut = 0;
			memcpy(bitsOut, &i, 4);
			return YES;
		}
		case VEValueTypeInt64: {
			long long v = strtoll(cText, &end, 0);
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
		_results = [NSMutableArray array];
		_saved = [NSMutableArray array];
		_frozen = [NSMutableArray array];
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

- (BOOL)writeBits:(uint64_t)bits at:(uint64_t)address type:(VEValueType)type {
	size_t size = VESizeForType(type);
	kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)&bits, (mach_msg_type_number_t)size);
	return kr == KERN_SUCCESS;
}

// MARK: Search

- (void)searchExact:(NSString *)text
			   type:(VEValueType)type
		 completion:(void (^)(NSUInteger count, BOOL capped, NSString *error))completion {
	uint64_t targetBits = 0;
	if (!VEParseBits(text, type, &targetBits)) {
		if (completion != NULL) {
			completion(0, NO, @"الرقم مو صحيح — اكتب رقم يناسب النوع اللي اخترته.");
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
		NSMutableArray<VEResult *> *found = [NSMutableArray array];
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
			// Next region: mach_vm_region keeps scanning from the
			// address we pass in, so advance past this one now.
			address += size;
			infoCount = VM_REGION_BASIC_INFO_COUNT_64;

			// Only readable regions can hold a value we can read.
			if ((info.protection & VM_PROT_READ) == 0) {
				continue;
			}

			mach_vm_address_t offset = 0;
			while (offset < regionSize && !capped) {
				vm_size_t chunk = (vm_size_t)MIN((uint64_t)kZenithVEChunkSize, (uint64_t)(regionSize - offset));
				vm_offset_t data = 0;
				mach_msg_type_number_t dataCount = 0;
				kern_return_t kr = vm_read(mach_task_self(), regionStart + offset, chunk, &data, &dataCount);
				if (kr != KERN_SUCCESS) {
					break;
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
	});
}

// Re-read every stored address and keep only the ones that now
// hold the new exact value.
- (void)refineExact:(NSString *)text completion:(void (^)(NSUInteger count, NSString *error))completion {
	uint64_t targetBits = 0;
	if (!VEParseBits(text, self.currentType, &targetBits)) {
		if (completion != NULL) {
			completion(self.results.count, @"الرقم مو صحيح.");
		}
		return;
	}
	if (self.scanning) {
		if (completion != NULL) {
			completion(self.results.count, @"البحث شغال بعد — انتظر يخلص.");
		}
		return;
	}
	self.scanning = YES;
	VEValueType type = self.currentType;
	NSArray<VEResult *> *previous = [self.results copy];
	size_t valueSize = VESizeForType(type);
	uint64_t mask = (valueSize == 8) ? UINT64_MAX : ((1ULL << (valueSize * 8)) - 1);

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *kept = [NSMutableArray array];
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
	});
}

// Fuzzy refine: compare each stored address's CURRENT value with
// the value it held when it was found (or last refined).
- (void)refineFuzzy:(VERefineMode)mode completion:(void (^)(NSUInteger count))completion {
	if (self.scanning) {
		if (completion != NULL) {
			completion(self.results.count);
		}
		return;
	}
	self.scanning = YES;
	VEValueType type = self.currentType;
	NSArray<VEResult *> *previous = [self.results copy];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<VEResult *> *kept = [NSMutableArray array];
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
				break;
			}
			for (VEResult *result in snapshot) {
				[self writeBits:result.bits at:result.address type:result.type];
			}
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
		[self.saved addObject:result];
		if (result.frozen) {
			[self.frozen addObject:result];
		}
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
		}];
	}
	[[NSUserDefaults standardUserDefaults] setObject:stored forKey:kZenithVESavedDefaultsKey];
}

- (void)saveResult:(VEResult *)result {
	for (VEResult *existing in self.saved) {
		if (existing.address == result.address) {
			existing.bits = result.bits;
			existing.type = result.type;
			[self persistSaved];
			return;
		}
	}
	VEResult *copy = [[VEResult alloc] init];
	copy.address = result.address;
	copy.bits = result.bits;
	copy.type = result.type;
	copy.label = result.label ?: VEStringForBits(result.bits, result.type);
	[self.saved addObject:copy];
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

/// The game's topmost view controller the menu's view hangs
/// off. The menu is NOT a child view controller (v2.16), so it
/// cannot present its edit sheets from itself — it presents
/// them from the host instead. Weak: the host owns the view
/// hierarchy, the menu must never keep it alive.
@property (nonatomic, weak) UIViewController *presentingHost;

- (void)refreshTable;
- (void)setStatus:(NSString *)text;
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
	[close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
	close.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:close];

	self.typeSeg = [[UISegmentedControl alloc] initWithItems:@[@"صحيح", @"كبير", @"فلوت", @"دبل"]];
	self.typeSeg.selectedSegmentIndex = 0;
	self.typeSeg.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.typeSeg];

	self.valueField = [[UITextField alloc] init];
	self.valueField.placeholder = @"اكتب الرقم هنا";
	self.valueField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	self.valueField.borderStyle = UITextBorderStyleRoundedRect;
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
	UIStackView *fuzzyRow = [[UIStackView alloc] init];
	fuzzyRow.axis = UILayoutConstraintAxisHorizontal;
	fuzzyRow.distribution = UIStackViewDistributionFillEqually;
	fuzzyRow.spacing = 6;
	fuzzyRow.translatesAutoresizingMaskIntoConstraints = NO;
	for (NSInteger i = 0; i < (NSInteger)fuzzyTitles.count; i++) {
		UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
		[b setTitle:fuzzyTitles[i] forState:UIControlStateNormal];
		b.titleLabel.font = [UIFont systemFontOfSize:14];
		[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
		b.layer.cornerRadius = 8;
		b.tag = i;
		[b addTarget:self action:@selector(fuzzyTapped:) forControlEvents:UIControlEventTouchUpInside];
		[fuzzyRow addArrangedSubview:b];
	}
	[self.view addSubview:fuzzyRow];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.text = @"اكتب الرقم ودوس بحث.";
	self.statusLabel.textColor = [UIColor lightGrayColor];
	self.statusLabel.font = [UIFont systemFontOfSize:13];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.statusLabel];

	self.tabSeg = [[UISegmentedControl alloc] initWithItems:@[@"بحث", @"المحفوظات"]];
	self.tabSeg.selectedSegmentIndex = 0;
	[self.tabSeg addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
	self.tabSeg.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.tabSeg];

	self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.tableView.backgroundColor = [UIColor clearColor];
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.tableView];

	[NSLayoutConstraint activateConstraints:@[
		[title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
		[title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
		[close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.typeSeg.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
		[self.typeSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.typeSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.valueField.topAnchor constraintEqualToAnchor:self.typeSeg.bottomAnchor constant:8],
		[self.valueField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.valueField.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.valueField.heightAnchor constraintEqualToConstant:36],
		[self.searchButton.topAnchor constraintEqualToAnchor:self.valueField.bottomAnchor constant:8],
		[self.searchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[self.searchButton.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.48],
		[self.searchButton.heightAnchor constraintEqualToConstant:40],
		[self.refineButton.topAnchor constraintEqualToAnchor:self.valueField.bottomAnchor constant:8],
		[self.refineButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[self.refineButton.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.44],
		[self.refineButton.heightAnchor constraintEqualToConstant:40],
		[fuzzyRow.topAnchor constraintEqualToAnchor:self.searchButton.bottomAnchor constant:8],
		[fuzzyRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
		[fuzzyRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
		[fuzzyRow.heightAnchor constraintEqualToConstant:34],
		[self.statusLabel.topAnchor constraintEqualToAnchor:fuzzyRow.bottomAnchor constant:8],
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
}

- (VEValueType)selectedType {
	return (VEValueType)self.typeSeg.selectedSegmentIndex;
}

- (NSArray<VEResult *> *)currentList {
	if (self.tabSeg.selectedSegmentIndex == 1) {
		return [ZenithValueEditor shared].saved;
	}
	return [ZenithValueEditor shared].results;
}

- (VEResult *)resultAtIndex:(NSInteger)index {
	NSArray<VEResult *> *list = [self currentList];
	if (index < 0 || index >= (NSInteger)list.count) {
		return nil;
	}
	return list[index];
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
	[self refreshTable];
}

- (void)searchTapped {
	[self.valueField resignFirstResponder];
	ZenithValueEditor *engine = [ZenithValueEditor shared];
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
	if (engine.results.count == 0) {
		[self setStatus:@"ما عندك نتائج تضيّقها — ابحث أول شي."];
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
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	if (engine.results.count == 0) {
		[self setStatus:@"ما عندك نتائج — ابحث عن رقم أول شي."];
		return;
	}
	[self setStatus:@"جاري التضييق…"];
	[engine refineFuzzy:(VERefineMode)sender.tag completion:^(NSUInteger count) {
		[self setStatus:[NSString stringWithFormat:@"النتائج: %lu", (unsigned long)count]];
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
	NSString *valueText = readable ? VEStringForBits(now, result.type) : @"؟";
	cell.textLabel.text = [NSString stringWithFormat:@"0x%llx  —  %@", (unsigned long long)result.address, valueText];
	NSString *frozenMark = result.frozen ? @"مثبّت • " : @"";
	NSString *label = (result.label != nil && result.label.length > 0) ? result.label : @"";
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
	[self showActionsForResult:result isSavedTab:isSavedTab];
}

/// Edit / freeze / save sheet for one address.
- (void)showActionsForResult:(VEResult *)result isSavedTab:(BOOL)isSavedTab {
	ZenithValueEditor *engine = [ZenithValueEditor shared];
	uint64_t now = 0;
	[engine readBitsAt:result.address type:result.type bitsOut:&now];

	UIAlertController *sheet = [UIAlertController
		alertControllerWithTitle:[NSString stringWithFormat:@"0x%llx", (unsigned long long)result.address]
		message:nil
		preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.text = VEStringForBits(now, result.type);
		textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
	}];

	UIAlertAction *edit = [UIAlertAction actionWithTitle:@"تعديل" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		NSString *text = sheet.textFields.firstObject.text;
		uint64_t bits = 0;
		if (!VEParseBits(text, result.type, &bits)) {
			[self setStatus:@"الرقم مو صحيح."];
			return;
		}
		if ([engine writeBits:bits at:result.address type:result.type]) {
			result.bits = bits;
			[self setStatus:@"تم التعديل."];
		} else {
			[self setStatus:@"ما قدرت أعدّل هاي القيمة — اللعبة حامية هاي الذاكرة."];
		}
		[self refreshTable];
	}];
	[sheet addAction:edit];

	NSString *freezeTitle = result.frozen ? @"إلغاء التثبيت" : @"تثبيت القيمة";
	UIAlertAction *freeze = [UIAlertAction actionWithTitle:freezeTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[engine setFrozen:!result.frozen forResult:result];
		[self setStatus:result.frozen ? @"القيمة مثبّتة — راح تبقى مثل ما هي." : @"تم إلغاء التثبيت."];
		[self refreshTable];
	}];
	[sheet addAction:freeze];

	if (!isSavedTab) {
		UIAlertAction *save = [UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[engine saveResult:result];
			[self setStatus:@"انحفظت بقائمة المحفوظات."];
			[self refreshTable];
		}];
		[sheet addAction:save];
	} else {
		UIAlertAction *apply = [UIAlertAction actionWithTitle:@"كتابة القيمة المحفوظة" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[engine applySaved:result];
			[self setStatus:@"انكتبت القيمة المحفوظة."];
			[self refreshTable];
		}];
		[sheet addAction:apply];
		UIAlertAction *remove = [UIAlertAction actionWithTitle:@"حذف من المحفوظات" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
			[engine removeSaved:result];
			[self refreshTable];
		}];
		[sheet addAction:remove];
	}

	[sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];

	// The menu is a plain subview, not a child view controller
	// (v2.16), so presenting from self would warn "whose view
	// is not in the window hierarchy" and drop the sheet.
	// Present from the host view controller instead.
	UIViewController *presenter = self.presentingHost ?: self;
	while (presenter.presentedViewController != nil) {
		presenter = presenter.presentedViewController;
	}
	[presenter presentViewController:sheet animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[textField resignFirstResponder];
	return YES;
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

	// Dark circular button.
	CGContextSetFillColorWithColor(ctx, [[UIColor colorWithWhite:0.05 alpha:0.92] CGColor]);
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
	// game's window, just hidden.
	if (_menu != nil && _menu.view.window != nil) {
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
	// menu still presents its edit sheets, through
	// presentingHost (see showActionsForResult:), and the game
	// keeps its key window, its scene and its runloop untouched.
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
	_menu.presentingHost = host;
	_menu.view.frame = CGRectInset(host.view.bounds, 16, 60);
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
