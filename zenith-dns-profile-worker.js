/**
 * Zenith Anti-Revoke DNS profile — Cloudflare Worker.
 *
 * Serves the bundled `Feather/Resources/ZenithAntiRevoke.mobileconfig`
 * with Content-Type: application/x-apple-aspen-config, so Safari on the
 * iPhone treats the download as a configuration profile and offers the
 * install prompt (Settings -> Profile Downloaded). Without that exact
 * MIME type Safari just shows the file as text.
 *
 * The profile bytes are embedded below (PROFILE) as an exact copy of the
 * bundled .mobileconfig. If the profile in the app ever changes, update
 * the embedded copy here too — or replace the handler with a fetch of
 * the raw file from this repo.
 *
 * DEPLOY (one click, no dashboard setup):
 *   https://deploy.workers.cloudflare.com/?url=https://github.com/<user>/<repo>
 * Replace <user>/<repo> with the repo that holds this file, open the
 * link, and Cloudflare copies the repo and deploys this worker. If it
 * asks for an entrypoint, point it at this file:
 *   zenith-dns-profile-worker.js
 *
 * AFTER DEPLOYING:
 * Copy the worker's public URL (https://<worker-name>.<subdomain>.workers.dev)
 * and paste it into `Feather/Views/Settings/Certificates/CertificatesView.swift`
 * as `_dnsProfileHostedURL` — the in-app "Install from Safari" button
 * opens that URL. Until then the button points at a placeholder URL.
 *
 * This file is inert for the Xcode build: it lives at the repo source
 * root, outside the Feather/ folder the app target syncs, so the build
 * ignores it.
 */

const PROFILE = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>\n\t\t\t<key>DNSSettings</key>\n\t\t\t<dict>\n\t\t\t\t<key>DNSProtocol</key>\n\t\t\t\t<string>Cleartext</string>\n\t\t\t\t<key>ProhibitDisablement</key>\n\t\t\t\t<false/>\n\t\t\t\t<key>ServerAddresses</key>\n\t\t\t\t<array>\n\t\t\t\t\t<string>127.0.0.1</string>\n\t\t\t\t\t<string>::1</string>\n\t\t\t\t</array>\n\t\t\t\t<key>SupplementalMatchDomains</key>\n\t\t\t\t<array>\n\t\t\t\t\t<string>ocsp.apple.com</string>\n\t\t\t\t\t<string>*.ocsp.apple.com</string>\n\t\t\t\t\t<string>ocsp2.apple.com</string>\n\t\t\t\t\t<string>*.ocsp2.apple.com</string>\n\t\t\t\t\t<string>ocsp3.apple.com</string>\n\t\t\t\t\t<string>*.ocsp3.apple.com</string>\n\t\t\t\t\t<string>ocsp4.apple.com</string>\n\t\t\t\t\t<string>*.ocsp4.apple.com</string>\n\t\t\t\t\t<string>certs.apple.com</string>\n\t\t\t\t\t<string>*.certs.apple.com</string>\n\t\t\t\t\t<string>crl.apple.com</string>\n\t\t\t\t\t<string>*.crl.apple.com</string>\n\t\t\t\t\t<string>valid.apple.com</string>\n\t\t\t\t\t<string>*.valid.apple.com</string>\n\t\t\t\t\t<string>appattest.apple.com</string>\n\t\t\t\t\t<string>*.appattest.apple.com</string>\n\t\t\t\t</array>\n\t\t\t\t<key>SupplementalMatchDomainsNoSearch</key>\n\t\t\t\t<true/>\n\t\t\t</dict>\n\t\t\t<key>PayloadDescription</key>\n\t\t\t<string>Routes Apple's certificate validation hosts (OCSP) to a dead-end resolver, so the device cannot check whether a signing certificate was revoked.</string>\n\t\t\t<key>PayloadDisplayName</key>\n\t\t\t<string>Zenith Anti-Revoke DNS</string>\n\t\t\t<key>PayloadIdentifier</key>\n\t\t\t<string>com.zenith.dnsprotection.dns</string>\n\t\t\t<key>PayloadType</key>\n\t\t\t<string>com.apple.dnsSettings.managed</string>\n\t\t\t<key>PayloadUUID</key>\n\t\t\t<string>83551bfa-5410-4dd2-b18b-e30377a8afe1</string>\n\t\t\t<key>PayloadVersion</key>\n\t\t\t<integer>1</integer>\n\t\t</dict>\n\t</array>\n\t<key>PayloadDescription</key>\n\t<string>Zenith anti-revoke protection: blocks Apple's certificate revocation checks so signed apps keep opening even if the certificate is revoked. Only the listed Apple validation hosts are affected; all other DNS stays on the system resolver. Protects against future revocations only \u2014 it cannot revive a certificate that was already revoked before installation.</string>\n\t<key>PayloadDisplayName</key>\n\t<string>Zenith Anti-Revoke Protection</string>\n\t<key>PayloadIdentifier</key>\n\t<string>com.zenith.dnsprotection</string>\n\t<key>PayloadOrganization</key>\n\t<string>Zenith</string>\n\t<key>PayloadRemovalDisallowed</key>\n\t<false/>\n\t<key>PayloadScope</key>\n\t<string>System</string>\n\t<key>PayloadType</key>\n\t<string>Configuration</string>\n\t<key>PayloadUUID</key>\n\t<string>dd05e3a2-6673-498f-9a37-19907d81eeab</string>\n\t<key>PayloadVersion</key>\n\t<integer>1</integer>\n</dict>\n</plist>\n";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    // Serve the profile at the root and at its file name; anything
    // else is a 404 so the worker URL cannot be mistaken for a site.
    if (url.pathname !== "/" && url.pathname !== "/ZenithAntiRevoke.mobileconfig") {
      return new Response("Not Found", { status: 404 });
    }

    return new Response(PROFILE, {
      headers: {
        // The exact MIME type iOS needs to offer profile installation.
        "Content-Type": "application/x-apple-aspen-config",
        // Inline (not attachment) so Safari handles it as a profile
        // instead of saving it to Files.
        "Content-Disposition": 'inline; filename="ZenithAntiRevoke.mobileconfig"',
        "Cache-Control": "public, max-age=3600",
      },
    });
  },
};
