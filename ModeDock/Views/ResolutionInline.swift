import CoreGraphics
import DisplayKit
import ModeDockCore
import SwiftUI

extension DisplayModeController.ScreenModes {
    func option(containing mode: DisplayMode?) -> ResolutionOption? {
        options.first { $0.modes.contains { $0.id == mode?.id } }
    }

    /// Picking a size keeps the current refresh rate when that size offers it, otherwise the highest.
    func mode(for option: ResolutionOption) -> DisplayMode? {
        let rate = current.map { Int($0.refreshRate.rounded()) }
        return option.modes.first { Int($0.refreshRate.rounded()) == rate } ?? option.modes.first
    }
}

/// The resolution list shown inside the panel under a screen's card.
struct ResolutionList: View {
    let display: CGDirectDisplayID
    let screenModes: DisplayModeController.ScreenModes
    let modes: DisplayModeController
    let onPicked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(screenModes.options) { option in
                            row(option).id(option.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear {
                    if let current = screenModes.option(containing: screenModes.current) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }

            if !screenModes.isMain {
                Divider().padding(.vertical, 4)
                Button {
                    modes.makeMain(display)
                    onPicked()
                } label: {
                    Label("Use as Main Screen", systemImage: "menubar.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(6)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(modes.pending != nil)
    }

    private func row(_ option: ResolutionOption) -> some View {
        let isCurrent = option.modes.contains { $0.id == screenModes.current?.id }
        return HStack(spacing: 3) {
            Button {
                if let mode = screenModes.mode(for: option) { select(mode) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .opacity(isCurrent ? 1 : 0)
                    Text(verbatim: "\(option.width) × \(option.height)")
                        .lineLimit(1)
                        .layoutPriority(2)
                    if option.isNative { tag("Native") }
                    if isLowResolution(option) { tag("1x").help("Low resolution: the 1x version of a HiDPI size") }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if option.modes.count > 1 {
                ForEach(option.modes) { mode in
                    let selected = mode.id == screenModes.current?.id
                    Button {
                        select(mode)
                    } label: {
                        Text(verbatim: "\(Int(mode.refreshRate.rounded()))")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(selected ? .white : .secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .layoutPriority(3)
                    .help("\(Int(mode.refreshRate.rounded())) Hz")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isCurrent ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6))
    }

    private func tag(_ text: String) -> some View {
        // Tags give way first when a row is short of space.
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The 1x copy of a size that also exists in HiDPI.
    private func isLowResolution(_ option: ResolutionOption) -> Bool {
        !option.isHiDPI
            && screenModes.options.contains { $0.isHiDPI && $0.width == option.width && $0.height == option.height }
    }

    private func select(_ mode: DisplayMode) {
        modes.select(mode, for: display)
        onPicked()
    }
}

/// "Keep this resolution?" inside the panel, with the countdown to the automatic revert.
struct PendingResolutionStrip: View {
    let change: DisplayModeController.PendingChange
    let modes: DisplayModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep this resolution?").font(.callout.weight(.medium))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(change.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text(
                    verbatim:
                        "Going back to \(change.previous.width) × \(change.previous.height) in \(remaining) s."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Revert") { modes.revert() }
                Button("Keep") { modes.confirm() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
