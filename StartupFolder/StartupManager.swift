//
//  StartupManager.swift
//  StartupFolder
//
//  Created by Alin Panaitiu on 25.01.2025.
//

import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

extension FilePath.ComponentView: @retroactive Comparable {
    public static func < (lhs: FilePath.ComponentView, rhs: FilePath.ComponentView) -> Bool {
        lhs.string.lowercased() < rhs.string.lowercased()
    }
}

extension StartupItem: Comparable, Equatable {
    public static func < (lhs: StartupItem, rhs: StartupItem) -> Bool {
        lhs.name.lowercased() < rhs.name.lowercased()
    }

    public static func == (lhs: StartupItem, rhs: StartupItem) -> Bool {
        lhs.url == rhs.url
    }
}

@Observable
class StartupManager {
    init() {
        startProcessCheckTimer()
        asyncNow {
            self.loadShellEnv()
        }
    }

    var windowClosed = false
    var recentlyDeletedStartupItems: [StartupItem] = []
    var appItems: [StartupItem] = []
    var scriptItems: [StartupItem] = []
    var binaryItems: [StartupItem] = []
    var linkItems: [StartupItem] = []
    var otherItems: [StartupItem] = []
    var shortcutItems: [StartupItem] = []

    @ObservationIgnored @Default(.startupFolderPath) var startupFolderPath
    var folders: [FilePath.ComponentView] = []

    var launchInProgress = false
    var stopInProgress = false

    var allLaunched = false

    var launchWorkItems: [DispatchWorkItem] = []
    var stopTask: Task<Void, Never>?

    var fetchProcessInfoWorkItems: [DispatchWorkItem] = []

    var processCheckTimer: Timer?

    @ObservationIgnored var shellEnv: [String: String]? = nil

    var startupItems: [StartupItem] = [] {
        didSet {
            categorize()
        }
    }

    var filteredStartupItems: [StartupItem]? {
        didSet {
            categorize()
        }
    }

    func categorize() {
        folders = startupItems
            .compactMap(\.folder)
            .uniqued
            .sorted()

        let itemsToCategorize = filteredStartupItems ?? startupItems
        appItems = itemsToCategorize.filter { $0.type == .app }.sorted()
        scriptItems = itemsToCategorize.filter { $0.type == .script }.sorted()
        binaryItems = itemsToCategorize.filter { $0.type == .binary }.sorted()
        linkItems = itemsToCategorize.filter { $0.type == .link }.sorted()
        otherItems = itemsToCategorize.filter { $0.type == .other }.sorted()
        shortcutItems = itemsToCategorize.filter { $0.type == .shortcut }.sorted()
        allLaunched = itemsToCategorize.allSatisfy(\.launched)
    }

    func cleanup() {
        let onCleanup = Defaults[.onCleanup]

        if onCleanup.contains(.quitApps) {
            for item in startupItems where item.app != nil {
                item.app?.terminate()
            }
        }

        if onCleanup.contains(.terminateProcesses) {
            for item in startupItems where item.process != nil && item.type != .shortcut {
                item.process?.terminate()
            }
        }

        if onCleanup.contains(.stopShortcuts) {
            for item in startupItems where item.type == .shortcut {
                item.process?.terminate()
            }
        }

    }
    func watchStartupFolder() {
        do {
            try LowtechFSEvents.startWatching(paths: [startupFolderPath.path], for: ObjectIdentifier(self), latency: 3) { event in
                guard let flags = event.flag, flags.hasElements(from: [.itemCreated, .itemRemoved, .itemRenamed, .itemModified]) else {
                    return
                }
                log.debug("Event: \(event)")
                SM.loadStartupItems()
            }
        } catch {
            log.error("Failed to watch Startup folder: \(error)")
        }
    }

