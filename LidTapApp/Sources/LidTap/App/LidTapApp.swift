import SwiftUI

@main
struct LidTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(AppModel.shared)
        } label: {
            MenuBarLabel(app: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let app = AppModel.shared
            app.start()
            // First run (nothing learned yet) or launched with --settings: open Settings.
            if CommandLine.arguments.contains("--settings") || app.dataset.samples.isEmpty { app.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.privacyGuard.release()
            AppModel.shared.flushSave()
        }
    }
}
