import SwiftUI
import QuickLookThumbnailing
import AppKit

extension FitLevel {
    var color: Color {
        switch self {
        case .comfortable: return .green
        case .lowMemoryMode: return .teal
        case .tight: return .orange
        case .tooLarge: return .red
        }
    }
}

struct FitBadge: View {
    let fit: FitLevel
    var compact = false
    var body: some View {
        Label(compact && fit == .lowMemoryMode ? "Low-memory fit" : fit.label, systemImage: fit.symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1).fixedSize()
            .foregroundStyle(fit.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fit.color.opacity(0.14), in: Capsule())
    }
}

struct Tag: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// A rounded panel. On the window backdrop it is Liquid Glass; inside another glass panel
/// (`inset`) it is a quiet tinted fill, because glass stacked on glass turns muddy.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var inset = false
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: inset ? 12 : 22, style: .continuous)
        if inset {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: shape)
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: shape)
        }
    }
}

enum Brand {
    static let violet = Color(red: 0.55, green: 0.42, blue: 1.0)
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.45)
    static let gradient = LinearGradient(colors: [violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Colour field behind the glass. The drifting glow is animated by Core Animation in the window
/// server, so the app itself does no per-frame work. It holds still while a model is working, when
/// the window is in the background, with Reduce Motion on, or when the setting is turned off.
struct AmbientBackground: View {
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlState
    @Environment(\.colorScheme) private var scheme
    @State private var settings = AppSettings.shared

    var body: some View {
        let moving = settings.animatedBackdrop && !reduceMotion && !active && controlState != .inactive
        BackdropLayer(moving: moving)
            .overlay(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.55))
            .ignoresSafeArea()
    }
}

private struct BackdropLayer: NSViewRepresentable {
    let moving: Bool
    func makeNSView(context: Context) -> BackdropNSView { BackdropNSView() }
    func updateNSView(_ view: BackdropNSView, context: Context) { view.setMoving(moving) }
}

final class BackdropNSView: NSView {
    private let base = CAGradientLayer()
    private var glows: [CAGradientLayer] = []
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        base.colors = [NSColor(red: 0.16, green: 0.10, blue: 0.40, alpha: 1).cgColor,
                       NSColor(red: 0.30, green: 0.20, blue: 0.70, alpha: 1).cgColor,
                       NSColor(red: 0.12, green: 0.14, blue: 0.36, alpha: 1).cgColor]
        base.startPoint = CGPoint(x: 0, y: 1); base.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(base)
        let tints: [NSColor] = [NSColor(red: 1.00, green: 0.52, blue: 0.42, alpha: 0.85),
                                NSColor(red: 0.50, green: 0.34, blue: 1.00, alpha: 0.9),
                                NSColor(red: 0.86, green: 0.42, blue: 0.62, alpha: 0.75),
                                NSColor(red: 0.24, green: 0.36, blue: 0.90, alpha: 0.8)]
        for tint in tints {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [tint.cgColor, tint.withAlphaComponent(0).cgColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(glow)
            glows.append(glow)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.frame = bounds
        let side = max(bounds.width, bounds.height) * 0.95
        // Resting places for the glows, as fractions of the window.
        let spots: [CGPoint] = [CGPoint(x: 0.55, y: 0.05), CGPoint(x: 0.18, y: 0.62), CGPoint(x: 0.92, y: 0.55), CGPoint(x: 0.75, y: 0.95)]
        for (i, glow) in glows.enumerated() {
            glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            glow.position = CGPoint(x: bounds.width * spots[i].x, y: bounds.height * spots[i].y)
        }
        CATransaction.commit()
        installAnimations()
    }

    /// Each glow wanders around its resting place on a slow loop.
    private func installAnimations() {
        guard bounds.width > 10 else { return }
        for (i, glow) in glows.enumerated() {
            glow.removeAnimation(forKey: "drift")
            let p = glow.position
            let dx = bounds.width * 0.16, dy = bounds.height * 0.14
            let sign: CGFloat = i.isMultiple(of: 2) ? 1 : -1
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [p, CGPoint(x: p.x + dx * sign, y: p.y + dy), CGPoint(x: p.x - dx * 0.5, y: p.y + dy * 1.4 * sign),
                           CGPoint(x: p.x - dx * sign, y: p.y - dy * 0.6), p].map { NSValue(point: $0) }
            path.calculationMode = .cubic
            path.duration = 46 + Double(i) * 11
            path.repeatCount = .infinity
            glow.add(path, forKey: "drift")
        }
        applyMoving()
    }

    func setMoving(_ value: Bool) {
        guard value != moving else { return }
        moving = value
        applyMoving()
    }

    /// Standard Core Animation pause and resume: freeze the layer's clock where it is.
    private func applyMoving() {
        guard let layer else { return }
        if moving, layer.speed == 0 {
            let paused = layer.timeOffset
            layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !moving, layer.speed != 0 {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
    }
}

/// Decodes images once, scaled down to what the screen can show, off the main thread.
/// A 4096 px result would otherwise hold 64 MB and be re-read from disk on every redraw.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 4 }

    /// `maxPixel` of 0 loads the image at full size.
    func image(for url: URL, maxPixel: Int) async -> NSImage? {
        let key = "\(url.path)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            if maxPixel > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
            return maxPixel > 0 ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                                : CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }

    func purge() { cache.removeAllObjects() }
}

/// Lifts a control slightly while the pointer is over it.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.025
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.28 : 0), radius: 18, y: 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Fades and slides a view in, later for higher `index`, so grids and lists arrive as a cascade.
struct AppearStagger: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(Double(min(index, 14)) * 0.035)) { shown = true }
            }
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.025) -> some View { modifier(HoverLift(scale: scale)) }
    func appearStagger(_ index: Int) -> some View { modifier(AppearStagger(index: index)) }
    /// A floating Liquid Glass panel.
    func glassPanel(cornerRadius: CGFloat = 26) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// System memory bar that turns orange and red as pressure builds.
