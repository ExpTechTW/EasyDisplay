/// Sends only the newest value when updates (a dragged slider) arrive faster than the
/// device accepts them.
@MainActor
final class LatestValueWriter<Value: Sendable> {
    private let write: @Sendable (Value) async -> Void
    private var pending: Value?
    private(set) var isBusy = false

    init(_ write: @escaping @Sendable (Value) async -> Void) {
        self.write = write
    }

    func submit(_ value: Value) {
        pending = value
        guard !isBusy else { return }
        isBusy = true
        Task {
            while let next = pending {
                pending = nil
                await write(next)
            }
            isBusy = false
        }
    }
}
