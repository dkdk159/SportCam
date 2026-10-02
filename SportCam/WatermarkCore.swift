import Foundation
import UIKit
import CoreImage
import CoreLocation
import AVFoundation

// ============================================================
//  时间地点水印
//  独立功能：只有开启水印才会启动定位、才会联网取天气、才会写进视频。
//  关闭时：不定位、不联网、不叠图，导出仍走 Passthrough 无损通路。
//  项对齐参考 App：时间 / 地点 / 描述 / 海拔 / 天气 / 温度 / 气压 / 风速
// ============================================================

// MARK: - 水印项
enum WatermarkItem: String, CaseIterable, Identifiable {
    case time = "时间"
    case place = "地点"
    case desc = "描述"
    case altitude = "海拔"
    case weather = "天气"
    case temperature = "温度"
    case pressure = "气压"
    case wind = "风速"

    var id: String { rawValue }

    /// 默认开哪几项：时间和地点，其余按需开
    static let `default`: Set<WatermarkItem> = [.time, .place]
}

// MARK: - 水印数据
/// 水印要用的实时数据。定位和天气各填一半，谁先回来谁先显示，互不阻塞。
struct WatermarkData {
    var place = ""
    var desc = "运动相机"
    var altitude = 0.0
    var hasAltitude = false
    var weather = ""
    var temperature = 0.0
    var pressure = 0.0
    var wind = 0.0
    var hasWeather = false
}

/// 烧进视频里的水印内容
struct WatermarkConfig {
    let data: WatermarkData
    let items: Set<WatermarkItem>
    /// 视频第 0 秒对应的真实时间（第一段开始写盘的那一刻）
    let startDate: Date
}

// MARK: - 拼行
/// 预览和烧录共用同一套拼法，保证"屏幕上看到的就是录进去的"。
enum WatermarkComposer {

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy.MM.dd HH:mm"      // 不读秒，和参考 App 一致
        return f
    }()

    static func lines(date: Date, data: WatermarkData, items: Set<WatermarkItem>) -> [String] {
        var out: [String] = []

        if items.contains(.time) { out.append(timeFormatter.string(from: date)) }
        if items.contains(.place), !data.place.isEmpty { out.append(data.place) }
        if items.contains(.desc), !data.desc.isEmpty { out.append(data.desc) }

        // 海拔 / 天气 / 温度 / 气压 / 风速 合成一行，和参考 App 一样用竖线隔开
        var metrics: [String] = []
        if items.contains(.altitude), data.hasAltitude {
            metrics.append(String(format: "海拔:%.1fm", data.altitude))
        }
        if items.contains(.weather), !data.weather.isEmpty { metrics.append(data.weather) }
        if items.contains(.temperature), data.hasWeather {
            metrics.append(String(format: "%.0f℃", data.temperature))
        }
        if items.contains(.pressure), data.hasWeather {
            metrics.append(String(format: "气压:%.0fhPa", data.pressure))
        }
        if items.contains(.wind), data.hasWeather {
            metrics.append(String(format: "风速:%.0fkm/h", data.wind))
        }
        if !metrics.isEmpty { out.append(metrics.joined(separator: " | ")) }

        return out
    }

    /// 设置面板里每一项右侧显示的当前值
    static func value(of item: WatermarkItem, data: WatermarkData) -> String {
        switch item {
        case .time:
            return timeFormatter.string(from: Date())
        case .place:
            return data.place.isEmpty ? "定位中…" : data.place
        case .desc:
            return data.desc.isEmpty ? "点击填写" : data.desc
        case .altitude:
            return data.hasAltitude ? String(format: "%.1fm", data.altitude) : "获取中…"
        case .weather:
            return data.weather.isEmpty ? "获取中…" : data.weather
        case .temperature:
            return data.hasWeather ? String(format: "%.0f℃", data.temperature) : "获取中…"
        case .pressure:
            return data.hasWeather ? String(format: "%.0fhPa", data.pressure) : "获取中…"
        case .wind:
            return data.hasWeather ? String(format: "%.0fkm/h", data.wind) : "获取中…"
        }
    }
}

