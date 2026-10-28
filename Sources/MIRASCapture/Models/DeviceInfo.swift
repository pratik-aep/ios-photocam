import Foundation
import Darwin

enum DeviceInfo {
    static var model: String {
        if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulator }
        var system = utsname(); uname(&system)
        let bytes = Mirror(reflecting:system.machine).children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) }
        return String(bytes:bytes,encoding:.utf8) ?? "iPhone"
    }
}
