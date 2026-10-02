import SwiftUI
import AVFoundation
import UIKit

// ============================================================
//  界面：竖屏，布局对齐苹果自带相机；功能保持大疆那套
// ============================================================

private enum Palette {
    static let accent = Color(red: 0.20, green: 0.86, blue: 0.70)
    static let record = Color(red: 1.00, green: 0.23, blue: 0.23)
    static let appleYellow = Color(red: 1.00, green: 0.84, blue: 0.04)
    static let glass = Color.black.opacity(0.42)
    static let border = Color.white.opacity(0.18)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 预览（铺满全屏，和苹果相机一样）
private final class PreviewHost: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: AVCaptureVideoOrientation

    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        apply(view)
        return view
    }

    func updateUIView(_ view: PreviewHost, context: Context) { apply(view) }

    private func apply(_ view: PreviewHost) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}

// MARK: - 小控件
private struct Pill: View {
    let text: String
    var color: Color = .white
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(Palette.mono(size))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.glass)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
    }
}

private struct CircleIcon: View {
    let icon: String
    var active = false
    var tint: Color = Palette.accent
    var diameter: CGFloat = 42
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundColor(active ? tint : .white)
                .frame(width: diameter, height: diameter)
                .background(Palette.glass)
                .clipShape(Circle())
                .overlay(Circle().stroke(active ? tint.opacity(0.75) : Palette.border, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for index in 1..<3 {
                    let x = geo.size.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }
    }
}

private struct LevelOverlay: View {
    @ObservedObject var sensor: LevelSensor

