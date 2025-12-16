import Foundation
import Shared

/// UI convenience extensions for SearchResult
extension SearchResult {

    // MARK: - Convenience Properties

    /// Convenience access to frameID (maps to id)
    public var frameID: FrameID {
        id
    }

    /// Convenience access to app name from metadata
    public var appName: String? {
        metadata.appName
    }

    /// Convenience access to app bundle ID from metadata
    public var appBundleID: String? {
        metadata.appBundleID
    }

    /// Convenience access to window title from metadata
    public var windowTitle: String? {
        metadata.windowTitle
    }

    /// Convenience access to browser URL from metadata
    public var url: String? {
        metadata.browserURL
    }

    /// Convenience access to relevance score (maps to existing property)
    /// Note: SearchResult already has relevanceScore, this is just for consistency
    public var score: Double {
        relevanceScore
    }

    /// Generate a thumbnail path for this frame
    /// TODO: This should be computed from the actual storage path
    public var thumbnailPath: String? {
        nil  // Will be implemented when we have actual frame loading
    }

    /// Text regions for OCR visualization
    /// TODO: Load from database when needed
    public var textRegions: [TextRegion] {
        []  // Will be loaded dynamically in FrameViewer
    }
}
