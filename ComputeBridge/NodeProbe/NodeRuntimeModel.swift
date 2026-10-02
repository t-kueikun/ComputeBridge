import Foundation
import SwiftUI
import NodeMobile
import UIKit

@MainActor
final class NextRuntimeModel: ObservableObject {
    @Published var status = "Next.js runtime is off"
    @Published var isStarted = false
    @Published var phase = "off"
    @Published var isSendingControl = false
    @Published var address = "<iPhone IP>"
    #if targetEnvironment(simulator)
    let token = "simulator-only-token"
    #elseif DEBUG
    let token = ProcessInfo.processInfo.environment["COMPUTEBRIDGE_DEV_TOKEN"]
        ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    #else
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    #endif
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        isStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        address = Self.wifiAddress ?? "<iPhone IP>"

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let entry = Bundle.main.bundleURL.appendingPathComponent("Runtime/server.cjs")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            status = "Bundled Node server is missing"
            return
        }
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            status = "Could not prepare Node: \(error.localizedDescription)"
            return
        }

        status = "Starting embedded Node…"
        let directoryPath = support.path
        let entryPath = entry.path
        let pairingToken = token
        Task.detached(priority: .userInitiated) {
            setenv("NODE_OPTIONS", "--max-old-space-size=768", 1)
            setenv("BRIDGE_TOKEN", pairingToken, 1)
            guard chdir(directoryPath) == 0 else {
                await MainActor.run { self.status = "Could not open the app support directory" }
                return
            }
            let arguments = ["node", entryPath]
            let pointers = arguments.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            var argv = pointers
            await MainActor.run { self.status = "Node listening · port 3100" }
            let result = argv.withUnsafeMutableBufferPointer { buffer in
                node_start(Int32(buffer.count), buffer.baseAddress)
            }
            await MainActor.run { self.status = "Node exited with code \(result)" }
        }

        Task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let url = URL(string: "http://127.0.0.1:3100/status") else { continue }
                var request = URLRequest(url: url)
                request.setValue(pairingToken, forHTTPHeaderField: "x-bridge-token")
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let response = try? JSONDecoder().decode(ProbeStatus.self, from: data) else { continue }
                phase = response.phase
                status = response.message
            }
        }
    }

    func stopNext() { controlNext(path: "stop", message: "Stopping Next.js…") }

    func restartNext() { controlNext(path: "start", message: "Starting Next.js…") }

    private func controlNext(path: String, message: String) {
        guard isStarted, !isSendingControl,
              let url = URL(string: "http://127.0.0.1:3100/\(path)") else { return }
        isSendingControl = true
        status = message
        Task {
            defer { isSendingControl = false }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(token, forHTTPHeaderField: "x-bridge-token")
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    status = "Could not \(path) Next.js. Check the runtime status."
                    return
                }
            } catch {
                status = "Could not \(path) Next.js: \(error.localizedDescription)"
            }
        }
    }

    private static var wifiAddress: String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let item = current {
            let interface = item.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(interface.ifa_addr.pointee.sa_len)
                if getnameinfo(interface.ifa_addr, length, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = address.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            current = interface.ifa_next
        }
        return nil
    }
}

private struct ProbeStatus: Decodable {
    let phase: String
    let message: String
}
