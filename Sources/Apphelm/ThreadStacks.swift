import Darwin
import Foundation
import MachO

/// Another thread's stack, read from outside it: the profiler samples the main thread with
/// it, and app-hang detection reads the main thread's stack while it hangs.
enum ThreadStacks {
  /// The main thread's Mach port. `pthread_main_thread_np` isn't visible to Swift, so it is
  /// looked up once in libSystem; nil if it can't be.
  static let mainThreadPort: thread_act_t? = {
    if Thread.isMainThread { return mach_thread_self() }
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_main_thread_np") else { return nil }
    let function = unsafeBitCast(symbol, to: (@convention(c) () -> pthread_t?).self)
    guard let main = function() else { return nil }
    return pthread_mach_thread_np(main)
  }()

  /// Suspend `target` (`thread_suspend`), read its program counter and frame pointer
  /// (`thread_get_state`), walk the frame-pointer chain with `vm_read_overwrite` (so a bad
  /// pointer is a failed read, never a crash) into `buffer`, innermost first, and resume it.
  /// Returns the number of addresses. Nothing is allocated and no lock is taken while the
  /// thread is suspended: it may hold the allocator's lock.
  static func capture(_ target: thread_act_t, into buffer: UnsafeMutablePointer<UInt64>, maxDepth: Int) -> Int {
    let task = mach_task_self_
    guard maxDepth > 0, thread_suspend(target) == KERN_SUCCESS else { return 0 }
    defer { thread_resume(target) }
    var pc: UInt64 = 0
    var fp: UInt64 = 0
    #if arch(arm64)
    var state = arm_thread_state64_t()
    var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(target, ARM_THREAD_STATE64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    pc = state.__pc
    fp = state.__fp
    #elseif arch(x86_64)
    var state = x86_thread_state64_t()
    var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(target, x86_THREAD_STATE64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    pc = state.__rip
    fp = state.__rbp
    #else
    return 0
    #endif
    // Pointer-authentication bits are not part of the address.
    let mask: UInt64 = 0x0000_7FFF_FFFF_FFFF
    buffer[0] = pc & mask
    var depth = 1
    var frame = fp
    var pair: (UInt64, UInt64) = (0, 0)
    while depth < maxDepth, frame != 0, frame & 7 == 0 {
      var read: vm_size_t = 0
      let status = withUnsafeMutableBytes(of: &pair) { bytes in
        vm_read_overwrite(task, vm_address_t(frame), vm_size_t(16), vm_address_t(UInt(bitPattern: bytes.baseAddress)), &read)
      }
      guard status == KERN_SUCCESS, read == 16 else { break }
      let returnAddress = pair.1 & mask
      if returnAddress == 0 { break }
      buffer[depth] = returnAddress
      depth += 1
      // The stack grows down, so each caller's frame is higher than its callee's.
      if pair.0 <= frame { break }
      frame = pair.0
    }
    return depth
  }

  /// Addresses as `backtrace_symbols` prints them (`3   Shop   0x0000000102a3f4c8 symbol + 52`),
  /// the form crash reports use, so the server symbolicates them the same way. Resolved with
  /// `dladdr` once the thread runs again; a stripped image shows its own name as the symbol.
  static func symbolicate(_ addresses: [UInt64]) -> [String] {
    addresses.enumerated().map { index, address in
      var info = Dl_info()
      let found = dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0
      let image = found && info.dli_fname != nil ? URL(fileURLWithPath: String(cString: info.dli_fname)).lastPathComponent : "???"
      let hex = "0x" + String(repeating: "0", count: max(0, 16 - String(address, radix: 16).count)) + String(address, radix: 16)
      let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
      let shown = image.padding(toLength: max(image.count, 35), withPad: " ", startingAt: 0)
      if found, let symbol = info.dli_sname, let start = info.dli_saddr {
        return "\(number)\(shown) \(hex) \(String(cString: symbol)) + \(address &- UInt64(UInt(bitPattern: start)))"
      }
      if found, let base = info.dli_fbase {
        return "\(number)\(shown) \(hex) \(image) + \(address &- UInt64(UInt(bitPattern: base)))"
      }
      return "\(number)\(shown) \(hex) ???"
    }
  }
}
