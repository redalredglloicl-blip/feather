//
//  MiniBrowserView.swift
//  Zenith
//
//  Zenith v2.3 — small in-app browser for IPA downloads.
//
//  Reda's v2.2 report: pasting an IPA link downloads nothing —
//  most links are landing pages, share pages or buttons, not the
//  file itself, so a blind URLSession download just fetches HTML.
//  This browser opens the pasted link like Documents does: the user
//  taps the real download button on the page, WebKit intercepts the
//  file download, hands the finished file to DownloadManager, and
//  the sheet closes itself. A pasted DIRECT link works the same way
//  — the page itself is the file, so the navigation response is the
//  download and it is intercepted without any tap.

import SwiftUI
import UIKit
import WebKit
import NimbleViews

struct MiniBrowserView: UIViewControllerRepresentable {
	let url: URL
	
	/// Called on the main actor with the finished file (a temp URL)
	/// the moment WebKit's download completes. The parent dismisses
	/// this sheet and hands the file to DownloadManager.
	var onFileCaptured: (URL) -> Void
	
	/// Called when the user taps the close button.
	var onClose: () -> Void
	
	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}
	
	func makeUIViewController(context: Context) -> MiniBrowserViewController {
		let controller = MiniBrowserViewController()
		controller.configure(
			coordinator: context.coordinator,
			startURL: url,
			onClose: onClose
		)
		return controller
	}
	
	func updateUIViewController(_ uiViewController: MiniBrowserViewController, context: Context) {
		// Only ever load the start URL into a fresh web view. Never
		// reload here: by the time this runs the user may have
		// navigated deep into the host's pages.
		uiViewController.loadIfNeeded(url: url)
	}
	
	// MARK: - Coordinator
	
	/// Navigation + download delegate. Owns the download handoff:
	/// decidePolicyFor spots a file response, WKDownloadDelegate
	/// receives the finished file, and onFileCaptured fires once.
	final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
		let parent: MiniBrowserView
		
		weak var controller: MiniBrowserViewController?
		
		private var progressObservation: NSKeyValueObservation?
		private var activeDownload: WKDownload?
		private var capturedDestinationURL: URL?
		private var didCapture = false
		
		init(parent: MiniBrowserView) {
			self.parent = parent
		}
		
		deinit {
			progressObservation?.invalidate()
		}
		
		func attach(webView: WKWebView) {
			progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
				Task { @MainActor in
					self?.controller?.setProgress(webView.estimatedProgress)
				}
			}
		}
		
		func close() {
			parent.onClose()
		}
		
		// MARK: WKNavigationDelegate — navigation
		
		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
			// Links that open a new tab (target="_blank", window.open):
			// there is no second tab here, so load them in this view.
			if navigationAction.targetFrame == nil,
			   let url = navigationAction.request.url {
				webView.load(URLRequest(url: url))
				decisionHandler(.cancel)
				return
			}
			decisionHandler(.allow)
		}
		
		func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
			if _isDownloadResponse(navigationResponse.response, navigationResponse: navigationResponse) {
				// The page IS the file (direct link), or the tapped
				// button navigated to the file: capture it as a
				// download instead of showing it in the page.
				decisionHandler(.download)
			} else {
				decisionHandler(.allow)
			}
		}
		
		func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			Task { @MainActor in
				self.controller?.hideError()
				self.controller?.setProgress(0)
			}
		}
		
		func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
			Task { @MainActor in
				self.controller?.setAddress(webView.url)
				self.controller?.hideError()
			}
		}
		
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			Task { @MainActor in
				self.controller?.setAddress(webView.url)
				self.controller?.setProgress(1)
			}
		}
		
		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			if (error as NSError).code == NSURLErrorCancelled { return }
			Task { @MainActor in
				self.controller?.setProgress(1)
				self.controller?.showError(error.localizedDescription)
			}
		}
		
		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			if (error as NSError).code == NSURLErrorCancelled { return }
			Task { @MainActor in
				self.controller?.showError(error.localizedDescription)
			}
		}
		
		// MARK: WKDownloadDelegate — the intercepted file
		
		func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
			// WebKit hands the download over here; keep it alive and
			// take its delegate so the finish/failure callbacks land.
			activeDownload = download
			download.delegate = self
			didCapture = false
			capturedDestinationURL = nil
		}
		
		func webView(_ webView: WKWebView, download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
			let rawName = suggestedFilename.isEmpty
				? (response.url?.lastPathComponent ?? "")
				: suggestedFilename
			// A suggested name must never smuggle a path in.
			let fileName = URL(fileURLWithPath: rawName).lastPathComponent
			let safeName = fileName.isEmpty ? "download.ipa" : fileName
			let directory = FileManager.default.temporaryDirectory
				.appendingPathComponent("ZenithBrowserDownloads", isDirectory: true)
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			let destination = directory.appendingPathComponent(safeName)
			try? FileManager.default.removeItem(at: destination)
			capturedDestinationURL = destination
			completionHandler(destination)
		}
		
		func webView(_ webView: WKWebView, downloadDidFinish download: WKDownload) {
			guard let destination = capturedDestinationURL, !didCapture else { return }
			didCapture = true
			activeDownload = nil
			// The file is fully written at the destination now.
			// Hand it over once; the parent closes this sheet and
			// starts the DownloadManager install flow from it.
			Task { @MainActor in
				self.parent.onFileCaptured(destination)
			}
		}
		
		func webView(_ webView: WKWebView, download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
			activeDownload = nil
			// Stay in the browser so the user can tap the button
			// again — just say what went wrong.
			Task { @MainActor in
				self.controller?.showError(.localized("Download Failed") + ": " + error.localizedDescription)
			}
		}
		
		// MARK: WKUIDelegate — popups stay in this view
		
		func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
			if let url = navigationAction.request.url {
				webView.load(URLRequest(url: url))
			}
			return nil
		}
		
		// MARK: Is this response a file?
		
		/// Decides whether a navigation response is a downloadable
		/// file rather than a page to display.
		private func _isDownloadResponse(_ response: URLResponse, navigationResponse: WKNavigationResponse) -> Bool {
			if let http = response as? HTTPURLResponse {
				// An error page is not a file, even if its URL ends
				// in .ipa — show it so the user sees what happened.
				guard (200...299).contains(http.statusCode) else { return false }
				// Sent as an attachment: always a file.
				if let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
				   disposition.contains("attachment") {
					return true
				}
			}
			// The server names an .ipa file.
			if let name = response.suggestedFilename,
			   name.lowercased().hasSuffix(".ipa") {
				return true
			}
			// A web page is never a download, even when its URL ends
			// in .ipa (some hosts serve a landing page there).
			if let mime = response.mimeType?.lowercased(), mime.hasPrefix("text/") {
				return false
			}
			// The URL itself points at a file.
			if let url = response.url, url.pathExtension.lowercased() == "ipa" {
				return true
			}
			// Anything the web view cannot display is a file.
			return !navigationResponse.canShowMIMEType
		}
	}
}

