import AppKit
import SmolVidCore
import SwiftUI

@main
struct SmolVidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("smol-vid", id: "main") {
            ContentView()
                .environment(model)
                .frame(minHeight: 330)
        }
        .defaultSize(width: 1130, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Compression") {
                Button("Compress") { model.compress() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canCompress)
                Button("Stop Compressing") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isCompressing || model.isCancelling)
                Divider()
                Picker("Profile", selection: $model.selectedProfileID) {
                    ForEach(CompressionProfile.builtIns) { Text(model.displayName(of: $0)).tag($0.id) }
                }
                Button("Reset Profile") { model.resetProfile(model.selectedProfileID) }
                    .disabled(!model.isCustomized(model.selectedProfileID) || model.isCompressing)
                Divider()
                Button("Compare Before and After") { model.compareItem = model.current }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                    .disabled(!(model.current?.result.map { !$0.keptOriginal } ?? false) || model.isCompressing)
                Button("Close") { model.close() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.items.isEmpty || model.isCompressing)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` rather than as a bundled app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// ffmpeg may have been installed meanwhile.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.locateFFmpeg() }
    }

    /// Files dropped onto the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.add(urls) }
    }

    /// Closing the window during a run lets it finish; the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppModel.shared.isCompressing }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.shouldTerminate() }
    }
}
