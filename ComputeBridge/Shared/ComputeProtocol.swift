import Foundation

public enum MessageKind: String, Codable, Sendable {
    case hello, capabilities, heartbeat
    case job, jobAccepted, jobProgress, jobResult, jobFailed, cancelJob
    case runJS, jsResult
}

public struct WorkerCapabilities: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let architecture: String
    public let cpuCores: Int
    public let thermalState: String
    public let batteryLevel: Double?
    public let isCharging: Bool?
    public let gpuAvailable: Bool
    public let httpURL: String?

    public init(id: String = UUID().uuidString, name: String, architecture: String, cpuCores: Int,
                thermalState: String = "unknown", batteryLevel: Double? = nil,
                isCharging: Bool? = nil, gpuAvailable: Bool = true, httpURL: String? = nil) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.cpuCores = cpuCores
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.gpuAvailable = gpuAvailable
        self.httpURL = httpURL
    }
}

public struct ComputeJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: String
    public let iterations: UInt64
    public let seed: UInt64
    public let createdAt: Date

    public init(id: UUID = UUID(), iterations: UInt64, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        self.id = id
        self.type = "monteCarloPi"
        self.iterations = iterations
        self.seed = seed
        self.createdAt = Date()
    }
}

public struct PiResult: Codable, Sendable {
    public let jobID: UUID
    public let iterations: UInt64
    public let hits: UInt64
    public let elapsedSeconds: Double
    public var estimate: Double { 4.0 * Double(hits) / Double(iterations) }
}

public struct BridgeMessage: Codable, Sendable {
    public var kind: MessageKind
    public var deviceName: String?
    public var capabilities: WorkerCapabilities?
    public var job: ComputeJob?
    public var result: PiResult?
    public var jobID: UUID?
    public var error: String?
    public var requestID: UUID?
    public var script: String?
    public var output: String?

    public init(kind: MessageKind, deviceName: String? = nil, capabilities: WorkerCapabilities? = nil,
                job: ComputeJob? = nil, result: PiResult? = nil, jobID: UUID? = nil, error: String? = nil,
                requestID: UUID? = nil, script: String? = nil, output: String? = nil) {
        self.kind = kind
        self.deviceName = deviceName
        self.capabilities = capabilities
        self.job = job
        self.result = result
        self.jobID = jobID
        self.error = error
        self.requestID = requestID
        self.script = script
        self.output = output
    }
}

public enum PiComputer {
    public static func run(_ job: ComputeJob) -> PiResult {
        let start = ContinuousClock.now
        var random = SplitMix64(state: job.seed)
        var hits: UInt64 = 0
        for _ in 0..<job.iterations {
            let x = random.unitDouble()
            let y = random.unitDouble()
            if x * x + y * y <= 1 { hits += 1 }
        }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return PiResult(jobID: job.id, iterations: job.iterations, hits: hits, elapsedSeconds: seconds)
    }
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unitDouble() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}
