import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine

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
    /// 前置摄像头时预览要镜像（录制出来的画面仍是非镜像）
    let mirrored: Bool
    /// 音量键 / iPhone 16 相机按钮：按一下切换录制
    let onCaptureButton: () -> Void
    /// 点按画面：分别给出「设备坐标」（给对焦用）和「屏幕坐标」（给对焦框用）
    let onFocusPoint: (CGPoint, CGPoint) -> Void

    final class Coordinator: NSObject {
        weak var view: PreviewHost?
        var onFocusPoint: (CGPoint, CGPoint) -> Void = { _, _ in }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = view else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onFocusPoint(devicePoint, layerPoint)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewHost {
        let view = PreviewHost()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if #available(iOS 17.2, *) {
            view.addInteraction(AVCaptureEventInteraction { event in
                if event.phase == .ended { onCaptureButton() }
            })
        }
        context.coordinator.view = view
        context.coordinator.onFocusPoint = onFocusPoint
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        apply(view)
        return view
    }

    func updateUIView(_ view: PreviewHost, context: Context) {
        context.coordinator.view = view
        context.coordinator.onFocusPoint = onFocusPoint
        apply(view)
    }

    private func apply(_ view: PreviewHost) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
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

/// 焦段档位（0.5x / 1x / 2x）。
/// 选中状态用动画过渡 —— 直接硬切会"啪"地闪一下，看着像是在重新加载画面。
private struct ZoomChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(selected ? .black : .white)
                .frame(width: 34, height: 34)
                .background(selected ? Color.white : Color.clear)
                .clipShape(Circle())
                .scaleEffect(selected ? 1.0 : 0.94)
                .animation(.easeOut(duration: 0.18), value: selected)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 预览上的水印：只是位置示意，真正烧进视频的那一份在导出时绘制。
/// 行内容由引擎按当前勾选项拼好，和烧录共用同一套拼法。
private struct WatermarkPreview: View {
    @ObservedObject var engine: CameraEngine
    let bottomInset: CGFloat
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let lines = engine.watermarkLines(at: now)
        // 和烧进视频的比例一致：字号按屏高算、整块宽度限制在屏宽 66%，
        // 地址长了会自己折行，不会甩出一条横贯全屏的长线。
        let fontSize = max(UIScreen.main.bounds.height * 0.0175, 11)
        let maxWidth = UIScreen.main.bounds.width * 0.66

        return VStack(alignment: .leading, spacing: fontSize * 0.26) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .frame(width: maxWidth, alignment: .leading)
        // 和烧进视频的一致：不铺黑底，白字 + 描边阴影，画面干净
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.9), radius: fontSize * 0.16, x: 0, y: 0.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 12)
        .padding(.bottom, bottomInset)
        .onReceive(tick) { now = $0 }
        .allowsHitTesting(false)
    }
}

