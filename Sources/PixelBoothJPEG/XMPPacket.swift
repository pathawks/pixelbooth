import CryptoKit
import Foundation

/// Bounded, entity-disabled XMP merging and JPEG APP1 packet construction.
enum JPEGXMPPacket {
  private static let standardIdentifier = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
  private static let extendedIdentifier = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
  private static let xmpNamespace = "adobe:ns:meta/"
  private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  private static let xmpNoteNamespace = "http://ns.adobe.com/xmp/note/"
  private static let maximumPacketBytes = 4 * 1_024 * 1_024
  private static let maximumXMLDepth = 128
  private static let maximumXMLNodes = 100_000

  struct Output {
    var segments: [JPEGSegment]
    var mergedPacket: [UInt8]
  }

  private struct PropertyKey: Hashable {
    var namespace: String
    var localName: String
  }

  private struct Element {
    var name: String
    var attributes: [String: String]
    var children: [Node]
  }

  private indirect enum Node {
    case element(Element)
    case text(String)
    case comment(String)
  }

  private struct Document {
    var root: Element
  }

  static func isStandardSegment(_ segment: JPEGSegment) -> Bool {
    segment.marker == 0xE1
      && content(after: 2, in: segment.payload)?.starts(with: standardIdentifier) == true
  }

  static func isExtendedSegment(_ segment: JPEGSegment) -> Bool {
    segment.marker == 0xE1
      && content(after: 2, in: segment.payload)?.starts(with: extendedIdentifier) == true
  }

  static func isXMPApp1(_ segment: JPEGSegment) -> Bool {
    isStandardSegment(segment) || isExtendedSegment(segment)
  }

  static func sourcePackets(from segments: [JPEGSegment]) throws -> [Data] {
    let standardSegments = segments.filter(isStandardSegment)
    let extensionSegments = segments.filter(isExtendedSegment)
    guard !extensionSegments.isEmpty || !standardSegments.isEmpty else { return [] }

    var parsedStandards: [(data: Data, document: Document, extendedGUID: String?)] = []
    for segment in standardSegments {
      guard let bytes = content(after: 2 + standardIdentifier.count, in: segment.payload) else {
        throw metadataError("A source XMP APP1 packet is truncated.")
      }
      let data = Data(bytes)
      let document = try parse(data)
      parsedStandards.append(
        (data, document, extendedGUID(in: document.root, namespaces: [:])))
    }

    var extensionGroups: [String: [ExtensionChunk]] = [:]
    for segment in extensionSegments {
      let chunk = try parseExtensionSegment(segment)
      extensionGroups[chunk.guid, default: []].append(chunk)
    }

    var packets: [Data] = []
    var referencedGUIDs: Set<String> = []
    for standard in parsedStandards {
      packets.append(standard.data)
      guard let guid = standard.extendedGUID else { continue }
      referencedGUIDs.insert(guid)
      guard let chunks = extensionGroups[guid] else {
        throw metadataError("The source XMP packet refers to a missing extended XMP payload.")
      }
      packets.append(try assembleExtension(guid: guid, chunks: chunks))
    }
    guard referencedGUIDs == Set(extensionGroups.keys) else {
      throw metadataError("The JPEG contains an unreferenced extended XMP payload.")
    }
    return packets
  }

  static func makeOutput(sourcePackets: [Data], additionalPacket: [UInt8]) throws -> Output {
    let appData = Data(additionalPacket)
    let appDocument = try parse(appData)
    guard findRDF(in: appDocument.root, inheritedNamespaces: [:]) != nil else {
      throw metadataError("The application XMP packet has no RDF description.")
    }

    var mergedDocument: Document
    if let first = sourcePackets.first {
      mergedDocument = Document(root: try parse(first).root)
      removeExtendedReferences(in: &mergedDocument.root, inheritedNamespaces: [:])
      guard isXMPRoot(mergedDocument.root, namespaces: [:]) else {
        throw metadataError("The source XMP packet has an unsupported root element.")
      }
      for sourcePacket in sourcePackets.dropFirst() {
        let sourceDocument = try parse(sourcePacket)
        var sourceRoot = sourceDocument.root
        removeExtendedReferences(in: &sourceRoot, inheritedNamespaces: [:])
        try appendRDFChildren(
          from: sourceRoot, to: &mergedDocument.root,
          inheritedNamespaces: [:], filteringConflicts: false, conflicts: [])
      }
    } else {
      mergedDocument = appDocument
      return try output(for: Data(serializePacket(mergedDocument.root).utf8))
    }

    let sourceProperties = collectProperties(in: mergedDocument.root, inheritedNamespaces: [:])
    try appendRDFChildren(
      from: appDocument.root, to: &mergedDocument.root,
      inheritedNamespaces: [:], filteringConflicts: true, conflicts: sourceProperties)
    return try output(for: Data(serializePacket(mergedDocument.root).utf8))
  }

