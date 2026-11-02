import UIKit
import AVFoundation
import EasyConnKit

/// Full-screen camera that returns the first QR whose text is a valid dash pairing link.
final class QrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onResult: ((String?) -> Void)?
  private let session = AVCaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?
  private let hint = UILabel()
  private var finished = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: configure()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { ok in
        DispatchQueue.main.async { ok ? self.configure() : self.fail("Camera access is off. Allow it in Settings > RideScreen, or paste the link instead.") }
      }
    default: fail("Camera access is off. Allow it in Settings > RideScreen, or paste the link instead.")
    }
    let close = UIButton(type: .system)
    close.setTitle("Cancel", for: .normal)
    close.tintColor = .white
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    close.translatesAutoresizingMaskIntoConstraints = false
    hint.text = "Point the camera at the QR on the bike screen."
    hint.textColor = .white
    hint.numberOfLines = 0
    hint.textAlignment = .center
    hint.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(close)
    view.addSubview(hint)
    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])
  }

  private func configure() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
      fail("No camera available. Paste the link instead."); return
    }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.insertSublayer(layer, at: 0)
    preview = layer
    DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  private func fail(_ message: String) { hint.text = message }

  @objc private func cancel() { finish(nil) }

  private func finish(_ value: String?) {
    guard !finished else { return }
    finished = true
    session.stopRunning()
    dismiss(animated: true) { self.onResult?(value) }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
    for case let code as AVMetadataMachineReadableCodeObject in objects {
      guard let text = code.stringValue else { continue }
      if QrData.parse(text) != nil { finish(text); return }
      hint.text = "That QR is not a dash pairing code. Point at the QR on the bike screen."
    }
  }
}
