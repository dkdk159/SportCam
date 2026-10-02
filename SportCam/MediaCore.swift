import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

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
final class SoundPlayer {
    private let queue = DispatchQueue(label: "com.sportcam.sound")
    private var player: AVAudioPlayer?
    private lazy var startTone = Self.makeTone([(0.00, 0.07), (0.12, 0.07), (0.24, 0.16)])
    private lazy var stopTone = Self.makeTone([(0.00, 0.20)])

    func playStart() { play(startTone) }
    func playStop() { play(stopTone) }

    private func play(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self, let audio = try? AVAudioPlayer(data: data) else { return }
            audio.volume = 1.0
            audio.prepareToPlay()
            audio.play()
            self.player = audio
        }
    }

    private static func makeTone(_ pattern: [(Double, Double)]) -> Data {
        let sampleRate = 44100
        let frequency = 880.0
        let amplitude = 28000.0
        let total = Int(0.7 * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: total)

        for (startAt, duration) in pattern {
            let start = Int(startAt * Double(sampleRate))
            let length = Int(duration * Double(sampleRate))
            for index in 0..<length {
                let position = start + index
                if position >= total { break }
                let t = Double(index) / Double(sampleRate)
                samples[position] = Int16(sin(2 * Double.pi * frequency * t) * amplitude * exp(-t * 18.0))
            }
        }

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + total * 2); data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        var subchunk = UInt32(16); data.append(Data(bytes: &subchunk, count: 4))
        var format = UInt16(1); data.append(Data(bytes: &format, count: 2))
        var channels = UInt16(1); data.append(Data(bytes: &channels, count: 2))
        var rate = UInt32(sampleRate); data.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(sampleRate * 2); data.append(Data(bytes: &byteRate, count: 4))
        var align = UInt16(2); data.append(Data(bytes: &align, count: 2))
        var bits = UInt16(16); data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(total * 2); data.append(Data(bytes: &dataSize, count: 4))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
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

        let needNew = (writer == nil) || (isKey && shouldRotate(at: time))
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
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sample) {
            if !trackAnchor.isValid { trackAnchor = time }
            lastTrackPTS = time
        }
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
        let segment = Segment(url: url, seconds: seconds, start: segmentBegin)
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
        let recorded = clip.map { RecordedSegment(url: $0.url, start: $0.start, seconds: $0.seconds) }
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
/// 无缝的关键：
/// 1) 视频分段都出自同一条采集时间轴，每段记录了自己的起点。
///    合并时统一映射回采集时间轴、再整体平移一次 —— 不做"逐段重新对齐"，
///    段与段之间自然零间隙、零重叠。
/// 2) 音频本来就是**一整条连续音轨**（录音期间只有一个 AAC 编码器、中途不重启），
///    合并时按时间范围裁一段直接搬进容器即可 —— 不存在任何接缝，
///    也就不会有"每 2 秒一次的滋滋声"。
enum SegmentMerger {
    static func merge(_ clip: RecordedClip, to output: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = concat(clip, to: output)
            if !ok {
                Log.write("[合并] 逐帧合并未成功，改用拼接方式重试")
                ok = fallback(clip, to: output)
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 已按输出时间轴裁剪好的音轨：格式 + (样本, 输出起点) 列表
    private struct PreparedAudio {
        let format: CMFormatDescription?
        let samples: [(sample: CMSampleBuffer, out: CMTime)]
    }

    private static func concat(_ clip: RecordedClip, to output: URL) -> Bool {
        let valid = clip.segments
            .filter { FileManager.default.fileExists(atPath: $0.url.path) && $0.start.isValid }
            .sorted { CMTimeCompare($0.start, $1.start) < 0 }
        guard !valid.isEmpty else {
            Log.write("[合并] 没有可用分段")
            return false
        }

        // 视频格式取第一个读得动的段；origin = 本次录制的起点，输出时间轴从这里归零
        var videoFormat: CMFormatDescription?
        var origin = valid[0].start
        for seg in valid {
            let probe = AVURLAsset(url: seg.url)
            if let head = readSamples(probe, media: .video, quiet: true).first,
               let format = CMSampleBufferGetFormatDescription(head) {
                videoFormat = format
                origin = seg.start
                break
            }
            Log.write("[合并] 跳过读不动的分段 \(seg.url.lastPathComponent)")
        }
        guard let hint = videoFormat else {
            Log.write("[合并] 所有分段都读不到视频格式")
            return false
        }

        // 本次录制在采集时间轴上的结束位置（用来裁剪连续音轨）
        var clipEnd = valid[0].start
        for seg in valid {
            let end = CMTimeAdd(seg.start, CMTime(seconds: seg.seconds, preferredTimescale: 600))
            if CMTimeCompare(end, clipEnd) > 0 { clipEnd = end }
        }

        let prepared = prepareAudio(clip.audio, origin: origin, clipEnd: clipEnd)

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            Log.write("[合并] 创建写入器失败")
            return false
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            Log.write("[合并] 无法添加视频轨")
            return false
        }
        writer.add(videoInput)

        // 音轨已经是单个连续 AAC 流，直接原样搬进容器（不重编码、不拼接）
        var audioInput: AVAssetWriterInput?
        if let prepared = prepared, let format = prepared.format {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            Log.write("[合并] startWriting 失败 \(writer.error?.localizedDescription ?? "")")
            return false
        }
        writer.startSession(atSourceTime: .zero)

        let began = Date()
        var videoCount = 0
        var audioCount = 0
        var lastVideoOut = CMTime.invalid
        var audioIndex = 0

        for seg in valid {
            let asset = AVURLAsset(url: seg.url)
            let anchor = seg.start
            let videos = readSamples(asset, media: .video)
            guard let head = videos.first else { continue }
            let base = presentationTime(head)

            // ---- 视频：无损搬运，统一映射回采集时间轴后再整体平移 ----
            for sample in videos {
                let out = CMTimeSubtract(CMTimeAdd(anchor, CMTimeSubtract(presentationTime(sample), base)), origin)
                guard out.isValid, CMTimeCompare(out, .zero) >= 0 else { continue }
                if lastVideoOut.isValid && CMTimeCompare(out, lastVideoOut) <= 0 { continue }
                guard let retimed = retime(sample, to: out) else { continue }
                waitReady(videoInput)
                if videoInput.append(retimed) {
                    lastVideoOut = out
                    videoCount += 1
                }
            }

            // ---- 音轨：按本段的时间窗把已经排好的连续音轨推进过去，保证与视频交错写入 ----
            guard let aIn = audioInput, let prepared = prepared else { continue }
            let windowEnd = CMTimeSubtract(
                CMTimeAdd(anchor, CMTime(seconds: seg.seconds, preferredTimescale: 600)), origin)
            while audioIndex < prepared.samples.count {
                let item = prepared.samples[audioIndex]
                if CMTimeCompare(item.out, windowEnd) >= 0 { break }
                waitReady(aIn)
                if aIn.append(item.sample) { audioCount += 1 }
                audioIndex += 1
            }
        }
        // 补齐剩余音轨
        if let aIn = audioInput, let prepared = prepared {
            while audioIndex < prepared.samples.count {
                waitReady(aIn)
                if aIn.append(prepared.samples[audioIndex].sample) { audioCount += 1 }
                audioIndex += 1
            }
        }

        guard videoCount > 0 else {
            Log.write("[合并] 没有可写入的视频样本")
            writer.cancelWriting()
            return false
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        let ok = writer.status == .completed
        let usedMS = Int(Date().timeIntervalSince(began) * 1000)
        if ok {
            let seconds = String(format: "%.1f", CMTimeGetSeconds(lastVideoOut))
            Log.write("[合并] 成功 \(valid.count)段 v=\(videoCount) a=\(audioCount) 时长\(seconds)秒 用时\(usedMS)ms")
        } else {
            Log.write("[合并] 失败 status=\(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")
        }
        return ok
    }

    /// 把连续音轨裁剪到本次录制的范围，并把每帧换算到输出时间轴（origin 归零）。
    private static func prepareAudio(_ audio: RecordedAudio?, origin: CMTime, clipEnd: CMTime) -> PreparedAudio? {
        guard let audio = audio, FileManager.default.fileExists(atPath: audio.url.path) else { return nil }
        let asset = AVURLAsset(url: audio.url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            Log.write("[合并] 读不到连续音轨")
            return nil
        }
        // 音轨文件自己时间轴上的基准（读回来的样本 PTS 也在这个时间轴上）
        let base = track.timeRange.start
        let duration = CMTimeSubtract(clipEnd, origin)
        guard CMTimeCompare(duration, .zero) > 0 else { return nil }
        // 采集时间轴 → 音轨文件时间轴：origin 对应 anchor
        let srcStart = CMTimeMaximum(CMTimeAdd(base, CMTimeSubtract(origin, audio.anchor)), base)

        let samples = readSamples(asset, media: .audio, quiet: true,
                                  range: CMTimeRange(start: srcStart, duration: duration))
        guard let first = samples.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            Log.write("[合并] 连续音轨里没有可用样本")
            return nil
        }

        var out: [(sample: CMSampleBuffer, out: CMTime)] = []
        for sample in samples {
            let t = CMTimeSubtract(CMTimeAdd(audio.anchor, CMTimeSubtract(presentationTime(sample), base)), origin)
            if CMTimeCompare(t, .zero) < 0 { continue }
            if CMTimeCompare(t, duration) > 0 { break }
            out.append((sample: sample, out: t))
        }
        Log.write("[合并] 音轨 \(out.count) 帧 裁到\(String(format: "%.1f", CMTimeGetSeconds(duration)))秒")
        return PreparedAudio(format: format, samples: out)
    }

    /// 兜底：用 AVMutableComposition + passthrough 拼接。
    private static func fallback(_ clip: RecordedClip, to output: URL) -> Bool {
        let valid = clip.segments
            .filter { FileManager.default.fileExists(atPath: $0.url.path) && $0.start.isValid }
            .sorted { CMTimeCompare($0.start, $1.start) < 0 }
        guard !valid.isEmpty else { return false }

        var clipEnd = valid[0].start
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
            let range = CMTimeRange(start: track.timeRange.start, duration: track.timeRange.duration)
            guard range.duration.isValid, CMTimeCompare(range.duration, .zero) > 0 else { continue }
            do {
                try videoTrack?.insertTimeRange(range, of: track, at: cursor)
                inserted += 1
                cursor = CMTimeAdd(cursor, range.duration)
            } catch {
                Log.write("[合并] 拼接失败 \(error.localizedDescription)")
            }
        }

        // 连续音轨：本身就是一条流，按录制范围整段插一次即可
        if let audio = clip.audio,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            let asset = AVURLAsset(url: audio.url)
            if let track = asset.tracks(withMediaType: .audio).first {
                let srcStart = CMTimeAdd(track.timeRange.start,
                                         CMTimeSubtract(valid[0].start, audio.anchor))
                let srcDuration = CMTimeSubtract(clipEnd, valid[0].start)
                if CMTimeCompare(srcDuration, .zero) > 0 {
                    try? audioTrack.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDuration),
                                                    of: track, at: .zero)
                }
            }
        }

        guard inserted > 0,
              let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        try? FileManager.default.removeItem(at: output)
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        let done = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { done.signal() }
        done.wait()
        let ok = exporter.status == .completed
        if ok {
            Log.write("[合并] 拼接方式成功 \(inserted)段")
        } else {
            Log.write("[合并] 拼接方式失败 status=\(exporter.status.rawValue) \(exporter.error?.localizedDescription ?? "")")
        }
        return ok
    }

    private static func readSamples(_ asset: AVURLAsset, media: AVMediaType,
                                    quiet: Bool = false, range: CMTimeRange? = nil) -> [CMSampleBuffer] {
        guard let track = asset.tracks(withMediaType: media).first else {
            if !quiet { Log.write("[合并] 该段没有 \(media.rawValue) 轨道") }
            return []
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            if !quiet { Log.write("[合并] 创建读取器失败") }
            return []
        }
        if let range = range, range.duration.isValid, CMTimeCompare(range.duration, .zero) > 0 {
            // 只读需要的区间，避免把很长的音轨整条读进内存
            reader.timeRange = range
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            if !quiet { Log.write("[合并] 无法挂载读取输出") }
            return []
        }
        reader.add(output)
        guard reader.startReading() else {
            if !quiet { Log.write("[合并] 开始读取失败 status=\(reader.status.rawValue) \(reader.error?.localizedDescription ?? "")") }
            return []
        }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        if samples.isEmpty && !quiet {
            Log.write("[合并] 该段读不到样本 status=\(reader.status.rawValue) \(reader.error?.localizedDescription ?? "")")
        }
        reader.cancelReading()
        return samples
    }

    private static func retime(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sample,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &output)
        return status == noErr ? output : nil
    }

    private static func waitReady(_ input: AVAssetWriterInput) {
        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 3000 {
            Thread.sleep(forTimeInterval: 0.002)
            spins += 1
        }
    }
}
