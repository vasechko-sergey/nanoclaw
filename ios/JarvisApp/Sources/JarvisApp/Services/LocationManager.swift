import CoreLocation

final class LocationManager: NSObject, CLLocationManagerDelegate, ObservableObject {
    // Do not wake GPS more often than once every 15 minutes
    private static let freshThreshold: TimeInterval = 15 * 60

    private let mgr = CLLocationManager()
    @Published var lastLocation: CLLocation?
    @Published var cityName: String?

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

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        lastLocation = loc
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] p, _ in
            DispatchQueue.main.async { self?.cityName = p?.first?.locality }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}
}
