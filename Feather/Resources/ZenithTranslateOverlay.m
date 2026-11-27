
//
//  ZenithTranslateOverlay.m
//  Zenith
//
//  Zenith v2.12, item 22 (#79): tap-to-switch-language overlay.
//
//  A constructor-only dylib: when loaded (LC_LOAD_DYLIB, via the
//  existing TweakHandler + Zsign.injectDyLib path) it opens a
//  small draggable floating button above the app. Tapping the
//  button shows the languages the app actually ships
//  (its *.lproj folders); picking one makes the app read its
//  strings from that language's bundle from then on, by
//  swizzling NSBundle's localizedStringForKey:value:table:.
//  The choice is remembered in the app's own NSUserDefaults, so
//  it survives a relaunch. The button label always shows the
//  language currently in use.
//
//  WHAT THIS DOES NOT DO — stated plainly, because the name
//  invites the misunderstanding:
//  * It translates NOTHING. There is no translation engine in
//    here: no machine translation, no cloud service, no
//    dictionary. It only switches between translations that
//    already exist inside the app bundle — the developer's own
//    .lproj tables, or the ones the user typed at signing time
//    with the in-app translation tool (which rewrites the
//    bundled .strings files before signing).
//  * It only affects text the app loads through NSLocalizedString
//    / NSBundle. Text compiled into the binary, drawn as images,
//    or fetched from a server is untouched, and text already on
//    screen does not change until the screen is rebuilt (the
//    app has to reload its views — most apps do this on the
//    next navigation; nothing here forces a reload).
//  * It hooks one Foundation method (NSBundle localizedString)
//    via the Objective-C runtime. No CydiaSubstrate / ElleKit
//    dependency: there is no hooking here beyond that single
//    method exchange, only UIKit + Foundation, so the dylib
//    loads with plain LC_LOAD_DYLIB injection.
//
//  BUILD (not part of the Xcode app target — a dylib needs its own
//  build step; this file ships as source only until that step
//  exists, and TranslationOverlayInjector reports the dylib as
//  missing):
//
//    clang -dynamiclib -arch arm64 -miphoneos-version-min=14.0 \
//      -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//      -framework Foundation -framework UIKit \
//      -o ZenithTranslate.dylib ZenithTranslateOverlay.m
//
//  The resulting ZenithTranslate.dylib is then bundled in the app
//  (the coordinator adds it as a resource) so
//  TranslationOverlayInjector can find it as Bundle.main
//  "ZenithTranslate.dylib" and stage it for injection at signing
//  time.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const kZenithTranslateDefaultsKey = @"ZenithTranslateLanguage";

@interface ZenithTranslateOverlay : NSObject

+ (instancetype)shared;
- (void)setup;
- (void)buttonTapped:(UIButton *)sender;
- (void)dragged:(UIPanGestureRecognizer *)gesture;
- (NSArray<NSString *> *)bundledLanguages;
- (NSString *)currentLanguage;
- (void)applyLanguage:(NSString *)languageCode;
- (void)swizzleLocalizedString;

@end

@implementation ZenithTranslateOverlay {
	UIWindow *_window;
	UIButton *_button;
}

+ (instancetype)shared {
	static ZenithTranslateOverlay *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [[ZenithTranslateOverlay alloc] init];
	});
	return shared;
}

- (void)setup {
	if (_window != nil) {
		return;
	}

	[self swizzleLocalizedString];

	// Re-apply the remembered language, if the user picked one
	// in a previous launch.
	NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kZenithTranslateDefaultsKey];
	if (saved != nil) {
		[self applyLanguage:saved];
	}

	_button = [UIButton buttonWithType:UIButtonTypeSystem];
	[_button setTitle:[self currentLanguage] forState:UIControlStateNormal];
	_button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
	[_button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
	_button.layer.cornerRadius = 15;
	_button.clipsToBounds = YES;
	[_button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];

	UIViewController *host = [[UIViewController alloc] init];
	host.view.backgroundColor = [UIColor clearColor];
	[host.view addSubview:_button];

	_window = [[UIWindow alloc] initWithFrame:CGRectMake(16, 110, 64, 30)];
	_window.windowLevel = UIWindowLevelStatusBar + 1;
	_window.backgroundColor = [UIColor clearColor];
	_window.rootViewController = host;
	_window.hidden = NO;

	[_button setFrame:CGRectMake(0, 0, 64, 30)];

	UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
		initWithTarget:self action:@selector(dragged:)];
	[_window addGestureRecognizer:drag];
}

