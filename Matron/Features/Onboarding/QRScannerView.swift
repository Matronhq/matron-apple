import SwiftUI
import AVFoundation

/// Full-screen QR scanner for sign-in (device-link login). QR metadata
/// objects only; fires `onScanned` once per presentation with the raw
/// payload string. Camera-permission denial renders an explanation with a
/// Settings deep-link — the manual code path remains on the sign-in form.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    @State private var authorized: Bool?
    /// Set when the capture session fails to configure in the authorized
    /// path (no camera hardware, input/output rejected) — surfaces the same
    /// "type the code instead" fallback rather than a silent black screen.
    @State private var setupFailed = false

    var body: some View {
        NavigationStack {
            Group {
                switch authorized {
                case .none:
                    ProgressView()
                case .some(true) where setupFailed:
                    // No camera hardware / capture setup failed: "Open
                    // Settings" wouldn't help, so omit it — just the message
                    // and the manual-code fallback.
                    unavailableMessage("Couldn't start the camera on this device.", showSettings: false)
                case .some(true):
                    CameraPreview(onScanned: { payload in
                        dismiss()
                        onScanned(payload)
                    }, onSetupFailed: { setupFailed = true })
                    .ignoresSafeArea()
                case .some(false):
                    unavailableMessage("Matron needs camera access to scan sign-in codes.", showSettings: true)
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                authorized = true
            case .notDetermined:
                authorized = await AVCaptureDevice.requestAccess(for: .video)
            default:
                authorized = false
            }
        }
    }

    /// Shared fallback for the camera-denied and setup-failed states: an
    /// explanation plus the manual-code hint (and, for denial, a Settings
    /// deep-link).
    @ViewBuilder private func unavailableMessage(_ message: String, showSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Text("Or type the code instead — it's shown under the QR on your other device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// UIKit capture layer: session + metadata output restricted to `.qr`.
private struct CameraPreview: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    /// Called (on the main thread) if the capture session can't be
    /// configured, so the SwiftUI layer can replace the black preview with
    /// the manual-code fallback instead of a dead screen.
    let onSetupFailed: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScanned = onScanned
        controller.onSetupFailed = onSetupFailed
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onSetupFailed: (() -> Void)?
    private let session = AVCaptureSession()
    private var didFire = false

    /// Report a configuration failure to SwiftUI asynchronously — never
    /// synchronously inside viewDidLoad, which runs during a SwiftUI update.
    private func reportSetupFailed() {
        DispatchQueue.main.async { [weak self] in self?.onSetupFailed?() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { reportSetupFailed(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { reportSetupFailed(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // startRunning blocks; keep it off the main thread (Apple guidance).
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFire,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr, let payload = object.stringValue
        else { return }
        didFire = true // one payload per presentation — a QR in frame fires repeatedly
        onScanned?(payload)
    }
}
