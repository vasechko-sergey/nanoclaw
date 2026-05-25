import CoreLocation

@Observable @MainActor final class LocationManager: NSObject, CLLocationManagerDelegate {
    // Do not wake GPS more often than once every 15 minutes
    private static let freshThreshold: TimeInterval = 15 * 60

    @ObservationIgnored private let mgr = CLLocationManager()
    var lastLocation: CLLocation?
    var cityName: String?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(loc)
            cityName = placemarks?.first?.locality
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}
