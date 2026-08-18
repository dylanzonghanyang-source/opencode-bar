#!/usr/bin/env swift
import Foundation

let raw: Int64 = 1787045589462
print("Raw expires: \(raw)")
print("Digits: \(String(raw).count)")

let seconds: Double
if raw > 9_999_999_999 {
    seconds = Double(raw) / 1000.0
    print("Treated as milliseconds")
} else {
    seconds = Double(raw)
    print("Treated as seconds")
}
let date = Date(timeIntervalSince1970: seconds)
print("Parsed date: \(date)")
print("Current date: \(Date())")
print("Expired? \(date < Date())")
print("Done.")