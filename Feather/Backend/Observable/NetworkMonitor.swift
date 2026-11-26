//
//  NetworkMonitor.swift
//  Zenith
//
//  Zenith v2.3: no-internet gate. If the device has NO internet at
//  all (Wi-Fi off and no mobile data), the app does not open — an
//  unskippable block screen is shown until connectivity returns.
//  This closes the bypass where turning Wi-Fi off skipped the
//  forced-update check (the check fails open with no network).
//
//  The gate reads connectivity only (NWPathMonitor), never Firebase
//  reachability: on a weak connection Firebase can fail while
//  general internet works, and that must not brick the app.

import Foundation
import Network

final class NetworkMonitor: ObservableObject {
	static let shared = NetworkMonitor()

	/// True once the monitor has reported a path without internet.
	/// Starts false (unknown): the app stays usable until the first
	/// path update arrives, which NWPathMonitor delivers immediately.
	@Published private(set) var isOffline = false

	private let _monitor = NWPathMonitor()
	private var _started = false

	private init() {}

	func start() {
		guard !_started else { return }
		_started = true
		_monitor.pathUpdateHandler = { [weak self] path in
			DispatchQueue.main.async {
				self?.isOffline = path.status != .satisfied
			}
		}
		_monitor.start(queue: DispatchQueue.global(qos: .background))
	}
}
