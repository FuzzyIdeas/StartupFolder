import Defaults
import Foundation
import Lowtech
import SwiftUI
import System
import WrappingHStack

struct StartupItemView: View {
    @State var item: StartupItem
    @State var runtime: String?

    @State var showSettings = SWIFTUI_PREVIEW
    @State var hoveringSettings = false

    @Default(.hideAppOnLaunch) var hideAppOnLaunch: [String: Bool]
    @Default(.keepAlive) var keepAlive: [String: Bool]
    @Default(.keepAliveMode) var keepAliveMode: [String: KeepAliveMode]

    var hideOnLaunch: Binding<Bool> {
        Binding {
            item.bundleIdentifier.map { id in hideAppOnLaunch[id] ?? false } ?? false
        } set: {
            guard let id = item.bundleIdentifier else { return }
            hideAppOnLaunch[id] = $0
        }
    }

    var keepAliveBinding: Binding<Bool> {
        Binding {
            keepAlive[item.bundleIdentifier ?? item.path] ?? false
        } set: {
            keepAlive[item.bundleIdentifier ?? item.path] = $0
        }
    }
    var keepAliveModeBinding: Binding<KeepAliveMode> {
        Binding {
            keepAliveMode[item.bundleIdentifier ?? item.path] ?? .onFail
        } set: {
            keepAliveMode[item.bundleIdentifier ?? item.path] = $0
        }
    }

