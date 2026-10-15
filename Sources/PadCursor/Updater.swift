import AppKit
import Foundation
import Security

/// Checks GitHub (baygut/padcursor) for a newer release, and installs it: downloads the zip,
/// verifies it is signed by the same developer team, swaps the app in place and relaunches.
final class Updater: ObservableObject {
    static let shared = Updater()

    private let repo = "baygut/padcursor"
    private let teamID = "69W6BBGGPT"
    private let lastCheckKey = "updates.lastCheck"

    @Published var available: Release?
    @Published var busy = false

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Quietly checks at most once a day; only a found update is shown.
    func checkInBackground() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                guard let data, let rel = try? JSONDecoder().decode(Release.self, from: data) else {
                    if userInitiated { self.alert("Could not check for updates", error?.localizedDescription ?? "GitHub did not answer.") }
                    return
                }
                if Self.isNewer(rel.version, than: self.currentVersion) {
                    self.available = rel
                    self.offer(rel)
                } else {
                    self.available = nil
                    if userInitiated { self.alert("PadCursor is up to date", "Version \(self.currentVersion) is the latest.") }
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func offer(_ rel: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "PadCursor \(rel.version) is available"
        a.informativeText = "You have \(currentVersion). Install the update now? PadCursor restarts when it is done."
        a.addButton(withTitle: "Install and Restart")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn: install(rel)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(URL(string: rel.html_url)!)
        default: break
        }
    }

    func install(_ rel: Release) {
        guard let asset = rel.assets.first(where: { $0.name == "PadCursor.zip" }),
              let url = URL(string: asset.browser_download_url) else {
            alert("Update failed", "The release has no PadCursor.zip.")
            return
        }
        busy = true
        URLSession.shared.downloadTask(with: url) { file, _, error in
            let result = Result { () throws -> URL in
                guard let file else { throw error ?? URLError(.badServerResponse) }
                return try self.unpackAndVerify(file)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let newApp): self.swapAndRelaunch(newApp)
                case .failure(let e): self.alert("Update failed", e.localizedDescription)
                }
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
    }

    private func unpackAndVerify(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PadCursorUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        let app = dir.appendingPathComponent("PadCursor.app")
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError(errorDescription: "The download could not be unpacked.")
        }
        // Only accept an app signed by the same Developer ID team.
        var code: SecStaticCode?
        var req: SecRequirement?
        let reqText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"io.github.baygut.padcursor\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(reqText as CFString, [], &req) == errSecSuccess, let req,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess else {
            throw UpdateError(errorDescription: "The downloaded app is not signed by the PadCursor developer, so it was not installed.")
        }
        return app
    }

    private func swapAndRelaunch(_ newApp: URL) {
        let current = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        // A detached shell waits for this process to exit, replaces the bundle and reopens it.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path)"
        mv "\(newApp.path)" "\(current.path)"
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            alert("Update failed", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
