@MainActor
func errorMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

@MainActor
func errorMessage(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return error.localizedDescription
    }
}
