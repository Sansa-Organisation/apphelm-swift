import Foundation
import MachO

/// The binaries loaded into this process, as a crash report needs them for symbolication.
///
/// A frame in a stripped build is only an address, and the address moves on every launch
/// (ASLR). To turn it back into a function the server needs to know which binary it is in
/// and where that binary was loaded: the binary's UUID (`LC_UUID`, which the uploaded
/// symbol table is keyed by), its load address, and the slide. They are read from dyld
/// while the process is healthy, never inside a signal handler.
enum DebugImages {
  static let maxPerReport = 16

  /// Every loaded image: `name`, `uuid`, `base` (load address) and `slide`, both in hex.
  static func loaded() -> [[String: String]] {
    var images: [[String: String]] = []
    for index in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index) else { continue }
      let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
      guard !name.isEmpty, let uuid = uuid(of: header) else { continue }
      images.append([
        "name": String(name.prefix(100)),
        "uuid": uuid,
        "base": "0x" + String(UInt(bitPattern: header), radix: 16),
        "slide": "0x" + String(UInt(bitPattern: _dyld_get_image_vmaddr_slide(index)), radix: 16),
      ])
    }
    return images
  }

  /// The `LC_UUID` of a 64-bit Mach-O image, walking its load commands.
  static func uuid(of header: UnsafePointer<mach_header>) -> String? {
    guard header.pointee.magic == MH_MAGIC_64 else { return nil }
    var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
      let load = command.assumingMemoryBound(to: load_command.self).pointee
      if load.cmd == UInt32(LC_UUID) {
        let bytes = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
        return UUID(uuid: bytes).uuidString
      }
      guard load.cmdsize > 0 else { return nil }
      command = command.advanced(by: Int(load.cmdsize))
    }
    return nil
  }

  /// The image a `backtrace_symbols` line names: everything between the frame number and
  /// the address, so a name with spaces survives.
  static func imageName(inFrame frame: String) -> String? {
    let trimmed = frame.trimmingCharacters(in: .whitespaces)
    guard let numberEnd = trimmed.firstIndex(where: { !$0.isNumber }), numberEnd != trimmed.startIndex,
      let address = trimmed.range(of: " 0x", range: numberEnd..<trimmed.endIndex) else { return nil }
    let name = trimmed[numberEnd..<address.lowerBound].trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }

  /// The images the frames of one stack are in, in stack order, at most `maxPerReport`.
  static func referenced(by frames: [String], among images: [[String: String]]) -> [[String: String]] {
    var byName: [String: [String: String]] = [:]
    for image in images { if let name = image["name"], byName[name] == nil { byName[name] = image } }
    var seen = Set<String>()
    var result: [[String: String]] = []
    for frame in frames {
      guard result.count < maxPerReport, let name = imageName(inFrame: frame), seen.insert(name).inserted, let image = byName[name] else { continue }
      result.append(image)
    }
    return result
  }
}
