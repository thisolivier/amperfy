//
//  MemoryReporter.swift
//  AmperfyKit
//
//  Memory diagnostics utility for tracking RSS during background sync.
//

import Foundation
import os.log

public enum MemoryReporter {
  private static let log = OSLog(subsystem: "Amperfy", category: "Memory")

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

  /// Logs the current RSS with an identifying label.
  public static func logMemory(label: String) {
    guard let bytes = currentResidentBytes() else {
      os_log("[Memory] %{public}@ — unable to read", log: log, type: .info, label)
      return
    }
    let megabytes = Double(bytes) / (1024 * 1024)
    os_log("[Memory] %{public}@ — %.1f MB", log: log, type: .info, label, megabytes)
  }
}
