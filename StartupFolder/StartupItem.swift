//
//  StartupItem.swift
//  StartupFolder
//
//  Created by Alin Panaitiu on 25.01.2025.
//

import Combine
import Defaults
import FaviconFinder
import Foundation
import Lowtech
import SwiftUI
import System
import UniformTypeIdentifiers

extension URL {
    var resolvingAliasOrSymlink: URL {
        (try? URL(resolvingAliasFileAt: self)) ?? resolvingSymlinksInPath()
    }
}

/// StartupManager is main-actor isolated (Defaults 9's @Default wrapper is), and every item
/// method that touches SM or drives the UI runs there anyway.
@Observable @MainActor
class StartupItem: Identifiable, CustomStringConvertible {
    init(url: URL, folder: FilePath.ComponentView? = nil, startProcessInfoFetching: Bool = true) {
        self.url = url
        self.folder = folder
        name = url.lastPathComponent
        type = StartupItem.determineType(of: url)
        if type == .shortcut {
            shortcut = extractShortcut(from: url)
        }

        icon = switch type {
        case .app:
            NSWorkspace.shared.icon(forFile: url.resolvingAliasOrSymlink.path)
        case .binary:
            NSWorkspace.shared.icon(forFile: url.resolvingAliasOrSymlink.path)
        case .link:
            getFavicon(for: siteURL) ?? NSImage(named: NSImage.networkName)!
        case .script:
            getLanguageIcon(for: url) ?? NSImage(named: NSImage.actionTemplateName)!
        case .shortcut:
            SHORTCUT_ICON
        default:
            NSImage(named: NSImage.actionTemplateName)!
        }

        let url = url
        let type = type
        if startProcessInfoFetching {
            asyncNow { [weak self] in
                self?.fetchProcessInfo(url: url, type: type)
            }
        }
    }

    enum StartupItemType: CaseIterable {
        case app
        case script
        case binary
        case other
        case link
        case shortcut

        var text: String {
            switch self {
            case .app:
                "App"
            case .script:
                "Script"
            case .binary:
                "Binary"
            case .other:
                "Other"
            case .link:
                "Link"
            case .shortcut:
                "Shortcut"
            }
        }
    }

    enum ExecutionStatus: CaseIterable {
        case notStarted
        case running
        case succeeded
        case terminated
        case failed

        var text: String {
            switch self {
            case .notStarted:
                "Not started"
            case .running:
                "Running"
            case .succeeded:
                "Succeeded"
            case .failed:
                "Failed"
            case .terminated:
                "Terminated"
            }
        }

