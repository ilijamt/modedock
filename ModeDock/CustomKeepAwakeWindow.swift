import AppKit
import ModeDockCore
import SwiftUI

/// Asks for a Keep Awake duration that isn't one of the presets: typed ("1h30", "90m") or as a
/// time of day to stay awake until.
@MainActor
final class CustomKeepAwakeWindow {
    static let shared = CustomKeepAwakeWindow()

    private var panel: PromptPanel?

    func show(power: PowerController) {
        close()
        let panel = PromptPanel()
        panel.setContent(CustomKeepAwakeView(power: power) { [weak self] in self?.close() }, cornerRadius: 14)
        self.panel = panel

        // Lay out first so the panel has its final size before it's centered.
        panel.layoutIfNeeded()
        panel.center(on: NSScreen.underMouse ?? NSScreen.main)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The Menu style's window around the custom duration editor; the other styles show it inline.
private struct CustomKeepAwakeView: View {
    let power: PowerController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep Awake").font(.headline)
            CustomKeepAwakeEditor(power: power, onDone: onClose)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

/// A custom Keep Awake duration: typed ("1h30", "90m") or a time of day to stay awake until.
struct CustomKeepAwakeEditor: View {
    enum Mode: Hashable { case duration, until }

    let power: PowerController
    /// Called after starting, and on Esc.
    let onDone: () -> Void

    @State private var mode = Mode.duration
    @State private var text = KeepAwakeSettings.lastCustomMinutes.map { PowerController.title(minutes: $0) } ?? ""
    @State private var until = Date().addingTimeInterval(3600)
    @FocusState private var fieldFocused: Bool

    private var minutes: Int? {
        switch mode {
        case .duration: PowerController.minutes(from: text)
        case .until: PowerController.minutes(until: until)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Mode", selection: $mode) {
                    Text("For").tag(Mode.duration)
                    Text("Until").tag(Mode.until)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch mode {
                case .duration:
                    TextField("90m, 2h, 1h30", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(start)
                case .until:
                    DatePicker("Until", selection: $until, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }

                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(minutes == nil)
            }

            Text(verbatim: preview)
                .font(.caption)
                .foregroundStyle(minutes == nil && !text.isEmpty ? .orange : .secondary)
                .monospacedDigit()
        }
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: onDone)
    }

    private var preview: String {
        guard let minutes else {
            return text.isEmpty ? "Type a duration, like 45m or 1h30." : "That isn't a duration ModeDock understands."
        }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let day: Date.FormatStyle.DateStyle = Calendar.current.isDateInToday(end) ? .omitted : .abbreviated
        return "\(PowerController.title(minutes: minutes)) · ends at \(end.formatted(date: day, time: .shortened))"
    }

    private func start() {
        guard let minutes else { return }
        if mode == .duration { KeepAwakeSettings.lastCustomMinutes = minutes }
        KeepAwakeSettings.start(minutes: minutes, power: power)
        onDone()
    }
}
