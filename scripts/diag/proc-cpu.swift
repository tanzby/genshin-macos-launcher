// Usage: proc-cpu <process name> <interval seconds>. Every interval prints "<epoch> <cumulative CPU ns of all processes with that name> <count>"
// until killed. fps-measure runs it on MTLCompilerService, the Metal compiler XPC service where pipelines of the
// game are compiled: CPU time that grows during a hitch means the hitch overlapped a run-time compile.
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MTLCompilerService"
let interval = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 0.05 : 0.05
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func compilerCPU() -> (ns: UInt64, count: Int) {
  var pids = [pid_t](repeating: 0, count: 4096)
  let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
  var total: UInt64 = 0
  var count = 0
  for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
    var buffer = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buffer, UInt32(buffer.count))
    guard String(cString: buffer).hasPrefix(name) else { continue }
    var usage = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { continue }
    total += (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    count += 1
  }
  return (total, count)
}

while true {
  let sample = compilerCPU()
  print(String(format: "%.3f", Date().timeIntervalSince1970), sample.ns, sample.count)
  usleep(UInt32(interval * 1_000_000))
}
