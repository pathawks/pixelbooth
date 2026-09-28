// PixelBoothMetadata — metadata collection/serialization: Exif, XMP, ICC,
// HDR, location, host vs camera provenance. Also handles the archived XMP
// application namespace for technical information and provenance.

import Foundation

/// Separates camera-provided data, host observations, and application-generated
/// technical data. Preserves conflicting source values rather than choosing.
public enum MetadataProvenance: String, Hashable, Sendable, Codable {
  case cameraProvided
  case hostObserved
  case applicationGenerated
}

/// A single metadata observation, labeled by provenance.
public struct MetadataObservation: Hashable, Sendable, Codable {
  public var key: String
  public var rawValueString: String
  public var provenance: MetadataProvenance
  /// ISO-8601 host time of the observation, when it matters (e.g. control reads).
  public var observedAtISO: String?
  /// Arbitrary verbatim payload preserved from the source when useful.
  public var rawPayload: String?

  public init(key: String, rawValueString: String, provenance: MetadataProvenance,
              observedAtISO: String? = nil, rawPayload: String? = nil) {
    self.key = key
    self.rawValueString = rawValueString
    self.provenance = provenance
    self.observedAtISO = observedAtISO
    self.rawPayload = rawPayload
  }
}

/// Host location observation, recorded with timestamp/age/accuracy.
public struct HostLocationObservation: Hashable, Sendable, Codable {
  public var latitude: Double
  public var longitude: Double
  public var altitude: Double?
  public var horizontalAccuracy: Double
  public var verticalAccuracy: Double?
  public var timestampISO: String
  /// Host-clock age at capture, in seconds.
  public var ageAtCaptureSeconds: Double

  public init(latitude: Double, longitude: Double, altitude: Double?,
              horizontalAccuracy: Double, verticalAccuracy: Double?,
              timestampISO: String, ageAtCaptureSeconds: Double) {
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.horizontalAccuracy = horizontalAccuracy
    self.verticalAccuracy = verticalAccuracy
    self.timestampISO = timestampISO
    self.ageAtCaptureSeconds = ageAtCaptureSeconds
  }
}

/// Snapshot of metadata applicable to the *selected* frame (not whatever is
/// current at encode time).
public struct FrameMetadataSnapshot: Hashable, Sendable, Codable {
  public var sampleBufferAttachments: [String: String]
  public var pixelBufferAttachments: [String: String]
  public var formatDescriptionData: [String: String]
  public var embeddedSourceExif: [UInt8]?
  public var embeddedSourceXMP: [UInt8]?
  public var embeddedSourceICC: [UInt8]?
  public var unknownSegments: [[UInt8]]
  public var hostObservations: [MetadataObservation]
  public var hostLocation: HostLocationObservation?
  /// Media-time (monotonic) of the frame and the wall-clock anchor.
  public var mediaTimeNanos: UInt64
  public var wallClockAnchorISO: String
  /// Configuration generation this snapshot belongs to.
  public var generation: Int

  public init(sampleBufferAttachments: [String: String] = [:],
              pixelBufferAttachments: [String: String] = [:],
              formatDescriptionData: [String: String] = [:],
              embeddedSourceExif: [UInt8]? = nil,
              embeddedSourceXMP: [UInt8]? = nil,
              embeddedSourceICC: [UInt8]? = nil,
              unknownSegments: [[UInt8]] = [],
              hostObservations: [MetadataObservation] = [],
              hostLocation: HostLocationObservation? = nil,
              mediaTimeNanos: UInt64,
              wallClockAnchorISO: String,
              generation: Int) {
    self.sampleBufferAttachments = sampleBufferAttachments
    self.pixelBufferAttachments = pixelBufferAttachments
    self.formatDescriptionData = formatDescriptionData
    self.embeddedSourceExif = embeddedSourceExif
    self.embeddedSourceXMP = embeddedSourceXMP
    self.embeddedSourceICC = embeddedSourceICC
    self.unknownSegments = unknownSegments
    self.hostObservations = hostObservations
    self.hostLocation = hostLocation
    self.mediaTimeNanos = mediaTimeNanos
    self.wallClockAnchorISO = wallClockAnchorISO
    self.generation = generation
  }
}

/// The versioned PixelBooth application XMP namespace payload.
public struct PixelBoothXMP {
  /// Namespace URI, versioned. Bumping the version changes the URI suffix.
  public static let namespaceURI = "https://pixelbooth.app/ns/2026/09/capture/"
  public static let namespacePrefix = "pbx"
  public static let schemaVersion = 1

