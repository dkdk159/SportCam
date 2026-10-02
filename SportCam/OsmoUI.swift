import SwiftUI
import AVFoundation
import AVKit
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
    /// 音量键 / iPhone 16 相机按钮：按一下切换录制
    let onCaptureButton: () -> Void

    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if #available(iOS 17.2, *) {
            view.addInteraction(AVCaptureEventInteraction { event in
                if event.phase == .ended { onCaptureButton() }
            })
        }
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
    @State private var showDuration = false
    @State private var pinching = false
    @State private var zoomBase: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session,
                          orientation: engine.videoOrientation,
                          onCaptureButton: { engine.toggleRecording() })
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
                statusPill
                Spacer()
                if engine.showLevel {
                    LevelOverlay(sensor: engine.level)
                    Spacer().frame(height: 14)
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

            if showDuration { durationPicker }
        }
        .onAppear { engine.launch() }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
    }

    // MARK: 顶部（左上：剩余空间 + 画质；右上：电量 + 闪光灯）
    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive").font(.system(size: 10))
                    Text("\(engine.freeSpaceText) / \(engine.recordableText)")
                        .font(Palette.mono(11))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.glass)
                .clipShape(Capsule())

                Text("\(engine.quality.rawValue)/\(engine.frameRate.rawValue)")
                    .font(Palette.mono(11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.glass)
                    .clipShape(Capsule())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if engine.voiceListening {
                        Text("🎙")
                            .font(.system(size: 11))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Palette.glass)
                            .clipShape(Capsule())
                    }
                    Text("\(Int(engine.battery * 100))%")
                        .font(Palette.mono(11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Palette.glass)
                        .clipShape(Capsule())
                }
                CircleIcon(icon: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                           active: engine.torchOn,
                           tint: Palette.appleYellow,
                           diameter: 38) {
                    engine.toggleTorch()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: 状态胶囊（预录中 / 录制中 / 保存中）
    @ViewBuilder
    private var statusPill: some View {
        if engine.isBusy {
            HStack(spacing: 7) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Palette.appleYellow))
                    .scaleEffect(0.8)
                Text("正在保存到相册…")
                    .font(Palette.mono(12))
                    .foregroundColor(Palette.appleYellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .padding(.top, 10)
        } else if engine.isRecording {
            HStack(spacing: 7) {
                Circle().fill(Palette.record).frame(width: 9, height: 9)
                Text(timeText(engine.recordSeconds))
                    .font(Palette.mono(17, .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .padding(.top, 10)
        } else {
            Button {
                showDuration = true
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 3)
                            .frame(width: 30, height: 30)
                        if engine.preRecordOn {
                            Circle()
                                .trim(from: 0, to: preRecordProgress)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 30, height: 30)
                                .rotationEffect(.degrees(-90))
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(engine.preRecordOn ? timeText(engine.preRecordSeconds) : "--:--")
                            .font(Palette.mono(15, .bold))
                            .foregroundColor(.white)
                        Text(engine.preRecordOn ? "预录制中" : "未开预录")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.92))
                    }
                    .frame(width: 62, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(engine.preRecordOn ? Palette.accent : Color.black.opacity(0.5))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 10)
        }
    }

    private var preRecordProgress: CGFloat {
        let window = max(engine.preRecordDelay.rawValue, 1)
        return min(max(CGFloat(engine.preRecordSeconds) / CGFloat(window), 0), 1)
    }

    // MARK: 设置预录时长（点预录胶囊 / 点右下角时间按钮都会弹这个）
    private var durationPicker: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { showDuration = false }

            VStack(spacing: 16) {
                Text("设置预录时长")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    durationCell("关闭", value: nil)
                    ForEach(PreRecordDelay.allCases) { delay in
                        durationCell(delay.label, value: delay)
                    }
                }

                Text("预录会在按下录像前先缓存这段时间的画面")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
            .cornerRadius(16)
        }
    }

    private func durationCell(_ title: String, value: PreRecordDelay?) -> some View {
        let selected: Bool = {
            guard let value = value else { return !engine.preRecordOn }
            return engine.preRecordOn && engine.preRecordDelay == value
        }()
        return Button {
            if let value = value {
                engine.preRecordDelay = value
                engine.preRecordOn = true
            } else {
                engine.preRecordOn = false
            }
            showDuration = false
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(selected ? Color(red: 0.13, green: 0.48, blue: 0.95)
                                     : Color.white.opacity(0.10))
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 底部（变焦胶囊 / 功能图标行 / 快门行）
    private var bottomBar: some View {
        VStack(spacing: 16) {
            zoomPill
            toolRow
            shutterRow
        }
        .padding(.bottom, 16)
    }

    private var zoomPill: some View {
        HStack(spacing: 4) {
            ForEach(["0.5x", "1x", "2x"], id: \.self) { chip in
                Button {
                    engine.selectZoomChip(chip)
                } label: {
                    Text(chip)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(zoomSelected(chip) ? .black : .white)
                        .frame(width: 34, height: 34)
                        .background(zoomSelected(chip) ? Color.white : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(engine.isRecording)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolItem("grid", "网格", engine.showGrid) { engine.showGrid.toggle() }
            toolItem("circle.dashed", "水平仪", engine.showLevel) { engine.showLevel.toggle() }
            toolItem("camera.filters", "防抖", engine.antiShake != .off) { cycleAntiShake() }
            toolItem("arrow.triangle.2.circlepath.camera", "镜头", false) { cycleLens() }
            toolItem("speaker.wave.2.fill", "提示音", engine.beepOn) { engine.beepOn.toggle() }
            toolItem("gearshape.fill", "设置", false) { showSettings = true }
        }
        .padding(.horizontal, 8)
    }

    private func toolItem(_ icon: String, _ title: String, _ active: Bool,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(active ? Palette.appleYellow : .white)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(active ? Palette.appleYellow : .white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(engine.isRecording)
        .opacity(engine.isRecording ? 0.4 : 1)
    }

    private var shutterRow: some View {
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

            // 单独的时间入口：点一下就能改预录时长
            CircleIcon(icon: "timer", diameter: 46) { showDuration = true }
        }
        .padding(.horizontal, 34)
    }

    private func cycleAntiShake() {
        let order: [AntiShake] = [.off, .standard, .cinematic, .auto]
        if let index = order.firstIndex(of: engine.antiShake) {
            engine.antiShake = order[(index + 1) % order.count]
        }
    }

    private func cycleLens() {
        let order: [FieldOfView] = [.ultraWide, .wide, .telephoto]
        if let index = order.firstIndex(of: engine.fieldOfView) {
            engine.fieldOfView = order[(index + 1) % order.count]
        }
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
