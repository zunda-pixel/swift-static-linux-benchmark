import Foundation
import Hummingbird
import Logging

struct Message: ResponseEncodable {
  let message: String
  let id: Int
  let enabled: Bool
}

@main
struct BenchmarkServer {
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = environment["HOST"] ?? "127.0.0.1"
    let port = environment["PORT"].flatMap(Int.init) ?? 8080

    var logger = Logger(label: "BenchmarkServer")
    // Request logging would add allocations and I/O unrelated to the workload.
    logger.logLevel = environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .error

    let router = Router()
    router.get("health") { _, _ in "ok" }

    // Baseline: almost no allocation per request beyond HTTP handling itself.
    router.get("plaintext") { _, _ in "Hello, World!" }

    // Typical API response: Encodable -> JSONEncoder (Foundation).
    router.get("json") { _, _ in
      Message(message: "Hello, World!", id: 123, enabled: true)
    }

    router.get("string") { _, _ in
      String(Workloads.string())
    }

    router.get("array") { _, _ in
      String(Workloads.array(reserve: false))
    }

    router.get("array-reserved") { _, _ in
      String(Workloads.array(reserve: true))
    }

    router.get("allocation") { _, _ in
      String(Workloads.allocation(seed: 0))
    }

    // Stress test: amplifies allocator contention by allocating from many tasks at once.
    router.get("parallel-allocation") { _, _ in
      String(await Workloads.parallelAllocation(tasks: 8))
    }

    let app = Application(
      router: router,
      configuration: .init(address: .hostname(host, port: port), serverName: "BenchmarkServer"),
      logger: logger
    )
    try await app.runService()
  }
}
