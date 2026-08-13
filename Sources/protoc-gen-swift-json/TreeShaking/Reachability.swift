//
// Reachability.swift
//
// Given a set of entry-point Swift type names and the descriptors for
// the proto files being generated, compute the set of *top-level*
// Swift type names that must be emitted in order to satisfy those
// entry points. Users name a few top-level messages or enums they
// actually use; we walk the type graph behind those and discover
// every other top-level message / enum any field can reach. The
// output is what survives the entry_points filter; every other
// top-level declaration is dropped.
//
// Algorithm summary:
//   - Build forward lookups for top-level message / enum Swift names.
//   - Seed BFS from each resolvable entry point.
//   - For each reachable message, walk its fields (including oneof
//     members). A field whose type points at a nested type contributes
//     its top-level *root* parent to the reachable set.
//   - Map fields synthesise a hidden `<Name>Entry` message that carries
//     the key/value descriptors. Drill through to the value's real
//     type without adding the synthetic message itself to the set.
//

import Foundation
import SwiftProtobufPluginLibrary

struct Reachability {

  /// A reference to a top-level proto type that's reachable from the
  /// entry points but whose containing file is outside the current
  /// generation scope. CrossPackageStubEmitter consumes these to write
  /// minimal Decodable stubs so the emitted module still compiles.
  struct OutOfScopeType: Hashable {
    let swiftFullName: String
    let isEnum: Bool
    /// `true` when the type lives in another Swift module (typically
    /// `SwiftProtobuf` for well-known types). The emitter writes a
    /// retroactive `Decodable` extension instead of redeclaring the
    /// type.
    let isImported: Bool
  }

  /// The top-level Swift type names that must be emitted to satisfy
  /// the entry points (including the entry points themselves).
  let reachableSwiftNames: Set<String>

  /// Entry points the caller named that didn't resolve to any
  /// top-level descriptor in the current generation scope. The plugin
  /// surfaces these so typos and stale config surface loudly.
  let unresolvedEntryPoints: [String]

  /// Top-level types reached via field references that don't have
  /// an in-scope descriptor. Their Swift symbols won't be produced by
  /// any of the in-scope `.pb.swift` files, so we synthesise stubs.
  let outOfScopeTypes: Set<OutOfScopeType>

  init(
    entryPoints: Set<String>,
    files: [FileDescriptor],
    namer: SwiftProtobufNamer
  ) {
    // Top-level forward lookups by Swift name.
    var topLevelMessages: [String: Descriptor] = [:]
    var topLevelEnums: [String: EnumDescriptor] = [:]
    for file in files {
      for message in file.messages where !message.options.mapEntry {
        topLevelMessages[namer.fullName(message: message)] = message
      }
      for enumDescriptor in file.enums {
        topLevelEnums[namer.fullName(enum: enumDescriptor)] = enumDescriptor
      }
    }

    // Seed BFS.
    var queue = Queue<Descriptor>()
    var reachable: Set<String> = []
    var unresolved: [String] = []
    for entry in entryPoints {
      if let message = topLevelMessages[entry] {
        queue.enqueue(message)
      } else if let enumDescriptor = topLevelEnums[entry] {
        reachable.insert(namer.fullName(enum: enumDescriptor))
      } else {
        unresolved.append(entry)
      }
    }

    // BFS.
    var outOfScope: Set<OutOfScopeType> = []
    var seenMessages: Set<ObjectIdentifier> = []
    while let message = queue.dequeue() {
      let identity = ObjectIdentifier(message)
      guard !seenMessages.contains(identity) else { continue }
      seenMessages.insert(identity)

      // The reachable set tracks the root parent of whatever we visit.
      let rootMessage = Self.rootMessage(of: message)
      reachable.insert(namer.fullName(message: rootMessage))

      // Every field — including oneof members — contributes its type
      // dependency, but expressed as the type's *top-level root*.
      let allFields = message.fields + message.oneofs.flatMap { $0.fields }
      for field in allFields {
        Self.expandField(
          field,
          queue: &queue,
          reachable: &reachable,
          outOfScope: &outOfScope,
          topLevelMessages: topLevelMessages,
          topLevelEnums: topLevelEnums,
          namer: namer
        )
      }

      // Nested types of a reachable message aren't independently emitted
      // (they ride along with the parent), but their fields can still
      // pull other top-level types into scope. Walk them too.
      for nested in Self.allNestedMessages(of: message) where !nested.options.mapEntry {
        queue.enqueue(nested)
      }
    }

    self.reachableSwiftNames = reachable
    self.unresolvedEntryPoints = unresolved.sorted()
    self.outOfScopeTypes = outOfScope
  }

