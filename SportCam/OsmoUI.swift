import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine

// ============================================================
//  界面：竖屏，布局对齐苹果自带相机；功能保持大疆那套
// ============================================================

// MARK: - 语言（中英运行时切换；默认中文，选择记忆）
enum AppLanguage: String, CaseIterable, Identifiable {
    case zh = "zh"
    case en = "en"
    var id: String { rawValue }
    /// 选项本身两种语言都写自己的名字，不随界面语言变
    var label: String { self == .zh ? "中文" : "English" }
}

/// 当前语言。改它会立刻让主界面 / 设置页重绘（两个视图都监听它）。
final class Lang: ObservableObject {
    static let shared = Lang()
    private static let key = "app_language"

    @Published var current: AppLanguage {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        current = AppLanguage(rawValue: saved) ?? .zh
    }
}

/// 取文案：L(中文, English)。调用点两套都写出来，不会漏翻。
/// 注意：它是普通函数，视图要重绘必须有人监听 Lang.shared（主界面 / 设置页都在监听）。
func L(_ zh: String, _ en: String) -> String {
    Lang.shared.current == .en ? en : zh
}

// MARK: - 界面主题（整套配色：背景 / 卡片 / 边框 / 主色一起换）
/// 不是只换按钮颜色 —— 每套主题带着自己的背景渐变和卡片底色，
/// 切过去整页气质就变了。所有颜色都在渲染时取，主题一变两个根视图重绘即可生效。
enum AppTheme: String, CaseIterable, Identifiable {
    case sky = "sky"
    case azure = "azure"
    case mint = "mint"
    case teal = "teal"
    case lime = "lime"
    case honey = "honey"
    case amber = "amber"
    case coral = "coral"
    case rose = "rose"
    case crimson = "crimson"
    case violet = "violet"
    case purple = "purple"
    case indigo = "indigo"
    case cyan = "cyan"
    case emerald = "emerald"
    case navy = "navy"
    case ink = "ink"
    case mist = "mist"
    case custom = "custom"

    var id: String { rawValue }

    /// 浅色主题：文字、卡片、边框都要反色，否则浅底浅字看不见。
    /// 雾灰固定算浅色；自定义主题按所选颜色的亮度自动判定（亮色反色、暗色正常）。
    var isLight: Bool {
        switch self {
        case .mist:   return true
        case .custom: return Self.luma(ThemeStore.shared.customBase) > 0.66
        default:      return false
        }
    }

