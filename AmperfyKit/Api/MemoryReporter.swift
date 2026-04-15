//
//  MemoryReporter.swift
//  AmperfyKit
//
//  Memory diagnostics utility for tracking footprint during background sync.
//

import Foundation

public enum MemoryReporter {
  /// File URL for crash-surviving log.
  private static let logFileURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("memdiag.log")
  }()

  /// Returns the phys_footprint — this is what Jetsam actually uses to decide kills.
  public static func currentFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.phys_footprint)
  }

  /// Returns the current resident set size (physical memory) in bytes, or nil on failure.
  public static func currentResidentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return info.resident_size
  }

  /// Clears the log file at start of a new session.
  public static func clearLog() {
    try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
  }

  /// Logs to NSLog (for idevicesyslog) AND appends to a file (survives crash).
  public static func logMemory(label: String) {
    let footprintMB: Double
    let rssMB: Double
    if let footprint = currentFootprintBytes() {
      footprintMB = Double(footprint) / (1024 * 1024)
    } else {
      footprintMB = -1
    }
    if let rss = currentResidentBytes() {
      rssMB = Double(rss) / (1024 * 1024)
    } else {
      rssMB = -1
    }

    let message = String(
      format: "[MEMDIAG] %@ -- footprint: %.1f MB, RSS: %.1f MB",
      label, footprintMB, rssMB
    )

    // NSLog for live streaming via idevicesyslog
    NSLog("%@", message)

    // Append to file (survives SIGKILL)
    let timestamped = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = timestamped.data(using: .utf8) {
      if FileManager.default.fileExists(atPath: logFileURL.path) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
          handle.seekToEndOfFile()
          handle.write(data)
          handle.closeFile()
        }
      } else {
        try? data.write(to: logFileURL)
      }
    }
  }
}
