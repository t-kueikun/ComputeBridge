import SwiftUI

@main
struct ComputeBridgeWorkerApp: App {
    @StateObject private var model = WorkerModel()
    @StateObject private var nextModel = NextRuntimeModel()
    var body: some Scene {
        WindowGroup {
            WorkerView(model: model, nextModel: nextModel)
                .task {
                    model.start()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["COMPUTEBRIDGE_AUTO_START_NEXT"] == "1" {
                        nextModel.start()
                    }
                    #endif
                }
        }
    }
}

private struct WorkerView: View {
    @ObservedObject var model: WorkerModel
    @ObservedObject var nextModel: NextRuntimeModel
    private let ink = Color(red: 0.09, green: 0.12, blue: 0.20)
    private let accent = Color(red: 0.29, green: 0.83, blue: 0.64)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.075, blue: 0.12).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 13) {
                        Image(systemName: "circle.hexagongrid.fill").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                            .frame(width: 48, height: 48).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ComputeBridge").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            Text("WORKER NODE").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.7).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("WORKER STATUS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.48))
                        HStack(spacing: 11) {
                            Circle().fill(model.connectedMac.isEmpty ? .orange : accent).frame(width: 9, height: 9)
                                .shadow(color: accent.opacity(0.8), radius: 8)
                            Text(model.status).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        }
                        if !model.connectedMac.isEmpty {
                            Label("Connected to \(model.connectedMac)", systemImage: "laptopcomputer").font(.system(size: 13)).foregroundStyle(.white.opacity(0.58))
                        } else {
                            Text("Keep this app open while your Mac is using this device.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.52))
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.27), ink], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                    HStack(spacing: 12) {
                        metricCard(title: "JOBS DONE", value: completedCount, symbol: "checkmark.circle.fill", tint: accent)
                        metricCard(title: "THERMAL", value: model.thermalState, symbol: "thermometer.medium", tint: thermalTint)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DEVICE RESOURCES").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.48))
                        HStack {
                            Label("Battery", systemImage: model.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                            Spacer()
                            Text(model.batteryLevel < 0 ? "—" : "\(Int(model.batteryLevel * 100))%")
                        }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                        Divider().overlay(.white.opacity(0.08))
                        HStack {
                            Label("CPU cores", systemImage: "cpu")
                            Spacer()
                            Text("\(ProcessInfo.processInfo.activeProcessorCount) available")
                        }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(20).background(ink, in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("LATEST JOB").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.48))
                        Text(model.recentJob).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.86))
                    }.padding(.horizontal, 3)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("HTTP PREVIEW").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.48))
                            Spacer()
                            Label(model.httpServerReady ? "Listening · 3000" : "Starting…", systemImage: "network")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(model.httpServerReady ? accent : .orange)
                        }
                        Text(model.httpURL).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                        Text("Open this address from a browser on the same local network.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading).background(ink, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("NEXT.JS DEVELOPMENT").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.48))
                            Spacer()
                            if !nextModel.isStarted {
                                Button("Start runtime") { nextModel.start() }
                                    .buttonStyle(.borderedProminent).tint(accent)
                            } else if ["starting", "ready", "stopping"].contains(nextModel.phase) {
                                Button(nextModel.phase == "stopping" ? "Stopping…" : "Stop Next.js") {
                                    nextModel.stopNext()
                                }
                                .buttonStyle(.bordered).tint(.orange)
                                .disabled(nextModel.isSendingControl || nextModel.phase == "stopping")
                            } else if ["uploaded", "stopped"].contains(nextModel.phase) {
                                Button("Start Next.js") { nextModel.restartNext() }
                                    .buttonStyle(.borderedProminent).tint(accent)
                                    .disabled(nextModel.isSendingControl)
                            }
                        }
                        Text(nextModel.status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        if nextModel.isStarted {
                            PairingQRCode(host: nextModel.address, token: nextModel.token)
                            Text("Transfer: http://\(nextModel.address):3100")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                            Text("Pairing token: \(nextModel.token)")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                            Text("Site: http://\(nextModel.address):3001")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(accent).textSelection(.enabled)
                        }
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading).background(ink, in: RoundedRectangle(cornerRadius: 18))
                }
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .preferredColorScheme(.dark)
    }

    private var completedCount: String { model.completedJobs.formatted() }
    private var thermalTint: Color { model.thermalState == "Normal" || model.thermalState == "Fair" ? accent : .orange }
    private func metricCard(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.15).foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(17).background(ink, in: RoundedRectangle(cornerRadius: 18))
    }
}