    /// 感知亮度（sRGB 加权），用来判断自定义色算不算浅色
    private static func luma(_ c: (Double, Double, Double)) -> Double {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    /// 档位名（中英两套都写出来，跟着语言走）
    var label: String {
        switch self {
        case .sky:    return L("天蓝", "Sky")
        case .azure:  return L("湖蓝", "Azure")
        case .mint:   return L("青绿", "Mint")
        case .teal:   return L("青碧", "Teal")
        case .lime:   return L("柠檬", "Lime")
        case .honey:  return L("蜜黄", "Honey")
        case .amber:  return L("琥珀", "Amber")
        case .coral:  return L("珊瑚", "Coral")
        case .rose:   return L("玫红", "Rose")
        case .crimson: return L("绯红", "Crimson")
        case .violet: return L("紫罗兰", "Violet")
        case .purple: return L("深紫", "Purple")
        case .indigo: return L("靛蓝", "Indigo")
        case .cyan:   return L("青蓝", "Cyan")
        case .emerald: return L("翡翠", "Emerald")
        case .navy:   return L("藏青", "Navy")
        case .ink:    return L("纯黑", "Ink")
        case .mist:   return L("雾灰", "Mist")
        case .custom: return L("自定义", "Custom")
        }
    }

    /// 每套只写一个基准色，背景 / 卡片 / 边框都由它朝黑或朝白混出来，
    /// 想加新配色只要在 base 和 label 里各补一行。
    private var base: (Double, Double, Double) {
        switch self {
        case .sky:    return (0.26, 0.62, 1.00)
        case .azure:  return (0.16, 0.70, 0.96)
        case .mint:   return (0.20, 0.86, 0.70)
        case .teal:   return (0.09, 0.72, 0.74)
        case .lime:   return (0.72, 0.88, 0.20)
        case .honey:  return (0.95, 0.75, 0.10)
        case .amber:  return (1.00, 0.62, 0.20)
        case .coral:  return (0.98, 0.42, 0.45)
        case .rose:   return (0.96, 0.28, 0.62)
        case .crimson: return (0.92, 0.18, 0.30)
        case .violet: return (0.69, 0.50, 1.00)
        case .purple: return (0.62, 0.24, 0.96)
        case .indigo: return (0.44, 0.42, 0.98)
        case .cyan:   return (0.12, 0.78, 0.94)
        case .emerald: return (0.06, 0.74, 0.44)
        case .navy:   return (0.18, 0.30, 0.72)
        case .ink:    return (0.82, 0.84, 0.88)
        case .mist:   return (0.34, 0.38, 0.46)
        case .custom: return ThemeStore.shared.customBase
        }
    }

    // MARK: 派生配色
    //
    // 思路对齐 Apple 官方 App（设置 / 相机 / 健康）：背景和卡片一律走「中性色」，
    // 主色只在上面薄薄掺一点做气质，饱和的亮色留给按钮 / 开关 / 高亮这类可交互元素。
    // 之前的做法是把基准色直接往纯黑 / 纯白里拉 —— 深色会糊成一团看不出层次的暗色，
    // 浅色又几乎等于纯白，正是「太刺眼」的根因。改成固定锚点 + 少量掺色后，
    // 每套主题依旧看得出自己的颜色，但整体干净、有层次、不扎眼。

    /// 浅色锚点：柔和灰白，刻意不用纯白（HIG：soften white backgrounds）
    private static let lightAnchor = (0.906, 0.914, 0.929)
    /// 深色锚点：近黑但非纯黑（HIG 建议 #121212 一类），比纯黑更留得住层次
    private static let darkAnchor = (0.062, 0.066, 0.078)

    /// 在中性锚点上掺入主题基准色：t = 掺色比例（越大气质越浓），lift = 整体明暗微调
    private func tone(_ t: Double, lift: Double = 0) -> Color {
        let a = isLight ? Self.lightAnchor : Self.darkAnchor
        let b = base
        return Color(red:   Self.clamp(a.0 + (b.0 - a.0) * t + lift),
                     green: Self.clamp(a.1 + (b.1 - a.1) * t + lift),
                     blue:  Self.clamp(a.2 + (b.2 - a.2) * t + lift))
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// 主色：按钮选中态 / 开关 / 高亮文字
    var accent: Color { Color(red: base.0, green: base.1, blue: base.2) }

    /// 主色实心块上的文字：按主色明暗自动选黑字或白字，任何主题都保证读得清
    var onAccent: Color { Self.luma(base) > 0.62 ? Color.black : Color.white }

    /// 页面背景：上浅下深两段渐变，主题色只掺一点点，基调始终是干净的中性色
    private var bgTop: Color { tone(isLight ? 0.10 : 0.17, lift: isLight ? 0.012 : 0.014) }
    private var bgBottom: Color { tone(isLight ? 0.05 : 0.06, lift: isLight ? -0.045 : -0.012) }

    /// 选择器上的色卡：背景 → 主色 → 背景的对角渐变，一眼看出整套气质
    var swatch: LinearGradient {
        LinearGradient(colors: [bgTop, accent.opacity(isLight ? 0.35 : 0.85), bgBottom],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 页面背景
    var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }

    /// 卡片底色：比背景亮一档形成层次（elevation）；浅色是柔和米白，不是纯白
    var surface: Color {
        isLight ? tone(0.08, lift: 0.058).opacity(0.96)
                : tone(0.16, lift: 0.055).opacity(0.82)
    }

    /// 次级底色：输入框 / 未选中的胶囊（比卡片再亮一点，形成内凹层次）
    var surfaceHi: Color {
        isLight ? tone(0.10, lift: 0.030).opacity(0.92)
                : tone(0.16, lift: 0.095).opacity(0.85)
    }

    /// 描边：跟着主题走的淡色勾边（浅色背景上要稍实一点才看得出来）
    var border: Color { accent.opacity(isLight ? 0.24 : 0.30) }

    /// 不透明面板底色：压在取景画面上时用（如专业参数面板），保持中性不串色
    var panel: Color {
        isLight ? tone(0.06, lift: 0.045).opacity(0.98)
                : tone(0.10, lift: 0.048).opacity(0.98)
    }
}

/// 当前主题。改它会立刻让主界面 / 设置页重绘（两个视图都监听它）。
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "app_theme"

    @Published var current: AppTheme {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: Self.key) }
    }

    /// 背景透明度：0 = 完全不透明，越大越透（设置页整页背景跟着变）
    @Published var backgroundTransparency: Double {
        didSet { UserDefaults.standard.set(backgroundTransparency, forKey: Self.bgKey) }
    }

    private static let bgKey = "app_bg_transparency"
    private static let customKey = "app_theme_custom"

    /// 「自定义」主题的基准色：用户用取色器自己挑，整套背景/卡片/边框都从它派生
    @Published var customBase: (Double, Double, Double) {
        didSet {
            UserDefaults.standard.set([customBase.0, customBase.1, customBase.2],
                                      forKey: Self.customKey)
        }
    }

    /// 给 ColorPicker 用的绑定：读写都落到 customBase
    var customColor: Binding<Color> {
        Binding(
            get: {
                let c = self.customBase
                return Color(red: c.0, green: c.1, blue: c.2)
            },
            set: { newColor in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                _ = UIColor(newColor).getRed(&r, green: &g, blue: &b, alpha: &a)
                self.customBase = (Double(r), Double(g), Double(b))
            }
        )
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        current = AppTheme(rawValue: saved) ?? .mint
        backgroundTransparency = UserDefaults.standard.object(forKey: Self.bgKey) as? Double ?? 0
        let savedRGB = UserDefaults.standard.array(forKey: Self.customKey) as? [Double]
        customBase = (savedRGB?.count == 3) ? (savedRGB![0], savedRGB![1], savedRGB![2])
                                            : (0.40, 0.62, 0.95)
    }
}

