//
// FixtureSyncTests — keep DecodingFixtures byte-identical to the goldens.
//
// We keep two copies of each emitted fixture:
//
//   Tests/protoc-gen-swift-jsonTests/Goldens/Expected/<name>.pb.swift
//     read at test time as a *resource* by GoldenTests; this is the
//     authoritative expected output of the strip-and-append pipeline.
//
//   Tests/protoc-gen-swift-jsonTests/DecodingFixtures/<name>.pb.swift
//     compiled into the test target as ordinary Swift source so
//     DecodingTests can exercise the emitted Decodable conformance with
//     JSONDecoder.
//
// SwiftPM doesn't let a file be both a resource and a compile-time source,
// so we keep two physical copies. The hazard is drift — somebody edits
// Expected/ without re-copying. This test fails immediately when that
// happens.
//

import Foundation
import Testing

@Suite("FixtureSync")
struct FixtureSyncTests {
  @Test(
    "DecodingFixtures matches Goldens/Expected",
    arguments: GoldenTests.fixtures
  )
  func inSync(_ fixture: String) throws {
    try assertSync(fixture: fixture)
  }

  // MARK: - Harness

  private func assertSync(fixture: String) throws {
    let expectedURL = Bundle.module
      .resourceURL!
      .appendingPathComponent("Goldens")
      .appendingPathComponent("Expected")
      .appendingPathComponent("\(fixture).pb.swift")
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)

    // DecodingFixtures lives under the test target's source tree (it is
    // compiled, not bundled as a resource). At test run time the source
    // file isn't reachable from Bundle.module, so we shell out to the
    // expected resource's path to locate it. Tests run from
    // .build/{config}/.../ — walk up to the package root and over to
    // DecodingFixtures.
    let mirrorURL = try mirrorFixtureURL(fixture: fixture)
    let mirror = try String(contentsOf: mirrorURL, encoding: .utf8)

    if expected != mirror {
      Issue.record(
        """
        DecodingFixtures/\(fixture).pb.swift has drifted from \
        Goldens/Expected/\(fixture).pb.swift. Re-run `make regen-goldens` \
        (or copy Goldens/Expected/\(fixture).pb.swift → \
        DecodingFixtures/\(fixture).pb.swift) to resync.
        """
      )
    }
  }

  /// Walks from the test bundle's resource URL up to the package root
  /// (the parent of `Tests/`) and back down to the DecodingFixtures copy.
  /// Brittle to layout changes, but tests run in-place so the layout is
  /// stable; the failure mode (resource not found) is loud.
  private func mirrorFixtureURL(fixture: String) throws -> URL {
    var url = Bundle.module.resourceURL!
    while url.path != "/" {
      let candidate = url
        .appendingPathComponent("Tests")
        .appendingPathComponent("protoc-gen-swift-jsonTests")
        .appendingPathComponent("DecodingFixtures")
        .appendingPathComponent("\(fixture).pb.swift")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      url.deleteLastPathComponent()
    }
    throw SyncError.mirrorNotFound(fixture)
  }
}

private enum SyncError: Error, CustomStringConvertible {
  case mirrorNotFound(String)

  var description: String {
    switch self {
    case .mirrorNotFound(let name):
      return "couldn't locate DecodingFixtures/\(name).pb.swift relative to the test bundle"
    }
  }
}