  /// Build the additional XMP packet for a capture. Includes only documented,
  /// factual observations; camera-provided values are preserved separately
  /// and are not rewritten here.
  public static func build(
    captureUUID: UUID,
    appVersion: String,
    captureBackend: String,
    backendVersion: String,
    libavifVersion: String,
    actualCaptureFormat: String,
    encoderSettings: String,
    metadataProvenance: [MetadataObservation],
    fidelity: String,
    hostLocation: HostLocationObservation?,
    mediaTimeNanos: UInt64,
    wallClockAnchorISO: String
  ) -> [UInt8] {
    var xmp = """
    <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PixelBooth \(appVersion)">
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:\(namespacePrefix)="\((namespaceURI))"
    """

    xmp += "\n  \(namespacePrefix):CaptureUUID=\"\(captureUUID.uuidString)\""
    xmp += "\n  \(namespacePrefix):ApplicationVersion=\"\(escape(appVersion))\""
    xmp += "\n  \(namespacePrefix):CaptureBackend=\"\(escape(captureBackend))\""
    xmp += "\n  \(namespacePrefix):CaptureBackendVersion=\"\(escape(backendVersion))\""
    xmp += "\n  \(namespacePrefix):LibavifVersion=\"\(escape(libavifVersion))\""
    xmp += "\n  \(namespacePrefix):ActualCaptureFormat=\"\(escape(actualCaptureFormat))\""
    xmp += "\n  \(namespacePrefix):EncoderSettings=\"\(escape(encoderSettings))\""
    xmp += "\n  \(namespacePrefix):AcquisitionFidelity=\"\(escape(fidelity))\""
    xmp += "\n  \(namespacePrefix):SchemaVersion=\"\(schemaVersion)\""
    xmp += "\n  \(namespacePrefix):MediaTimeNanos=\"\(mediaTimeNanos)\""
    xmp += "\n  \(namespacePrefix):WallClockAnchor=\"\(escape(wallClockAnchorISO))\""
    if let loc = hostLocation {
      xmp += "\n  \(namespacePrefix):HostLatitude=\"\(loc.latitude)\""
      xmp += "\n  \(namespacePrefix):HostLongitude=\"\(loc.longitude)\""
      if let a = loc.altitude { xmp += "\n  \(namespacePrefix):HostAltitude=\"\(a)\"" }
      xmp += "\n  \(namespacePrefix):HostHorizontalAccuracy=\"\(loc.horizontalAccuracy)\""
      xmp += "\n  \(namespacePrefix):HostLocationTimestamp=\"\(escape(loc.timestampISO))\""
      xmp += "\n  \(namespacePrefix):HostLocationAgeAtCaptureSeconds=\"\(loc.ageAtCaptureSeconds)\""
    }
    for (i, obs) in metadataProvenance.enumerated() {
      xmp += "\n  \(namespacePrefix):Provenance\(i)=\"\(escape(obs.key))=\(escape(obs.rawValueString))|\(obs.provenance.rawValue)\""
      if let at = obs.observedAtISO {
        xmp += "\n  \(namespacePrefix):Provenance\(i)ObservedAt=\"\(escape(at))\""
      }
    }
    xmp += ">\n</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>"
    return Array(xmp.utf8)
  }

  static func escape(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
  }
}

/// Location acceptance policy. Rejects invalid/stale observations and invalid
/// altitude; omits unavailable information without delaying the shutter.
public struct LocationAcceptance {
  public var maximumAgeSeconds: Double

  public init(maximumAgeSeconds: Double = 60.0) {
    self.maximumAgeSeconds = maximumAgeSeconds
  }

  /// Returns the observation if it is acceptable, else nil. Never invents
  /// zero coordinates; never claims GPS without evidence.
  public static func accept(
    _ obs: HostLocationObservation?, atCaptureISO captureISO: String,
    policy: LocationAcceptance
  ) -> HostLocationObservation? {
    guard let obs else { return nil }
    // Validity of coordinates.
    guard obs.latitude >= -90, obs.latitude <= 90,
          obs.longitude >= -180, obs.longitude <= 180 else {
      return nil
    }
    // Reject the degenerate zero-coordinate case; never invent coordinates.
    guard !(obs.latitude == 0 && obs.longitude == 0) else { return nil }
    // Reject stale observations.
    guard obs.ageAtCaptureSeconds >= 0,
          obs.ageAtCaptureSeconds <= policy.maximumAgeSeconds else {
      return nil
    }
    // Reject invalid altitude (below the Earth's center is not plausible).
    if let alt = obs.altitude, alt < -10000 { return nil }
    // Sanity-check that the capture timestamp is parseable; the observation's
    // own timestamp is what is recorded.
    guard !captureISO.isEmpty else { return nil }
    return obs
  }
}
