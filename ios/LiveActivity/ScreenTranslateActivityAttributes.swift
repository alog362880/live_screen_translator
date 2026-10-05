import ActivityKit

/// Shared between the Runner app target and the Widget Extension target
/// (add this file to BOTH targets in Xcode's File Inspector -> Target
/// Membership — ActivityKit requires the attributes type to be visible
/// to whichever process starts/updates/ends the Activity).
struct ScreenTranslateActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var summaryText: String
        var blockCount: Int
    }
}
