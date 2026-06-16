import CoreLocation

@Observable @MainActor final class LocationManager: NSObject, CLLocationManagerDelegate {
    // Do not wake GPS more often than once every 15 minutes
    private static let freshThreshold: TimeInterval = 15 * 60

    // Reverse-geocode at most this often; reuse the cached city otherwise.
    private static let cityFreshThreshold: TimeInterval = 15 * 60

    @ObservationIgnored private let mgr = CLLocationManager()
    var lastLocation: CLLocation?
    var cityName: String?

    /// Injected — fires proactive triggers when delta exceeds 500m.
    @ObservationIgnored private weak var dispatcher: ProactiveDispatcher?
    /// Last location anchor used to compute geofence deltas.
    @ObservationIgnored private var geofenceAnchor: CLLocation?
    /// One reused geocoder — allocating a `CLGeocoder` per fix is wasteful and
    /// significant-change updates can arrive in bursts.
    @ObservationIgnored private let geocoder = CLGeocoder()
    /// When `cityName` was last resolved — gates how often we reverse-geocode.
    @ObservationIgnored private var cityResolvedAt: Date?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func attachDispatcher(_ d: ProactiveDispatcher) {
        self.dispatcher = d
    }

    func startSignificantLocationMonitoring() {
        mgr.startMonitoringSignificantLocationChanges()
    }

    func requestAndUpdate() {
        mgr.requestWhenInUseAuthorization()
        if let loc = lastLocation,
           Date().timeIntervalSince(loc.timestamp) < Self.freshThreshold { return }
        mgr.requestLocation()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            lastLocation = loc
            if let anchor = geofenceAnchor, loc.distance(from: anchor) > 500 {
                let lat = (loc.coordinate.latitude * 1e4).rounded() / 1e4
                let lon = (loc.coordinate.longitude * 1e4).rounded() / 1e4
                dispatcher?.fire(type: "geofence", payload: [
                    "lat": lat, "lon": lon, "city": cityName ?? "",
                ])
                geofenceAnchor = loc
            } else if geofenceAnchor == nil {
                geofenceAnchor = loc
            }
            // Only reverse-geocode when the cached city is empty or stale — not on
            // every significant-change update.
            let stale = cityResolvedAt.map { Date().timeIntervalSince($0) > Self.cityFreshThreshold } ?? true
            if (cityName?.isEmpty ?? true) || stale, !geocoder.isGeocoding {
                if let placemarks = try? await geocoder.reverseGeocodeLocation(loc),
                   let city = placemarks.first?.locality {
                    cityName = city
                    cityResolvedAt = Date()
                }
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}
