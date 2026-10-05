import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TallyCore

/// The images Tally can export.
public enum ExportImageKind: String, CaseIterable, Identifiable, Sendable {
    /// 16:9 at twice the point size, for posts.
    case shareCard
    /// Every subsystem and the top apps, at twice the point size.
    case dashboard
    /// The year summed up, offered while Tally Wrapped is in season.
    case wrapped

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .shareCard: "Share Card"
        case .dashboard: "Dashboard"
        case .wrapped: "Wrapped"
        }
    }

    /// Size in points; the image is this times `scale` in pixels.
    var pointSize: CGSize {
        switch self {
        case .shareCard: ShareCardView.size
        case .dashboard: DashboardImageView.size
        case .wrapped: WrappedCardView.size
        }
    }

    var scale: CGFloat { 2 }

    var pixelSize: CGSize { CGSize(width: pointSize.width * scale, height: pointSize.height * scale) }

    var caption: String {
        let pixels = pixelSize
        let dimensions = "\(Int(pixels.width)) × \(Int(pixels.height)) PNG"
        switch self {
        case .shareCard: return "\(dimensions) showing memory, CPU and the busiest apps, sized for sharing."
        case .dashboard: return "\(dimensions) of every metric and the apps behind them."
        case .wrapped: return "\(dimensions) of your Mac's year and the apps that filled it."
        }
    }
}

/// Renders the export images with live data, in either appearance.
@MainActor
public enum ExportRenderer {
    public static func image(_ kind: ExportImageKind, scheme: ColorScheme, date: Date = Date()) -> CGImage? {
        let renderer = ImageRenderer(content: content(kind, date: date).environment(\.colorScheme, scheme))
        renderer.scale = kind.scale
        renderer.isOpaque = true
        var image: CGImage?
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        } else {
            image = renderer.cgImage
        }
        return image.map(standardRGB)
    }

    /// Redraws in 8-bit sRGB: the renderer draws in the display's wide, deep format, which makes a PNG twice the size
    /// and shows in the wrong colours wherever the profile is dropped.
    private static func standardRGB(_ image: CGImage) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    public static func pngData(_ kind: ExportImageKind, scheme: ColorScheme, date: Date = Date()) -> Data? {
        guard let image = image(kind, scheme: scheme, date: date) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @ViewBuilder
    static func content(_ kind: ExportImageKind, date: Date) -> some View {
        switch kind {
        case .shareCard: ShareCardView(date: date)
        case .dashboard: DashboardImageView(date: date)
        case .wrapped: WrappedCardView()
        }
    }

    /// "Tally 2026-09-24 at 14.32.05.png", like macOS screenshots, or "Tally Wrapped 2026.png".
    static func fileName(for kind: ExportImageKind, date: Date) -> String {
        if kind == .wrapped, let year = WrappedModel.shared.summary?.year { return "Tally Wrapped \(year).png" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Tally \(formatter.string(from: date)).png"
    }
}

/// Save or copy a snapshot of the Mac as a share card or dashboard image.
/// The preview is drawn once per choice and is exactly the image that gets copied or saved,
/// so nothing redraws while the sheet stays open.
public struct ExportView: View {
    @Environment(\.colorScheme) private var environmentScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var wrapped = WrappedModel.shared
    @State private var kind: ExportImageKind
    @State private var scheme: ColorScheme?
    @State private var rendered: RenderedExport?
    @State private var feedback: Feedback?

    public init(kind: ExportImageKind = .shareCard) {
        _kind = State(initialValue: kind)
    }

    /// Tall enough for the 16:9 share card to fill the width.
    private static let previewHeight: CGFloat = 397

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export as an Image")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text(kind.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 12)
                Picker("Image", selection: $kind) {
                    ForEach(ExportImageKind.allCases.filter { $0 != .wrapped || wrapped.summary != nil }) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            preview

            HStack(spacing: 10) {
                Picker("Appearance", selection: schemeBinding) {
                    Label("Light", systemImage: "sun.max").tag(ColorScheme.light)
                    Label("Dark", systemImage: "moon").tag(ColorScheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if let feedback {
                    Label(feedback.text, systemImage: feedback.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(feedback.isError ? Palette.red : Palette.good)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Group {
                    Button("Copy") { copy() }
                        .keyboardShortcut("c", modifiers: .command)
                        .help("Copy the image to the clipboard")
                    Button("Save…") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .help("Save the image as a PNG file")
                }
                // Only what needs an image waits for one, so a failed render can still be retried or dismissed.
                .disabled(rendered == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .background {
            // Escape closes the sheet, as Cancel would.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: feedback)
        .task(id: RenderKey(kind: kind, scheme: resolvedScheme, summary: wrapped.summary)) {
            wrapped.refresh()
            render()
        }
    }

    private var resolvedScheme: ColorScheme { scheme ?? environmentScheme }

    private var schemeBinding: Binding<ColorScheme> {
        Binding(get: { resolvedScheme }, set: { scheme = $0 })
    }

    private var preview: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered.image, scale: rendered.kind.scale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.background)
                            .shadow(color: Palette.thumbShadow, radius: 10, y: 4)
                    )
                    .padding(16)
                    .accessibilityElement()
                    .accessibilityLabel("Preview of the \(rendered.kind.title.lowercased()) image, \(rendered.scheme == .dark ? "dark" : "light")")
                    .accessibilityAddTraits(.isImage)
            } else {
                livePreview
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.previewHeight)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    /// The live view, shown only until the first image is drawn (and in the render harness, which runs no tasks).
    private var livePreview: some View {
        GeometryReader { geometry in
            let size = kind.pointSize
            let scale = min((geometry.size.width - 32) / size.width, (geometry.size.height - 32) / size.height)
            ExportRenderer.content(kind, date: Date())
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, resolvedScheme)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func render() {
        let date = Date()
        let scheme = resolvedScheme
        guard let image = ExportRenderer.image(kind, scheme: scheme, date: date) else {
            rendered = nil
            show(Feedback(text: "Could not draw the image", symbol: "exclamationmark.triangle.fill", isError: true))
            return
        }
        rendered = RenderedExport(image: image, kind: kind, scheme: scheme, date: date)
    }

    private func copy() {
        guard let rendered else { return }
        let bitmap = NSBitmapImageRep(cgImage: rendered.image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
        show(Feedback(text: "Copied", symbol: "checkmark.circle.fill"))
    }

    private func save() {
        guard let rendered, let png = NSBitmapImageRep(cgImage: rendered.image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ExportRenderer.fileName(for: rendered.kind, date: rendered.date)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try png.write(to: url, options: .atomic) }
                DispatchQueue.main.async {
                    switch result {
                    case .success: show(Feedback(text: "Saved", symbol: "checkmark.circle.fill"))
                    case .failure(let error): show(Feedback(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true))
                    }
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func show(_ value: Feedback) {
        feedback = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if feedback == value { feedback = nil }
        }
    }
}

private struct RenderKey: Hashable {
    var kind: ExportImageKind
    var scheme: ColorScheme
    /// The Wrapped card is drawn again when its year finishes loading.
    var summary: YearSummary?
}

private struct RenderedExport {
    var image: CGImage
    var kind: ExportImageKind
    var scheme: ColorScheme
    var date: Date
}

private struct Feedback: Equatable {
    var text: String
    var symbol: String
    var isError = false
    var id = UUID()
}
