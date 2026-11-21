import AppKit

/// Finite paste operation (PasteOperation/PasteObservation):
/// promised data, global ownership, observed reads and conditional restoration.
enum NativePaste {
    struct Representation { let type: NSPasteboard.PasteboardType; let data: Data }
    private static func main<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    static func representations(text: String, format: String) throws -> [Representation] {
        try RequestRuntime.check()
        guard ["text", "md", "html"].contains(format) else { throw ServiceError(.unhandledEvent, "Unknown paste format") }
        if format == "text" { return [Representation(type: .string, data: Data(text.utf8))] }
        let html: String
        if format == "md" {
            html = try MarkdownHTML.render(text, checkpoint: RequestRuntime.check)
        } else { html = text }
        let rich = try main {
            try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        try RequestRuntime.check()
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return [Representation(type: .html, data: Data(html.utf8)), Representation(type: .rtf, data: rtf),
                Representation(type: .string, data: Data(rich.string.utf8))]
    }

    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        private let lock = NSLock()
        private let values: [NSPasteboard.PasteboardType: Data]
        private var active = true, failed = false
        private var reads = 0, lastRead: TimeInterval?
        private var rearmCount = 0
        var ownedCount = 0 // main-thread only
        init(_ representations: [Representation]) { values = Dictionary(uniqueKeysWithValues: representations.map { ($0.type, $0.data) }) }
        var observation: (failed: Bool, reads: Int, lastRead: TimeInterval?) {
            lock.lock(); defer { lock.unlock() }; return (failed, reads, lastRead)
        }
        func stop() { lock.lock(); active = false; lock.unlock() }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.lock(); let enabled = active; lock.unlock()
            guard enabled else { return }
            let success = values[type].map { item.setData($0, forType: type) } ?? false
            lock.lock()
            failed = failed || !success
            if success { reads += 1; lastRead = ProcessInfo.processInfo.systemUptime }
            lock.unlock()
            // Re-arm a read representation, at most 256
            // times, while its pasteboard generation is still owned.
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item else { return }
                self.lock.lock(); let enabled = self.active; self.lock.unlock()
                guard enabled, self.rearmCount < 256, NSPasteboard.general.changeCount == self.ownedCount else { return }
                self.rearmCount += 1
                _ = item.setDataProvider(self, forTypes: [type])
            }
        }
    }
    private final class Transaction {
        let provider: Provider
        let saved: [[Representation]]
        let ownedCount: Int
        init(_ representations: [Representation]) throws {
            precondition(Thread.isMainThread)
            let pb = NSPasteboard.general, count = pb.changeCount
            var saved: [[Representation]] = []
            for item in pb.pasteboardItems ?? [] {
                var values: [Representation] = []
                for type in item.types {
                    guard let data = item.data(forType: type) else {
                        throw ServiceError(.unknownError, "Could not preserve a clipboard representation")
                    }
                    values.append(Representation(type: type, data: data))
                }
                saved.append(values)
            }
            guard pb.changeCount == count else { throw ServiceError(.unknownError, "Clipboard changed while saving it") }
            self.saved = saved
            provider = Provider(representations)
            let item = NSPasteboardItem()
            guard item.setDataProvider(provider, forTypes: representations.map(\.type)) else {
                throw ServiceError(.unknownError, "Could not prepare paste data")
            }
            ownedCount = pb.prepareForNewContents(with: .currentHostOnly)
            provider.ownedCount = ownedCount
            guard pb.writeObjects([item]) else {
                provider.stop()
                if pb.changeCount == ownedCount { _ = Self.restore(saved, into: pb) }
                throw ServiceError(.unknownError, "Could not write paste data")
            }
        }
        var isOwned: Bool { NativePaste.main { NSPasteboard.general.changeCount == ownedCount } }
        func finish() -> Bool {
            precondition(Thread.isMainThread)
            provider.stop()
            let pb = NSPasteboard.general
            guard pb.changeCount == ownedCount else { return true } // a new owner keeps its data
            return Self.restore(saved, into: pb)
        }
        private static func restore(_ saved: [[Representation]], into pb: NSPasteboard) -> Bool {
            pb.prepareForNewContents(with: .currentHostOnly)
            return saved.isEmpty || pb.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for value in values { item.setData(value.data, forType: value.type) }
                return item
            })
        }
    }
    static func perform(_ representations: [Representation], send: () throws -> Void, settle: () throws -> Void) throws {
        try RequestRuntime.check()
        let transaction = try main { try Transaction(representations) }
        var restored = false
        defer { if !restored { _ = main { transaction.finish() } } }
        try RequestRuntime.check()
        try send()
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            try RequestRuntime.check()
            let observed = transaction.provider.observation
            if observed.failed { throw ServiceError(.unknownError, "Could not supply paste data") }
            if !transaction.isOwned {
                guard observed.reads > 0 else { throw ServiceError(.unknownError, "Clipboard changed before the application read paste data") }
                break
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = observed.lastRead, now - last >= 0.1 { break }
            // Poll at .025s with a two-second bound. Successful restoration
            // counts even when no read acknowledgement arrives.
            if now - start >= 2 { break }
            try RequestRuntime.wait(0.025)
        }
        // Keep the data available until the recipient's UI handles the paste,
        // instead of restoring it while a delayed responder is still busy.
        try settle()
        let ok = main { transaction.finish() }; restored = true
        guard ok else { throw ServiceError(.unknownError, "Could not restore the clipboard") }
        try RequestRuntime.check()
    }
}
