//
//  ContentView.swift
//  Zenith
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _selectedPassportAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _isSigningQueuePresenting = false
	@State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
	
	// MARK: Selection State
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive
	
	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all
	@State private var _selectedCategory: HomeCategory = .all
	
	@ObservedObject private var _prefs = LibraryPrefs.shared
	
	@State private var _didAppear = false
	@State private var _appPendingDelete: AnyApp?
	@State private var _isDeleteConfirmPresenting = false
	@State private var _isBulkDeleteConfirmPresenting = false
	
	
	@Namespace private var _namespace

	/// 2-column grid for the Library (mockup layout).
	private static let _gridColumns = [
		GridItem(.flexible(), spacing: 12),
		GridItem(.flexible(), spacing: 12)
	]
	
	// MARK: Filtering & Sorting
	private func _matchingApps<T>(from apps: FetchedResults<T>) -> [AppInfoPresentable] where T: NSManagedObject {
		apps.compactMap { $0 as? AppInfoPresentable }.filter { app in
			if !_searchText.isEmpty {
				guard (app.name ?? "").localizedCaseInsensitiveContains(_searchText) else { return false }
			}
			if _selectedCategory != .all {
				guard _prefs.category(for: app.uuid) == _selectedCategory else { return false }
			}
			if !_prefs.showExpired, _prefs.isExpired(app: app) {
				return false
			}
			return true
		}
	}
	
	private var _signedAppsMatching: [AppInfoPresentable] {
		_matchingApps(from: _signedApps)
	}
	
	private var _importedAppsMatching: [AppInfoPresentable] {
		_matchingApps(from: _importedApps)
	}
	
	private func _inScope(_ app: AppInfoPresentable) -> Bool {
		switch _selectedScope {
		case .all: return true
		case .signed: return app.isSigned
		case .imported: return !app.isSigned
		}
	}
	
	private func _alphabetical(_ lhs: AppInfoPresentable, _ rhs: AppInfoPresentable) -> Bool {
		(lhs.name ?? "").localizedStandardCompare(rhs.name ?? "") == .orderedAscending
	}
	
	private var _favoriteApps: [AppInfoPresentable] {
		(_signedAppsMatching + _importedAppsMatching)
			.filter { _inScope($0) && _prefs.isFavorite(uuid: $0.uuid) }
			.sorted(by: _alphabetical)
	}
	
	private var _regularSignedApps: [AppInfoPresentable] {
		_signedAppsMatching
			.filter { !_prefs.isFavorite(uuid: $0.uuid) }
			.sorted(by: _alphabetical)
	}
	
	private var _regularImportedApps: [AppInfoPresentable] {
		_importedAppsMatching
			.filter { !_prefs.isFavorite(uuid: $0.uuid) }
			.sorted(by: _alphabetical)
	}
	
	private var _hiddenExpiredCount: Int {
		let all: [AppInfoPresentable] = _signedApps.compactMap { $0 as? AppInfoPresentable }
			+ _importedApps.compactMap { $0 as? AppInfoPresentable }
		return all.filter { app in
			if !_searchText.isEmpty {
				guard (app.name ?? "").localizedCaseInsensitiveContains(_searchText) else { return false }
			}
			if _selectedCategory != .all {
				guard _prefs.category(for: app.uuid) == _selectedCategory else { return false }
			}
			return _prefs.isExpired(app: app)
		}.count
	}
	
	private var _unusedApps: [AppInfoPresentable] {
		(_signedAppsMatching + _importedAppsMatching)
			.filter { _inScope($0) && _isUnused($0) }
			.sorted(by: _alphabetical)
	}
	
	private func _isUnused(_ app: AppInfoPresentable) -> Bool {
		let reference = _prefs.lastOpenedDate(for: app.uuid) ?? app.date
		guard let reference else { return false }
		return Date().timeIntervalSince(reference) > LibraryPrefs.unusedThreshold
	}
	
	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Home"), displayMode: .inline) {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					_zenithHeader
					
					_categoryChips
					
					if !_unusedApps.isEmpty {
						_gridSection(
							title: .localized("Not opened in a while"),
							apps: _unusedApps
						)
					}
					
					if !_favoriteApps.isEmpty {
						_gridSection(
							title: .localized("Favorites"),
							count: _favoriteApps.count,
							systemName: "heart.fill",
							apps: _favoriteApps
						)
					}
					
					if
						!_regularSignedApps.isEmpty,
						_selectedScope == .all || _selectedScope == .signed
					{
						_gridSection(
							title: .localized("Signed"),
							count: _regularSignedApps.count,
							apps: _regularSignedApps
						)
					}
					
					if
						!_regularImportedApps.isEmpty,
						_selectedScope == .all || _selectedScope == .imported
					{
						_gridSection(
							title: .localized("Imported"),
							count: _regularImportedApps.count,
							apps: _regularImportedApps
						)
					}
					
					if _hiddenExpiredCount > 0, !_prefs.showExpired {
						Button {
							_prefs.showExpired = true
						} label: {
							HStack {
								Text(verbatim: .localized("%lld expired apps hidden", arguments: _hiddenExpiredCount))
								Spacer()
								Text(.localized("Show"))
									.foregroundStyle(Color.accentColor)
							}
							.padding()
						}
						.zenithGlassCard(cornerRadius: 16, fallback: Color.white.opacity(0.08))
						.padding(.horizontal)
					}
				}
				.padding(.bottom, 16)
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if
					_favoriteApps.isEmpty,
					_regularSignedApps.isEmpty,
					_regularImportedApps.isEmpty
				{
					_emptyState
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}
				
				if _editMode.isEditing {
					NBToolbarButton(
						.localized("Delete"),
						image: "icon-delete",
						isDisabled: _selectedAppUUIDs.isEmpty
					) {
						_isBulkDeleteConfirmPresenting = true
					}
				} else {
					NBToolbarMenu(
						image: "icon-sort",
						style: .icon,
						placement: .topBarTrailing
					) {
						Toggle(.localized("Show Expired Apps"), isOn: $_prefs.showExpired)
					}
					NBToolbarMenu(
						systemImage: "plus",
						style: .icon,
						placement: .topBarTrailing
					) {
						_importActions()
					}
					NBToolbarButton(
						.localized("Batch Sign"),
						image: "icon-sign",
						placement: .topBarTrailing
					) {
						_isSigningQueuePresenting = true
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
					.zenithSheetBackground()
			}
			.sheet(item: $_selectedPassportAppPresenting) { app in
				AppPassportView(app: app.base)
					.zenithSheetBackground()
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
					.zenithSheetBackground()
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						
						for url in urls {
							let id = "ZenithManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							try? downloadManager.handlePachageFile(url: url, dl: dl)
						}
					}
				)
				.ignoresSafeArea()
				.zenithSheetBackground()
			}
			.sheet(isPresented: $_isSigningQueuePresenting) {
				SigningQueueView()
					.zenithSheetBackground()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "ZenithManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.alert(.localized("متأكد تمسح التطبيق؟"), isPresented: $_isDeleteConfirmPresenting) {
				Button(.localized("Delete"), role: .destructive) {
					if let app = _appPendingDelete {
						Storage.shared.deleteApp(for: app.base)
					}
					_appPendingDelete = nil
				}
				Button(.localized("Cancel"), role: .cancel) {
					_appPendingDelete = nil
				}
			}
			.alert(.localized("متأكد تمسح التطبيق؟"), isPresented: $_isBulkDeleteConfirmPresenting) {
				Button(.localized("Delete"), role: .destructive) {
					_bulkDeleteSelectedApps()
				}
				Button(.localized("Cancel"), role: .cancel) { }
			}
			.onAppear {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					_didAppear = true
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Zenith.installApp"))) { _ in
				if let latest = _signedApps.first {
					_selectedInstallAppPresenting = AnyApp(base: latest)
				}
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
		}
		.starfieldBackground()
	}
}

