import CoreGraphics
import Foundation
import os

/// Calls `onChange` once after displays are connected, disconnected, enabled or reconfigured.
/// CoreGraphics sends a burst of callbacks per change, so they are coalesced.
@MainActor
public final class DisplayObserver {
    private let onChange: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Must be called before the observer is released.
    public func stop() {
        pending?.cancel()
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        Logger(subsystem: "com.matoski.modedock", category: "screens")
            .info("reconfiguration display=\(display, privacy: .public) flags=\(flags.rawValue, privacy: .public)")
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let observer = Unmanaged<DisplayObserver>.fromOpaque(userInfo).takeUnretainedValue()
        // CoreGraphics delivers these on the main run loop for callbacks registered there.
        MainActor.assumeIsolated { observer.schedule() }
    }
}
