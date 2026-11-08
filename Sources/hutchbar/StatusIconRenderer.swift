// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import HutchbarCore

/// Renders the menu bar status item image according to the status icon model.
public enum StatusIconRenderer {
  private static let canvasHeight: CGFloat = 22.0
  private static let ringDiameter: CGFloat = 10.0
  private static let ringLineWidth: CGFloat = 1.5
  private static let spacing: CGFloat = 4.0
  private static let sidePadding: CGFloat = 2.0

  public static func model(waitingCount: Int, quotaPercent: Double?) -> StatusIconModel {
    StatusIconModel(waitingCount: waitingCount, quotaPercent: quotaPercent)
  }

  public static func image(waitingCount: Int, quotaPercent: Double?) -> NSImage {
    let iconModel = model(waitingCount: waitingCount, quotaPercent: quotaPercent)
    return image(for: iconModel)
  }

  public static func image(for model: StatusIconModel) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    let fallbackSize = NSSize(width: 16.0, height: 12.0)
    let baseSymbol = NSImage(
      systemSymbolName: "terminal",
      accessibilityDescription: "Hutchbar"
    )
    let symbolImage =
      baseSymbol?.withSymbolConfiguration(config)
      ?? NSImage(size: fallbackSize)
    let symbolSize = symbolImage.size

    let textAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
    ]

    var textSize = NSSize.zero
    if let text = model.text {
      textSize = (text as NSString).size(withAttributes: textAttributes)
    }

    var totalWidth = sidePadding + symbolSize.width
    if model.text != nil {
      totalWidth += spacing + textSize.width
    }
    if model.ringPercent != nil {
      totalWidth += spacing + ringDiameter
    }
    totalWidth += sidePadding
    let roundedWidth = ceil(totalWidth)

    let imageSize = NSSize(width: roundedWidth, height: canvasHeight)
    let resultImage = NSImage(size: imageSize, flipped: false) { _ in
      var currentX = sidePadding

      let symbolY = (canvasHeight - symbolSize.height) / 2.0
      let symbolRect = NSRect(
        x: currentX,
        y: symbolY,
        width: symbolSize.width,
        height: symbolSize.height
      )
      symbolImage.draw(in: symbolRect)
      currentX += symbolSize.width

      if let text = model.text {
        currentX += spacing
        let textY = (canvasHeight - textSize.height) / 2.0
        let textRect = NSRect(
          x: currentX,
          y: textY,
          width: textSize.width,
          height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: textAttributes)
        currentX += textSize.width
      }

      if let percent = model.ringPercent {
        currentX += spacing
        let ringY = (canvasHeight - ringDiameter) / 2.0
        let ringRect = NSRect(
          x: currentX,
          y: ringY,
          width: ringDiameter,
          height: ringDiameter
        )
        drawRing(in: ringRect, percent: percent, level: model.ringLevel)
        currentX += ringDiameter
      }
      return true
    }

    resultImage.isTemplate = (model.ringLevel == .normal)
    return resultImage
  }

  private static func drawRing(in rect: NSRect, percent: Double, level: StatusRingLevel) {
    let clampedPercent = max(0.0, min(100.0, percent))
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = (rect.width - ringLineWidth) / 2.0

    let trackColor: NSColor
    let arcColor: NSColor
    switch level {
    case .critical:
      trackColor = NSColor.systemRed.withAlphaComponent(0.25)
      arcColor = NSColor.systemRed
    case .warning:
      trackColor = NSColor.systemOrange.withAlphaComponent(0.25)
      arcColor = NSColor.systemOrange
    case .normal:
      trackColor = NSColor.labelColor.withAlphaComponent(0.25)
      arcColor = NSColor.labelColor
    }

    let trackPath = NSBezierPath(
      ovalIn: rect.insetBy(dx: ringLineWidth / 2.0, dy: ringLineWidth / 2.0)
    )
    trackPath.lineWidth = ringLineWidth
    trackColor.setStroke()
    trackPath.stroke()

    guard clampedPercent > 0.0 else { return }

    let startAngle: CGFloat = 90.0
    let sweep = (clampedPercent / 100.0) * 360.0
    let endAngle = startAngle - sweep

    let arcPath = NSBezierPath()
    arcPath.appendArc(
      withCenter: center,
      radius: radius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: true
    )
    arcPath.lineWidth = ringLineWidth
    arcPath.lineCapStyle = .round
    arcColor.setStroke()
    arcPath.stroke()
  }
}
