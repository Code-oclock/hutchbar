// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import HutchbarCore

/// Renders the menu bar status item image according to the status icon model.
public enum StatusIconRenderer {
  private static let canvasHeight: CGFloat = 22.0
  private static let barWidth: CGFloat = 18.0
  private static let barHeight: CGFloat = 3.0
  private static let barRadius: CGFloat = 1.5
  private static let barGap: CGFloat = 2.0
  private static let dotDiameter: CGFloat = 6.0
  private static let pillHeight: CGFloat = 14.0
  private static let pillRadius: CGFloat = 7.0
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
    let hasQuotas = (model.sessionRemaining != nil || model.weekRemaining != nil)
    let hasPill = model.waitingCount > 0

    let countText = "\(model.waitingCount)"
    let textAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .bold),
      .foregroundColor: NSColor.white,
    ]
    let textSize = (countText as NSString).size(withAttributes: textAttributes)
    let pillWidth = max(pillHeight, ceil(textSize.width + 10.0))

    var contentWidth: CGFloat = 0.0
    if hasQuotas {
      contentWidth += barWidth
      if hasPill {
        contentWidth += spacing + pillWidth
      }
    } else {
      contentWidth += hasPill ? pillWidth : dotDiameter
    }

    let totalWidth = sidePadding + contentWidth + sidePadding
    let imageSize = NSSize(width: ceil(totalWidth), height: canvasHeight)

    let resultImage = NSImage(size: imageSize, flipped: false) { _ in
      var currentX = sidePadding

      if hasQuotas {
        let sessionCritical =
          (model.sessionRemaining != nil && (model.sessionRemaining ?? 0.0) < 10.0)
        let weekCritical = (model.weekRemaining != nil && (model.weekRemaining ?? 0.0) < 10.0)

        // Session remaining on top (y = 12)
        drawBar(
          originX: currentX, originY: 12.0, remaining: model.sessionRemaining,
          isCritical: sessionCritical)
        // Week remaining on bottom (y = 7)
        drawBar(
          originX: currentX, originY: 7.0, remaining: model.weekRemaining, isCritical: weekCritical)
        currentX += barWidth

        if hasPill {
          currentX += spacing
          drawPill(
            at: currentX,
            width: pillWidth,
            text: countText,
            textSize: textSize,
            attributes: textAttributes,
            style: model.pillStyle
          )
        }
      } else {
        if hasPill {
          drawPill(
            at: currentX,
            width: pillWidth,
            text: countText,
            textSize: textSize,
            attributes: textAttributes,
            style: model.pillStyle
          )
        } else {
          drawNeutralDot(at: currentX)
        }
      }

      return true
    }

    let sessionCritical = (model.sessionRemaining != nil && (model.sessionRemaining ?? 0.0) < 10.0)
    let weekCritical = (model.weekRemaining != nil && (model.weekRemaining ?? 0.0) < 10.0)
    let hasRedBar = hasQuotas && (sessionCritical || weekCritical)
    resultImage.isTemplate = !hasRedBar && !hasPill
    resultImage.accessibilityDescription = "Hutchbar"
    return resultImage
  }

  private static func drawBar(
    originX: CGFloat,
    originY: CGFloat,
    remaining: Double?,
    isCritical: Bool
  ) {
    let barRect = NSRect(x: originX, y: originY, width: barWidth, height: barHeight)
    let barColor = isCritical ? NSColor.systemRed : NSColor.labelColor
    let trackColor = barColor.withAlphaComponent(0.25)

    let trackPath = NSBezierPath(
      roundedRect: barRect,
      xRadius: barRadius,
      yRadius: barRadius
    )
    trackColor.setFill()
    trackPath.fill()

    guard let remaining, remaining > 0.0 else { return }
    let clampedRemaining = max(0.0, min(100.0, remaining))
    let fillWidth = (clampedRemaining / 100.0) * barWidth
    guard fillWidth > 0.0 else { return }

    let fillRect = NSRect(x: originX, y: originY, width: fillWidth, height: barHeight)
    NSGraphicsContext.current?.saveGraphicsState()
    trackPath.addClip()
    barColor.setFill()
    fillRect.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  private static func drawPill(
    at originX: CGFloat,
    width: CGFloat,
    text: String,
    textSize: NSSize,
    attributes: [NSAttributedString.Key: Any],
    style: PillStyle
  ) {
    let pillY = (canvasHeight - pillHeight) / 2.0
    let pillRect = NSRect(x: originX, y: pillY, width: width, height: pillHeight)
    let pillPath = NSBezierPath(
      roundedRect: pillRect,
      xRadius: pillRadius,
      yRadius: pillRadius
    )
    let pillColor = (style == .approval) ? NSColor.systemOrange : NSColor.systemBlue
    pillColor.setFill()
    pillPath.fill()

    let textX = pillRect.minX + (pillRect.width - textSize.width) / 2.0
    let textY = pillRect.minY + (pillRect.height - textSize.height) / 2.0
    (text as NSString).draw(
      in: NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height),
      withAttributes: attributes
    )
  }

  private static func drawNeutralDot(at originX: CGFloat) {
    let dotY = (canvasHeight - dotDiameter) / 2.0
    let dotRect = NSRect(x: originX, y: dotY, width: dotDiameter, height: dotDiameter)
    let dotPath = NSBezierPath(ovalIn: dotRect)
    NSColor.labelColor.withAlphaComponent(0.6).setFill()
    dotPath.fill()
  }
}
