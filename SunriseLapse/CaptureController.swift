import AVFoundation
import CoreImage
import UIKit

/// 采集控制器：相机会话、对焦策略、镜头切换、动态间隔抽帧、越档减帧、中断处理。
///
/// 与原生相机的唯一差异：对焦用 continuousAutoFocus + 平滑对焦（原生延时是开始时锁定）。
/// 抽帧间隔复刻原生延时摄影的动态表，成片恒为 20–40 秒 @30fps。
final class CaptureController: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case composing
    }

    /// 一颗可用镜头及其变焦倍率标签（".5" / "1" / "3" 等，仿原生显示）
    struct LensInfo: Identifiable {
        let id = UUID()
        let device: AVCaptureDevice
        let label: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lenses: [LensInfo] = []
    @Published private(set) var currentLensIndex = 0
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

    /// 发现本机所有后置镜头（超广角/广角/长焦），按视野从宽到窄排序
    private func discoverLenses() -> [LensInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let devices = discovery.devices.sorted {
            $0.activeFormat.videoFieldOfView > $1.activeFormat.videoFieldOfView
        }
        let wideFOV = devices.first(where: { $0.deviceType == .builtInWideAngleCamera })?
            .activeFormat.videoFieldOfView ?? 73
        return devices.map { device in
            // 变焦倍率 ≈ 广角视野 / 本镜头视野，取整到 0.5 一档
            let raw = Double(wideFOV / device.activeFormat.videoFieldOfView)
            let factor = (raw * 2).rounded() / 2
            return LensInfo(device: device, label: Self.zoomLabel(factor))
        }
    }

    /// 0.5 → ".5"，1 → "1"，3 → "3"（仿原生相机的显示方式）
    private static func zoomLabel(_ factor: Double) -> String {
        if factor < 1 {
            let s = String(format: "%.1f", factor)
            return s.hasPrefix("0") ? String(s.dropFirst()) : s
        }
        return factor.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(factor)) : String(format: "%.1f", factor)
    }

    /// 必须在 sessionQueue 调用
    private func configureSession() {
        let discovered = discoverLenses()
        // 默认使用广角（1x）；找不到则退回系统默认相机
        let defaultIndex = discovered.firstIndex(where: {
            $0.device.deviceType == .builtInWideAngleCamera
        }) ?? 0

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        let device: AVCaptureDevice
        if discovered.indices.contains(defaultIndex) {
            device = discovered[defaultIndex].device
        } else if let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            device = fallback
        } else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.message = "无法初始化相机" }
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.message = "无法初始化相机" }
            return
        }

        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(videoOutput)
        configureConnection()
        session.commitConfiguration()

        applyCapturePolicy(to: device)

        DispatchQueue.main.async {
            self.lenses = discovered
            self.currentLensIndex = defaultIndex
        }
    }

    /// 预览/采集连接的公共设置；切换镜头后需重设
    private func configureConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // 竖屏
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto // 与原生一致，交给系统
        }
    }

    /// 对焦/曝光策略：本 App 存在的意义。
    /// 连续自动对焦 + 平滑过渡，对焦区域默认画面中心；曝光/白平衡连续自动，与原生一致。
    private func applyCapturePolicy(to device: AVCaptureDevice) {
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

    /// 切换镜头（仅录制前可用；录制中锁定，避免分辨率/视野突变）
    func switchLens(to index: Int) {
        guard state == .idle, index != currentLensIndex, lenses.indices.contains(index) else { return }
        sessionQueue.async {
            let device = self.lenses[index].device
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            guard let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.message = "镜头切换失败" }
                return
            }
            self.session.addInput(input)
            self.configureConnection()
            self.session.commitConfiguration()
            self.applyCapturePolicy(to: device)
            DispatchQueue.main.async { self.currentLensIndex = index }
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

    /// 结束录制并合成
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
