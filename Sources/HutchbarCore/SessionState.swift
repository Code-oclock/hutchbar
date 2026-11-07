// SPDX-License-Identifier: GPL-3.0-or-later
public enum SessionState: String, CaseIterable, Sendable, Codable {
  case running
  case waitingForInput
  case waitingForApproval
  case finished
}

public enum HutchbarVersion {
  public static let current = "0.0.1"
}
