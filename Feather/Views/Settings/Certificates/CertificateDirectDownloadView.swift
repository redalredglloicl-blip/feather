//
//  CertificateDirectDownloadView.swift
//  Zenith
//
//  Zenith v2.4 — direct certificate download: paste a link to the
//  .p12 file and a link to the .mobileprovision file, and the app
//  downloads both straight in and imports them — no Files picker
//  needed. Reachable from Settings and from the Certificates tab.
//  Links are cleaned by the shared normalizer (leading slashes and
//  whitespace stripped), so a pasted chat link never fails validation.

import SwiftUI
import NimbleViews

struct CertificateDirectDownloadView: View {
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12LinkText = ""
	@State private var _provisionLinkText = ""
	@State private var _password = ""
	@State private var _nickname = ""
	@State private var _isDownloading = false
	@State private var _statusMessage: String? = nil
	@State private var _isError = false
	@State private var _isDone = false
	
	var body: some View {
		ZStack {
			StarfieldBackground()
			NBNavigationView(.localized("تحميل شهادة من رابط"), displayMode: .inline) {
				Form {
					Section {
						TextField(.localized("رابط ملف الشهادة (.p12)"), text: $_p12LinkText)
							.textInputAutocapitalization(.never)
							.keyboardType(.URL)
							.autocorrectionDisabled()
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
						TextField(.localized("رابط ملف التثبيت (.mobileprovision)"), text: $_provisionLinkText)
							.textInputAutocapitalization(.never)
							.keyboardType(.URL)
							.autocorrectionDisabled()
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
					} footer: {
						Text(.localized("الصق رابط مباشر لكل ملف. الروابط تُنظَّف تلقائياً."))
					}
					
					Section {
						SecureField(.localized("كلمة السر (اختياري)"), text: $_password)
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
						TextField(.localized("اسم الشهادة (اختياري)"), text: $_nickname)
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
					}
					
					Section {
						Button {
							_downloadAndImport()
						} label: {
							if _isDownloading {
								ProgressView()
									.frame(maxWidth: .infinity)
							} else {
								HStack(spacing: 8) {
									Image("icon-download")
										.resizable()
										.scaledToFit()
										.frame(width: 20, height: 20)
									Text(.localized("حمّل واستورد"))
								}
								.frame(maxWidth: .infinity)
							}
						}
						.buttonStyle(.borderedProminent)
						.disabled(_isDownloading || _p12LinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || _provisionLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
					
					if let status = _statusMessage {
						Section {
							Text(status)
								.font(.subheadline)
								.foregroundStyle(_isError ? .red : .secondary)
								.multilineTextAlignment(.center)
								.frame(maxWidth: .infinity)
								.zenithGlassCard(cornerRadius: 12)
								.listRowSeparator(.hidden)
						}
					}
					
					if _isDone {
						Section {
							Button(.localized("إغلاق")) {
								dismiss()
							}
							.frame(maxWidth: .infinity)
							.zenithGlassCard(cornerRadius: 12)
							.listRowSeparator(.hidden)
						}
					}
				}
				.scrollContentBackground(.hidden)
				.toolbar {
					NBToolbarButton(role: .cancel)
				}
			}
		}
	}
	
	private func _downloadAndImport() {
		guard
			let p12URL = DownloadManager.normalizedURL(from: _p12LinkText),
			let provisionURL = DownloadManager.normalizedURL(from: _provisionLinkText)
		else {
			_statusMessage = .localized("الرابط مو صحيح")
			_isError = true
			return
		}
		_isDownloading = true
		_isError = false
		_isDone = false
		_statusMessage = .localized("جاي أحمل ملف الشهادة…")
		let password = _password
		let nickname = _nickname
		Task {
			do {
				let p12File = try await _downloadFile(from: p12URL, fileName: "certificate.p12")
				await MainActor.run { _statusMessage = .localized("جاي أحمل ملف التثبيت…") }
				let provisionFile = try await _downloadFile(from: provisionURL, fileName: "certificate.mobileprovision")
				await MainActor.run { _statusMessage = .localized("جاي أتحقق من الشهادة…") }
				// Same check as the file-picker flow, on the main
				// actor exactly like CertificatesAddView does it.
				let passwordOK = await MainActor.run {
					Zenith.checkPasswordForCertificate(for: p12File, with: password, using: provisionFile)
				}
				guard passwordOK else {
					await MainActor.run {
						_isDownloading = false
						_isError = true
						_statusMessage = .localized("كلمة السر غلط أو الملفات مو شهادة صحيحة.")
					}
					return
				}
				let importError: Error? = await withCheckedContinuation { continuation in
					Zenith.handleCertificateFiles(
						p12URL: p12File,
						provisionURL: provisionFile,
						p12Password: password,
						certificateName: nickname
					) { error in
						continuation.resume(returning: error)
					}
				}
				await MainActor.run {
					_isDownloading = false
					if let importError {
						_isError = true
						_statusMessage = importError.localizedDescription
					} else {
						_isDone = true
						_isError = false
						_statusMessage = .localized("تم الاستيراد بنجاح.")
					}
				}
			} catch {
				await MainActor.run {
					_isDownloading = false
					_isError = true
					_statusMessage = .localized("فشل التحميل") + ": " + error.localizedDescription
				}
			}
		}
	}
	
	/// Downloads one file with a browser user agent (some hosts refuse
	/// the default agent) into a temp file with the right extension.
	private func _downloadFile(from url: URL, fileName: String) async throws -> URL {
		var request = URLRequest(url: url)
		request.timeoutInterval = 60
		request.setValue(DownloadManager.browserUserAgent, forHTTPHeaderField: "User-Agent")
		let (tempURL, response) = try await URLSession.shared.download(for: request)
		guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
			throw URLError(.badServerResponse)
		}
		let destination = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
		try? FileManager.default.removeItem(at: destination)
		try FileManager.default.moveItem(at: tempURL, to: destination)
		return destination
	}
}
