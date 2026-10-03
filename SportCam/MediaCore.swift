import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AudioToolbox

// ============================================================
//  媒体核心：日志 / sampleBuffer 工具 / H.264 编码器 / 提示音
//           分段落盘录制器（行车记录仪架构） / 分段合并
//
//  架构说明：
//  预录不再把帧囤在内存里（那样会把系统的缓冲池耗干 → 系统不报错、直接停帧，
//  症状就是"画面卡在某一秒不动"）。改为：一边实时编码，一边以约 2 秒为单位
//  滚动落盘成小分段文件，只保留最近若干段。内存里永远只有"正在写的那一帧"。
//  按下录制 = 锁定当前保留段 + 继续录；停止 = 把这些段无损合并成一个文件存相册。
// ============================================================

// MARK: - 调试日志（屏幕可见，出问题自动弹出）
enum LogBuffer {
    private static let lock = NSLock()
    private static var lines: [String] = []

    static func add(_ text: String) {
        lock.lock()
        lines.append(text)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        lock.unlock()
    }

    static func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

enum Log {
    static func write(_ text: String) { LogBuffer.add(text) }
}

// MARK: - CMSampleBuffer 工具
extension CMSampleBuffer {
    /// 关键帧（I 帧）。无附加信息时按关键帧处理。
    var isSync: Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = array.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(self),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let frames = CMSampleBufferGetNumSamples(self)
        guard frames > 0,
              let audioFormat = AVAudioFormat(streamDescription: description),
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self,
                                                                  at: 0,
                                                                  frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

func presentationTime(_ sample: CMSampleBuffer) -> CMTime {
    CMSampleBufferGetPresentationTimeStamp(sample)
}

// MARK: - H.264 硬编码器
final class H264Encoder {
    private var session: VTCompressionSession?
    private var configuredSize = CGSize.zero
    private let lock = NSLock()
    var onSample: ((CMSampleBuffer) -> Void)?

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        let evenWidth = width % 2 == 0 ? width : width + 1
        let evenHeight = height % 2 == 0 ? height : height + 1
        if let current = session, configuredSize == CGSize(width: evenWidth, height: evenHeight) { return }
        if let old = session {
            session = nil
            VTCompressionSessionInvalidate(old)
        }

        var created: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                     width: Int32(evenWidth),
                                                     height: Int32(evenHeight),
                                                     codecType: kCMVideoCodecType_H264,
                                                     encoderSpecification: nil,
                                                     imageBufferAttributes: nil,
                                                     compressedDataAllocator: nil,
                                                     outputCallback: { refcon, _, status, _, sample in
                                                         guard status == noErr, let sample = sample, let refcon = refcon else { return }
                                                         Unmanaged<H264Encoder>.fromOpaque(refcon)
                                                             .takeUnretainedValue()
                                                             .onSample?(sample)
                                                     },
                                                     refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                     compressionSessionOut: &created)
        guard createStatus == noErr, let encoder = created else {
            Log.write("[编码] 创建失败 st=\(createStatus) \(evenWidth)x\(evenHeight)")
            return
        }

        set(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(encoder, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // 关键帧间隔控制在一秒内：分段要在关键帧处切，合并才能无损
        set(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(fps, 15)))
        set(encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        VTCompressionSessionPrepareToEncodeFrames(encoder)

        session = encoder
        configuredSize = CGSize(width: evenWidth, height: evenHeight)
        Log.write("[编码] 就绪 \(evenWidth)x\(evenHeight) \(fps)fps")
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr { Log.write("[编码] 参数失败 \(key) st=\(status)") }
    }

    /// forceKey：请求本帧输出为关键帧（分段边界 / 录制起点要用）
    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, forceKey: Bool) {
        lock.lock()
        let current = session
        lock.unlock()
        guard let session = current else { return }

        var properties: [String: Any] = [:]
        if forceKey { properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true }
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: time,
                                        duration: .invalid,
                                        frameProperties: properties.isEmpty ? nil : (properties as CFDictionary),
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let current = session {
            session = nil
            VTCompressionSessionInvalidate(current)
        }
        configuredSize = .zero
    }
}

// MARK: - 提示音
/// 用苹果自带的系统声音，和 iPhone 自带相机录像时的提示音一致：
/// 1113 = begin_record.caf（开始录像）、1114 = end_record.caf（结束录像）。
/// 走 AudioServicesPlaySystemSound（不是自己合成波形），是系统音效，听感更自然。
/// 注：AVCaptureEventSound 那套是 iOS 26 才有的，本 App 部署目标 iOS 14，用不了。
final class SoundPlayer {
    private static let startID: SystemSoundID = 1113
    private static let stopID: SystemSoundID = 1114

