import SwiftUI
import AVFoundation

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String)->Void
    let onFailure: (String)->Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode:onCode,onFailure:onFailure) }
    func updateUIViewController(_ uiViewController: ScannerController,context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController,coordinator: ()) { controller.stop() }
}
final class ScannerController: UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let work = DispatchQueue(label:"app.pccontrol.camera")
    private var layer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let onCode: (String)->Void
    private let onFailure: (String)->Void
    init(onCode: @escaping (String)->Void,onFailure: @escaping (String)->Void) { self.onCode = onCode; self.onFailure = onFailure; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session:session); preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview); layer = preview
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: configure()
        case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in DispatchQueue.main.async { if allowed { self?.configure() } else { self?.onFailure("Camera access is off. You can import your PC’s setup file instead.") } } }
        default:onFailure("Camera access is off. Enable it in iPhone Settings, or import your PC’s setup file instead.")
        }
    }
    private func configure() {
        work.async { [weak self] in
            guard let self else { return }
            do {
                guard let camera = AVCaptureDevice.default(for:.video) else { throw CameraError.unavailable }
                let input = try AVCaptureDeviceInput(device:camera), output = AVCaptureMetadataOutput()
                self.session.beginConfiguration(); defer { self.session.commitConfiguration() }
                guard self.session.canAddInput(input),self.session.canAddOutput(output) else { throw CameraError.unavailable }
                self.session.addInput(input); self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self,queue:.main); output.metadataObjectTypes = [.qr]
            } catch { DispatchQueue.main.async { self.onFailure("A camera isn’t available. Import the setup file from your PC instead.") }; return }
            self.session.startRunning()
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    func stop() { work.async { [session] in if session.isRunning { session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput,didOutput metadataObjects: [AVMetadataObject],from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); onCode(code)
    }
    enum CameraError: Error { case unavailable }
}
