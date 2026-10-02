import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Speech
import Photos
import CoreMotion
import UIKit
import Combine

// ============================================================
//  相机核心：采集会话 / 语音控制 / 省电熄屏 / 看门狗
//  录制走 SegmentRecorder（分段落盘），内存里不囤帧
// ============================================================

// MARK: - 可调项
enum FieldOfView: String, CaseIterable, Identifiable {
    case ultraWide = "超广角"
    case wide = "广角"
    case telephoto = "长焦"
    var id: String { rawValue }
    var lens: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case k4 = "4K"
    case p1080 = "1080P"
    case p720 = "720P"
    case p1080x43 = "1080P 4:3"
    case k4x43 = "4K 4:3"
    var id: String { rawValue }

    /// 4:3 用满传感器高度：同样焦距下上下视野更宽，参考 App 里的「超广视野」就是它
    var is4x3: Bool { self == .p1080x43 || self == .k4x43 }

    /// 画面宽高比（传感器方向，宽 > 高）
    var aspect: Double { is4x3 ? 4.0 / 3.0 : 16.0 / 9.0 }

    /// 4:3 没有对应的 sessionPreset，交给设备 activeFormat 决定：
    /// 用 inputPriority 让会话完全听设备的格式，不再被预置裁回 16:9。
    var preset: AVCaptureSession.Preset {
        switch self {
        case .k4: return .hd4K3840x2160
        case .p1080: return .hd1920x1080
        case .p720: return .hd1280x720
        case .p1080x43, .k4x43: return .inputPriority
        }
    }

    var size: (width: Int, height: Int) {
        switch self {
        case .k4: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        case .p1080x43: return (1440, 1080)
        case .k4x43: return (2880, 2160)
        }
    }
}

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

enum AntiShake: String, CaseIterable, Identifiable {
    case off = "关闭"
    case standard = "标准"
    case cinematic = "影院级"
    case auto = "自动"
    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .auto: return .auto
        }
    }
}

/// 专业参数（底部滑杆面板）——顺序对齐参考 App：曝光/快门/感光度/白平衡/对焦/变焦
enum ProControl: String, CaseIterable, Identifiable {
    case exposure = "曝光"
    case shutter = "快门"
    case iso = "感光度"
    case whiteBalance = "白平衡"
    case focus = "对焦"
    case zoom = "变焦"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .exposure: return "sun.max.fill"
        case .shutter: return "timer"
        case .iso: return "camera.aperture"
        case .whiteBalance: return "thermometer.medium"
        case .focus: return "viewfinder"
        case .zoom: return "plus.magnifyingglass"
        }
    }
}

/// 预录时长（按下之前保留多久的画面）
enum PreRecordDelay: Int, CaseIterable, Identifiable {
    case s5 = 5
    case s10 = 10
    case s15 = 15
    case s30 = 30
    case m1 = 60
    case m2 = 120
    case m5 = 300
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s5: return "5秒"
        case .s10: return "10秒"
        case .s15: return "15秒"
        case .s30: return "30秒"
        case .m1: return "1分钟"
        case .m2: return "2分钟"
        case .m5: return "5分钟"
        }
    }
}

/// 省电自动熄屏
enum PowerSaveDelay: Int, CaseIterable, Identifiable {
    case s5 = 5
    case s15 = 15
    case s30 = 30
    case m1 = 60
    case never = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s5: return "5秒"
        case .s15: return "15秒"
        case .s30: return "30秒"
        case .m1: return "1分钟"
        case .never: return "永不息屏"
        }
    }
}

// MARK: - 语音控制
final class VoiceControl {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onListening: ((Bool) -> Void)?

    private(set) var startWords = ["开始录像", "开启录像", "开始录制", "开始拍摄"]
    private(set) var stopWords = ["停止录像", "结束录像", "关闭录像", "停止录制", "保存"]

    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var listening = false
    private var preferOffline = true
    private var lastStart = Date.distantPast
    private var lastStop = Date.distantPast
    private var lastHeardLog = Date.distantPast

    func setWords(start: [String], stop: [String]) {
        if !start.isEmpty { startWords = start }
        if !stop.isEmpty { stopWords = stop }
    }

    func begin() {
        lock.lock()
        // 上一次可能卡在半途（任务已销毁但标记还在），放行重新启动
        if listening, task == nil, request == nil { listening = false }
        let already = listening
        lock.unlock()
        guard !already else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            Log.write("[语音] 授权=\(status.rawValue)")
            guard status == .authorized else {
                Log.write("[语音] 未授权，请到 设置→隐私→语音识别 打开")
                return
            }
            DispatchQueue.main.async { self.startListening() }
        }
    }

    func end() {
        lock.lock()
        listening = false
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        onListening?(false)
    }

    private func startListening() {
        lock.lock()
        if listening { lock.unlock(); return }
        listening = true
        lock.unlock()
        buildTask()
    }

    /// 建/重建识别任务。重建时复用它（不能在这里再判 running，否则语音只会生效一次）
    private func buildTask() {
        lock.lock()
        guard listening else { lock.unlock(); return }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        let offlineAvailable = recognizer?.supportsOnDeviceRecognition ?? false
        if offlineAvailable && preferOffline { recognitionRequest.requiresOnDeviceRecognition = true }
        request = recognitionRequest
        lock.unlock()
        onListening?(true)

        guard let recognizer = recognizer else {
            Log.write("[语音] zh-CN 识别器不可用")
            return
        }

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty, Date().timeIntervalSince(self.lastHeardLog) > 1.5 {
                    self.lastHeardLog = Date()
                    Log.write("[语音] 听到 \(text)")
                }
                self.match(text)
                if result.isFinal {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.rebuild() }
                }
            } else if let error = error {
                Log.write("[语音] 错误 \(error.localizedDescription)")
                if offlineAvailable { self.preferOffline = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.rebuild() }
            }
        }
        Log.write("[语音] 监听启动 离线=\(offlineAvailable && preferOffline)")
    }

    private func rebuild() {
        lock.lock()
        let stillListening = listening
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        lock.unlock()
        guard stillListening else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.buildTask()
        }
    }

    private func match(_ text: String) {
        let clean = text.replacingOccurrences(of: " ", with: "")
        guard !clean.isEmpty else { return }
        let now = Date()

        // 部分结果里关键词往往先于整句出现（先听见"开始"，"录像"两字才跟上）。
        // 所以除了整词匹配，再加一条宽松规则：动词 + "录/拍" 同时出现就算命中，
        // 口令能提前小半秒生效，不用等识别器把整句收尾 —— 这就是"语音迟钝"的来源之一。
        let wantsStart = startWords.contains { clean.contains($0) }
            || (Self.startVerbs.contains { clean.contains($0) } && Self.recordWords.contains { clean.contains($0) })
        let wantsStop = stopWords.contains { clean.contains($0) }
            || (Self.stopVerbs.contains { clean.contains($0) } && Self.recordWords.contains { clean.contains($0) })

        if wantsStart {
            if now.timeIntervalSince(lastStart) > 2.5 {
                lastStart = now
                Log.write("[语音] 命中开始口令")
                DispatchQueue.main.async { [weak self] in self?.onStart?() }
            }
        } else if wantsStop {
            if now.timeIntervalSince(lastStop) > 2.5 {
                lastStop = now
                Log.write("[语音] 命中停止口令")
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
            }
        }
    }

    /// 宽松匹配用的词根（只在本类内使用，不影响设置里可自定义的口令表）
    private static let startVerbs = ["开始", "开启", "启动"]
    private static let stopVerbs = ["停止", "结束", "关闭", "保存"]
    private static let recordWords = ["录像", "录制", "拍摄", "录"]

    func feed(_ sample: CMSampleBuffer) {
        lock.lock()
        let active = listening
        let recognitionRequest = request
        lock.unlock()
        guard active, let target = recognitionRequest, let pcm = sample.pcmBuffer() else { return }
        if let mono = Self.to16kMono(pcm) { target.append(mono) }
    }

    /// 语音识别只接受 16kHz 单声道，必须重采样
    private static func to16kMono(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if Int(source.format.sampleRate) == 16000 && source.format.channelCount == 1 { return source }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source.format, to: target) else { return nil }
        let ratio = 16000.0 / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var attempts = 0
        while attempts < 6 {
            attempts += 1
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if delivered {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return source
            }
            if status == .error { return nil }
            if status == .endOfStream { break }
            if status == .haveData && output.frameLength > 0 { break }
        }
        return output.frameLength > 0 ? output : nil
    }
}

