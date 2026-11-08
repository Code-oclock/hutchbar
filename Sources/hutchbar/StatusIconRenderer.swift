// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import HutchbarCore

/// Renders the menu bar status item: the monochrome hutch logo plus the number of
/// sessions waiting for the user. Quotas live in the panel, not in the menu bar.
///
/// - nobody waits: the logo alone, as a template image;
/// - only "your turn": the logo and a plain number, still a template image;
/// - someone waits for an approval: the number sits in an orange pill.
public enum StatusIconRenderer {
  private static let canvasHeight: CGFloat = 22.0
  private static let logoSide: CGFloat = 16.0
  private static let logoStroke: CGFloat = 1.6
  private static let spacing: CGFloat = 3.0
  private static let sidePadding: CGFloat = 1.0
  private static let pillHeight: CGFloat = 14.0
  private static let pillPadding: CGFloat = 5.0

  public static func image(for model: StatusIconModel) -> NSImage {
    let count = max(0, model.waitingCount)
    let countText = count > 99 ? "99+" : "\(count)"
    let usesPill = count > 0 && model.pillStyle == .approval
    let attributes = textAttributes(inPill: usesPill)
    let textSize = (countText as NSString).size(withAttributes: attributes)
    let badgeWidth =
      usesPill ? max(pillHeight, ceil(textSize.width + pillPadding * 2)) : ceil(textSize.width)

    var width = sidePadding + logoSide + sidePadding
    if count > 0 { width += spacing + badgeWidth }

    let size = NSSize(width: ceil(width), height: canvasHeight)
    let result = NSImage(size: size, flipped: true) { _ in
      drawLogo(originX: sidePadding, originY: (canvasHeight - logoSide) / 2.0)
      guard count > 0 else { return true }
      let badgeX = sidePadding + logoSide + spacing
      if usesPill {
        drawPill(originX: badgeX, width: badgeWidth)
      }
      let textX = badgeX + (badgeWidth - textSize.width) / 2.0
      let textY = (canvasHeight - textSize.height) / 2.0
      (countText as NSString).draw(
        in: NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height),
        withAttributes: attributes
      )
      return true
    }
    result.isTemplate = !usesPill
    result.accessibilityDescription = accessibilityText(count: count, approval: usesPill)
    return result
  }

  private static func textAttributes(inPill: Bool) -> [NSAttributedString.Key: Any] {
    [
      .font: NSFont.monospacedDigitSystemFont(ofSize: inPill ? 10.0 : 12.0, weight: .semibold),
      .foregroundColor: inPill ? NSColor.white : NSColor.labelColor,
    ]
  }

  /// The house from `mockup/panel-v3.html`, in its 16×16 SVG coordinates (y grows down).
  private static func drawLogo(originX: CGFloat, originY: CGFloat) {
    func point(_ xCoord: CGFloat, _ yCoord: CGFloat) -> NSPoint {
      NSPoint(x: originX + xCoord, y: originY + yCoord)
    }
    let house = NSBezierPath()
    house.move(to: point(2.5, 7.5))
    house.line(to: point(8.0, 3.0))
    house.line(to: point(13.5, 7.5))
    house.line(to: point(13.5, 13.0))
    house.curve(
      to: point(13.0, 13.5), controlPoint1: point(13.5, 13.28), controlPoint2: point(13.28, 13.5))
    house.line(to: point(3.0, 13.5))
    house.curve(
      to: point(2.5, 13.0), controlPoint1: point(2.72, 13.5), controlPoint2: point(2.5, 13.28))
    house.close()

    let door = NSBezierPath()
    door.move(to: point(6.0, 13.5))
    door.line(to: point(6.0, 10.0))
    door.line(to: point(10.0, 10.0))
    door.line(to: point(10.0, 13.5))

    NSColor.labelColor.setStroke()
    for path in [house, door] {
      path.lineWidth = logoStroke
      path.lineJoinStyle = .round
      path.lineCapStyle = .round
      path.stroke()
    }
  }

  private static func drawPill(originX: CGFloat, width: CGFloat) {
    let rect = NSRect(
      x: originX, y: (canvasHeight - pillHeight) / 2.0, width: width, height: pillHeight)
    NSColor.systemOrange.setFill()
    NSBezierPath(roundedRect: rect, xRadius: pillHeight / 2.0, yRadius: pillHeight / 2.0).fill()
  }

  private static func accessibilityText(count: Int, approval: Bool) -> String {
    guard count > 0 else { return "Hutchbar" }
    return approval ? "Hutchbar: \(count) waiting, approval needed" : "Hutchbar: \(count) waiting"
  }
}

// MARK: - Offline rendering (`hutchbar --render-icon <dir>`)

extension StatusIconRenderer {
  /// Writes the menu bar icon states as 4× PNGs on a light and a dark menu bar,
  /// so the icon can be checked without starting the app.
  @MainActor
  public static func renderSamples(to directory: String) -> Bool {
    func waiting(_ count: Int, _ style: PillStyle) -> StatusIconModel {
      StatusIconModel(
        sessionRemaining: nil, weekRemaining: nil, waitingCount: count, pillStyle: style)
    }
    let samples: [(String, StatusIconModel)] = [
      ("idle", waiting(0, .none)),
      ("turn-3", waiting(3, .yourTurn)),
      ("approval-2", waiting(2, .approval)),
      ("approval-120", waiting(120, .approval)),
    ]
    let appearances: [(String, NSAppearance.Name, NSColor)] = [
      ("light", .aqua, NSColor(white: 0.93, alpha: 1)),
      ("dark", .darkAqua, NSColor(white: 0.16, alpha: 1)),
    ]
    for (name, model) in samples {
      for (suffix, appearanceName, background) in appearances {
        let path = (directory as NSString).appendingPathComponent("icon-\(name)-\(suffix).png")
        guard let appearance = NSAppearance(named: appearanceName),
          writeSample(image(for: model), appearance: appearance, background: background, to: path)
        else { return false }
      }
    }
    return true
  }

  @MainActor
  private static func writeSample(
    _ icon: NSImage,
    appearance: NSAppearance,
    background: NSColor,
    to path: String
  ) -> Bool {
    let scale: CGFloat = 4.0
    let pixelsWide = Int(ceil(icon.size.width + 8) * scale)
    let pixelsHigh = Int(icon.size.height * scale)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return false }
    // Points, not pixels: the context then scales every drawing by `scale`.
    bitmap.size = NSSize(width: CGFloat(pixelsWide) / scale, height: icon.size.height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }

    var drawn = true
    appearance.performAsCurrentDrawingAppearance {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      background.setFill()
      NSRect(origin: .zero, size: bitmap.size).fill()
      let iconRect = NSRect(x: 4, y: 0, width: icon.size.width, height: icon.size.height)
      // The drawing handler uses `labelColor`, which follows the current drawing
      // appearance — close enough to how the menu bar tints a template image.
      icon.draw(in: iconRect)
      NSGraphicsContext.restoreGraphicsState()
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        drawn = false
        return
      }
      drawn = (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
    return drawn
  }
}
