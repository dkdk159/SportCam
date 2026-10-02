import SwiftUI
import AVFoundation
import UIKit

// ============================================================
//  界面：横屏专业风格（仿大疆 Osmo Action 机身）
// ============================================================

private enum Palette {
    static let accent = Color(red: 0.20, green: 0.86, blue: 0.70)
    static let record = Color(red: 1.00, green: 0.22, blue: 0.22)
    static let warn = Color(red: 1.00, green: 0.76, blue: 0.28)
    static let panel = Color.black.opacity(0.45)
    static let border = Color.white.opacity(0.16)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 预览
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
        view.previewLayer.videoGravity = .resizeAspect
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

// MARK: - 基础控件
private struct GlassLabel: View {
    let text: String
    var color: Color = .white
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(Palette.mono(size))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
    }
}

private struct RoundButton: View {
    let icon: String
    var active = false
    var tint: Color = Palette.accent
    var diameter: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundColor(active ? tint : .white)
                .frame(width: diameter, height: diameter)
                .background(Palette.panel)
                .clipShape(Circle())
                .overlay(Circle().stroke(active ? tint.opacity(0.75) : Palette.border, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 右上角参数胶囊：点开就是选项列表（大疆那种参数浮层）
private struct ParamMenu<Item: Hashable & Identifiable>: View {
    let title: String
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection {
                        Label(label(item), systemImage: "checkmark")
                    } else {
                        Text(label(item))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.55))
                Text(label(selection)).font(Palette.mono(12)).foregroundColor(Palette.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
        }
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
                .stroke(sensor.level ? Palette.accent : Palette.warn, lineWidth: 1.5)
                .frame(width: 56, height: 56)
            Rectangle()
                .fill(sensor.level ? Palette.accent : Palette.warn)
                .frame(width: 36, height: 1)
                .offset(x: CGFloat(sensor.roll * 100))
            Rectangle()
                .fill(sensor.level ? Palette.accent : Palette.warn)
                .frame(width: 1, height: 36)
                .offset(y: CGFloat(sensor.pitch * 100))
            Circle()
                .fill(sensor.level ? Palette.accent : Palette.warn)
                .frame(width: 5, height: 5)
        }
        .opacity(0.85)
    }
}

// MARK: - 主界面
struct OsmoScreen: View {
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

            // 左右两侧面板
            HStack(alignment: .center, spacing: 0) {
                modePanel
                Spacer()
                parameterPanel
            }
            .padding(.horizontal, 14)

            VStack(spacing: 0) {
                statusBar
                Spacer()
                if engine.showLevel {
                    LevelOverlay(sensor: engine.level).padding(.bottom, 6)
                }
                controlBar
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
                        .padding(.bottom, 110)
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
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }

            if engine.dimmed {
                Color.black.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20).onEnded { value in
                            // 上滑唤醒（横屏下依然按屏幕坐标判断向上）
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

    // MARK: 顶部状态
    private var statusBar: some View {
        HStack(spacing: 10) {
            if engine.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(Palette.record).frame(width: 9, height: 9)
                    Text(timeText(engine.recordSeconds))
                        .font(Palette.mono(18, .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            } else {
                GlassLabel(text: "待机", color: .white.opacity(0.75))
            }

            if engine.preRecordOn {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    Text("预录中").font(Palette.mono(11)).foregroundColor(Palette.accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.panel)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Palette.accent.opacity(0.6), lineWidth: 0.5))
            }

            Spacer()

            if engine.voiceListening {
                GlassLabel(text: "🎙 语音", color: Palette.accent)
            }
            if engine.torchOn {
                GlassLabel(text: "🔦", color: Palette.warn)
            }
            GlassLabel(text: "\(Int(engine.battery * 100))%")
            RoundButton(icon: "slider.horizontal.3", diameter: 34) { showSettings = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: 左侧拍摄模式
    private var modePanel: some View {
        VStack(spacing: 10) {
            modeButton(title: "视频", icon: "video.fill", selected: !engine.preRecordOn) {
                if engine.preRecordOn { engine.preRecordOn = false }
            }
            modeButton(title: "预录", icon: "backward.end.fill", selected: engine.preRecordOn) {
                if !engine.preRecordOn { engine.preRecordOn = true }
            }
            Spacer()
        }
        .frame(width: 62)
    }

    private func modeButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(selected ? Palette.accent : .white)
            .frame(width: 58, height: 58)
            .background(selected ? Palette.accent.opacity(0.18) : Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.8) : Palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(engine.isRecording)
        .opacity(engine.isRecording ? 0.45 : 1)
    }

    // MARK: 右侧参数
    private var parameterPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ParamMenu(title: "分辨率", items: VideoQuality.allCases, label: { $0.rawValue }, selection: $engine.quality)
            ParamMenu(title: "帧率", items: FrameRate.allCases, label: { $0.label }, selection: $engine.frameRate)
            ParamMenu(title: "防抖", items: AntiShake.allCases, label: { $0.rawValue }, selection: $engine.antiShake)
            ParamMenu(title: "视角", items: FieldOfView.allCases, label: { $0.rawValue }, selection: $engine.fieldOfView)
            if engine.preRecordOn {
                ParamMenu(title: "预录", items: PreRecordDelay.allCases, label: { $0.label }, selection: $engine.preRecordDelay)
            }
            Spacer()
        }
        .frame(width: 128)
    }

    // MARK: 底部控制
    private var controlBar: some View {
        HStack(alignment: .center) {
            // 变焦
            HStack(spacing: 6) {
                ForEach(["0.5x", "1x", "2x"], id: \.self) { chip in
                    Button {
                        engine.selectZoomChip(chip)
                    } label: {
                        Text(chip)
                            .font(Palette.mono(12))
                            .foregroundColor(zoomChipSelected(chip) ? .black : .white)
                            .frame(width: 42, height: 30)
                            .background(zoomChipSelected(chip) ? Color.white : Palette.panel)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Palette.border, lineWidth: 0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(engine.isRecording)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 快门
            Button {
                if engine.isRecording { engine.stopRecording() } else { engine.startRecording() }
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 84, height: 84)
                    if engine.isRecording {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.record)
                            .frame(width: 36, height: 36)
                    } else {
                        Circle().fill(Palette.record).frame(width: 68, height: 68)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())

            HStack(spacing: 8) {
                RoundButton(icon: "photo.on.rectangle", diameter: 40) { engine.openPhotos() }
                RoundButton(icon: "arrow.left.arrow.right.circle", diameter: 40) {
                    let order: [FieldOfView] = [.ultraWide, .wide, .telephoto]
                    if let index = order.firstIndex(of: engine.fieldOfView) {
                        engine.fieldOfView = order[(index + 1) % order.count]
                    }
                }
                RoundButton(icon: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            active: engine.torchOn, tint: Palette.warn, diameter: 40) {
                    engine.toggleTorch()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 14)
    }

    private func zoomChipSelected(_ chip: String) -> Bool {
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
                        applyWords()
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
        .onDisappear { applyWords() }
    }

    private func applyWords() {
        // 语音口令直接写回引擎（引擎持有 VoiceControl）
        engine.setVoiceWords(start: words.start, stop: words.stop)
    }
}
