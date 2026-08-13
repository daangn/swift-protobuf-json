//
// ReachabilityTests — descriptor-graph BFS that powers entry_points.
//
// We load the goldens/closed_enums.proto and goldens/oneofs.proto
// descriptor sets to build small, real type graphs. Each test names
// one or two top-level types as entry points and asserts the right
// transitive closure is reachable.
//

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary
import Testing

@testable import protoc_gen_swift_json

@Suite("Reachability")
struct ReachabilityTests {

  @Test("a leaf message reaches only itself")
  func leafMessage() throws {
    let (files, namer) = try loadFiles(fixture: "scalars")
    let result = Reachability(
      entryPoints: ["Goldens_Scalars"],
      files: files,
      namer: namer
    )
    #expect(result.reachableSwiftNames == ["Goldens_Scalars"])
    #expect(result.unresolvedEntryPoints.isEmpty)
  }

  @Test("a message reaches the messages and enums it references")
  func transitiveClosure() throws {
    let (files, namer) = try loadFiles(fixture: "oneofs")
    let result = Reachability(
      entryPoints: ["Goldens_Notification"],
      files: files,
      namer: namer
    )
    // Notification's oneof references Image; both are top-level.
    #expect(result.reachableSwiftNames.contains("Goldens_Notification"))
    #expect(result.reachableSwiftNames.contains("Goldens_Image"))
  }

  @Test("an enum entry-point is reachable on its own")
  func enumEntryPoint() throws {
    let (files, namer) = try loadFiles(fixture: "enums")
    let result = Reachability(
      entryPoints: ["Goldens_Status"],
      files: files,
      namer: namer
    )
    #expect(result.reachableSwiftNames.contains("Goldens_Status"))
  }

  @Test("an entry-point not present in the files is reported unresolved")
  func unresolvedEntryPoint() throws {
    let (files, namer) = try loadFiles(fixture: "scalars")
    let result = Reachability(
      entryPoints: ["Goldens_DoesNotExist"],
      files: files,
      namer: namer
    )
    #expect(result.reachableSwiftNames.isEmpty)
    #expect(result.unresolvedEntryPoints == ["Goldens_DoesNotExist"])
  }

  // MARK: - Helpers

  private func loadFiles(fixture: String) throws -> (
    files: [FileDescriptor], namer: SwiftProtobufNamer
  ) {
    let url = Bundle.module.resourceURL!
      .appendingPathComponent("Goldens")
      .appendingPathComponent("Fixtures")
      .appendingPathComponent("\(fixture).descriptorset")
    let data = try Data(contentsOf: url)
    let proto = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
    let descriptors = DescriptorSet(proto: proto)
    let target = descriptors.files.first { $0.name.hasSuffix("\(fixture).proto") }!
    let namer = SwiftProtobufNamer(
      currentFile: target,
      protoFileToModuleMappings: ProtoFileToModuleMappings()
    )
    return (descriptors.files, namer)
  }
}