private enum Palette {
    /// 以下取值都跟随主题，渲染时才读；主题一变两个根视图重绘就能带上新配色
    static var accent: Color { ThemeStore.shared.current.accent }
    static var themeBackground: LinearGradient { ThemeStore.shared.current.background }
    static var surface: Color { ThemeStore.shared.current.surface }
    static var surfaceHi: Color { ThemeStore.shared.current.surfaceHi }
    static var border: Color { ThemeStore.shared.current.border }
    static var panel: Color { ThemeStore.shared.current.panel }
    /// 浅色主题判定：文字 / 卡片 / 边框按它反色
    static var isLight: Bool { ThemeStore.shared.current.isLight }
    /// 主题文字色：深色主题用白、浅色主题用黑，opacity 沿用原来的值，深浅两套都协调
    static func text(_ opacity: Double) -> Color {
        isLight ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
    /// 主色实心块上的文字：按当前主色明暗自动选黑字 / 白字（见 AppTheme.onAccent）
    static var onAccent: Color { ThemeStore.shared.current.onAccent }
    /// 铺在取景画面上的浮层底色：不跟浅色主题变白，保证白字始终看得清
    static let overlayPanel = Color.black.opacity(0.55)
    static let record = Color(red: 1.00, green: 0.23, blue: 0.23)
    static let appleYellow = Color(red: 1.00, green: 0.84, blue: 0.04)
    static let glass = Color.black.opacity(0.42)
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
    /// 防抖模式：预览也按设置里的档位来，取景器里看到的抖动抑制就是录进去的效果
    let stabilization: AVCaptureVideoStabilizationMode
    /// 4:3 时取景器要"装得下整个画面"（上下留黑边），否则 resizeAspectFill 会把
    /// 多出来的上下视野直接裁掉 —— 用户看到的就是"选了 4:3 画面没变"。
    let fitInFrame: Bool
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
        view.previewLayer.videoGravity = fitInFrame ? .resizeAspect : .resizeAspectFill
        if #available(iOS 17.2, *) {
            view.addInteraction(AVCaptureEventInteraction { event in
                if event.phase == .ended { onCaptureButton() }
            })
        }
        context.coordinator.view = view
        context.coordinator.onFocusPoint = onFocusPoint
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        // 预览铺满全屏，这个对焦手势挂在它上面。默认 cancelsTouchesInView = true 时，
        // 落在预览范围内的触摸会被它抢先吃掉 —— 表现就是"点焦段档位有时候点不动"。
        // 关掉它，对焦照常，触摸照样能传给上层的按钮。
        tap.cancelsTouchesInView = false
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
        // 画面比例切换（16:9 ↔ 4:3）时同步取景方式：
        // 4:3 装得下整幅（留黑边），16:9 铺满全屏。用 CATransaction 淡一下，切档不突兀。
        let gravity: AVLayerVideoGravity = fitInFrame ? .resizeAspect : .resizeAspectFill
        if view.previewLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            view.previewLayer.videoGravity = gravity
            CATransaction.commit()
        }
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if connection.isVideoStabilizationSupported,
           connection.preferredVideoStabilizationMode != stabilization {
            connection.preferredVideoStabilizationMode = stabilization
        }
    }
}

// MARK: - 小控件
/// 主界面所有功能钮统一走这一个：46pt 玻璃圆钮 + 一行短标签，字号/描边/投影完全一致，
/// 不再出现"顶部 38、底部 46"这种一大一小。标签直接把"这个钮管什么"写在下面。
private struct ToolButton: View {
    let icon: String
    /// 短标签（闪光灯 / 翻转 / 相册…）。传 nil 就只留圆钮。
    var title: String? = nil
    var active = false
    var tint: Color = Palette.accent
    var diameter: CGFloat = 46
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(active ? tint : Palette.glass)
                    Circle().stroke(active ? tint.opacity(0.9) : Palette.border, lineWidth: 1)
                    Image(systemName: icon)
                        .font(.system(size: diameter * 0.40, weight: .semibold))
                        .foregroundColor(active ? Color.black : .white)
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 1)

                if let title = title {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: diameter)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
}

