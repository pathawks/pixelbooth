// LocationService — Core Location host observations with explicit
// authorization, freshness, and accuracy validation. The shutter never waits
// for a new location; it snapshots only an already-delivered observation.

@preconcurrency import CoreLocation
import Foundation
import PixelBoothMetadata

@MainActor
public final class LocationProvider: NSObject, CLLocationManagerDelegate {
  private struct CachedLocation: Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var horizontalAccuracy: Double
    var verticalAccuracy: Double?
    var timestamp: Date
  }

  private let manager: CLLocationManager
  private var latest: CachedLocation?
  private var enabled = false
  private var authorizationRequestStarted = false
  private var maximumAgeSeconds: Double

  public init(maximumAgeSeconds: Double = 60.0) {
    self.maximumAgeSeconds = maximumAgeSeconds
    manager = CLLocationManager()
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  /// Starts updates only when the preference is enabled. The first call may
  /// prompt for while-in-use authorization; no coordinates are read before
  /// Core Location grants it.
  public func setEnabled(_ enabled: Bool, maximumAgeSeconds: Double) {
    self.maximumAgeSeconds = Self.validMaximumAge(maximumAgeSeconds)
    guard self.enabled != enabled else { return }
    self.enabled = enabled
    guard enabled else {
      manager.stopUpdatingLocation()
      latest = nil
      return
    }
    refreshAuthorizationAndUpdates()
  }

  /// Snapshot cached location data only. This method never waits for a
  /// location request or asks Core Location to resolve a new coordinate.
  public func snapshotLocation(atCapture captureTime: Date = Date()) -> HostLocationObservation? {
    guard enabled, hasAuthorization, let location = latest else { return nil }
    let age = captureTime.timeIntervalSince(location.timestamp)
    guard age.isFinite, age >= 0, age <= maximumAgeSeconds else { return nil }
    return HostLocationObservation(
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitude,
      horizontalAccuracy: location.horizontalAccuracy,
      verticalAccuracy: location.verticalAccuracy,
      timestampISO: LocationAcceptance.isoString(from: location.timestamp),
      ageAtCaptureSeconds: age)
  }

  public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in
      guard let self, self.enabled else { return }
      self.refreshAuthorizationAndUpdates()
    }
  }

  public nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let newest = locations.last, let cached = Self.cachedLocation(from: newest) else {
      return
    }
    Task { @MainActor [weak self] in
      guard let self, self.enabled, self.hasAuthorization else { return }
      self.latest = cached
    }
  }

  public nonisolated func locationManager(
    _ manager: CLLocationManager, didFailWithError error: Error
  ) {
    // Preserve any still-fresh prior observation. A failed update never
    // becomes a coordinate, and staleness still expires it at shutter time.
  }

  private func refreshAuthorizationAndUpdates() {
    switch manager.authorizationStatus {
    case .notDetermined:
      guard !authorizationRequestStarted else { return }
      authorizationRequestStarted = true
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      authorizationRequestStarted = false
      manager.startUpdatingLocation()
    case .denied, .restricted:
      authorizationRequestStarted = false
      manager.stopUpdatingLocation()
      latest = nil
    @unknown default:
      authorizationRequestStarted = false
      manager.stopUpdatingLocation()
      latest = nil
    }
  }

  private var hasAuthorization: Bool {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: return true
    default: return false
    }
  }

  private nonisolated static func cachedLocation(from location: CLLocation) -> CachedLocation? {
    let coordinate = location.coordinate
    guard
      coordinate.latitude.isFinite && coordinate.longitude.isFinite
        && (-90...90).contains(coordinate.latitude)
        && (-180...180).contains(coordinate.longitude)
        && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
        && location.timestamp.timeIntervalSince1970.isFinite
    else { return nil }
    let hasValidVerticalAccuracy =
      location.verticalAccuracy.isFinite
      && location.verticalAccuracy >= 0
    return CachedLocation(
      latitude: coordinate.latitude, longitude: coordinate.longitude,
      altitude: hasValidVerticalAccuracy && location.altitude.isFinite ? location.altitude : nil,
      horizontalAccuracy: location.horizontalAccuracy,
      verticalAccuracy: hasValidVerticalAccuracy ? location.verticalAccuracy : nil,
      timestamp: location.timestamp)
  }

  private static func validMaximumAge(_ seconds: Double) -> Double {
    seconds.isFinite ? min(max(seconds, 0), 600) : 60
  }
}

extension LocationAcceptance {
  public static func isoString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
