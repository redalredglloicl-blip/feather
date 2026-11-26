//
//  SigningQueueView.swift
//  Zenith
//
//  Zenith v2.2 — batch signing queue: pick several imported IPAs, sign
//  them one after another, watch each item's real status, retry the
//  ones that fail. Signing itself goes through Zenith.signPackageFile.

import SwiftUI
import CoreData
import NimbleViews

struct SigningQueueView: View {
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	@StateObject private var _queue = SigningQueueManager.shared
	@State private var _selectedUUIDs: Set<String> = []
	@Environment(\.dismiss) private var _dismiss
	
	var body: some View {
		ZStack {
			StarfieldBackground()
			NBNavigationView(.localized("Batch Signing")) {
				List {
					Section(.localized("Pick Apps to Sign")) {
						if _importedApps.isEmpty {
							Text(.localized("No unsigned apps. Import an IPA first."))
								.font(.subheadline)
								.foregroundStyle(.secondary)
								.zenithGlassCard(cornerRadius: 12)
								.listRowSeparator(.hidden)
						} else {
							ForEach(_importedApps, id: \.uuid) { app in
								_signingPickRow(for: app)
							}
						}
					}
				
					if !_queue.items.isEmpty {
						Section {
							ForEach(_queue.items) { item in
								SigningQueueItemRowView(item: item)
							}
						
							if _queue.failedCount > 0 {
								Button(.localized("Retry All Failed")) {
									for item in _queue.items where item.status == .failed {
										_queue.retry(item)
									}
								}
								.zenithGlassCard(cornerRadius: 12)
								.listRowSeparator(.hidden)
							}
						
							if _queue.doneCount > 0, !_queue.isRunning {
								Button(.localized("Clear Signed")) {
									_queue.clearFinished()
								}
								.zenithGlassCard(cornerRadius: 12)
								.listRowSeparator(.hidden)
							}
						} header: {
							HStack {
								Text(.localized("Signing Queue"))
								Spacer()
								if !_queue.items.isEmpty {
									Text(verbatim: "\(_queue.doneCount)/\(_queue.items.count)")
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						} footer: {
							if _queue.isRunning {
								Text(.localized("Signing one by one — keep the app open."))
							}
						}
					}
				
					Section {
						Button {
							let selected = _importedApps.filter { app in
								_selectedUUIDs.contains(app.uuid ?? "")
							}
							_queue.enqueue(selected)
							_selectedUUIDs.removeAll()
							_queue.start()
						} label: {
							if _queue.isRunning {
								ProgressView()
									.frame(maxWidth: .infinity)
							} else {
								Text(verbatim: .localized("Sign Selected (%lld)", arguments: _selectedUUIDs.count))
									.frame(maxWidth: .infinity)
							}
						}
						.buttonStyle(.borderedProminent)
						.disabled(_selectedUUIDs.isEmpty || _queue.isRunning)
					}
					.listRowBackground(Color.clear)
				}
				// Transparent list so the starfield shows through the gaps
				// between rows; rows themselves stay clear as well.
				.scrollContentBackground(.hidden)
				.background(Color.clear)
				.listRowBackground(Color.clear)
				.toolbar {
					NBToolbarButton(role: .close)
				}
				.alert(.localized("No Certificate"), isPresented: $_queue.showNoCertificateAlert) {
					Button(.localized("OK"), role: .cancel) {}
				} message: {
					Text(.localized("Please go to settings and import a valid certificate"))
				}
			}
		}
	}
	
	private func _signingPickRow(for app: Imported) -> some View {
		let uuid = app.uuid ?? ""
		let isSelected = _selectedUUIDs.contains(uuid)
		return Button {
			if isSelected {
				_selectedUUIDs.remove(uuid)
			} else {
				_selectedUUIDs.insert(uuid)
			}
		} label: {
			HStack(spacing: 12) {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.foregroundStyle(isSelected ? Color(hex: "#FFC778") : .secondary)
					.font(.title3)
				VStack(alignment: .leading, spacing: 2) {
					Text(app.name ?? .localized("Unknown"))
						.font(.subheadline)
						.lineLimit(1)
					if let version = app.version {
						Text(verbatim: version)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
			}
		}
		.buttonStyle(.plain)
		.zenithGlassCard(cornerRadius: 12)
		.listRowSeparator(.hidden)
	}
}

// MARK: - Queue item row

struct SigningQueueItemRowView: View {
	@ObservedObject var item: SigningQueueItem
	
	var body: some View {
		HStack(spacing: 12) {
			switch item.status {
			case .waiting:
				Image(systemName: "clock")
					.foregroundStyle(.secondary)
			case .signing:
				ProgressView()
			case .done:
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
			case .failed:
				Image(systemName: "xmark.circle.fill")
					.foregroundStyle(.red)
			}
			
			VStack(alignment: .leading, spacing: 2) {
				Text(item.app.name ?? .localized("Unknown"))
					.font(.subheadline)
					.lineLimit(1)
				Text(_statusText)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			
			Spacer()
			
			if item.status == .failed {
				Button(.localized("Retry")) {
					SigningQueueManager.shared.retry(item)
				}
				.buttonStyle(.borderless)
				.font(.subheadline)
			} else if item.status == .done || item.status == .waiting {
				Button {
					SigningQueueManager.shared.remove(item)
				} label: {
					Image(systemName: "xmark")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.borderless)
			}
		}
		.padding(.vertical, 2)
		.zenithGlassCard(cornerRadius: 12)
		.listRowSeparator(.hidden)
	}
	
	private var _statusText: String {
		switch item.status {
		case .waiting: return .localized("Waiting")
		case .signing: return .localized("Signing…")
		case .done: return .localized("Signed")
		case .failed: return item.errorMessage ?? .localized("Signing Failed")
		}
	}
}
