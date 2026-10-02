import Foundation
import AVFoundation
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
    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .k4: return .hd4K3840x2160
        case .p1080: return .hd1920x1080
        case .p720: return .hd1280x720
        }
    }
    var size: (width: Int, height: Int) {
        switch self {
        case .k4: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
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
        if startWords.contains(where: { clean.contains($0) }) {
            if now.timeIntervalSince(lastStart) > 2.5 {
                lastStart = now
                Log.write("[语音] 命中开始口令")
                DispatchQueue.main.async { [weak self] in self?.onStart?() }
            }
        } else if stopWords.contains(where: { clean.contains($0) }) {
            if now.timeIntervalSince(lastStop) > 2.5 {
                lastStop = now
                Log.write("[语音] 命中停止口令")
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
            }
        }
    }

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
    @Published var preRecordOn = false { didSet { if oldValue != preRecordOn { syncPreRecord() } } }
    @Published var preRecordDelay: PreRecordDelay = .s15 { didSet { if oldValue != preRecordDelay { syncPreRecord() } } }
    @Published var powerSave: PowerSaveDelay = .never { didSet { resetPowerTimer() } }
    @Published var showGrid = true
    @Published var showLevel = true
    @Published var beepOn = true
    @Published var debugInfo = false
    /// 语音控制默认开启：装好即可直接说「开始录像」「停止录像」
    @Published var voiceOn = true { didSet { if oldValue != voiceOn { voiceOn ? startVoice() : stopVoice() } } }
    @Published var startWords = ["开始录像", "开启录像", "开始录制", "开始拍摄"]
    @Published var stopWords = ["停止录像", "结束录像", "关闭录像", "停止录制", "保存"]

    let session = AVCaptureSession()
    let level = LevelSensor()

    private let sessionQueue = DispatchQueue(label: "com.sportcam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let encoder = H264Encoder()
    private let recorder = SegmentRecorder()
    private let sound = SoundPlayer()
    private let voice = VoiceControl()
    private let power = PowerMonitor()

    private var cameraDevice: AVCaptureDevice?
    private var cameraInput: AVCaptureDeviceInput?
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

    // 跨线程状态
    private let stateLock = NSLock()
    private var flagRecording = false
    private var flagVoice = false
    private var flagForceKey = false

    private var recording: Bool { stateLock.lock(); defer { stateLock.unlock() }; return flagRecording }
    private var voiceActive: Bool { stateLock.lock(); defer { stateLock.unlock() }; return flagVoice }

    private var recordTimer: Timer?
    private var powerTimer: Timer?
    private var uiTimer: Timer?

    // MARK: 启动
    func launch() {
        configureAudioSession()
        level.start()
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        recorder.onSegmentsChanged = { [weak self] total in
            self?.segmentCount = total
        }

        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.runWatchdogs()
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
            try audioSession.setCategory(.playAndRecord, mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audioSession.setActive(true)
            Log.write("[音频] 会话就绪")
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

        if let device = camera(for: fieldOfView),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            cameraDevice = device
            cameraInput = input
        }
        if let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(input) {
            session.addInput(input)
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
        session.startRunning()
        attachConnectionsLocked()
        Log.write("[会话] 启动 \(quality.rawValue) \(frameRate.rawValue)fps \(fieldOfView.rawValue)")
    }

    private func camera(for fov: FieldOfView) -> AVCaptureDevice? {
        AVCaptureDevice.default(fov.lens, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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
        let fps = Double(frameRate.rawValue)
        let target = quality.size
        do {
            try device.lockForConfiguration()
            if let matched = device.formats.first(where: { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard Int(dims.width) >= target.width, Int(dims.height) >= target.height else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            }) {
                device.activeFormat = matched
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Log.write("[会话] 帧率失败 \(error.localizedDescription)")
        }
    }

    func attachConnections() { sessionQueue.async { [weak self] in self?.attachConnectionsLocked() } }

    func switchLens() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.recording {
                Log.write("[镜头] 录制中不可切换")
                return
            }
            guard let device = self.camera(for: self.fieldOfView),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            if let old = self.cameraInput { self.session.removeInput(old) }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.cameraInput = input
                self.cameraDevice = device
            } else if let old = self.cameraInput {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()
            self.attachConnectionsLocked()
            self.applyFrameRateLocked()
            self.encoder.invalidate()
            self.needEncoderRebuild = true
            // 换了镜头：分段格式已不一致，旧段全部作废
            self.recorder.reset()
            self.rearmPreRecord()
            DispatchQueue.main.async { self.zoom = 1.0 }
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

    func applyZoom() { sessionQueue.async { [weak self] in self?.applyZoomLocked() } }

    private func applyZoomLocked() {
        guard let device = cameraDevice else { return }
        do {
            try device.lockForConfiguration()
            let maxFactor = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(zoom, maxFactor))
            device.unlockForConfiguration()
        } catch {
            Log.write("[变焦] 失败 \(error.localizedDescription)")
        }
    }

    /// 0.5x / 1x / 2x 三档
    func selectZoomChip(_ chip: String) {
        switch chip {
        case "0.5x":
            if fieldOfView != .ultraWide { fieldOfView = .ultraWide }
            zoom = 1.0
        case "1x":
            if fieldOfView != .wide { fieldOfView = .wide }
            zoom = 1.0
        default:
            if fieldOfView != .wide { fieldOfView = .wide }
            zoom = 2.0
        }
    }

    // MARK: 预录
    private func syncPreRecord() {
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
            SegmentMerger.merge(clip, to: output) { ok in
                for seg in clip.segments { try? FileManager.default.removeItem(at: seg.url) }
                if let audio = clip.audio { try? FileManager.default.removeItem(at: audio.url) }
                guard ok else {
                    DispatchQueue.main.async {
                        self.isBusy = false
                        self.message("合并失败，请看日志")
                    }
                    return
                }
                PhotoSaver.save(output) { saved in
                    try? FileManager.default.removeItem(at: output)
                    DispatchQueue.main.async {
                        self.isBusy = false
                        self.message(saved ? "已保存到相册 · 共\(clip.segments.count)段" : "保存相册失败（检查相册权限）")
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
        return folder.appendingPathComponent("SportCam_\(formatter.string(from: Date()))_\(clipIndex).mp4")
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
            if let device = self.cameraDevice, device.hasTorch,
               device.isTorchModeSupported(next ? .on : .off) {
                try? device.lockForConfiguration()
                device.torchMode = next ? .on : .off
                device.unlockForConfiguration()
            }
            DispatchQueue.main.async { self.torchOn = next }
        }
    }

    // MARK: 计时 / 提示 / 省电
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
            if text.contains("失败") || text.contains("没有录到") {
                self.showLog = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.showLog = false }
            }
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
        encoder.encode(pixelBuffer, at: time, forceKey: forceKey)
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        if voiceActive { voice.feed(sample) }
        guard recording || preRecordOn else { return }
        recorder.appendAudio(sample)
    }
}
