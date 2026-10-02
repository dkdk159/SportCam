import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

// ============================================================
//  媒体核心：日志 / 环形缓冲 / sampleBuffer 工具 / H.264 编码器
//            提示音 / 影片写入器
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

// MARK: - 线程安全环形缓冲
final class RingBuffer<T> {
    private var storage: [T?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        let safeCapacity = Swift.max(capacity, 1)
        self.capacity = safeCapacity
        self.storage = Array(repeating: nil, count: safeCapacity)
    }

    func append(_ element: T) {
        lock.lock(); defer { lock.unlock() }
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// 由旧到新返回所有元素
    func snapshot() -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return [] }
        var result: [T] = []
        result.reserveCapacity(count)
        let start = count < capacity ? 0 : writeIndex
        for offset in 0..<count {
            if let element = storage[(start + offset) % capacity] { result.append(element) }
        }
        return result
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}

// MARK: - CMSampleBuffer 工具
extension CMSampleBuffer {
    /// 关键帧（I 帧）。无附加信息时按关键帧处理。
    var isSync: Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = array.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// 深拷贝：生成拥有独立内存的副本。
    ///
    /// 【这条是预录能否工作的命门】
    /// 采集/编码回调只要一返回，原始 sampleBuffer 内部的内存就会被系统回收。
    /// 如果我们把原对象塞进预录缓冲、几秒甚至几十秒后才交给 AVAssetWriter，
    /// 拿到的是悬垂指针 —— 写入器立刻 .failed（录不出文件/保存失败），严重时直接闪退。
    func deepCopy() -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
                                              sampleBuffer: self,
                                              sampleBufferOut: &copy)
        guard status == noErr, let duplicated = copy else { return nil }

        guard let source = CMSampleBufferGetDataBuffer(self) else { return duplicated }
        let totalLength = CMBlockBufferGetDataLength(source)
        guard totalLength > 0 else { return duplicated }
        guard let raw = malloc(totalLength) else { return duplicated }

        var offset = 0
        var contiguous = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(source,
                                                        atOffset: 0,
                                                        lengthAtOffsetOut: &offset,
                                                        totalLengthOut: &contiguous,
                                                        dataPointerOut: &pointer)
        // 只支持单块连续内存（采集与编码产出的都是单块）
        guard pointerStatus == noErr, let base = pointer, contiguous == totalLength else {
            free(raw)
            return duplicated
        }
        memcpy(raw, base, totalLength)

        var newBlock: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                             memoryBlock: raw,
                                                             blockLength: totalLength,
                                                             blockAllocator: kCFAllocatorDefault,
                                                             customBlockSource: nil,
                                                             offsetToData: 0,
                                                             dataLength: totalLength,
                                                             flags: 0,
                                                             blockBufferOut: &newBlock)
        guard blockStatus == noErr, let block = newBlock else {
            free(raw)
            return duplicated
        }
        CMSampleBufferSetDataBuffer(duplicated, newValue: block)
        return duplicated
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

    /// 编码器是否可用。创建失败或被系统回收后为 false，由引擎按 1 秒节流自动重建。
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
        // 帧数 + 时间 双保险，保证预录缓冲里总能找到可解码的起点
        set(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Swift.max(fps, 15)))
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

// MARK: - 提示音（进程内合成，走扬声器；录音会话下 AudioServices 听不到）
final class SoundPlayer {
    private let queue = DispatchQueue(label: "com.sportcam.sound")
    private var player: AVAudioPlayer?
    // 大疆式：三连"滴"（开始） / 单声长"滴"（停止）
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

// MARK: - 影片写入器（预录历史帧 + 实时帧）
///
/// 三条写死的规矩（都是踩坑换来的）：
/// 1. expectsMediaDataInRealTime = false —— 预录帧是历史数据，设 true 会被按实时速度节流并丢帧。
/// 2. 每次 append 前必须 isReadyForMoreMediaData —— 盲目 append 会阻塞/抛异常。
/// 3. PTS 必须单调递增，音频不得早于视频起点。
/// 实时帧进"积压队列"，就绪即排空，不丢帧。
final class ClipWriter {
    private let queue = DispatchQueue(label: "com.sportcam.writer")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var running = false

    private var videoWritten = 0
    private var audioWritten = 0
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private var videoBacklog: [CMSampleBuffer] = []
    private var audioBacklog: [CMSampleBuffer] = []
    private let backlogLimit = 300

    func start(video: [CMSampleBuffer],
               audio: [CMSampleBuffer],
               url: URL,
               transform: CGAffineTransform?,
               completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion(false) }; return }
            if self.running {
                Log.write("[写入] 上一段未收尾，强制取消")
                self.writer?.cancelWriting()
                self.resetLocked()
            }
            guard let first = video.first, let format = CMSampleBufferGetFormatDescription(first) else {
                Log.write("[写入] 没有可用视频帧")
                DispatchQueue.main.async { completion(false) }
                return
            }
            let startTime = presentationTime(first)

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let videoTrack = AVAssetWriterInput(mediaType: .video,
                                                    outputSettings: nil,
                                                    sourceFormatHint: format)
                videoTrack.expectsMediaDataInRealTime = false
                if let transform = transform { videoTrack.transform = transform }
                guard assetWriter.canAdd(videoTrack) else {
                    Log.write("[写入] 视频轨添加失败")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                assetWriter.add(videoTrack)

                let validAudio = audio.filter { CMTimeCompare(presentationTime($0), startTime) >= 0 }
                let audioTrack = AVAssetWriterInput(mediaType: .audio,
                                                    outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                     AVEncoderBitRateKey: 128000],
                                                    sourceFormatHint: validAudio.first.flatMap { CMSampleBufferGetFormatDescription($0) })
                audioTrack.expectsMediaDataInRealTime = false
                let hasAudio = assetWriter.canAdd(audioTrack)
                if hasAudio { assetWriter.add(audioTrack) }

