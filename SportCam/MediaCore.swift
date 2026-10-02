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
final class SegmentRecorder {

    private struct Segment {
        let url: URL
        let seconds: Double
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
    private var audioInput: AVAssetWriterInput?
    private var currentURL: URL?
    private var segmentStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private var audioFormat: CMFormatDescription?

    private var rolling: [Segment] = []      // 可被淘汰的滚动段
    private var clip: [Segment] = []         // 正式录制期间累计的段

    private var pendingFinishes = 0
    private var endCompletion: (([URL]) -> Void)?
    private var sequence = 0

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

    /// 停止录制：收尾当前段，返回按时间顺序排列的全部分段
    func endClip(completion: @escaping ([URL]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.armed = false
            self.endCompletion = completion
            if self.writer != nil {
                self.finishCurrentSegment(intoClip: true)
            }
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
        if input.append(sample) { lastVideoPTS = time }
    }

    private func shouldRotate(at time: CMTime) -> Bool {
        guard segmentStart.isValid else { return false }
        return CMTimeGetSeconds(CMTimeSubtract(time, segmentStart)) >= segmentSeconds
    }

    private func handleAudio(_ sample: CMSampleBuffer) {
        guard armed else { return }
        if let format = CMSampleBufferGetFormatDescription(sample) { audioFormat = format }
        guard writer != nil, segmentStart.isValid else { return }
        let time = presentationTime(sample)
        // 段的音频不得早于该段视频起点
        if CMTimeCompare(time, segmentStart) < 0 { return }
        guard let input = audioInput, let w = writer, w.status == .writing else { return }
        if lastAudioPTS.isValid && CMTimeCompare(time, lastAudioPTS) <= 0 { return }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sample) { lastAudioPTS = time }
    }

    private func startSegment(with sample: CMSampleBuffer, at time: CMTime) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        sequence += 1
        let url = folder.appendingPathComponent("seg_\(Int(Date().timeIntervalSince1970))_\(sequence).mp4")
        do {
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            video.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(video) else { return false }
            assetWriter.add(video)

            var audio: AVAssetWriterInput?
            if let audioFormat = audioFormat {
                let candidate = AVAssetWriterInput(mediaType: .audio,
                                                   outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                    AVEncoderBitRateKey: 128000],
                                                   sourceFormatHint: audioFormat)
                candidate.expectsMediaDataInRealTime = true
                if assetWriter.canAdd(candidate) {
                    assetWriter.add(candidate)
                    audio = candidate
                }
            }

            guard assetWriter.startWriting() else {
                Log.write("[分段] startWriting 失败 \(assetWriter.error?.localizedDescription ?? "")")
                return false
            }
            assetWriter.startSession(atSourceTime: time)

