// Shared singletons: the save queue actor is process-wide so journal
// reconciliation works across window lifetimes.

import Foundation
import PixelBoothLibrary

final class SaveQueueHolder: @unchecked Sendable {
  static let shared = SaveQueueHolder()
  let queue: SaveQueueActor

  private init() {
    queue = SaveQueueActor()
  }
}
