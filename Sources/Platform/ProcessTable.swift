import Darwin
import Foundation

/// One running process, as far as the Wine launch code needs to see it.
public struct ProcessRecord: Sendable, Equatable {
  public var pid: Int32
  /// The process's argv as it holds it in memory. Wine rewrites it to the Windows command line.
  public var arguments: [String]
  /// Working directory and open files are only filled when asked for (a syscall per process or fd).
  public var workingDirectory: String?
  /// Paths of files the process has open.
  public var openPaths: [String]

  public init(pid: Int32, arguments: [String], workingDirectory: String? = nil, openPaths: [String] = []) {
    self.pid = pid
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.openPaths = openPaths
  }
}

/// Reads and kills processes in-process. Replaces the `ps | lsof | awk` pipeline of the TS launcher; `lsof`
/// is not on the external-process allowlist (ADR 0002).
public protocol ProcessTable: Sendable {
  func processes(includeOpenPaths: Bool) -> [ProcessRecord]
  func kill(_ pid: Int32)
}

/// Production `ProcessTable` on libproc. Only the current user's processes are listed.
public struct SystemProcessTable: ProcessTable {
  public init() {}

  public func processes(includeOpenPaths: Bool) -> [ProcessRecord] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    let uid = getuid()
    var result: [ProcessRecord] = []
    for pid in pids.prefix(Int(count)) where pid > 0 {
      var info = proc_bsdinfo()
      let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      guard size == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == uid else { continue }
      result.append(
        ProcessRecord(
          pid: pid,
          arguments: Self.arguments(of: pid),
          workingDirectory: includeOpenPaths ? Self.workingDirectory(of: pid) : nil,
          openPaths: includeOpenPaths ? Self.openPaths(of: pid) : []))
    }
    return result
  }

  public func kill(_ pid: Int32) {
    _ = Darwin.kill(pid, SIGKILL)
  }

  static func workingDirectory(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
  }

  static func openPaths(of pid: Int32) -> [String] {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
    let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard filled > 0 else { return [] }
    var paths: [String] = []
    for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var vnode = vnode_fdinfowithpath()
      let size = proc_pidfdinfo(
        pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
      guard size == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
      let path = withUnsafePointer(to: &vnode.pvip.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  /// argv via `sysctl(KERN_PROCARGS2)`: `argc`, the exec path, padding NULs, then argc NUL-separated strings.
  static func arguments(of pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }  // exec path
    while index < size, buffer[index] == 0 { index += 1 }  // padding
    var result: [String] = []
    var start = index
    while index < size, result.count < Int(argc) {
      if buffer[index] == 0 {
        result.append(String(decoding: buffer[start..<index], as: UTF8.self))
        start = index + 1
      }
      index += 1
    }
    return result
  }
}