// MARK: - Extension: View
extension LibraryView {
	@ViewBuilder
	private func _importActions() -> some View {
		Button {
			_isImportingPresenting = true
		} label: {
			Label(.localized("Import from Files"), image: "icon-import")
		}
		Button {
			_isDownloadingPresenting = true
		} label: {
			Label(.localized("Import from URL"), image: "icon-import")
		}
	}
	
	/// Zenith Home category chips. Selecting a chip filters the list by the
	/// category the user assigned to each app (uncategorized apps show under All).
	private var _categoryChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(HomeCategory.allCases, id: \.self) { category in
					Button {
						_selectedCategory = category
					} label: {
						Text(category.displayName)
							.font(.subheadline)
							.fontWeight(_selectedCategory == category ? .bold : .regular)
							.padding(.horizontal, 14)
							.padding(.vertical, 7)
							.background(
								_selectedCategory == category
									? Color(red: 1.0, green: 199.0 / 255.0, blue: 120.0 / 255.0)
									: Color(uiColor: .quaternarySystemFill)
							)
							.foregroundStyle(_selectedCategory == category ? .black : .primary)
							.clipShape(Capsule())
					}
					.buttonStyle(ZenithPressButtonStyle())
				}
			}
			.padding(.horizontal)
		}
		.padding(.vertical, 8)
	}
	
	/// Mockup header: big peach "Zenith" over the library subtitle.
	/// The navigation bar is inline, so this is the only large title.
	private var _zenithHeader: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(verbatim: "Zenith")
				.font(.system(size: 44, weight: .bold, design: .rounded))
				.foregroundStyle(Color.accentColor)
			Text(.localized("App Library"))
				.font(.title3)
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal)
		.padding(.top, 8)
	}
	
	/// One Library section as a 2-column grid of large glass cards.
	/// Same apps, same order and same counts as the old list sections.
	private func _gridSection(
		title: String,
		count: Int? = nil,
		systemName: String? = nil,
		apps: [AppInfoPresentable]
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 4) {
				if let systemName {
					Image(systemName: systemName)
						.font(.system(size: 12))
						.offset(y: -2)
				}
				Text(verbatim: title)
					.font(.title2)
					.fontWeight(.bold)
				if let count {
					Text(verbatim: count.description)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
			.padding(.horizontal)
			
			LazyVGrid(columns: Self._gridColumns, spacing: 12) {
				ForEach(Array(apps.enumerated()), id: \.element.uuid) { index, app in
					_libraryCell(for: app, index: index)
				}
			}
			.padding(.horizontal)
		}
	}
	
	/// Designed empty state: transparent so the starfield shows
	/// through, the library illustration, the existing Iraqi copy
	/// and the import button.
	private var _emptyState: some View {
		VStack(spacing: 16) {
			Image("icon-library")
				.resizable()
				.scaledToFit()
				.frame(width: 96, height: 96)
				.shadow(color: Color.accentColor.opacity(0.5), radius: 24)
			Text(.localized("No Apps"))
				.font(.title2)
				.fontWeight(.bold)
			Text(.localized("Get started by importing your first IPA file."))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 32)
			Menu {
				_importActions()
			} label: {
				NBButton(.localized("Import"), style: .text)
			}
		}
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color.clear)
	}
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}
		
		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}
		
		_selectedAppUUIDs.removeAll()
		
		// _editMode = .inactive
	}
	
	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		
		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _favoriteApps.filter { $0.isSigned })
			allApps.append(contentsOf: _regularSignedApps)
		}
		
		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _favoriteApps.filter { !$0.isSigned })
			allApps.append(contentsOf: _regularImportedApps)
		}
		
		return allApps
	}
}