// MARK: - View controller (toolbar + progress + web view)

/// The sheet's contents: a small toolbar (back, forward, address,
/// reload, close), a loading progress bar, an error line, the web
/// view, and a one-line hint telling the user to tap the page's
/// download button.
final class MiniBrowserViewController: UIViewController {
	private var coordinator: MiniBrowserView.Coordinator?
	private var startURL: URL?
	private var onClose: (() -> Void)?
	
	private var webView: WKWebView!
	private var addressLabel: UILabel!
	private var progressView: UIProgressView!
	private var errorLabel: UILabel!
	private var errorHeightConstraint: NSLayoutConstraint!
	private var backButton: UIButton!
	private var forwardButton: UIButton!
	private weak var _toolbar: UIView?
	
	func configure(coordinator: MiniBrowserView.Coordinator, startURL: URL, onClose: @escaping () -> Void) {
		self.coordinator = coordinator
		self.startURL = startURL
		self.onClose = onClose
		coordinator.controller = self
	}
	
	func loadIfNeeded(url: URL) {
		guard let webView, webView.url == nil else { return }
		webView.load(URLRequest(url: url))
	}
	
	func setAddress(_ url: URL?) {
		addressLabel?.text = url?.absoluteString ?? ""
		backButton?.isEnabled = webView?.canGoBack ?? false
		forwardButton?.isEnabled = webView?.canGoForward ?? false
	}
	
	func setProgress(_ progress: Double) {
		progressView?.progress = Float(progress)
		progressView?.isHidden = progress >= 1
	}
	
	func showError(_ message: String) {
		errorLabel?.text = message
		errorLabel?.isHidden = false
		errorHeightConstraint?.isActive = false
	}
	
	func hideError() {
		errorLabel?.isHidden = true
		errorHeightConstraint?.isActive = true
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground
		_buildToolbar()
		_buildWebView()
		_buildHint()
		if let startURL {
			webView.load(URLRequest(url: startURL))
		}
	}
	
