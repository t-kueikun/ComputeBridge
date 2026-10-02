import Foundation
import Network

public final class NetworkPipe: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var pending = Data()
    private let lock = NSLock()
    public var onState: ((NWConnection.State) -> Void)?
    public var onMessage: ((BridgeMessage) -> Void)?

    public init(connection: NWConnection, label: String) {
        self.connection = connection
        self.queue = DispatchQueue(label: label)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.onState?(state) }
        connection.start(queue: queue)
        receiveNext()
    }

    public func send(_ message: BridgeMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    public func cancel() { connection.cancel() }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if !isComplete && error == nil { self.receiveNext() }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        pending.append(data)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            messages.append(pending.prefix(upTo: newline))
            pending.removeSubrange(...newline)
        }
        lock.unlock()
        for line in messages {
            if let message = try? JSONDecoder().decode(BridgeMessage.self, from: line) { onMessage?(message) }
        }
    }
}
