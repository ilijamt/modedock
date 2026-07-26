import SwiftUI

/// One Settings page in the classic Mac layout: labels right-aligned on the left, controls
/// lined up on the right, and no scrolling.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            // An empty row as wide as the widest label, so the labels end at the same place on
            // every tab and the controls don't move sideways when switching tabs. Longer labels
            // (in some languages) still widen it.
            LabeledContent {
                EmptyView()
            } label: {
                Color.clear.frame(width: Self.labelWidth, height: 0)
            }
            .accessibilityHidden(true)
            content
        }
        .formStyle(.columns)
        .fixedSize()
        .padding(.leading, Self.leading)
        // The sizing row adds its own row spacing at the top.
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(width: SettingsPage.width, alignment: .leading)
    }

    static var width: CGFloat { 600 }
    static var labelWidth: CGFloat { 120 }
    static var leading: CGFloat { 56 }
}

/// A short explanation under a control, in the controls' column.
struct SettingsNote: View {
    let text: LocalizedStringKey
    var width: CGFloat = 340

    init(_ text: LocalizedStringKey, width: CGFloat = 340) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            // A fixed width so the form measures how many lines it wraps to; a maximum width
            // made the window too short for the longer notes.
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Space between groups of settings on a page, as in classic Mac settings windows.
struct SettingsGap: View {
    var body: some View {
        Color.clear.frame(height: 10)
    }
}

/// Tabs within a Settings tab, shown as a segmented control at the top, like iTerm2's.
struct SettingsSubTabs<Tab: Hashable & Identifiable, Content: View>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    @ViewBuilder var content: (Tab) -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(tabs) { Text(verbatim: title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 20)
            content(selection)
        }
        .frame(width: SettingsPage<EmptyView>.width)
    }
}

extension RawRepresentable where RawValue == String {
    /// The sub-tab named by `-settingsSubTab` on the command line, for screenshots.
    init?(launchArgument: Bool) {
        guard let name = UserDefaults.standard.string(forKey: "settingsSubTab") else { return nil }
        self.init(rawValue: name)
    }
}
