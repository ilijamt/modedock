import SwiftUI

struct MenuView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ModeDock")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            Text("Display controls are coming soon.")
                .foregroundStyle(.secondary)
                .padding(12)

            Divider()

            HStack {
                Button("Settings…", action: onOpenSettings)
                    .keyboardShortcut(",")

                Spacer()

                Button("Quit ModeDock") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 300)
    }
}