// MARK: - 水平仪
final class LevelSensor: ObservableObject {
    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var level = false
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self = self, let motion = motion else { return }
            self.roll = motion.attitude.roll
            self.pitch = motion.attitude.pitch
            self.level = abs(motion.attitude.roll) < 0.03
        }
    }
    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - 电量
final class PowerMonitor {
    private var timer: Timer?
    func start(_ handler: @escaping (Float) -> Void) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        handler(max(UIDevice.current.batteryLevel, 0))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            handler(max(UIDevice.current.batteryLevel, 0))
        }
    }
}

// MARK: - 相册
enum PhotoSaver {
    static func save(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.write("[相册] 文件不存在")
            completion(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Log.write("[相册] 无权限 \(status.rawValue)")
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, error in
                if let error = error {
                    Log.write("[相册] 失败 \(error.localizedDescription)")
                } else {
                    Log.write("[相册] 保存\(ok ? "成功" : "失败")")
                }
                completion(ok)
            }
        }
    }
}

// MARK: - 相机引擎
final class CameraEngine: NSObject, ObservableObject {
    // 对外状态
    @Published var isRecording = false
    @Published var isBusy = false            // 合并 / 保存中
    @Published var recordSeconds = 0
    @Published var toast: String?
    @Published var voiceListening = false
    @Published var battery: Float = 1
    @Published var torchOn = false
    @Published var dimmed = false
    @Published var showLog = false
    @Published var logText = ""
    @Published var segmentCount = 0
    @Published var preRecordSeconds = 0       // 预录窗口内已缓存秒数（到设定时长后停住）
    @Published var freeSpaceText = "--"       // 剩余存储空间
    @Published var recordableText = "--"      // 按当前画质预估可录时长
    // 注意：这两个计数器每帧自增，绝不能是 @Published，否则每秒触发 30 次界面重绘
    var encodedFrames = 0
    var receivedFrames = 0
    let videoOrientation: AVCaptureVideoOrientation = .portrait

    // 参数
    @Published var fieldOfView: FieldOfView = .wide { didSet { if oldValue != fieldOfView { switchLens() } } }
    @Published var quality: VideoQuality = .p1080 { didSet { if oldValue != quality { reconfigure() } } }
    @Published var frameRate: FrameRate = .fps30 { didSet { if oldValue != frameRate { applyFrameRate() } } }
    @Published var antiShake: AntiShake = .standard { didSet { if oldValue != antiShake { attachConnections() } } }
    @Published var zoom: CGFloat = 1.0 { didSet { if oldValue != zoom { applyZoom() } } }
    // 专业参数：0 表示自动
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var proControl: ProControl?          // 非空时弹出参数面板
    /// 参数面板打开时按 5Hz 自增，用来驱动实时数值刷新
    @Published var proTick = 0
    @Published var exposureBias: Float = 0          // EV
    @Published var isoValue: Float = 0              // 0 = 自动
    @Published var shutterSeconds: Double = 0       // 0 = 自动
    @Published var whiteBalanceKelvin: Float = 0    // 0 = 自动
    @Published var focusLensPosition: Float = -1    // -1 = 自动对焦

    @Published var preRecordOn = false { didSet { if oldValue != preRecordOn { syncPreRecord() } } }
    @Published var preRecordDelay: PreRecordDelay = .s15 { didSet { if oldValue != preRecordDelay { syncPreRecord() } } }
    @Published var powerSave: PowerSaveDelay = .never { didSet { resetPowerTimer() } }
    @Published var showGrid = true
    /// 左上角「剩余空间 / 可录时长」显示开关（默认关闭，设置里最末尾可打开）
    @Published var showStorage = false
    /// 音量键 / iPhone 16 相机按钮：按一下开始 / 停止录像（设置里可关）
    @Published var volumeKeyRecording = true
    /// 画面中间那个"圆圈十字架"水平仪，默认不显示（设置 → 拍摄辅助 里可以打开）
    @Published var showLevel = false
    /// 降噪：音频风噪抑制 + 画面暗光降噪，哪个系统支持就开哪个
    @Published var denoiseOn = false { didSet { if oldValue != denoiseOn { applyDenoise() } } }
    /// 降噪实际生效情况（设置页显示用）
    @Published var denoiseNote = ""
    @Published var beepOn = true
    @Published var debugInfo = false
    /// 语音控制默认开启：装好即可直接说「开始录像」「停止录像」
    @Published var voiceOn = true { didSet { if oldValue != voiceOn { voiceOn ? startVoice() : stopVoice() } } }
    @Published var startWords = ["开始录像", "开启录像", "开始录制", "开始拍摄"]
    @Published var stopWords = ["停止录像", "结束录像", "关闭录像", "停止录制", "保存"]
    /// 水印：独立功能，打开才定位、才取天气、才写进视频
    @Published var watermarkOn = false { didSet { if oldValue != watermarkOn { syncWatermark() } } }
    /// 水印里显示哪几项（时间/地点/描述/海拔/天气/温度/气压/风速）
    @Published var watermarkItems: Set<WatermarkItem> = WatermarkItem.default {
        didSet {
            if oldValue != watermarkItems {
                saveWatermarkSettings()
                refreshBurnSnapshot()
            }
        }
    }
    /// 水印数据：地点 / 海拔 / 天气…，定位和天气各填一半，谁先回来谁先显示
    @Published var watermarkData = WatermarkData() { didSet { refreshBurnSnapshot() } }
    /// 定位异常提示（只在设置页显示，不会写进视频）
    @Published var locationNote = ""
    /// 用户是否主动碰过水印（开过面板 / 勾过项）。启动预热不要在这种时候把定位停掉
    private var watermarkEngaged = false
    /// 面板打开时"补数据"的节流时间戳
    private var lastWatermarkRetry = Date.distantPast

    let session = AVCaptureSession()
    let level = LevelSensor()

    private let sessionQueue = DispatchQueue(label: "com.sportcam.session")
    /// 设备参数（曝光/ISO/快门/白平衡/对焦/变焦）专用队列。
    /// 绝不能和采集回调共用 sessionQueue —— 那会让每一条配置都排在帧处理后面，
    /// 拖动滑杆时表现为"手指动了、画面和数值要等一两秒才跟上"。
    private let deviceQueue = DispatchQueue(label: "com.sportcam.device", qos: .userInteractive)
    private let proLock = NSLock()
    private var pendingPro: [ProControl] = []
    private var proDraining = false
    private var proTickTimer: Timer?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let encoder = H264Encoder()
    private let recorder = SegmentRecorder()
    private let sound = SoundPlayer()
    private let locator = LocationProvider()
    private let weather = WeatherProvider()
    private let voice = VoiceControl()
    private let power = PowerMonitor()

    // cameraDevice 在 sessionQueue 上写、在 deviceQueue / 主线程上读，加锁保证不会读到半路换掉的引用
    private let deviceRefLock = NSLock()
    private var storedCameraDevice: AVCaptureDevice?
    private var cameraDevice: AVCaptureDevice? {
        get { deviceRefLock.lock(); defer { deviceRefLock.unlock() }; return storedCameraDevice }
        set { deviceRefLock.lock(); defer { deviceRefLock.unlock() }; storedCameraDevice = newValue }
    }
    private var cameraInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    /// 每颗摄像头建好的 input 缓存起来复用。
    /// 重建 AVCaptureDeviceInput 要重新配置设备，很慢；反复 0.5x ↔ 1x 时每次重建
    /// 就是"点了半天没反应"的元凶。只在 sessionQueue 上访问，无需加锁。
    private var inputCache: [String: AVCaptureDeviceInput] = [:]
    /// 换镜头（0.5x ↔ 1x）前先放好目标倍数，switchLens 切完镜头再套用，避免白白回到 1x
    private var pendingZoom: CGFloat = 1.0
    /// 每台设备上「画质 + 帧率」挑好的格式，选一次就记住。
    /// 每次都去遍历 device.formats（几十项、每项还要比帧率区间）太慢，那段时间预览是黑的。
    private let formatCacheLock = NSLock()
    private var formatCache: [String: AVCaptureDevice.Format] = [:]
    private var deliveredSize = CGSize.zero
    private var needEncoderRebuild = false
    private var lastKeyTime = CMTime.invalid
    private var clipIndex = 0
    private var sessionReady = false

