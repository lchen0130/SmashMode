import Foundation
import IOKit
import IOKit.hid

typealias AccelerometerCallback = (_ x: Float, _ y: Float, _ z: Float) -> Void

// ── Constants (from taigrr/apple-silicon-accelerometer/sensor/constants.go) ──
// The Bosch BMI286 SPU accelerometer lives on Apple's vendor page, not 0x0020.
private let kPageVendor: Int = 0xFF00
private let kUsageAccel: Int = 3

// 22-byte IMU report: bytes 0-5 = header, bytes 6-17 = XYZ (int32 LE each)
private let kIMUDataOffset = 6

// ─────────────────────────────────────────────────────────────────────────────

/// Reads X/Y/Z acceleration from the Bosch BMI286 IMU via IOKit HID.
/// Must run as root.
///
/// Follows the exact pattern from taigrr/apple-silicon-accelerometer:
///   1. Wake "AppleSPUHIDDriver" services
///   2. Enumerate "AppleSPUHIDDevice" services
///   3. For each matching device: open → register callback → schedule
final class AccelerometerReader {

    // Stable C heap allocation — IOKit holds this pointer asynchronously.
    // Swift's &array only pins for the call duration; this lives forever.
    private let reportBuffer: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        p.initialize(repeating: 0, count: 4096)
        return p
    }()
    private let userCallback: AccelerometerCallback

    // Keep opened devices alive for the duration of the run loop
    private var openDevices: [IOHIDDevice] = []

    init(callback: @escaping AccelerometerCallback) {
        self.userCallback = callback
    }

    // MARK: - Public API

    func start() throws {
        wakeSPUDrivers()
        let found = try registerHIDDevices()
        guard found else {
            throw AccelerometerError.deviceNotFound
        }
    }

    // MARK: - SPU wake

    /// Poke "AppleSPUHIDDriver" (the driver service, not the HID device service).
    private func wakeSPUDrivers() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSPUHIDDriver"),
                                           &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }

        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            func setI32(_ key: String, _ val: Int32) {
                var v = val
                guard let n = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) else { return }
                IORegistryEntrySetCFProperty(svc, key as CFString, n)
            }
            setI32("SensorPropertyReportingState", 1)
            setI32("SensorPropertyPowerState",     1)
            setI32("ReportInterval",               1000)
        }
    }

    // MARK: - Device registration

    /// Enumerate "AppleSPUHIDDevice" services, filter to accelerometer,
    /// then open → register callback → schedule (exact Go source order).
    private func registerHIDDevices() throws -> Bool {
        var it: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("AppleSPUHIDDevice"),
                                              &it)
        guard kr == KERN_SUCCESS else {
            throw AccelerometerError.serviceNotFound(kr)
        }
        defer { IOObjectRelease(it) }

        var found = false
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }

            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else { continue }

            let page  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey     as CFString) as? Int ?? -1
            guard page == kPageVendor && usage == kUsageAccel else { continue }

            // ── Go source order: open → register callback → schedule ──────────

            let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard ret == kIOReturnSuccess else {
                fputs("[AccelerometerReader] IOHIDDeviceOpen failed: \(ret). Try sudo.\n", stderr)
                continue
            }

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                device,
                reportBuffer,
                CFIndex(4096),
                { ctx, _, _, _, _, report, reportLength in
                    guard let ctx else { return }
                    let me = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
                    me.handleReport(report: report, length: Int(reportLength))
                },
                selfPtr
            )

            IOHIDDeviceScheduleWithRunLoop(
                device,
                CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )

            openDevices.append(device)
            found = true
            print("[AccelerometerReader] Accelerometer opened.")
            break
        }

        return found
    }

    // MARK: - Report parsing

    private func handleReport(report: UnsafePointer<UInt8>, length: Int) {
        guard length >= kIMUDataOffset + 12 else { return }

        func readI32(_ offset: Int) -> Int32 {
            let b = (0..<4).map { Int32(report[offset + $0]) }
            return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        }

        let x = Float(readI32(kIMUDataOffset + 0)) / 65536.0
        let y = Float(readI32(kIMUDataOffset + 4)) / 65536.0
        let z = Float(readI32(kIMUDataOffset + 8)) / 65536.0

        userCallback(x, y, z)
    }
}

// MARK: - Errors

enum AccelerometerError: Error {
    case serviceNotFound(kern_return_t)
    case deviceNotFound
}