  private struct ExtensionChunk {
    var guid: String
    var fullLength: Int
    var offset: Int
    var bytes: [UInt8]
  }

  private static func parseExtensionSegment(_ segment: JPEGSegment) throws -> ExtensionChunk {
    guard let raw = content(after: 2 + extendedIdentifier.count, in: segment.payload),
      raw.count >= 40
    else { throw metadataError("A source extended XMP APP1 packet is truncated.") }
    let guidBytes = raw[0..<32]
    guard guidBytes.allSatisfy({ isHex($0) }),
      let fullLength32 = readUInt32(raw, at: 32),
      let offset32 = readUInt32(raw, at: 36),
      fullLength32 > 0, fullLength32 <= UInt32(maximumPacketBytes)
    else { throw metadataError("A source extended XMP header is malformed or oversized.") }
    let fullLength = Int(fullLength32)
    let offset = Int(offset32)
    let chunkBytes = Array(raw.dropFirst(40))
    guard offset <= fullLength, chunkBytes.count <= fullLength - offset else {
      throw metadataError("A source extended XMP chunk exceeds its declared bounds.")
    }
    return ExtensionChunk(
      guid: String(decoding: guidBytes, as: UTF8.self).uppercased(), fullLength: fullLength,
      offset: offset, bytes: chunkBytes)
  }

  private static func assembleExtension(guid: String, chunks: [ExtensionChunk]) throws -> Data {
    guard let first = chunks.first, chunks.allSatisfy({ $0.fullLength == first.fullLength }) else {
      throw metadataError("Extended XMP chunks disagree about the full packet length.")
    }
    let ordered = chunks.sorted { $0.offset < $1.offset }
    var packet: [UInt8] = []
    packet.reserveCapacity(first.fullLength)
    for chunk in ordered {
      guard chunk.offset == packet.count else {
        throw metadataError("Extended XMP chunks overlap or leave a gap.")
      }
      packet.append(contentsOf: chunk.bytes)
    }
    guard packet.count == first.fullLength,
      md5GUID(Data(packet)) == guid
    else { throw metadataError("The extended XMP length or MD5 identifier does not match.") }
    _ = try parse(Data(packet))
    return Data(packet)
  }

  private static func output(for packet: Data) throws -> Output {
    guard packet.count <= maximumPacketBytes else {
      throw metadataError("Merged XMP exceeds the 4 MiB safety limit.")
    }
    let bytes = [UInt8](packet)
    if let standard = try makeSegment(identifier: standardIdentifier, data: bytes) {
      return Output(segments: [standard], mergedPacket: bytes)
    }

    let guid = md5GUID(packet)
    let primary = Array(extendedPrimaryPacket(guid: guid).utf8)
    guard let standard = try makeSegment(identifier: standardIdentifier, data: primary),
      let fullLength = UInt32(exactly: bytes.count)
    else { throw metadataError("Merged XMP cannot be represented in JPEG APP1 segments.") }
    let maximumChunkBytes = 65_535 - 2 - extendedIdentifier.count - 32 - 8
    var segments = [standard]
    var offset = 0
    while offset < bytes.count {
      let chunkEnd = min(offset + maximumChunkBytes, bytes.count)
      var extensionData = Array(guid.utf8)
      appendUInt32(fullLength, to: &extensionData)
      guard let offset32 = UInt32(exactly: offset) else {
        throw metadataError("An extended XMP chunk offset exceeds JPEG bounds.")
      }
      appendUInt32(offset32, to: &extensionData)
      extensionData.append(contentsOf: bytes[offset..<chunkEnd])
      guard let segment = try makeSegment(identifier: extendedIdentifier, data: extensionData)
      else {
        throw metadataError("An extended XMP chunk exceeds the JPEG APP1 limit.")
      }
      segments.append(segment)
      offset = chunkEnd
    }
    return Output(segments: segments, mergedPacket: bytes)
  }

