import Foundation

/// Per-request workloads. Each returns a checksum that is sent back in the response
/// so the optimizer cannot drop the work.
///
/// Swift stores strings of up to 15 UTF-8 bytes inline, so strings that are meant to
/// hit the allocator are deliberately longer than that.
enum Workloads {
  /// ~1,000 short strings plus one joined string.
  static func string() -> Int {
    (0..<1000)
      .map(String.init)
      .joined(separator: ",")
      .utf8.count
  }

  /// 10,000 appends. Without `reserveCapacity` the buffer is reallocated ~14 times.
  static func array(reserve: Bool) -> Int {
    var values: [Int] = []
    if reserve {
      values.reserveCapacity(10_000)
    }
    for i in 0..<10_000 {
      values.append(i)
    }
    return values.count &+ values[values.count / 2]
  }

  final class Node {
    let id: Int
    let name: String
    var tags: [String]

    init(id: Int, name: String, tags: [String]) {
      self.id = id
      self.name = name
      self.tags = tags
    }
  }

  struct Record: Codable {
    let id: Int
    let name: String
    let tags: [String]
    let attributes: [String: String]
  }

  /// Mix of allocations a Swift server typically performs: class instances, arrays,
  /// heap-allocated strings, dictionaries, `Data`, and JSON encoding.
  static func allocation(seed: Int) -> Int {
    var nodes: [Node] = []
    var index: [String: Int] = [:]
    var records: [Record] = []
    var buffer = Data()

    for i in 0..<200 {
      let name = "benchmark-user-\(seed)-\(i)"
      let tags = (0..<4).map { "benchmark-tag-\($0)-\(i)" }
      nodes.append(Node(id: i, name: name, tags: tags))
      index[name] = i

      if i % 10 == 0 {
        records.append(
          Record(
            id: i,
            name: name,
            tags: tags,
            attributes: ["created-by-benchmark": name, "sequence-number": "\(i)-\(seed)-sequence"]
          )
        )
      }

      buffer.append(contentsOf: [UInt8](repeating: UInt8(truncatingIfNeeded: i), count: 64))
    }

    let json = (try? JSONEncoder().encode(records)) ?? Data()

    var checksum = nodes.count &+ index.count &+ json.count &+ buffer.count
    for node in nodes {
      checksum &+= node.tags.count &+ node.name.utf8.count
    }
    return checksum
  }

  /// Runs `allocation` concurrently from `tasks` child tasks.
  static func parallelAllocation(tasks: Int) async -> Int {
    await withTaskGroup(of: Int.self) { group in
      for seed in 0..<tasks {
        group.addTask { allocation(seed: seed) }
      }
      return await group.reduce(0, &+)
    }
  }
}
