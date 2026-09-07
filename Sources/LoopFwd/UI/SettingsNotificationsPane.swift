import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Notifications

struct NotificationsPane: View {
    @AppStorage(Pref.notifyOnComplete) private var notifyOnComplete = Pref.Default.notifyOnComplete
    @AppStorage(Pref.notifyOnAttention) private var notifyOnAttention = Pref.Default.notifyOnAttention
    @AppStorage(Pref.notifyOnFailure) private var notifyOnFailure = Pref.Default.notifyOnFailure
    @AppStorage(Pref.notifyOnStalled) private var notifyOnStalled = Pref.Default.notifyOnStalled
    @AppStorage(Pref.notifyOnStart) private var notifyOnStart = Pref.Default.notifyOnStart
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var permissionError: String?
    @AppStorage(Pref.hideNotificationDetails) private var hideNotificationDetails = Pref.Default.hideNotificationDetails

    var body: some View {
        SSection(title: "macOS Notifications", footer: permissionFooter) {
            Toggle(L10n.string("Hide notification details"), isOn: $hideNotificationDetails)
            SRow(title: "Permission", subtitle: permissionSubtitle) {
                Button(L10n.string(permissionActionLabel), action: handlePermissionAction)
                    .disabled(permissionAllowed)
            }
            SDiv()
            SRow(
                title: "Needs your attention",
                subtitle: "Questions, approvals, sign-in and confirmation requests."
            ) {
                Toggle(L10n.string(""), isOn: $notifyOnAttention).toggleStyle(.switch).labelsHidden()
            }
            SDiv()
            SRow(title: "Task failed", subtitle: "Provider-confirmed failures only.") {
                Toggle(L10n.string(""), isOn: $notifyOnFailure).toggleStyle(.switch).labelsHidden()
            }
            SDiv()
            SRow(title: "Task completed", subtitle: "Sent once per confirmed turn.") {
                Toggle(L10n.string(""), isOn: $notifyOnComplete).toggleStyle(.switch).labelsHidden()
            }
            SDiv()
            SRow(
                title: "Possibly stalled",
                subtitle: "Optional warning after three minutes without provider-backed progress."
            ) {
                Toggle(L10n.string(""), isOn: $notifyOnStalled).toggleStyle(.switch).labelsHidden()
            }
            SDiv()
            SRow(title: "New session started") {
                Toggle(L10n.string(""), isOn: $notifyOnStart).toggleStyle(.switch).labelsHidden()
            }
        }
        .onAppear(perform: refreshPermission)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshPermission()
        }
    }

    private var permissionAllowed: Bool {
        authorizationStatus == .authorized
            || authorizationStatus == .provisional
    }

    private var permissionSubtitle: String {
        if let permissionError { return permissionError }
        switch authorizationStatus {
        case .authorized, .provisional:
            return "Allowed — enabled task alerts can appear"
        case .denied:
            return "Blocked in System Settings"
        case .notDetermined:
            return "Not requested — LoopFwd never asks at startup"
        @unknown default:
            return "Check notification access in System Settings"
        }
    }

    private var permissionActionLabel: String {
        switch authorizationStatus {
        case .authorized, .provisional: return "Allowed"
        case .notDetermined: return "Allow…"
        case .denied: return "Open Settings"
        @unknown default: return "Open Settings"
        }
    }

    private var permissionFooter: String {
        permissionAllowed
            ? "LoopFwd posts only the notification types enabled below."
            : "Notification access is requested only after an explicit click here; startup remains silent."
    }

    private func handlePermissionAction() {
        if authorizationStatus == .notDetermined {
            permissionError = nil
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                _, error in
                DispatchQueue.main.async {
                    permissionError = error.map { L10n.format("Request failed: %@", $0.localizedDescription) }
                    refreshPermission()
                }
            }
            return
        }
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            )
        else { return }
        if !NSWorkspace.shared.open(url) {
            permissionError = "System Settings could not be opened"
        }
    }

    private func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorizationStatus = settings.authorizationStatus
            }
        }
    }
}
