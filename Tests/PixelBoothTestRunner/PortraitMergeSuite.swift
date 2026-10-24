import Foundation
import ImageIO
import PixelBoothJPEG
import PixelBoothMetadata

private let portraitRegionsNamespace = "http://www.metadataworkinggroup.com/schemas/regions/"
private let portraitAreaNamespace = "http://ns.adobe.com/xmp/sType/Area#"

private final class PortraitRegionCounter: NSObject, XMLParserDelegate {
  var count = 0

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if namespaceURI == portraitRegionsNamespace && elementName == "Regions" { count += 1 }
  }
}

private func portraitRegionCount(_ packet: [UInt8]) throws -> Int {
  let counter = PortraitRegionCounter()
  let parser = XMLParser(data: Data(packet))
  parser.shouldProcessNamespaces = true
  parser.shouldResolveExternalEntities = false
  parser.delegate = counter
  guard parser.parse() else { throw NSError(domain: "PortraitMerge", code: 2) }
  return counter.count
}

private func portraitMergePacket() throws -> [UInt8] {
  PixelBoothXMP.build(
    captureUUID: UUID(), appVersion: "test", captureBackend: "synthetic", backendVersion: "test",
    libavifVersion: "test", actualCaptureFormat: "synthetic", encoderSettings: "lossless",
    metadataProvenance: [], fidelity: "unknown", hostLocation: nil, mediaTimeNanos: 1,
    wallClockAnchorISO: "2026-10-22T12:00:00Z",
    portraitRenderIntent: try PortraitRenderIntent(primaryWidth: 400, primaryHeight: 300))
}

