import AppKit
import SwiftUI
import TallyCore
import TallyDashboard
import TallyProjects
import TallyMenuBar
import TallyFanControl
import TallyExtras

/// Renders views to PNG with live data, for checking the UI without a screen:
///   Tally --render overview,cpu@620,popover --out /tmp/shots [--wait 6] [--scheme light|dark|both] [--width 640]
/// A name followed by @ and a number renders that screen at its own width. --projects-under <folder> leaves only
/// the projects inside that folder on the Projects screen, so a shared screenshot does not name private ones.
@MainActor
enum RenderHarness {
    static let names = ["overview", "cpu", "memory", "disk", "network", "gpu", "battery", "sensors", "temperatures", "projects", "popover", "settings", "welcome", "export", "wrapped", "inspector"]

    static var isRequested: Bool { CommandLine.arguments.contains("--render") }

    static func run(engine: SamplingEngine) {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let requested = (value(after: "--render") ?? "overview").split(separator: ",").map(String.init)
        let output = URL(fileURLWithPath: value(after: "--out") ?? FileManager.default.currentDirectoryPath)
        let wait = Double(value(after: "--wait") ?? "6") ?? 6
        let schemeArgument = value(after: "--scheme") ?? "light"
        let schemes: [ColorScheme] = schemeArgument == "both" ? [.light, .dark] : (schemeArgument == "dark" ? [.dark] : [.light])
        let requestedWidth = value(after: "--width").flatMap(Double.init).map { CGFloat($0) }

        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        engine.beginFastSampling("render")
        WrappedModel.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if let folder = value(after: "--projects-under").map({ ($0 as NSString).standardizingPath }) {
                let store = TallyStore.shared
                let shown = store.projects.filter { ($0.path as NSString).standardizingPath.hasPrefix(folder) }
                store.apply(snapshot: store.snapshot, live: store.live, processSnapshot: nil, projects: shown, alerts: nil, totals: nil)
            }
            for request in requested {
                let parts = request.split(separator: "@", maxSplits: 1)
                let name = String(parts[0])
                let width = parts.count > 1 ? Double(parts[1]).map { CGFloat($0) } : requestedWidth
                for scheme in schemes {
                    let suffix = schemes.count > 1 ? "-\(scheme == .dark ? "dark" : "light")" : ""
                    let file = output.appendingPathComponent("\(name)\(suffix).png")
                    render(name, scheme: scheme, requestedWidth: width, to: file)
                }
            }
            exit(0)
        }
    }

    private static func render(_ name: String, scheme: ColorScheme, requestedWidth: CGFloat?, to file: URL) {
        let content: AnyView
        var width: CGFloat = 1080
        switch name {
        case "overview": content = AnyView(OverviewView())
        case "sensors": content = AnyView(SensorsView { FanControlView() })
        // The Sensors tab without the fan card, whose sliders ImageRenderer cannot draw.
        case "temperatures": content = AnyView(SensorsView { EmptyView() })
        case "projects": content = AnyView(ProjectsView())
        case "popover":
            content = AnyView(MenuBarPanelView())
            width = 380
        case "settings":
            content = AnyView(SettingsView())
            width = 560
        case "welcome":
            content = AnyView(WelcomeView(onFinish: {}))
            width = 760
        case "export":
            content = AnyView(ExportView())
            width = 720
        // The export sheet on the Tally Wrapped card; add --wrapped <year> out of season.
        case "wrapped":
            content = AnyView(ExportView(kind: .wrapped))
            width = 720
        case "inspector":
            let appID = TallyStore.shared.apps.first?.id ?? ""
            content = AnyView(AppInspectorView(appID: appID))
            width = 640
        default:
            guard let tab = TallyTab(rawValue: name) else {
                print("Unknown view \(name). Choose from: \(names.joined(separator: ", "))")
                return
            }
            content = AnyView(MetricTabView(tab: tab))
        }
        if let requestedWidth {
            width = requestedWidth
        }

        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let view = content
            .padding(name == "popover" ? 0 : 20)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var rendered: CGImage?
        appearance?.performAsCurrentDrawingAppearance {
            rendered = renderer.cgImage
        }
        guard let rendered, let png = sRGBPNG(rendered) else {
            print("Could not render \(name)")
            return
        }
        do {
            try png.write(to: file)
            print("Wrote \(file.path)")
        } catch {
            print("Could not write \(file.path): \(error)")
        }
    }

    /// Redraws into 8-bit sRGB so the PNG is not tagged with the display's HDR profile.
    private static func sRGBPNG(_ image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let converted = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: converted).representation(using: .png, properties: [:])
    }
}
