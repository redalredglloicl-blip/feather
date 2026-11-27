
//
//  PaywallDetector.swift
//  Zenith
//
//  Zenith v2.12, item 15 (#42): find the subscription / paywall
//  screen in an imported .app bundle and offer to remove it
//  before signing.
//
//  HONEST LIMITS — the UI states all of these plainly, and this
//  is the most honest tool of the four:
//  * This removes the LOCALLY-SHOWN subscription screen only.
//    It does NOT unlock server-verified premium features or
//    subscriptions. An app that checks the subscription with its
//    server (or with Apple) still knows the user is not
//    subscribed, and its premium features stay locked.
//  * Only local Bool flags can be changed: a key that shows the
//    paywall (set to false), or a key that marks the user as
//    subscribed locally (set to true). Flipping a local flag only
//    asks the app to hide its screen; an app that re-checks with
//    the server still shows the paywall or keeps premium locked.
//  * Subscription SDK frameworks (RevenueCat, Adapty, ...) and
//    paywall screen files are reported only and NEVER removed:
//    deleting them breaks the app at launch, and removing them
//    does not unlock anything the server verifies.
//  * If no local subscription screen or gate is found, the UI
//    says so plainly instead of offering a fake toggle.
//

import Foundation

// MARK: - Model

/// One local flag that may show the subscription screen or gate
/// premium, with the change that would hide the screen. Nil
/// change means the value is shown for information only.
struct PaywallFinding: Identifiable, Equatable {
	var id: String { finding.id }

	var finding: AppConfigFinding
	/// The staged change that hides the screen, or nil when this
	/// value is already in the wanted state.
	var proposedChange: AppConfigChange?

	/// True when the subscription screen is already hidden for
	/// this value, so there is nothing to change.
	var alreadyOff: Bool { proposedChange == nil }
}

/// One subscription SDK found inside the .app bundle. Reported
/// only — never removable.
struct DetectedPaywallSDK: Identifiable, Equatable {
	var id: String { frameworkName ?? displayName }

	/// Bundle name on disk, e.g. `RevenueCat.framework`.
	/// Nil when the SDK is only found inside the main executable.
	var frameworkName: String?
	var displayName: String
	/// True when the SDK's code was found inside the main
	/// executable itself (statically linked).
	var foundInBinary: Bool
}

/// The outcome of the subscription-screen scan.
struct PaywallReport: Equatable {
	var findings: [PaywallFinding]
	var sdks: [DetectedPaywallSDK]
	/// Screen files found by name (*Paywall* / *Subscription* /
	/// *Premium* storyboards, nibs, JSON layouts). Reported only.
	var paywallFiles: [String]
}

// MARK: - Known SDKs

struct KnownPaywallSDK {
	var frameworkName: String
	var displayName: String
	/// Distinctive strings found in the main executable when the
	/// SDK is compiled in statically.
	var binaryMarkers: [String]
}

// MARK: - Detector

enum PaywallDetector {
	static let knownSDKs: [KnownPaywallSDK] = [
		KnownPaywallSDK(frameworkName: "RevenueCat.framework", displayName: "RevenueCat", binaryMarkers: ["RevenueCat", "Purchases"]),
		KnownPaywallSDK(frameworkName: "PurchasesHybridCommon.framework", displayName: "RevenueCat (Hybrid)", binaryMarkers: ["PurchasesHybridCommon"]),
		KnownPaywallSDK(frameworkName: "Adapty.framework", displayName: "Adapty", binaryMarkers: ["Adapty"]),
		KnownPaywallSDK(frameworkName: "Qonversion.framework", displayName: "Qonversion", binaryMarkers: ["Qonversion"]),
		KnownPaywallSDK(frameworkName: "SuperwallKit.framework", displayName: "Superwall", binaryMarkers: ["Superwall"]),
		KnownPaywallSDK(frameworkName: "Paywall.framework", displayName: "Paywall", binaryMarkers: ["PaywallViewController"]),
	]

	/// Substrings that mark a key as subscription-related.
	/// Matching is case-insensitive.
	static let keyPatterns = [
		"paywall", "subscription", "premium", "subscribed",
		"ispro", "prounlock", "unlockpro", "showpaywall", "iap",
	]
	/// Substrings in a file name that mark the whole file as
	/// config worth parsing.
	static let fileNameHints = [
		"config", "settings", "remote", "feature", "flags",
		"defaults", "preferences", "constants", "app",
		"subscription", "paywall", "premium", "purchase", "iap",
	]
	/// Safety cap so a huge bundle cannot stall the signing screen.
	static let maxScannedEntries = 20000

	/// Scans `appDirectory` (a `.app` bundle) for a local
	/// subscription screen. Synchronous — call from a background
	/// queue.
	static func detect(appDirectory: URL) -> PaywallReport {
		let findings = _detectConfig(appDirectory: appDirectory)
		let sdks = _detectSDKs(appDirectory: appDirectory)
		let paywallFiles = _detectPaywallFiles(appDirectory: appDirectory)
		return PaywallReport(findings: findings, sdks: sdks, paywallFiles: paywallFiles)
	}

	// MARK: Config values