/// 构图网格：三分线。
/// 用 1 物理像素的实线 + 很淡的白，取景器那种细线；不用虚线（虚线太像演示稿，
/// 亮场景下反而更抢眼）。线外压一层极淡暗影，白墙上也看得见。
private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let hairline = 1 / UIScreen.main.scale
            Path { path in
                for index in 1..<3 {
                    let x = (geo.size.width * CGFloat(index) / 3).rounded()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))

                    let y = (geo.size.height * CGFloat(index) / 3).rounded()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: hairline)
            .shadow(color: .black.opacity(0.20), radius: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// 水平尺：一段固定基准线 + 一条随倾角转动的指示线，上方带角度读数。
/// 两条线重合成一条直线就是水平（此时整条尺变绿），和相机/摄像机上的一样。
private struct LevelOverlay: View {
    @ObservedObject var sensor: LevelSensor

    /// roll 是弧度，水平尺上显示成角度更直观
    private var degrees: Double { sensor.roll * 180 / .pi }

    var body: some View {
        let leveled = sensor.level
        let tint = leveled ? Palette.accent : Color.white.opacity(0.92)

        return VStack(spacing: 6) {
            Text(String(format: "%+.1f°", degrees))
                .font(Palette.mono(10, .semibold))
                .foregroundColor(leveled ? Palette.accent : .white.opacity(0.65))

            ZStack {
                // 左右两段固定基准线，中间留出位置给指示线
                HStack(spacing: 16) {
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: 56, height: 1.5)
                    Capsule().fill(Color.white.opacity(0.5)).frame(width: 56, height: 1.5)
                }
                // 指示线：跟着手机倾斜转，和基准线对齐即水平
                Capsule()
                    .fill(tint)
                    .frame(width: 46, height: 2)
                    .rotationEffect(.radians(sensor.roll))
                    .shadow(color: leveled ? Palette.accent.opacity(0.9) : .clear, radius: 4)
                    .animation(.linear(duration: 0.08), value: sensor.roll)
            }
            .frame(width: 150, height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// 只有部分角是圆角
private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

/// 横向刻度滑杆：点哪儿就选哪儿，也可以按住不放继续微调
private struct RulerSlider: View {
    let value: Double                 // 0...1
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack {
                HStack(spacing: 0) {
                    ForEach(0..<40, id: \.self) { index in
                        Rectangle()
                            .fill(index % 5 == 0 ? Color.white.opacity(0.5) : Color.white.opacity(0.18))
                            .frame(width: 1, height: index % 5 == 0 ? 18 : 10)
                            .frame(maxWidth: .infinity)
                    }
                }
                Rectangle()
                    .fill(Palette.appleYellow)
                    .frame(width: 2, height: 28)
                    .offset(x: CGFloat(value - 0.5) * (width - 16))
            }
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance: 0 —— 按下的瞬间就生效，点哪儿选哪儿；
                // 手指不离开继续拖动就是微调。
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let usable = max(width - 16, 1)
                        let t = Double((gesture.location.x - 8) / usable)
                        onChange(min(max(t, 0), 1))
                    }
            )
        }
        .frame(height: 40)
    }
}

