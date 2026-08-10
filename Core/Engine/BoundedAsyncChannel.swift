import Foundation

/// Small suspending channel used between one source reader and each
/// destination writer. Its hard capacity bounds memory; closing a failed
/// writer releases any producer waiting behind it.
actor BoundedAsyncChannel<Element: Sendable> {
    private let capacity: Int
    private var buffer: [Element] = []
    private var receivers: [CheckedContinuation<Element?, Never>] = []
    private var senders: [(Element, CheckedContinuation<Bool, Never>)] = []
    private var isFinished = false
    private var isClosed = false

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func send(_ element: Element) async -> Bool {
        guard !isFinished, !isClosed else { return false }
        if !receivers.isEmpty {
            receivers.removeFirst().resume(returning: element)
            return true
        }
        if buffer.count < capacity {
            buffer.append(element)
            return true
        }
        return await withCheckedContinuation { continuation in
            senders.append((element, continuation))
        }
    }

    func next() async -> Element? {
        if !buffer.isEmpty {
            let value = buffer.removeFirst()
            admitWaitingSender()
            return value
        }
        if !senders.isEmpty, !isClosed {
            let (value, sender) = senders.removeFirst()
            sender.resume(returning: true)
            return value
        }
        if isFinished || isClosed { return nil }
        return await withCheckedContinuation { continuation in
            receivers.append(continuation)
        }
    }

    /// Drain already-buffered chunks, then end.
    func finish() {
        guard !isFinished, !isClosed else { return }
        isFinished = true
        for (_, sender) in senders { sender.resume(returning: false) }
        senders.removeAll()
        if buffer.isEmpty {
            for receiver in receivers { receiver.resume(returning: nil) }
            receivers.removeAll()
        }
    }

    /// Writer failure/cancellation: discard queued work and unblock everyone.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        buffer.removeAll()
        for (_, sender) in senders { sender.resume(returning: false) }
        senders.removeAll()
        for receiver in receivers { receiver.resume(returning: nil) }
        receivers.removeAll()
    }

    private func admitWaitingSender() {
        guard !senders.isEmpty, !isFinished, !isClosed else {
            if buffer.isEmpty, isFinished {
                for receiver in receivers { receiver.resume(returning: nil) }
                receivers.removeAll()
            }
            return
        }
        let (element, sender) = senders.removeFirst()
        buffer.append(element)
        sender.resume(returning: true)
    }
}
