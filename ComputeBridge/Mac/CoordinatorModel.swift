import Foundation
import Network
import SwiftUI
import Darwin

struct WorkerRow: Identifiable {
    var id: String
    var capabilities: WorkerCapabilities
    var status: String
}

struct BenchmarkRecord: Identifiable {
    let id = UUID()
    let mode: String
    let iterations: UInt64
    let duration: Double
    let estimate: Double
    let speedup: Double?
    let details: String
}

@MainActor
final class CoordinatorModel: ObservableObject {
    @Published var workers: [WorkerRow] = []
    @Published var isSearching = false
    @Published var status = "Searching for workers"
    @Published var usbHost = "172.20.10.1"
    @Published var iterations = 10_000_000.0
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var latestResult: PiResult?
    @Published var benchmarks: [BenchmarkRecord] = []
    @Published var errorMessage: String?
    @Published var macCPU = 0.0
    @Published var memoryUsedGB = 0.0
    @Published var memoryTotalGB = 0.0
    @Published var jsSource = "console.log(\"Hello from ComputeBridge iPhone Worker\");"
    @Published var jsOutput = "No JavaScript run yet."
    @Published var workerHTTPURL: String?
    @Published var isRunningJavaScript = false
    @Published var selectedJSWorkerID: String?
    @Published var nextFolder: URL?
    @Published var nextHost = ""
    @Published var nextToken = ""
    @Published var nextStatus = "Choose a Next.js 15 or 16 project and enter the address shown on iPhone."
    @Published var isSyncingNext = false

    private var browser: NWBrowser?
    private var pipes: [String: NetworkPipe] = [:]
    private var workerEndpoints: [String: NWEndpoint] = [:]
    private var pendingJobs: [UUID: CheckedContinuation<PiResult, Error>] = [:]
    private var pendingJobTimeouts: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTimer: Timer?
    private var previousCPU: (user: UInt64, system: UInt64, idle: UInt64)?
    private let workerPort = NWEndpoint.Port(rawValue: 43182)!
    private var nextProcess: Process?
    private var nextPipe: Pipe?
    private var nextFolderAccessed = false

    var nextSiteURL: URL? {
        let input = nextHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = URLComponents(string: input.contains("://") ? input : "http://" + input)
        guard let host = components?.host else { return nil }
        return URL(string: "http://\(host):3001")
    }