            writer = assetWriter
            videoInput = video
            audioInput = audio
            currentURL = url
            segmentStart = time
            lastVideoPTS = time
            lastAudioPTS = .invalid
            return true
        } catch {
            Log.write("[分段] 创建失败 \(error.localizedDescription)")
            return false
        }
    }

    private func finishCurrentSegment(intoClip: Bool, discard: Bool = false) {
        guard let assetWriter = writer, let url = currentURL else { return }
        let seconds = segmentStart.isValid
            ? max(CMTimeGetSeconds(CMTimeSubtract(lastVideoPTS, segmentStart)), 0)
            : 0

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer = nil
        videoInput = nil
        audioInput = nil
        currentURL = nil
        segmentStart = .invalid
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid

        pendingFinishes += 1
        let segment = Segment(url: url, seconds: seconds)
        let useClip = intoClip
        assetWriter.finishWriting { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                if discard {
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
        let urls = clip.map { $0.url }
        clip.removeAll()
        clipMode = false
        notifySegments()
        Log.write("[录制] 收尾完成 共\(urls.count)段")
        DispatchQueue.main.async { completion(urls) }
    }
}

// MARK: - 分段合并
/// 逐样本读取 + 重排时间戳 + 无损写入。
///
/// 之前用 AVMutableComposition 按"每段总时长"顺序拼接，段与段之间会差一两帧
/// （每段的 asset.duration 含不含末帧时长、音频轨比视频轨短一点等），
/// 接缝处就会停顿或跳帧 —— 看起来"一段一段"的。
/// 现在改成自己控制输出时间轴：把每段的样本起点对齐到上一段的结束点，
/// 逐帧重排 PTS 后写入，接缝处零间隙，且只搬样本、不重新编码。
enum SegmentMerger {
    static func merge(_ urls: [URL], to output: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = concat(urls, to: output)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static func concat(_ urls: [URL], to output: URL) -> Bool {
        let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else {
            Log.write("[合并] 没有可用分段")
            return false
        }
        if valid.count == 1 {
            do {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.copyItem(at: valid[0], to: output)
                Log.write("[合并] 单段，直接使用")
                return true
            } catch {
                Log.write("[合并] 复制失败 \(error.localizedDescription)")
                return false
            }
        }

        // 从第一段取视频/音频格式（合并时直接沿用，不重新编码）
        let firstAsset = AVURLAsset(url: valid[0])
        guard let videoFormat = readSamples(firstAsset, media: .video).first
            .flatMap({ CMSampleBufferGetFormatDescription($0) }) else {
            Log.write("[合并] 读不到视频格式")
            return false
        }
        let audioFormat = readSamples(firstAsset, media: .audio).first
            .flatMap({ CMSampleBufferGetFormatDescription($0) })

        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else {
            Log.write("[合并] 创建写入器失败")
            return false
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            Log.write("[合并] 无法添加视频轨")
            return false
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioFormat = audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
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
        var cursor = CMTime.zero
        var videoCount = 0
        var audioCount = 0

        for url in valid {
            let asset = AVURLAsset(url: url)
            let videos = readSamples(asset, media: .video)
            guard let head = videos.first else { continue }
            let base = presentationTime(head)
            let audios = audioInput == nil ? [] : readSamples(asset, media: .audio)

            // 本段时长 = 末帧结束 − 段起点；下一段就从这里接着排，保证零间隙
            var lastEnd = base
            for sample in videos {
                let end = CMTimeAdd(presentationTime(sample), CMSampleBufferGetDuration(sample))
                if CMTimeCompare(end, lastEnd) > 0 { lastEnd = end }
            }
            let limit = CMTimeAdd(cursor, CMTimeSubtract(lastEnd, base))

            var jobs: [(CMTime, Bool, CMSampleBuffer)] = []
            for sample in videos {
                let shifted = CMTimeAdd(cursor, CMTimeSubtract(presentationTime(sample), base))
                if let retimed = retime(sample, to: shifted) { jobs.append((shifted, true, retimed)) }
            }
            for sample in audios {
                let shifted = CMTimeAdd(cursor, CMTimeSubtract(presentationTime(sample), base))
                // 落在本段窗口外的音频丢掉，避免和相邻段重叠
                if CMTimeCompare(shifted, cursor) < 0 || CMTimeCompare(shifted, limit) >= 0 { continue }
                if let retimed = retime(sample, to: shifted) { jobs.append((shifted, false, retimed)) }
            }
            jobs.sort { CMTimeCompare($0.0, $1.0) < 0 }

            for (_, isVideo, sample) in jobs {
                guard let target = isVideo ? videoInput : audioInput else { continue }
                waitReady(target)
                if target.append(sample) {
                    if isVideo { videoCount += 1 } else { audioCount += 1 }
                }
            }
            cursor = limit
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
            let seconds = String(format: "%.1f", CMTimeGetSeconds(cursor))
            Log.write("[合并] 成功 \(valid.count)段 v=\(videoCount) a=\(audioCount) 时长\(seconds)秒 用时\(usedMS)ms")
        } else {
            Log.write("[合并] 失败 status=\(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")
        }
        return ok
    }

    private static func readSamples(_ asset: AVURLAsset, media: AVMediaType) -> [CMSampleBuffer] {
        guard let track = asset.tracks(withMediaType: media).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
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