	private static func _detectConfig(appDirectory: URL) -> [PaywallFinding] {
		let found = AppConfigScanner.scan(
			appDirectory: appDirectory,
			keyPatterns: keyPatterns,
			fileNameHints: fileNameHints
		)
		var results: [PaywallFinding] = []
		for finding in found {
			results.append(PaywallFinding(
				finding: finding,
				proposedChange: _proposedChange(for: finding)
			))
		}
		return results
	}

	/// Decides the staged change for one found value, or nil when
	/// it is already in the wanted state (or is not a Bool at
	/// all — numbers and strings say nothing reliable about a
	/// subscription screen and are never changed).
	private static func _proposedChange(for finding: AppConfigFinding) -> AppConfigChange? {
		guard case .bool(let current) = finding.value else { return nil }
		let key = finding.key.lowercased()

		// A key that marks the user as subscribed locally
		// ("isSubscribed", "hasPremium", ...) gets set to true.
		// Checked first: "premiumUnlocked" contains neither
		// "show" nor "enabled", but "isPro" style keys must not
		// fall through to the hide-screen branch.
		if key.contains("subscribed") || key.contains("premium") || key.contains("ispro")
			|| key.contains("unlocked") || key.contains("unlockpro") || key.contains("prounlock") {
			return current ? nil : AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .bool(true)
			)
		}

		// A key that shows or forces the paywall ("showPaywall",
		// "paywallEnabled", "subscriptionRequired", ...) gets set
		// to false.
		if key.contains("show") || key.contains("enabled") || key.contains("force")
			|| key.contains("required") || key.contains("wall") || key.contains("block")
			|| key.contains("subscription") || key.contains("iap") {
			return current ? AppConfigChange(
				relativePath: finding.relativePath,
				key: finding.key,
				value: .bool(false)
			) : nil
		}

		return nil
	}

	// MARK: SDKs + screen files (detection only)

	private static func _detectSDKs(appDirectory: URL) -> [DetectedPaywallSDK] {
		var found: [String: DetectedPaywallSDK] = [:]

		// 1. Bundled frameworks on disk.
		let frameworksDir = appDirectory.appendingPathComponent("Frameworks")
		if let entries = try? FileManager.default.contentsOfDirectory(
			at: frameworksDir,
			includingPropertiesForKeys: [.isDirectoryKey]
		) {
			for url in entries where url.pathExtension.lowercased() == "framework" {
				let name = url.lastPathComponent
				guard let known = knownSDKs.first(where: {
					$0.frameworkName.lowercased() == name.lowercased()
				}) else { continue }
				found[known.frameworkName.lowercased()] = DetectedPaywallSDK(
					frameworkName: known.frameworkName,
					displayName: known.displayName,
					foundInBinary: false
				)
			}
		}

		// 2. Main executable: statically linked SDKs.
		if let executableURL = Bundle(url: appDirectory)?.executableURL {
			let markers = _binaryMarkersFound(
				in: executableURL,
				markers: knownSDKs.flatMap(\.binaryMarkers)
			)
			for known in knownSDKs {
				let key = known.frameworkName.lowercased()
				let markerHit = known.binaryMarkers.contains { markers.contains($0) }
				if var existing = found[key] {
					existing.foundInBinary = markerHit
					found[key] = existing
				} else if markerHit {
					found[key] = DetectedPaywallSDK(
						frameworkName: nil,
						displayName: known.displayName,
						foundInBinary: true
					)
				}
			}
		}

		var sdks = Array(found.values)
		sdks.sort { $0.displayName < $1.displayName }
		return sdks
	}

	private static func _detectPaywallFiles(appDirectory: URL) -> [String] {
		var files: [String] = []
		let appPath = appDirectory.path
		guard let enumerator = FileManager.default.enumerator(
			at: appDirectory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else {
			return files
		}

		var scanned = 0
		for case let url as URL in enumerator {
			scanned += 1
			if scanned > maxScannedEntries { break }
			let relativePath = url.path.replacingOccurrences(of: appPath + "/", with: "")
			let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
			if ["_CodeSignature", "Frameworks", "PlugIns", "Watch"].contains(firstComponent) {
				continue
			}
			let ext = url.pathExtension.lowercased()
			guard ext == "storyboard" || ext == "nib" || ext == "json" else { continue }
			let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
			guard fileName.contains("paywall") || fileName.contains("subscription")
				|| fileName.contains("premium") else { continue }
			files.append(relativePath)
			if files.count >= 20 { break }
		}

		files.sort()
		return files
	}

	/// Searches the main executable for the given ASCII markers,
	/// in 1MB chunks with overlap so a marker split across a chunk
	/// boundary is still found.
	private static func _binaryMarkersFound(in executableURL: URL, markers: [String]) -> Set<String> {
		guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return [] }
		defer { try? handle.close() }
		let markerData = markers.map { ($0, Data($0.utf8)) }
		var found = Set<String>()
		let chunkSize = 1024 * 1024
		let overlap = 256
		var carry = Data()
		while found.count < markers.count {
			let chunk = handle.readData(ofLength: chunkSize)
			guard !chunk.isEmpty else { break }
			let data = carry + chunk
			for (marker, bytes) in markerData where !found.contains(marker) {
				if data.range(of: bytes) != nil { found.insert(marker) }
			}
			carry = data.suffix(overlap)
		}
		return found
	}
}
