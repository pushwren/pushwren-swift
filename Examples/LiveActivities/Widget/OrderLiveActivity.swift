import ActivityKit
import SwiftUI
import WidgetKit

/// How an order looks on the Lock Screen and in the Dynamic Island.
struct OrderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrderAttributes.self) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("Order \(context.attributes.orderNumber)").font(.headline)
                Text(context.state.status)
                if context.state.etaMinutes > 0 {
                    Text("Ready in about \(context.state.etaMinutes) min").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.orderNumber).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.etaMinutes > 0 { Text("\(context.state.etaMinutes) min") }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status)
                }
            } compactLeading: {
                Image(systemName: "bag")
            } compactTrailing: {
                Text(context.state.etaMinutes > 0 ? "\(context.state.etaMinutes)m" : "")
            } minimal: {
                Image(systemName: "bag")
            }
        }
    }
}
