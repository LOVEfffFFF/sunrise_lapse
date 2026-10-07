import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CaptureController()
    @StateObject private var level = LevelMonitor()
    @State private var focusBoxPoint: CGPoint?
    @State private var focusBoxScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreview(
                    session: controller.session,
                    onTap: { layerPoint, devicePoint in
                        controller.focus(at: devicePoint)
                        showFocusBox(at: layerPoint)
                    },
                    onLongPress: { layerPoint, devicePoint in
                        controller.lockFocus(at: devicePoint)
                        showFocusBox(at: layerPoint)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                )
                .ignoresSafeArea()

                // 水平仪：白色基准线 + 实时水平线（与真实地平面平行，水平时变黄重合）
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 160, height: 1)
                    Rectangle()
                        .fill(level.isLevel ? Color.yellow : Color.white)
                        .frame(width: 160, height: 1.5)
                        .rotationEffect(.radians(-level.tilt))
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .allowsHitTesting(false)

                // 对焦框（常驻）。未锁定：连续自动对焦，框只是指示当前对焦区域；
                // 锁定后：边框加粗 + 下方出现锁图标（仿原生 AE/AF 锁定）
                if let point = focusBoxPoint {
                    ZStack {
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: controller.isFocusLocked ? 2.5 : 1.5)
                            .frame(width: 80, height: 80)
                        if controller.isFocusLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                                .offset(y: 52)
                        }
                    }
                    .scaleEffect(focusBoxScale)
                    .position(point)
                    .allowsHitTesting(false)
                }

                VStack {
                    if controller.state == .recording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text(formattedElapsed)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                    }

                    if controller.state == .composing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("正在合成…")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                    }

                    Spacer()

                    // 变焦档位切换（仿原生 .5 / 1 / 2 / 3；仅录制前可切）
                    if controller.lenses.count > 1 {
                        HStack(spacing: 12) {
                            ForEach(Array(controller.lenses.enumerated()), id: \.element.id) { index, lens in
                                Button {
                                    controller.switchLens(to: index)
                                } label: {
                                    Text(lens.label)
                                        .font(.system(.caption, design: .rounded).bold())
                                        .foregroundColor(index == controller.currentLensIndex ? .yellow : .white)
                                        .frame(width: 36, height: 36)
                                        .background(.black.opacity(index == controller.currentLensIndex ? 0.7 : 0.4))
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle().stroke(
                                                index == controller.currentLensIndex ? Color.yellow : Color.clear,
                                                lineWidth: 1.5)
                                        )
                                }
                                .disabled(controller.state != .idle)
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    recordButton
                        .padding(.bottom, 32)
                }
            }
            .onAppear {
                controller.requestAccessAndStart()
                level.start()
                // 初始对焦框显示在画面中心（与默认对焦兴趣点一致）
                focusBoxPoint = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .onDisappear {
                level.stop()
            }
        }
        .alert("提示", isPresented: messagePresented) {
            Button("好") { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
    }

    /// 点按处显示对焦框：先放大出现、收缩到位，之后一直停留（直到点下一处）
    private func showFocusBox(at point: CGPoint) {
        focusBoxPoint = point
        focusBoxScale = 1.3
        withAnimation(.easeOut(duration: 0.2)) {
            focusBoxScale = 1.0
        }
    }

    private var messagePresented: Binding<Bool> {
        Binding(
            get: { controller.message != nil },
            set: { if !$0 { controller.message = nil } }
        )
    }

    private var formattedElapsed: String {
        let total = Int(controller.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private var recordButton: some View {
        Button {
            switch controller.state {
            case .idle:
                controller.startRecording()
            case .recording:
                controller.stopRecording()
            case .composing:
                break
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if controller.state == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(controller.state == .composing ? Color.gray : Color.red)
                        .frame(width: 56, height: 56)
                }
            }
        }
        .disabled(controller.state == .composing)
    }
}

#Preview {
    ContentView()
}