    // 看门狗时间戳
    private var lastFrameAt: Date?
    private var lastEncodeAt = Date.distantPast
    private var lastEncoderTry = Date.distantPast
    private var lastCaptureRescue = Date.distantPast
    private var lastEncoderRescue = Date.distantPast

    // MARK: 录制期水印烧录
    // 目的：录制时就把水印画进每一帧，落盘的分段本身就是带水印的，
    // 停止录制后只需无损拼接 → 保存几乎瞬间完成（不再重编码）。
    // 代价是录制时每帧多一次 CoreImage 合成（走 GPU，1080p 每帧几毫秒）。
    private let burnContext = CIContext(options: [.useSoftwareRenderer: false])
    private var burnRenderer: WatermarkRenderer?
    private var burnRendererSize = CGSize.zero
    private var burnPool: CVPixelBufferPool?
    private var burnPoolSize = CGSize.zero
    /// 采集线程读、主线程写这三项 → 用锁保护快照
    private let burnLock = NSLock()
    private var burnOn = false
    private var burnItems: Set<WatermarkItem> = []
    private var burnData = WatermarkData()
    /// 本次录制是否真的把水印烧进了画面：合并时据此决定还要不要再叠一次
    private var clipBurnedWatermark = false

    /// 把主线程的水印状态快照给采集线程用（采集线程不能直接读 @Published）
    private func refreshBurnSnapshot() {
        burnLock.lock()
        burnOn = watermarkOn
        burnItems = watermarkItems
        burnData = watermarkData
        burnLock.unlock()
    }

    private var burnSnapshotOn: Bool {
        burnLock.lock(); defer { burnLock.unlock() }
        return burnOn
    }

    // 跨线程状态
    private let stateLock = NSLock()
    private var flagRecording = false
    private var flagVoice = false
    private var flagForceKey = false
    /// 正在翻转摄像头。连点会并发两次 beginConfiguration，会话直接乱掉 —— 用它挡掉
    private var flagSwitching = false