        var color: Color {
            switch self {
            case .notStarted:
                .gray
            case .running:
                .orange
            case .succeeded:
                if #available(macOS 15.0, *) {
                    .green.mix(with: .primary, by: 0.2)
                } else {
                    .green
                }
            case .failed:
                .red
            case .terminated:
                .blue
            }
        }
    }

    var folder: FilePath.ComponentView?

    var stdoutFilePath: FilePath?
    var stderrFilePath: FilePath?

    var name: String
    var type: StartupItemType
    var exitCode: Int32?
    var startTime: Date?
    var endTime: Date?
    var isTrashed = false
    var shortcut: Shortcut?
    var isTerminating = false
    var icon: NSImage?

    @ObservationIgnored lazy var utType: UTType? = {
        if type == .script, ext.isEmpty {
            guard let fileHandle = try? FileHandle(forReadingFrom: url),
                  let firstLine = String(data: fileHandle.readData(ofLength: 1024), encoding: .utf8)?.components(separatedBy: .newlines).first,
                  firstLine.hasPrefix("#!")
            else {
                return nil
            }
            return ScriptRunner(fromShebang: firstLine)?.utType ?? .executable
        }
        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let utType = resourceValues.contentType
        else {
            return nil
        }
        return utType
    }()

    @ObservationIgnored lazy var siteURL: URL? = {
        guard type == .link else {
            return nil
        }
        if ext == "webloc" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let siteURLString = plist["URL"] as? String,
                  let siteURL = URL(string: siteURLString)
            else {
                return nil
            }
            return siteURL
        } else if ["link", "txt", "url"].contains(ext) {
            guard let content = try? String(contentsOf: url).trimmed,
                  let siteURL = URL(string: content)
            else {
                return nil
            }
            return siteURL
        }
        return nil
    }()

    var pid: Int32?

    var launching = false

    @ObservationIgnored lazy var bundleIdentifier: String? = app?.bundleIdentifier ?? Bundle(url: url.resolvingAliasOrSymlink)?.bundleIdentifier
    @ObservationIgnored lazy var path: String = url.path
    @ObservationIgnored lazy var ext: String = url.pathExtension
    @ObservationIgnored lazy var id = "\(path)-\(type)"
    @ObservationIgnored var observers: [AnyCancellable] = []
    @ObservationIgnored var appTerminatedObserver: AnyCancellable?

    var ignoreKeepAlive: ExpiringBool = false

    var url: URL {
        didSet {
            path = url.path
            ext = url.pathExtension
            id = "\(path)-\(type)"
        }
    }

    var status: ExecutionStatus = .notStarted {
        didSet {
            guard !ignoreKeepAlive.value, canBeKeptAlive else {
                return
            }
            if status == .failed, (Defaults[.keepAliveMode][bundleIdentifier ?? path] ?? .onFail) != .onSuccess {
                handleKeepAlive()
            }
            if status == .succeeded, (Defaults[.keepAliveMode][bundleIdentifier ?? path] ?? .onFail) != .onFail {
                handleKeepAlive()
            }
            if status == .terminated, oldValue == .running, type == .app {
                handleKeepAlive()
            }
        }
    }
    var canBeKeptAlive: Bool {
        type == .app || type == .binary || type == .script
    }

    var description: String {
        "\(name) - \(type.text) - \(status.text)"
    }

    var launched: Bool {
        status != .notStarted
    }

    var isNetLink: Bool {
        type == .link && (siteURL?.scheme?.starts(with: "http") ?? false)
    }

    var process: Process? {
        didSet {
            stdoutFilePath = process?.stdoutFilePath?.existingFilePath
            stderrFilePath = process?.stderrFilePath?.existingFilePath
        }
    }

    var shouldShowExtension: Bool {
        switch type {
        case .app, .link, .shortcut:
            false
        default:
            true
        }
    }

    var isRunning: Bool {
        status == .running
    }

    var canTerminate: Bool {
        status == .running && (app.map { !$0.isTerminated } ?? process?.isRunning ?? (pid != nil))
    }

    @ObservationIgnored var app: NSRunningApplication? {
        willSet {
            appTerminatedObserver?.cancel()
            appTerminatedObserver = nil
        }
        didSet {
            appTerminatedObserver = app?.publisher(for: \.isTerminated)
                .drop(while: { terminated in !terminated })
                .sink { [weak self] _ in
                    self?.appTerminatedObserver?.cancel()
                    self?.appTerminatedObserver = nil
                    self?.setAppTerminated()
                }
        }
    }

    static func determineType(of url: URL) -> StartupItemType {
        let ext = url.pathExtension

        return if ext == "app" || (url.resolvingAliasOrSymlink).pathExtension == "app" {
            .app
        } else if ["webloc", "link", "txt", "url"].contains(ext) {
            if let _ = try? String(contentsOf: url).url {
                .link
            } else {
                .other
            }
        } else if ext == "shortcut" {
            .shortcut
        } else if url.isExecutable(), !url.isBinary() {
            .script
        } else if url.isExecutable() {
            .binary
        } else if let _ = ScriptRunner(fromExtension: ext) {
            .script
        } else {
            .other
        }
    }

    func setAppTerminated() {
        if status != .terminated {
            status = .terminated
            endTime = Date()
        }
        app = nil
    }

    func hasRunningApp() -> Bool {
        getRunningApp() != nil
    }
    func getRunningApp() -> NSRunningApplication? {
        guard let bundleID = bundleIdentifier else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    func fetchProcessInfo(url: URL, type: StartupItemType) {
        switch type {
        case .app:
            guard let bundle = Bundle(url: url.resolvingAliasOrSymlink), let bundleID = bundle.bundleIdentifier,
                  let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else {
                return
            }
            mainAsync { [weak self] in
                guard let self else { return }
                startTime = runningApp.launchDate
                app = runningApp
                status = .running
            }
        case .script, .binary:
            guard let pid = shell("/usr/bin/pgrep", args: ["-n", "-f", url.resolvingAliasOrSymlink.path]).o?.i32
            else { return }
            mainAsync { [weak self] in
                guard let self else { return }
                self.pid = pid
                (stdoutFilePath, stderrFilePath) = getStdoutAndStderrPaths(pid: pid)
                startTime = getStartTime(forPid: pid)
                status = .running
            }
        case .shortcut:
            guard let shortcut, let pid = shell("/usr/bin/pgrep", args: ["-n", "-f", shortcut.identifier ?! shortcut.name]).o?.i32
            else { return }
            mainAsync { [weak self] in
                guard let self else { return }
                self.pid = pid
                (stdoutFilePath, stderrFilePath) = getStdoutAndStderrPaths(pid: pid)
                startTime = getStartTime(forPid: pid)
                status = .running
            }
        default:
            return
        }
    }

    func readStdout() -> String? {
        guard let stdoutFilePath else {
            return nil
        }
        return (try? String(contentsOf: stdoutFilePath.url)) ?? ""
    }

    func readStderr() -> String? {
        guard let stderrFilePath else {
            return nil
        }
        return (try? String(contentsOf: stderrFilePath.url)) ?? ""
    }

    func trash() {
        var trashURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        } catch {
            log.error("Failed to trash \(url): \(error)")
            return
        }

        let id = id
        SM.startupItems.removeAll { $0.id == id }

        guard let trashURL = trashURL as URL? else {
            log.error("Failed to trash \(url)")
            return
        }
        url = trashURL
        isTrashed = true
        SM.recentlyDeletedStartupItems = SM.recentlyDeletedStartupItems.without(id: id) + [self]
    }

    func putBack() {
        guard isTrashed else {
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: SM.startupFolderPath.appendingPathComponent(name))
        } catch {
            log.error("Failed to put back \(url): \(error)")
            return
        }

        let id = id
        SM.recentlyDeletedStartupItems.removeAll { $0.id == id }
        SM.startupItems = SM.startupItems + [self]
        isTrashed = false
    }

    func launch() {
        guard !isRunning, !isTerminating else {
            return
        }

        let resolved = url.resolvingAliasOrSymlink
        if resolved != url, !FileManager.default.fileExists(atPath: resolved.path) {
            log.error("Cannot launch \(name): symlink target does not exist at \(resolved.path)")
            status = .failed
            return
        }

        launching = true
        defer { launching = false }

        endTime = nil

        switch type {
        case .app:
            launchApp()
        case .script, .binary, .shortcut:
            launchExecutable()
        case .link:
            launchURL()
        case .other:
            launchWithWorkspace()
        }
    }

    func stop() async -> Bool {
        guard canTerminate else {
            status = .notStarted
            return true
        }
        return await terminate()
    }

    func terminate() async -> Bool {
        guard !isTerminating else {
            return false
        }

        isTerminating = true
        defer { isTerminating = false }

        ignoreKeepAlive.set(true, expireAfter: 7)

        if let app {
            app.terminate()
        } else if let process {
            process.terminate()
        } else if let pid {
            kill(pid, SIGTERM)
        }

        if await (waitUntilTerminated(for: 3)) {
            withoutKeepAlive {
                status = .terminated
            }
            return true
        }
        return false
    }

    func withoutKeepAlive(action: () -> Void) {
        ignoreKeepAlive.set(true, expireAfter: nil)
        action()
        ignoreKeepAlive.set(false, expireAfter: nil)
    }

    func restart() async -> Bool {
        guard !isTerminating else {
            return false
        }

        isTerminating = true
        defer { isTerminating = false }

        ignoreKeepAlive.set(true, expireAfter: 7)

        if let app {
            app.terminate()
        } else if let process {
            process.terminate()
        }

        if await !waitUntilTerminated(for: 3) {
            forceTerminate()
            if await !waitUntilTerminated(for: 3) {
                return false
            }
        }
        isTerminating = false
        status = .notStarted
        launch()
        return true
    }

    func waitUntilTerminated(for timeout: TimeInterval) async -> Bool {
        let isRunning: () -> Bool = {
            if let process = self.process {
                process.isRunning
            } else if let app = self.app {
                !app.isTerminated
            } else if let pid = self.pid {
                kill(pid, 0) == 0
            } else {
                false
            }
        }

        for _ in 0 ..< Int(timeout * 10) {
            if isRunning() {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            } else {
                return true
            }
        }
        return false
    }

    func forceTerminate() {
        withoutKeepAlive {
            if let app {
                app.forceTerminate()
                status = .terminated
            } else if let process {
                let pid = process.processIdentifier
                kill(pid, SIGKILL)
                status = .terminated
            } else if let pid {
                kill(pid, SIGKILL)
                status = .terminated
            }
        }
        isTerminating = false
    }

    private var terminationTimestamps: [Date] = []

    private func handleKeepAlive() {
        terminationTimestamps.append(Date())
        terminationTimestamps = terminationTimestamps.filter { $0.timeIntervalSinceNow > -30 }

        if terminationTimestamps.count > 5 {
            log.error("Crash loop detected for \(name). Not restarting.")
            return
        }

        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.fileExists(atPath: url.resolvingAliasOrSymlink.path)
        else {
            log.error("File does not exist: \(url)")
            SM.startupItems.removeAll { $0.id == id }
            return
        }

        if Defaults[.keepAlive][bundleIdentifier ?? path] == true {
            log.info("Restarting \(name) in 3 seconds due to keep alive setting.")
            mainAsyncAfter(3) { [weak self] in
                self?.launch()
            }
        }
    }

    private func launchApp() {
        status = .running

        let config = NSWorkspace.OpenConfiguration()
        if let id = bundleIdentifier {
            config.activates = Defaults[.hideAppOnLaunch][id] != true
            config.hides = Defaults[.hideAppOnLaunch][id] == true
        }

        log.info("Launching app \(path) with config \(config)")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            mainAsync {
                if let error {
                    self.status = .failed
                    log.error("Failed to open app \(self.url): \(error)")
                    return
                }
                guard let app else {
                    self.status = .failed
                    return
                }

                self.status = app.isTerminated ? .succeeded : .running
                self.startTime = app.launchDate
                self.endTime = app.isTerminated ? Date() : nil
                self.app = app

                guard let bundleID = self.bundleIdentifier else {
                    log.warning("No bundle ID for \(self.path), cannot hide app")
                    return
                }
                if Defaults[.hideAppOnLaunch][bundleID] == true, app.activationPolicy == .regular {
                    app.hide()
                    mainAsyncAfter(1) { app.hide() }
                    mainAsyncAfter(2) { app.hide() }
                    mainAsyncAfter(3) { app.hide() }
                }
            }
        }
    }

    private func launchExecutable() {
        if type == .shortcut {
            guard let shortcut else {
                log.error("Failed to extract shortcut from \(url)")
                return
            }
            process = shellProc("/usr/bin/shortcuts", args: ["run", shortcut.identifier ?! shortcut.name])
        } else if type == .script, !url.isExecutable(), let scriptRunner = ScriptRunner(fromExtension: ext) {
            process = shellProc(scriptRunner.path, args: [path], env: SM.shellEnv)
        } else {
            process = shellProc(path, args: [], env: SM.shellEnv)
        }
        guard let process else {
            status = .failed
            log.error("Failed to launch process for \(url)")
            return
        }

        status = .running
        startTime = Date()

        process.terminationHandler = { [weak self] proc in
            // mainActor, not mainAsync: the item is main-actor isolated and only the
            // @MainActor closure proves to the compiler that this runs there.
            mainActor {
                guard let self else {
                    return
                }
                self.exitCode = proc.terminationStatus
                self.endTime = Date()
                if self.status != .terminated, !self.isTerminating {
                    self.status = proc.terminationStatus == 0 ? .succeeded : .failed
                }
            }
        }
    }

    private func launchURL() {
        status = NSWorkspace.shared.open(siteURL ?? url) ? .succeeded : .failed
    }

    private func launchWithWorkspace() {
        status = NSWorkspace.shared.open(url) ? .succeeded : .failed
    }

    private func extractShortcut(from url: URL) -> Shortcut? {
        let identifier: String?
        if let fileHandle = try? FileHandle(forReadingFrom: url) {
            let data = fileHandle.readData(ofLength: 36) // UUID length
            identifier = String(data: data, encoding: .utf8)?.trimmed
        } else {
            identifier = nil
        }

        if let identifier, !identifier.isEmpty {
            return SHM.shortcuts.first { $0.identifier == identifier }
                ?? Shortcut(name: url.deletingPathExtension().lastPathComponent, identifier: identifier)
        } else {
            return SHM.shortcuts.first { $0.name == url.deletingPathExtension().lastPathComponent }
                ?? Shortcut(name: url.deletingPathExtension().lastPathComponent, identifier: "")
        }
    }

    private func getLanguageIcon(for url: URL) -> NSImage? {
        NSWorkspace.shared.icon(for: utType ?? .executable)
    }

    private func getFavicon(for url: URL?) -> NSImage? {
        guard let url else {
            return nil
        }
        if let image = FAVICON_CACHE.object(forKey: url as NSURL) {
            return image
        }

        guard url.scheme?.starts(with: "http") ?? false else {
            if let appURL = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() as URL? {
                let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                FAVICON_CACHE.setObject(appIcon, forKey: url as NSURL)
                return appIcon
            }
            return nil
        }

        Task { [weak self] in
            if let image = await downloadFavicon(for: url) {
                mainAsync {
                    FAVICON_CACHE.setObject(image, forKey: url as NSURL)
                    self?.icon = image
                }
            }

        }
        return nil
    }

}