// MARK: - 主界面
struct CameraScreen: View {
    @ObservedObject var engine: CameraEngine
    @State private var showSettings = false
    @State private var showDuration = false
    @State private var showFormat = false
    @State private var showWatermark = false
    @State private var showDescEdit = false
    @State private var pinching = false
    @State private var zoomBase: CGFloat = 1.0
    @State private var focusReticle: CGPoint?
    /// 水印面板打开时每秒推一下：时间行会走字，定位/天气晚回来也能立刻显示
    private let panelTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: engine.session,
                          orientation: engine.videoOrientation,
                          mirrored: engine.cameraPosition == .front,
                          onCaptureButton: {
                              // 音量键 / iPhone 16 相机按钮 → 切换录制（设置里可关）
                              if engine.volumeKeyRecording { engine.toggleRecording() }
                          },
                          onFocusPoint: { devicePoint, layerPoint in
                              engine.focus(atDevicePoint: devicePoint)
                              withAnimation(.easeOut(duration: 0.12)) { focusReticle = layerPoint }
                              DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                  withAnimation(.easeIn(duration: 0.25)) { focusReticle = nil }
                              }
                          })
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

            // 水印：开启才显示，位置对齐最终烧进视频的左下角
            if engine.watermarkOn {
                WatermarkPreview(engine: engine,
                                 bottomInset: engine.proControl != nil ? 300 : 148)
            }

            if let point = focusReticle {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Palette.appleYellow, lineWidth: 1.5)
                    .frame(width: 76, height: 76)
                    .position(point)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                statusPill
                Spacer()
                if engine.showLevel {
                    LevelOverlay(sensor: engine.level)
                    Spacer().frame(height: 14)
                }
                // 参数面板贴在底栏上方：快门按钮始终露在外面
                if let control = engine.proControl {
                    proSheet(control)
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

            if showDuration && engine.proControl == nil { durationPicker }
            if showFormat && engine.proControl == nil { formatPicker }
            if showWatermark { watermarkPicker }
        }
        .onAppear { engine.launch() }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
    }

    // MARK: 顶部（左上：剩余空间 + 画质；右上：电量 + 闪光灯）
    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if engine.showStorage {
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
                }

                // 画质胶囊：分辨率 + 帧率，点一下就能改
                Button {
                    showFormat = true
                } label: {
                    HStack(spacing: 5) {
                        Text("\(engine.quality.rawValue)/\(engine.frameRate.rawValue)fps")
                            .font(Palette.mono(11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.75)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.glass)
                    .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(engine.isRecording)
                .opacity(engine.isRecording ? 0.5 : 1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if engine.voiceListening {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Palette.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
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
                HStack(spacing: 8) {
                    CircleIcon(icon: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                               active: engine.torchOn,
                               tint: Palette.appleYellow,
                               diameter: 38) {
                        engine.toggleTorch()
                    }
                    // 翻转：前/后摄像头切换。原来藏在设置里，挪到屏幕上单手就能切
                    CircleIcon(icon: "arrow.triangle.2.circlepath.camera",
                               active: engine.cameraPosition == .front,
                               diameter: 38) {
                        engine.toggleCamera()
                    }
                    .disabled(engine.isRecording)
                    .opacity(engine.isRecording ? 0.4 : 1)
                    CircleIcon(icon: "gearshape.fill", diameter: 38) { showSettings = true }
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
            // 这里是"预录快捷键"：点一下直接开关预录；预录时长在右下角的计时器按钮里设
            Button {
                engine.preRecordOn.toggle()
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
                        // 没开预录时只显示设置好的时长（时长在右下角计时器按钮里改）
                        Text(engine.preRecordOn ? timeText(engine.preRecordSeconds)
                                                : engine.preRecordDelay.label)
                            .font(Palette.mono(15, .bold))
                            .foregroundColor(.white)
                        Text(engine.preRecordOn ? "预录制中" : "预录时长")
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

    // MARK: 设置预录时长（右下角计时器按钮）
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

    // MARK: 分辨率 + 帧率（点顶部画质胶囊弹出）
    private var formatPicker: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { showFormat = false }

            VStack(spacing: 14) {
                Text("分辨率")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                HStack(spacing: 10) {
                    ForEach(VideoQuality.allCases) { item in
                        formatCell(item.rawValue, selected: engine.quality == item) {
                            engine.quality = item
                        }
                    }
                }

                Text("帧率")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 2)

                HStack(spacing: 10) {
                    ForEach(FrameRate.allCases) { item in
                        formatCell("\(item.rawValue)fps", selected: engine.frameRate == item) {
                            engine.frameRate = item
                        }
                    }
                }

                Text(engine.isRecording ? "录制中不能改分辨率和帧率"
                                        : "分辨率越高越清晰，帧率越高越流畅，文件也越大")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))

                Button {
                    showFormat = false
                } label: {
                    Text("完成")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white)
                        .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)
            .frame(maxWidth: 330)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
            .cornerRadius(16)
        }
    }

    private func formatCell(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .disabled(engine.isRecording)
        .opacity(engine.isRecording ? 0.5 : 1)
    }

    // MARK: 水印面板（逐项勾选，勾上立刻出现在画面上；卡片靠上，不挡左下角的水印预览）
    private var watermarkPicker: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showWatermark = false }

            VStack(spacing: 0) {
                Spacer().frame(height: 76)
                card
                Spacer()
            }
        }
        .sheet(isPresented: $showDescEdit) {
            DescEditorView(initial: engine.watermarkData.desc) { engine.setWatermarkDesc($0) }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            // 总开关
            HStack(spacing: 0) {
                watermarkMaster("关闭", on: !engine.watermarkOn) { engine.watermarkOn = false }
                watermarkMaster("开启", on: engine.watermarkOn) { engine.watermarkOn = true }
            }
            .padding(4)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(WatermarkItem.allCases.enumerated()), id: \.element.id) { index, item in
                        watermarkRow(item)
                        if index < WatermarkItem.allCases.count - 1 {
                            Divider().background(Color.white.opacity(0.10))
                        }
                    }
                }
            }
            .frame(maxHeight: 268)

            Text("数据来自系统定位与 Open-Meteo 天气，勾上即刻显示")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))

            Button {
                showWatermark = false
            } label: {
                Text("完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white)
                    .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(18)
        .frame(maxWidth: 340)
        .background(Color(red: 0.15, green: 0.15, blue: 0.16))
        .cornerRadius(16)
        // 面板开着时每秒推一次：时间会走字，定位/天气晚回来也能马上填上
        .onReceive(panelTick) { _ in engine.refreshWatermarkIfNeeded() }
    }

    private func watermarkMaster(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(on ? .black : .white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(on ? Color.white : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func watermarkRow(_ item: WatermarkItem) -> some View {
        let on = engine.watermarkItems.contains(item)
        return HStack(spacing: 10) {
            Button {
                engine.toggleWatermarkItem(item, on: !on)
            } label: {
                ZStack {
                    Capsule()
                        .fill(on ? Palette.accent : Color.white.opacity(0.22))
                        .frame(width: 42, height: 25)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 21, height: 21)
                        .offset(x: on ? 8.5 : -8.5)
                }
                .animation(.easeOut(duration: 0.16), value: on)
            }
            .buttonStyle(PlainButtonStyle())

            Text(item.rawValue)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 8)

            if item == .desc {
                Button {
                    showDescEdit = true
                } label: {
                    HStack(spacing: 4) {
                        Text(engine.watermarkValue(item))
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(engine.watermarkValue(item))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: 底部（变焦胶囊 / 快门行 + 参数按钮）
    private var bottomBar: some View {
        VStack(spacing: 14) {
            zoomPill
            shutterRow
        }
        .padding(.bottom, 16)
    }

    private var zoomPill: some View {
        HStack(spacing: 4) {
            // 档位已按机型过滤：没有超广角就只给广角 / 长焦，不会摆出点不动的档
            ForEach(engine.zoomChips, id: \.self) { chip in
                ZoomChip(label: chip, selected: engine.isZoomChipSelected(chip)) {
                    engine.selectZoomChip(chip)
                }
                .disabled(engine.isRecording)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private var shutterRow: some View {
        ZStack {
            // 快门永远钉在屏幕正中央
            shutterButton

            HStack(spacing: 14) {
                // 左：相册 + 专业参数
                CircleIcon(icon: "photo.on.rectangle", diameter: 46) {
                    engine.openPhotos()
                }
                proToggleButton

                Spacer(minLength: 8)

                // 右：水印 + 预录时长
                watermarkButton
                CircleIcon(icon: "timer", diameter: 46) { showDuration = true }
            }
        }
        .padding(.horizontal, 20)
    }

    /// 水印：点开面板，逐项勾选（时间/地点/描述/海拔/天气/温度/气压/风速）
    private var watermarkButton: some View {
        Button {
            showWatermark = true
            engine.ensureWatermarkStarted()
        } label: {
            Text("水印时间")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(engine.watermarkOn ? .black : .white)
                .padding(.horizontal, 13)
                .frame(height: 46)
                .background(engine.watermarkOn ? Palette.accent : Palette.glass)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(engine.watermarkOn ? Color.clear : Palette.border, lineWidth: 0.5))
                .animation(.easeOut(duration: 0.18), value: engine.watermarkOn)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// 一个按钮管全部专业参数：点开面板，里面六项随便切
    private var proToggleButton: some View {
        Button {
            setPro(engine.proControl == nil ? .exposure : nil)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(engine.proControl != nil ? .black : .white)
                .frame(width: 46, height: 46)
                .background(engine.proControl != nil ? Color.white : Palette.glass)
                .clipShape(Circle())
                .overlay(Circle().stroke(Palette.border, lineWidth: 0.5))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var shutterButton: some View {
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
    }

    // MARK: 专业参数面板（贴在底栏上方，六项在这里直接切换）
    private func proSheet(_ control: ProControl) -> some View {
        let rangeText = engine.proRangeText(control)
        return VStack(spacing: 12) {
            // 六项全在面板里，点一下就换；每项显示实时数值（自动模式下会一直跳）
            HStack(spacing: 4) {
                ForEach(ProControl.allCases) { item in
                    Button {
                        setPro(item)
                    } label: {
                        VStack(spacing: 3) {
                            Text(engine.proShort(item))
                                .font(Palette.mono(12, .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(item.rawValue)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .foregroundColor(item == control
                                         ? .black
                                         : (engine.proIsManual(item) ? Palette.appleYellow : .white))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(item == control ? Color.white : Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                // 网格：一键开关构图辅助线
                Button {
                    engine.showGrid.toggle()
                } label: {
                    VStack(spacing: 3) {
                        Text(engine.showGrid ? "开" : "关")
                            .font(Palette.mono(12, .semibold))
                        Text("网格")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundColor(engine.showGrid ? Palette.appleYellow : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PlainButtonStyle())
            }

            HStack(spacing: 10) {
                Text(engine.proDisplay(control))
                    .font(Palette.mono(15, .semibold))
                    .foregroundColor(engine.proIsManual(control) ? Palette.appleYellow : .white.opacity(0.75))
                Spacer()
                Button {
                    engine.resetPro(control)
                } label: {
                    Text("A")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(engine.proIsManual(control) ? .white : .black)
                        .frame(width: 30, height: 30)
                        .background(engine.proIsManual(control) ? Color.white.opacity(0.15) : Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                Button {
                    setPro(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PlainButtonStyle())
            }

            RulerSlider(value: engine.proNormalized(control)) { t in
                engine.setPro(control, normalized: t)
            }

            HStack {
                Text(rangeText.0)
                Spacer()
                Text(rangeText.1)
            }
            .font(Palette.mono(10))
            .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            Color(red: 0.13, green: 0.13, blue: 0.14)
                .clipShape(RoundedCorner(radius: 18, corners: [.topLeft, .topRight]))
        )
    }

    /// 开关参数面板。显式关掉动画 —— 否则面板会在收起的过程中滑过底栏，
    /// 出现"关掉了但下面还压着一层"的残影。
    private func setPro(_ control: ProControl?) {
        var trans = Transaction()
        trans.disablesAnimations = true
        withTransaction(trans) {
            if let control = control {
                engine.openPro(control)
            } else {
                engine.closePro()
            }
        }
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// 水印「描述」那一行的编辑页
private struct DescEditorView: View {
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.presentationMode) private var presentation
    @State private var text = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("水印描述"),
                        footer: Text("这一行会原样写进水印，例如「钓鱼运动相机」。留空则不显示。")) {
                    TextField("输入描述", text: $text)
                }
            }
            .navigationBarTitle("描述", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() },
                                trailing: Button("保存") {
                                    onSave(text)
                                    presentation.wrappedValue.dismiss()
                                })
        }
        .onAppear { text = initial }
    }
}

// MARK: - 设置
struct SettingsSheet: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.presentationMode) private var presentation
    @State private var startInput = ""
    @State private var stopInput = ""
    @State private var words: (start: [String], stop: [String]) = ([], [])
    /// 设置页打开时每秒推一次，定位/天气晚回来也能立刻填上
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                        ForEach(engine.availableFieldOfViews) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording || engine.cameraPosition == .front)
                    Picker("防抖", selection: $engine.antiShake) {
                        ForEach(AntiShake.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(engine.isRecording)
                }

                Section(header: Text("降噪"),
                        footer: Text(engine.denoiseOn && !engine.denoiseNote.isEmpty
                                     ? "已生效：\(engine.denoiseNote)"
                                     : "开启后抑制麦克风风噪，并在暗光下压制画面噪点。是否可用取决于机型和系统版本。")) {
                    Toggle("降噪", isOn: $engine.denoiseOn)
                }

                Section(header: Text("水印"),
                        footer: Text("开启后会把水印烧进视频左下角，预览上同款显示。需要定位权限、天气需要联网；关闭时完全不定位、不联网、不写入画面。\n要显示哪些内容，在拍摄界面右下角的「水印时间」里逐项勾选。")) {
                    Toggle("时间地点水印", isOn: $engine.watermarkOn)
                    if engine.watermarkOn {
                        HStack {
                            Text("当前地点")
                            Spacer()
                            Text(engine.watermarkData.place.isEmpty
                                 ? (engine.locationNote.isEmpty ? "定位中…" : engine.locationNote)
                                 : engine.watermarkData.place)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("天气数据")
                            Spacer()
                            Text(engine.watermarkData.hasWeather ? "已就绪" : "获取中…")
                                .foregroundColor(.secondary)
                        }
                    }
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

                Section(header: Text("按键"),
                        footer: Text("开启后，按音量键（或 iPhone 16 的相机按钮）即可开始 / 停止录像。")) {
                    Toggle("音量键控制录像", isOn: $engine.volumeKeyRecording)
                }

                Section(header: Text("显示"),
                        footer: Text("左上角那个「剩余空间 / 可录时长」的胶囊。默认关闭，想看再打开。")) {
                    Toggle("显示剩余空间", isOn: $engine.showStorage)
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
        .onReceive(tick) { _ in engine.refreshWatermarkIfNeeded() }
    }
}