    func setupStartupFolder() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: startupFolderPath.path) {
            do {
                try fileManager.createDirectory(at: startupFolderPath, withIntermediateDirectories: true, attributes: nil)
                log.info("Created Startup folder at \(startupFolderPath)")
            } catch {
                log.error("Failed to create Startup folder: \(error)")
            }
        }
    }

    func loadStartupItems() {
        let enumerator = FileManager.default.enumerator(at: startupFolderPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants, .includesDirectoriesPostOrder]) {
            url, error in
            log.warning("Failed to enumerate Startup folder at \(url): \(error)")
            return true
        }
        let startupPathComponents = startupFolderPath.filePath?.components

        var newItems: [StartupItem] = []
        while let file = (enumerator?.nextObject() as? URL) {
            guard let resourceValues = try? file.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory, !isDirectory
            else {
                continue
            }

            let resolved = file.resolvingAliasOrSymlink
            if resolved != file, !FileManager.default.fileExists(atPath: resolved.path) {
                log.warning("Skipping broken symlink/alias: \(file.path) -> \(resolved.path)")
                continue
            }

            log.debug("Adding item at \(file.path)")
            var folder: FilePath.ComponentView?
            if let startupPathComponents, let path = file.filePath {
                let subfolder = path.removingLastComponent().components.trimmingPrefix(startupPathComponents)
                if !subfolder.isEmpty {
                    folder = FilePath.ComponentView(subfolder)
                }
            }
            newItems.append(StartupItem(url: file, folder: folder, startProcessInfoFetching: false))
        }

        var mergedItems: [StartupItem] = []
        for newItem in newItems {
            if let existingItem = startupItems.first(where: { $0.url == newItem.url }) {
                existingItem.name = newItem.name
                existingItem.type = newItem.type
                existingItem.folder = newItem.folder
                mergedItems.append(existingItem)
            } else {
                mergedItems.append(newItem)
            }
        }
        startupItems = mergedItems
        for item in fetchProcessInfoWorkItems {
            item.cancel()
        }
        fetchProcessInfoWorkItems = startupItems.map { item in
            asyncNow { item.fetchProcessInfo(url: item.url, type: item.type) }
        }
    }

    func launchStartupItems(delay: TimeInterval? = nil) {
        launchInProgress = true

        if (delay ?? startupDelay) > 0 {
            let workItem = mainAsyncAfter(startupDelay) {
                self.runStartupItemsWithDelay()
            }
            launchWorkItems = [workItem]
        } else {
            runStartupItemsWithDelay()
        }
    }

    func cancelOperations() {
        for workItem in launchWorkItems {
            workItem.cancel()
        }
        launchWorkItems = []
        stopTask?.cancel()
        launchInProgress = false
        stopInProgress = false
    }

    func stopStartupItems() {
        stopInProgress = true
        stopTask = Task {
            await withDiscardingTaskGroup { group in
                for item in startupItems {
                    let added = group.addTaskUnlessCancelled {
                        let _ = await item.stop()
                    }
                    guard added else {
                        break
                    }
                }
            }
            stopInProgress = false
            allLaunched = false
        }
    }

    @ObservationIgnored @Default(.startupDelay) private var startupDelay
    @ObservationIgnored @Default(.delayBetweenItems) private var delayBetweenItems

    private func runStartupItemsWithDelay() {
        guard delayBetweenItems > 0 else {
            for item in startupItems.sorted() {
                item.launch()
            }
            launchInProgress = false
            allLaunched = true
            return
        }

        for appItem in startupItems.filter({ $0.type == .app }) {
            guard let id = appItem.bundleIdentifier, let app = appItem.getRunningApp() else {
                continue
            }

            log.debug("Found already running app, not launching: \(app)")
            appItem.app = app
            appItem.startTime = app.launchDate
            appItem.status = app.isTerminated ? .succeeded : .running
            if Defaults[.hideAppOnLaunch][id] == true {
                log.debug("Hiding already running app: \(app)")
                app.hide()
            }

        }

        let startupItems = startupItems.filter { !$0.hasRunningApp() }
        let count = startupItems.count
        for (index, item) in startupItems.sorted().enumerated() {
            let workItem = mainAsyncAfter(delayBetweenItems * index.d) {
                item.launch()
                if index == count - 1 {
                    self.launchInProgress = false
                    self.allLaunched = true
                }
            }
            launchWorkItems.append(workItem)
        }
    }

    private func startProcessCheckTimer() {
        processCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [self] _ in
            checkRunningProcesses()
        }
        processCheckTimer?.tolerance = 60.0
    }

    private func checkRunningProcesses() {
        for item in startupItems {
            if let pid = item.pid, item.app == nil, item.process == nil, kill(pid, 0) != 0 {
                item.status = .terminated
                item.pid = nil
            }
        }
    }

    private func loadShellEnv() {
        guard let userShell = ProcessInfo.processInfo.environment["SHELL"] else {
            log.error("SHELL environment variable not found")
            return
        }
        guard let envOutput = shell(userShell, args: ["-l", "-c", "/usr/bin/printenv"]).o, envOutput.isNotEmpty else {
            log.error("Failed to get environment variables from shell")
            return
        }
        let env = envOutput.split(separator: "\n").reduce(into: [String: String]()) { dict, line in
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }

        mainAsync {
            self.shellEnv = env
        }
    }

}

@MainActor let SM = StartupManager()
