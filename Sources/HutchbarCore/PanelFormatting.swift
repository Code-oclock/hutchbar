// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure formatting functions for the Hutchbar panel and attention pill.

/// Formats waiting duration for session rows (for example, "just now", "4 min", "2h 15m", "3d").
public func formatWaitingTime(since: Date?, now: Date = Date()) -> String {
  guard let since else { return "" }
  let elapsed = now.timeIntervalSince(since)
  if elapsed < 60 {
    return "just now"
  }
  let minutes = Int(elapsed / 60)
  if minutes < 60 {
    return "\(minutes) min"
  }
  let hours = minutes / 60
  let remMinutes = minutes % 60
  if hours < 24 {
    if remMinutes == 0 {
      return "\(hours)h"
    }
    return "\(hours)h \(remMinutes)m"
  }
  let days = hours / 24
  return "\(days)d"
}

/// Formats compact duration for the attention pill (for example, "2m", "1h", "2d").
public func formatPillDuration(since: Date?, now: Date = Date()) -> String {
  guard let since else { return "" }
  let elapsed = max(0, now.timeIntervalSince(since))
  let minutes = Int(elapsed / 60)
  if minutes < 60 {
    return "\(minutes)m"
  }
  let hours = minutes / 60
  let remMinutes = minutes % 60
  if hours < 24 {
    if remMinutes == 0 {
      return "\(hours)h"
    }
    return "\(hours)h \(remMinutes)m"
  }
  let days = hours / 24
  return "\(days)d"
}

/// Formats quota utilization percentage (for example, "85%", "25.5%", "0%").
public func formatPercent(_ percent: Double) -> String {
  let clamped = min(max(percent, 0.0), 100.0)
  let rounded = (clamped * 10).rounded() / 10
  if rounded.truncatingRemainder(dividingBy: 1) == 0 {
    return "\(Int(rounded))%"
  }
  return String(format: "%.1f%%", rounded)
}

/// Formats quota window reset time ("↻ 21:30" today, "↻ Wed" later).
public func formatQuotaReset(
  resetsAt: Date?,
  now: Date = Date(),
  calendar: Calendar = Calendar(identifier: .gregorian),
  timeZone: TimeZone = .current,
  locale: Locale = Locale(identifier: "en_US_POSIX")
) -> String? {
  guard let resetsAt else { return nil }
  var cal = calendar
  cal.timeZone = timeZone
  cal.locale = locale

  let formatter = DateFormatter()
  formatter.calendar = cal
  formatter.timeZone = timeZone
  formatter.locale = locale

  if cal.isDate(resetsAt, inSameDayAs: now) {
    formatter.dateFormat = "HH:mm"
    return "↻ \(formatter.string(from: resetsAt))"
  }
  formatter.dateFormat = "EEE"
  return "↻ \(formatter.string(from: resetsAt))"
}

/// Returns human-readable state description used in accessibility labels and pill text.
public func sessionStateDescription(_ state: SessionState) -> String {
  switch state {
  case .waitingForApproval:
    return "waiting for approval"
  case .waitingForInput:
    return "waiting for input"
  case .running:
    return "running"
  case .finished:
    return "finished"
  }
}

/// Formats quota window minutes into short duration (for example, 300 -> "5h", 10080 -> "7d").
public func formatQuotaWindowDuration(_ windowMinutes: Int) -> String {
  if windowMinutes == 300 {
    return "5h"
  }
  if windowMinutes == 10080 {
    return "7d"
  }
  if windowMinutes % 60 == 0 {
    return "\(windowMinutes / 60)h"
  }
  return "\(windowMinutes)m"
}
