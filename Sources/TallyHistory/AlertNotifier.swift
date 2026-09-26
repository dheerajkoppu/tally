import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import TallyCore

extension AlertKind {
    /// The tab a notification opens.
    var tab: TallyTab {
        switch self {
        case .highCPU: .cpu
        case .growingMemory: .memory
        case .heavyDisk: .disk
        case .heavyNetwork: .network
        }
    }
}

/// Posts alerts as local notifications and routes clicks back into the app.
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertNotifier()

    /// UNUserNotificationCenter crashes in a process without a bundle identifier, such as a probe.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private let queue = DispatchQueue(label: "tally.alerts.notifications", qos: .utility)
    private let appIDKey = "appID"
    private let kindKey = "kind"

    static func installDelegate() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate !== shared { center.delegate = shared }
    }

    static func requestAuthorization() {
        guard isAvailable else { return }
        installDelegate()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Tally alerts: notification permission failed: %@", error.localizedDescription) }
        }
    }

    /// - Parameter iconPath: a bundle or executable whose icon is attached as the image on the right, as in the launch video.
    func post(_ alert: AlertItem, iconPath: String?) {
        guard Self.isAvailable else { return }
        queue.async { [appIDKey, kindKey] in
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.detail
            content.threadIdentifier = alert.appID
            content.userInfo = [appIDKey: alert.appID, kindKey: alert.kind.rawValue]
            let icon = iconPath.flatMap(Self.iconAttachment(forPath:))
            if let icon { content.attachments = [icon.attachment] }
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                // The system has moved the image into its own store by now; this clears what is left.
                if let icon { try? FileManager.default.removeItem(at: icon.folder) }
                if let error { NSLog("Tally alerts: could not post notification: %@", error.localizedDescription) }
            }
        }
    }

    private static let iconPixels = 256

    /// The app's icon as a small flattened PNG in a temporary folder of its own, or nil if it cannot be made.
    private static func iconAttachment(forPath path: String) -> (attachment: UNNotificationAttachment, folder: URL)? {
        // Resolved so an app linked into /Applications (Safari) shows no alias arrow.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved),
              let data = flattenedPNG(NSWorkspace.shared.icon(forFile: resolved))
        else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TallyAlertIcons", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("icon.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            let attachment = try UNNotificationAttachment(identifier: "icon", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
            return (attachment, folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Workspace icons are extended-range images; the notification gets a plain 8-bit sRGB bitmap.
    private static func flattenedPNG(_ icon: NSImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: iconPixels, height: iconPixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: iconPixels, height: iconPixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let appID = userInfo[appIDKey] as? String
        let kind = (userInfo[kindKey] as? String).flatMap(AlertKind.init(rawValue:))
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let kind {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppRouter.shared.open(kind.tab, inspecting: appID)
                }
            }
        }
        completionHandler()
    }
}
