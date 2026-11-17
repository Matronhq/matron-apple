import Foundation

/// The first value `stream` yields within `seconds`, or nil: a missing value
/// fails the test instead of hanging it until the runner gives up.
func firstValue<T: Sendable>(of stream: AsyncStream<T>, within seconds: Double = 5) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