let SHORTCUT_ICON = NSWorkspace.shared.icon(forFile: "/System/Applications/Shortcuts.app")
let FAVICON_CACHE_DIR = FilePath.dir(
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("startup-folder-favicons")
        .filePath ?? "/tmp/startup-folder-favicons".filePath!
)
let FAVICON_CACHE = NSCache<NSURL, NSImage>()

func downloadFavicon(for url: URL) async -> NSImage? {
    guard let domain = url.host else {
        return nil
    }

    let cacheFilePath = FAVICON_CACHE_DIR / "\(domain.safeFilename).png"
    if cacheFilePath.exists, let image = NSImage(contentsOf: cacheFilePath.url) {
        return image
    }

    do {
        let favicon = try await FaviconFinder(url: url)
            .fetchFaviconURLs()
            .download()
            .smallest()

        guard let image = favicon.image?.image else {
            log.error("Failed to retrieve favicon for \(url)")
            return nil
        }

        if let tiff = image.tiffRepresentation, let tiffData = NSBitmapImageRep(data: tiff),
           let imageData = tiffData.representation(using: .png, properties: [:])
        {
            try imageData.write(to: cacheFilePath.url)
        } else {
            log.error("Failed to save favicon for \(url)")
        }

        return image
    } catch {
        log.error("Failed to retrieve or save favicon with error: \(String(describing: error))")
        return nil
    }
}

