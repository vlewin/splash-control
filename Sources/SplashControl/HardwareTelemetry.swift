import Foundation
import IOKit

/// Native sampler for macOS GPU and Apple Neural Engine (ANE) hardware utilization.
/// - GPU: Sampled via IOKit `IOAccelerator` (`Device Utilization %`).
/// - ANE: Sampled via `libIOReport` (`Energy Model` ANE energy integration over time / peak wattage).
final class HardwareTelemetry {
  static let shared = HardwareTelemetry()

  private typealias CopyChannelsFunc =
    @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
  private typealias CreateSubFunc =
    @convention(c) (
      UnsafeMutableRawPointer?, CFMutableDictionary,
      UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
    ) -> OpaquePointer?
  private typealias CreateSamplesFunc =
    @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  private typealias GetChannelFunc = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
  private typealias GetUnitFunc = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
  private typealias GetIntFunc = @convention(c) (CFDictionary, Int32) -> Int64

  private let copyChannels: CopyChannelsFunc?
  private let createSub: CreateSubFunc?
  private let createSamples: CreateSamplesFunc?
  private let getChannel: GetChannelFunc?
  private let getUnit: GetUnitFunc?
  private let getInt: GetIntFunc?

  private var aneChannels: CFMutableDictionary?
  private var aneSubscription: OpaquePointer?
  private var prevANEEnergy: Double = 0
  private var prevANETime: Date?
  /// Apple Silicon nominal ANE max power rating (Watts) for utilization normalization.
  private let aneMaxWatts: Double = 8.0

  init() {
    if let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) {
      copyChannels = unsafeBitCast(
        dlsym(lib, "IOReportCopyChannelsInGroup"), to: CopyChannelsFunc.self)
      createSub = unsafeBitCast(dlsym(lib, "IOReportCreateSubscription"), to: CreateSubFunc.self)
      createSamples = unsafeBitCast(dlsym(lib, "IOReportCreateSamples"), to: CreateSamplesFunc.self)
      getChannel = unsafeBitCast(
        dlsym(lib, "IOReportChannelGetChannelName"), to: GetChannelFunc.self)
      getUnit = unsafeBitCast(dlsym(lib, "IOReportChannelGetUnitLabel"), to: GetUnitFunc.self)
      getInt = unsafeBitCast(dlsym(lib, "IOReportSimpleGetIntegerValue"), to: GetIntFunc.self)
      setupANE()
    } else {
      copyChannels = nil
      createSub = nil
      createSamples = nil
      getChannel = nil
      getUnit = nil
      getInt = nil
    }
  }

  private func setupANE() {
    guard let copyChannels = copyChannels,
      let createSub = createSub,
      let raw = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
    else { return }

    let count = CFDictionaryGetCount(raw)
    guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, count, raw) else {
      return
    }
    var subDict: Unmanaged<CFMutableDictionary>?
    if let sub = createSub(nil, mutable, &subDict, 0, nil) {
      self.aneChannels = mutable
      self.aneSubscription = sub
      subDict?.release()
    }
  }

  /// System GPU utilization percentage (0–100%).
  func sampleGPU() -> Double? {
    var iter = io_iterator_t()
    let match = IOServiceMatching("IOAccelerator")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == kIOReturnSuccess else {
      return nil
    }
    defer { IOObjectRelease(iter) }
    var service = IOIteratorNext(iter)
    while service != 0 {
      defer {
        IOObjectRelease(service)
        service = IOIteratorNext(iter)
      }
      var props: Unmanaged<CFMutableDictionary>?
      if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        == kIOReturnSuccess,
        let dict = props?.takeRetainedValue() as? [String: Any],
        let stats = dict["PerformanceStatistics"] as? [String: Any]
      {
        if let dev = stats["Device Utilization %"] as? NSNumber {
          return min(100.0, max(0.0, dev.doubleValue))
        }
      }
    }
    return nil
  }

  /// System Apple Neural Engine utilization percentage (0–100%).
  func sampleANE() -> Double? {
    guard let sub = aneSubscription,
      let channels = aneChannels,
      let createSamples = createSamples,
      let getChannel = getChannel,
      let getUnit = getUnit,
      let getInt = getInt,
      let sampleRef = createSamples(sub, channels, nil)?.takeRetainedValue() as? [String: Any],
      let list = sampleRef["IOReportChannels"] as? NSArray
    else { return nil }

    let items = list as CFArray
    var energySum: Double = 0
    var found = false

    for i in 0..<CFArrayGetCount(items) {
      let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
      if let ch = getChannel(item)?.takeUnretainedValue() as String?, ch.starts(with: "ANE") {
        let raw = Double(getInt(item, 0))
        let unit =
          (getUnit(item)?.takeUnretainedValue() as String?)?
          .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let joules: Double
        switch unit {
        case "mj": joules = raw / 1e3
        case "uj", "µj": joules = raw / 1e6
        case "nj": joules = raw / 1e9
        case "pj": joules = raw / 1e12
        default: joules = raw / 1e9
        }
        energySum += joules
        found = true
      }
    }
    guard found else { return nil }
    let now = Date()
    defer {
      prevANEEnergy = energySum
      prevANETime = now
    }
    guard let prevTime = prevANETime else { return 0 }
    let dt = now.timeIntervalSince(prevTime)
    guard dt > 0 else { return 0 }
    let powerWatts = (energySum - prevANEEnergy) / dt
    let utilPct = min(100.0, max(0.0, (powerWatts / aneMaxWatts) * 100.0))
    return utilPct
  }
}