// MARK: - 定位 + 反查地名
/// 只在开启水印时启动，关掉就停，不常驻。
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    /// 地名变化回调（主线程）
    var onPlace: ((String) -> Void)?
    /// 坐标 / 海拔回调（主线程）——天气要用。第三个参数表示海拔是否有效。
    var onFix: ((CLLocationCoordinate2D, Double, Bool) -> Void)?
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

    /// 是否已经拿到定位权限（用来决定能不能在启动时静默预热一次）
    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func start() {
        guard !running else { return }
        running = true
        manager.distanceFilter = 25           // 走 25 米以上就重新上报，地名跟得上移动
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            DispatchQueue.main.async { self.onFailure?("定位权限未开启") }
        }
    }

    /// 立刻出一版数据，别让用户干等：
    /// 1) 先把上次记住的地名/坐标顶上去（通常还在同一个地方）；
    /// 2) 有系统缓存位置就直接用它反查；
    /// 3) 先用粗精度逼系统马上给一个点，再把精度收紧。
    private func begin() {
        if let cached = cachedPlace() {
            DispatchQueue.main.async { self.onPlace?(cached) }
        }
        if let cached = cachedCoordinate() {
            DispatchQueue.main.async { self.onFix?(cached.0, cached.1, cached.2) }
        }
        // 粗精度优先：百米精度要等 GPS 收敛，冷启动能拖好几秒；
        // 三公里精度通常走基站/WiFi，1 秒内就有第一个点，先出地名再慢慢变准。
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.startUpdatingLocation()
        if let known = manager.location {
            if abs(known.timestamp.timeIntervalSinceNow) < 1800 { resolve(known) }
            DispatchQueue.main.async {
                self.onFix?(known.coordinate, known.altitude, known.verticalAccuracy >= 0)
            }
        }
        manager.requestLocation()
    }

    // MARK: 缓存
    private static let placeKey = "sportcam.watermark.place"
    private static let placeTimeKey = "sportcam.watermark.placeTime"
    private static let latKey = "sportcam.watermark.lat"
    private static let lonKey = "sportcam.watermark.lon"
    private static let altKey = "sportcam.watermark.alt"

    private func cachedPlace() -> String? {
        let store = UserDefaults.standard
        let text = store.string(forKey: LocationProvider.placeKey) ?? ""
        guard !text.isEmpty else { return nil }
        let when = store.object(forKey: LocationProvider.placeTimeKey) as? Date ?? .distantPast
        // 放宽到 24 小时：绝大多数时候人还在同一个地方，先顶上去再让新定位纠正，
        // 这样点开水印是"秒出"而不是干等定位。
        guard abs(when.timeIntervalSinceNow) < 24 * 3600 else { return nil }
        return text
    }

    private func cachedCoordinate() -> (CLLocationCoordinate2D, Double, Bool)? {
        let store = UserDefaults.standard
        guard store.object(forKey: LocationProvider.latKey) != nil else { return nil }
        let lat = store.double(forKey: LocationProvider.latKey)
        let lon = store.double(forKey: LocationProvider.lonKey)
        guard abs(lat) > 0.0001 || abs(lon) > 0.0001 else { return nil }
        // 只在海拔有效时才写 altKey，所以这里能拿它当有效标志
        let hasAltitude = store.object(forKey: LocationProvider.altKey) != nil
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon),
                store.double(forKey: LocationProvider.altKey),
                hasAltitude)
    }

    private func remember(_ text: String, location: CLLocation) {
        let store = UserDefaults.standard
        store.set(text, forKey: LocationProvider.placeKey)
        store.set(Date(), forKey: LocationProvider.placeTimeKey)
        store.set(location.coordinate.latitude, forKey: LocationProvider.latKey)
        store.set(location.coordinate.longitude, forKey: LocationProvider.lonKey)
        if location.verticalAccuracy >= 0 {
            store.set(location.altitude, forKey: LocationProvider.altKey)
        }
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
        // 已经拿到点，把精度收紧到百米 —— 够反查街道门牌了
        if manager.desiredAccuracy != kCLLocationAccuracyHundredMeters {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
        DispatchQueue.main.async {
            self.onFix?(location.coordinate, location.altitude, location.verticalAccuracy >= 0)
        }
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
            let text = LocationProvider.describe(mark)
            guard !text.isEmpty else { return }
            self.remember(text, location: location)
            DispatchQueue.main.async { self.onPlace?(text) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?("定位失败") }
    }

    /// 拼地名：市 + 区 + 街道（含门牌）+ 具体地点。
    /// 不写省名（太长），而且 name 通常已经含街道了就不再重复拼一遍 ——
    /// 参考 App 的地址也是这个长度，字少一半、水印块更整齐。
    private static func describe(_ mark: CLPlacemark) -> String {
        var parts: [String] = []
        func add(_ raw: String?) {
            guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !parts.contains(s) else { return }
            parts.append(s)
        }

        add(mark.locality ?? mark.administrativeArea)   // 市（直辖市时就是市名）
        add(mark.subLocality)                           // 区

        let name = mark.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let road = mark.thoroughfare?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty, !road.isEmpty, name.contains(road) {
            add(name)                                   // name 已含街道：只写 name
        } else {
            add(road.isEmpty ? nil : road + (mark.subThoroughfare ?? ""))
            add(name)
        }

        if parts.isEmpty { add(mark.country) }
        return parts.joined()
    }
}