    /// 保留预热接口（引擎在 launch 里会调用）；系统音效无需预热，直接播放。
    func prepare() {}

    func playStart() { AudioServicesPlaySystemSound(Self.startID) }
    func playStop() { AudioServicesPlaySystemSound(Self.stopID) }
}

// MARK: - 分段落盘录制器
///
/// 预录的"缓冲"落在磁盘上：边编码边写小分段，只保留最近 N 秒对应的若干段。
/// 内存里不囤任何帧 → 不会耗尽系统缓冲池，也就不会出现"画面突然卡住不再出帧"。
///
/// 音频不走分段：整段会话只开一个音频编码器，写成一个连续音轨文件。
/// 每个分段各自起一次 AAC 编码器，会在每段首尾留下编码器 priming/padding，
/// 拼起来就是每隔约 2 秒一次的"滋滋"声 —— 单条连续音轨从根上避免这件事。
final class SegmentRecorder {

    private struct Segment {
        let url: URL
        let seconds: Double
        /// 本段第一个视频帧的时间戳（用于按真实先后排序）
        let start: CMTime
        /// 本段开写时的真实时间（水印要用它换算每一帧的墙上时间）
        let createdAt: Date
    }

    private let queue = DispatchQueue(label: "com.sportcam.segmenter")
    private let folder: URL

    // 运行状态（只在 queue 上访问）
    private var armed = false            // 是否在滚动写盘（预录中）
    private var clipMode = false         // 是否处于"正式录制"（此时不删段）
    private var keepSeconds: Double = 15
    private var segmentSeconds: Double = 2.0

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var currentURL: URL?
    private var segmentStart = CMTime.invalid
    private var segmentStartDate = Date()
    private var lastVideoPTS = CMTime.invalid

    // 连续音轨：整段会话只有一个音频编码器，中途不重启
    private var trackWriter: AVAssetWriter?
    private var trackInput: AVAssetWriterInput?
    private var trackURL: URL?
    private var trackAnchor = CMTime.invalid       // 音轨第一帧在采集时间轴上的位置
    private var lastTrackPTS = CMTime.invalid
    private var finishedTrack: RecordedAudio?      // 已收尾、待交给合并器
    private var trackUnavailable = false           // 音轨起不来时不再反复重试

    private var rolling: [Segment] = []      // 可被淘汰的滚动段
    private var clip: [Segment] = []         // 正式录制期间累计的段

    private var pendingFinishes = 0
    private var endCompletion: ((RecordedClip) -> Void)?
    private var sequence = 0
    private var lastRejectLog = Date.distantPast
    private var badSegments = 0

    /// 分段数量变化通知（主线程回调，供界面显示）
    var onSegmentsChanged: ((Int) -> Void)?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: 对外接口
    /// 进入预录：开始滚动写盘，保留最近 preRecordSeconds 秒
    func arm(preRecordSeconds: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.keepSeconds = max(preRecordSeconds, 1)
            if !self.armed {
                self.armed = true
                self.trackUnavailable = false
                Log.write("[预录] 开始滚动写盘 保留\(Int(preRecordSeconds))秒")
            }
            self.trimRolling()
            self.notifySegments()
        }
    }

