import AppKit
import ModeDockCore
import SwiftUI

/// Which profiles the Next Profile shortcut goes through.
enum ProfileCycleScope: String, CaseIterable, Identifiable {
    case connected, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connected: "Profiles for the connected screens"
        case .all: "All profiles"
        }
    }

    static var current: ProfileCycleScope {
        UserDefaults.standard.string(forKey: SettingsKey.profileCycleScope).flatMap(Self.init(rawValue:)) ?? .connected
    }
}

/// The Next Profile shortcut: a window listing the profiles it cycles through. Each press moves
/// to the next one, and the highlighted profile is applied once the presses stop.
@MainActor
final class ProfileSwitcher {
    /// Long enough to press again, short enough to feel like the press did it.
    private static let applyDelay = Duration.milliseconds(1100)

    @Observable
    @MainActor
    final class Model {
        var candidates: [DisplayProfile] = []
        var selected = 0
        var current: DisplayProfile.ID?
        var applying = false
    }

    private let profiles: ProfileController
    private let screens: ScreenController
    private let modes: DisplayModeController
    private let hud: ShortcutHUD
    private let model = Model()
    private let panel: FloatingPanel = {
        let panel = FloatingPanel(level: .popUpMenu)
        panel.ignoresMouseEvents = true
        return panel
    }()
    private var applyTask: Task<Void, Never>?

    init(profiles: ProfileController, screens: ScreenController, modes: DisplayModeController, hud: ShortcutHUD) {
        self.profiles = profiles
        self.screens = screens
        self.modes = modes
        self.hud = hud
    }

    func next() {
        guard profiles.applying == nil, !model.applying else { return }
        if panel.isVisible {
            model.selected = (model.selected + 1) % model.candidates.count
        } else if !open() {
            return
        }
        scheduleApply()
    }

    /// Fills the list and shows the window, with the profile after the current one selected.
    private func open() -> Bool {
        modes.refresh(
            displays: screens.screens.map(\.display),
            showAllModes: UserDefaults.standard.bool(forKey: SettingsKey.showAllModes))
        let scope = ProfileCycleScope.current
        let candidates = profiles.profiles.filter { scope == .all || profiles.fitsConnectedScreens($0) }
        guard !candidates.isEmpty else {
            hud.show(
                profiles.profiles.isEmpty ? "No profiles saved" : "No profiles for these screens",
                systemImage: "rectangle.3.group")
            return false
        }
        let current = candidates.firstIndex { $0.id == profiles.currentProfile?.id }
        model.candidates = candidates
        model.current = current.map { candidates[$0].id }
        model.selected = current.map { ($0 + 1) % candidates.count } ?? 0
        model.applying = false

        // Sized once; the rows don't change while it's open.
        let content = NSHostingView(
            rootView: ProfileSwitcherView(model: model, scope: scope)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        content.sizingOptions = []
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.setContentSize(size)
        if let screen = NSScreen.underMouse ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        return true
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: Self.applyDelay)
            guard !Task.isCancelled else { return }
            let profile = model.candidates[model.selected]
            model.applying = true
            await profiles.apply(profile)
            panel.orderOut(nil)
            model.applying = false
            if let error = profiles.lastError { hud.show(error, systemImage: "exclamationmark.triangle.fill") }
        }
    }
}

private struct ProfileSwitcherView: View {
    let model: ProfileSwitcher.Model
    let scope: ProfileCycleScope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Text(scope == .all ? "All profiles" : "For these screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, profile in
                    row(profile, isSelected: index == model.selected)
                }
            }

            Text(model.applying ? "Applying…" : "Press again for the next one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(_ profile: DisplayProfile, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.id == model.current ? "checkmark.circle.fill" : "rectangle.3.group")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if profile.id == model.current {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.12), in: Capsule())
                    }
                }
                if profile.mirroring || profile.autoApply {
                    Text(verbatim: profile.summary).font(.caption)
                }
                ProfileScreenLines(profile: profile)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            if let shortcut = profile.shortcutText {
                Text(verbatim: shortcut)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