struct MemoryGauge: View {
    @State private var monitor = MemoryMonitor.shared
    var body: some View {
        let total = SystemInfo.current.totalGB
        let used = total - monitor.availableGB
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Memory").font(.caption.weight(.medium))
                Spacer()
                Text("\(String(format: "%.1f", used)) of \(Format.gb(total))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * monitor.usedFraction))
                    if monitor.jobGB > 0.1 {
                        Capsule().fill(.tint).frame(width: max(4, geo.size.width * min(1, monitor.jobGB / total)))
                    }
                }
            }
            .frame(height: 6)
            if monitor.jobGB > 0.1 {
                Text("Model \(Format.gb(monitor.jobGB))" + (monitor.swapGB > 0.5 ? " · swap \(Format.gb(monitor.swapGB))" : ""))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else if monitor.pressure != .normal {
                Text(monitor.pressure.label).font(.caption2).foregroundStyle(color)
            }
        }
        .animation(.easeOut(duration: 0.4), value: monitor.usedFraction)
    }
    private var color: Color {
        switch monitor.pressure {
        case .normal: return .secondary.opacity(0.55)
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 160 }

    func purge() { cache.removeAllObjects() }

    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)@\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

struct Thumbnail: View {
    let url: URL
    var side: CGFloat = 160
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url, side: side) }
    }
}

/// A drop target that also opens a file picker when clicked.
struct FileWell: View {
    let title: String
    let symbol: String
    let allowed: [String]          // file extensions
    @Binding var path: String?
    var showsPreview = true
    @State private var targeted = false

    var body: some View {
        Group {
            if let path {
                HStack(spacing: 10) {
                    if showsPreview {
                        Thumbnail(url: URL(fileURLWithPath: path), side: 54)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Image(systemName: symbol).font(.title3).frame(width: 54, height: 54)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { self.path = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
                .padding(8)
            } else {
                Button(action: choose) {
                    HStack(spacing: 8) {
                        Image(systemName: symbol)
                        Text(title)
                        Spacer()
                        Text("Drop or choose").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .background(targeted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), style: StrokeStyle(lineWidth: 1, dash: path == nil ? [4, 3] : [])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { allowed.contains($0.pathExtension.lowercased()) }) else { return false }
            path = url.path
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

import UniformTypeIdentifiers

enum FileKinds {
    static let images = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "bmp"]
    static let audio = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "ogg"]
}

func relativeDate(_ date: Date) -> String {
    if abs(date.timeIntervalSinceNow) < 45 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

extension View {
    /// Soft brand gradient used for hero touches.
    func mirageGradient() -> some View { self.foregroundStyle(Brand.gradient) }
}

// MARK: - Custom controls

/// The main call-to-action: a glowing gradient capsule that brightens on hover and dips when pressed.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, large: large) }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
                .padding(.horizontal, large ? 20 : 14).padding(.vertical, large ? 11 : 6)
                .background {
                    Capsule().fill(enabled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.primary.opacity(0.1)))
                        .overlay(Capsule().fill(.white.opacity(hovering && enabled ? 0.16 : 0)))
                        .overlay(Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1).opacity(enabled ? 1 : 0.25))
                }
                .shadow(color: Brand.violet.opacity(enabled ? (hovering ? 0.7 : 0.42) : 0), radius: hovering ? 18 : 10, y: 4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.68), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .animation(.easeOut(duration: 0.25), value: enabled)
                .onHover { hovering = $0 }
                .contentShape(Capsule())
        }
    }
}

/// Secondary action: a soft translucent capsule.
struct SoftButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, small: small) }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .font((small ? Font.caption : Font.callout).weight(.medium))
                .foregroundStyle(destructive && hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.primary.opacity(enabled ? 0.92 : 0.4)))
                .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 4 : 6.5)
                .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.22 : hovering && enabled ? 0.16 : 0.09)))
                .overlay(Capsule().strokeBorder(.primary.opacity(hovering && enabled ? 0.22 : 0.1), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.16), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Capsule())
        }
    }
}

