import Foundation
import MachO
import Storybook

/// Finds every type conforming to `Storybook.Stories` in the loaded images
/// by walking the `__TEXT,__swift5_proto` section, so stories need no
/// registration.
///
/// This reads Swift's stable conformance-record ABI (`include/swift/ABI/Metadata.h`)
/// but no private Apple API: it only looks for *our* protocol. A `@Stories`
/// macro emitting `@section` records (Swift 6.3+) is the planned fast path;
/// this scan stays as the fallback.
public enum ConformanceScanner {
    public static func storiesTypes() -> [any Stories.Type] {
        var found: [any Stories.Type] = []
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index) else { continue }
            if isSystemImage(String(cString: path)) { continue }
            header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { header64 in
                found += scan(header: header64)
            }
        }
        return found
    }

    static func isSystemImage(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/") || path.contains(".simruntime/")
            || path.contains("/Developer/Library/") || path.contains("/usr/lib/swift/")
    }

    private static func scan(header: UnsafePointer<mach_header_64>) -> [any Stories.Type] {
        var size: UInt = 0
        guard let section = getsectiondata(header, "__TEXT", "__swift5_proto", &size) else { return [] }
        let count = Int(size) / MemoryLayout<Int32>.size
        let base = UnsafeRawPointer(section)
        var result: [any Stories.Type] = []
        for i in 0..<count {
            // Each record is a relative offset to a ProtocolConformanceDescriptor.
            let recordAddress = base + i * MemoryLayout<Int32>.size
            let descriptor = resolveRelative(recordAddress)
            if let type = storiesType(conformance: descriptor) {
                result.append(type)
            }
        }
        return result
    }

    /// ProtocolConformanceDescriptor:
    /// `{ Protocol: rel-indirectable, TypeRef: rel, WitnessTable: rel, Flags: UInt32 }`.
    private static func storiesType(conformance: UnsafeRawPointer) -> (any Stories.Type)? {
        guard let protocolDescriptor = resolveRelativeIndirectable(conformance),
              isStoriesProtocol(protocolDescriptor) else { return nil }

        let flags = conformance.load(fromByteOffset: 12, as: UInt32.self)
        let typeReferenceKind = (flags >> 3) & 0x7
        let typeRefField = conformance + 4
        let typeDescriptor: UnsafeRawPointer?
        switch typeReferenceKind {
        case 0: typeDescriptor = resolveRelative(typeRefField)               // direct
        case 1: typeDescriptor = resolveRelative(typeRefField).load(as: UnsafeRawPointer?.self) // indirect
        default: return nil                                                    // ObjC class refs
        }
        guard let typeDescriptor else { return nil }

        // Context descriptor flags: kind in the low 5 bits, generic bit 0x80.
        let contextFlags = typeDescriptor.load(as: UInt32.self)
        let kind = contextFlags & 0x1F
        let isGeneric = contextFlags & 0x80 != 0
        guard (16...18).contains(kind), !isGeneric else { return nil } // class, struct, enum

        // TypeContextDescriptor: { Flags, Parent, Name, AccessFunction, ... }.
        let accessorField = typeDescriptor + 12
        guard accessorField.load(as: Int32.self) != 0 else { return nil }
        typealias MetadataAccessor = @convention(c) (Int) -> UnsafeRawPointer
        let accessor = unsafeBitCast(resolveRelative(accessorField), to: MetadataAccessor.self)
        let metadata = accessor(0) // MetadataRequest: complete, blocking
        let type = unsafeBitCast(metadata, to: Any.Type.self)
        return type as? any Stories.Type
    }

    /// ProtocolDescriptor: `{ Flags, Parent: rel-indirectable, Name: rel, ... }`.
    private static func isStoriesProtocol(_ descriptor: UnsafeRawPointer) -> Bool {
        guard name(at: descriptor + 8) == "Stories",
              let module = resolveRelativeIndirectable(descriptor + 4) else { return false }
        return name(at: module + 8) == "Storybook"
    }

    private static func name(at field: UnsafeRawPointer) -> String? {
        let offset = field.load(as: Int32.self)
        guard offset != 0 else { return nil }
        return String(cString: (field + Int(offset)).assumingMemoryBound(to: CChar.self))
    }

    private static func resolveRelative(_ field: UnsafeRawPointer) -> UnsafeRawPointer {
        field + Int(field.load(as: Int32.self))
    }

    /// Low bit set means the target is a pointer to the real address.
    private static func resolveRelativeIndirectable(_ field: UnsafeRawPointer) -> UnsafeRawPointer? {
        let offset = field.load(as: Int32.self)
        guard offset != 0 else { return nil }
        if offset & 1 == 0 { return field + Int(offset) }
        return (field + Int(offset & ~1)).load(as: UnsafeRawPointer?.self)
    }
}
