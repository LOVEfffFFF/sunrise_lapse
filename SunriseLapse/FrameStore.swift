import Foundation

/// JPEG 帧缓存：按序写入临时目录；越档时隔帧删除一半并重排编号。
/// 所有变更方法必须在同一串行队列（capture 队列）调用。
final class FrameStore {
    private let directory: URL
    private let lock = NSLock()
    private var _frameCount = 0

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SunriseLapseFrames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for index: Int, prefix: String = "") -> URL {
        directory.appendingPathComponent(String(format: "%@%08d.jpg", prefix, index))
    }

    /// 追加一帧（capture 队列调用）
    func saveFrame(jpeg: Data) {
        lock.lock()
        let index = _frameCount
        lock.unlock()
        try? jpeg.write(to: url(for: index), options: .atomic)
        lock.lock()
        _frameCount = index + 1
        lock.unlock()
    }

    /// 隔帧丢弃一半（capture 队列调用）。复刻原生「越档丢一半已拍帧」。
    func decimate() {
        lock.lock()
        let total = _frameCount
        lock.unlock()

        let fm = FileManager.default
        var kept = 0
        for i in 0..<total {
            let src = url(for: i)
            if i % 2 == 0 {
                try? fm.moveItem(at: src, to: url(for: kept, prefix: "k"))
                kept += 1
            } else {
                try? fm.removeItem(at: src)
            }
        }
        for i in 0..<kept {
            try? fm.moveItem(at: url(for: i, prefix: "k"), to: url(for: i))
        }

        lock.lock()
        _frameCount = kept
        lock.unlock()
    }

    /// 按拍摄顺序返回所有帧文件（录制停止后调用）
    func frameURLs() -> [URL] {
        (0..<frameCount).map { url(for: $0) }
    }

    /// 删除整个临时目录
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