func getStartTime(forBundleID bundleID: String) -> Date? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.launchDate
}

func getStartTime(forExePath exePath: String) -> Date? {
    guard let pid = shell("/usr/bin/pgrep", args: ["-n", "-f", exePath]).o?.i32 else {
        return nil
    }

    return getStartTime(forPid: pid)
}

func getStartTime(forPid pid: Int32) -> Date? {
    if let proc = NSRunningApplication(processIdentifier: pid) {
        return proc.launchDate
    }
    guard let timeStr = shell("/bin/ps", args: ["-o", "lstart=", "-p", "\(pid)"]).o else {
        return nil
    }

    var time = tm()
    strptime(timeStr, "%c", &time)
    return Date(timeIntervalSince1970: Double(mktime(&time)))
}

func getArgumentsForPID(pid: Int32) -> [String] {
    var args = [String]()

    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    sysctl(&mib, u_int(mib.count), nil, &size, nil, 0)

    var buffer = [CChar](repeating: 0, count: size)
    sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0)

    // Convert buffer to a string with proper bounds checking
    let bufferString = NSString(bytesNoCopy: &buffer, length: size, encoding: NSASCIIStringEncoding, freeWhenDone: false)

    // Split the string into arguments
    if let bufferString = bufferString as String? {
        args = bufferString.split(separator: "\0").map { String($0) }
    }

    // Drop the first element which is the full path to the executable
    if !args.isEmpty {
        args.removeFirst()
    }

    return args
}

func getStdoutAndStderrPaths(pid: Int32) -> (FilePath?, FilePath?) {
    let args = getArgumentsForPID(pid: pid)

    let stdoutPath = args.first { $0.hasPrefix("__swift_stdout=") }?.replacingOccurrences(of: "__swift_stdout=", with: "").existingFilePath
    let stderrPath = args.first { $0.hasPrefix("__swift_stderr=") }?.replacingOccurrences(of: "__swift_stderr=", with: "").existingFilePath

    return (stdoutPath, stderrPath)
}