    /// 退出预录：停止写盘并清掉滚动段
    func disarm() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.clipMode else { return }
            self.armed = false
            self.clearRolling()
            self.finishCurrentSegment(intoClip: false, discard: true)
            self.discardTrack()
            Log.write("[预录] 已停止")
        }
    }

    /// 按下录制：把当前保留的滚动段锁定为预录部分，并从此不再淘汰
    func beginClip() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.clipMode = true
            self.clip.append(contentsOf: self.rolling)
            let carried = self.rolling.count
            self.rolling.removeAll()
            self.notifySegments()
            Log.write("[录制] 锁定预录段 \(carried) 个")
        }
    }

    /// 停止录制：收尾视频段与连续音轨，返回本次录制的全部素材
    func endClip(completion: @escaping (RecordedClip) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.armed = false
            self.endCompletion = completion
            self.finishedTrack = nil
            if self.writer != nil {
                self.finishCurrentSegment(intoClip: true)
            }
            self.finishTrack()
            self.completeEndIfReady()
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in self?.handleVideo(sample) }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in self?.handleAudio(sample) }
    }

    /// 丢弃（异常时复位用）
    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.armed = false
            self.clipMode = false
            self.clearRolling()
            let leftovers = self.clip
            self.clip.removeAll()
            for segment in leftovers { try? FileManager.default.removeItem(at: segment.url) }
            self.finishCurrentSegment(intoClip: false, discard: true)
            self.discardTrack()
            self.notifySegments()
        }
    }

    // MARK: 内部
    private func handleVideo(_ sample: CMSampleBuffer) {
        guard armed else { return }
        let time = presentationTime(sample)
        let isKey = sample.isSync

        // 只有预录的"滚动缓存"需要切段（方便淘汰旧段）。
        // 正式录制期间不再切段 —— 结束时只剩一个长文件，
        // 合并时不用再打开几十上百个小分段，保存明显更快。
        let needNew = (writer == nil) || (!clipMode && isKey && shouldRotate(at: time))
        if needNew {
            guard isKey else { return }
            finishCurrentSegment(intoClip: clipMode)
            guard startSegment(with: sample, at: time) else { return }
        }

        guard let input = videoInput, let w = writer, w.status == .writing else { return }
        if lastVideoPTS.isValid && CMTimeCompare(time, lastVideoPTS) <= 0 { return }
        // 实时写入：未就绪就丢这一帧（阻塞会拖垮采集线程）
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sample) {
            lastVideoPTS = time
        } else if Date().timeIntervalSince(lastRejectLog) > 5 {
            lastRejectLog = Date()
            Log.write("[分段] 追加视频被拒 status=\(w.status.rawValue) \(w.error?.localizedDescription ?? "")")
        }
    }

    private func shouldRotate(at time: CMTime) -> Bool {
        guard segmentStart.isValid else { return false }
        return CMTimeGetSeconds(CMTimeSubtract(time, segmentStart)) >= segmentSeconds
    }

    /// 音频只写进"连续音轨"，与视频分段无关：段怎么切都不影响音轨，永远不会出现接缝。
    private func handleAudio(_ sample: CMSampleBuffer) {
        guard armed else { return }
        if trackWriter == nil && !trackUnavailable {
            if !startTrack(with: sample) { trackUnavailable = true }
        }
        guard let w = trackWriter, let input = trackInput, w.status == .writing else { return }
        let time = presentationTime(sample)
        if lastTrackPTS.isValid && CMTimeCompare(time, lastTrackPTS) <= 0 { return }
        if appendAudioWaiting(sample, to: input) {
            if !trackAnchor.isValid { trackAnchor = time }
            lastTrackPTS = time
        }
    }

    /// 音频宁可等一小会儿也不能丢帧：丢一帧就是波形上一个断点，听感就是"滋"一声。
    /// 这里跑在录音器自己的串行队列上，短暂等待不会拖住采集线程。
    private func appendAudioWaiting(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 25 {   // 最多等 50ms
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
        }
        return input.append(sample)
    }

    /// 用当前音频格式新开一条连续音轨（整个预录/录制期间只有这一条）
    @discardableResult
    private func startTrack(with sample: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
        sequence += 1
        let url = folder.appendingPathComponent("aud_\(Int(Date().timeIntervalSince1970))_\(sequence).m4a")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .m4a) else {
            Log.write("[音轨] 创建写入器失败")
            return false
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
            AVSampleRateKey: asbd.mSampleRate,
            AVEncoderBitRateKey: 128000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else {
            Log.write("[音轨] 无法添加音轨")
            return false
        }
        w.add(input)
        guard w.startWriting() else {
            Log.write("[音轨] startWriting 失败 \(w.error?.localizedDescription ?? "")")
            return false
        }
        w.startSession(atSourceTime: presentationTime(sample))
        trackWriter = w
        trackInput = input
        trackURL = url
        trackAnchor = .invalid
        lastTrackPTS = .invalid
        Log.write("[音轨] 连续音轨开始 \(Int(asbd.mSampleRate))Hz/\(Int(asbd.mChannelsPerFrame))声道")
        return true
    }

    /// 收尾连续音轨：finalize 后交给合并器，随后为重开的预录留空（下次音频样本会自动新建）
    private func finishTrack() {
        guard let w = trackWriter, let url = trackURL else { return }
        let anchor = trackAnchor
        trackWriter = nil
        trackInput = nil
        trackURL = nil
        trackAnchor = .invalid
        lastTrackPTS = .invalid

        guard anchor.isValid else {
            // 一次都没写进去过：没有可用的音轨
            w.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            Log.write("[音轨] 空音轨，已丢弃")
            return
        }

        pendingFinishes += 1
        w.finishWriting { [weak self] in
            guard let self = self else { return }
            let ok = w.status == .completed
            self.queue.async {
                if ok {
                    self.finishedTrack = RecordedAudio(url: url, anchor: anchor)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    Log.write("[音轨] 收尾失败 \(w.error?.localizedDescription ?? "")")
                }
                self.pendingFinishes -= 1
                self.completeEndIfReady()
            }
        }
    }

    /// 直接丢弃当前连续音轨（退出预录 / 复位）
    private func discardTrack() {
        guard let w = trackWriter else { return }
        let url = trackURL
        trackWriter = nil
        trackInput = nil
        trackURL = nil
        trackAnchor = .invalid
        lastTrackPTS = .invalid
        w.cancelWriting()
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }

    private func startSegment(with sample: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        sequence += 1
        let url = folder.appendingPathComponent("seg_\(Int(Date().timeIntervalSince1970))_\(sequence).mp4")
        do {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

            // 分段文件里只有视频；音频统一走连续音轨（见 startTrack）
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            video.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(video) else { return false }
            assetWriter.add(video)

            guard assetWriter.startWriting() else {
                Log.write("[分段] startWriting 失败 \(assetWriter.error?.localizedDescription ?? "")")
                return false
            }
            assetWriter.startSession(atSourceTime: time)

            writer = assetWriter
            videoInput = video
            currentURL = url
            segmentStart = time
            segmentStartDate = Date()
            // 注意：这里不能把 lastVideoPTS 设成 time，
            // 否则下面"时间戳必须递增"的判断会把本段的第一个关键帧直接丢掉 ——
            // 段首没有关键帧，合并时就会读不出视频格式。
            lastVideoPTS = .invalid
            return true
        } catch {
            Log.write("[分段] 创建失败 \(error.localizedDescription)")
            return false
        }
    }

    private func finishCurrentSegment(intoClip: Bool, discard: Bool = false) {
        guard let assetWriter = writer, let url = currentURL else { return }
        let segmentBegin = segmentStart
        let segmentBeginDate = segmentStartDate
        let rawSeconds = (segmentStart.isValid && lastVideoPTS.isValid)
            ? max(CMTimeGetSeconds(CMTimeSubtract(lastVideoPTS, segmentStart)), 0)
            : 0
        let seconds = rawSeconds.isFinite ? rawSeconds : 0

        videoInput?.markAsFinished()

        writer = nil
        videoInput = nil
        currentURL = nil
        segmentStart = .invalid
        lastVideoPTS = .invalid

        pendingFinishes += 1
        let segment = Segment(url: url, seconds: seconds, start: segmentBegin, createdAt: segmentBeginDate)
        let useClip = intoClip
        assetWriter.finishWriting { [weak self] in
            guard let self = self else { return }
            let ok = assetWriter.status == .completed
            let reason = assetWriter.error?.localizedDescription ?? ""
            self.queue.async {
                if !ok {
                    // 写坏的段绝不能进合并列表，否则整段合并都会失败
                    self.badSegments += 1
                    Log.write("[分段] 收尾失败(已丢弃) status=\(assetWriter.status.rawValue) \(reason)")
                    try? FileManager.default.removeItem(at: segment.url)
                } else if discard {
                    try? FileManager.default.removeItem(at: segment.url)
                } else if useClip {
                    self.clip.append(segment)
                } else {
                    self.rolling.append(segment)
                    self.trimRolling()
                }
                self.pendingFinishes -= 1
                self.notifySegments()
                self.completeEndIfReady()
            }
        }
    }

    private func notifySegments() {
        let total = rolling.count + clip.count
        DispatchQueue.main.async { [weak self] in self?.onSegmentsChanged?(total) }
    }

    private func trimRolling() {
        var total = rolling.reduce(0) { $0 + $1.seconds }
        while rolling.count > 1 && total > keepSeconds {
            let removed = rolling.removeFirst()
            total -= removed.seconds
            try? FileManager.default.removeItem(at: removed.url)
        }
    }

    private func clearRolling() {
        for segment in rolling { try? FileManager.default.removeItem(at: segment.url) }
        rolling.removeAll()
    }

    private func completeEndIfReady() {
        guard let completion = endCompletion, pendingFinishes == 0 else { return }
        endCompletion = nil
        let recorded = clip.map {
            RecordedSegment(url: $0.url, start: $0.start, seconds: $0.seconds, createdAt: $0.createdAt)
        }
        clip.removeAll()
        clipMode = false
        let audio = finishedTrack
        finishedTrack = nil
        notifySegments()
        Log.write("[录制] 收尾完成 共\(recorded.count)段 音轨=\(audio != nil ? "有" : "无")")
        DispatchQueue.main.async { completion(RecordedClip(segments: recorded, audio: audio)) }
    }
}

