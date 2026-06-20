import Foundation

public enum PMSet {
    /// Runs `/usr/bin/pmset` and waits for it. Returns false when it exits with an error.
    public static func run(_ arguments: String...) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