/// 焦段档位（0.5x / 1x / 2x）。
/// 选中状态用动画过渡 —— 直接硬切会"啪"地闪一下，看着像是在重新加载画面。
/// 热区做到 56×40：原来只有 34 的圆点，手指压不准，会有"点不动"的感觉。
/// contentShape 放在 label 的 frame 上 —— 保证整个矩形都是热区，而不是只有字形那一点点。
private struct ZoomChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            // 轻微触感 + 立刻回调：先给手指一个回应，再去做切镜头这种"慢活"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .black : .white)
                // 60×44：达到苹果建议的最小点按尺寸。之前 34 的圆点太窄，
                // 左手拇指从左侧斜着按下来经常落在缝里 —— 就是"左手点不动、右手能点"的原因。
                .frame(width: 60, height: 44)
                .contentShape(Rectangle())
                .background(selected ? Color.white : Color.clear)
                .clipShape(Capsule())
                .scaleEffect(selected ? 1.0 : 0.96)
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: selected)
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
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
    /// 监听语言：中英切换时整屏重绘
    @ObservedObject private var lang = Lang.shared
    /// 监听主题：换主色时整屏重绘（Palette.accent 是动态取值）
    @ObservedObject private var theme = ThemeStore.shared
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
                          stabilization: engine.antiShake.mode,
                          fitInFrame: engine.quality.is4x3,
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

            // 翻转过渡帧：换镜头那几帧会话要断一下（预览会黑），这层盖住黑屏再淡出，
            // 观感就是平滑地切过去。取景方式和预览保持一致（4:3 装得下、16:9 铺满）。
            if let overlay = engine.flipOverlay {
                Image(uiImage: overlay)
                    .resizable()
                    .aspectRatio(contentMode: engine.quality.is4x3 ? .fit : .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(engine.flipOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

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
                            Text(L("省电熄屏中 · 上滑唤醒", "Screen off · swipe up to wake"))
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                            if engine.isRecording {
                                Text("\(L("录制中", "REC")) \(timeText(engine.recordSeconds))")
                                    .font(Palette.mono(12))
                                    .foregroundColor(Palette.record.opacity(0.85))
                            }
                        }
                    )
            }

            if showDuration && engine.proControl == nil { durationPicker }
            if showFormat && engine.proControl == nil { formatPicker }
            if showWatermark { watermarkPicker }

            // 设置页做成叠在取景画面上的一层（不再用 sheet）：sheet 自带不透明底 +
            // 系统导航栏，透不出后面的画面。叠在这里，背景透明度拉高就能真的看到取景画面。
            if showSettings {
                SettingsSheet(engine: engine, isPresented: $showSettings)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .onAppear { engine.launch() }
        .statusBar(hidden: true)
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
                        Text("\(engine.quality.rawValue)/\(engine.frameRate.label)")
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
                // 三个功能钮：统一 46 圆钮 + 短标签，和底部一排同规格，不再一大一小
                HStack(spacing: 10) {
                    ToolButton(icon: engine.torchOn ? "bolt.fill" : "bolt.slash.fill",
                               title: L("闪光灯", "Flash"),
                               active: engine.torchOn,
                               tint: Palette.appleYellow) {
                        engine.toggleTorch()
                    }
                    // 翻转：前/后摄像头切换。原来藏在设置里，挪到屏幕上单手就能切
                    ToolButton(icon: "arrow.triangle.2.circlepath.camera",
                               title: L("翻转", "Flip"),
                               active: engine.cameraPosition == .front,
                               disabled: engine.isRecording) {
                        engine.toggleCamera()
                    }
                    ToolButton(icon: "gearshape.fill", title: L("设置", "Settings")) {
                        withAnimation(.easeInOut(duration: 0.28)) { showSettings = true }
                    }
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
                Text(L("正在保存到相册…", "Saving to Photos…"))
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
            // 这里是"预录快捷键"：点一下直接开关预录；预录时长在右下角的预录按钮里设
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
                        // 没开预录时只显示设置好的时长（时长在右下角预录按钮里改）
                        Text(engine.preRecordOn ? timeText(engine.preRecordSeconds)
                                                : engine.preRecordDelay.label)
                            .font(Palette.mono(15, .bold))
                            .foregroundColor(.white)
                        Text(engine.preRecordOn ? L("预录制中", "Pre-recording")
                                               : L("预录时长", "Pre-record"))
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

    // MARK: 设置预录时长（右下角预录按钮）
    private var durationPicker: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { showDuration = false }

            VStack(spacing: 16) {
                Text(L("设置预录时长", "Pre-record Duration"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    durationCell(L("关闭", "Off"), value: nil)
                    ForEach(PreRecordDelay.allCases) { delay in
                        durationCell(delay.label, value: delay)
                    }
                }

                Text(L("预录会在按下录像前先缓存这段时间的画面",
                       "Pre-record keeps the moments before you press record"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(Palette.overlayPanel)
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
                .foregroundColor(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(selected ? Palette.accent : Color.white.opacity(0.10))
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
                Text(L("分辨率", "Resolution"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    ForEach(engine.availableQualities) { item in
                        formatCell(item.rawValue, selected: engine.quality == item) {
                            engine.quality = item
                        }
                    }
                }

                Text(L("帧率", "Frame Rate"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 2)

                HStack(spacing: 10) {
                    ForEach(engine.frameRateOptions) { item in
                        formatCell(item.label, selected: engine.frameRate == item) {
                            engine.frameRate = item
                        }
                    }
                }

                // 真实输出尺寸：选的档是"名义值"，这里显示的是摄像头真正送出来的画面大小，
                // 是不是真 4K 一眼就能对上（比如 3840×2160 才是真 4K，1920×1080 就是没给到）。
                if !engine.actualResolution.isEmpty {
                    Text("\(L("实际输出", "Output")) \(engine.actualResolution)")
                        .font(Palette.mono(11))
                        .foregroundColor(Palette.accent)
                }

                Text(engine.isRecording
                     ? L("录制中不能改分辨率和帧率", "Can't change resolution or frame rate while recording")
                     : L("分辨率越高越清晰，帧率越高越流畅，文件也越大",
                         "Higher resolution is sharper, higher frame rate is smoother, files are larger"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))

                Button {
                    showFormat = false
                } label: {
                    Text(L("完成", "Done"))
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
            .background(Palette.overlayPanel)
            .cornerRadius(16)
        }
    }

    private func formatCell(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(selected ? Palette.accent : Color.white.opacity(0.10))
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
                watermarkMaster(L("关闭", "Off"), on: !engine.watermarkOn) { engine.watermarkOn = false }
                watermarkMaster(L("开启", "On"), on: engine.watermarkOn) { engine.watermarkOn = true }
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

            Text(L("数据来自系统定位与 Open-Meteo 天气，勾上即刻显示",
                   "Data from system location and Open-Meteo weather. Shown instantly once checked."))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))

            Button {
                showWatermark = false
            } label: {
                Text(L("完成", "Done"))
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
        .background(Palette.overlayPanel)
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

            Text(item.title)
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
                ToolButton(icon: "photo.on.rectangle", title: L("相册", "Photos")) {
                    engine.openPhotos()
                }
                proToggleButton

                Spacer(minLength: 8)

                // 右：水印 + 预录时长
                watermarkButton
                ToolButton(icon: "timer", title: L("预录", "Pre-rec")) { showDuration = true }
            }
        }
        .padding(.horizontal, 20)
    }

    /// 水印：点开面板，逐项勾选（时间/地点/描述/海拔/天气/温度/气压/风速）
    /// 和左右两侧其它按钮一样做成 46 的圆，底栏一排按钮尺寸统一、不再一大一小。
    private var watermarkButton: some View {
        ToolButton(icon: "textformat",
                   title: L("水印", "Watermark"),
                   active: engine.watermarkOn) {
            showWatermark = true
            engine.ensureWatermarkStarted()
        }
    }

    /// 一个按钮管全部专业参数：点开面板，里面六项随便切
    private var proToggleButton: some View {
        ToolButton(icon: "slider.horizontal.3",
                   title: L("参数", "Pro"),
                   active: engine.proControl != nil) {
            setPro(engine.proControl == nil ? .exposure : nil)
        }
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
                            Text(item.title)
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
                        Text(engine.showGrid ? L("开", "On") : L("关", "Off"))
                            .font(Palette.mono(12, .semibold))
                        Text(L("网格", "Grid"))
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
            Palette.overlayPanel
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
    /// 监听语言：切换语言时这一页也跟着重绘
    @ObservedObject private var lang = Lang.shared
    @State private var text = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("水印描述", "Watermark Description")),
                        footer: Text(L("这一行会原样写进水印，例如「钓鱼预录相机Pro」。留空则不显示。",
                                       "This line is written into the watermark as-is, e.g. \"Fishing Pre-record Cam Pro\". Leave empty to hide."))) {
                    TextField(L("输入描述", "Enter description"), text: $text)
                }
            }
            .navigationBarTitle(L("描述", "Description"), displayMode: .inline)
            .navigationBarItems(leading: Button(L("取消", "Cancel")) { presentation.wrappedValue.dismiss() },
                                trailing: Button(L("保存", "Save")) {
                                    onSave(text)
                                    presentation.wrappedValue.dismiss()
                                })
        }
        .onAppear { text = initial }
    }
}

