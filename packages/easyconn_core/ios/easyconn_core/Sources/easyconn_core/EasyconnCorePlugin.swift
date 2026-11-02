import Flutter
import UIKit
import EasyConnKit
import AVFoundation
import CoreLocation

/// Dart <-> EasyConnKit bridge. Methods: start({qr}), stop. Events (one stream): {"log": String} / {"state": String}.
public class EasyconnCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CLLocationManagerDelegate, AVSpeechSynthesizerDelegate {
  private var session: EasyConnSession?
  private var sink: FlutterEventSink?
  private var silence: AVAudioPlayer?
  private var savedBrightness: CGFloat?
  private let locationStore = LocationStore()
  private let locationManager = CLLocationManager()
  private var mapSource: MapSource?
  private var layout: DashLayout = .full
  private var zoomOffset = 0.0
  private let nav = NavigationController()
  private let speech = AVSpeechSynthesizer()
  private var voiceOn = true

  private func setupNavigation() {
    speech.delegate = self
    nav.language = (Locale.preferredLanguages.first ?? "en").hasPrefix("th") ? .th : .en
    nav.onVoice = { [weak self] text in DispatchQueue.main.async { self?.speak(text) } }
    nav.onChange = { [weak self] in
      guard let self else { return }
      let s = self.nav.snapshot
      self.emit(["nav": Self.navSummary(s)])
    }
  }

