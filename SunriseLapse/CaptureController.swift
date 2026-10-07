import AVFoundation
import CoreImage
import UIKit

/// 采集控制器：相机会话、对焦策略、动态间隔抽帧、越档减帧、中断处理。
///
/// 与原生相机的唯一差异：对焦用 continuousAutoFocus + 平滑对焦（原生延时是开始时锁定）。
/// 抽帧间隔复刻原生延时摄影的动态表，成片恒为 20–40 秒 @30fps。
final class CaptureController: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case composing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var message: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.sunriselapse.session")
    private let captureQueue = DispatchQueue(label: "com.sunriselapse.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()

    private var frameStore: FrameStore?
    private var recordStart: Date?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var elapsedTimer: Timer?
    private var currentTier = 0

    /// 原生延时摄影动态间隔表：(起始秒数, 每秒抽帧数)
    /// 0–10min: 2fps | 10–20min: 1fps | 20–40min: 0.5fps | 之后每档间隔翻倍
    private let tiers: [(threshold: TimeInterval, fps: Double)] = [
        (0, 2), (600, 1), (1200, 0.5), (2400, 0.25), (4800, 0.125), (9600, 0.0625), (19200, 0.03125)
    ]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    // MARK: - 权限与配置

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.configureAndRun()
                } else {
                    DispatchQueue.main.async { self.message = "需要相机权限才能拍摄" }
                }
            }
        default:
            DispatchQueue.main.async { self.message = "相机权限被拒绝，请在系统设置中开启" }
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            self.configureSession()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// 必须在 sessionQueue 调用
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.message = "无法初始化相机" }
            return
        }

        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90 // 竖屏
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto // 与原生一致，交给系统
            }
        }
        session.commitConfiguration()

        // 对焦：本 App 存在的意义。连续自动对焦 + 平滑过渡，对焦区域默认画面中心。
        // 曝光/白平衡保持连续自动，与原生拍照一致。
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // 配置失败不致命，系统会回退到默认模式
        }
    }

    /// 点按对焦/曝光（原生手势）。保持连续模式，仅移动兴趣点。
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - 录制控制

    func startRecording() {
        guard state == .idle else { return }
        do {
            frameStore = try FrameStore()
        } catch {
            message = "无法创建帧缓存目录"
            return
        }
        recordStart = Date()
        lastFrameTimestamp = 0
        currentTier = 0
        elapsed = 0
        state = .recording
        UIApplication.shared.isIdleTimerDisabled = true

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        finishRecording(saveResult: true)
    }

    private func tick() {
        guard let start = recordStart else { return }
        let e = Date().timeIntervalSince(start)
        elapsed = e

        // 越档检查：每跨一档，已拍帧隔帧丢弃一半（复刻原生）
        var newTier = currentTier
        for (i, tier) in tiers.enumerated() where e >= tier.threshold {
            newTier = i
        }
        if newTier > currentTier {
            let steps = newTier - currentTier
            currentTier = newTier
            captureQueue.async {
                for _ in 0..<steps {
                    self.frameStore?.decimate()
                }
            }
        }
    }

    /// 结束录制并合成。interrupted=true 时表示被系统打断（来电/锁屏等）
    private func finishRecording(saveResult: Bool) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false

        guard let store = frameStore else {
            state = .idle
            return
        }
        state = .composing

        captureQueue.async {
            let urls = store.frameURLs()
            guard saveResult, !urls.isEmpty else {
                store.cleanup()
                DispatchQueue.main.async {
                    self.frameStore = nil
                    self.recordStart = nil
                    self.state = .idle
                    self.elapsed = 0
                }
                return
            }
            TimelapseComposer.compose(frameURLs: urls) { result in
                store.cleanup()
                DispatchQueue.main.async {
                    self.frameStore = nil
                    self.recordStart = nil
                    self.state = .idle
                    self.elapsed = 0
                    switch result {
                    case .success:
                        self.message = "已保存到相册（\(urls.count) 帧）"
                    case .failure(let error):
                        self.message = "保存失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - 中断处理（来电、锁屏、其他 App 抢相机）

    @objc private func sessionInterrupted(_ notification: Notification) {
        DispatchQueue.main.async {
            if self.state == .recording {
                self.message = "拍摄被系统中断，正在保存已录部分…"
                self.finishRecording(saveResult: true)
            }
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: - 抽帧（capture 队列）

    private func currentFPS() -> Double {
        tiers[currentTier].fps
    }
}

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard state == .recording, recordStart != nil, let store = frameStore else { return }

        let interval = 1.0 / currentFPS()
        let now = CACurrentMediaTime()
        guard now - lastFrameTimestamp >= interval else { return }
        lastFrameTimestamp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 竖屏：传感器横向输出旋转 90°，烘焙进 JPEG（1080x1920）
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace) else { return }
        store.saveFrame(jpeg: jpeg)
    }
}
