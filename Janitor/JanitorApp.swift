import SwiftUI
import UserNotifications

struct JanitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = Monitor()

    var body: some Scene {
        Window("Janitor", id: "main") {
            ContentView()
                .environment(monitor)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 920, height: 680)

        Window("Disk Cleanup", id: "cleanup") {
            CleanupView()
                .environment(monitor)
        }
        .defaultSize(width: 780, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
        } label: {
            MenuBarLabel()
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}

/// Always on screen, so it is also where the "open the cleanup window" hook is registered
/// for the notification's Clean Now button.
struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Show load in the menu bar only when there is something worth cleaning.
            if monitor.sims.isEmpty && monitor.hogs.isEmpty {
                Image(systemName: "bubbles.and.sparkles")
            } else {
                Image(systemName: "bubbles.and.sparkles.fill")
                Text("\(Int(monitor.totalCPU.rounded()))%")
            }
        }
        .task {
            AppDelegate.openCleanup = {
                openWindow(id: "cleanup")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var openCleanup: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LowDiskNotifier.registerCategory()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Clicking the notification or its Clean Now button opens the cleanup preview.
    /// Nothing is deleted until Clean Now is pressed there.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            // On a cold launch the menu bar item may not have registered the hook yet.
            for _ in 0..<20 where AppDelegate.openCleanup == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            AppDelegate.openCleanup?()
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