/// Aliased prefixes and source-only structured fields exercise namespace-aware
/// merging rather than string matching or replacement of the source region bag.
private func portraitSourceRegions(
  _ type: String, width: Int = 400, height: Int = 300
) -> [UInt8] {
  Array(
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:r="http://www.metadataworkinggroup.com/schemas/regions/"
      xmlns:d="http://ns.adobe.com/xap/1.0/sType/Dimensions#"
      xmlns:a="http://ns.adobe.com/xmp/sType/Area#" xmlns:u="urn:synthetic:source">
      <r:Regions rdf:parseType="Resource">
        <u:RegionNote>preserve source structure</u:RegionNote>
        <r:AppliedToDimensions rdf:parseType="Resource">
          <d:w>\(width)</d:w><d:h>\(height)</d:h><d:unit>pixel</d:unit>
        </r:AppliedToDimensions>
        <r:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource">
          <r:Type>\(type)</r:Type><r:Name>Source region</r:Name>
          <u:PrivateField>unknown retained</u:PrivateField>
          <r:Area rdf:parseType="Resource">
            <a:x>0.8</a:x><a:y>0.3</a:y><a:w>0.1</a:w><a:h>0.1</a:h>
            <a:unit>normalized</a:unit>
          </r:Area>
        </rdf:li></rdf:Bag></r:RegionList>
      </r:Regions>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """.utf8)
}

private func portraitMergedValues(_ packet: [UInt8]) throws -> [String: [String]] {
  guard let metadata = CGImageMetadataCreateFromXMPData(Data(packet) as CFData) else {
    throw NSError(domain: "PortraitMerge", code: 1)
  }
  var values: [String: [String]] = [:]
  CGImageMetadataEnumerateTagsUsingBlock(
    metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
  ) { _, tag in
    if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
      let name = CGImageMetadataTagCopyName(tag) as String?,
      let value = CGImageMetadataTagCopyValue(tag) as? String
    {
      values[namespace + "|" + name, default: []].append(value)
    }
    return true
  }
  return values
}

func runPortraitMergeSuite() async {
  suite("PortraitMerge")

  await test("faceAnnotationsKeepTheirUnknownFieldsAndGainDefaultFocus") {
    let merged = try JPEGMetadataWriter.mergingXMP(
      source: portraitSourceRegions("Face"), additional: portraitMergePacket())
    let values = try portraitMergedValues(merged)
    check(try portraitRegionCount(merged) == 1, "no duplicate Regions property is serialized")
    check(
      values[portraitRegionsNamespace + "|Type"]?.sorted() == ["Face", "Focus"],
      "source face and generated focus both visible to ImageIO")
    check(
      values[portraitAreaNamespace + "|x"]?.sorted() == ["0.5", "0.8"],
      "source region and application focus coordinates retained")
    check(
      values["urn:synthetic:source|PrivateField"] == ["unknown retained"],
      "unknown source field within a region retained")
    check(
      values["urn:synthetic:source|RegionNote"] == ["preserve source structure"],
      "unknown source field within Regions retained")
  }

  await test("existingSourceFocusWinsOverDefaultFocus") {
    let source = portraitSourceRegions("Focus")
    let aliased = String(decoding: source, as: UTF8.self)
      .replacingOccurrences(
        of: "<rdf:Description",
        with: "<q:Description xmlns:q=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\""
      )
      .replacingOccurrences(of: "</rdf:Description>", with: "</q:Description>")
      .replacingOccurrences(of: "rdf:about=", with: "q:about=")
    for packet in [source, Array(aliased.utf8)] {
      let merged = try JPEGMetadataWriter.mergingXMP(
        source: packet, additional: portraitMergePacket())
      let values = try portraitMergedValues(merged)
      check(try portraitRegionCount(merged) == 1, "source Focus has no competing Regions property")
      check(values[portraitRegionsNamespace + "|Type"] == ["Focus"], "no duplicate Focus")
      check(values[portraitAreaNamespace + "|x"] == ["0.8"], "source focus position wins")
      check(
        values["urn:synthetic:source|PrivateField"] == ["unknown retained"],
        "source focus unknown fields survive")
    }
  }

  await test("incompatibleSourceGeometryRetainsSourceRegionsWithoutGuessing") {
    let merged = try JPEGMetadataWriter.mergingXMP(
      source: portraitSourceRegions("Face", width: 800), additional: portraitMergePacket())
    let values = try portraitMergedValues(merged)
    check(values[portraitRegionsNamespace + "|Type"] == ["Face"], "source region not rescaled")
    check(values[portraitAreaNamespace + "|x"] == ["0.8"], "no ungrounded default added")
  }

  await test("focusIsNeverAppendedToAnUnrelatedRDFSubject") {
    let source = String(decoding: portraitSourceRegions("Face"), as: UTF8.self)
      .replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"urn:other-image\"")
    let merged = try JPEGMetadataWriter.mergingXMP(
      source: Array(source.utf8), additional: portraitMergePacket())
    let text = String(decoding: merged, as: UTF8.self)
    check(text.contains("urn:other-image"), "source RDF subject preserved")
    check(text.contains("preserve source structure"), "source region structure preserved")
    check(!text.contains(">Focus<"), "primary Focus never assigned to an unrelated image")
  }

  await test("unsafeSourceXMLCannotEnterAVIFThroughRawMerge") {
    let unsafe = Array(
      """
      <!DOCTYPE x [<!ENTITY external SYSTEM "file:///etc/hosts">]>
      <x:xmpmeta xmlns:x="adobe:ns:meta/">&external;</x:xmpmeta>
      """.utf8)
    expectThrows(
      { try JPEGMetadataWriter.mergingXMP(source: unsafe, additional: portraitMergePacket()) },
      "external entities rejected")
  }

  await test("ordinaryJPEGInsertionRetainsWholeSourceRegionsPriority") {
    let source = try JPEGMetadataWriter.withAdditionalMetadata(
      original: jpegFixture(includeMetadata: false), additionalXMP: portraitSourceRegions("Face"))
    let merged = try JPEGMetadataWriter.withAdditionalMetadata(
      original: source, additionalXMP: portraitMergePacket())
    guard let segment = try JPEGParser.parse(merged).xmpSegment else {
      throw NSError(domain: "PortraitMerge", code: 3)
    }
    let headerSize = 2 + "http://ns.adobe.com/xap/1.0/\0".utf8.count
    let values = try portraitMergedValues(Array(segment.payload.dropFirst(headerSize)))
    check(
      values[portraitRegionsNamespace + "|Type"] == ["Face"],
      "only raw AVIF merging opts into appending Focus to source Regions")
  }
}
