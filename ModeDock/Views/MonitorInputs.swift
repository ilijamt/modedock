import CoreGraphics
import DisplayKit
import ModeDockCore
import SwiftUI

extension MonitorInputController.Inputs {
    /// DDC only works over the input the monitor shows, so the current one is always this Mac's.
    /// Others get their MCCS name, which some monitors (Samsung) don't follow.
    func name(of input: UInt8) -> String {
        input == current ? String(localized: "This Mac") : DDCPacket.inputName(input)
    }
}

extension MonitorInputController {
    static let switchWarning =
        String(localized: "ModeDock can't switch back. Use the monitor's buttons or the other device.")
}

struct InputChips: View {
    let display: CGDirectDisplayID
    let inputs: MonitorInputController.Inputs
    @Environment(MonitorInputController.self) private var controller
    @State private var confirming: UInt8?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Input").font(.callout)
                Spacer(minLength: 4)
                ForEach(inputs.available, id: \.self) { input in
                    let selected = input == inputs.current
                    Button {
                        if !selected { confirming = input }
                    } label: {
                        Text(inputs.name(of: input))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(selected ? .white : .primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .tip(verbatim: String(format: String(localized: "Input source 0x%02X"), input))
                }
            }
            if let input = confirming {
                InputSwitchConfirmation(name: inputs.name(of: input)) {
                    Task { await controller.select(input, for: display) }
                    confirming = nil
                } onCancel: {
                    confirming = nil
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct InputSwitchConfirmation: View {
    let name: String
    let onSwitch: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch to \(name)?").font(.callout.weight(.medium))
            Text(MonitorInputController.switchWarning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Switch", action: onSwitch).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
