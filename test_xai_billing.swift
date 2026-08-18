#!/usr/bin/env swift
import Foundation
// This is a minimal test that mimics XaiSuperGrokProvider.fetch() without depending on the full app
// It only reads auth.json and attempts a real network request to verify the path

let authPath = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".local")
    .appendingPathComponent("share")
    .appendingPathComponent("opencode")
    .appendingPathComponent("auth.json")

print("🔍 Checking auth at: \(authPath.path)")
guard let data = try? Data(contentsOf: authPath),
      let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: [String: Any]],
      let xai = json["xai"],
      let access = (xai as? [String: Any])?["access"] as? String else {
    print("❌ xai OAuth not available or malformed")
    exit(1)
}

print("✓ xai OAuth found (access token prefix: \(String(access.prefix(12)))...)")

// Attempt the real billing request
let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
var req = URLRequest(url: url)
req.httpMethod = "GET"
req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")

print("🔍 Fetching: \(url.absoluteString)")
let sem = DispatchSemaphore(value: 0)
var statusCode: Int?
var error: Error?
var body: Data?

let task = URLSession.shared.dataTask(with: req) { d, r, e in
    if let e { error = e }
    if let r = r as? HTTPURLResponse {
        statusCode = r.statusCode
    }
    body = d
    sem.signal()
}
task.resume()
sem.wait()

if let error {
    print("❌ Network error: \(error.localizedDescription)")
    exit(1)
}
guard let code = statusCode else {
    print("❌ No status code")
    exit(1)
}

print("✓ HTTP status: \(code)")

guard let body, let json2 = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
    print("❌ Non-JSON response or empty body")
    if let str = String(data: body ?? Data(), encoding: .utf8) {
        print("Body preview (first 500): \(String(str.prefix(500)))")
    }
    exit(1)
}

print("✓ Response is JSON")
if let config = json2["config"] as? [String: Any],
   let current = config["currentPeriod"] as? [String: Any] {
    let type = current["type"] as? String ?? "(null)"
    let usage = current["creditUsagePercent"] as? Double
    let end = current["end"] as? String ?? "(null)"
    print("✓ Period type: \(type)")
    print("✓ Usage percent: \(usage.map { String(format: "%.1f", $0) + "%% used" } ?? "(null)")")
    print("✓ Period end: \(end)")
} else {
    print("⚠️ No config/currentPeriod in response")
    print("Full response keys: \(json2.keys.sorted())")
    // Print first 800 chars of response for debugging (no access token)
    if let str = String(data: body, encoding: .utf8) {
        let truncated = String(str.prefix(800))
        // Filter out likely access token lines (Bearer patterns)
        let filtered = truncated.components(separatedBy: "\n").filter { line in
            !line.contains("Bearer ") && !line.contains("access_token") && !line.lowercased().contains("secret")
        }.joined(separator: "\n")
        print("Response preview (filtered, max 800):")
        print(filtered)
    }
}

print("Done.")