// MARK: - Extension: View (Phase 3)
extension LibraryView {
	@ViewBuilder
	private func _libraryCell(for app: AppInfoPresentable, index: Int) -> some View {
		LibraryCellView(
			app: app,
			selectedInfoAppPresenting: $_selectedInfoAppPresenting,
			selectedSigningAppPresenting: $_selectedSigningAppPresenting,
			selectedInstallAppPresenting: $_selectedInstallAppPresenting,
			selectedPassportAppPresenting: $_selectedPassportAppPresenting,
			selectedAppUUIDs: $_selectedAppUUIDs,
			onDeleteRequest: { app in
				_appPendingDelete = AnyApp(base: app)
				_isDeleteConfirmPresenting = true
			}
		)
		.transition(.opacity.combined(with: .scale(scale: 0.97)))
		.opacity(_didAppear ? 1 : 0)
		.animation(.easeOut(duration: 0.25).delay(Double(index) * 0.05), value: _didAppear)
		.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
	}
	
}

// MARK: - Extension: View (Sort)
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported
		
		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Imported")
			}
		}
	}
	
	/// Zenith Home categories. Chips filter the list; each app's own category
	/// is picked by the user in the cell context menu (stored locally).
	enum HomeCategory: String, CaseIterable {
		case all
		case games
		case social
		case tools
		
		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .games: return .localized("Games")
			case .social: return .localized("Social")
			case .tools: return .localized("Tools")
			}
		}
		
		/// Display name inside the per-app category picker ("All" reads as no category there).
		var pickerDisplayName: String {
			switch self {
			case .all: return .localized("No Category")
			default: return displayName
			}
		}
	}
}