    private var recording: Bool { stateLock.lock(); defer { stateLock.unlock() }; return flagRecording }
    private var voiceActive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return flagVoice }

    private var recordTimer: Timer?
    private var powerTimer: Timer?
    private var uiTimer: Timer?
    private var storageTick = 0

    // MARK: 启动
    func launch() {
        configureAudioSession()
        level.start()
        sound.prepare()             // 提示音提前预热，按下秒响（不然第一下总慢半拍）
        refreshLensAvailability()   // 本机有没有超广角（决定 0.5x 能不能用）
        loadWatermarkSettings()     // 上次勾的水印项和自定义描述
        refreshBurnSnapshot()       // 把加载后的水印状态同步给采集线程
        prewarmLocation()           // 已授权就先把位置取一次，点水印时不用干等
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        recorder.onSegmentsChanged = { [weak self] total in
            self?.segmentCount = total
        }

        // 地名/海拔/天气只在水印开着时才需要
        locator.onPlace = { [weak self] text in
            guard let self = self, self.watermarkData.place != text else { return }
            var data = self.watermarkData
            data.place = text
            self.watermarkData = data
            self.locationNote = ""
            Log.write("[水印] 地点：\(text)")
        }
        locator.onFix = { [weak self] coordinate, altitude, hasAltitude in
            guard let self = self else { return }
            var data = self.watermarkData
            if hasAltitude {
                data.altitude = altitude
                data.hasAltitude = true
            }
            self.watermarkData = data
            self.weather.fetch(coordinate)
        }
        locator.onFailure = { [weak self] reason in
            // 只提示在设置页，绝不写进 watermarkData —— 否则"定位失败"会被烧进视频
            self?.locationNote = reason
        }
        weather.onUpdate = { [weak self] snap in
            guard let self = self, snap.valid else { return }
            var data = self.watermarkData
            data.weather = snap.text
            data.temperature = snap.temperature
            data.pressure = snap.pressure
            data.wind = snap.wind
            data.hasWeather = true
            self.watermarkData = data
            Log.write("[水印] 天气：\(snap.text) \(Int(snap.temperature))℃")
        }

        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.runWatchdogs()
            self.tickStatus()
            guard self.debugInfo || self.showLog else { return }
            let head = "帧:\(self.receivedFrames) 编码:\(self.encodedFrames) 段:\(self.segmentCount) "
                + "录:\(self.isRecording ? "Y" : "N") 预录:\(self.preRecordOn ? "Y" : "N")"
            self.logText = head + "\n" + LogBuffer.text()
        }

        power.start { [weak self] value in
            DispatchQueue.main.async { self?.battery = value }
        }

        encoder.onSample = { [weak self] sample in self?.onEncoded(sample) }
        voice.onListening = { [weak self] on in DispatchQueue.main.async { self?.voiceListening = on } }
        voice.onStart = { [weak self] in
            guard let self = self else { return }
            if self.recording { Log.write("[语音] 正在录制，忽略") } else { self.startRecording() }
        }
        voice.onStop = { [weak self] in
            guard let self = self else { return }
            if self.recording { self.stopRecording() }
        }

        sessionQueue.async { [weak self] in self?.buildSession() }

        // 语音默认开启：直接开始监听
        if voiceOn { startVoice() }

        observeSessionLifecycle()
    }

    /// 会话被电话/后台等打断后自动恢复，否则画面会停、编码也就停了
    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
            Log.write("[会话] 被中断 reason=\(raw)")
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            Log.write("[会话] 中断结束，尝试恢复")
            self?.restartSession()
        }
        center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            Log.write("[会话] 运行错误 \(error?.localizedDescription ?? "")")
            self?.restartSession()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            if raw == AVAudioSession.InterruptionType.ended.rawValue {
                Log.write("[音频] 中断结束，恢复会话")
                self?.restartSession()
            }
        }
    }

    private func restartSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.attachConnectionsLocked()
            // 会话恢复后采集时间戳会跳变，编码器与分段都要重新开始
            self.encoder.invalidate()
            self.needEncoderRebuild = true
            self.recorder.reset()
            self.rearmPreRecord()
            Log.write("[会话] 恢复完成 running=\(self.session.isRunning)")
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // 关键：录像必须用 .videoRecording 模式。
            // .default 模式会给麦克风套上"语音通话"那套自动增益/降噪处理，
            // 录出来的声音会一阵一阵发闷、发爆（就是听到的"滋滋/爆音"）。
            // 参考 App 用的正是 PlayAndRecord + VideoRecording 这一组。
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                         options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            if audioSession.sampleRate > 0 {
                Log.write("[音频] 录音就绪 \(Int(audioSession.sampleRate))Hz")
            } else {
                Log.write("[音频] 录音就绪")
            }
        } catch {
            Log.write("[音频] 会话失败 \(error.localizedDescription)")
        }
    }

    // MARK: 会话
    private func buildSession() {
        guard !sessionReady else { return }
        sessionReady = true
        session.beginConfiguration()
        if session.canSetSessionPreset(quality.preset) { session.sessionPreset = quality.preset }

        if let device = camera(cameraPosition, fieldOfView: fieldOfView),
           let input = cachedInput(for: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraDevice = device
            cameraInput = input
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()
        attachConnectionsLocked()
        applyFrameRateLocked()
        applyDenoiseLocked()
        session.startRunning()
        attachConnectionsLocked()
        Log.write("[会话] 启动 \(quality.rawValue) \(frameRate.rawValue)fps \(fieldOfView.rawValue)")
    }

    private func camera(_ position: AVCaptureDevice.Position, fieldOfView fov: FieldOfView) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        if fov == .ultraWide, let ultra = ultraWideDevice() { return ultra }
        return AVCaptureDevice.default(fov.lens, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// 严格按镜头类型取设备：本机没有这颗镜头（比如 iPhone 8 Plus 没有超广角）就返回 nil，
    /// 用来在切焦段之前判断"到底需不需要动会话"。
    private func lensDevice(_ fov: FieldOfView) -> AVCaptureDevice? {
        if fov == .ultraWide { return ultraWideDevice() }
        return AVCaptureDevice.default(fov.lens, for: .video, position: .back)
    }

    /// 后置超广角：优先取独立的那颗；个别机型只把超广角藏在「三摄 / 双广角」虚拟设备里，
    /// 这时退回虚拟设备（它的 1x 端就是超广角），保证有超广角的机器一定用得上 0.5x。
    /// 「视角」列表、0.5x 档位、实际切镜头都必须走这一个入口，三处结论才一致。
    private func ultraWideDevice() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return device
        }
        // 部分机型只把超广角暴露在「三摄 / 双广角」这类虚拟设备里：
        // 这种虚拟设备的最广一端就是超广角，videoZoomFactor 1.0 即 0.5x 视野。
        // 用一次性 DiscoverySession 把后置所有镜头都列出来，逐个按类型取，避免漏。
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInTripleCamera, .builtInDualWideCamera
        ]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: .back).devices
        if let ultra = devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return ultra }
        if let triple = devices.first(where: { $0.deviceType == .builtInTripleCamera }) { return triple }
        if let dualWide = devices.first(where: { $0.deviceType == .builtInDualWideCamera }) { return dualWide }
        return nil
    }

    /// 取（或首次创建）某台摄像头的 input。只在 sessionQueue 上调用。
    private func cachedInput(for device: AVCaptureDevice) -> AVCaptureDeviceInput? {
        if let cached = inputCache[device.uniqueID] { return cached }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        inputCache[device.uniqueID] = input
        return input
    }

    /// 前后摄像头翻转。
    /// 以前的毛病：连点会并发跑两次 beginConfiguration，把会话搞乱（表现为卡住/黑屏）；
    /// 而且 cameraPosition 要等换完才更新，按钮和镜像都慢半拍。
    func toggleCamera() {
        stateLock.lock()
        if flagSwitching {
            stateLock.unlock()
            return                       // 上一次还没换完，忽略这次点击
        }
        flagSwitching = true
        stateLock.unlock()

        let next: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        // 注意：这里故意不提前改 cameraPosition。
        // 提前改会让预览先按新方向镜像翻一次，随后换 input 再黑一下 —— 两次视觉变化叠起来
        // 就是用户看到的"翻回去会闪一下"。改成换完镜头后在主线程一次性落状态，视觉只变一次。
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.flagSwitching = false
                self.stateLock.unlock()
            }

            func giveUp(_ reason: String) {
                DispatchQueue.main.async { self.message(reason) }
            }

            guard !self.recording else {
                Log.write("[镜头] 录制中不可翻转")
                giveUp("录制中不能翻转")
                return
            }

            // 前置只有广角：切过去时把视角收回广角，免得切回来时焦段对不上
            let fov: FieldOfView = next == .front ? .wide : self.fieldOfView
            guard let device = self.camera(next, fieldOfView: fov),
                  let input = self.cachedInput(for: device) else {
                giveUp("该机型不支持翻转")
                return
            }

            let old = self.cameraInput
            // 换镜头前先关掉闪光灯：否则后置的灯会一直亮着，切到前置也关不掉
            if let oldDevice = self.cameraDevice, oldDevice.hasTorch,
               oldDevice.isTorchModeSupported(.off) {
                try? oldDevice.lockForConfiguration()
                oldDevice.torchMode = .off
                oldDevice.unlockForConfiguration()
            }
            self.session.beginConfiguration()
            if let old = old { self.session.removeInput(old) }
            guard self.session.canAddInput(input) else {
                if let old = old { self.session.addInput(old) }
                self.session.commitConfiguration()
                giveUp("翻转失败，请重试")
                return
            }
            // 先把新设备的格式 / 帧率定好，再挂上去：这样"换 input"和"换格式"
            // 合并成同一次中断。等 commit 之后再改 activeFormat，预览会断开重连，
            // 用户看到的就是"闪一下"。
            self.applyFrameRateLocked(on: device)
            self.session.addInput(input)
            self.cameraInput = input
            self.cameraDevice = device
            self.pendingZoom = 1.0
            self.applyDenoiseLocked()          // 新摄像头的暗光降噪也在配置块里一起生效
            self.session.commitConfiguration()
            self.attachConnectionsLocked()
            self.encoder.invalidate()
            self.needEncoderRebuild = true
            // 换了摄像头：分段格式已不一致，旧段全部作废
            self.recorder.reset()
            self.rearmPreRecord()
            DispatchQueue.main.async {
                self.cameraPosition = next
                // 先落 cameraPosition 再落 fieldOfView：前者已是 .front 时，
                // fieldOfView 的 didSet 会走 switchLens，被"前置不支持切换焦段"挡掉，正好不动会话
                self.fieldOfView = fov
                self.torchOn = false        // 上面已经把灯关了，按钮同步灭掉
                self.zoom = 1.0
                self.exposureBias = 0
                self.isoValue = 0
                self.shutterSeconds = 0
                self.whiteBalanceKelvin = 0
                self.focusLensPosition = -1
            }
            Log.write("[镜头] 翻转 → \(next == .front ? "前置" : "后置")")
        }
    }

    /// 重新挂好输出连接。
    /// 每次 beginConfiguration/commitConfiguration 之后，数据输出的 connection 可能被置为
    /// isEnabled = false（预览层是另一条链路，所以预览照常、数据回调却停了），必须显式恢复。
    private func attachConnectionsLocked() {
        if let connection = videoOutput.connection(with: .video) {
            if !connection.isEnabled { connection.isEnabled = true }
            if connection.isVideoOrientationSupported { connection.videoOrientation = videoOrientation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = antiShake.mode
            }
        }
        if let connection = audioOutput.connection(with: .audio), !connection.isEnabled {
            connection.isEnabled = true
        }
    }

    private func applyFrameRate() { sessionQueue.async { [weak self] in self?.applyFrameRateLocked() } }

    private func applyFrameRateLocked() {
        guard let device = cameraDevice else { return }
        applyFrameRateLocked(on: device)
    }

    /// 给指定设备挑格式、设帧率。
    /// 换摄像头时会带着新设备在 beginConfiguration 块里调用 —— 让"换 input"和"换格式"
    /// 合并成同一次中断；等 commitConfiguration 之后再动 activeFormat，预览会再黑一下。
    private func applyFrameRateLocked(on device: AVCaptureDevice) {
        let fps = Double(frameRate.rawValue)
        let target = quality.size
        let key = "\(device.uniqueID)|\(quality.rawValue)|\(frameRate.rawValue)"

        formatCacheLock.lock()
        let cached = formatCache[key]
        formatCacheLock.unlock()

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 选格式：既要比目标分辨率大，宽高比也要对得上。
            // 关键：4:3 绝不能匹配到同高的 16:9（1440×1080 与 1920×1080 高度相同），
            // 否则「4:3 超广视野」会退化成普通 16:9 裁切，看着就是没变化。
            // 满足条件的里面挑面积最小的那颗，避免想要 1080P 却给了 4K。
            func pick(aspect wanted: Double) -> AVCaptureDevice.Format? {
                let list = device.formats.filter { format in
                    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let w = Int(dims.width), h = Int(dims.height)
                    guard w >= target.width, h >= target.height else { return false }
                    let aspect = Double(w) / Double(h)
                    guard abs(aspect - wanted) < 0.06 else { return false }
                    return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
                }
                return list.min { lhs, rhs in
                    let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
                }
            }

            // 本机没有 4:3 时退回 16:9：宁可少一点视野，也不能让会话停在半套格式上
            var matched = cached ?? pick(aspect: quality.aspect)
            if matched == nil, quality.is4x3 { matched = pick(aspect: 16.0 / 9.0) }
            if let matched = matched {
                if cached == nil {
                    formatCacheLock.lock()
                    formatCache[key] = matched
                    formatCacheLock.unlock()
                }
                // 已经就是这个格式就别再赋值：重设一次 activeFormat 预览会再黑一下
                if device.activeFormat !== matched { device.activeFormat = matched }
            }

            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            if device.activeVideoMinFrameDuration != duration { device.activeVideoMinFrameDuration = duration }
            if device.activeVideoMaxFrameDuration != duration { device.activeVideoMaxFrameDuration = duration }
        } catch {
            Log.write("[会话] 帧率失败 \(error.localizedDescription)")
        }
    }

    func attachConnections() { sessionQueue.async { [weak self] in self?.attachConnectionsLocked() } }

    func switchLens() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // selectZoomChip 会提前放好目标倍数（比如点 2x 切回广角后仍要停在 2x）
            let restoreZoom = self.pendingZoom
            self.pendingZoom = 1.0

            if self.recording {
                Log.write("[镜头] 录制中不可切换")
                return
            }
            guard self.cameraPosition == .back else {
                Log.write("[镜头] 前置摄像头不支持切换焦段")
                return
            }
            guard let device = self.camera(.back, fieldOfView: self.fieldOfView) else { return }

            // 已经就是同一颗镜头（本机没有超广角时 0.5x 会回退到广角）：
            // 只改倍数就行。以前这里会把同一颗摄像头 removeInput + addInput 重来一遍，
            // 画面必然黑一下 —— 这就是"点 0.5x 会闪"的原因。
            if let current = self.cameraDevice, current.uniqueID == device.uniqueID {
                DispatchQueue.main.async { self.zoom = restoreZoom }
                Log.write("[镜头] \(self.fieldOfView.rawValue)（同镜头，仅改变焦倍数）")
                return
            }

            guard let input = self.cachedInput(for: device) else { return }
            let old = self.cameraInput
            self.session.beginConfiguration()
            if let old = old { self.session.removeInput(old) }
            guard self.session.canAddInput(input) else {
                if let old = old { self.session.addInput(old) }
                self.session.commitConfiguration()
                Log.write("[镜头] 切换失败，已还原")
                return
            }
            // 先在配置块里把新镜头格式定好再挂上去，避免 commit 之后再改导致二次黑帧
            self.applyFrameRateLocked(on: device)
            self.session.addInput(input)
            self.cameraInput = input
            self.cameraDevice = device
            self.session.commitConfiguration()
            self.attachConnectionsLocked()
            self.encoder.invalidate()
            self.needEncoderRebuild = true
            // 换了镜头：分段格式已不一致，旧段全部作废
            self.recorder.reset()
            self.rearmPreRecord()
            DispatchQueue.main.async {
                self.zoom = restoreZoom
                self.exposureBias = 0
                self.isoValue = 0
                self.shutterSeconds = 0
                self.whiteBalanceKelvin = 0
                self.focusLensPosition = -1
            }
            Log.write("[镜头] \(self.fieldOfView.rawValue)")
        }
    }

    private func reconfigure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recording { Log.write("[会话] 录制中不可改分辨率"); return }
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(self.quality.preset) {
                self.session.sessionPreset = self.quality.preset
            }
            self.session.commitConfiguration()
            self.attachConnectionsLocked()
            self.applyFrameRateLocked()
            self.encoder.invalidate()
            self.needEncoderRebuild = true
            self.recorder.reset()
            self.rearmPreRecord()
            Log.write("[会话] \(self.quality.rawValue)")
        }
    }

    func applyZoom() { applyPro(.zoom) }

    private func applyZoomLocked() {
        guard let device = cameraDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let maxFactor = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            let target = max(1.0, min(zoom, maxFactor))
            let distance = abs(target - device.videoZoomFactor)
            // 上一次的斜坡还没跑完就再点：先取消，否则两次斜坡叠在一起会忽快忽慢
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            if distance < 0.01 {
                device.videoZoomFactor = target
                return
            }
            // 固定时长的小斜坡：既跟手，又不会在 2x 附近触发系统反复换镜头 + 重新对焦
            device.ramp(toVideoZoomFactor: target, withRate: Float(max(distance / 0.28, 3)))
        } catch {
            Log.write("[变焦] 失败 \(error.localizedDescription)")
        }
    }

    /// 0.5x / 1x / 2x 三档。
    /// 核心原则：能不复建会话就绝不复建 —— 同一颗镜头内只改 videoZoomFactor（平滑过渡，无黑帧），
    /// 只有真的需要换镜头（0.5x 的超广角）时才换 input。
    func selectZoomChip(_ chip: String) {
        let fov: FieldOfView
        let factor: CGFloat
        switch chip {
        case "0.5x": fov = .ultraWide; factor = 1.0
        case "2x":   fov = .wide;      factor = 2.0
        default:     fov = .wide;      factor = 1.0
        }

        // 0.5x 要后置超广角。按钮已经是置灰的，这里只是兜底
        guard isZoomChipAvailable(chip) else { return }

        guard cameraPosition == .back else {
            zoom = factor                  // 前置没有多摄，直接在广角上做数字变焦
            return
        }

        if fieldOfView == fov {
            zoom = factor                  // 同一颗镜头内（1x ↔ 2x）：只改变焦倍数，不重建会话，无黑帧
        } else {
            pendingZoom = factor           // 真要换镜头：切完由 switchLens 套用
            fieldOfView = fov
        }
    }

    /// 焦段档位：本机有超广角才给三档，没有就只留广角 / 长焦，
    /// 摆出来的一定点得动，不会出现灰着的 0.5x。
    var zoomChips: [String] { ["0.5x", "1x", "2x"].filter { isZoomChipAvailable($0) } }
    /// 后置有没有超广角镜头（0.5x 靠它）。开机算一次就够，查设备不该每帧都跑。
    @Published var ultraWideAvailable = false
    /// 本机摄像头有没有真正的 4:3 视频格式（没有就不摆这两档，免得选了没效果）
    @Published var supports4x3 = false

    func refreshLensAvailability() {
        // 和「视角」列表、实际切镜头同源（都走 ultraWideDevice）：
        // 三处结论必须一致，否则会出现「有 0.5x 档、视角里却没有超广角」这种自相矛盾。
        ultraWideAvailable = ultraWideDevice() != nil
        let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        supports4x3 = back?.formats.contains { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.width) >= 1440 else { return false }
            return abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.06
        } ?? false
        Log.write("[镜头] 超广角\(ultraWideAvailable ? "可用" : "不可用") · 4:3\(supports4x3 ? "可用" : "不可用")")
    }

    /// 可用的分辨率档：4:3 只有本机真支持才摆出来
    var availableQualities: [VideoQuality] {
        VideoQuality.allCases.filter { !$0.is4x3 || supports4x3 }
    }

    /// 这一档在当前机型/当前镜头上能不能用。0.5x 需要后置超广角，前置也做不了。
    func isZoomChipAvailable(_ chip: String) -> Bool {
        guard chip == "0.5x" else { return true }
        return cameraPosition == .back && ultraWideAvailable
    }

    /// 本机后置真实存在的镜头。设置里的「视角」只列有的，免得选了没反应。
    var availableFieldOfViews: [FieldOfView] {
        FieldOfView.allCases.filter { lensDevice($0) != nil }
    }

    /// 已经授权过定位的话，启动时先悄悄取一次位置。
    /// 这样用户点开水印面板时地名已经在手里，不会出现"要点两次才出来"。
    /// 30 秒内没碰过水印就停掉，不留后台定位。
    private func prewarmLocation() {
        guard locator.isAuthorized else { return }
        watermarkEngaged = false
        locator.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, !self.watermarkOn, !self.watermarkEngaged else { return }
            self.locator.stop()
        }
    }

    /// 某档是否处于选中态（前置没有超广角/长焦，统一按广角算）
    func isZoomChipSelected(_ chip: String) -> Bool {
        let fov: FieldOfView = cameraPosition == .front ? .wide : fieldOfView
        switch chip {
        case "0.5x": return fov == .ultraWide
        case "2x":   return fov == .wide && zoom >= 1.8
        default:     return fov == .wide && zoom < 1.8
        }
    }

    // MARK: 专业参数（曝光 / ISO / 快门 / 白平衡）
    func openPro(_ control: ProControl) {
        proControl = control
        startProTick()
    }

    func closePro() {
        proControl = nil
        stopProTick()
    }

    /// 面板打开时按 5Hz 推一下：自动模式下 ISO / 快门 / 白平衡 一直在变，
    /// 不推 SwiftUI 就不会重绘，看上去就是"数值不动"。
    private func startProTick() {
        proTickTimer?.invalidate()
        proTickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, self.proControl != nil else { return }
            self.proTick &+= 1
        }
    }

    private func stopProTick() {
        proTickTimer?.invalidate()
        proTickTimer = nil
    }

    /// 面板那一行用的紧凑实时值
    func proShort(_ control: ProControl) -> String {
        let raw = proEffective(control)
        // 自动模式下偶尔会读到 0 / NaN，直接转 Int 会崩，先兜住
        let value = raw.isFinite ? raw : 0
        switch control {
        case .exposure: return String(format: "%.1f", value)
        case .shutter: return shutterText(value)
        case .iso: return "\(Int(value.rounded()))"
        case .whiteBalance: return "\(Int(value.rounded()))"
        case .focus: return String(format: "%.2f", value)
        case .zoom: return String(format: "%.1fx", value)
        }
    }

    /// 该参数是否已从自动切到手动
    func proIsManual(_ control: ProControl) -> Bool {
        switch control {
        case .exposure: return abs(exposureBias) > 0.01
        case .iso: return isoValue > 0
        case .shutter: return shutterSeconds > 0
        case .whiteBalance: return whiteBalanceKelvin > 0
        case .focus: return focusLensPosition >= 0
        case .zoom: return zoom > 1.05
        }
    }

    /// 可调范围（跟着当前摄像头/格式走）
    func proRange(_ control: ProControl) -> ClosedRange<Double> {
        guard let device = cameraDevice else { return 0...1 }
        let format = device.activeFormat
        switch control {
        case .exposure:
            let lo = Double(device.minExposureTargetBias)
            let hi = Double(device.maxExposureTargetBias)
            return lo < hi ? lo...hi : -2...2
        case .iso:
            let lo = Double(format.minISO), hi = Double(format.maxISO)
            return lo < hi ? lo...hi : 24...3200
        case .shutter:
            let lo = CMTimeGetSeconds(format.minExposureDuration)
            let hi = CMTimeGetSeconds(format.maxExposureDuration)
            return lo > 0 && hi > lo ? lo...hi : (1.0 / 8000.0)...(1.0 / 2.0)
        case .whiteBalance:
            return 2500...9000
        case .focus:
            return 0...1
        case .zoom:
            let hi = min(Double(device.activeFormat.videoMaxZoomFactor), 8.0)
            return 1.0...max(hi, 1.1)
        }
    }

    /// 当前生效值：自动时取设备当前值，滑杆就停在自动的位置上
    func proEffective(_ control: ProControl) -> Double {
        guard let device = cameraDevice else { return 0 }
        switch control {
        case .exposure:
            return Double(exposureBias)
        case .iso:
            return isoValue > 0 ? Double(isoValue) : Double(device.iso)
        case .shutter:
            return shutterSeconds > 0 ? shutterSeconds : CMTimeGetSeconds(device.exposureDuration)
        case .whiteBalance:
            if whiteBalanceKelvin > 0 { return Double(whiteBalanceKelvin) }
            return Double(device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature)
        case .focus:
            return focusLensPosition >= 0 ? Double(focusLensPosition) : Double(device.lensPosition)
        case .zoom:
            return Double(zoom)
        }
    }

    /// 换算成 0...1 的滑杆位置（ISO / 快门用对数刻度）
    func proNormalized(_ control: ProControl) -> Double {
        let range = proRange(control)
        let value = proEffective(control)
        switch control {
        case .exposure, .whiteBalance, .focus:
            guard range.upperBound > range.lowerBound else { return 0.5 }
            return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        case .iso, .shutter, .zoom:
            guard range.lowerBound > 0, range.upperBound > range.lowerBound, value > 0 else { return 0 }
            let t = (log(value) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound))
            return min(max(t, 0), 1)
        }
    }

    func proDisplay(_ control: ProControl) -> String {
        switch control {
        case .exposure:
            return proIsManual(.exposure) ? String(format: "%+.1f EV", exposureBias) : "自动"
        case .iso:
            return isoValue > 0 ? "ISO \(Int(isoValue))" : "自动"
        case .shutter:
            guard shutterSeconds > 0 else { return "自动" }
            return shutterText(shutterSeconds)
        case .whiteBalance:
            return whiteBalanceKelvin > 0 ? "\(Int(whiteBalanceKelvin))K" : "自动"
        case .focus:
            return focusLensPosition >= 0 ? String(format: "%.2f", focusLensPosition) : "自动"
        case .zoom:
            return String(format: "%.1fx", zoom)
        }
    }

    func proRangeText(_ control: ProControl) -> (String, String) {
        let range = proRange(control)
        switch control {
        case .exposure:
            return (String(format: "%.0f", range.lowerBound), String(format: "%.0f", range.upperBound))
        case .iso:
            return ("\(Int(range.lowerBound))", "\(Int(range.upperBound))")
        case .shutter:
            return (shutterText(range.lowerBound), shutterText(range.upperBound))
        case .whiteBalance:
            return ("2500K", "9000K")
        case .focus:
            return ("近", "远")
        case .zoom:
            return (String(format: "%.1fx", range.lowerBound), String(format: "%.1fx", range.upperBound))
        }
    }

    private func shutterText(_ seconds: Double) -> String {
        // 自动模式下可能读到 0，1/0 再转 Int 会崩
        guard seconds.isFinite, seconds > 0 else { return "--" }
        if seconds >= 1 { return String(format: "%.0f\"", seconds) }
        return "1/\(Int((1.0 / seconds).rounded()))"
    }

    func setPro(_ control: ProControl, normalized t: Double) {
        let clamped = min(max(t, 0), 1)
        let range = proRange(control)
        switch control {
        case .exposure:
            exposureBias = Float(range.lowerBound + clamped * (range.upperBound - range.lowerBound))
        case .iso:
            isoValue = Float(logValue(range.lowerBound, range.upperBound, clamped))
        case .shutter:
            shutterSeconds = logValue(range.lowerBound, range.upperBound, clamped)
        case .whiteBalance:
            whiteBalanceKelvin = Float(range.lowerBound + clamped * (range.upperBound - range.lowerBound))
        case .focus:
            focusLensPosition = Float(clamped)
        case .zoom:
            zoom = CGFloat(logValue(range.lowerBound, range.upperBound, clamped))
        }
        applyPro(control)
    }

    func resetPro(_ control: ProControl) {
        switch control {
        case .exposure: exposureBias = 0
        case .iso: isoValue = 0
        case .shutter: shutterSeconds = 0
        case .whiteBalance: whiteBalanceKelvin = 0
        case .focus: focusLensPosition = -1
        case .zoom: zoom = 1.0
        }
        applyPro(control)
    }

    /// 点按画面对焦 + 测光
    func focus(atDevicePoint point: CGPoint) {
        deviceQueue.async { [weak self] in
            guard let self = self, let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let x = min(max(point.x, 0), 1)
                let y = min(max(point.y, 0), 1)
                let poi = CGPoint(x: x, y: y)
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = poi
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = poi
                    if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                }
                // 点按后回到自动对焦，手动滑杆状态同步清掉
                DispatchQueue.main.async { self.focusLensPosition = -1 }
            } catch {
                Log.write("[专业] 点按对焦失败 \(error.localizedDescription)")
            }
        }
    }

    private func logValue(_ lo: Double, _ hi: Double, _ t: Double) -> Double {
        guard lo > 0, hi > lo else { return lo + (hi - lo) * t }
        return exp(log(lo) + t * (log(hi) - log(lo)))
    }

    /// 拖动滑杆时每秒会回调几十次，中间值没必要逐个下发给硬件（它也来不及响应）。
    /// 这里做两件事：
    ///   1) 同一参数在队列里最多只留一份，后面的直接覆盖前面的（合并成一次下发）；
    ///   2) 全部跑在 deviceQueue 上，不再占用采集回调队列。
    private func applyPro(_ control: ProControl) {
        proLock.lock()
        if !pendingPro.contains(control) { pendingPro.append(control) }
        let busy = proDraining
        proDraining = true
        proLock.unlock()
        guard !busy else { return }
        deviceQueue.async { [weak self] in self?.drainPro() }
    }

    private func drainPro() {
        while true {
            proLock.lock()
            guard !pendingPro.isEmpty else {
                proDraining = false
                proLock.unlock()
                return
            }
            let control = pendingPro.removeFirst()
            proLock.unlock()
            // 这里读到的永远是该参数的最新值
            switch control {
            case .whiteBalance: applyWhiteBalanceLocked()
            case .focus: applyFocusLocked()
            case .zoom: applyZoomLocked()
            case .exposure, .shutter, .iso: applyExposureLocked()
            }
        }
    }

    private func applyFocusLocked() {
        guard let device = cameraDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if focusLensPosition < 0 {
                // 每帧都重设模式会让 AF 重新收敛一遍，画面一顿一顿的 —— 只在需要时切
                if device.isFocusModeSupported(.continuousAutoFocus),
                   device.focusMode != .continuousAutoFocus {
                    device.focusMode = .continuousAutoFocus
                }
            } else if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: min(max(focusLensPosition, 0), 1),
                                          completionHandler: nil)
            }
        } catch {
            Log.write("[专业] 对焦失败 \(error.localizedDescription)")
        }
    }

    private func applyExposureLocked() {
        guard let device = cameraDevice else { return }
        let format = device.activeFormat
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if isoValue > 0 || shutterSeconds > 0 {
                var duration = device.exposureDuration
                if shutterSeconds > 0 {
                    let lo = CMTimeGetSeconds(format.minExposureDuration)
                    let hi = CMTimeGetSeconds(format.maxExposureDuration)
                    duration = CMTime(seconds: min(max(shutterSeconds, lo), hi), preferredTimescale: 1_000_000)
                }
                let iso = isoValue > 0 ? min(max(isoValue, format.minISO), format.maxISO) : device.iso
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                // 同上：模式没变就别重设，否则 AE 每帧重新收敛
                if device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(exposureBias, completionHandler: nil)
            }
        } catch {
            Log.write("[专业] 曝光失败 \(error.localizedDescription)")
        }
    }

    private func applyWhiteBalanceLocked() {
        guard let device = cameraDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if whiteBalanceKelvin <= 0 {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
                   device.whiteBalanceMode != .continuousAutoWhiteBalance {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else if device.isWhiteBalanceModeSupported(.locked) {
                let temp = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: whiteBalanceKelvin, tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: temp)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        } catch {
            Log.write("[专业] 白平衡失败 \(error.localizedDescription)")
        }
    }

    // MARK: 降噪
    private func applyDenoise() {
        sessionQueue.async { [weak self] in self?.applyDenoiseLocked() }
    }

    /// 音频走系统的风噪抑制（iOS 17+ 才开放），画面走低光增强抑制暗部噪点。
    /// 两者都不支持的话就在设置页说明白，不做假开关。
    private func applyDenoiseLocked() {
        let on = denoiseOn
        var audioOK = false
        var videoOK = false

        if let input = audioInput {
            // 风噪抑制挂在 AVCaptureDeviceInput 上，而且要 iOS 18 才开放
            if #available(iOS 18.0, *), input.isWindNoiseRemovalSupported {
                input.isWindNoiseRemovalEnabled = on
                audioOK = true
            }
        }

        if let device = cameraDevice, device.isLowLightBoostSupported {
            do {
                try device.lockForConfiguration()
                device.automaticallyEnablesLowLightBoostWhenAvailable = on
                device.unlockForConfiguration()
                videoOK = true
            } catch {
                Log.write("[降噪] 画面设置失败 \(error.localizedDescription)")
            }
        }

        var parts: [String] = []
        parts.append(audioOK ? "麦克风风噪抑制" : "本机不支持麦克风风噪抑制")
        parts.append(videoOK ? "暗光画面降噪" : "本机不支持暗光画面降噪")
        let note = parts.joined(separator: " · ")
        DispatchQueue.main.async { self.denoiseNote = on ? note : "" }
    }

    // MARK: 预录
    private func syncPreRecord() {
        preRecordSeconds = 0
        if preRecordOn {
            rearmPreRecord()
        } else {
            recorder.disarm()
        }
    }

    private func rearmPreRecord() {
        guard preRecordOn, !recording else { return }
        recorder.arm(preRecordSeconds: Double(preRecordDelay.rawValue))
    }

    /// 水印总开关：打开才开始定位 / 取天气，关掉立刻停，不留后台定位
    private func syncWatermark() {
        refreshBurnSnapshot()          // 开关一变，采集线程下一帧就要知道
        if watermarkOn {
            Log.write("[水印] 开启")
            ensureWatermarkStarted()
        } else {
            locator.stop()
            weather.cancel()
            locationNote = ""
            Log.write("[水印] 关闭")
        }
    }

    /// 启动定位 / 天气（幂等）。
    /// 点开「水印时间」面板、或勾选任意一项时都会调 —— 目的是提前把定位跑起来，
    /// 等用户勾上的那一刻数据已经在手里，不用再开关两次。
    func ensureWatermarkStarted() {
        watermarkEngaged = true
        locator.requestRefresh()
    }

    /// 面板还开着、但地点 / 天气还没回来时，每隔几秒补一次 ——
    /// 之前要"关掉再打开"才出数据，就是因为在跑的时候不会再取一次。
    func refreshWatermarkIfNeeded() {
        guard watermarkOn || watermarkEngaged, locationNote.isEmpty else { return }
        guard watermarkData.place.isEmpty || !watermarkData.hasWeather else { return }
        guard Date().timeIntervalSince(lastWatermarkRetry) > 4 else { return }
        lastWatermarkRetry = Date()
        locator.requestRefresh()
    }

    /// 勾选 / 取消某一项。勾选时顺手把总开关打开 —— 和参考 App 一样，点一下水印就出现。
    func toggleWatermarkItem(_ item: WatermarkItem, on: Bool) {
        var items = watermarkItems
        if on { items.insert(item) } else { items.remove(item) }
        watermarkItems = items
        if on && !watermarkOn { watermarkOn = true } else { ensureWatermarkStarted() }
    }

    /// 当前水印的每一行文本。预览和烧录共用同一套拼法，保证所见即所得。
    func watermarkLines(at date: Date) -> [String] {
        WatermarkComposer.lines(date: date, data: watermarkData, items: watermarkItems)
    }

    /// 面板里某一项右侧显示的当前值
    func watermarkValue(_ item: WatermarkItem) -> String {
        WatermarkComposer.value(of: item, data: watermarkData)
    }

    func setWatermarkDesc(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var data = watermarkData
        data.desc = trimmed
        watermarkData = data
        UserDefaults.standard.set(trimmed, forKey: CameraEngine.descKey)
    }

    private static let itemsKey = "sportcam.watermark.items"
    private static let descKey = "sportcam.watermark.desc"

    private func saveWatermarkSettings() {
        UserDefaults.standard.set(watermarkItems.map { $0.rawValue }, forKey: CameraEngine.itemsKey)
    }

    private func loadWatermarkSettings() {
        let store = UserDefaults.standard
        if let raw = store.array(forKey: CameraEngine.itemsKey) as? [String] {
            watermarkItems = Set(raw.compactMap { WatermarkItem(rawValue: $0) })
        }
        var data = watermarkData
        if let text = store.string(forKey: CameraEngine.descKey), !text.isEmpty {
            data.desc = text
        }
        watermarkData = data
    }

    // MARK: 录制
    func startRecording() {
        stateLock.lock()
        if flagRecording || isBusy {
            stateLock.unlock()
            return
        }
        flagRecording = true
        stateLock.unlock()

        resetPowerTimer()
        if beepOn { sound.playStart() }
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordSeconds = 0
            self.startRecordTimer()
        }

        // 未开预录：从现在开始，请求一个关键帧以便立刻起段
        if !preRecordOn {
            recorder.arm(preRecordSeconds: 0)
            stateLock.lock(); flagForceKey = true; stateLock.unlock()
        }
        // 录制期若正在烧水印（含预录段），落盘的分段自带水印 → 停止时无需再重编码
        clipBurnedWatermark = burnSnapshotOn
        recorder.beginClip()
        Log.write("[录制] 开始")
    }

    /// 音量键 / iPhone 16 相机按钮：按一下切换录制
    func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func stopRecording() {
        stateLock.lock()
        let wasActive = flagRecording
        flagRecording = false
        stateLock.unlock()
        guard wasActive else { return }

        if beepOn { sound.playStop() }
        DispatchQueue.main.async {
            self.isRecording = false
            self.stopRecordTimer()
            self.isBusy = true
        }
        resetPowerTimer()

        recorder.endClip { [weak self] clip in
            guard let self = self else { return }
            guard !clip.segments.isEmpty else {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.message("没有录到画面，请重试")
                }
                return
            }
            let output = self.nextClipURL()
            // 水印：录制期已经烧进画面了 → 传 nil，合并走 Passthrough 无损秒存；
            // 只有"录制时没烧"（比如中途才打开水印）才在这里补一层，那才需要重编码。
            let mark: WatermarkConfig? = (self.watermarkOn && !self.clipBurnedWatermark) ? WatermarkConfig(
                data: self.watermarkData,
                items: self.watermarkItems,
                startDate: clip.segments.map { $0.createdAt }.min() ?? Date()
            ) : nil
            SegmentMerger.merge(clip, to: output, watermark: mark) { ok in
                for seg in clip.segments { try? FileManager.default.removeItem(at: seg.url) }
                if let audio = clip.audio { try? FileManager.default.removeItem(at: audio.url) }
                guard ok else {
                    DispatchQueue.main.async {
                        self.isBusy = false
                        self.message("保存失败，请重试")
                    }
                    return
                }
                PhotoSaver.save(output) { saved in
                    try? FileManager.default.removeItem(at: output)
                    DispatchQueue.main.async {
                        self.isBusy = false
                        self.message(saved ? "保存成功" : "保存相册失败（检查相册权限）")
                    }
                }
            }
        }

        // 停录后预录继续跑
        rearmPreRecord()
    }

    private func onEncoded(_ sample: CMSampleBuffer) {
        lastEncodeAt = Date()
        encodedFrames &+= 1
        guard recording || preRecordOn else { return }
        recorder.appendVideo(sample)
    }

    private func nextClipURL() -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        clipIndex += 1
        return folder.appendingPathComponent("SportCam_\(formatter.string(from: Date()))_\(clipIndex).mov")
    }

    // MARK: 看门狗
    /// 画面停了救采集；"该编码却没输出"才重建编码器
    private func runWatchdogs() {
        let now = Date()

        if let last = lastFrameAt, now.timeIntervalSince(last) > 2.5 {
            if now.timeIntervalSince(lastCaptureRescue) > 5 {
                lastCaptureRescue = now
                Log.write("[看门狗] 2.5秒无画面，重挂数据输出")
                sessionQueue.async { [weak self] in self?.rescueCaptureLocked() }
            }
        }

        // 只有"本来就该编码"时才检查输出。预录关闭且未录制时是故意不编码的，不能误判成故障。
        let shouldEncode = preRecordOn || recording
        if shouldEncode, let last = lastFrameAt, now.timeIntervalSince(last) < 1.5,
           now.timeIntervalSince(lastEncodeAt) > 3 {
            if now.timeIntervalSince(lastEncoderRescue) > 3 {
                lastEncoderRescue = now
                Log.write("[看门狗] 3秒无编码输出，重建编码器")
                sessionQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.encoder.invalidate()
                    self.needEncoderRebuild = true
                    self.lastEncoderTry = .distantPast
                    // 换了编码器：分段格式不一致，旧段作废
                    self.recorder.reset()
                    self.rearmPreRecord()
                }
            }
        }
    }

    private func rescueCaptureLocked() {
        if !session.isRunning { session.startRunning() }
        session.beginConfiguration()
        session.removeOutput(videoOutput)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        attachConnectionsLocked()
        Log.write("[看门狗] 数据输出已重挂 running=\(session.isRunning)")
    }

    // MARK: 语音
    private func startVoice() {
        stateLock.lock(); flagVoice = true; stateLock.unlock()
        voice.setWords(start: startWords, stop: stopWords)
        Log.write("[语音] 开关打开，开始监听")
        voice.begin()
    }

    private func stopVoice() {
        stateLock.lock(); flagVoice = false; stateLock.unlock()
        Log.write("[语音] 开关关闭")
        voice.end()
    }

    func setVoiceWords(start: [String], stop: [String]) {
        if !start.isEmpty { startWords = start }
        if !stop.isEmpty { stopWords = stop }
        voice.setWords(start: startWords, stop: stopWords)
        Log.write("[语音] 口令已更新 开始=\(startWords.joined(separator: "/"))")
    }

    // MARK: 手电筒
    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let next = !self.torchOn
            guard let device = self.cameraDevice, device.hasTorch,
                  device.isTorchModeSupported(next ? .on : .off) else {
                // 这颗镜头没有闪光灯（比如前置）：别把按钮点亮了骗人
                DispatchQueue.main.async { self.torchOn = false }
                return
            }
            try? device.lockForConfiguration()
            device.torchMode = next ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = next }
        }
    }

    // MARK: 计时 / 提示 / 省电
    /// 每秒刷新预录计时与剩余空间（供主界面显示）
    private func tickStatus() {
        if preRecordOn && !isRecording {
            let window = max(preRecordDelay.rawValue, 1)
            if preRecordSeconds < window { preRecordSeconds += 1 }
        } else if preRecordSeconds != 0 {
            preRecordSeconds = 0
        }
        storageTick += 1
        if storageTick >= 5 {
            storageTick = 0
            refreshStorage()
        }
    }

    private func refreshStorage() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 else { return }
        freeSpaceText = String(format: "%.1fGB", Double(bytes) / 1_000_000_000)
        let bitrate = Double(max(quality.size.width * quality.size.height * 3, 6_000_000)) / 8.0
        let seconds = Double(bytes) / bitrate
        recordableText = String(format: "%dh%02dm", Int(seconds) / 3600, (Int(seconds) % 3600) / 60)
    }

    private func startRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordSeconds += 1
            self.resetPowerTimer()
        }
    }

    private func stopRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
    }

    func message(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            // 以前出错会把调试日志糊在屏幕上一段时间，正式版里不做了
            Log.write("[提示] \(text)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.toast == text { self?.toast = nil }
            }
        }
    }

    func resetPowerTimer() {
        powerTimer?.invalidate()
        let seconds = powerSave.rawValue
        guard seconds > 0 else { return }
        powerTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dimmed = true }
        }
    }

    func wakeUp() {
        dimmed = false
        resetPowerTimer()
    }

    func openPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

