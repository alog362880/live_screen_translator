import ActivityKit
import WidgetKit
import SwiftUI

/// Lives inside the Widget Extension target (create via Xcode: File > New
/// > Target > Widget Extension, check "Include Live Activity"). Renders
/// both the Lock Screen banner and the Dynamic Island states for a
/// running translation session.
struct ScreenTranslateLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScreenTranslateActivityAttributes.self) { context in
            // Lock Screen / banner UI
            HStack {
                Image(systemName: "translate")
                VStack(alignment: .leading) {
                    Text("Screen Translate").font(.caption).foregroundStyle(.secondary)
                    Text(context.state.summaryText).font(.body).lineLimit(2)
                }
                Spacer()
                Text("\(context.state.blockCount)").font(.caption).foregroundStyle(.secondary)
            }
            .padding()

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "translate")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.blockCount) blocks")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.summaryText).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "translate")
            } compactTrailing: {
                Text("\(context.state.blockCount)")
            } minimal: {
                Image(systemName: "translate")
            }
        }
    }
}
