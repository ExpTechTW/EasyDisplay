import Foundation
import IOKit

/// Read-only access to AppleSMC float sensors through its user client (no root needed).
///
/// Requests use the classic 80-byte SMCKeyData struct: key @0, keyInfo.dataSize @28,
/// keyInfo.dataType @32, result @40, command @42, data32 @44, bytes @48.
final class SMC: Sendable {
    struct Key: Sendable, Hashable {
        let name: String
        let code: UInt32
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// The key if it exists and holds a 4-byte float.
    func floatKey(named name: String) -> Key? {
        let key = Key(name: name, code: Self.fourCC(name))
        guard let info = request(.readKeyInfo, code: key.code),
              Self.uint32(info, at: 32) == Self.fourCC("flt "), Self.uint32(info, at: 28) == 4
        else { return nil }
        return key
    }

    /// Every float key whose name starts with `prefix`. Enumerates all SMC keys, so call it once.
    func floatKeys(prefix: String) -> [Key] {
        guard let count = request(.readBytes, code: Self.fourCC("#KEY"), dataSize: 4) else { return [] }
        let total = count[48..<52].reduce(0) { $0 << 8 | UInt32($1) }  // big-endian
        return (0..<total).compactMap { index in
            guard let entry = request(.readIndex, index: index) else { return nil }
            let name = Self.name(of: Self.uint32(entry, at: 0))
            return name.hasPrefix(prefix) ? floatKey(named: name) : nil
        }
    }

    func read(_ key: Key) -> Double? {
        guard let data = request(.readBytes, code: key.code, dataSize: 4) else { return nil }
        return Double(Float(bitPattern: Self.uint32(data, at: 48)))
    }

    // MARK: - Transport

    private func request(_ command: Command, code: UInt32 = 0, index: UInt32 = 0, dataSize: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: code) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: dataSize) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = command.rawValue
        withUnsafeBytes(of: index) { input.replaceSubrange(44..<48, with: $0) }

        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(connection, 2, inBytes.baseAddress, inBytes.count, outBytes.baseAddress, &outputSize)
            }
        }
        return result == KERN_SUCCESS && output[40] == 0 ? output : nil
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func name(of code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
