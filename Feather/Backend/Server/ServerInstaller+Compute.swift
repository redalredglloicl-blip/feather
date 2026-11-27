//
//  Server+Compute.swift
//  zenith
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR ZENITH
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	var plistEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/\(id).plist"
		comps.port = port
		return comps.url!
	}

	var payloadEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/\(id).ipa"
		comps.port = port
		return comps.url!
	}
	
	var pageEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/install"
		comps.port = port
		return comps.url!
	}
	
	var externalServerLink: String {
		let baseUrl = "https://api.palera.in/genPlist?bundleid=\(app.identifier!)&name=\(app.name!)&version=\(app.version!)&fetchurl=\(self.payloadEndpoint.absoluteString)"
		let encodedBaseUrl = baseUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
		let finalEncodedUrl = encodedBaseUrl.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
		
		return finalEncodedUrl
	}

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}
	
	private func _iTunesLink(with url: String) -> String {
		return "itms-services://?action=download-manifest&url=\(url)"
	}

	var displayImageSmallEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = sni()
		comps.path = "/app57x57.png"
		comps.port = port
		return comps.url!
	}

	var displayImageLargeEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = sni()
		comps.path = "/app512x512.png"
		comps.port = port
		return comps.url!
	}
	
	var displayImageSmallData: Data {
		_displayIconData(size: 57)
	}
	
	var displayImageLargeData: Data {
		_displayIconData(size: 512)
	}
	
	// Zenith v2.20: the real app icon for the local (mode 0)
	// manifest's display images, scaled to the requested size.
	// The old _createIcon drew a solid tint-color square, so the
	// home screen showed a blank square while the app downloaded.
	// The icon comes from the signed .app on disk, using the same
	// CFBundleIcons lookup the Library uses; the tint square is
	// only the fallback when the bundle has no loose icon file
	// (e.g. icons only inside Assets.car). Mode 1 (palera.in)
	// cannot carry a display image: its genPlist endpoint ignores
	// icon parameters (verified live 2026-11-28), so in mode 1 the
	// placeholder only goes away by the download actually
	// finishing — which the InstallPreviewView keep-alive fixes
	// in this same version.
	private func _displayIconData(size r: CGFloat) -> Data {
		if let icon = _realAppIcon() {
			let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
			let scaled = renderer.image { _ in
				icon.draw(in: .init(x: 0, y: 0, width: r, height: r))
			}
			if let data = scaled.pngData() {
				return data
			}
		}
		return _createIcon(r)
	}
	
	private func _realAppIcon() -> UIImage? {
		guard
			let appURL = Storage.shared.getAppDirectory(for: app),
			let bundle = Bundle(url: appURL),
			let name = bundle.iconFileName
		else { return nil }
		for suffix in ["@3x.png", "@2x.png", ".png"] {
			let url = appURL.appendingPathComponent(name + suffix)
			if let image = UIImage(contentsOfFile: url.path) {
				return image
			}
		}
		return nil
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData()!
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLinkExternal)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": displayImageSmallEndpoint.absoluteString,
				],
				[
					"kind": "full-size-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": app.identifier,
				"bundle-version": app.version,
				"kind": "software",
				"title": app.name,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
