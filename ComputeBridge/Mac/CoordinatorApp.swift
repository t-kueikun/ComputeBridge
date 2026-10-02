import SwiftUI
import AppKit

@main
struct ComputeBridgeMacApp: App {
    @StateObject private var model = CoordinatorModel()
    var body: some Scene {
        WindowGroup {
            CoordinatorView(model: model)
                .frame(minWidth: 820, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private struct CoordinatorView: View {
    @ObservedObject var model: CoordinatorModel
    @State private var benchmarkMode = 0
    @State private var showingPairingScanner = false
    private let accent = Color(red: 0.31, green: 0.86, blue: 0.68)
    private let muted = Color.white.opacity(0.48)
    private let panel = Color(red: 0.095, green: 0.12, blue: 0.18)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.075, blue: 0.12).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        resourceOverview
                        workerSection
                        runtimeSection
                        nextSection
                        benchmarkSection
                        if let error = model.errorMessage { errorBanner(error) }
                        if !model.benchmarks.isEmpty { resultsSection }
                        footer
                    }
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 28)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(accent)
                .frame(width: 46, height: 46).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("ComputeBridge").font(.system(size: 18, weight: .semibold))
                Text("DISTRIBUTED COMPUTE · COORDINATOR").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.workers.isEmpty ? Color.orange : accent).frame(width: 8, height: 8)
                Text(model.status).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 13).padding(.vertical, 9).background(panel, in: Capsule())
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .background(Color(red: 0.07, green: 0.09, blue: 0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var resourceOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("THIS MAC", trailing: "Coordinator")
            HStack(spacing: 12) {
                resourceCard(title: "CPU LOAD", value: "\(Int(model.macCPU))%", detail: "Live system usage", symbol: "cpu", valueProgress: model.macCPU / 100)
                resourceCard(title: "MEMORY IN USE", value: model.memoryUsedGB.formatted(.number.precision(.fractionLength(1))) + " GB",
                             detail: "of \(model.memoryTotalGB.formatted(.number.precision(.fractionLength(0)))) GB unified memory", symbol: "memorychip",
                             valueProgress: model.memoryTotalGB > 0 ? model.memoryUsedGB / model.memoryTotalGB : 0)
                resourceCard(title: "COMPUTE POOL", value: "\(model.workers.count + 1) device\(model.workers.count == 0 ? "" : "s")",
                             detail: "This Mac + \(model.workers.count) worker\(model.workers.count == 1 ? "" : "s")", symbol: "point.3.connected.trianglepath.dotted", valueProgress: nil)
            }
        }
    }

    private func resourceCard(title: String, value: String, detail: String, symbol: String, valueProgress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Image(systemName: symbol).foregroundStyle(accent); Spacer(); Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(muted) }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(detail).font(.system(size: 11)).foregroundStyle(muted)
            if let valueProgress { ProgressView(value: min(1, max(0, valueProgress))).tint(accent).scaleEffect(x: 1, y: 0.7, anchor: .center) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 17))
    }

    private var workerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("WORKERS", trailing: model.isSearching ? "Bonjour · Searching" : "Paused")
            if model.workers.isEmpty {
                HStack(spacing: 15) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 42, height: 42)
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(muted)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No workers found yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                        Text("Open ComputeBridge Worker on an iPhone on this network.").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    ProgressView().controlSize(.small).tint(accent)
                }
                .padding(15).background(panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(model.workers) { worker in
                    HStack(spacing: 13) {
                        Image(systemName: "iphone.gen3").font(.system(size: 18)).foregroundStyle(accent)
                            .frame(width: 42, height: 42).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(worker.capabilities.name).font(.system(size: 13, weight: .semibold))
                            Text("\(worker.capabilities.architecture) · \(worker.capabilities.cpuCores) cores · Thermal \(worker.capabilities.thermalState)").font(.system(size: 10)).foregroundStyle(muted)
                        }
                        Spacer()
                        if let battery = worker.capabilities.batteryLevel {
                            Label("\(Int(battery * 100))%", systemImage: worker.capabilities.isCharging == true ? "battery.100percent.bolt" : "battery.75percent")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                        }
                        Text(worker.status.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(accent)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(accent.opacity(0.1), in: Capsule())
                    }
                    .padding(12).background(panel, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "cable.connector").font(.system(size: 15)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual connection").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.86))
                    Text("USB tether: enable Personal Hotspot. Wi-Fi: enter the worker IP or Bonjour name.").font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer(minLength: 8)
                TextField("Worker IP or hostname", text: $model.usbHost)
                    .textFieldStyle(.roundedBorder).frame(width: 142)
                Button("Connect") { model.connectViaUSB() }
                    .buttonStyle(.bordered).tint(accent)
                Button("Network IP") { model.connectViaIP() }
                    .buttonStyle(.bordered).tint(accent)
            }
            .padding(12).background(panel.opacity(0.58), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionLabel("MONTE CARLO π", trailing: "BENCHMARK")
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Iterations").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    HStack(spacing: 7) {
                        TextField("10,000,000", value: $model.iterations, format: .number).textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced)).frame(width: 135)
                        Stepper("", value: $model.iterations, in: 10_000...200_000_000, step: 1_000_000).labelsHidden().controlSize(.small)
                    }
                    Text("Range 10K–200M · same-work comparison").font(.system(size: 10)).foregroundStyle(muted)
                }
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run on").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    Picker("Benchmark target", selection: $benchmarkMode) {
                        Text("This Mac").tag(0)
                        Text("Worker").tag(1)
                        Text("Distributed").tag(2)
                    }
                    .pickerStyle(.segmented).frame(width: 285)
                }
                Spacer()
                Button(action: runSelected) {
                    HStack(spacing: 8) {
                        if model.isRunning { ProgressView().controlSize(.small).tint(Color(red: 0.05, green: 0.08, blue: 0.12)) }
                        else { Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)) }
                        Text(model.isRunning ? "Running" : "Run benchmark")
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.055, green: 0.075, blue: 0.12))
                    .padding(.horizontal, 17).padding(.vertical, 12).background(accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(model.isRunning)
            }
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                    .tint(accent)
                    .frame(height: 4)
                    .opacity(model.isRunning ? 1 : 0)
                    .accessibilityHidden(!model.isRunning)
                Group {
                    if let result = model.latestResult {
                        HStack(spacing: 18) {
                            Label("π ≈ \(result.estimate.formatted(.number.precision(.fractionLength(8))))", systemImage: "sum")
                            Label("\(result.iterations.formatted()) samples", systemImage: "number")
                        }
                    } else {
                        HStack(spacing: 18) {
                            Label("π ≈ 0.00000000", systemImage: "sum")
                            Label("0 samples", systemImage: "number")
                        }
                        .hidden()
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(0.95))
                .lineLimit(1)
                .frame(height: 14)
            }
            .frame(height: 26, alignment: .topLeading)
        }
        .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionLabel("IPHONE RUNTIME", trailing: "JAVASCRIPTCORE · PHASE 2A")
            Text("Run a JavaScript snippet on the connected iPhone and return console output to this Mac.")
                .font(.system(size: 11)).foregroundStyle(muted)
            TextEditor(text: $model.jsSource)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 88, maxHeight: 110)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 10) {
                Picker("JavaScript worker", selection: $model.selectedJSWorkerID) {
                    ForEach(model.workers) { worker in
                        Text(worker.capabilities.name).tag(Optional(worker.id))
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 170, alignment: .leading)
                .disabled(model.workers.isEmpty || model.isRunningJavaScript)
                Button(action: model.runJavaScript) {
                    Label(model.isRunningJavaScript ? "Running…" : "Run on iPhone", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.055, green: 0.075, blue: 0.12))
                        .padding(.horizontal, 13).padding(.vertical, 9).background(accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(model.isRunningJavaScript || model.workers.isEmpty)
                Spacer()
                if let url = model.workerHTTPURL, let destination = URL(string: url) {
                    Text(url).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    Button("Open HTTP page") { NSWorkspace.shared.open(destination) }
                        .font(.system(size: 10, weight: .medium)).buttonStyle(.bordered).tint(accent)
                } else {
                    Text("HTTP server starting on port 3000…").font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            Text(model.jsOutput)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(accent.opacity(0.95))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(11).background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var nextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("NEXT.JS ON IPHONE", trailing: "EXPERIMENTAL · NEXT 15/16")
            Text("Start the Next.js runtime in ComputeBridge Worker, then enter its transfer address and pairing token.")
                .font(.system(size: 11)).foregroundStyle(muted)
            HStack(spacing: 10) {
                Button("Choose folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Use this project"
                    if panel.runModal() == .OK { model.nextFolder = panel.url }
                }
                .buttonStyle(.bordered).tint(accent)
                Text(model.nextFolder?.path ?? "No folder selected")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Button("Scan QR", systemImage: "qrcode.viewfinder") {
                    showingPairingScanner = true
                }
                .buttonStyle(.bordered).tint(accent)
            }
            HStack(spacing: 10) {
                TextField("iPhone IP or .local name", text: $model.nextHost)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
                SecureField("Pairing token", text: $model.nextToken)
                    .textFieldStyle(.roundedBorder).frame(width: 210)
                Button(model.isSyncingNext ? "Syncing…" : "Send and run") { model.startNextOnIPhone() }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(model.isSyncingNext)
                if model.isSyncingNext {
                    Button("Stop sync") { model.stopNextSync() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if let url = model.nextSiteURL {
                    Button("Open site") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered).tint(accent)
                }
            }
            Text(model.nextStatus)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(accent.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $showingPairingScanner) {
            PairingQRScannerSheet { pairing in
                model.nextHost = pairing.host
                model.nextToken = pairing.token
                model.nextStatus = "Paired with iPhone. Choose a project folder, then Send and run."
                showingPairingScanner = false
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionLabel("RUN HISTORY", trailing: "SPEEDUP COMPARED WITH MAC ONLY")
            ForEach(model.benchmarks.prefix(8)) { record in
                HStack(spacing: 12) {
                    Image(systemName: record.mode == "Mac only" ? "laptopcomputer" : record.mode == "iPhone only" ? "iphone" : "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(accent).frame(width: 30)
                    Text(record.mode).font(.system(size: 12, weight: .semibold)).frame(width: 100, alignment: .leading)
                    Text(record.duration.formatted(.number.precision(.fractionLength(2))) + " s")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 76, alignment: .trailing)
                    Text("π \(record.estimate.formatted(.number.precision(.fractionLength(5))))").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    Spacer()
                    if let speedup = record.speedup {
                        Text(String(format: "%.2f×", speedup)).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(speedup > 1 ? accent : .orange)
                            .padding(.horizontal, 9).padding(.vertical, 5).background((speedup > 1 ? accent : Color.orange).opacity(0.11), in: Capsule())
                    }
                }
                .padding(.vertical, 5)
                if record.id != model.benchmarks.prefix(8).last?.id { Divider().overlay(.white.opacity(0.05)) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle").foregroundStyle(accent.opacity(0.8))
            Text("Distributed mode splits the sample set across this Mac and every connected worker.")
            Spacer()
            Text("ComputeBridge · V2 preview").foregroundStyle(.white.opacity(0.3))
        }
        .font(.system(size: 10)).foregroundStyle(muted)
    }

    private func sectionLabel(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(trailing.uppercased()).font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(muted)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark").foregroundStyle(muted) }.buttonStyle(.plain)
        }
        .padding(13).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
    }

    private func runSelected() {
        switch benchmarkMode { case 0: model.runLocal(); case 1: model.runWorker(); default: model.runDistributed() }
    }
}
