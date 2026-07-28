import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import Vision

/// Capture screen for "Check a Bill" — a custom AVFoundation camera (not
/// `VNDocumentCameraViewController`, which has no torch API) so the
/// flashlight can stay on continuously while framing the bill in a dark
/// restaurant, not just flash at the shutter moment. Torch defaults on;
/// toggleable, since glare off glossy thermal paper is the trade-off.
///
/// Also runs live document detection (Vision) on the camera feed and
/// auto-fires the shutter once the bill holds steady in frame — the same
/// convenience VisionKit's scanner offers, but built into this camera so it
/// doesn't come at the cost of losing torch control. A manual shutter tap
/// always still works regardless, and auto-capture can be turned off for
/// anyone who prefers full manual control.
struct BillCaptureView: View {
    let onCancel: () -> Void
    let onCaptured: (Data) -> Void

    @StateObject private var camera = BillCameraController()
    @State private var torchOn = TorchPreferenceStore.isOn
    @State private var torchBrightness = TorchPreferenceStore.defaultBrightness
    /// A single always-running pulse both active-state buttons ride on, so the
    /// torch and auto-capture buttons glow in sync — each only shows the
    /// effect while its own feature is on.
    @State private var pulse = false
    @State private var autoCaptureOn = TorchPreferenceStore.autoCaptureEnabled
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showLibraryPicker = false
    @State private var showPermissionAlert = false
    @State private var showCaptureFailedAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                BillCameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .overlay(scanFrameOverlay)
            }

            VStack(spacing: 6) {
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
                    Button {
                        autoCaptureOn.toggle()
                        TorchPreferenceStore.autoCaptureEnabled = autoCaptureOn
                        camera.autoCaptureEnabled = autoCaptureOn
                    } label: {
                        Image(systemName: autoCaptureOn ? "viewfinder.circle.fill" : "viewfinder.circle")
                            .font(.title2)
                            .foregroundStyle(autoCaptureOn ? .green : .white)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(autoCaptureOn ? Color.green.opacity(pulse ? 0.55 : 0.15) : Color.black.opacity(0.4))
                            )
                            .scaleEffect(autoCaptureOn && pulse ? 1.12 : 1.0)
                    }
                    .padding(.leading, 8)
                    Spacer()
                    Button {
                        torchOn.toggle()
                        TorchPreferenceStore.isOn = torchOn
                        camera.setTorch(on: torchOn, level: torchBrightness)
                    } label: {
                        Image(systemName: torchOn ? "bolt.fill" : "bolt.slash")
                            .font(.title2)
                            .foregroundStyle(torchOn ? .yellow : .white)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(torchOn ? Color.yellow.opacity(pulse ? 0.55 : 0.15) : Color.black.opacity(0.4))
                            )
                            .scaleEffect(torchOn && pulse ? 1.12 : 1.0)
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                if torchOn {
                    torchLevelControl
                }

                Spacer()

                Text(statusText)
                    .font(.subheadline.weight(isCapturing ? .semibold : .regular))
                    .foregroundStyle(isCapturing ? .green : .white)
                    .padding(.bottom, 12)

                HStack(spacing: 40) {
                    Button {
                        showLibraryPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(.black.opacity(0.4), in: Circle())
                    }

                    Button {
                        camera.capturePhoto { data in
                            if let data {
                                onCaptured(data)
                            } else {
                                showCaptureFailedAlert = true
                            }
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
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
            camera.autoCaptureEnabled = autoCaptureOn
            camera.onAutoCapture = { data in onCaptured(data) }
            camera.start { authorized in
                if authorized {
                    camera.setTorch(on: torchOn, level: torchBrightness)
                } else {
                    showPermissionAlert = true
                }
            }
        }
        .onDisappear { camera.stop() }
        .photosPicker(isPresented: $showLibraryPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: showLibraryPicker) { isOpen in
            // While the library picker is up, the user isn't using the live
            // camera at all — so fully suspend it: pausing the session kills
            // the torch, the auto-capture video analysis (which could
            // otherwise fire a camera shot behind the picker), and focus/
            // exposure work, all at once. Resume only if they back out
            // without picking; if they pick, the screen dismisses anyway.
            if isOpen {
                camera.pause()
            } else if photoPickerItem == nil {
                camera.resume()
                camera.setTorch(on: torchOn, level: torchBrightness)
            }
        }
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
        .alert("Couldn't Capture Photo", isPresented: $showCaptureFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That didn't come through — please try again.")
        }
    }

    /// Low/Medium/High as fast, reliable one-tap presets, plus a slider
    /// underneath for anyone who wants to fine-tune (or dim all the way
    /// down) rather than being limited to three fixed steps. Both write to
    /// the same underlying brightness value, so they always stay in sync,
    /// and the choice persists between uses.
    private var torchLevelControl: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(TorchLevel.allCases, id: \.self) { level in
                    Button {
                        setTorchBrightness(level.torchLevelValue)
                    } label: {
                        Text(level.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isPreset(level) ? .black : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isPreset(level) ? Color.yellow : Color.black.opacity(0.4),
                                        in: Capsule())
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.white.opacity(0.7))
                ThickSlider(value: Binding(
                    get: { Double(torchBrightness) },
                    set: { setTorchBrightness(Float($0)) }
                ), range: 0.05...1.0)
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.white)
            }
            .frame(width: 260)
        }
    }

    private func isPreset(_ level: TorchLevel) -> Bool {
        abs(level.torchLevelValue - torchBrightness) < 0.01
    }

    private func setTorchBrightness(_ value: Float) {
        torchBrightness = value
        camera.setTorch(on: true, level: value)
    }

    private var isCapturing: Bool { camera.guidance == .capturing }

    /// Adaptive coaching, reusing the same document-detection signal already
    /// needed for auto-capture — surfacing it as guidance costs nothing
    /// extra and is far more helpful than a single static instruction,
    /// especially for a user unfamiliar with document-scanning apps.
    private var statusText: String {
        guard autoCaptureOn else { return "Hold steady, then tap the shutter" }
        switch camera.guidance {
        case .searching: return "Point the camera at the bill"
        case .tooSmall: return "Move closer to the bill"
        case .tooLarge: return "Move back — fit the whole bill in view"
        case .holdSteady: return "Hold steady…"
        case .capturing: return "Got it — capturing…"
        }
    }

    /// A framing border that goes from a plain white outline to a solid
    /// green one as the live document detector locks onto the bill — visual
    /// confirmation of what's about to auto-fire, without needing to draw
    /// the exact detected quadrilateral.
    @ViewBuilder
    private var scanFrameOverlay: some View {
        if autoCaptureOn {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isCapturing ? Color.green : Color.white.opacity(0.5),
                              lineWidth: isCapturing ? 4 : 2)
                .padding(24)
                .animation(.easeInOut(duration: 0.2), value: isCapturing)
        }
    }
}

