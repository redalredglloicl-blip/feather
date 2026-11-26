//
//  StarfieldBackground.swift
//  Zenith
//
//  Zenith v2.2 (shared UI foundation): a soft white starfield on black
//  used behind the Home, Certificates and Settings screens, the signing
//  success screen, the forced-update screen and the startup screen.
//  Apply with `.starfieldBackground()` — stars always sit BEHIND content.
//
//  Performance (iPhone 11: 60 Hz, 4 GB RAM): one Canvas redraws ~200
//  pre-computed star positions per frame — no per-star views, no images,
//  no per-frame allocation. Twinkle is a cheap sine on opacity only.
//  The shooting stars are two stroked lines per cycle at most.

import SwiftUI

// MARK: - View
struct StarfieldBackground: View {
	private let _stars: [Star]
	private let _starCount: Int

	init(starCount: Int = 200) {
		_starCount = starCount
		var rng = SeededRandom(seed: 20261126)
		var stars: [Star] = []
		stars.reserveCapacity(starCount)
		for _ in 0..<starCount {
			stars.append(
				Star(
					x: rng.next(),
					y: rng.next(),
					radius: 0.5 + rng.next() * 1.3,
					opacity: 0.35 + rng.next() * 0.65,
					speed: 0.6 + rng.next() * 1.8,
					phase: rng.next() * .pi * 2
				)
			)
		}
		_stars = stars
	}

	var body: some View {
		ZStack {
			Color.black

			TimelineView(.animation) { timeline in
				Canvas { context, size in
					let time = timeline.date.timeIntervalSinceReferenceDate

					for star in _stars {
						let twinkle = 0.55 + 0.45 * sin(time * star.speed + star.phase)
						context.opacity = star.opacity * twinkle
						let rect = CGRect(
							x: star.x * size.width - star.radius,
							y: star.y * size.height - star.radius,
							width: star.radius * 2,
							height: star.radius * 2
						)
						context.fill(Path(ellipseIn: rect), with: .color(.white))
					}

					// Shooting stars (item 14): a 3 s cycle with up to
					// two streaks — the second is offset by half a
					// cycle, so a streak is visible roughly every
					// 1.5 s. Each streak is visible for the first
					// 0.9 s of its own cycle.
					let cycleLength = 3.0
					for streak in 0..<2 {
						let streakTime = time + Double(streak) * cycleLength / 2
						let cycle = Int(streakTime / cycleLength)
						let cycleTime = streakTime.truncatingRemainder(dividingBy: cycleLength)
						if cycleTime < 0.9 {
							let progress = cycleTime / 0.9
							var rng = SeededRandom(seed: UInt64(cycle &* 2654435761 &+ 97 &+ streak &* 1_000_003))
							let startX = (0.15 + rng.next() * 0.55) * size.width
							let startY = rng.next() * 0.35 * size.height
							let travel = 0.35 * size.width
							let head = CGPoint(
								x: startX + progress * travel,
								y: startY + progress * travel * 0.45
							)
							let tail = CGPoint(
								x: head.x - travel * 0.28,
								y: head.y - travel * 0.28 * 0.45
							)
							context.opacity = 1 - progress
							let gradient = Gradient(colors: [.clear, .white])
							var path = Path()
							path.move(to: tail)
							path.addLine(to: head)
							context.stroke(
								path,
								with: .linearGradient(gradient, startPoint: tail, endPoint: head),
								lineWidth: 1.5
							)
							let dot = CGRect(x: head.x - 1, y: head.y - 1, width: 2, height: 2)
							context.fill(Path(ellipseIn: dot), with: .color(.white))
						}
					}

					context.opacity = 1
				}
			}
		}
		.ignoresSafeArea()
	}
}

// MARK: - View extension
extension View {
	/// Layers the Zenith starfield behind this view's content.
	func starfieldBackground() -> some View {
		background(StarfieldBackground())
	}
}

// MARK: - Private types
private struct Star {
	var x: Double
	var y: Double
	var radius: Double
	var opacity: Double
	var speed: Double
	var phase: Double
}

/// Tiny deterministic RNG so the stars are laid out once, identically
/// on every launch — no per-frame random work.
private struct SeededRandom {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
	}

	mutating func next() -> Double {
		state &*= 6364136223846793005
		state &+= 1442695040888963407
		return Double((state >> 11) & 0x1FFFFFFFFFFFFF) / Double(0x1FFFFFFFFFFFFF)
	}
}
