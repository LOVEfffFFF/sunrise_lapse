import AVFoundation
import CoreImage
import UIKit

/// 采集控制器：相机会话、对焦策略、变焦档位切换、动态间隔抽帧、越档减帧、中断处理。
///
/// 与原生相机的唯一差异：对焦用 continuousAutoFocus + 平滑对焦（原生延时是开始时锁定）。
/// 抽帧间隔复刻原生延时摄影的动态表，成片恒为 20–40 秒 @30fps。
final class CaptureController: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case composing
    }

    /// 一个变焦档位（仿原生相机的 0.5 / 1 / 2 / 3）。
    /// 物理镜头 zoomFactor 为 1；2x 这类虚拟档位复用主摄 + 传感器中心裁切（与原生一致）。
    struct LensInfo: Identifiable {
        let id = UUID()
        let device: AVCaptureDevice
        let zoomFactor: CGFloat
        let label: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lenses: [LensInfo] = []
    @Published private(set) var currentLensIndex = 0
    @Published private(set) var isFocusLocked = false
    @Published var message: String?

    private var focusObservation: NSKeyValueObservation?

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

    /// 组装变焦档位列表（仿原生相机）：
    /// 物理镜头（超广角/广角/长焦）按视野从宽到窄排序；
    /// 若长焦 ≥3x，在主摄上补一个 2x 虚拟档位（48MP 中心裁切，如 iPhone 14 Pro 系列）。
    private func discoverLensStops() -> [LensInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let devices = discovery.devices.sorted {
            $0.activeFormat.videoFieldOfView > $1.activeFormat.videoFieldOfView
        }
        let wideDevice = devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        let wideFOV = wideDevice?.activeFormat.videoFieldOfView ?? 73

        func factor(of device: AVCaptureDevice) -> Double {
            let raw = Double(wideFOV / device.activeFormat.videoFieldOfView)
            return (raw * 2).rounded() / 2
        }

        let teleFactor = devices.last(where: { $0.deviceType == .builtInTelephotoCamera }).map(factor) ?? 0

        var stops: [LensInfo] = []
        for device in devices {
            // 在长焦档位前插入主摄 2x 虚拟档位（原生在 3x/5x 长焦机型上均提供 2x）
            if device.deviceType == .builtInTelephotoCamera,
               teleFactor >= 3,
               let wide = wideDevice,
               wide.maxAvailableVideoZoomFactor >= 2 {
                stops.append(LensInfo(device: wide, zoomFactor: 2, label: "2"))
            }
            stops.append(LensInfo(device: device, zoomFactor: 1, label: Self.zoomLabel(factor(of: device))))
        }
        return stops
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
        let discovered = discoverLensStops()
        // 默认使用广角 1x；找不到则退回系统默认相机
        let defaultIndex = discovered.firstIndex(where: {
            $0.device.deviceType == .builtInWideAngleCamera && $0.zoomFactor == 1
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

        applyCapturePolicy(to: device, zoom: 1)

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

    /// 变焦倍率 + 对焦/曝光策略（本 App 存在的意义）：
    /// 连续自动对焦 + 平滑过渡，对焦区域默认画面中心；曝光/白平衡连续自动，与原生一致。
    private func applyCapturePolicy(to device: AVCaptureDevice, zoom: CGFloat) {
        do {
            try device.lockForConfiguration()
            let clampedZoom = max(1, min(zoom, device.maxAvailableVideoZoomFactor))
            if device.videoZoomFactor != clampedZoom {
                device.videoZoomFactor = clampedZoom
            }
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

    /// 切换变焦档位（仅录制前可用；录制中锁定，避免视野/分辨率突变）。
    /// 同一颗镜头的档位切换（如 1x ↔ 2x）只改变焦倍率，不重建输入。
    func switchLens(to index: Int) {
        guard state == .idle, index != currentLensIndex, lenses.indices.contains(index) else { return }
        sessionQueue.async {
            let stop = self.lenses[index]
            let current = self.lenses[self.currentLensIndex]

            if stop.device.uniqueID == current.device.uniqueID {
                // 同一颗镜头：只调 videoZoomFactor（中心裁切），会话不动
                self.applyCapturePolicy(to: stop.device, zoom: stop.zoomFactor)
            } else {
                self.session.beginConfiguration()
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                guard let input = try? AVCaptureDeviceInput(device: stop.device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.message = "镜头切换失败" }
                    return
                }
                self.session.addInput(input)
                self.configureConnection()
                self.session.commitConfiguration()
                self.applyCapturePolicy(to: stop.device, zoom: stop.zoomFactor)
            }
            DispatchQueue.main.async {
                self.currentLensIndex = index
                self.isFocusLocked = false // 切换档位后回到连续自动对焦
            }
        }
    }

    /// 点按：移动对焦/曝光兴趣点。连续自动对焦保持不变（焦点距离仍随场景自动调整，
    /// 太阳移动、光线变化都会持续重新合焦）。若此前处于锁定态，点按即解锁并回到连续自动
    ///（仿原生相机：锁定后点别处自动解锁）。
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            self.focusObservation?.invalidate()
            self.focusObservation = nil
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.focusMode == .locked {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = true
                    }
                }
                if device.exposureMode == .locked,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isFocusLocked = false }
            } catch {}
        }
    }

    /// 长按：锁定对焦/曝光在该点（仿原生相机的 AE/AF 锁定）。
    /// 先在该点做一次单次对焦，合焦完成后才锁定镜头位置；3 秒未合焦也强制锁定兜底。
    /// 只有锁定后对焦才真正固定，未锁定时永远连续自动。
    func lockFocus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            self.focusObservation?.invalidate()
            self.focusObservation = nil
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus // 单次对焦，合焦后由 KVO 转锁定
                }
                device.unlockForConfiguration()
            } catch {
                return
            }

            let lockNow: (AVCaptureDevice) -> Void = { dev in
                do {
                    try dev.lockForConfiguration()
                    if dev.isFocusModeSupported(.locked) {
                        dev.focusMode = .locked
                    }
                    if dev.isExposureModeSupported(.locked) {
                        dev.exposureMode = .locked
                    }
                    dev.unlockForConfiguration()
                    DispatchQueue.main.async { self.isFocusLocked = true }
                } catch {}
            }

            // 等合焦完成后锁定（KVO）
            self.focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] dev, change in
                guard let self, change.newValue == false else { return }
                self.focusObservation?.invalidate()
                self.focusObservation = nil
                lockNow(dev)
            }
            // 暗光下可能迟迟不合焦：3 秒强制锁定兜底
            self.sessionQueue.asyncAfter(deadline: .now() + 3) {
                guard self.focusObservation != nil else { return }
                self.focusObservation?.invalidate()
                self.focusObservation = nil
                lockNow(device)
            }
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
        // 竖屏：传感器横向缓冲需逆时针旋转 90° 才是正立竖屏（1080x1920）。
        // 注意是 .left：用 .right 会转出倒立 180° 的帧
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.left)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace) else { return }
        store.saveFrame(jpeg: jpeg)
    }
}
