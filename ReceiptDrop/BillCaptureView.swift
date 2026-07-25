import AVFoundation
import PhotosUI
import SwiftUI

/// Capture screen for "Check a Bill" — a custom AVFoundation camera (not
/// `VNDocumentCameraViewController`, which has no torch API) so the
/// flashlight can stay on continuously while framing the bill in a dark
/// restaurant, not just flash at the shutter moment. Torch defaults on;
/// toggleable, since glare off glossy thermal paper is the trade-off.
struct BillCaptureView: View {
    let onCancel: () -> Void
    let onCaptured: (Data) -> Void

    @StateObject private var camera = BillCameraController()
    @State private var torchOn = true
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPermissionAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                BillCameraPreview(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    Button {
                        torchOn.toggle()
                        camera.setTorch(on: torchOn)
                    } label: {
                        Image(systemName: torchOn ? "bolt.fill" : "bolt.slash")
                            .font(.title2)
                            .foregroundStyle(torchOn ? .yellow : .white)
                            .padding(12)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .padding()

                Spacer()

                Text("Hold steady over the bill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)

                HStack(spacing: 40) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.4), in: Circle())
                    }

                    Button {
                        camera.capturePhoto { data in
                            if let data { onCaptured(data) }
                        }
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.white, lineWidth: 3).frame(width: 84, height: 84))
                    }

                    // Balances the layout against the library button.
                    Color.clear.frame(width: 54, height: 54)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            camera.start { authorized in
                if authorized {
                    camera.setTorch(on: torchOn)
                } else {
                    showPermissionAlert = true
                }
            }
        }
        .onDisappear { camera.stop() }
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                // Re-encode to real JPEG bytes — a library photo can be HEIC/PNG,
                // and the itemization request always labels the upload as
                // image/jpeg, so passing the original bytes through unconverted
                // breaks decoding server-side for anything that isn't already JPEG.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.9) {
                    onCaptured(jpeg)
                } else {
                    photoPickerItem = nil
                }
            }
        }
        .alert("Camera Access Needed", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) { onCancel() }
        } message: {
            Text("Enable camera access in Settings to check a bill by photo, or choose one from your library instead.")
        }
    }
}

/// Owns the AVCaptureSession, torch state, and photo capture — kept separate
/// from the SwiftUI view so session setup/teardown isn't tangled with view
/// lifecycle re-renders.
final class BillCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "BillCameraController.session")
    private var captureCompletion: ((Data?) -> Void)?

    @Published private(set) var isAuthorized = false

    func start(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async { self.isAuthorized = granted }
            guard granted else {
                completion(false)
                return
            }
            self.sessionQueue.async {
                self.configureSessionIfNeeded()
                self.session.startRunning()
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    func setTorch(on: Bool) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  device.hasTorch, device.isTorchAvailable else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func capturePhoto(completion: @escaping (Data?) -> Void) {
        sessionQueue.async {
            self.captureCompletion = completion
            let settings = AVCapturePhotoSettings()
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let completion = captureCompletion
        captureCompletion = nil
        DispatchQueue.main.async { completion?(data) }
    }
}

private struct BillCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
