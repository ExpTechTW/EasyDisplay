import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over an external monitor's Apple silicon DCP AV service, for monitors that
/// DisplayServices can't dim. All I2C traffic for one monitor goes through one serial queue.
final class DDCChannel: @unchecked Sendable {
    static let brightnessVCP: UInt8 = 0x10

    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let createService = systemSymbol(iokit, "IOAVServiceCreateWithService", as: CreateService.self)
    private static let writeI2C = systemSymbol(iokit, "IOAVServiceWriteI2C", as: TransferI2C.self)
    private static let readI2C = systemSymbol(iokit, "IOAVServiceReadI2C", as: TransferI2C.self)

    private static let chipAddress: UInt32 = 0x37
    private static let hostAddress: UInt8 = 0x51
    private static let displayAddress: UInt8 = 0x6E

    /// Only touched on `queue`.
    private let avService: CFTypeRef
    private let queue: DispatchQueue

    private init(avService: CFTypeRef, name: String) {
        self.avService = avService
        queue = DispatchQueue(label: "EasyDisplay.DDC.\(name)")
    }

    /// Finds the channel for an external display. Its EDID vendor, model and serial pick the
    /// framebuffer (under the `dispextN` device); the matching DCPAVServiceProxy hangs off the
    /// coprocessor (`dcpextN`) under an endpoint named `dispextN:dcpav-service-epic:0`.
    static func channel(for display: CGDirectDisplayID) -> DDCChannel? {
        guard let createService, writeI2C != nil, readI2C != nil else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let framebuffer = IOIteratorNext(iterator), framebuffer != 0 {
            defer { IOObjectRelease(framebuffer) }
            guard matches(framebuffer: framebuffer, display: display),
                  let proxy = avServiceProxy(near: framebuffer) else { continue }
            defer { IOObjectRelease(proxy) }
            guard let service = createService(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }
            return DDCChannel(avService: service, name: "\(display)")
        }
        return nil
    }

    private static func matches(framebuffer: io_service_t, display: CGDirectDisplayID) -> Bool {
        guard let attributes = IORegistryEntryCreateCFProperty(framebuffer, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any]
        else { return false }
        let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value
        let model = (product["ProductID"] as? NSNumber)?.uint32Value
        let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value
        return vendor == CGDisplayVendorNumber(display)
            && model == CGDisplayModelNumber(display)
            && (serial == nil || serial == CGDisplaySerialNumber(display))
    }

    /// The DCPAVServiceProxy whose endpoint is named after the framebuffer's device.
    private static func avServiceProxy(near framebuffer: io_service_t) -> io_service_t? {
        guard let device = parentName(of: framebuffer) else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            if parentName(of: proxy)?.hasPrefix("\(device):") == true { return proxy }
            IOObjectRelease(proxy)
        }
        return nil
    }

    private static func parentName(of entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - VCP

    struct Value: Sendable {
        let current: Int
        let maximum: Int
    }

    func read(_ vcp: UInt8) async -> Value? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readSync(vcp)) }
        }
    }

    func write(_ vcp: UInt8, _ value: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.writeSync(vcp, value)) }
        }
    }

    private func readSync(_ vcp: UInt8) -> Value? {
        for _ in 0..<4 {
            guard send([0x01, vcp]) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard let readI2C = Self.readI2C,
                  readI2C(avService, Self.chipAddress, UInt32(Self.hostAddress), &reply, UInt32(reply.count)) == kIOReturnSuccess
            else { continue }
            // Reply: source, length, 0x02 (VCP reply), result, vcp, type, max hi/lo, current hi/lo, checksum.
            let checksum = reply[0..<10].reduce(0x50, ^)
            guard reply[2] == 0x02, reply[3] == 0, reply[4] == vcp, reply[10] == checksum else { continue }
            return Value(current: Int(reply[8]) << 8 | Int(reply[9]), maximum: Int(reply[6]) << 8 | Int(reply[7]))
        }
        return nil
    }

    private func writeSync(_ vcp: UInt8, _ value: Int) -> Bool {
        for _ in 0..<3 where send([0x03, vcp, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) {
            return true
        }
        return false
    }

    /// Frames `payload` with its length and checksum and writes it to the monitor.
    private func send(_ payload: [UInt8]) -> Bool {
        guard let writeI2C = Self.writeI2C else { return false }
        var packet = [0x80 | UInt8(payload.count)] + payload
        packet.append(packet.reduce(Self.displayAddress ^ Self.hostAddress, ^))
        usleep(10_000)
        return writeI2C(avService, Self.chipAddress, UInt32(Self.hostAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess
    }
}