	private func _buildToolbar() {
		let bar = UIView()
		bar.backgroundColor = .secondarySystemBackground
		bar.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(bar)
		
		backButton = _toolButton(systemName: "chevron.backward")
		backButton.addTarget(self, action: #selector(_goBack), for: .touchUpInside)
		backButton.isEnabled = false
		
		forwardButton = _toolButton(systemName: "chevron.forward")
		forwardButton.addTarget(self, action: #selector(_goForward), for: .touchUpInside)
		forwardButton.isEnabled = false
		
		let reloadButton = _toolButton(systemName: "arrow.clockwise")
		reloadButton.addTarget(self, action: #selector(_reload), for: .touchUpInside)
		
		let closeButton = _toolButton(systemName: "xmark")
		closeButton.addTarget(self, action: #selector(_close), for: .touchUpInside)
		
		let addressContainer = UIView()
		addressContainer.backgroundColor = .tertiarySystemFill
		addressContainer.layer.cornerRadius = 8
		addressContainer.translatesAutoresizingMaskIntoConstraints = false
		
		addressLabel = UILabel()
		addressLabel.font = .preferredFont(forTextStyle: .subheadline)
		addressLabel.textColor = .secondaryLabel
		addressLabel.textAlignment = .center
		addressLabel.lineBreakMode = .byTruncatingMiddle
		addressLabel.translatesAutoresizingMaskIntoConstraints = false
		addressContainer.addSubview(addressLabel)
		
		let row = UIStackView(arrangedSubviews: [backButton, forwardButton, addressContainer, reloadButton, closeButton])
		row.axis = .horizontal
		row.spacing = 8
		row.alignment = .center
		row.translatesAutoresizingMaskIntoConstraints = false
		bar.addSubview(row)
		
		progressView = UIProgressView(progressViewStyle: .bar)
		progressView.progressTintColor = UIColor(red: 1.0, green: 0.78, blue: 0.47, alpha: 1)
		progressView.translatesAutoresizingMaskIntoConstraints = false
		bar.addSubview(progressView)
		
		errorLabel = UILabel()
		errorLabel.font = .preferredFont(forTextStyle: .caption)
		errorLabel.textColor = .systemRed
		errorLabel.numberOfLines = 2
		errorLabel.isHidden = true
		errorLabel.translatesAutoresizingMaskIntoConstraints = false
		bar.addSubview(errorLabel)
		
		// Collapsed until an error is shown, so the bar stays compact.
		errorHeightConstraint = errorLabel.heightAnchor.constraint(equalToConstant: 0)
		errorHeightConstraint.isActive = true
		
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			
			row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
			row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
			row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
			row.heightAnchor.constraint(equalToConstant: 32),
			
			addressLabel.topAnchor.constraint(equalTo: addressContainer.topAnchor, constant: 4),
			addressLabel.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: -4),
			addressLabel.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 8),
			addressLabel.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
			
			progressView.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
			progressView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
			progressView.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
			
			errorLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 6),
			errorLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
			errorLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
			errorLabel.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
		])
		
		_toolbar = bar
	}
	
	private func _buildWebView() {
		let configuration = WKWebViewConfiguration()
		// The default data store: cookies and logins persist between
		// opens, so hosts that need a login keep working. A real
		// Safari-like agent is what makes hosts serve the file.
		configuration.websiteDataStore = .default()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = true
		configuration.allowsInlineMediaPlayback = true
		
		let webView = WKWebView(frame: .zero, configuration: configuration)
		webView.navigationDelegate = coordinator
		webView.uiDelegate = coordinator
		webView.allowsBackForwardNavigationGestures = true
		webView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(webView)
		self.webView = webView
		coordinator?.attach(webView: webView)
		
		guard let bar = _toolbar else { return }
		NSLayoutConstraint.activate([
			webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
			webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
	}
	
	private func _buildHint() {
		// A one-line hint floating over the bottom of the page, so
		// the user knows to tap the page's own download button.
		let hint = UILabel()
		hint.text = .localized("Tap the download button on the page and the file will download automatically.")
		hint.font = .preferredFont(forTextStyle: .caption)
		hint.textColor = .secondaryLabel
		hint.textAlignment = .center
		hint.numberOfLines = 2
		hint.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.92)
		hint.layer.cornerRadius = 8
		hint.layer.masksToBounds = true
		hint.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(hint)
		
		NSLayoutConstraint.activate([
			hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
			hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
			hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
		])
	}
	
	private func _toolButton(systemName: String) -> UIButton {
		let button = UIButton(type: .system)
		button.setImage(UIImage(systemName: systemName), for: .normal)
		button.tintColor = .label
		button.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			button.widthAnchor.constraint(equalToConstant: 32),
			button.heightAnchor.constraint(equalToConstant: 32),
		])
		return button
	}
	
	@objc private func _goBack() {
		webView?.goBack()
	}
	
	@objc private func _goForward() {
		webView?.goForward()
	}
	
	@objc private func _reload() {
		webView?.reload()
	}
	
	@objc private func _close() {
		coordinator?.close() ?? onClose?()
	}
}
