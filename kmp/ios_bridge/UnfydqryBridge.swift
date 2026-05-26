import Foundation
import UnifiedQuery

// MARK: - Hit

/// ObjC-visible counterpart of UnifiedQuery.Hit.
@objc public class UnfydqryHit: NSObject {
    @objc public let hitId: Int64
    @objc public let score: Double

    init(hitId: Int64, score: Double) {
        self.hitId = hitId
        self.score = score
    }
}

// MARK: - SearchEngine bridge

/// Thin @objc wrapper over UnifiedQuery.SearchEngine.
///
/// This class exists solely to give Kotlin/Native's cinterop an
/// Objective-C-compatible interface.  All search logic lives in the Rust core;
/// this file never needs to change unless the public API of SearchEngine
/// changes.
///
/// Re-generate the companion header after editing:
///   ./kmp/scripts/generate_bridge_header.sh
@objc public class UnfydqrySearchEngine: NSObject {

    private let engine: SearchEngine

    /// Returns nil and sets `error` on failure.
    @objc public class func create(dbPath: String, error outError: NSErrorPointer) -> UnfydqrySearchEngine? {
        do {
            let e = try SearchEngine(dbPath: dbPath)
            return UnfydqrySearchEngine(engine: e)
        } catch let err {
            outError?.pointee = nsError(err)
            return nil
        }
    }

    private init(engine: SearchEngine) {
        self.engine = engine
    }

    @objc public func index(id itemId: Int64, text: String, error outError: NSErrorPointer) -> Bool {
        do {
            try engine.index(id: itemId, text: text)
            return true
        } catch let err {
            outError?.pointee = nsError(err)
            return false
        }
    }

    @objc public func remove(id itemId: Int64, error outError: NSErrorPointer) -> Bool {
        do {
            try engine.remove(id: itemId)
            return true
        } catch let err {
            outError?.pointee = nsError(err)
            return false
        }
    }

    /// Returns nil and sets `error` on failure.
    @objc public func search(query: String, limit: Int32, error outError: NSErrorPointer) -> NSArray? {
        do {
            let hits = try engine.search(query: query, limit: UInt32(limit))
            return hits.map { UnfydqryHit(hitId: $0.id, score: $0.score) } as NSArray
        } catch let err {
            outError?.pointee = nsError(err)
            return nil
        }
    }
}

// MARK: - Helpers

private let domain = "UnfydqryErrorDomain"

private func nsError(_ err: Error) -> NSError {
    NSError(domain: domain, code: 0,
            userInfo: [NSLocalizedDescriptionKey: err.localizedDescription])
}