// MARK: - 设置（深色卡片式排版）

/// 设置卡片：统一圆角 + 描边 + 分组标题，深色下更克制、专业
private struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Palette.accent)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(Palette.text(0.5))
            }
            VStack(alignment: .leading, spacing: 16) { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.border, lineWidth: 1))
    }
}

/// 卡片里的一项：图标 + 标题，下面跟随控件
private struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.text(0.55))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(Palette.text(0.85))
            }
            content
        }
    }
}

/// 开关行：图标 + 标题（可带副标题）+ 开关
private struct SettingToggleRow: View {
    let icon: String
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isOn ? Palette.accent : Palette.text(0.5))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Palette.text(0.92))
                if let caption = caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.text(0.4))
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .accentColor(Palette.accent)
        }
    }
}

/// 胶囊选择器：横向排列的档位，选中态用主题色，比系统 Picker 更紧凑统一
private struct SettingSegments<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T
    var disabled: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                    } label: {
                        Text(title(option))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(selected ? Palette.onAccent : Palette.text(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? Palette.accent : Palette.surfaceHi))
                            .overlay(Capsule().stroke(selected ? Color.clear : Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// 深色输入框
private struct SettingField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 13.5))
            .foregroundColor(Palette.text(1))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceHi))
    }
}

/// 说明文字
private struct SettingNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Palette.text(0.38))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 主题选择：网格渐变色卡（3 列），切换整套配色
private struct ThemeSwatchPicker: View {
    @Binding var selection: AppTheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(AppTheme.allCases) { theme in
                let selected = theme == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = theme }
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.swatch)
                            .frame(height: 62)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(selected ? Palette.accent : Palette.text(0.16),
                                        lineWidth: selected ? 2.5 : 1))
                            .overlay(checkmark(theme: theme).opacity(selected ? 1 : 0), alignment: .topTrailing)
                        Text(theme.label)
                            .font(.system(size: 11, weight: selected ? .bold : .medium))
                            .foregroundColor(selected ? Palette.text(1) : Palette.text(0.55))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 选中角标：主色实心圆 + 反色勾
    private func checkmark(theme: AppTheme) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .black))
            .foregroundColor(Palette.onAccent)
            .frame(width: 18, height: 18)
            .background(Circle().fill(theme.accent))
            .padding(5)
    }
}