// MARK: - 分段合并
/// 一段已落盘的视频分段：文件路径 + 它在"采集时间轴"上的起点与时长。
struct RecordedSegment {
    let url: URL
    let start: CMTime
    let seconds: Double
    /// 本段开写时的真实时间
    let createdAt: Date
}

/// 一条连续音轨文件（整个预录/录制期间只有这一个音频编码器）。
struct RecordedAudio {
    let url: URL
    /// 音轨第一帧在采集时间轴上的位置
    let anchor: CMTime
}

/// 一次录制的全部素材：视频分段 + 一条连续音轨。
struct RecordedClip {
    let segments: [RecordedSegment]
    let audio: RecordedAudio?
}

/// 把一次录制的素材合成一个完整文件。
///
/// 做法对齐参考 App（钓鱼相机 jj.dyxj）的源码写法：
///   1) AVMutableComposition 按时间先后把每个分段 insertTimeRange 首尾相接；
///   2) 音频是一条连续音轨，按本次录制的时间窗整段插入一次；
///   3) AVAssetExportSession(presetName: Passthrough) 直接导出 —— 不重新编码，
///      画质音质都没有二次损失。
///   脱壳出来的二进制里用的正是这一组 API：
///   addMutableTrackWithMediaType: / insertTimeRange:ofTrack:atTime:error: /
///   initWithAsset:presetName: / setOutputFileType: / setShouldOptimizeForNetworkUse: /
///   exportAsynchronouslyWithCompletionHandler:
enum SegmentMerger {
    /// - Parameter watermark: 非空时把水印（时间/地点/描述/海拔/天气…）烧进画面（必须重编码）；
    ///                        nil 时保持原样的无损 Passthrough。
    static func merge(_ clip: RecordedClip, to output: URL,
                      watermark: WatermarkConfig? = nil,
                      completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = compose(clip, to: output, watermark: watermark)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 合成：分段首尾相接 + 连续音轨整段插入，然后导出。
    private static func compose(_ clip: RecordedClip, to output: URL,
                                watermark: WatermarkConfig?) -> Bool {
        let valid = clip.segments
            .filter { FileManager.default.fileExists(atPath: $0.url.path) && $0.start.isValid }
            .sorted { CMTimeCompare($0.start, $1.start) < 0 }
        guard !valid.isEmpty else {
            Log.write("[合并] 没有可用分段")
            return false
        }

        // origin = 本次录制的起点，clipEnd = 结束点；输出时间轴从 0 开始
        let origin = valid[0].start
        var clipEnd = origin
        for seg in valid {
            let end = CMTimeAdd(seg.start, CMTime(seconds: seg.seconds, preferredTimescale: 600))
            if CMTimeCompare(end, clipEnd) > 0 { clipEnd = end }
        }

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var inserted = 0
        for seg in valid {
            let asset = AVURLAsset(url: seg.url)
            guard let track = asset.tracks(withMediaType: .video).first else { continue }
            let range = track.timeRange
            guard range.duration.isValid, CMTimeCompare(range.duration, .zero) > 0 else { continue }
            do {
                try videoTrack?.insertTimeRange(range, of: track, at: cursor)
                cursor = CMTimeAdd(cursor, range.duration)
                inserted += 1
            } catch {
                Log.write("[合并] 分段插入失败 \(seg.url.lastPathComponent)")
            }
        }
        guard inserted > 0 else {
            Log.write("[合并] 没有可用的视频轨")
            return false
        }

        // 音频：整条连续音轨，把 [origin, clipEnd] 这一段插到开头
        if let audio = clip.audio, FileManager.default.fileExists(atPath: audio.url.path),
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            let asset = AVURLAsset(url: audio.url)
            if let track = asset.tracks(withMediaType: .audio).first {
                let base = track.timeRange.start
                // 采集时间轴 → 音轨文件时间轴：origin 对应 anchor
                let srcStart = CMTimeMaximum(CMTimeAdd(base, CMTimeSubtract(origin, audio.anchor)), base)
                let srcDuration = CMTimeSubtract(clipEnd, origin)
                if CMTimeCompare(srcDuration, .zero) > 0 {
                    do {
                        try audioTrack.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDuration),
                                                       of: track, at: .zero)
                    } catch {
                        Log.write("[合并] 音轨插入失败 \(error.localizedDescription)")
                    }
                }
            }
        }

        let began = Date()
        let videoComposition = watermark.flatMap { WatermarkComposition.make(asset: composition, config: $0) }
        var ok: Bool
        if let videoComposition = videoComposition {
            // 叠了水印没法走 Passthrough，只能重编码一次。
            // 重编码先用自建管线（AVAssetReader + AVAssetWriter 硬件编码，不经
            // AVAssetExportSession 的调度），明显更快；万一失败再退回老路，保证存得下来。
            ok = fastRecode(composition, videoComposition: videoComposition, to: output)
            if !ok {
                Log.write("[合并] 自建管线失败，退回 AVAssetExportSession")
                ok = export(composition, videoComposition: videoComposition, to: output,
                            preset: recodePreset(for: composition))
            }
        } else {
            ok = export(composition, videoComposition: nil, to: output,
                        preset: AVAssetExportPresetPassthrough)
            if !ok {
                // 分段格式万一不一致，Passthrough 会拒；退回最高画质重编码一次
                Log.write("[合并] 无损导出失败，改用 HighestQuality 重试")
                ok = export(composition, videoComposition: nil, to: output,
                            preset: AVAssetExportPresetHighestQuality)
            }
        }
        let usedMS = Int(Date().timeIntervalSince(began) * 1000)
        if ok {
            let seconds = String(format: "%.1f", CMTimeGetSeconds(composition.duration))
            let mark = watermark == nil ? "无水印" : "已加水印"
            Log.write("[合并] 成功 \(inserted)段 \(mark) 时长\(seconds)秒 用时\(usedMS)ms")
        }
        return ok
    }

    /// 烧水印时的重编码：自己拉 reader + writer（硬件 H.264），不经过 AVAssetExportSession。
    /// 好处是编码器不排队、立刻全速跑，保存比原来快；音轨直接搬压缩样本，不二次编码。
    /// 失败返回 false，由调用方退回 AVAssetExportSession。
    private static func fastRecode(_ asset: AVAsset, videoComposition: AVVideoComposition, to output: URL) -> Bool {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return false }
        let audioTrack = asset.tracks(withMediaType: .audio).first
        let renderSize = videoComposition.renderSize
        guard renderSize.width > 8, renderSize.height > 8 else { return false }

        try? FileManager.default.removeItem(at: output)
        guard let reader = try? AVAssetReader(asset: asset) else { return false }

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = videoComposition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { return false }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            // outputSettings 传 nil = 不解码，直接搬原始压缩样本（AAC 原样进新文件）
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mov) else { return false }

        // 帧率跟着合成走；渲染尺寸就是输出尺寸，不再让预设二次缩放
        let fps = (videoComposition.frameDuration.isValid && videoComposition.frameDuration.seconds > 0)
            ? 1.0 / videoComposition.frameDuration.seconds : 30.0
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width.rounded()),
            AVVideoHeightKey: Int(renderSize.height.rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(Int(renderSize.width * renderSize.height * 3), 6_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())
            ]
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard writer.canAdd(videoIn) else { return false }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if let audioOut = audioOut, let format = audioTrack?.formatDescriptions.first {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: nil,
                                           sourceFormatHint: format as! CMFormatDescription)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        guard writer.startWriting(), reader.startReading() else {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: output)
            return false
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.sportcam.recode")
        let group = DispatchGroup()
        let stateLock = NSLock()
        var healthy = true

        group.enter()
        videoIn.requestMediaDataWhenReady(on: queue) {
            while videoIn.isReadyForMoreMediaData {
                guard let sample = videoOut.copyNextSampleBuffer() else {
                    videoIn.markAsFinished()
                    group.leave()
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if let buffer = CMSampleBufferGetImageBuffer(sample),
                   adaptor.append(buffer, withPresentationTime: time) {
                    continue
                }
                stateLock.lock(); healthy = false; stateLock.unlock()
                videoIn.markAsFinished()
                group.leave()
                return
            }
        }

        if let audioIn = audioIn, let audioOut = audioOut {
            group.enter()
            audioIn.requestMediaDataWhenReady(on: queue) {
                while audioIn.isReadyForMoreMediaData {
                    guard let sample = audioOut.copyNextSampleBuffer() else {
                        audioIn.markAsFinished()
                        group.leave()
                        return
                    }
                    if audioIn.append(sample) { continue }
                    stateLock.lock(); healthy = false; stateLock.unlock()
                    audioIn.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        let done = DispatchSemaphore(value: 0)
        var success = false
        group.notify(queue: queue) {
            stateLock.lock(); let healthyNow = healthy; stateLock.unlock()
            if !healthyNow || reader.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
            } else {
                let wait = DispatchSemaphore(value: 0)
                writer.finishWriting { wait.signal() }
                wait.wait()
                success = writer.status == .completed
                if !success { try? FileManager.default.removeItem(at: output) }
            }
            done.signal()
        }
        // 正常几秒到几十秒就完事；给足 10 分钟，真卡住了也不能把保存流程吊死
        if done.wait(timeout: .now() + 600) == .timedOut {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            Log.write("[合并] 自建管线超时，退回 AVAssetExportSession")
            return false
        }
        reader.cancelReading()
        return success
    }

    /// 重编码时按源分辨率挑预设。
    /// HighestQuality 会把 720p 往上补，白白多花时间、画质也没收益。
    private static func recodePreset(for asset: AVAsset) -> String {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return AVAssetExportPresetHighestQuality
        }
        let size = track.naturalSize
        let shortSide = min(size.width, size.height)
        if shortSide <= 600 { return AVAssetExportPreset640x480 }
        if shortSide <= 800 { return AVAssetExportPreset1280x720 }
        if shortSide <= 1200 { return AVAssetExportPreset1920x1080 }
        if shortSide <= 2200 { return AVAssetExportPreset3840x2160 }
        return AVAssetExportPresetHighestQuality
    }

    /// 导出。参考 App 用的就是 .mov。
    private static func export(_ composition: AVAsset, videoComposition: AVVideoComposition?,
                               to output: URL, preset: String) -> Bool {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            Log.write("[合并] 无法创建导出会话 preset=\(preset)")
            return false
        }
        try? FileManager.default.removeItem(at: output)
        exporter.outputURL = output
        exporter.outputFileType = .mov
        // 本地保存不需要 fast-start，开了反而要多写一遍文件
        exporter.shouldOptimizeForNetworkUse = false
        exporter.videoComposition = videoComposition
        let done = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { done.signal() }
        done.wait()
        if exporter.status == .completed { return true }
        Log.write("[合并] 导出失败 preset=\(preset) status=\(exporter.status.rawValue) \(exporter.error?.localizedDescription ?? "")")
        return false
    }
}