    var body: some View {
        ZStack {
            Circle()
                .stroke(sensor.level ? Palette.accent : Palette.appleYellow, lineWidth: 1.5)
                .frame(width: 54, height: 54)
            Rectangle()
                .fill(sensor.level ? Palette.accent : Palette.appleYellow)
                .frame(width: 34, height: 1)
                .offset(x: CGFloat(sensor.roll * 100))
            Rectangle()
                .fill(sensor.level ? Palette.accent : Palette.appleYellow)
                .frame(width: 1, height: 34)
                .offset(y: CGFloat(sensor.pitch * 100))
            Circle()
                .fill(sensor.level ? Palette.accent : Palette.appleYellow)
                .frame(width: 5, height: 5)
        }
        .opacity(0.85)
    }
}

// MARK: - 主界面
struct CameraScreen: View {
    @ObservedObject var engine: CameraEngine
    @State private var showSettings = false
    @State private var pinching = false
    @State private var zoomBase: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session, orientation: engine.videoOrientation)
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if !pinching { pinching = true; zoomBase = engine.zoom }
                            engine.zoom = min(max(zoomBase * value, 1.0), 6.0)
                        }
                        .onEnded { _ in pinching = false }
                )

            if engine.showGrid { GridOverlay().ignoresSafeArea() }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if engine.showLevel {
                    LevelOverlay(sensor: engine.level)
                    Spacer().frame(height: 18)
                }
                bottomBar
            }

            if let toast = engine.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 200)
                    Spacer()
                }
                .transition(.opacity)
            }

            if engine.debugInfo || engine.showLog {
                VStack {
                    Spacer()
                    Text(engine.logText.isEmpty ? "…" : engine.logText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(red: 0.55, green: 1.0, blue: 0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.62))
                        .cornerRadius(8)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 250)
                }
                .allowsHitTesting(false)
            }

            if engine.dimmed {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20).onEnded { value in
                            // 上滑唤醒
                            if value.translation.height < -50,
                               abs(value.translation.height) > abs(value.translation.width) {
                                engine.wakeUp()
                            }
                        }
                    )
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "chevron.up.2")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.45))
                            Text("省电熄屏中 · 上滑唤醒")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                            if engine.isRecording {
                                Text("录制中 \(timeText(engine.recordSeconds))")
                                    .font(Palette.mono(12))
                                    .foregroundColor(Palette.record.opacity(0.85))
                            }
                        }
                    )
            }
        }
        .onAppear { engine.launch() }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
    }

    // MARK: 顶部（苹果相机：左上闪光灯 / 右上更多）
    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                CircleIcon(icon: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                           active: engine.torchOn,
                           tint: Palette.appleYellow) {
                    engine.toggleTorch()
                }
                Spacer()
                if engine.voiceListening {
                    Pill(text: "🎙 语音", color: Palette.accent)
                }
                Pill(text: "\(Int(engine.battery * 100))%")
                CircleIcon(icon: "ellipsis.circle") { showSettings = true }
            }

            // 录制计时 / 预录中 / 处理中
            if engine.isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Palette.appleYellow))
                        .scaleEffect(0.8)
                    Text("正在保存到相册…")
                        .font(Palette.mono(11))
                        .foregroundColor(Palette.appleYellow)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            } else if engine.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(Palette.record).frame(width: 9, height: 9)
                    Text(timeText(engine.recordSeconds))
                        .font(Palette.mono(17, .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            } else if engine.preRecordOn {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    Text("预录中 · \(engine.preRecordDelay.label)")
                        .font(Palette.mono(11))
                        .foregroundColor(Palette.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.glass)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Palette.accent.opacity(0.6), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: 底部（苹果相机：变焦 / 模式 / 参数 / 快门）
    private var bottomBar: some View {
        VStack(spacing: 14) {
            // 变焦
            HStack(spacing: 14) {
                ForEach(["0.5x", "1x", "2x"], id: \.self) { chip in
                    Button {
                        engine.selectZoomChip(chip)
                    } label: {
                        Text(chip)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(zoomSelected(chip) ? .black : .white)
                            .frame(width: 40, height: 40)
                            .background(zoomSelected(chip) ? Color.white : Color.black.opacity(0.35))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Palette.border, lineWidth: 0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(engine.isRecording)
                }
                if engine.zoom > 1.05 {
                    Text(String(format: "%.1fx", engine.zoom))
                        .font(Palette.mono(12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Palette.glass)
                        .clipShape(Capsule())
                }
            }

            // 模式（苹果相机的黄色选中态）
            HStack(spacing: 22) {
                modeItem(title: "视频", selected: !engine.preRecordOn) {
                    if engine.preRecordOn { engine.preRecordOn = false }
                }
                modeItem(title: "预录", selected: engine.preRecordOn) {
                    if !engine.preRecordOn { engine.preRecordOn = true }
                }
            }

            // 参数行（点击进设置，像苹果相机顶部那个参数条）
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Text("\(engine.quality.rawValue) · \(engine.frameRate.rawValue)fps")
                    Text("·")
                    Text(engine.fieldOfView.rawValue)
                    Text("·")
                    Text("防抖\(engine.antiShake.rawValue)")
                }
                .font(Palette.mono(11))
                .foregroundColor(Palette.appleYellow.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.glass)
                .clipShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(engine.isRecording)
            .opacity(engine.isRecording ? 0.4 : 1)

            // 快门行
            HStack {
                Button {
                    engine.openPhotos()
                } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.glass)
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Palette.border, lineWidth: 0.5)
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button {
                    if engine.isRecording { engine.stopRecording() } else { engine.startRecording() }
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                        if engine.isBusy {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Palette.appleYellow))
                                .scaleEffect(1.4)
                        } else if engine.isRecording {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.record)
                                .frame(width: 34, height: 34)
                        } else {
                            Circle().fill(Palette.record).frame(width: 63, height: 63)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(engine.isBusy)

                Spacer()

                CircleIcon(icon: "arrow.triangle.2.circlepath.camera", diameter: 46) {
                    let order: [FieldOfView] = [.ultraWide, .wide, .telephoto]
                    if let index = order.firstIndex(of: engine.fieldOfView) {
                        engine.fieldOfView = order[(index + 1) % order.count]
                    }
                }
            }
            .padding(.horizontal, 34)
        }
        .padding(.bottom, 18)
    }

    private func modeItem(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .medium))
                .foregroundColor(selected ? Palette.appleYellow : Color.white.opacity(0.6))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(engine.isRecording)
        .opacity(engine.isRecording ? 0.4 : 1)
    }

    private func zoomSelected(_ chip: String) -> Bool {
        switch chip {
        case "0.5x": return engine.fieldOfView == .ultraWide
        case "2x": return engine.fieldOfView == .wide && engine.zoom >= 1.8
        default: return engine.fieldOfView == .wide && engine.zoom < 1.8
        }
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 设置
struct SettingsSheet: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) private var presentation
    @State private var startInput = ""
    @State private var stopInput = ""
    @State private var words: (start: [String], stop: [String]) = ([], [])

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("画面")) {
                    Picker("分辨率", selection: $engine.quality) {
                        ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("帧率", selection: $engine.frameRate) {
                        ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("视角", selection: $engine.fieldOfView) {
                        ForEach(FieldOfView.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                    Picker("防抖", selection: $engine.antiShake) {
                        ForEach(AntiShake.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                }

                Section(header: Text("预录"),
                        footer: Text("开启后持续缓存最近画面，按下录像时会把「按下之前」的画面一起保存。")) {
                    Toggle("开启预录", isOn: $engine.preRecordOn)
                    Picker("预录时长", selection: $engine.preRecordDelay) {
                        ForEach(PreRecordDelay.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!engine.preRecordOn)
                }

                Section(header: Text("语音控制"),
                        footer: Text("开启后说「开始录像」即可开始，说「停止录像」即可结束。")) {
                    Toggle("语音控制", isOn: $engine.voiceOn)
                    HStack {
                        Text("开始口令")
                        Spacer()
                        Text(words.start.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    TextField("自定义开始口令（英文逗号分隔）", text: $startInput)
                    HStack {
                        Text("结束口令")
                        Spacer()
                        Text(words.stop.joined(separator: " / "))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    TextField("自定义结束口令（英文逗号分隔）", text: $stopInput)
                    Button("保存口令") {
                        let start = startInput.isEmpty ? words.start
                            : startInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let stop = stopInput.isEmpty ? words.stop
                            : stopInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        words = (start, stop)
                        engine.setVoiceWords(start: start, stop: stop)
                    }
                }

                Section(header: Text("省电"),
                        footer: Text("熄屏后继续录制，上滑屏幕即可唤醒。")) {
                    Picker("自动熄屏", selection: $engine.powerSave) {
                        ForEach(PowerSaveDelay.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section(header: Text("拍摄辅助")) {
                    Toggle("构图网格", isOn: $engine.showGrid)
                    Toggle("水平仪", isOn: $engine.showLevel)
                    Toggle("录制提示音", isOn: $engine.beepOn)
                }

                Section(header: Text("其它")) {
                    Toggle("显示调试信息", isOn: $engine.debugInfo)
                }
            }
            .navigationBarTitle("设置", displayMode: .inline)
            .navigationBarItems(trailing: Button("完成") { presentation.wrappedValue.dismiss() })
        }
        .onAppear {
            words = (engine.startWords, engine.stopWords)
            startInput = words.start.joined(separator: ",")
            stopInput = words.stop.joined(separator: ",")
        }
        .onDisappear {
            engine.setVoiceWords(start: words.start, stop: words.stop)
        }
    }
}
