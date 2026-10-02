import AVFoundation
import SwiftUI
import Vision

@MainActor
final class PairingQRScanner: NSObject, ObservableObject {
    @Published var message = "Point the Mac camera at the QR code on your iPhone."
    let session = AVCaptureSession()
    private var configured = false
    private var matched = false
    private var hasVideoFrame = false
    private var frameProcessor: PairingFrameProcessor?
    private var onPairing: ((PairingPayload) -> Void)?

    func start(onPairing: @escaping (PairingPayload) -> Void) {
        self.onPairing = onPairing
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                authorized = true
            case .notDetermined:
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            default:
                authorized = false
            }
            guard authorized else {
                message = "Allow camera access for ComputeBridge in System Settings to scan the QR code."
                return
            }
            configureAndRun()
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    private func configureAndRun() {
        if !configured {
            let builtInCamera = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
            ).devices.first
            guard let camera = builtInCamera ?? AVCaptureDevice.default(for: .video) else {
                message = "No Mac camera was found."
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    message = "The Mac camera could not provide video for QR scanning."
                    return
                }
                let processor = PairingFrameProcessor(
                    onFrame: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, !self.hasVideoFrame else { return }
                            self.hasVideoFrame = true
                            self.message = "Camera ready. Point it at the QR code on your iPhone."
                        }
                    },
                    onCode: { [weak self] value in
                        Task { @MainActor [weak self] in self?.accept(value) }
                    }
                )
                session.beginConfiguration()
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(
                    processor, queue: DispatchQueue(label: "dev.computebridge.pairing-camera")
                )
                session.commitConfiguration()
                frameProcessor = processor
                configured = true
            } catch {
                message = "Could not start the Mac camera: \(error.localizedDescription)"
                return
            }
        }
        matched = false
        if !session.isRunning { session.startRunning() }
        if !session.isRunning { message = "The Mac camera did not start. Close other camera apps and try again." }
    }

    private func accept(_ value: String) {
        guard !matched else { return }
        guard let pairing = PairingPayload.parse(value) else {
            message = "This is not a ComputeBridge pairing QR code."
            return
        }
        matched = true
        stop()
        onPairing?(pairing)
    }
}

private final class PairingFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let request = VNDetectBarcodesRequest()
    private let onFrame: @Sendable () -> Void
    private let onCode: @Sendable (String) -> Void
    private var lastScanTime = 0.0
    private var reportedFirstFrame = false

    init(onFrame: @escaping @Sendable () -> Void, onCode: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onCode = onCode
        super.init()
        request.symbologies = [.qr]
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if !reportedFirstFrame {
            reportedFirstFrame = true
            onFrame()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScanTime >= 0.25 else { return }
        lastScanTime = now
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer)
        guard (try? handler.perform([request])) != nil,
              let value = request.results?.compactMap(\.payloadStringValue).first else { return }
        onCode(value)
    }
}

private final class PairingCameraView: NSView {
    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct PairingCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PairingCameraView {
        let view = PairingCameraView()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: PairingCameraView, context: Context) {
        view.previewLayer.session = session
    }
}

struct PairingQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = PairingQRScanner()
    let onPairing: (PairingPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan iPhone pairing QR")
                .font(.system(size: 20, weight: .semibold))
            PairingCameraPreview(session: scanner.session)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(scanner.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear { scanner.start(onPairing: onPairing) }
        .onDisappear { scanner.stop() }
    }
}