    var status: some View {
        HStack {
            Text(" ").monospacedDigit()
            if let code = item.exitCode {
                Text("Exit Code: \(code)").monospacedDigit()
            }
            if let duration = runtime {
                Text("Run time: \(duration)").monospacedDigit()
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    var settings: some View {
        HStack {
            if item.type == .app {
                Toggle("Hide on launch", isOn: hideOnLaunch)
                    .help("Launch the app in hidden mode (without showing the window)")
            }
            if item.canBeKeptAlive {
                if item.type == .app {
                    Divider()
                }
                Toggle("Keep alive", isOn: keepAliveBinding)
                    .help("Restart the item if it crashes or fails to run. If the item crashes more than 5 times in 30 seconds, restarting will be stopped.")

                if keepAlive[item.bundleIdentifier ?? item.path] ?? false, item.type != .app {
                    Picker("", selection: keepAliveModeBinding) {
                        ForEach(KeepAliveMode.allCases) { mode in
                            Text(mode.text)
                                .tag(mode)
                                .help(mode.help)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            Spacer()

            status

        }
        .controlSize(.small)
        .font(.round(11))
        .foregroundStyle(.primary.opacity(0.8))
        .fill(.leading)
        .roundbg(radius: 5, verticalPadding: 5, horizontalPadding: 10, color: .gray.opacity(0.05))
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    .shadow(.inner(color: .gray, radius: 2, x: 2, y: 2))
                        .shadow(.inner(color: .gray, radius: 2, x: -2, y: -2))

                )
                .foregroundColor(.gray.opacity(0.1))
        )
        .overlay(roundRect(5, stroke: .gray.opacity(0.3), lineWidth: 1))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveringSettings = hovering
            }
        }
        .opacity(hoveringSettings ? 1 : 0.5)
    }

    var itemStatus: some View {
        HStack {
            if item.isTerminating || item.launching {
                ProgressView().controlSize(.small)
            }
            Text(item.isTerminating ? "Terminating..." : (item.launching ? "Launching..." : item.status.text))
                .roundbg(
                    radius: 7, verticalPadding: 2, horizontalPadding: 8,
                    color: item.isTerminating ? .red : item.launching ? .orange : item.status.color.opacity(0.8), noFG: true
                )
                .foregroundStyle(.white)
                .font(.round(11))
                .opacity(0.75)

            if item.type != .link, item.type != .shortcut, item.type != .other {
                Toggle(isOn: $showSettings) {
                    Image(systemName: "gearshape")
                        .font(.round(11))
                        .foregroundColor(.fg.warm)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    HStack {
                        Image(nsImage: item.icon ?? NSImage(named: NSImage.actionTemplateName)!)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 14, height: 14)
                            .roundbg(radius: 4, verticalPadding: 1, horizontalPadding: 1, color: item.isNetLink ? .white : .highContrast.opacity(0.1))
                        Text(item.shouldShowExtension ? item.name : item.name.ns.deletingPathExtension)
                            .round(14, weight: .heavy)
                            .foregroundColor(.fg.warm.opacity(0.9))
                        Button(action: {
                            if item.type == .shortcut, let url = item.shortcut?.url {
                                NSWorkspace.shared.open(url)
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                        }) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(PlainButtonStyle())

                        if let folder = item.folder {
                            Text("(in \(folder.map(\.string).joined(separator: "/")))").mono(9).foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if !item.isTrashed {
                    itemStatus
                }
            }.padding(.bottom, 5)

            if showSettings {
                settings
            }

            HStack {
                if item.isTrashed {
                    trashedActions
                        .buttonStyle(FlatButton(color: .fg.warm.opacity(0.1), textColor: .bg.gray, hoverColor: .fg.warm, radius: 5, horizontalPadding: 5, verticalPadding: 2))
                        .font(.round(11))
                        .fixedSize()
                } else {
                    actions
                        .buttonStyle(FlatButton(color: .fg.warm.opacity(0.1), textColor: .bg.gray, hoverColor: .fg.warm, radius: 5, horizontalPadding: 5, verticalPadding: 2))
                        .font(.round(11))
                        .fixedSize()
                    Spacer()
                }
            }

        }
        .padding(2)
        .sheet(isPresented: $showStdout) {
            outputView(item.readStdout() ?? "", path: item.stdoutFilePath)
        }
        .sheet(isPresented: $showStderr) {
            outputView(item.readStderr() ?? "", path: item.stderrFilePath)
        }
        .onChange(of: showSettings) {
            runtime = durationText()
        }
        .onChange(of: item.status) {
            runtime = durationText()
        }
        .onAppear {
            if showSettings {
                runtime = durationText()
            }
        }
    }

    var trashedActions: some View {
        HStack {
            Button {
                item.putBack()
            } label: {
                Label("Put back", systemImage: "trash.slash")
            }
            Button(role: .destructive) {
                SM.recentlyDeletedStartupItems.removeAll { $0.id == item.id }
            } label: {
                Label("Delete completely", systemImage: "trash")
            }
            .foregroundStyle(.red)
        }
    }

    var actions: some View {
        WrappingHStack(alignment: .leading, verticalSpacing: 2) {
            if item.canTerminate {
                Button {
                    Task { await item.restart() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }.disabled(item.isTerminating)
                Button {
                    Task { await item.terminate() }
                } label: {
                    Label("Quit", systemImage: "xmark.circle")
                }.disabled(item.isTerminating)
                Button(role: .destructive) {
                    item.forceTerminate()
                } label: {
                    Label("Force Quit", systemImage: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
            } else {
                Button {
                    item.launch()
                } label: {
                    Label("Start", systemImage: "play.circle")
                }.disabled(item.isTerminating)
            }

            if item.type == .script {
                Button {
                    NSWorkspace.shared.open([item.url], withApplicationAt: Defaults[.editorApp], configuration: .init())
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                item.trash()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .foregroundStyle(.red)

            if item.stdoutFilePath != nil {
                let outSize = item.stdoutFilePath?.fileSize() ?? 0

                Button {
                    if outSize < 100 * 1024 {
                        showStdout = true
                    } else if let url = item.stdoutFilePath?.url {
                        NSWorkspace.shared.open([url], withApplicationAt: Defaults[.editorApp], configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label(outSize <= 0 ? "No output" : "View output", systemImage: "doc.text")
                }
                .disabled(outSize <= 0)
            }
            if item.stdoutFilePath != nil {
                let errSize = item.stderrFilePath?.fileSize() ?? 0
                Button {
                    if errSize < 100 * 1024 {
                        showStderr = true
                    } else if let url = item.stderrFilePath?.url {
                        NSWorkspace.shared.open([url], withApplicationAt: Defaults[.editorApp], configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label(errSize <= 0 ? "No errors" : "View errors", systemImage: "exclamationmark.triangle")
                }
                .disabled(errSize <= 0)
            }
        }
    }

    func outputView(_ text: String, path: FilePath?) -> some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: {
                    showStdout = false
                    showStderr = false
                }) {
                    Image(systemName: "xmark")
                        .font(.heavy(7))
                        .foregroundColor(.bg.warm)
                }
                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                .padding(.top, 8).padding(.leading, 8)
                Spacer()
            }
            ScrollView {
                VStack {
                    Text(text)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .monospaced()
                        .fill(.topLeading)
                }.frame(maxWidth: .infinity)
            }
            .padding(.bottom).padding(.horizontal, 25)
            if let path {
                Button("Open in editor") {
                    NSWorkspace.shared.open([path.url], withApplicationAt: Defaults[.editorApp], configuration: .init())
                }
                .padding(4)
            }
        }.frame(width: 600, height: 300, alignment: .topLeading)
    }

    func durationText(endDate: Date? = nil) -> String? {
        guard let start = item.startTime else {
            return nil
        }
        if item.status != .running, item.endTime == nil {
            return nil
        }

        let end = item.endTime ?? endDate ?? Date()
        let duration = end.timeIntervalSince(start)
        return if duration < 1 {
            "\((duration * 1000).intround) ms"
        } else if duration < 60 {
            String(format: "%.2fs", duration)
        } else if duration < 3600 {
            String(format: "%dmin %02ds", Int(duration / 60), Int(duration) % 60)
        } else if duration < 86400 {
            String(
                format: "%dh %02dmin %02ds",
                Int(duration / 3600),
                Int((duration / 60).truncatingRemainder(dividingBy: 60)),
                Int(duration.truncatingRemainder(dividingBy: 60))
            )
        } else {
            String(
                format: "%dd %02dh %02dmin %02ds",
                Int(duration / 86400),
                Int((duration / 3600).truncatingRemainder(dividingBy: 24)),
                Int((duration / 60).truncatingRemainder(dividingBy: 60)),
                Int(duration.truncatingRemainder(dividingBy: 60))
            )
        }
    }

    @State private var showStdout = false
    @State private var showStderr = false

}

@MainActor let RUNNING_ITEM: StartupItem = {
    let s = StartupItem(url: "~/Startup/test-wait".existingFilePath!.url)
    s.status = .running
    s.startTime = Date().addingTimeInterval(-300)
    return s
}()
#Preview {
    StartupItemView(item: RUNNING_ITEM).frame(width: 600)
}