    init() {
        startBrowsing()
        refreshResources()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshResources(); self?.sendHeartbeats() }
        }
    }

    func startNextOnIPhone() {
        guard !isSyncingNext else { return }
        guard let folder = nextFolder else { nextStatus = "Choose a project folder first."; return }
        let host = nextHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = nextToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else {
            nextStatus = "Enter the iPhone address and pairing token."
            return
        }
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scripts/send-next-project.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            nextStatus = "The project transfer script is missing from the Mac app."
            return
        }
        nextFolderAccessed = folder.startAccessingSecurityScopedResource()
        let developerDirectories = [
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-beta.app/Contents/Developer",
            "/Library/Developer/CommandLineTools"
        ].compactMap { $0 }
        guard let pythonPath = developerDirectories
            .map({ $0 + "/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            nextStatus = "Python 3 from Xcode or Command Line Tools was not found."
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [script.path, folder.path, "--host", host]
        var environment = ProcessInfo.processInfo.environment
        environment["COMPUTEBRIDGE_PAIRING_TOKEN"] = token
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.nextStatus = output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.nextPipe?.fileHandleForReading.readabilityHandler = nil
                self?.nextPipe = nil
                self?.nextProcess = nil
                self?.isSyncingNext = false
                if self?.nextFolderAccessed == true {
                    self?.nextFolder?.stopAccessingSecurityScopedResource()
                    self?.nextFolderAccessed = false
                }
                if finished.terminationStatus != 0 {
                    self?.nextStatus += "\nTransfer stopped with code \(finished.terminationStatus)."
                }
            }
        }
        do {
            try process.run()
            nextProcess = process
            nextPipe = pipe
            isSyncingNext = true
            nextStatus = "Preparing project transfer…"
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            if nextFolderAccessed { folder.stopAccessingSecurityScopedResource() }
            nextFolderAccessed = false
            nextStatus = "Could not start transfer: \(error.localizedDescription)"
        }
    }

    func stopNextSync() {
        nextProcess?.terminate()
        nextStatus = "Stopping source sync…"
    }

    func startBrowsing() {
        guard browser == nil else { return }
        isSearching = true
        status = "Searching for workers"
        let browser = NWBrowser(for: .bonjour(type: "_computebridge._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state { self?.errorMessage = error.localizedDescription }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.updateResults(results) }
        }
        browser.start(queue: .main)
    }

    private func updateResults(_ results: Set<NWBrowser.Result>) {
        isSearching = true
        for result in results {
            let key = String(describing: result.endpoint)
            guard pipes[key] == nil else { continue }
            workerEndpoints[key] = result.endpoint
            attach(NWConnection(to: result.endpoint, using: .tcp), key: key)
        }
        let current = Set(results.map { String(describing: $0.endpoint) })
        for key in Array(workerEndpoints.keys) where !current.contains(key) { removeWorker(key) }
        status = workers.isEmpty ? "Searching for workers" : "\(workers.count) worker\(workers.count == 1 ? "" : "s") ready"
    }

    func connectViaUSB() {
        let host = usbHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "Enter the iPhone USB network address."
            return
        }
        let key = "wired:\(host)"
        guard pipes[key] == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wiredEthernet
        let connection = NWConnection(host: NWEndpoint.Host(host), port: workerPort, using: parameters)
        attach(connection, key: key)
        status = "Connecting over USB"
    }

    func connectViaIP() {
        let host = usbHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "Enter the iPhone network address."
            return
        }
        let key = "ip:\(host)"
        guard pipes[key] == nil else { return }
        attach(NWConnection(host: NWEndpoint.Host(host), port: workerPort, using: .tcp), key: key)
        status = "Connecting to worker at \(host)"
    }

    private func attach(_ connection: NWConnection, key: String) {
        let pipe = NetworkPipe(connection: connection, label: "bridge.worker.\(key.hashValue)")
        pipes[key] = pipe
        pipe.onState = { [weak self, weak pipe] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state { pipe?.send(BridgeMessage(kind: .hello, deviceName: Host.current().localizedName ?? "Mac")) }
                if case .failed = state { self.removeWorker(key) }
                if case .cancelled = state { self.removeWorker(key) }
            }
        }
        pipe.onMessage = { [weak self] message in Task { @MainActor in self?.handle(message, from: key) } }
        pipe.start()
    }

    private func removeWorker(_ key: String) {
        pipes.removeValue(forKey: key)?.cancel()
        workerEndpoints.removeValue(forKey: key)
        workers.removeAll { $0.id == key }
        if selectedJSWorkerID == key { selectedJSWorkerID = workers.first?.id }
        if workers.isEmpty { workerHTTPURL = nil }
        if isRunningJavaScript {
            isRunningJavaScript = false
            pendingJSRequestID = nil
            jsOutput = "Worker disconnected before the JavaScript result arrived."
        }
        let interrupted = Array(pendingJobs.values)
        pendingJobs.removeAll()
        pendingJobTimeouts.values.forEach { $0.cancel() }
        pendingJobTimeouts.removeAll()
        for continuation in interrupted { continuation.resume(throwing: BridgeError.disconnected) }
        status = workers.isEmpty ? "Searching for workers" : "\(workers.count) workers ready"
    }

    private func handle(_ message: BridgeMessage, from key: String) {
        switch message.kind {
        case .capabilities:
            if let caps = message.capabilities {
                if let i = workers.firstIndex(where: { $0.id == key }) { workers[i].capabilities = caps; workers[i].status = "Ready" }
                else { workers.append(WorkerRow(id: key, capabilities: caps, status: "Ready")) }
                if selectedJSWorkerID == nil { selectedJSWorkerID = key }
                if let url = caps.httpURL { workerHTTPURL = url }
                status = "\(workers.count) worker\(workers.count == 1 ? "" : "s") ready"
            }
        case .jobResult:
            if let result = message.result, let continuation = pendingJobs.removeValue(forKey: result.jobID) {
                pendingJobTimeouts.removeValue(forKey: result.jobID)?.cancel()
                continuation.resume(returning: result)
            }
        case .jobFailed:
            if let id = message.jobID, let continuation = pendingJobs.removeValue(forKey: id) {
                pendingJobTimeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: BridgeError.failed(message.error ?? "Worker failed the job"))
            } else {
                errorMessage = message.error ?? "Worker failed the job"
            }
        case .jsResult:
            isRunningJavaScript = false
            pendingJSRequestID = nil
            jsOutput = message.error.map { "JavaScript error: \($0)" } ?? (message.output?.isEmpty == false ? message.output! : "(no console output)")
        default: break
        }
    }

    private var pendingJSRequestID: UUID?

    func runJavaScript() {
        guard !isRunningJavaScript else { return }
        guard let worker = workers.first(where: { $0.id == selectedJSWorkerID }) ?? workers.first,
              let pipe = pipes[worker.id] else {
            jsOutput = "Connect an iPhone Worker first."
            return
        }
        let requestID = UUID()
        pendingJSRequestID = requestID
        isRunningJavaScript = true
        jsOutput = "Running on \(worker.capabilities.name)…"
        pipe.send(BridgeMessage(kind: .runJS, requestID: requestID, script: jsSource))
    }


    private func sendHeartbeats() { for pipe in pipes.values { pipe.send(BridgeMessage(kind: .heartbeat)) } }

    func runLocal() { runBenchmark(mode: .local) }
    func runWorker() { runBenchmark(mode: .worker) }
    func runDistributed() { runBenchmark(mode: .distributed) }

    private enum BenchmarkMode { case local, worker, distributed }

    private func runBenchmark(mode: BenchmarkMode) {
        guard !isRunning else { return }
        if mode != .local && workers.isEmpty { errorMessage = "No worker is connected. Open ComputeBridge Worker on your iPhone and keep it in the foreground."; return }
        isRunning = true
        progress = 0
        errorMessage = nil
        let count = UInt64(max(10_000, min(iterations, 200_000_000)))
        let start = ContinuousClock.now
        Task {
            do {
                let result: PiResult
                var details = ""
                switch mode {
                case .local:
                    result = await Task.detached(priority: .userInitiated) { PiComputer.run(ComputeJob(iterations: count)) }.value
                    details = "Mac only"
                case .worker:
                    let worker = workers[0]
                    guard let pipe = pipes[worker.id] else { throw BridgeError.disconnected }
                    result = try await submit(ComputeJob(iterations: count), via: pipe)
                    details = worker.capabilities.name
                case .distributed:
                    result = try await runSplit(iterations: count)
                    details = "Mac + \(workers.count) worker\(workers.count == 1 ? "" : "s")"
                }
                let elapsed = durationSeconds(start.duration(to: .now))
                latestResult = result
                let baseline = benchmarks.first(where: { $0.mode == "Mac only" && $0.iterations == result.iterations })?.duration
                benchmarks.insert(BenchmarkRecord(mode: label(mode), iterations: result.iterations, duration: elapsed, estimate: result.estimate,
                                                   speedup: baseline.map { $0 / elapsed }, details: details), at: 0)
                progress = 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func runSplit(iterations count: UInt64) async throws -> PiResult {
        let selected = workers.compactMap { row -> (WorkerRow, NetworkPipe)? in pipes[row.id].map { (row, $0) } }
        guard !selected.isEmpty else { throw BridgeError.disconnected }
        let macWeight = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let workerWeights = selected.map { max(1, $0.0.capabilities.cpuCores) }
        let totalWeight = UInt64(macWeight + workerWeights.reduce(0, +))
        let macCount = count * UInt64(macWeight) / totalWeight
        let jobID = UUID()
        let localJob = ComputeJob(iterations: max(1, macCount), seed: 0xCB_2026_09_30)
        var workerJobs: [(NetworkPipe, ComputeJob)] = []
        var assigned = macCount
        for (index, pair) in selected.enumerated() {
            let part = index == selected.count - 1 ? count - assigned : count * UInt64(workerWeights[index]) / totalWeight
            assigned += part
            workerJobs.append((pair.1, ComputeJob(iterations: max(1, part), seed: UInt64(index + 2) &* 0x9E3779B97F4A7C15)))
        }
        let localTask = Task.detached(priority: .userInitiated) { PiComputer.run(localJob) }
        let remoteTasks = try await withThrowingTaskGroup(of: PiResult.self) { group in
            for (pipe, job) in workerJobs { group.addTask { try await self.submit(job, via: pipe) } }
            var results: [PiResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        let local = await localTask.value
        let hits = local.hits + remoteTasks.reduce(0) { $0 + $1.hits }
        let actualIterations = local.iterations + remoteTasks.reduce(0) { $0 + $1.iterations }
        return PiResult(jobID: jobID, iterations: actualIterations, hits: hits, elapsedSeconds: 0)
    }

    private func submit(_ job: ComputeJob, via pipe: NetworkPipe) async throws -> PiResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PiResult, Error>) in
            pendingJobs[job.id] = continuation
            pendingJobTimeouts[job.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled, let self,
                      let continuation = self.pendingJobs.removeValue(forKey: job.id) else { return }
                self.pendingJobTimeouts.removeValue(forKey: job.id)
                continuation.resume(throwing: BridgeError.timeout)
            }
            pipe.send(BridgeMessage(kind: .job, job: job))
        }
    }

    private func label(_ mode: BenchmarkMode) -> String {
        switch mode { case .local: "Mac only"; case .worker: "iPhone only"; case .distributed: "Distributed" }
    }

    private func refreshResources() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var load = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &load) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size) } }
        if result == KERN_SUCCESS {
            let user = UInt64(load.cpu_ticks.0 + load.cpu_ticks.1)
            let system = UInt64(load.cpu_ticks.2)
            let idle = UInt64(load.cpu_ticks.3)
            if let previousCPU {
                let userDelta = user &- previousCPU.user
                let systemDelta = system &- previousCPU.system
                let idleDelta = idle &- previousCPU.idle
                let total = userDelta + systemDelta + idleDelta
                if total > 0 { macCPU = min(100, max(0, 100 * (1 - Double(idleDelta) / Double(total)))) }
            }
            previousCPU = (user, system, idle)
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &stats) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        if vmResult == KERN_SUCCESS {
            let page = Double(sysconf(Int32(_SC_PAGESIZE)))
            memoryUsedGB = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page / 1_073_741_824
            memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        }
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

enum BridgeError: LocalizedError {
    case disconnected
    case timeout
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .disconnected: "Worker disconnected"
        case .timeout: "Worker did not return the result within 3 minutes"
        case .failed(let value): value
        }
    }
}
