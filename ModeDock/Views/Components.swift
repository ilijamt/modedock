import AppKit
import SwiftUI

extension EnvironmentValues {
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

    /// System Settings doesn't tell apps when a permission changes, so it's checked every 2 seconds.
    func pollingPermissions(_ check: @escaping @MainActor () async -> Void) -> some View {
        task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

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

struct ActionTile: View {
    let title: String
    let systemImage: String
    var isOn: Bool?
    var detail: String?
    var detailIsPlaceholder = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isOn == nil ? 5 : 6) {
                icon
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Spacer(minLength: 4)
                    Text(verbatim: detail)
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(detailIsPlaceholder ? .tertiary : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: isOn == nil ? .center : .leading)
            .padding(.horizontal, isOn == nil ? 10 : 6)
            .padding(.vertical, isOn == nil ? 9 : 5)
            .surface(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn.map { $0 ? Text("On") : Text("Off") } ?? Text(verbatim: ""))
    }

    @ViewBuilder private var icon: some View {
        if let isOn {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: 24, height: 24)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.1)), in: Circle())
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
        }
    }
}

struct TileGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            content
        }
    }
}

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
