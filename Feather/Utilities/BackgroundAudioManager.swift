//
//  BackgroundAudioManager.swift
//  Zenith
//
//  Created by Nagata Asami on 12/10/25.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

/// Silent-audio keep-alive: while anything holds it, Zenith keeps
/// playing silence so iOS does not suspend the process in the
/// background — the local install server (and the download
/// session) only survive while the process runs.
///
/// Zenith v2.21: the old start()/stop() pair was not safe to
/// share. Every start() attached a brand-new source node (never
/// detached), a second start() while the engine was already
/// running risked an attach-while-running exception, a stop()
/// from ANY caller killed the keep-alive for EVERY caller
/// (install vs. downloads vs. auto-refresh share this one
/// engine), and an audio interruption (call, Siri, another app)
/// stopped the engine with no restart — the process then
/// suspended mid-download and installd stalled at ~50% with a
/// white placeholder icon. Now start()/stop() are refcounted
/// (the engine runs while any caller holds it), the silence node
/// is created and attached once and reused, a start while running
/// is a no-op, and an ended interruption restarts the engine.
class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()

	private let _engine = AVAudioEngine()
	private let _lock = NSLock()

	/// Callers currently holding the keep-alive.
	private var _retainCount = 0
	/// The one silence node, attached once and reused forever.
	private var _silenceNode: AVAudioSourceNode?
	private var _interruptionObserver: NSObjectProtocol?

	private init() {
		_interruptionObserver = NotificationCenter.default.addObserver(
			forName: AVAudioSession.interruptionNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			self?._handleInterruption(notification)
		}
	}

	deinit {
		if let observer = _interruptionObserver {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	/// Hold the keep-alive. Refcounted and safe to call while
	/// already held, and safe to call from any thread.
	func start() {
		_lock.lock()
		defer { _lock.unlock() }
		_retainCount += 1
		if !_engine.isRunning {
			_startEngineLocked()
		}
	}

	/// Release one hold. The engine stops only when the last
	/// holder releases, so a download finishing cannot kill an
	/// install's keep-alive (or the reverse).
	func stop() {
		_lock.lock()
		defer { _lock.unlock() }
		guard _retainCount > 0 else { return }
		_retainCount -= 1
		guard _retainCount == 0 else { return }
		_engine.stop()
		try? AVAudioSession.sharedInstance().setActive(false)
	}

	/// Restart the engine if anything still holds the keep-alive
	/// but the engine is not running — a start that raced a stop,
	/// or a failed start that left a counted-but-dead hold
	/// (Zenith v2.23: the install session's start() used to leave
	/// exactly that phantom hold). Does not touch the refcount.
	/// Returns whether the engine is running afterwards.
	func ensureEngineRunning() -> Bool {
		_lock.lock()
		defer { _lock.unlock() }
		if _retainCount > 0, !_engine.isRunning {
			_startEngineLocked()
		}
		return _engine.isRunning
	}

	/// Start the engine. Called with _lock held.
	private func _startEngineLocked() {
		do {
			let session = AVAudioSession.sharedInstance()

			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			if _silenceNode == nil {
				let silence = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
					let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
					for buffer in ablPointer {
						memset(buffer.mData, 0, Int(buffer.mDataByteSize))
					}
					return noErr
				}

				_engine.attach(silence)
				_engine.connect(silence, to: _engine.mainMixerNode, format: nil)
				_silenceNode = silence
			}
			if !_engine.isRunning {
				try _engine.start()
			}
		} catch {
			// The hold is already counted: a later stop() still
			// balances it, and a later start() retries the engine.
			print("failed to start engine:", error)
		}
	}

	/// An interruption (call, Siri, another app's audio) stops
	/// the engine; when it ends, restart it if anything still
	/// holds the keep-alive — otherwise the process suspends
	/// and the install stalls with no recovery.
	private func _handleInterruption(_ notification: Notification) {
		guard
			let info = notification.userInfo,
			let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: typeValue),
			type == .ended
		else { return }

		_lock.lock()
		defer { _lock.unlock() }
		guard _retainCount > 0, !_engine.isRunning else { return }
		_startEngineLocked()
	}
}

#endif