struct SettingsSheet: View {
    @ObservedObject var engine: CameraEngine
    /// 显隐由父视图控制：设置页现在是叠在取景画面上的一层，
    /// 背景透明后能真的看到后面的画面（而不是被纯黑/纯白垫底挡住）。
    @Binding var isPresented: Bool
    /// 监听语言：中英切换时整页重绘
    @ObservedObject private var lang = Lang.shared
    /// 监听主题：换主色时整页重绘（Palette.accent 是动态取值）
    @ObservedObject private var theme = ThemeStore.shared
    @State private var startInput = ""
    @State private var stopInput = ""
    @State private var words: (start: [String], stop: [String]) = ([], [])
    /// 设置页打开时每秒推一次，定位/天气晚回来也能立刻填上
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 只铺主题渐变，底下不再垫任何纯色 —— 透明度拉满时整页真透明，
            // 直接看到后面的取景画面。
            Palette.themeBackground
                .opacity(1 - theme.backgroundTransparency)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        SettingsCard(icon: "camera.aperture", title: L("画面", "Video")) {
                            SettingRow(icon: "rectangle.on.rectangle", title: L("分辨率", "Resolution")) {
                                SettingSegments(options: engine.availableQualities,
                                                title: { $0.rawValue },
                                                selection: $engine.quality,
                                                disabled: engine.isRecording)
                            }
                            SettingRow(icon: "speedometer", title: L("帧率", "Frame Rate")) {
                                SettingSegments(options: engine.frameRateOptions,
                                                title: { $0.label },
                                                selection: $engine.frameRate,
                                                disabled: engine.isRecording)
                            }
                            SettingToggleRow(icon: "wand.and.stars", title: L("自动帧率", "Auto Frame Rate"), isOn: $engine.autoFrameRate)
                            if !engine.actualResolution.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(Palette.accent)
                                    Text("\(L("实际输出", "Output")) \(engine.actualResolution)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.text(0.45))
                                }
                            }
                            SettingRow(icon: "camera.metering.center.weighted", title: L("视角", "Field of View")) {
                                SettingSegments(options: engine.availableFieldOfViews,
                                                title: { $0.title },
                                                selection: $engine.fieldOfView,
                                                disabled: engine.isRecording || engine.cameraPosition == .front)
                            }
                            SettingToggleRow(icon: "viewfinder", title: L("自动最广视野", "Auto Widest View"), isOn: $engine.autoWidest)
                            SettingNote(text: L("镜头按本机真实能力适配：只列出这台机器真有的（前置/后置、超广角/广角/长焦/多摄）。自动最广视野开启后，自动切到最广的镜头。镜头切换是本地操作，无信号、飞行模式、省电模式下都能用。",
                                                "Lenses adapt to this device's real capabilities: only what it actually has (front/rear, ultra-wide/wide/tele/multi-cam) is listed. When Auto Widest View is on, it switches to the widest lens automatically. Lens switching is local and works with no signal, in Airplane Mode and Low Power Mode."))
                            SettingRow(icon: "hand.raised.fill", title: L("防抖", "Stabilization")) {
                                SettingSegments(options: AntiShake.allCases,
                                                title: { $0.title },
                                                selection: $engine.antiShake,
                                                disabled: engine.isRecording)
                            }
                        }

                        SettingsCard(icon: "moon.zzz.fill", title: L("自动熄屏", "Auto Screen Off")) {
                            SettingRow(icon: "timer", title: L("熄屏时间", "Screen Off Timer")) {
                                SettingSegments(options: PowerSaveDelay.allCases,
                                                title: { $0.label },
                                                selection: $engine.powerSave)
                            }
                            SettingNote(text: L("到点自动熄屏省电，熄屏后继续录制，上滑屏幕即可唤醒。",
                                                "Turns the screen off to save power; recording continues. Swipe up to wake."))
                        }

                        SettingsCard(icon: "squareshape.split.3x3", title: L("拍摄辅助", "Shooting Aids")) {
                            SettingToggleRow(icon: "grid", title: L("构图网格", "Grid"), isOn: $engine.showGrid)
                            SettingToggleRow(icon: "level", title: L("水平仪", "Level"), isOn: $engine.showLevel)
                            SettingToggleRow(icon: "speaker.wave.2.fill", title: L("录制提示音", "Recording Sound"), isOn: $engine.beepOn)
                            SettingToggleRow(icon: "lightbulb.fill", title: L("夜钓自动补光", "Auto Night Light"), isOn: $engine.nightAutoLight)
                            SettingNote(text: L("提示音用的是苹果自带相机的录像声。夜钓自动补光：录制中画面变暗时自动开手电，变亮自动关，停止录制也会关灯省电；是否生效取决于当前镜头有没有闪光灯。",
                                                "The sound is Apple's own camera recording tone. Auto Night Light: during recording it turns the torch on when the scene gets dark, off when bright, and always off when recording stops; depends on whether the current lens has a torch."))
                        }

                        SettingsCard(icon: "mappin.and.ellipse", title: L("水印", "Watermark")) {
                            SettingToggleRow(icon: "text.viewfinder", title: L("时间地点水印", "Time & Location Watermark"), isOn: $engine.watermarkOn)
                            if engine.watermarkOn {
                                HStack {
                                    Text(L("当前地点", "Current Place")).font(.system(size: 13)).foregroundColor(Palette.text(0.7))
                                    Spacer()
                                    Text(engine.watermarkData.place.isEmpty
                                         ? (engine.locationNote.isEmpty ? L("定位中…", "Locating…") : engine.locationNote)
                                         : engine.watermarkData.place)
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.text(0.45))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.trailing)
                                }
                                HStack {
                                    Text(L("天气数据", "Weather Data")).font(.system(size: 13)).foregroundColor(Palette.text(0.7))
                                    Spacer()
                                    Text(engine.watermarkData.hasWeather ? L("已就绪", "Ready") : L("获取中…", "Fetching…"))
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.text(0.45))
                                }
                            }
                            SettingNote(text: L("水印烧进画面左下角，预览同款显示。需要定位权限，天气需联网；关闭后不定位、不联网、不写入。显示哪些内容，在拍摄界面右下角「水印时间」里逐项勾选。",
                                                "The watermark is burned into the bottom-left of the frame and shown the same way in preview. Needs location permission; weather needs network. When off, no location, no network, nothing written. Pick which items to show via the Watermark button on the shooting screen."))
                        }

                        SettingsCard(icon: "clock.arrow.circlepath", title: L("预录", "Pre-record")) {
                            SettingToggleRow(icon: "record.circle", title: L("开启预录", "Enable Pre-record"), isOn: $engine.preRecordOn)
                            SettingRow(icon: "timer", title: L("预录时长", "Pre-record Duration")) {
                                SettingSegments(options: PreRecordDelay.allCases,
                                                title: { $0.label },
                                                selection: $engine.preRecordDelay,
                                                disabled: !engine.preRecordOn)
                            }
                            SettingNote(text: L("开启后持续缓存最近画面，按下录像时会把「按下之前」的画面一起保存。",
                                                "Keeps buffering recent footage so that when you press record, the moments before are saved too."))
                        }

                        SettingsCard(icon: "waveform", title: L("语音控制", "Voice Control")) {
                            SettingToggleRow(icon: "mic.fill", title: L("语音控制", "Voice Control"), isOn: $engine.voiceOn)
                            SettingRow(icon: "play.circle", title: L("开始口令", "Start Phrase")) {
                                Text(words.start.joined(separator: " / "))
                                    .font(.system(size: 12))
                                    .foregroundColor(Palette.accent)
                                    .lineLimit(1)
                                SettingField(placeholder: L("自定义开始口令（英文逗号分隔）", "Custom start phrases (comma separated)"), text: $startInput)
                            }
                            SettingRow(icon: "stop.circle", title: L("结束口令", "Stop Phrase")) {
                                Text(words.stop.joined(separator: " / "))
                                    .font(.system(size: 12))
                                    .foregroundColor(Palette.accent)
                                    .lineLimit(1)
                                SettingField(placeholder: L("自定义结束口令（英文逗号分隔）", "Custom stop phrases (comma separated)"), text: $stopInput)
                            }
                            Button {
                                let start = startInput.isEmpty ? words.start
                                    : startInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                let stop = stopInput.isEmpty ? words.stop
                                    : stopInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                words = (start, stop)
                                engine.setVoiceWords(start: start, stop: stop)
                            } label: {
                                Text(L("保存口令", "Save Phrases"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Palette.onAccent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(Palette.accent))
                            }
                            .buttonStyle(.plain)
                            SettingNote(text: L("开启后说「开始录像」即可开始，说「停止录像」即可结束。",
                                                "When on, say \"start recording\" to begin and \"stop recording\" to end."))
                        }

                        SettingsCard(icon: "bolt.fill", title: L("性能与续航", "Performance & Battery")) {
                            SettingToggleRow(icon: "waveform.badge.mic", title: L("降噪", "Noise Reduction"), isOn: $engine.denoiseOn)
                            SettingNote(text: engine.denoiseOn && !engine.denoiseNote.isEmpty
                                        ? L("降噪已生效：\(engine.denoiseNote)", "Noise reduction active: \(engine.denoiseNote)")
                                        : L("降噪：抑制麦克风风噪，并在暗光下压制画面噪点（是否可用取决于机型和系统）。",
                                            "Noise reduction: suppresses mic wind noise and reduces low-light grain (availability depends on device and OS)."))
                        }

                        SettingsCard(icon: "battery.100", title: L("低电量保护", "Low Battery Protection")) {
                            SettingToggleRow(icon: "battery.25", title: L("低电量强制保存", "Force Save on Low Battery"), isOn: $engine.lowBatterySaveOn)
                            SettingRow(icon: "percent", title: L("阈值", "Threshold")) {
                                SettingSegments(options: BatteryThreshold.allCases,
                                                title: { $0.label },
                                                selection: $engine.batteryThreshold,
                                                disabled: !engine.lowBatterySaveOn)
                            }
                            SettingNote(text: L("录制中电量降到阈值时自动停止并保存当前视频，避免突然断电把文件丢掉。当前电量 \(Int(engine.battery * 100))%。",
                                                "When battery drops to the threshold while recording, it stops and saves the current video so a sudden shutdown won't lose the file. Current battery \(Int(engine.battery * 100))%."))
                        }

                        SettingsCard(icon: "hand.tap.fill", title: L("按键", "Buttons")) {
                            SettingToggleRow(icon: "speaker.wave.3.fill", title: L("音量键控制录像", "Volume Key Recording"), isOn: $engine.volumeKeyRecording)
                            SettingNote(text: L("开启后，按音量键（或 iPhone 16 的相机按钮）即可开始 / 停止录像。默认关闭，想用时再打开。",
                                                "When on, press a volume key (or the iPhone 16 Camera Control) to start / stop recording. Off by default; turn it on when you need it."))
                        }

                        SettingsCard(icon: "eye.fill", title: L("显示", "Display")) {
                            SettingToggleRow(icon: "internaldrive.fill", title: L("显示剩余空间", "Show Free Space"), isOn: $engine.showStorage)
                            SettingNote(text: L("左上角那个「剩余空间 / 可录时长」的胶囊。默认关闭，想看再打开。",
                                                "The free space / recordable time pill at the top-left. Off by default; turn it on when you want it."))
                        }

                        // 界面主题：整套配色一起换
                        SettingsCard(icon: "paintpalette.fill", title: L("界面主题", "Theme")) {
                            ThemeSwatchPicker(selection: $theme.current)
                            // 选到「自定义」时才出现取色器：随便挑一个颜色，整套跟着它变
                            if theme.current == .custom {
                                SettingRow(icon: "eyedropper.halffull", title: L("自定义颜色", "Custom Color")) {
                                    ColorPicker("", selection: theme.customColor, supportsOpacity: false)
                                        .labelsHidden()
                                }
                            }
                            SettingRow(icon: "circle.lefthalf.filled", title: L("背景透明度", "Background Transparency")) {
                                HStack(spacing: 12) {
                                    Slider(value: $theme.backgroundTransparency, in: 0...1)
                                        .accentColor(Palette.accent)
                                    Text("\(Int(theme.backgroundTransparency * 100))%")
                                        .font(Palette.mono(12))
                                        .foregroundColor(Palette.text(0.6))
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                            SettingNote(text: L("整套配色一起换：背景、卡片、边框、按钮和开关的颜色都跟着变，选择会被记住。背景透明度是「真透明」：调高后设置页背景直接透出去，能看到后面的取景画面；拉到 100% 就只剩文字和卡片浮在画面上。",
                                                "Switches the whole palette — background, cards, borders, buttons and toggles all follow, and your choice is remembered. Background transparency is real see-through: raise it and the settings background becomes transparent, revealing the camera view behind; at 100% only the text and cards float over the picture."))
                        }

                        // 联系方式：展示抖音 / QQ 客服
                        SettingsCard(icon: "bubble.left.and.bubble.right.fill", title: L("联系我们", "Contact Us")) {
                            SettingRow(icon: "video.fill", title: L("抖音账号", "Douyin")) {
                                Text("84393019417")
                                    .font(Palette.mono(15, .semibold))
                                    .foregroundColor(Palette.accent)
                            }
                            SettingRow(icon: "message.fill", title: L("QQ 客服", "QQ Support")) {
                                Text("2188888999")
                                    .font(Palette.mono(15, .semibold))
                                    .foregroundColor(Palette.accent)
                            }
                            SettingNote(text: L("关注抖音账号获取最新版本与使用教程；使用中遇到问题可联系 QQ 客服。",
                                                "Follow our Douyin for the latest version and tutorials; contact QQ support if you run into problems."))
                        }

                        // 语言：底部切换，选中即生效并记忆
                        SettingsCard(icon: "globe", title: L("语言", "Language")) {
                            SettingSegments(options: AppLanguage.allCases,
                                            title: { $0.label },
                                            selection: $lang.current)
                            SettingNote(text: L("切换后界面文字立即生效，选择会被记住。",
                                                "Takes effect immediately and your choice is remembered."))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                }
            }
        }
        .contentShape(Rectangle())
        .preferredColorScheme(theme.current.isLight ? .light : .dark)
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

    /// 自绘顶部栏：原来用 NavigationView 的导航栏，系统导航栏有不透明底，
    /// 会把「透明看到屏幕」整个挡掉。这里换成跟着主题走的一条，底色随透明度一起淡出。
    private var header: some View {
        HStack {
            Text(L("设置", "Settings"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Palette.text(0.95))
            Spacer()
            Button(L("完成", "Done")) { withAnimation(.easeInOut(duration: 0.24)) { isPresented = false } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Palette.panel.opacity(0.9 * (1 - theme.backgroundTransparency)))
    }
}
