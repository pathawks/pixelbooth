import Foundation

/// Shared source/output reservation policy for GUI and command-line captures.
enum CaptureStagingCapacity {
  /// Reserve local source JSON, a conservative encoded output allowance, the
  /// temporary output used by atomic finalization, and bounded journal space.
  /// The limit is checked before creating the per-capture directory so a
  /// refused capture leaves no orphan staging folder.
  static func reservation(
    for capture: CapturedCapture, encodedSourceBytes: Int
  ) throws -> UInt64 {
    let sourceBytes: UInt64
    switch capture.payload {
    case .jpegBytes(let bytes):
      sourceBytes = UInt64(bytes.count)
    case .planes(let snapshot):
      sourceBytes = try snapshot.contiguous.reduce(into: UInt64(0)) { total, plane in
        let (next, overflow) = total.addingReportingOverflow(UInt64(plane.count))
        guard !overflow else { throw SaveQueueActor.QueueError.capacityExceeded }
        total = next
      }
    }
    let (doubledOutput, outputOverflow) = sourceBytes.multipliedReportingOverflow(by: 2)
    guard !outputOverflow else { throw SaveQueueActor.QueueError.capacityExceeded }
    var outputReserve = max(doubledOutput, 4 * 1024 * 1024)
    if capture.metadata.attachmentArchive != nil || capture.metadata.deviceIdentity != nil
      || capture.metadata.streamColorObservations != nil
    {
      let metadataBytes = try JSONEncoder().encode(capture.metadata).count
      let (metadataReserve, overflow) = UInt64(metadataBytes).multipliedReportingOverflow(by: 8)
      let (withMetadata, additionOverflow) = outputReserve.addingReportingOverflow(metadataReserve)
      guard !overflow, !additionOverflow else { throw SaveQueueActor.QueueError.capacityExceeded }
      outputReserve = withMetadata
    }
    if case .planes = capture.payload, capture.metadata.includeEstimatedDisparity == true {
      // Configurations allow at most 1,048,576 gray8 samples. Include a
      // conservative encoding/metadata allowance for output and its atomic copy.
      let (withDisparity, overflow) = outputReserve.addingReportingOverflow(2 * 1024 * 1024)
      guard !overflow else { throw SaveQueueActor.QueueError.capacityExceeded }
      outputReserve = withDisparity
    }
    let (sourceAndOutput, firstOverflow) = UInt64(encodedSourceBytes).addingReportingOverflow(
      outputReserve)
    let (withTemporary, secondOverflow) = sourceAndOutput.addingReportingOverflow(outputReserve)
    let (required, thirdOverflow) = withTemporary.addingReportingOverflow(2 * 1024 * 1024)
    guard !firstOverflow, !secondOverflow, !thirdOverflow else {
      throw SaveQueueActor.QueueError.capacityExceeded
    }
    return required
  }

}
