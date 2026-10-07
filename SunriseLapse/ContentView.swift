import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CaptureController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: controller.session) { devicePoint in
                controller.focus(at: devicePoint)
            }
            .ignoresSafeArea()

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

                // 镜头切换（仿原生 .5 / 1 / 3；仅录制前可切）
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
        }
        .alert("提示", isPresented: messagePresented) {
            Button("好") { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
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
