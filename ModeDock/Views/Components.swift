import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Use the system glass material (macOS 26) instead of hand-drawn fills.
    @Entry var useGlass = false
}

private struct Surface<S: Shape>: ViewModifier {
    @Environment(\.useGlass) private var useGlass
    let shape: S
    var tint: Color?
    var interactive = true

    func body(content: Content) -> some View {
        if useGlass, #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content
                .background(.primary.opacity(0.06), in: shape)
                .overlay(shape.stroke(.primary.opacity(0.06)))
        }
    }
}

extension View {
    func surface(_ shape: some Shape, tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(Surface(shape: shape, tint: tint, interactive: interactive))
    }
}

/// A rounded, translucent tile like the ones in Control Center.
struct Card<Content: View>: View {
    /// The glass reacts to presses. Off for cards that are one big button: pressing those while
    /// the panel resized crashed SwiftUI's glass on macOS 26.
    var interactive = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: interactive)
    }
}

/// Round on/off button: filled with the accent colour when on.
struct CircleToggle: View {
    let systemImage: String
    let isOn: Bool
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: size, height: size)
                .surface(Circle(), tint: isOn ? .accentColor : nil)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A compact tile with an icon beside a short label, for one-tap actions. Tinted when on.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var isOn = false
    /// Shown at the right edge, such as the tile's keyboard shortcut.
    var detail: String?
    var detailIsPlaceholder = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Spacer(minLength: 4)
                    Text(verbatim: detail)
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(detailIsPlaceholder ? .tertiary : .secondary)
                }
            }
            .foregroundStyle(isOn ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .surface(RoundedRectangle(cornerRadius: 10, style: .continuous), tint: isOn ? .accentColor : nil)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Tiles in equal columns, for sections with more than fit on one row.
struct TileGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            content
        }
    }
}

/// A small capsule button for picking one of a few options, tinted when chosen.
struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isOn ? .white : .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A controller's last error under a section; nothing when there is none.
struct ErrorLabel: View {
    let message: String?

    init(_ message: String?) {
        self.message = message
    }

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A section with a clickable header that collapses its content.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}

/// The translucent background used by menu-bar popovers.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
