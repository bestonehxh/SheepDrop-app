import SwiftUI

@main
struct SheepDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            // Single-window app: AppModel.shared is process-global state, a second
            // window would mirror the first. Same decision as SheepTerm.
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { AppModel.shared.showQuickConnect = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Connection") {
                    if let tab = AppModel.shared.selectedTab {
                        AppModel.shared.closeTab(tab)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev hook for dark-mode screenshots without flipping the system.
        if let index = CommandLine.arguments.firstIndex(of: "-demoAppearance"),
           CommandLine.arguments.indices.contains(index + 1),
           CommandLine.arguments[index + 1] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
