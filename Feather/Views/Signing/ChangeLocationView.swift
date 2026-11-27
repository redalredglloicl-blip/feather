
//
//  ChangeLocationView.swift
//  Zenith
//
//  Zenith v2.12, item 19 (#60): change the location an app sees.
//  Item 12 of the "تعديل التطبيقات" section on the signing screen,
//  after item 11 (change app font, #45) and before item 13
//  (use without account, #61).
//
//  The screen scans the imported .app for location usage
//  (CoreLocation link or NSLocation*UsageDescription keys), then
//  offers a city picker plus hand-typed coordinates. The choice
//  is staged in Options.locationSpoof and written into the copied
//  .app as ZenithLocationSpoof.json by LocationSpoofWriter at
//  signing time, before re-signing.
//
//  HONEST LIMITS — shown in the UI, not hidden: the JSON file
//  alone does nothing. A location-spoof tweak (.dylib) must read
//  it at runtime, and Zenith ships none — the user adds their own
//  through the existing injection path, same as any tweak. Only
//  apps that read location locally through CoreLocation can be
//  spoofed; server-verified location cannot.
//
//  WIRING (coordinator): drop the row into the "تعديل التطبيقات"
//  section as item 12 — the row label carries the title and the
//  1–2 line Iraqi explanation, per Reda's rule. SigningView.swift
//  is NOT edited by this file:
//
//    NavigationLink {
//        ChangeLocationView(app: app, options: $_temporaryOptions)
//    } label: {
//        ChangeLocationRowLabel()
//    }
//    .zenithGlassCard(cornerRadius: 12)
//    .padding(.vertical, 6)
//    .listRowSeparator(.hidden)
//
//  The coordinator also adds Options.locationSpoof (see the
//  report) and the one LocationSpoofWriter hook in
//  SigningHandler.modify().
//
//  MARK: - ChangeLocationView
//  MARK: - ChangeLocationRowLabel
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ChangeLocationView: View {
	let app: AppInfoPresentable
	
	@Binding var options: Options
	
	@State private var _report: LocationSpoofReport?
	@State private var _isScanning = true
	@State private var _appDirectoryMissing = false
	@State private var _isAddingPresenting = false
	@State private var _customLatitude = ""
	@State private var _customLongitude = ""
	@State private var _customInvalid = false
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Change Location")) {
			NBSection(.localized("Change Location")) {
				Text(verbatim: .localized("Change Location Description"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
				Text(verbatim: .localized("Location Spoof Needs Tweak"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
				Text(verbatim: .localized("Server Location Cannot Be Spoofed"))
					.font(.footnote)
					.foregroundStyle(.secondary)
					.zenithGlassCard(cornerRadius: 12)
					.padding(.vertical, 6)
					.listRowSeparator(.hidden)
			}
			
			if _appDirectoryMissing {
				NBSection(.localized("Change Location")) {
					Text(verbatim: .localized("App Files Not Found"))
						.font(.footnote)
						.foregroundColor(.disabled())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if _isScanning {
				NBSection(.localized("Change Location")) {
					ProgressView()
						.frame(maxWidth: .infinity, alignment: .center)
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
				}
			} else if let report = _report {
				NBSection(.localized("Change Location")) {
					if report.usesCoreLocation {
						Text(verbatim: .localized("App Uses Location"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					} else if report.linkageKnown {
						Text(verbatim: .localized("No Location Usage Found"))
							.font(.footnote)
							.foregroundColor(.disabled())
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					} else {
						Text(verbatim: .localized("App Location Usage Unknown"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
					
					Toggle(.localized("Change Location"), isOn: _enabledBinding)
						.disabled(!_canSpoof(report: report))
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
					
					if options.locationSpoof != nil {
						Text(verbatim: _selectionText)
							.font(.footnote)
							.foregroundStyle(Color(hex: "#FFC778"))
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
					}
				}
				
				if options.locationSpoof != nil {
					NBSection(.localized("Choose a City")) {
						ForEach(LocationSpoofDetector.presets) { preset in
							_presetRow(preset)
						}
					}
					
					NBSection(.localized("Custom Location")) {
						TextField(.localized("Latitude"), text: $_customLatitude)
							.keyboardType(.decimalPad)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						TextField(.localized("Longitude"), text: $_customLongitude)
							.keyboardType(.decimalPad)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						if _customInvalid {
							Text(verbatim: .localized("Invalid Coordinates"))
								.font(.footnote)
								.foregroundStyle(.red)
								.zenithGlassCard(cornerRadius: 12)
								.padding(.vertical, 6)
								.listRowSeparator(.hidden)
						}
						Button {
							_useCustomLocation()
						} label: {
							Text(.localized("Use Custom Location"))
						}
						.buttonStyle(ZenithPressButtonStyle())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
					}
					
					NBSection(.localized("Change Location")) {
						Text(verbatim: .localized("Location Spoof Config Saved"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Text(verbatim: .localized("Enabled When You Sign"))
							.font(.footnote)
							.foregroundStyle(.secondary)
							.zenithGlassCard(cornerRadius: 12)
							.padding(.vertical, 6)
							.listRowSeparator(.hidden)
						Button {
							_isAddingPresenting = true
						} label: {
							Label {
								Text(.localized("Add Location Tweak"))
							} icon: {
								Image(systemName: "plus")
							}
						}
						.buttonStyle(ZenithPressButtonStyle())
						.zenithGlassCard(cornerRadius: 12)
						.padding(.vertical, 6)
						.listRowSeparator(.hidden)
						if !options.injectionFiles.isEmpty {
							ForEach(options.injectionFiles, id: \.absoluteString) { tweak in
								_file(tweak: tweak)
							}
						}
					}
				}
			}
		}
		.starfieldBackground()
		.task { _scan() }
		.sheet(isPresented: $_isAddingPresenting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					guard !urls.isEmpty else { return }
					
					for url in urls {
						FileManager.default.moveAndStore(url, with: "ZenithTweak") { url in
							options.injectionFiles.append(url)
						}
					}
				}
			)
			.ignoresSafeArea()
		}
	}
}

// MARK: - Extension: View
extension ChangeLocationView {
	/// The toggle is offered when the app uses location, or when
	/// usage could not be proven either way. It is disabled only
	/// when the scan proved the app never touches location.
	private func _canSpoof(report: LocationSpoofReport) -> Bool {
		report.usesCoreLocation || !report.linkageKnown
	}
	
	private var _enabledBinding: Binding<Bool> {
		Binding(
			get: { options.locationSpoof != nil },
			set: { isOn in
				if isOn {
					if options.locationSpoof == nil {
						let baghdad = LocationSpoofDetector.presets[0]
						options.locationSpoof = LocationSpoofSelection(
							latitude: baghdad.latitude,
							longitude: baghdad.longitude,
							presetID: baghdad.englishName
						)
					}
				} else {
					options.locationSpoof = nil
				}
			}
		)
	}
	
	private var _selectionText: String {
		guard let selection = options.locationSpoof else { return "" }
		return "\(selection.displayName) — \(selection.coordinateText)"
	}
	
	@ViewBuilder
	private func _presetRow(_ preset: LocationSpoofPreset) -> some View {
		Button {
			options.locationSpoof = LocationSpoofSelection(
				latitude: preset.latitude,
				longitude: preset.longitude,
				presetID: preset.englishName
			)
		} label: {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text(verbatim: preset.localizedName)
						.font(.subheadline)
					Text(verbatim: String(format: "%.4f, %.4f", preset.latitude, preset.longitude))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				if options.locationSpoof?.presetID == preset.englishName {
					Image(systemName: "checkmark")
						.foregroundStyle(Color(hex: "#FFC778"))
				}
			}
		}
		.zenithGlassCard(cornerRadius: 12)
		.padding(.vertical, 6)
		.listRowSeparator(.hidden)
	}
	
	private func _useCustomLocation() {
		guard
			let latitude = Double(_customLatitude),
			let longitude = Double(_customLongitude),
			LocationSpoofDetector.isValid(latitude: latitude, longitude: longitude)
		else {
			_customInvalid = true
			return
		}
		_customInvalid = false
		options.locationSpoof = LocationSpoofSelection(
			latitude: latitude,
			longitude: longitude,
			presetID: nil
		)
	}
	
	@ViewBuilder
	private func _file(tweak: URL) -> some View {
		Label(tweak.lastPathComponent, systemImage: "folder.fill")
			.lineLimit(2)
			.frame(maxWidth: .infinity, alignment: .leading)
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				_fileActions(tweak: tweak)
			}
			.contextMenu {
				_fileActions(tweak: tweak)
			}
			.zenithGlassCard(cornerRadius: 12)
			.padding(.vertical, 6)
			.listRowSeparator(.hidden)
	}
	
	@ViewBuilder
	private func _fileActions(tweak: URL) -> some View {
		Button(role: .destructive) {
			FileManager.default.deleteStored(tweak) { url in
				if let index = options.injectionFiles.firstIndex(where: { $0 == url }) {
					options.injectionFiles.remove(at: index)
				}
			}
		} label: {
			Label {
				Text(.localized("Delete"))
			} icon: {
				Image("icon-delete")
					.resizable()
					.scaledToFit()
					.frame(width: 20, height: 20)
			}
		}
	}
	
	private func _scan() {
		guard let appDirectory = Storage.shared.getAppDirectory(for: app) else {
			_appDirectoryMissing = true
			_isScanning = false
			return
		}
		Task.detached(priority: .userInitiated) {
			let report = LocationSpoofDetector.detect(appDirectory: appDirectory)
			await MainActor.run {
				// Drop a stale choice: a location override only
				// stays when the app actually uses location (or
				// usage could not be proven either way).
				if !report.usesCoreLocation && report.linkageKnown {
					options.locationSpoof = nil
				}
				_report = report
				_isScanning = false
			}
		}
	}
}

// MARK: - ChangeLocationRowLabel

/// The signing-screen row for item 19 (#60): the title with its
/// 1–2 line Iraqi explanation underneath, per Reda's rule. The
/// coordinator uses this as the NavigationLink label.
struct ChangeLocationRowLabel: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(.localized("Change Location"))
				.font(.headline)
			Text(.localized("Change Location Explanation"))
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(2)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