                guard assetWriter.startWriting() else {
                    Log.write("[写入] startWriting 失败 \(assetWriter.error?.localizedDescription ?? "")")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                assetWriter.startSession(atSourceTime: startTime)

                self.writer = assetWriter
                self.videoInput = videoTrack
                self.audioInput = hasAudio ? audioTrack : nil
                self.outputURL = url
                self.videoWritten = 0
                self.audioWritten = 0
                self.lastVideoPTS = startTime
                self.lastAudioPTS = .invalid
                self.videoBacklog.removeAll()
                self.audioBacklog.removeAll()
                self.running = true

                self.writePreRecorded(video: video, audio: validAudio)
                Log.write("[写入] 就绪 预录v=\(video.count) 已写v=\(self.videoWritten) 音频=\(hasAudio)")
                DispatchQueue.main.async { completion(true) }
            } catch {
                Log.write("[写入] 异常 \(error.localizedDescription)")
                self.resetLocked()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// 预录历史帧：按 PTS 交错写入
    private func writePreRecorded(video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        guard let videoTrack = videoInput else { return }
        var videoIndex = 0
        var audioIndex = 0
        let deadline = Date().addingTimeInterval(8)

        while (videoIndex < video.count || audioIndex < audio.count) && Date() < deadline {
            // 写入器一旦失败立即退出，绝不空等（否则会堵死整个写入队列，导致后续点击无反应）
            if let assetWriter = writer, assetWriter.status != .writing {
                Log.write("[写入] 预录写入中止 \(assetWriter.error?.localizedDescription ?? "")")
                break
            }
            let takeVideo: Bool
            if audioIndex >= audio.count {
                takeVideo = true
            } else if videoIndex >= video.count {
                takeVideo = false
            } else {
                takeVideo = CMTimeCompare(presentationTime(video[videoIndex]),
                                          presentationTime(audio[audioIndex])) <= 0
            }

            if takeVideo {
                if videoTrack.isReadyForMoreMediaData {
                    if videoTrack.append(video[videoIndex]) {
                        videoWritten += 1
                        lastVideoPTS = presentationTime(video[videoIndex])
                    }
                    videoIndex += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } else if let audioTrack = audioInput {
                if audioTrack.isReadyForMoreMediaData {
                    if audioTrack.append(audio[audioIndex]) {
                        audioWritten += 1
                        lastAudioPTS = presentationTime(audio[audioIndex])
                    }
                    audioIndex += 1
                } else {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            } else {
                audioIndex += 1
            }
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.running,
                  let assetWriter = self.writer, assetWriter.status == .writing else { return }
            if self.videoBacklog.count > self.backlogLimit { self.videoBacklog.removeFirst() }
            self.videoBacklog.append(sample)
            self.drainVideo()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.running,
                  let assetWriter = self.writer, assetWriter.status == .writing else { return }
            if self.audioBacklog.count > self.backlogLimit { self.audioBacklog.removeFirst() }
            self.audioBacklog.append(sample)
            self.drainAudio()
        }
    }

    private func drainVideo() {
        guard let videoTrack = videoInput,
              let assetWriter = writer, assetWriter.status == .writing else { return }
        while !videoBacklog.isEmpty {
            guard videoTrack.isReadyForMoreMediaData else { return }
            let sample = videoBacklog.removeFirst()
            let time = presentationTime(sample)
            if lastVideoPTS.isValid && CMTimeCompare(time, lastVideoPTS) <= 0 { continue }
            lastVideoPTS = time
            if videoTrack.append(sample) { videoWritten += 1 }
        }
    }

    private func drainAudio() {
        guard let audioTrack = audioInput,
              let assetWriter = writer, assetWriter.status == .writing else { return }
        while !audioBacklog.isEmpty {
            guard audioTrack.isReadyForMoreMediaData else { return }
            let sample = audioBacklog.removeFirst()
            let time = presentationTime(sample)
            if lastAudioPTS.isValid && CMTimeCompare(time, lastAudioPTS) <= 0 { continue }
            lastAudioPTS = time
            if audioTrack.append(sample) { audioWritten += 1 }
        }
    }

    func finish(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self, self.running, let assetWriter = self.writer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.running = false
            let url = self.outputURL

            // 收尾前把积压写完
            let deadline = Date().addingTimeInterval(3)
            while (!self.videoBacklog.isEmpty || !self.audioBacklog.isEmpty)
                    && Date() < deadline && assetWriter.status == .writing {
                self.drainVideo()
                self.drainAudio()
                if !self.videoBacklog.isEmpty || !self.audioBacklog.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let writtenFrames = self.videoWritten
            Log.write("[写入] 收尾 视频帧=\(writtenFrames) 音频帧=\(self.audioWritten) 积压=\(self.videoBacklog.count)")

            if writtenFrames == 0 {
                Log.write("[写入] 无有效视频帧，取消")
                assetWriter.cancelWriting()
                self.resetLocked()
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            assetWriter.finishWriting {
                let ok = (assetWriter.status == .completed)
                Log.write("[写入] 完成 ok=\(ok) \(assetWriter.error?.localizedDescription ?? "")")
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
            self.resetLocked()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.running { self.writer?.cancelWriting() }
            self.resetLocked()
        }
    }

    private func resetLocked() {
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        running = false
        videoBacklog.removeAll()
        audioBacklog.removeAll()
        videoWritten = 0
        audioWritten = 0
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid
    }
}