  /// Speaks over music/other audio by ducking it for the length of the phrase.
  private func speak(_ text: String) {
    guard voiceOn else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])   // lower the music while we talk
    try? session.setActive(true)
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: nav.language == .th ? "th-TH" : "en-US")
    u.rate = AVSpeechUtteranceDefaultSpeechRate
    speech.speak(u)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // give the music its volume back
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, options: [.mixWithOthers])
    try? session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private static func navSummary(_ s: NavigationController.Snapshot) -> String {
    switch s.status {
    case .idle: return ""
    case .routing: return "Calculating route to \(s.destinationName)…"
    case .failed(let why): return "Navigation: \(why)"
    case .arrived: return "Arrived at \(s.destinationName)"
    case .navigating:
      guard let p = s.progress, let r = s.route, p.nextManeuver < r.maneuvers.count else { return "Navigating to \(s.destinationName)" }
      let m = r.maneuvers[p.nextManeuver]
      let km = p.remainingMeters >= 1000 ? String(format: "%.1f km", p.remainingMeters / 1000) : "\(Int(p.remainingMeters)) m"
      return "\(m.instruction) in \(Int(p.distanceToNext)) m · \(km) left to \(s.destinationName)"
    }
  }

  /// Background location updates are what keep the app (and the map) alive after the screen locks.
  private func startLocation() {
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    locationManager.activityType = .otherNavigation
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.requestWhenInUseAuthorization()
    locationManager.startUpdatingLocation()
  }

  private func stopLocation() {
    locationManager.stopUpdatingLocation()
    locationManager.allowsBackgroundLocationUpdates = false
  }

  public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
    locationStore.update(LocationFix(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                     speed: l.speed, course: l.course, accuracy: l.horizontalAccuracy,
                                     altitude: l.verticalAccuracy >= 0 ? l.altitude : nil, time: l.timestamp))
    nav.ingest(locationStore.latest!)
  }

  public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    emit(["log": "location error: \(error.localizedDescription)"])
  }

  @available(iOS 14.0, *)
  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    emit(["log": "location permission status=\(manager.authorizationStatus.rawValue) (3=while using, 4=always)"])
  }

  private func makeMapSource(template: String) -> MapSource {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles")
    let store = TileStore(diskDirectory: caches,
                          loader: TileStore.urlLoader(template: template, userAgent: "RideScreen-iOS/0.1 (personal dashboard app)"))
    let src = MapSource(tiles: store, location: locationStore, weather: WeatherStore(), nav: nav)
    src.layout = layout
    src.zoomOffset = zoomOffset
    mapSource = src
    return src
  }

  /// A looping silent track keeps the process running after the screen locks (UIBackgroundModes: audio).
  /// mixWithOthers so music and navigation voice keep working.
  private func startKeepAlive() {
    if silence != nil { return }
    let rate = 8000, n = rate
    var wav = Data("RIFF".utf8)
    func le(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
    wav += le(UInt32(36 + n * 2)) + Data("WAVEfmt ".utf8) + le(16) + le16(1) + le16(1)
    wav += le(UInt32(rate)) + le(UInt32(rate * 2)) + le16(2) + le16(16)
    wav += Data("data".utf8) + le(UInt32(n * 2)) + Data(count: n * 2)
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      let p = try AVAudioPlayer(data: wav)
      p.numberOfLoops = -1
      p.play()
      silence = p
    } catch {
      emit(["log": "keep-alive audio failed: \(error)"])
    }
  }

  private func stopKeepAlive() {
    silence?.stop()
    silence = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = EasyconnCorePlugin()
    instance.setupNavigation()
    let channel = FlutterMethodChannel(name: "easyconn_core", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "easyconn_core/events", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      let host = args?["host"] as? String
      do {
        session?.stop()
        var cfg = SessionConfig()
        cfg.bikeHost = host
        let scale = UIScreen.main.scale
        let b = UIScreen.main.bounds
        cfg.phoneScreen = (Int(b.width * scale), Int(b.height * scale))
        cfg.identity.model = UIDevice.current.model
        let useMap = (args?["source"] as? String) == "map"
        let template = (args?["tileUrl"] as? String) ?? "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        let s = try useMap ? EasyConnSession(config: cfg, source: makeMapSource(template: template))
                           : EasyConnSession(config: cfg)
        if useMap { locationStore.trip.reset(); startLocation() }
        s.onLog = { [weak self] line in self?.emit(["log": line]) }
        s.onState = { [weak self] st in self?.emit(["state": Self.describe(st)]) }
        try s.start()
        session = s
        UIApplication.shared.isIdleTimerDisabled = true
        startKeepAlive()
        result(nil)
      } catch {
        result(FlutterError(code: "start_failed", message: "\(error)", details: nil))
      }
    case "stop":
      session?.stop()
      session = nil
      UIApplication.shared.isIdleTimerDisabled = false
      mapSource = nil
      if nav.snapshot.status == .idle { stopKeepAlive(); stopLocation() }
      setDim(false)
      result(nil)
    case "scanQr":
      guard let top = Self.topViewController() else { result(nil); return }
      let vc = QrScannerViewController()
      vc.modalPresentationStyle = .fullScreen
      vc.onResult = { result($0) }
      top.present(vc, animated: true)
    case "layout":
      layout = ((call.arguments as? [String: Any])?["name"] as? String) == "wide" ? .wide : .full
      mapSource?.layout = layout
      result(nil)
    case "zoom":
      // delta in zoom levels: +0.5 = closer, -0.5 = wider; clamped to +/-2 around the automatic zoom
      zoomOffset = min(max(zoomOffset + ((call.arguments as? [String: Any])?["delta"] as? Double ?? 0), -2), 2)
      mapSource?.zoomOffset = zoomOffset
      result(zoomOffset)
    case "lastLocation":
      result(locationStore.latest.map { ["lat": $0.lat, "lon": $0.lon] })
    case "search":
      let a = call.arguments as? [String: Any]
      let q = a?["query"] as? String ?? ""
      let here = locationStore.latest.map { LatLon(lat: $0.lat, lon: $0.lon) }
      let near = (a?["lat"] as? Double).flatMap { lat in (a?["lon"] as? Double).map { LatLon(lat: lat, lon: $0) } } ?? here
      Geocoder.search(q, near: near) { places in
        DispatchQueue.main.async {
          result(places.map { ["name": $0.name, "detail": $0.detail, "lat": $0.coordinate.lat, "lon": $0.coordinate.lon] })
        }
      }
    case "navigate":
      guard let a = call.arguments as? [String: Any], let lat = a["lat"] as? Double, let lon = a["lon"] as? Double else {
        result(FlutterError(code: "bad_args", message: "lat/lon required", details: nil)); return
      }
      startLocation()                       // navigation needs GPS even before the dash is connected
      startKeepAlive()
      nav.start(to: LatLon(lat: lat, lon: lon), name: (a["name"] as? String) ?? "Pinned place", from: locationStore.latest)
      result(nil)
    case "stopNavigation":
      nav.stop()
      speech.stopSpeaking(at: .immediate)
      if session == nil { stopLocation(); stopKeepAlive() }
      result(nil)
    case "voice":
      voiceOn = (call.arguments as? [String: Any])?["on"] as? Bool ?? true
      if !voiceOn { speech.stopSpeaking(at: .immediate) }
      result(nil)
    case "dim":
      setDim((call.arguments as? [String: Any])?["on"] as? Bool ?? false)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Blacks out the phone's own display while the app stays in the foreground (the safe alternative to locking).
  private func setDim(_ on: Bool) {
    if on {
      if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
      UIScreen.main.brightness = 0
    } else if let b = savedBrightness {
      UIScreen.main.brightness = b
      savedBrightness = nil
    }
  }

  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func emit(_ event: [String: String]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }

  private static func describe(_ s: SessionState) -> String {
    switch s {
    case .idle: return "idle"
    case .probing: return "probing"
    case .waitingForBike: return "waiting"
    case .handshaking: return "handshaking"
    case .streaming: return "streaming"
    case .failed(let why): return "failed: \(why)"
    }
  }
}
