import Foundation

/// A lookup result owns its symbol spelling; image lifetime belongs to the
/// backend. A nonnil result always has a callable, nonzero address.
struct ControllerSoftLinkSymbol: Equatable, Sendable {
    let address: UInt
    let name: String
    init(address: UInt, name: String) {
        precondition(address != 0)
        self.address = address
        self.name = name
    }
}

protocol ControllerSoftLinkBackend {
    associatedtype Image
    func loadedImages(requests: [UInt64], salt: String) -> [Image]
    func loadImagesFromFilesystem(requests: [UInt64], salt: String) -> [Image]
    func symbols(in image: Image, hashes: Set<UInt64>, salt: String) -> [UInt64: ControllerSoftLinkSymbol]
}

enum ControllerSoftLink {
    private struct Request {
        let index: Int
        let alternative: Int
    }
    private struct Match {
        let alternative: Int
        let symbol: ControllerSoftLinkSymbol
    }

    /// Aliases are preferred across images, rather than
    /// accepting the first address. Equal-priority matches retain the first
    /// image. Filesystem lookup is eager and only skipped when every request
    /// already has alternative zero. Empty requests remain unresolved.
    static func resolve<Backend: ControllerSoftLinkBackend>(images: [UInt64], requests: [[UInt64]],
                                                           salt: String, backend: Backend) -> [ControllerSoftLinkSymbol?] {
        guard !requests.isEmpty else { return [] }
        var byHash: [UInt64: [Request]] = [:]
        for (index, alternatives) in requests.enumerated() {
            for (alternative, hash) in alternatives.enumerated() {
                byHash[hash, default: []].append(.init(index: index, alternative: alternative))
            }
        }
        var matches = [Match?](repeating: nil, count: requests.count)
        func complete() -> Bool { matches.allSatisfy { $0?.alternative == 0 } }
        func inspect(_ image: Backend.Image) {
            let needed = Set(byHash.compactMap { hash, destinations in
                destinations.contains { request in
                    guard let match = matches[request.index] else { return true }
                    return request.alternative < match.alternative
                } ? hash : nil
            })
            guard !needed.isEmpty else { return }
            let found = backend.symbols(in: image, hashes: needed, salt: salt)
            // First accumulate the best new alias per request,
            // then publishes that image's matches. Dictionary order cannot
            // replace a higher-priority alternative with a lower-priority one.
            var updates: [Int: Match] = [:]
            for (hash, symbol) in found where needed.contains(hash) {
                for request in byHash[hash] ?? [] {
                    if let previous = matches[request.index], previous.alternative <= request.alternative { continue }
                    if let update = updates[request.index], update.alternative <= request.alternative { continue }
                    updates[request.index] = .init(alternative: request.alternative, symbol: symbol)
                }
            }
            for (index, update) in updates { matches[index] = update }
        }
        for image in backend.loadedImages(requests: images, salt: salt) {
            inspect(image)
            if complete() { break }
        }
        if !complete() {
            for image in backend.loadImagesFromFilesystem(requests: images, salt: salt) {
                inspect(image)
                if complete() { break }
            }
        }
        return matches.map { $0?.symbol }
    }

    /// SipHash-2-4 with the fixed key bytes 00...0f. The salt is
    /// appended to the symbol/path bytes, not prepended or hashed separately.
    static func hash<Bytes: Collection>(_ bytes: Bytes, appending salt: [UInt8] = []) -> UInt64 where Bytes.Element == UInt8 {
        var state = SipHash()
        for byte in bytes { state.append(byte) }
        for byte in salt { state.append(byte) }
        return state.finish()
    }
    private struct SipHash {
        var v0: UInt64 = 0x7469686173716475
        var v1: UInt64 = 0x6b617f6d656e6665
        var v2: UInt64 = 0x6b7f62616d677361
        var v3: UInt64 = 0x7b6b696e727e6c7b
        var pending: UInt64 = 0
        var pendingCount = 0
        var count = 0
        private func rotate(_ value: UInt64, _ by: Int) -> UInt64 { (value << by) | (value >> (64 - by)) }
        mutating func round() {
            v0 = v0 &+ v1; v1 = rotate(v1, 13) ^ v0; v0 = rotate(v0, 32)
            v2 = v2 &+ v3; v3 = rotate(v3, 16) ^ v2
            v0 = v0 &+ v3; v3 = rotate(v3, 21) ^ v0
            v2 = v2 &+ v1; v1 = rotate(v1, 17) ^ v2; v2 = rotate(v2, 32)
        }
        mutating func compress(_ word: UInt64) { v3 ^= word; round(); round(); v0 ^= word }
        mutating func append(_ byte: UInt8) {
            pending |= UInt64(byte) << (pendingCount * 8)
            pendingCount += 1; count += 1
            if pendingCount == 8 { compress(pending); pending = 0; pendingCount = 0 }
        }
        mutating func finish() -> UInt64 {
            compress(pending | (UInt64(count & 255) << 56))
            v2 ^= 255
            for _ in 0..<4 { round() }
            return v0 ^ v1 ^ v2 ^ v3
        }
    }
}
