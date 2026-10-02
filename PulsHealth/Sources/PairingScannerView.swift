import AVFoundation
import SwiftUI
import PulsHealthSync

/// Camera sheet that scans the QR code `scripts/bootstrap.sh` prints and hands
/// back a parsed `PairingPayload`.
///
/// The camera is used for nothing else: no frame is stored, written, or sent
/// anywhere — the capture session exists only long enough to read one code, and
/// the sheet stops it as soon as a valid payload is found. Every failure mode
/// (permission refused, no camera, a QR code that is not a pairing code) leaves
/// a way out to typing the details by hand.
struct PairingScannerView: View {
    /// Called on the main actor with a validated payload, right before dismissal.
    let onPayload: (PairingPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var requesting = false
    /// A hardware/configuration problem reported by the capture session, or the
    /// reason the last scanned code was rejected. Shown over the preview.
    @State private var problem: String?
    /// True once a payload has been accepted, so a second code in the same
    /// frame burst cannot fire the callback twice.
    @State private var done = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Type It Instead") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .authorized:
            scanner
        case .denied, .restricted:
            deniedNotice
        default:
            permissionPrompt
        }
    }

    private var scanner: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(
                onCode: { code in handle(code) },
                onFailure: { problem = $0 }
            )
            .ignoresSafeArea()
            VStack {
                Spacer()
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.red.opacity(0.85), in: .rect(cornerRadius: 12))
                } else {
                    Text("Point the camera at the pairing code your database’s setup prints.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Label("Camera Access", systemImage: "qrcode.viewfinder")
        } description: {
            Text("PulsHealth needs the camera to read the pairing code. The camera is used for nothing else and no images are saved.")
        } actions: {
            Button {
                requesting = true
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    status = granted ? .authorized : .denied
                    requesting = false
                }
            } label: {
                Text("Allow Camera Access").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .disabled(requesting)
            Button("Type It Instead") { dismiss() }
        }
    }

    private var deniedNotice: some View {
        ContentUnavailableView {
            Label("Camera Access Is Off", systemImage: "video.slash")
        } description: {
            Text("Turn the camera on for PulsHealth in Settings → Privacy & Security → Camera, or enter the database URL, token and user ID by hand.")
        } actions: {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            Button("Type It Instead") { dismiss() }
        }
    }

    private func handle(_ code: String) {
        guard !done else { return }
        switch PairingPayload.parse(code) {
        case .success(let payload):
            done = true
            onPayload(payload)
            dismiss()
        case .failure(let failure):
            problem = failure.errorDescription ?? "That code could not be read."
        }
    }
}

// MARK: - Capture session

/// `AVCaptureSession` is configured on the main actor but started and stopped on
/// a background queue, because `startRunning()` blocks (Apple's own sample code
/// does the same). Nothing else touches the session off the main actor.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

private struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let box = SessionBox(session: AVCaptureSession())
    private let queue = DispatchQueue(label: "PulsHealth.pairing-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        let session = box.session
        // The simulator has no capture device at all, so this is the ordinary
        // path there — not an error worth a crash.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onFailure?("No camera is available on this device. Enter the pairing details by hand instead.")
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onFailure?("This device cannot scan QR codes. Enter the pairing details by hand instead.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Only settable once the output belongs to a session with an input:
        // the available types depend on both.
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        configured = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updateRotation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard configured else { return }
        let box = self.box
        queue.async {
            if !box.session.isRunning { box.session.startRunning() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let box = self.box
        queue.async {
            if box.session.isRunning { box.session.stopRunning() }
        }
    }

    private func updateRotation() {
        guard let connection = previewLayer?.connection else { return }
        let angle: CGFloat
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // AVFoundation calls this on the queue handed to `setMetadataObjectsDelegate`
    // above — `.main` — so the hop below is an assertion, not a dispatch.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Reduce to a String before hopping: AVMetadataObject is not Sendable
        // and must not cross into the main-actor closure.
        guard let code = metadataObjects
            .lazy
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }
        MainActor.assumeIsolated { onCode?(code) }
    }
}
