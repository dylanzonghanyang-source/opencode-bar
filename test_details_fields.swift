#!/usr/bin/env swift
import Foundation

// Simulate XaiSuperGrokProvider logic to verify details fields
let usedPercent: Double = 2.0 // from manual test
let periodType = "USAGE_PERIOD_TYPE_WEEKLY"
let resetDateStr = "2026-08-25T01:47:32.885969+00:00"

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let resetDate = formatter.date(from: resetDateStr)

var details: [String: Any] = [:]

switch periodType.uppercased() {
case "USAGE_PERIOD_TYPE_MONTHLY":
    details["monthlyUsage"] = usedPercent
    details["primaryReset"] = resetDate ?? Date()
case "USAGE_PERIOD_TYPE_DAILY":
    details["dailyUsage"] = usedPercent
    details["primaryReset"] = resetDate ?? Date()
case "USAGE_PERIOD_TYPE_WEEKLY":
    details["sevenDayUsage"] = usedPercent
    details["sevenDayReset"] = resetDate ?? Date()
case "":
    details["mcpUsagePercent"] = usedPercent
    details["mcpUsageReset"] = resetDate ?? Date()
default:
    print("Unknown period type: \(periodType)")
    exit(1)
}

let authPath = NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath
details["authSource"] = authPath

print("Details fields:")
for (k, v) in details.sorted(by: { $0.key < $1.key }) {
    if let d = v as? Date {
        print("  \(k): \(ISO8601DateFormatter().string(from: d))")
    } else if let n = v as? Double {
        print("  \(k): \(n)")
    } else if let s = v as? String {
        print("  \(k): \(s)")
    } else {
        print("  \(k): \(type(of: v))")
    }
}

// Check if expected fields exist for xaiSuperGrok menu builder
let hasSevenDay = details["sevenDayUsage"] != nil
let hasSevenReset = details["sevenDayReset"] != nil
print("\nMenu builder expects:")
print("  sevenDayUsage: \(hasSevenDay ? "YES" : "NO") (value: \(details["sevenDayUsage"] ?? "nil"))")
print("  sevenDayReset: \(hasSevenReset ? "YES" : "NO") (value: \(details["sevenDayReset"] ?? "nil"))")