// MARK: - 天气（Open-Meteo，免费且不需要申请 key）
final class WeatherProvider {

    struct Snapshot {
        var text = ""
        var temperature = 0.0
        var pressure = 0.0
        var wind = 0.0
        var valid = false
    }

    var onUpdate: ((Snapshot) -> Void)?

    private var lastAt = Date.distantPast
    private var lastLatitude = Double.nan
    private var lastLongitude = Double.nan
    private var task: URLSessionDataTask?

    /// 位置基本没动、且刚取过就不重复请求（默认 10 分钟一次）
    func fetch(_ coordinate: CLLocationCoordinate2D, force: Bool = false) {
        if !force,
           abs(coordinate.latitude - lastLatitude) < 0.02,
           abs(coordinate.longitude - lastLongitude) < 0.02,
           Date().timeIntervalSince(lastAt) < 600 { return }

        lastAt = Date()
        lastLatitude = coordinate.latitude
        lastLongitude = coordinate.longitude

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,surface_pressure,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = comps?.url else { return }

        task?.cancel()
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = root["current"] as? [String: Any] else { return }

            var snap = Snapshot()
            snap.temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue ?? 0
            snap.pressure = (current["surface_pressure"] as? NSNumber)?.doubleValue ?? 0
            snap.wind = (current["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0
            let code = (current["weather_code"] as? NSNumber)?.intValue ?? -1
            snap.text = WeatherProvider.describe(code)
            snap.valid = true
            DispatchQueue.main.async { self.onUpdate?(snap) }
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// WMO 天气码 → 中文
    private static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "晴间多云"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "雪粒"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷暴"
        default: return ""
        }
    }
}

// MARK: - 水印画布
/// 把水印画成一张与视频同尺寸的透明图。
/// 画成整幅同尺寸，后面直接叠加即可，不用算任何坐标。
/// 按内容缓存：同一秒的 30 帧复用同一张图，开销可以忽略。
final class WatermarkRenderer {

    private let size: CGSize
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var cacheOrder: [String] = []

    init(renderSize: CGSize) {
        size = renderSize
    }

    func overlay(for date: Date, data: WatermarkData, items: Set<WatermarkItem>) -> CIImage? {
        let lines = WatermarkComposer.lines(date: date, data: data, items: items)
        guard !lines.isEmpty else { return nil }

        // 秒 + 内容一起做 key：时间在走、天气刚回来，都会自动重画
        let key = String(Int(date.timeIntervalSince1970.rounded(.down))) + "|" + lines.joined(separator: "\u{1}")

        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let image = render(lines: lines), let ci = CIImage(image: image) else { return nil }

        lock.lock()
        cache[key] = ci
        cacheOrder.append(key)
        while cacheOrder.count > 6 {                 // 只留最近几张，别把内存吃满
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        lock.unlock()
        return ci
    }

    private func render(lines: [String]) -> UIImage? {
        guard size.width > 8, size.height > 8 else { return nil }

        let fontSize = max(size.height * 0.024, 15)
        let margin = size.width * 0.035
        // 整块限制在屏宽的 66% 以内：地址长就自己折行，不会甩出一条横贯全屏的长线
        let maxWidth = size.width * 0.66
        let gap = fontSize * 0.26

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                              // 尺寸即像素，和视频一一对应
        format.opaque = false
        let canvas = UIGraphicsImageRenderer(size: size, format: format)

        return canvas.image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineSpacing = fontSize * 0.2

            // 参考 App 的写法：不铺黑底，只用「白字 + 细黑描边 + 淡阴影」，
            // 亮天空下照样看得清，画面也干净。
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = fontSize * 0.3
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.05)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black.withAlphaComponent(0.5),
                .strokeWidth: -3.0,
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]

            // 先量出每一行（含折行后）的高度，再整块从底部往上排
            let heights: [CGFloat] = lines.map { line in
                ceil((line as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: attrs,
                                                     context: nil).height)
            }
            let total = heights.reduce(0, +) + gap * CGFloat(max(lines.count - 1, 0))

            var y = size.height - margin - total
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(with: CGRect(x: margin, y: y, width: maxWidth, height: heights[index]),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: attrs,
                                        context: nil)
                y += heights[index] + gap
            }
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

            guard let overlay = drawer.overlay(for: date, data: config.data, items: config.items) else {
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