// MARK: - 采集回调
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sample: CMSampleBuffer) {
        lastFrameAt = Date()
        receivedFrames &+= 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)

        if deliveredSize != size {
            deliveredSize = size
            encoder.invalidate()
            needEncoderRebuild = true
            recorder.reset()
            rearmPreRecord()
            if recording {
                Log.write("[采集] 录制中画面尺寸变化，停止本次录制")
                DispatchQueue.main.async { self.stopRecording() }
                return
            }
        }

        // 只在需要时编码（预录开启 / 录制中）
        let needEncode = preRecordOn || recording
        guard needEncode else { return }

        if needEncoderRebuild || !encoder.isReady {
            let now = Date()
            if needEncoderRebuild || now.timeIntervalSince(lastEncoderTry) > 1.0 {
                lastEncoderTry = now
                needEncoderRebuild = false
                encoder.configure(width: width, height: height,
                                  fps: frameRate.rawValue,
                                  bitrate: max(width * height * 3, 6_000_000))
            }
        }
        guard encoder.isReady else { return }

        let time = presentationTime(sample)
        var forceKey = false
        stateLock.lock()
        if flagForceKey { flagForceKey = false; forceKey = true }
        stateLock.unlock()
        if !forceKey {
            if !lastKeyTime.isValid || CMTimeGetSeconds(CMTimeSubtract(time, lastKeyTime)) >= 1.0 {
                forceKey = true
                lastKeyTime = time
            }
        }
        // 分段要在关键帧处切，段内关键帧密度由上面这条保证（约 1 秒一个）
        // 录制期烧录水印：把水印直接画进这一帧，落盘的分段本身就是成品，
        // 停止录制后只需无损拼接 → 保存几乎瞬间完成（不再重编码）。
        var frame = pixelBuffer
        burnLock.lock()
        let burning = burnOn
        let items = burnItems
        let data = burnData
        burnLock.unlock()
        if burning, let burned = burnFrame(pixelBuffer, size: size, items: items, data: data) {
            frame = burned
        }
        encoder.encode(frame, at: time, forceKey: forceKey)
    }

    /// 把水印合成到一帧上（走 Core Image / GPU，1080p 每帧几毫秒）。
    /// 目标 buffer 从池里取 —— 逐帧新分配会让内存一路涨，录久了直接被系统杀掉。
    private func burnFrame(_ source: CVPixelBuffer, size: CGSize,
                           items: Set<WatermarkItem>, data: WatermarkData) -> CVPixelBuffer? {
        if burnRenderer == nil || burnRendererSize != size {
            burnRenderer = WatermarkRenderer(renderSize: size)
            burnRendererSize = size
        }
        guard let renderer = burnRenderer,
              let overlay = renderer.overlay(for: Date(), data: data, items: items) else { return nil }

        // 目标用 BGRA：Core Image 对它支持最稳，编码器内部再转回 YUV
        if burnPool == nil || burnPoolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            burnPool = pool
            burnPoolSize = size
        }
        guard let pool = burnPool else { return nil }

        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target) == kCVReturnSuccess,
              let dest = target else { return nil }

        let base = CIImage(cvPixelBuffer: source)
        let bounds = CGRect(origin: .zero, size: size)
        burnContext.render(overlay.composited(over: base), to: dest, bounds: bounds,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return dest
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        if voiceActive { voice.feed(sample) }
        guard recording || preRecordOn else { return }
        recorder.appendAudio(sample)
    }
}