/// Round icon-only button that lifts on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var tinted = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, size: size, tinted: tinted) }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let tinted: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(destructive && hovering ? AnyShapeStyle(.red)
                                 : tinted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(enabled ? 0.9 : 0.35)))
                .frame(width: size, height: size)
                .background(Circle().fill(tinted ? AnyShapeStyle(Brand.gradient)
                                          : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.24 : hovering && enabled ? 0.17 : 0.09))))
                .overlay(Circle().strokeBorder(.primary.opacity(hovering ? 0.22 : 0.1), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.9 : hovering && enabled ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Circle())
        }
    }
}

/// Small selectable pill, used for size shortcuts.
struct ChipButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, selected: selected) }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.caption.weight(selected ? .semibold : .medium)).monospacedDigit()
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.8)))
                .padding(.horizontal, 10).padding(.vertical, 4.5)
                .background(Capsule().fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.primary.opacity(hovering ? 0.16 : 0.08))))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: selected)
                .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var miragePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var miragePrimaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
    static var softSmall: SoftButtonStyle { SoftButtonStyle(small: true) }
}
extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// Slider with a gradient fill and a thumb that swells while you drag it.
struct MirageSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// Value at which a small marker is drawn on the track (for example the recommended setting).
    var marker: Double? = nil
    var tint: AnyShapeStyle = AnyShapeStyle(Brand.gradient)

    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    private let thumb: CGFloat = 20

    private var span: Double { max(range.upperBound - range.lowerBound, 0.0001) }
    private func fraction(_ v: Double) -> Double { min(1, max(0, (v - range.lowerBound) / span)) }

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - thumb)
            let x = thumb / 2 + usable * fraction(value)
            let trackHeight: CGFloat = dragging || hovering ? 9 : 7
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12)).frame(height: trackHeight)
                Capsule().fill(tint).frame(width: x, height: trackHeight)
                    .opacity(enabled ? 1 : 0.4)
                if let marker {
                    Capsule().fill(.primary.opacity(0.55))
                        .frame(width: 2, height: trackHeight + 7)
                        .offset(x: thumb / 2 + usable * fraction(marker) - 1)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: dragging ? 7 : 3, y: dragging ? 3 : 1.5)
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(dragging ? 1.22 : hovering ? 1.08 : 1)
                    .offset(x: x - thumb / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    var v = range.lowerBound + span * Double(min(1, max(0, (g.location.x - thumb / 2) / usable)))
                    if step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
                    value = min(range.upperBound, max(range.lowerBound, v))
                }
                .onEnded { _ in dragging = false })
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: value)
            .onHover { hovering = $0 }
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            let delta = step > 0 ? step : span / 20
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? delta : -delta)))
        }
    }
}

/// Segmented control with a highlight that slides between options.
struct SlidingSegments<T: Hashable>: View {
    struct Item { let value: T; let title: String; var symbol: String? = nil }
    let items: [Item]
    @Binding var selection: T
    /// Draw its own glass capsule (for use directly on the window backdrop).
    var glass = true
    @Namespace private var ns

    var body: some View {
        let content = HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol { Image(systemName: symbol).imageScale(.small) }
                        Text(item.title)
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 13).padding(.vertical, 5.5)
                    .background {
                        if selected {
                            Capsule().fill(Brand.gradient)
                                .shadow(color: Brand.violet.opacity(0.45), radius: 7, y: 2)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        if glass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.primary.opacity(0.07), in: Capsule())
        }
    }
}

/// "− 2 +" counter.
struct CountStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.2)) { value = max(range.lowerBound, value - 1) } } label: { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(value <= range.lowerBound)
            Text("\(value)").font(.callout.weight(.semibold)).monospacedDigit().frame(minWidth: 18)
                .contentTransition(.numericText(value: Double(value)))
            Button { withAnimation(.snappy(duration: 0.2)) { value = min(range.upperBound, value + 1) } } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: 24)).disabled(value >= range.upperBound)
        }
    }
}

/// One folder setting: where something is kept, with buttons to change or reveal it.
struct FolderRow: View {
    let title: String
    let symbol: String
    let path: String
    var note: String? = nil
    var busy = false
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 34, height: 34).mirageGradient()
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(note ?? freeSpaceText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Button("Show", systemImage: "folder") {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            .buttonStyle(IconButtonStyle(size: 28)).help("Show in Finder")
            Button("Change…", action: choose).buttonStyle(.soft).disabled(busy)
        }
    }

    private var freeSpaceText: String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        guard let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return "" }
        return "\(Format.bytes(free)) free on this disk"
    }
}

/// Brief message that drops in from the top of the window.
struct ToastView: View {
    let symbol: String
    var tint: Color = .green
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).symbolEffect(.bounce, value: title)
            Text(title).fontWeight(.medium).lineLimit(1)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.miragePrimary)
            }
        }
        .padding(.leading, 16).padding(.trailing, actionTitle == nil ? 16 : 7).padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

/// A labelled switch with the switch at the trailing edge.
struct SwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } }
    }
}
