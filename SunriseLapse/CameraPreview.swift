import SwiftUI
import AVFoundation

/// 全屏相机预览。
/// 点按：移动对焦/曝光兴趣点（连续自动对焦不变）；长按：锁定对焦。
/// 回调同时给出屏幕坐标（用于画对焦框）和设备坐标（用于设置相机兴趣点）。
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?
    var onLongPress: ((_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        view.addGestureRecognizer(longPress)

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onLongPress: onLongPress)
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onLongPress: ((CGPoint, CGPoint) -> Void)?

        init(onTap: ((CGPoint, CGPoint) -> Void)?, onLongPress: ((CGPoint, CGPoint) -> Void)?) {
            self.onTap = onTap
            self.onLongPress = onLongPress
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onTap?(layerPoint, devicePoint)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let view = gesture.view as? PreviewView else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onLongPress?(layerPoint, devicePoint)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