/// Owns the AVCaptureSession, torch state, and photo capture — kept separate
/// from the SwiftUI view so session setup/teardown isn't tangled with view
/// lifecycle re-renders.
final class BillCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
                                    AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "BillCameraController.session")
    private let videoQueue = DispatchQueue(label: "BillCameraController.video")
    private var captureCompletion: ((Data?) -> Void)?
    private var captureAttempt = 0
    private let maxCaptureAttempts = 3

    @Published private(set) var isAuthorized = false
    /// Mirrors whether the live detector currently sees a steady document —
    /// drives the on-screen framing border and status text.
    /// Coaching state surfaced to the capture screen's status text and
    /// framing border — reuses the same document-detection signal already
    /// needed for auto-capture, so the guidance is essentially free.
    enum CaptureGuidance {
        case searching
        case tooSmall
        case tooLarge
        case holdSteady
        case capturing
    }
    @Published private(set) var guidance: CaptureGuidance = .searching

    /// Whether the shutter fires itself once a steady document is detected.
    /// A manual shutter tap always works regardless of this setting.
    var autoCaptureEnabled = true
    /// Called (on the main thread) with the captured JPEG once auto-capture
    /// fires. Set by the view before starting the session.
    var onAutoCapture: ((Data) -> Void)?

    private let sequenceHandler = VNSequenceRequestHandler()
    private var lastQuad: VNRectangleObservation?
    private var stableFrameCount = 0
    private var hasAutoCaptured = false
    /// Consecutive stable frames needed before firing — roughly half a
    /// second at a typical 30fps feed, long enough to filter out a hand
    /// just passing through frame.
    private let requiredStableFrames = 15
    private var frameCounter = 0

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

    /// Temporarily suspends the running session (e.g. while the library
    /// picker is open) — stopping the session turns the torch off and halts
    /// video-frame delivery, so auto-capture can't fire behind the picker.
    /// Also clears any in-progress auto-capture stability so it starts fresh
    /// on resume.
    func pause() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.stableFrameCount = 0
            self.lastQuad = nil
            self.hasAutoCaptured = false
            DispatchQueue.main.async { self.guidance = .searching }
        }
    }

    func resume() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
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
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    func setTorch(on: Bool, level: Float = 1.0) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  device.hasTorch, device.isTorchAvailable else { return }
            try? device.lockForConfiguration()
            if on {
                try? device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        }
    }

    func capturePhoto(completion: @escaping (Data?) -> Void) {
        sessionQueue.async {
            self.captureCompletion = completion
            self.captureAttempt = 0
            // The live video-analysis pipeline (for auto-capture) delivering
            // frames on the same session while a photo capture is in flight
            // is a known AVFoundation contention spot — it can occasionally
            // produce a corrupted/empty capture. Suspending frame delivery
            // for the brief capture window removes that contention entirely.
            self.videoOutput.connection(with: .video)?.isEnabled = false
            self.performCapture()
        }
    }

    private func performCapture() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let rawData = error == nil ? photo.fileDataRepresentation() : nil
        let isValid = Self.isValidImageData(rawData)

        // Belt-and-suspenders: even with frame delivery suspended above, if a
        // capture somehow still comes back empty/corrupt, retry internally a
        // couple of times before giving up — cheap, and spares the user from
        // re-tapping the shutter for what's an internal glitch.
        if !isValid, captureAttempt < maxCaptureAttempts - 1 {
            captureAttempt += 1
            sessionQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.performCapture()
            }
            return
        }

        videoOutput.connection(with: .video)?.isEnabled = true
        let completion = captureCompletion
        captureCompletion = nil
        DispatchQueue.main.async { completion?(isValid ? rawData : nil) }
    }

    /// Confirms the bytes actually decode as a real image, not just
    /// non-empty — a corrupted capture from output contention can come back
    /// as non-zero garbage bytes that still pass an `isEmpty` check.
    private static func isValidImageData(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    // MARK: - Live document detection (auto-capture)

    /// Runs on every video frame — throttled to every 3rd frame since
    /// document detection doesn't need full frame-rate to feel responsive,
    /// and this keeps CPU/thermal load down during what can be a fairly
    /// long "hold it over the bill" moment.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                        from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 3 == 0 else { return }
        guard autoCaptureEnabled, !hasAutoCaptured,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectDocumentSegmentationRequest()
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .right)
        } catch {
            return
        }

        guard let quad = request.results?.first as? VNRectangleObservation else {
            resetStability(guidance: .searching)
            return
        }

        let area = quadArea(quad)
        guard area > 0.15 else {
            resetStability(guidance: .tooSmall)
            return
        }
        guard area < 0.92 else {
            resetStability(guidance: .tooLarge)
            return
        }

        if let last = lastQuad, cornerDistance(quad, last) < 0.03 {
            stableFrameCount += 1
        } else {
            stableFrameCount = 1
        }
        lastQuad = quad

        let stable = stableFrameCount >= requiredStableFrames
        DispatchQueue.main.async { self.guidance = stable ? .capturing : .holdSteady }

        if stable && !hasAutoCaptured {
            hasAutoCaptured = true
            capturePhoto { [weak self] data in
                guard let data else { self?.hasAutoCaptured = false; return }
                DispatchQueue.main.async { self?.onAutoCapture?(data) }
            }
        }
    }

    private func resetStability(guidance: CaptureGuidance) {
        stableFrameCount = 0
        lastQuad = nil
        DispatchQueue.main.async { self.guidance = guidance }
    }

    private func quadArea(_ quad: VNRectangleObservation) -> CGFloat {
        // Shoelace formula on the four normalized corners — good enough for
        // a rough "does this fill a meaningful portion of frame" check.
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var area: CGFloat = 0
        for i in 0..<points.count {
            let j = (i + 1) % points.count
            area += points[i].x * points[j].y
            area -= points[j].x * points[i].y
        }
        return abs(area) / 2
    }

    private func cornerDistance(_ a: VNRectangleObservation, _ b: VNRectangleObservation) -> CGFloat {
        func dist(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
            hypot(p1.x - p2.x, p1.y - p2.y)
        }
        return dist(a.topLeft, b.topLeft) + dist(a.topRight, b.topRight)
            + dist(a.bottomLeft, b.bottomLeft) + dist(a.bottomRight, b.bottomRight)
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

/// A slider with a noticeably thicker track and larger thumb than SwiftUI's
/// native `Slider` (whose track is a thin ~4pt line) — easier to see and to
/// grab precisely for a senior user, since the built-in control isn't
/// customizable to this degree via modifiers alone.
private struct ThickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackHeight: CGFloat = 14
    private let thumbDiameter: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let fillWidth = max(trackHeight, width * fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.yellow)
                    .frame(width: fillWidth, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(radius: 1)
                    .offset(x: min(max(0, width * fraction - thumbDiameter / 2), width - thumbDiameter))
            }
            .frame(height: max(trackHeight, thumbDiameter))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    let clampedX = min(max(0, gesture.location.x), width)
                    let newFraction = Double(clampedX / width)
                    value = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                }
            )
        }
        .frame(height: max(thumbDiameter, trackHeight))
    }
}