/// Languages the app bundle actually ships, from its *.lproj
/// folders. "Base" is not a language and is left out.
- (NSArray<NSString *> *)bundledLanguages {
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	NSError *error = nil;
	NSArray<NSString *> *contents = [[NSFileManager defaultManager]
		contentsOfDirectoryAtPath:bundlePath error:&error];
	NSMutableArray<NSString *> *languages = [NSMutableArray array];
	for (NSString *name in contents) {
		if (![name hasSuffix:@".lproj"]) {
			continue;
		}
		NSString *code = [name stringByDeletingPathExtension];
		if ([code isEqualToString:@"Base"]) {
			continue;
		}
		[languages addObject:code];
	}
	return [languages sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)currentLanguage {
	NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kZenithTranslateDefaultsKey];
	if (saved != nil) {
		return saved;
	}
	// No choice yet: the language the device is using for this
	// app, or the bundle's development region as a last resort.
	NSString *preferred = [[NSLocale preferredLanguages] firstObject];
	if (preferred != nil) {
		return preferred;
	}
	return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDevelopmentRegion"];
}

- (void)applyLanguage:(NSString *)languageCode {
	[[NSUserDefaults standardUserDefaults] setObject:languageCode forKey:kZenithTranslateDefaultsKey];
	[_button setTitle:languageCode forState:UIControlStateNormal];
}

- (void)buttonTapped:(UIButton *)sender {
	NSArray<NSString *> *languages = [self bundledLanguages];
	if (languages.count == 0) {
		return;
	}

	UIAlertController *sheet = [UIAlertController
		alertControllerWithTitle:@"Language"
		message:nil
		preferredStyle:UIAlertControllerStyleActionSheet];
	for (NSString *code in languages) {
		UIAlertAction *action = [UIAlertAction
			actionWithTitle:code
			style:UIAlertActionStyleDefault
			handler:^(UIAlertAction * _Nonnull action) {
				[self applyLanguage:code];
			}];
		[sheet addAction:action];
	}
	[sheet addAction:[UIAlertAction
		actionWithTitle:@"Cancel"
		style:UIAlertActionStyleCancel
		handler:nil]];

	UIWindow *keyWindow = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (scene.activationState != UISceneActivationStateForegroundActive) {
			continue;
		}
		if (![scene isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (window.isKeyWindow) {
				keyWindow = window;
				break;
			}
		}
		if (keyWindow != nil) {
			break;
		}
	}
	UIViewController *presenter = keyWindow.rootViewController;
	while (presenter.presentedViewController != nil) {
		presenter = presenter.presentedViewController;
	}
	[presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
	if (gesture.state != UIGestureRecognizerStateChanged) {
		return;
	}
	CGPoint translation = [gesture translationInView:_window];
	CGPoint center = _window.center;
	center.x += translation.x;
	center.y += translation.y;
	_window.center = center;
	[gesture setTranslation:CGPointZero inView:_window];
}

/// Swaps NSBundle's localizedStringForKey:value:table: with
/// zenith_localizedStringForKey:value:table:, which loads the
/// string from the chosen language's .lproj bundle instead of
/// the bundle the app asked. After the exchange, calling the
/// new selector runs the original implementation.
- (void)swizzleLocalizedString {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		Class bundleClass = [NSBundle class];
		SEL originalSelector = @selector(localizedStringForKey:value:table:);
		SEL swizzledSelector = @selector(zenith_localizedStringForKey:value:table:);
		Method originalMethod = class_getInstanceMethod(bundleClass, originalSelector);
		Method swizzledMethod = class_getInstanceMethod(bundleClass, swizzledSelector);
		if (originalMethod == NULL || swizzledMethod == NULL) {
			return;
		}
		method_exchangeImplementations(originalMethod, swizzledMethod);
	});
}

@end

@implementation NSBundle (ZenithTranslate)

- (NSString *)zenith_localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)tableName {
	NSString *languageCode = [[NSUserDefaults standardUserDefaults] stringForKey:kZenithTranslateDefaultsKey];
	if (languageCode == nil) {
		// No language chosen: run the original implementation.
		return [self zenith_localizedStringForKey:key value:value table:tableName];
	}
	NSString *lprojPath = [[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:[languageCode stringByAppendingPathExtension:@"lproj"]];
	NSBundle *languageBundle = [NSBundle bundleWithPath:lprojPath];
	if (languageBundle == nil) {
		return [self zenith_localizedStringForKey:key value:value table:tableName];
	}
	NSString *translated = [languageBundle zenith_localizedStringForKey:key value:value table:tableName];
	// The language bundle has no entry for this key: fall back
	// to whatever the app would have shown.
	if ([translated isEqualToString:key] && value != nil) {
		return value;
	}
	return translated;
}

@end

__attribute__((constructor)) static void ZenithTranslateInit(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[ZenithTranslateOverlay shared] setup];
	});
}
