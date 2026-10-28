import CoreLocation
import Observation

@MainActor @Observable final class HeadingService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var requested = false
    var heading: HeadingRecord?
    var location: LocationRecord?
    var place: String?
    var message: String?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; manager.headingOrientation = .portrait }
    func request() { requested = true; manager.requestWhenInUseAuthorization(); start() }
    func stop() { requested = false; manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }
    private func start() {
        guard requested else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { start() }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.trueHeading >= 0, newHeading.headingAccuracy >= 0 else { heading = nil; return }
        heading = .init(degrees: newHeading.trueHeading, accuracy: newHeading.headingAccuracy)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0 else { return }
        location = .init(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude, accuracy: value.horizontalAccuracy)
        if place == nil {
            Task { do { let marks = try await CLGeocoder().reverseGeocodeLocation(value); place = marks.first?.locality ?? marks.first?.name } catch { message = "Place name unavailable; coordinates are retained." } }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Location unavailable. Capture can continue using the first shot as its reference." }
}
