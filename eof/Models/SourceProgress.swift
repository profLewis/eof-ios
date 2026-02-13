import Foundation
import Observation

/// Observable progress for a single data source during a fetch.
@Observable
class SourceProgress: Identifiable {
    let id = UUID()
    let sourceID: SourceID
    let displayName: String
    var totalItems: Int = 0
    var completedItems: Int = 0
    var status: Status = .idle
    var allocatedStreams: Int = 0
    var currentSource: String = ""

    var fraction: Double {
        totalItems > 0 ? Double(completedItems) / Double(totalItems) : 0
    }

    enum Status: String {
        case idle, searching, downloading, done, failed, skipped
    }

    init(sourceID: SourceID, displayName: String) {
        self.sourceID = sourceID
        self.displayName = displayName
    }
}
