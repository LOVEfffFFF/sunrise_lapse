import CoreMotion

/// 水平仪：读设备重力向量，算出屏幕平面内的水平倾角（低通滤波防抖）。
/// 用于三脚架构图时把地平线调平，仿原生相机的水平指示。
final class LevelMonitor: ObservableObject {

    /// 设备绕屏幕法线的倾斜角（弧度）。0 = 完全水平
    @Published private(set) var tilt: Double = 0

    private let motion = CMMotionManager()
    private var filtered: Double?

    /// 判定"已水平"的阈值（弧度），约 1°
    static let levelThreshold = Double.pi / 180

    var isLevel: Bool { abs(tilt) < Self.levelThreshold }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            // 竖屏：重力 (0,-1,0) 表示完全水平；倾斜时 x 分量增大
            let angle = atan2(gravity.x, -gravity.y)
            let alpha = 0.2
            let previous = self.filtered ?? angle
            let smoothed = previous + alpha * (angle - previous)
            self.filtered = smoothed
            self.tilt = smoothed
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        filtered = nil
    }
}