  // MARK: - Helpers

  private static func expandField(
    _ field: FieldDescriptor,
    queue: inout Queue<Descriptor>,
    reachable: inout Set<String>,
    outOfScope: inout Set<OutOfScopeType>,
    topLevelMessages: [String: Descriptor],
    topLevelEnums: [String: EnumDescriptor],
    namer: SwiftProtobufNamer
  ) {
    switch field.type {
    case .message, .group:
      guard let target = field.messageType else { return }
      if target.options.mapEntry {
        // Synthetic map entry. Drill through to the key + value's real type.
        guard target.fields.count >= 2 else { return }
        expandField(
          target.fields[0],
          queue: &queue, reachable: &reachable, outOfScope: &outOfScope,
          topLevelMessages: topLevelMessages, topLevelEnums: topLevelEnums,
          namer: namer
        )
        expandField(
          target.fields[1],
          queue: &queue, reachable: &reachable, outOfScope: &outOfScope,
          topLevelMessages: topLevelMessages, topLevelEnums: topLevelEnums,
          namer: namer
        )
      } else {
        let root = rootMessage(of: target)
        let rootName = namer.fullName(message: root)
        if topLevelMessages[rootName] != nil {
          queue.enqueue(target)
        } else {
          outOfScope.insert(
            OutOfScopeType(
              swiftFullName: rootName, isEnum: false, isImported: isModuleQualified(rootName)
            )
          )
        }
      }
    case .enum:
      guard let target = field.enumType else { return }
      if let parentMessage = target.containingType {
        // Nested enum — pull its root parent message into the BFS.
        let root = rootMessage(of: parentMessage)
        let rootName = namer.fullName(message: root)
        if topLevelMessages[rootName] != nil {
          queue.enqueue(root)
        } else {
          outOfScope.insert(
            OutOfScopeType(
              swiftFullName: rootName, isEnum: false, isImported: isModuleQualified(rootName)
            )
          )
        }
      } else {
        let name = namer.fullName(enum: target)
        if topLevelEnums[name] != nil {
          reachable.insert(name)
        } else {
          outOfScope.insert(
            OutOfScopeType(
              swiftFullName: name, isEnum: true, isImported: isModuleQualified(name)
            )
          )
        }
      }
    default:
      break
    }
  }

  /// A type name that comes back from SwiftProtobufNamer as
  /// `Module.TypeName` lives in another Swift module — typically
  /// `SwiftProtobuf` itself for the well-known types.
  private static func isModuleQualified(_ name: String) -> Bool {
    name.contains(".")
  }

  /// Walks up to the outermost containing message.
  private static func rootMessage(of message: Descriptor) -> Descriptor {
    var current = message
    while let parent = current.containingType {
      current = parent
    }
    return current
  }

  /// All transitively nested messages under `message`, depth-first.
  /// Skips synthetic map-entry messages.
  private static func allNestedMessages(of message: Descriptor) -> [Descriptor] {
    var result: [Descriptor] = []
    for nested in message.messages {
      result.append(nested)
      result.append(contentsOf: allNestedMessages(of: nested))
    }
    return result
  }
}
