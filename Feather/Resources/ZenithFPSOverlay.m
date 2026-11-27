//
//  ZenithFPSOverlay.m
//  Zenith
//
//  Zenith v2.12, item 12 (#31): in-game FPS counter overlay.
//
//  A constructor-only dylib: it hooks NOTHING in the game. When
//  loaded (LC_LOAD_DYLIB, via the existing TweakHandler +
//  Zsign.injectDyLib path) it opens a small floating window above
//  the game and drives it with CADisplayLink, which fires once per
//  presented frame. The label therefore shows the game's rendered
//  frames per second as presented on screen — nothing more. The
//  pill is draggable, so the player can move it out of the way.
//
//  No CydiaSubstrate / ElleKit dependency: there is no hooking
//  here, only UIKit + QuartzCore, so the dylib loads with plain
//  LC_LOAD_DYLIB injection.
//
//  BUILD (not part of the Xcode app target — a dylib needs its own
//  build step; this file ships as source only until that step
//  exists, and FPSOverlayInjector reports the dylib as missing):
//
//    clang -dynamiclib -arch arm64 -miphoneos-version-min=14.0 \
//      -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
//      -framework Foundation -framework UIKit -framework QuartzCore \
//      -o ZenithFPS.dylib ZenithFPSOverlay.m
//
//  The resulting ZenithFPS.dylib is then bundled in the app (the
//  coordinator adds it as a resource) so FPSOverlayInjector can
//  find it as Bundle.main "ZenithFPS.dylib" and stage it for
//  injection at signing time.
//
//  HONEST LIMIT: CADisplayLink ticks on the main run loop's vsync,
//  so the number is the presented frame rate. A game that renders
//  off the main thread at a different internal rate still presents
//  through the same compositor, so the displayed number is what
//  the player actually sees. Offline games only.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface ZenithFPSOverlay : NSObject

+ (instancetype)shared;
- (void)setup;
- (void)displayLinkTick:(CADisplayLink *)link;
- (void)dragged:(UIPanGestureRecognizer *)gesture;

@end

@implementation ZenithFPSOverlay {
	UIWindow *_window;
	UILabel *_label;
	CADisplayLink *_link;
	NSUInteger _frames;
	NSTimeInterval _lastTime;
}

+ (instancetype)shared {
	static ZenithFPSOverlay *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shared = [[ZenithFPSOverlay alloc] init];
	});
	return shared;
}

- (void)setup {
	if (_window != nil) {
		return;
	}

	_label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 92, 30)];
	_label.text = @"FPS: --";
	_label.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0];
	_label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
	_label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
	_label.textAlignment = NSTextAlignmentCenter;
	_label.layer.cornerRadius = 15;
	_label.clipsToBounds = YES;

	UIViewController *host = [[UIViewController alloc] init];
	host.view.backgroundColor = [UIColor clearColor];
	[host.view addSubview:_label];

	_window = [[UIWindow alloc] initWithFrame:CGRectMake(16, 60, 92, 30)];
	_window.windowLevel = UIWindowLevelStatusBar + 1;
	_window.backgroundColor = [UIColor clearColor];
	_window.rootViewController = host;
	_window.hidden = NO;

	UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
		initWithTarget:self action:@selector(dragged:)];
	[_window addGestureRecognizer:drag];

	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

/// Counts presented frames; twice a second the label is updated
/// with frames / elapsed seconds.
- (void)displayLinkTick:(CADisplayLink *)link {
	_frames += 1;
	NSTimeInterval now = link.timestamp;
	if (_lastTime == 0) {
		_lastTime = now;
		return;
	}
	NSTimeInterval elapsed = now - _lastTime;
	if (elapsed >= 0.5) {
		double fps = (double)_frames / elapsed;
		_label.text = [NSString stringWithFormat:@"FPS: %lu", (unsigned long)lround(fps)];
		_frames = 0;
		_lastTime = now;
	}
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

@end

__attribute__((constructor)) static void ZenithFPSInit(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[ZenithFPSOverlay shared] setup];
	});
}
