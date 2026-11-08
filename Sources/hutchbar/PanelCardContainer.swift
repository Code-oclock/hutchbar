// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

extension PanelColorToken {
  var color: Color {
    switch self {
    case .orange:
      return .orange
    case .blue:
      return .blue
    case .red:
      return .red
    case .green:
      return .green
    case .purple:
      return .purple
    case .teal:
      return .teal
    case .secondary:
      return .secondary
    }
  }
}

/// Card container for Panel v2 displaying content inside a rounded container with subtle border.
struct PanelCardView<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}
