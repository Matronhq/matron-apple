import SwiftUI
import AVFoundation

/// Full-screen QR scanner for sign-in (device-link login). Wraps
/// `QRScannerSurface` in navigation chrome with a Cancel button; fires
/// `onScanned` once per presentation and dismisses.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            QRScannerSurface(onScanned: { payload in
                dismiss()
                onScanned(payload)
            })
            .ignoresSafeArea()
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The chrome-less scanner: camera permission + preview + fallback
/// messages. Hosts decide the framing — `QRScannerView` goes full-screen
/// for onboarding; Settings → Link a Device → Scan embeds it inline as a
/// card, where `refireDelay` lets the same mounted camera report again
/// after a cooldown (a full-screen host dismisses on first fire, so the
/// default fire-once is right there).
struct QRScannerSurface: View {
    let onScanned: (String) -> Void
    /// Seconds before the scanner may fire again after a hit; nil = once
    /// per presentation.
    var refireDelay: TimeInterval?

    @State private var authorized: Bool?
    /// Set when the capture session fails to configure in the authorized
    /// path (no camera hardware, input/output rejected) — surfaces the same
    /// "type the code instead" fallback rather than a silent black screen.
    @State private var setupFailed = false

    var body: some View {
        Group {
            switch authorized {
            case .none:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(true) where setupFailed:
                // No camera hardware / capture setup failed: "Open
                // Settings" wouldn't help, so omit it — just the message
                // and the manual-code fallback.
                unavailableMessage("Couldn't start the camera on this device.", showSettings: false)
            case .some(true):
                CameraPreview(onScanned: onScanned,
                              onSetupFailed: { setupFailed = true },
                              refireDelay: refireDelay)
            case .some(false):
                unavailableMessage("Matron needs camera access to scan sign-in codes.", showSettings: true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// UIKit capture layer: session + metadata output restricted to `.qr`.
private struct CameraPreview: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    /// Called (on the main thread) if the capture session can't be
    /// configured, so the SwiftUI layer can replace the black preview with
    /// the manual-code fallback instead of a dead screen.
    let onSetupFailed: () -> Void
    let refireDelay: TimeInterval?

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScanned = onScanned
        controller.onSetupFailed = onSetupFailed
        controller.refireDelay = refireDelay
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onSetupFailed: (() -> Void)?
    /// nil = fire once per presentation (full-screen host dismisses on
    /// fire); otherwise re-arm after this many seconds so an inline host
    /// can report retries without remounting the camera.
    var refireDelay: TimeInterval?
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
        didFire = true // a QR in frame fires this delegate many times a second
        onScanned?(payload)
        if let refireDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + refireDelay) { [weak self] in
                self?.didFire = false
            }
        }
    }
}
