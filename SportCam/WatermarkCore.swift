import Foundation
import UIKit
import CoreImage
import CoreLocation
import AVFoundation

// ============================================================
//  时间地点水印
//  独立功能：只有设置里打开「时间地点水印」才会启动定位、才会写进视频。
//  关闭时：不定位、不叠图、导出仍走 Passthrough 无损通路。
// ============================================================

// MARK: - 水印配置
/// 烧进视频里的水印内容。
struct WatermarkConfig {
    /// 地点文字，例如「广东省深圳市南山区」
    let place: String
    /// 视频第 0 秒对应的真实时间（第一段开始写盘的那一刻）
    let startDate: Date
}

// MARK: - 定位 + 反查地名
/// 只在开启水印时启动，关掉就停，不常驻。
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    /// 地名变化回调（主线程）
    var onPlace: ((String) -> Void)?
    /// 定位不可用时的提示（主线程）
    var onFailure: ((String) -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocodeAt = Date.distantPast
    private var lastGeocodedLocation: CLLocation?
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25           // 走 25 米以上就重新上报，地名跟得上移动
    }

    func start() {
        guard !running else { return }
        running = true
        // 先用高精度换"马上有结果"，拿到地名后再放宽省电
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            DispatchQueue.main.async { self.onFailure?("定位权限未开启") }
        }
    }

    /// 立刻用系统缓存的位置出一版地名，再持续更新。
    /// 只调 startUpdatingLocation 的话要等系统慢慢吐出第一个点，开关打开后好几秒才有地名。
    private func begin() {
        manager.startUpdatingLocation()
        if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) < 300 {
            resolve(cached)
        }
        manager.requestLocation()          // 再要一次单次定位，拿更新的点
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
    }

    // MARK: CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard running else { return }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            begin()
        } else if status == .denied || status == .restricted {
            DispatchQueue.main.async { self.onFailure?("定位权限被拒绝") }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // 反查地名有配额也很贵：位置基本没动、或刚查过，就跳过
        if let last = lastGeocodedLocation,
           location.distance(from: last) < 50,
           Date().timeIntervalSince(lastGeocodeAt) < 8 { return }
        resolve(location)
    }

    private func resolve(_ location: CLLocation) {
        lastGeocodeAt = Date()
        lastGeocodedLocation = location
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] marks, _ in
            guard let self = self, let mark = marks?.first else { return }
            // 拿到结果就把精度收回来，别一直高精度耗电
            self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            let text = LocationProvider.describe(mark)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { self.onPlace?(text) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?("定位失败") }
    }

    /// 拼地名：省 + 市 + 区 + 街道（含门牌）+ 具体地点。
    /// 反查结果里 thoroughfare / name 才是"具体地方"，只取到区会看不清是在哪。
    private static func describe(_ mark: CLPlacemark) -> String {
        var core: [String] = []
        func addCore(_ raw: String?) {
            guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !core.contains(s) else { return }
            core.append(s)
        }
        addCore(mark.administrativeArea)   // 省 / 直辖市
        addCore(mark.locality)             // 市
        addCore(mark.subLocality)          // 区

        // 街道 + 门牌号
        if let road = mark.thoroughfare?.trimmingCharacters(in: .whitespaces), !road.isEmpty {
            addCore(road + (mark.subThoroughfare ?? ""))
        }

        var text = core.joined()
        // name 一般就是最近的 POI / 具体地点；和已有内容重复就不再加
        if let name = mark.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
           !text.contains(name), !name.contains(text) {
            text += name
        }
        if text.isEmpty { text = mark.country ?? "" }
        return text
    }
}

// MARK: - 水印画布
/// 把「时间 + 地点」画成一张与视频同尺寸的透明图。
/// 画成整幅同尺寸，后面直接叠加即可，不用算任何坐标。
/// 按"秒"缓存：同一秒的 30 帧复用同一张图，开销可以忽略。
final class WatermarkRenderer {

    private let size: CGSize
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private var cacheOrder: [Int] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(renderSize: CGSize) {
        size = renderSize
    }

    func overlay(for date: Date, place: String) -> CIImage? {
        let key = Int(date.timeIntervalSince1970.rounded(.down))
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let image = render(date: date, place: place), let ci = CIImage(image: image) else { return nil }

        lock.lock()
        cache[key] = ci
        cacheOrder.append(key)
        while cacheOrder.count > 4 {                 // 只留最近几秒，别把内存吃满
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        lock.unlock()
        return ci
    }

    private func render(date: Date, place: String) -> UIImage? {
        guard size.width > 8, size.height > 8 else { return nil }

        let fontSize = max(size.height * 0.026, 16)
        let margin = size.width * 0.035
        let timeText = WatermarkRenderer.timeFormatter.string(from: date)
        let lines = place.isEmpty ? [timeText] : [timeText, place]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                              // 尺寸即像素，和视频一一对应
        format.opaque = false
        let canvas = UIGraphicsImageRenderer(size: size, format: format)

        return canvas.image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineSpacing = fontSize * 0.26

            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = fontSize * 0.22
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.05)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]

            let text = lines.joined(separator: "\n") as NSString
            let maxTextWidth = size.width - margin * 3
            let textBounds = text.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               attributes: attrs,
                                               context: nil)

            // 半透明底衬：亮天空下也看得清
            let padX = fontSize * 0.55
            let padY = fontSize * 0.34
            let boxWidth = min(ceil(textBounds.width) + padX * 2, size.width - margin * 1.6)
            let boxHeight = ceil(textBounds.height) + padY * 2
            let boxRect = CGRect(x: margin * 0.8,
                                 y: size.height - margin - boxHeight,
                                 width: boxWidth,
                                 height: boxHeight)

            UIColor.black.withAlphaComponent(0.26).setFill()
            UIBezierPath(roundedRect: boxRect, cornerRadius: boxHeight * 0.2).fill()

            text.draw(with: CGRect(x: boxRect.minX + padX,
                                   y: boxRect.minY + padY,
                                   width: maxTextWidth,
                                   height: ceil(textBounds.height)),
                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                      attributes: attrs,
                      context: nil)
        }
    }
}

// MARK: - 水印合成
enum WatermarkComposition {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 给整条时间轴叠上水印。
    /// 注意：叠加了 videoComposition 就没法再走 Passthrough（系统会拒绝），
    /// 所以开启水印时由合并器改用重编码导出。
    static func make(asset: AVAsset, config: WatermarkConfig) -> AVMutableVideoComposition? {
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let oriented = track.naturalSize.applying(track.preferredTransform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard renderSize.width > 8, renderSize.height > 8 else { return nil }

        let drawer = WatermarkRenderer(renderSize: renderSize)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let seconds = CMTimeGetSeconds(request.compositionTime)
            let date = config.startDate.addingTimeInterval(seconds.isFinite ? max(seconds, 0) : 0)
            let source = request.sourceImage

            guard let overlay = drawer.overlay(for: date, place: config.place) else {
                request.finish(with: source, context: nil)
                return
            }
            let shifted = overlay.transformed(by: CGAffineTransform(translationX: source.extent.minX,
                                                                    y: source.extent.minY))
            request.finish(with: shifted.composited(over: source), context: context)
        }

        composition.renderSize = renderSize
        let fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        return composition
    }
}
