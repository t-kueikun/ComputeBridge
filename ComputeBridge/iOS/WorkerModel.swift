import Foundation
import Network
import SwiftUI
import UIKit
@preconcurrency import JavaScriptCore

@MainActor
final class WorkerModel: ObservableObject {
    @Published var status = "Starting worker…"
    @Published var connectedMac = ""
    @Published var completedJobs = 0
    @Published var thermalState = "Normal"
    @Published var batteryLevel: Float = -1
    @Published var isCharging = false
    @Published var recentJob = "Waiting for a job"
    @Published var httpURL = "Starting HTTP server…"
    @Published var httpServerReady = false

    private var listener: NWListener?
    private var httpServer: WorkerHTTPServer?
    private var pipe: NetworkPipe?
    private var batteryTimer: Timer?
    private var didStart = false
    private let listenerQueue = DispatchQueue(label: "bridge.worker.listener")
    private let workerID = UUID().uuidString

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshDeviceState()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        startListener()
        startHTTPServer()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDeviceState(); self?.sendCapabilities() }
        }
    }

    private func startListener() {
        do {
            let port = NWEndpoint.Port(rawValue: 43182)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.service = NWListener.Service(name: UIDevice.current.name, type: "_computebridge._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "Ready for jobs"
                    case .failed(let error): self?.status = "Network error: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: listenerQueue)
        } catch { status = "Could not start worker: \(error.localizedDescription)" }
    }

    private func accept(_ connection: NWConnection) {
        pipe?.cancel()
        let pipe = NetworkPipe(connection: connection, label: "bridge.mac")
        self.pipe = pipe
        pipe.onState = { [weak self, weak pipe] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state { self.status = "Connected · Ready"; self.sendCapabilities() }
                if case .failed = state, let pipe { self.disconnect(pipe) }
                if case .cancelled = state, let pipe { self.disconnect(pipe) }
                _ = pipe
            }
        }
        pipe.onMessage = { [weak self] message in Task { @MainActor in self?.handle(message) } }
        pipe.start()
    }

    private func disconnect(_ connection: NetworkPipe) {
        guard pipe === connection else { return }
        pipe = nil
        connectedMac = ""
        status = "Ready for jobs"
    }

    private func handle(_ message: BridgeMessage) {
        switch message.kind {
        case .hello:
            connectedMac = message.deviceName ?? "Mac"
            status = "Connected · Ready"
            sendCapabilities()
        case .heartbeat:
            sendCapabilities()
        case .job:
            guard let job = message.job else { return }
            status = "Computing…"
            recentJob = "Monte Carlo π · \(job.iterations.formatted()) samples"
            pipe?.send(BridgeMessage(kind: .jobAccepted, jobID: job.id))
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = PiComputer.run(job)
                await MainActor.run {
                    self?.completedJobs += 1
                    self?.status = "Connected · Ready"
                    self?.recentJob = "π ≈ \(result.estimate.formatted(.number.precision(.fractionLength(6)))) · \(result.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s"
                    self?.pipe?.send(BridgeMessage(kind: .jobResult, result: result, jobID: job.id))
                }
            }
        case .runJS:
            guard let script = message.script, let requestID = message.requestID else { return }
            status = "Running JavaScript…"
            recentJob = "JavaScript · (script.prefix(50))"
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = WorkerJavaScriptRuntime.evaluate(script)
                await MainActor.run {
                    guard let self else { return }
                    self.status = "Connected · Ready"
                    self.recentJob = "JavaScript finished"
                    self.pipe?.send(BridgeMessage(kind: .jsResult, error: result.error,
                                                  requestID: requestID, output: result.output))
                }
            }
        case .cancelJob:
            status = "Connected · Ready"
        default: break
        }
    }

    private func refreshDeviceState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "Normal"
        case .fair: thermalState = "Fair"
        case .serious: thermalState = "Serious"
        case .critical: thermalState = "Critical"
        @unknown default: thermalState = "Unknown"
        }
        batteryLevel = UIDevice.current.batteryLevel
        isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    private func sendCapabilities() {
        let arch = "arm64"
        let capability = WorkerCapabilities(id: workerID, name: UIDevice.current.name, architecture: arch,
            cpuCores: ProcessInfo.processInfo.activeProcessorCount, thermalState: thermalState,
            batteryLevel: batteryLevel >= 0 ? Double(batteryLevel) : nil, isCharging: isCharging,
            httpURL: httpServerReady ? httpURL : nil)
        pipe?.send(BridgeMessage(kind: .capabilities, deviceName: capability.name, capabilities: capability))
    }

    private func startHTTPServer() {
        do {
            let server = try WorkerHTTPServer(port: 3000, name: UIDevice.current.name)
            httpServer = server
            server.onState = { [weak self] ready in
                Task { @MainActor in
                    guard let self else { return }
                    self.httpServerReady = ready
                    self.httpURL = WorkerHTTPServer.localURL ?? "http://iphone.local:3000"
                    self.sendCapabilities()
                }
            }
            server.start()
        } catch {
            status = "HTTP server error: \(error.localizedDescription)"
        }
    }
}

private enum WorkerJavaScriptRuntime {
    static func evaluate(_ script: String) -> (output: String, error: String?) {
        guard let context = JSContext() else { return ("", "Could not create JavaScriptCore context") }
        context.evaluateScript("var __bridgeLogs = []; var console = { log: function(...v) { __bridgeLogs.push(v.join(' ')); }, error: function(...v) { __bridgeLogs.push(v.join(' ')); }, warn: function(...v) { __bridgeLogs.push(v.join(' ')); } };")
        var exceptionText: String?
        context.exceptionHandler = { _, exception in exceptionText = exception?.toString() }
        _ = context.evaluateScript(script, withSourceURL: URL(string: "computebridge://worker/script.js"))
        let logs = (context.objectForKeyedSubscript("__bridgeLogs")?.toArray() as? [String]) ?? []
        return (logs.joined(separator: "\n"), exceptionText)
    }
}

private final class WorkerHTTPServer: @unchecked Sendable {
    static var localURL: String? { deviceIPv4Addresses().first.map { "http://\($0):3000" } }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "bridge.worker.http")
    var onState: (@Sendable (Bool) -> Void)?

    init(port: UInt16, name: String) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: name, type: "_http._tcp")
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(true)
            case .failed, .cancelled: self?.onState?(false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, error in
            guard error == nil else { connection.cancel(); return }
            let body = "Hello from ComputeBridge Worker\n"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func deviceIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var preferred: [String] = []
        var other: [String] = []
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let value = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if String(cString: current.pointee.ifa_name).hasPrefix("en0") { preferred.append(value) }
            else { other.append(value) }
        }
        return preferred + other
    }
}
