import WeatherKit
import CoreLocation

/// Current conditions at a location via WeatherKit.
///
/// Returns nil on any failure — including the common case of a missing
/// WeatherKit entitlement (`com.apple.developer.weatherkit`) on Personal Team
/// accounts. WeatherKit requires a paid Apple Developer Program membership;
/// `import WeatherKit` and calling `WeatherService` compile without the
/// entitlement, but at runtime the call throws. The `try?` below catches that
/// and propagates nil, so the caller degrades to an empty context object.
/// The field is fully wired end-to-end; adding the entitlement on a paid
/// account is the only step needed to activate live weather data.
final class WeatherManager {
    private let service = WeatherService.shared

    func current(at loc: CLLocation) async -> (tempC: Double, condition: String)? {
        guard let w = try? await service.weather(for: loc) else { return nil }
        return (w.currentWeather.temperature.converted(to: .celsius).value,
                w.currentWeather.condition.description)
    }
}