  private static func makeSegment(identifier: [UInt8], data: [UInt8]) throws -> JPEGSegment? {
    let (length, overflow) = identifier.count.addingReportingOverflow(data.count)
    guard !overflow else { throw metadataError("XMP APP1 size arithmetic overflowed.") }
    let (segmentLength, lengthOverflow) = length.addingReportingOverflow(2)
    guard !lengthOverflow else { throw metadataError("XMP APP1 size arithmetic overflowed.") }
    guard segmentLength <= 65_535 else { return nil }
    return JPEGSegment(
      marker: 0xE1, offset: 0,
      payload: [UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)] + identifier + data)
  }

  private static func extendedPrimaryPacket(guid: String) -> String {
    """
    <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmpNote="http://ns.adobe.com/xmp/note/" xmpNote:HasExtendedXMP="\(guid)"/>
    </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
  }

  private static func md5GUID(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
  }

  private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 24) & 0xFF))
    bytes.append(UInt8((value >> 16) & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
    bytes.append(UInt8(value & 0xFF))
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else { return nil }
    return (UInt32(bytes[offset]) << 24)
      | (UInt32(bytes[offset + 1]) << 16)
      | (UInt32(bytes[offset + 2]) << 8)
      | UInt32(bytes[offset + 3])
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
  }

  private static func content(after offset: Int, in payload: [UInt8]) -> [UInt8]? {
    guard offset >= 0, offset <= payload.count else { return nil }
    return Array(payload.dropFirst(offset))
  }

  private static func parse(_ data: Data) throws -> Document {
    guard !data.isEmpty, data.count <= maximumPacketBytes,
      let string = String(data: data, encoding: .utf8)
    else { throw metadataError("An XMP packet is empty, oversized or not valid UTF-8.") }
    let uppercase = string.uppercased()
    guard !uppercase.contains("<!DOCTYPE"), !uppercase.contains("<!ENTITY") else {
      throw metadataError("XMP document types and entity declarations are not accepted.")
    }
    let builder = XMPBuilder()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.shouldResolveExternalEntities = false
    parser.delegate = builder
    guard parser.parse(), let root = builder.root else {
      throw metadataError("An XMP packet is malformed: \(builder.failure ?? "XML parse failed").")
    }
    guard isXMPRoot(root, namespaces: [:]),
      findRDF(in: root, inheritedNamespaces: [:]) != nil
    else { throw metadataError("An XMP packet has no recognized xmpmeta/RDF structure.") }
    return Document(root: root)
  }

  private static func isXMPRoot(_ element: Element, namespaces: [String: String]) -> Bool {
    let scope = namespaceScope(parent: namespaces, attributes: element.attributes)
    let (prefix, localName) = splitName(element.name)
    return localName == "xmpmeta" && scope[prefix] == xmpNamespace
  }

  private static func findRDF(
    in element: Element, inheritedNamespaces: [String: String]
  ) -> (path: [Int], namespaces: [String: String])? {
    let scope = namespaceScope(parent: inheritedNamespaces, attributes: element.attributes)
    let (prefix, localName) = splitName(element.name)
    if localName == "RDF", scope[prefix] == rdfNamespace { return ([], scope) }
    for index in element.children.indices {
      guard case .element(let child) = element.children[index],
        let result = findRDF(in: child, inheritedNamespaces: scope)
      else { continue }
      return ([index] + result.path, result.namespaces)
    }
    return nil
  }

  private static func appendRDFChildren(
    from source: Element, to destination: inout Element,
    inheritedNamespaces: [String: String], filteringConflicts: Bool,
    conflicts: Set<PropertyKey>
  ) throws {
    guard let sourceRDF = findRDF(in: source, inheritedNamespaces: inheritedNamespaces) else {
      throw metadataError("An XMP packet has no RDF structure.")
    }
    guard let destinationRDF = findRDF(in: destination, inheritedNamespaces: [:]) else {
      try addEmptyRDF(to: &destination)
      guard let newRDF = findRDF(in: destination, inheritedNamespaces: [:]) else {
        throw metadataError("Could not build a merged RDF description.")
      }
      try appendChildren(
        from: source, sourcePath: sourceRDF.path, sourceNamespaces: sourceRDF.namespaces,
        to: &destination, destinationPath: newRDF.path,
        filteringConflicts: filteringConflicts, conflicts: conflicts)
      return
    }
    try appendChildren(
      from: source, sourcePath: sourceRDF.path, sourceNamespaces: sourceRDF.namespaces,
      to: &destination, destinationPath: destinationRDF.path,
      filteringConflicts: filteringConflicts, conflicts: conflicts)
  }

  private static func appendChildren(
    from source: Element, sourcePath: [Int], sourceNamespaces: [String: String],
    to destination: inout Element, destinationPath: [Int],
    filteringConflicts: Bool, conflicts: Set<PropertyKey>
  ) throws {
    guard let sourceRDF = element(at: sourcePath, in: source),
      var destinationRDF = element(at: destinationPath, in: destination)
    else { throw metadataError("Could not locate an RDF description while merging XMP.") }

    for child in sourceRDF.children {
      guard case .element(var copied) = child else { continue }
      guard
        expandedName(copied.name, namespaces: sourceNamespaces, isAttribute: false)
          == PropertyKey(namespace: rdfNamespace, localName: "Description")
      else {
        destinationRDF.children.append(child)
        continue
      }
      copied.attributes = sourceNamespaces.reduce(into: copied.attributes) { attributes, entry in
        let name = entry.key.isEmpty ? "xmlns" : "xmlns:\(entry.key)"
        if attributes[name] == nil { attributes[name] = entry.value }
      }
      if filteringConflicts {
        let copiedNamespaces = namespaceScope(
          parent: sourceNamespaces, attributes: copied.attributes)
        copied.attributes = copied.attributes.filter { name, _ in
          guard let key = expandedName(name, namespaces: copiedNamespaces, isAttribute: true),
            name != "rdf:about"
          else { return true }
          return !conflicts.contains(key)
        }
        copied.children.removeAll { child in
          guard case .element(let property) = child,
            let key = expandedName(property.name, namespaces: copiedNamespaces, isAttribute: false)
          else { return false }
          return conflicts.contains(key)
        }
      }
      destinationRDF.children.append(.element(copied))
    }
    guard replaceElement(at: destinationPath, in: &destination, with: destinationRDF) else {
      throw metadataError("Could not install merged RDF properties.")
    }
  }

  private static func collectProperties(
    in root: Element, inheritedNamespaces: [String: String]
  ) -> Set<PropertyKey> {
    guard let rdf = findRDF(in: root, inheritedNamespaces: inheritedNamespaces),
      let rdfElement = element(at: rdf.path, in: root)
    else { return [] }
    var result: Set<PropertyKey> = []
    for child in rdfElement.children {
      guard case .element(let description) = child,
        expandedName(description.name, namespaces: rdf.namespaces, isAttribute: false)
          == PropertyKey(namespace: rdfNamespace, localName: "Description")
      else { continue }
      let scope = namespaceScope(parent: rdf.namespaces, attributes: description.attributes)
      for name in description.attributes.keys where name != "rdf:about" {
        if let key = expandedName(name, namespaces: scope, isAttribute: true) { result.insert(key) }
      }
      for property in description.children {
        guard case .element(let property) = property,
          let key = expandedName(property.name, namespaces: scope, isAttribute: false)
        else { continue }
        result.insert(key)
      }
    }
    return result
  }

  private static func extendedGUID(in root: Element, namespaces: [String: String]) -> String? {
    guard let rdf = findRDF(in: root, inheritedNamespaces: namespaces),
      let rdfElement = element(at: rdf.path, in: root)
    else { return nil }
    for child in rdfElement.children {
      guard case .element(let description) = child else { continue }
      let scope = namespaceScope(parent: rdf.namespaces, attributes: description.attributes)
      for (name, value) in description.attributes {
        guard
          expandedName(name, namespaces: scope, isAttribute: true)
            == PropertyKey(namespace: xmpNoteNamespace, localName: "HasExtendedXMP")
        else { continue }
        let normalized = value.uppercased()
        guard normalized.count == 32, normalized.utf8.allSatisfy(isHex) else { return nil }
        return normalized
      }
    }
    return nil
  }

  private static func removeExtendedReferences(
    in element: inout Element, inheritedNamespaces: [String: String]
  ) {
    let scope = namespaceScope(parent: inheritedNamespaces, attributes: element.attributes)
    element.attributes = element.attributes.filter { name, _ in
      expandedName(name, namespaces: scope, isAttribute: true)
        != PropertyKey(namespace: xmpNoteNamespace, localName: "HasExtendedXMP")
    }
    for index in element.children.indices {
      guard case .element(var child) = element.children[index] else { continue }
      removeExtendedReferences(in: &child, inheritedNamespaces: scope)
      element.children[index] = .element(child)
    }
  }

  private static func addEmptyRDF(to root: inout Element) throws {
    var scope = namespaceScope(parent: [:], attributes: root.attributes)
    if scope["rdf"] != nil, scope["rdf"] != rdfNamespace {
      root.children.append(
        .element(
          Element(
            name: "rdf:RDF", attributes: ["xmlns:rdf": rdfNamespace],
            children: [
              .element(
                Element(name: "rdf:Description", attributes: ["rdf:about": ""], children: []))
            ])))
    } else {
      root.attributes["xmlns:rdf"] = rdfNamespace
      scope["rdf"] = rdfNamespace
      root.children.append(
        .element(
          Element(
            name: "rdf:RDF", attributes: [:],
            children: [
              .element(
                Element(name: "rdf:Description", attributes: ["rdf:about": ""], children: []))
            ])))
    }
  }

  private static func element(at path: [Int], in root: Element) -> Element? {
    guard let index = path.first else { return root }
    guard root.children.indices.contains(index), case .element(let child) = root.children[index]
    else {
      return nil
    }
    return element(at: Array(path.dropFirst()), in: child)
  }

  private static func replaceElement(
    at path: [Int], in root: inout Element, with replacement: Element
  ) -> Bool {
    guard let index = path.first else {
      root = replacement
      return true
    }
    guard root.children.indices.contains(index), case .element(var child) = root.children[index]
    else { return false }
    guard replaceElement(at: Array(path.dropFirst()), in: &child, with: replacement) else {
      return false
    }
    root.children[index] = .element(child)
    return true
  }

  private static func namespaceScope(
    parent: [String: String], attributes: [String: String]
  ) -> [String: String] {
    var result = parent
    for (name, value) in attributes {
      if name == "xmlns" {
        result[""] = value
      } else if name.hasPrefix("xmlns:") {
        result[String(name.dropFirst(6))] = value
      }
    }
    return result
  }

  private static func expandedName(
    _ name: String, namespaces: [String: String], isAttribute: Bool
  ) -> PropertyKey? {
    guard name != "xmlns", !name.hasPrefix("xmlns:") else { return nil }
    let (prefix, localName) = splitName(name)
    guard !localName.isEmpty else { return nil }
    if prefix.isEmpty, isAttribute { return nil }
    guard let namespace = namespaces[prefix] else { return nil }
    return PropertyKey(namespace: namespace, localName: localName)
  }

  private static func splitName(_ name: String) -> (String, String) {
    guard let colon = name.firstIndex(of: ":") else { return ("", name) }
    return (String(name[..<colon]), String(name[name.index(after: colon)...]))
  }

  private static func serializePacket(_ root: Element) -> String {
    "<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
      + serialize(.element(root)) + "\n<?xpacket end=\"w\"?>"
  }

  private static func serialize(_ node: Node) -> String {
    switch node {
    case .element(let element):
      let attributes = element.attributes.keys.sorted().map { key in
        " \(key)=\"\(escape(element.attributes[key] ?? "", attribute: true))\""
      }.joined()
      if element.children.isEmpty { return "<\(element.name)\(attributes)/>" }
      return "<\(element.name)\(attributes)>"
        + element.children.map(serialize).joined()
        + "</\(element.name)>"
    case .text(let text): return escape(text, attribute: false)
    case .comment(let comment): return "<!--\(comment)-->"
    }
  }

  private static func escape(_ value: String, attribute: Bool) -> String {
    var result = value.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    if attribute {
      result = result.replacingOccurrences(of: "\"", with: "&quot;")
      result = result.replacingOccurrences(of: "'", with: "&apos;")
    }
    return result
  }

  private static func metadataError(_ message: String) -> JPEGError {
    .metadataInsertionFailed(message)
  }

  private final class XMPBuilder: NSObject, XMLParserDelegate {
    var root: Element?
    var failure: String?
    private var stack: [Element] = []
    private var nodeCount = 0

    func parser(
      _ parser: XMLParser, didStartElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]
    ) {
      nodeCount += 1
      guard stack.count < JPEGXMPPacket.maximumXMLDepth,
        nodeCount <= JPEGXMPPacket.maximumXMLNodes
      else {
        failure = "The XMP nesting or node count exceeds safety limits"
        parser.abortParsing()
        return
      }
      stack.append(Element(name: qName ?? elementName, attributes: attributes, children: []))
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?
    ) {
      guard let element = stack.popLast() else {
        failure = "The XMP element nesting is invalid"
        parser.abortParsing()
        return
      }
      if stack.isEmpty {
        root = element
      } else {
        stack[stack.count - 1].children.append(.element(element))
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      append(.text(string), parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
      append(.text(String(decoding: cdataBlock, as: UTF8.self)), parser: parser)
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
      append(.comment(comment), parser: parser)
    }

    func parser(
      _ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?
    ) -> Data? {
      nil
    }

    private func append(_ node: Node, parser: XMLParser) {
      guard !stack.isEmpty else { return }
      nodeCount += 1
      guard nodeCount <= JPEGXMPPacket.maximumXMLNodes else {
        failure = "The XMP node count exceeds safety limits"
        parser.abortParsing()
        return
      }
      stack[stack.count - 1].children.append(node)
    }
  }
}
