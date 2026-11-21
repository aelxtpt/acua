import Foundation

@main
enum TreeTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name + " unexpectedly succeeded") }
            catch is ServiceError { passed += 1; print("PASS \(name)") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let sections = [TreeSection(key: "window", title: "Example")]
        func node(_ reference: String, _ identifier: String? = nil, title: String? = nil,
                  value: String? = nil, parent: Int? = 0, section: String = "window") -> TreeNode<String> {
            TreeNode(reference: reference, description: ElementDescription(role: parent == nil ? "AXWindow" : "AXButton",
                     identifier: identifier, title: title, value: value), parent: parent, section: section)
        }
        var base = [node("window", title: "Example", parent: nil)]
        base += (0..<12).map { node("button\($0)", "button-\($0)", title: "Button \($0)") }
        var store = TreeRevisionStore<String>()
        let initial = try store.update(session: "pid:1", sections: sections, nodes: base, appName: "Example")
        let id = initial.entries[4].id
        check("first observation returns a complete tree", !initial.isDiff && initial.text == initial.fullText)
        check("first observation has one ID for every node", Set(initial.entries.map(\.id)).count == base.count)
        let same = try store.update(session: "pid:1", sections: sections, nodes: base, appName: "Example")
        check("unchanged observation keeps all IDs", same.entries.map(\.id) == initial.entries.map(\.id))
        check("unchanged observation emits the no-change message", same.isDiff && same.text.hasPrefix("There has been no change in the accessibility tree for "))
        check("revision numbers advance", same.number == initial.number + 1)
        var withInserted = base
        withInserted.insert(node("new", "new-control", title: "Inserted"), at: 1)
        let inserted = try store.update(session: "pid:1", sections: sections, nodes: withInserted, appName: "Example")
        check("insertion does not renumber existing elements", inserted.entries.first { $0.reference == "button3" }?.id == id)
        check("new control receives a fresh ID", inserted.entries[1].id > initial.entries.last!.id)
        check("small insertion produces an incremental tree", inserted.isDiff && inserted.text.contains("+    ["))
        check("diff includes parent context", inserted.text.contains(" [0] AXWindow"))
        let target = inserted.entries.first { $0.reference == "button3" }!
        var replaced = withInserted
        let targetIndex = replaced.firstIndex { $0.reference == "button3" }!
        replaced[targetIndex] = node("replacement", "button-3", title: "Button 3")
        let recovered = try store.update(session: "pid:1", sections: sections, nodes: replaced, appName: "Example")
        check("unique recreated control retains its logical ID", recovered.entries[targetIndex].id == target.id)
        check("stale control resolves to the new reference", try recovered.validatedElement(expected: target).reference == "replacement")
        check("internal recovery can be previewed without mutating publication", store.current?.number == recovered.number)
        var preview = store
        var changed = replaced
        changed[targetIndex] = node("replacement2", "button-3", title: "Different action")
        let changedRevision = try preview.update(session: "pid:1", sections: sections, nodes: changed, appName: "Example")
        check("explicit identifier preserves ID continuity across label changes", changedRevision.entries[targetIndex].id == target.id)
        rejects("an old target cannot silently become a relabeled action") { _ = try changedRevision.validatedElement(expected: target) }
        check("rejected preview leaves observed baseline intact", store.current?.fullText == recovered.fullText)
        let forced = try store.update(session: "pid:1", sections: sections, nodes: replaced, appName: "Example", forceFull: true)
        check("disableDiff forces the complete tree even when unchanged", !forced.isDiff && forced.text == forced.fullText)
        var valueBase = replaced
        valueBase[targetIndex] = node("replacement", "button-3", title: "Button 3", value: "old")
        let oldValue = try store.update(session: "pid:1", sections: sections, nodes: valueBase, appName: "Example")
        let oldTarget = oldValue.entries[targetIndex]
        valueBase[targetIndex] = node("replacement3", "button-3", title: "Button 3", value: "new")
        let newValue = try store.update(session: "pid:1", sections: sections, nodes: valueBase, appName: "Example")
        rejects("value-sensitive recovery rejects a changed value") { _ = try newValue.validatedElement(expected: oldTarget) }
        check("explicit ignore-value recovery still identifies the intended control", try newValue.validatedElement(expected: oldTarget, ignoreValueChange: true).reference == "replacement3")
        var duplicates = valueBase
        duplicates[targetIndex] = node("duplicate1", "button-3", title: "Button 3", value: "new")
        duplicates.append(node("duplicate2", "button-3", title: "Button 3", value: "new"))
        let ambiguous = try store.update(session: "pid:1", sections: sections, nodes: duplicates, appName: "Example")
        check("ambiguous recreated controls receive fresh IDs", ambiguous.entry(newValue.entries[targetIndex].id) == nil)
        rejects("ambiguous recovery cannot select the first candidate") { _ = try ambiguous.validatedElement(expected: newValue.entries[targetIndex]) }
        let removedIDs = ambiguous.entries.filter { $0.description.identifier == "button-3" }.map(\.id)
        let removed = try store.update(session: "pid:1", sections: sections, nodes: base, appName: "Example")
        check("removed IDs are reported", removedIDs.allSatisfy { removed.text.contains(String($0)) })
        check("removed IDs cannot select another control", removedIDs.allSatisfy { removed.entry($0) == nil })
        let counterBefore = store.nextID
        let restarted = try store.update(session: "pid:2", sections: sections, nodes: base, appName: "Example")
        check("new process begins with a full tree", !restarted.isDiff)
        check("new process does not reuse earlier IDs", restarted.entries.allSatisfy { $0.id >= counterBefore })
        var reordered = base
        reordered.swapAt(1, 2)
        let moved = try store.update(session: "pid:2", sections: sections, nodes: reordered, appName: "Example")
        check("reordering retains element IDs", Set(moved.entries.map(\.id)) == Set(restarted.entries.map(\.id)))
        check("reordering reports moves", moved.changes.contains { $0.kind == .moved })
        var changedDescription = reordered
        changedDescription[3] = node(reordered[3].reference, reordered[3].description.identifier, title: "Updated")
        let budget = try store.update(session: "pid:2", sections: sections, nodes: changedDescription, appName: "Example", maxDiffLines: 0)
        check("over-budget differences fall back to the full tree", !budget.isDiff && budget.text == budget.fullText)
        let truncated = try store.update(session: "pid:2", sections: sections, nodes: changedDescription, appName: "Example", truncated: true)
        check("partial tree is explicitly marked and never treated as a delta", !truncated.isDiff && truncated.text.contains("truncated"))
        var recreatedPartial = changedDescription
        recreatedPartial[3] = node("partial-replacement", changedDescription[3].description.identifier, title: "Updated")
        let incomplete = try store.update(session: "pid:2", sections: sections, nodes: recreatedPartial, appName: "Example", truncated: true)
        rejects("a partial scan cannot prove unique replacement") { _ = try incomplete.validatedElement(expected: truncated.entries[3]) }
        let recoveredFull = try store.update(session: "pid:2", sections: sections, nodes: recreatedPartial, appName: "Example")
        check("first complete scan after truncation restores full context", !recoveredFull.isDiff)
        let beforeFailure = store.current!.number, beforeCounter = store.nextID
        rejects("forward parent pointers are rejected") {
            _ = try store.update(session: "pid:2", sections: sections, nodes: [node("bad", parent: 1)], appName: "Example")
        }
        rejects("duplicate references are rejected") {
            _ = try store.update(session: "pid:2", sections: sections, nodes: [base[0], base[0]], appName: "Example")
        }
        rejects("unknown window scope is rejected") {
            _ = try store.update(session: "pid:2", sections: sections, nodes: [node("bad", parent: nil, section: "unknown")], appName: "Example")
        }
        rejects("cancelled revision does not publish") {
            _ = try store.update(session: "pid:2", sections: sections, nodes: base, appName: "Example", check: { throw ServiceError(.unknownError, "cancelled") })
        }
        check("failed revisions preserve both baseline and next ID", store.current?.number == beforeFailure && store.nextID == beforeCounter)
        var exhausted = TreeRevisionStore<String>(nextID: Int.max)
        rejects("ID exhaustion fails without overflow") { _ = try exhausted.update(session: "x", sections: sections, nodes: base, appName: "Example") }
        check("ID exhaustion cannot publish a partial tree", exhausted.current == nil && exhausted.nextID == Int.max)
        var noIdentifier = TreeRevisionStore<String>()
        let plain = [node("root", title: "Example", parent: nil), node("plain", title: "Unique caption")]
        let plainOld = try noIdentifier.update(session: "x", sections: sections, nodes: plain, appName: "Example")
        let plainNew = try noIdentifier.update(session: "x", sections: sections, nodes: [plain[0], node("plain-new", title: "Unique caption")], appName: "Example")
        check("a unique full fingerprint can recover a control without an identifier", try plainNew.validatedElement(expected: plainOld.entries[1]).reference == "plain-new")
        let anonymous = [node("root", title: "Example", parent: nil), node("anonymous")]
        var anonymousStore = TreeRevisionStore<String>()
        let anonymousOld = try anonymousStore.update(session: "x", sections: sections, nodes: anonymous, appName: "Example")
        let anonymousNew = try anonymousStore.update(session: "x", sections: sections, nodes: [anonymous[0], node("other-anonymous")], appName: "Example")
        check("anonymous controls are never guessed from position", anonymousNew.entries[1].id != anonymousOld.entries[1].id)
        var multi = TreeRevisionStore<String>()
        let two = [TreeSection(key: "a", title: "A"), TreeSection(key: "b", title: "B")]
        let twoNodes = [node("wa", title: "A", parent: nil, section: "a"), node("a", "same-id", title: "Same", parent: 0, section: "a"),
                        node("wb", title: "B", parent: nil, section: "b"), node("b", "same-id", title: "Same", parent: 2, section: "b")]
        let multiOld = try multi.update(session: "x", sections: two, nodes: twoNodes, appName: "Example")
        var newTwo = twoNodes
        newTwo[1] = node("a-new", "same-id", title: "Same", parent: 0, section: "a")
        let multiNew = try multi.update(session: "x", sections: two, nodes: newTwo, appName: "Example")
        check("recovery is scoped to its own window", try multiNew.validatedElement(expected: multiOld.entries[1]).reference == "a-new")
        check("other window with matching identifier remains separate", multiNew.entries[1].id != multiNew.entries[3].id)
        let hostile = ElementDescription(role: "AXButton", title: "a\"\n[999] forged\\value")
        check("rendered attributes cannot inject tree lines", !hostile.line(id: 2, depth: 0).contains("\n"))
        check("backslashes and quotes are escaped", hostile.line(id: 2, depth: 0).contains("\\\"") && hostile.line(id: 2, depth: 0).contains("\\\\value"))
        check("invalid geometry cannot crash integer rendering", ElementFrame(x: .infinity, y: 0, width: 2, height: 2).rendered == nil)
        check("out-of-range geometry cannot overflow", ElementFrame(x: .greatestFiniteMagnitude, y: 0, width: 2, height: 2).rendered == nil)
        var cancellationChecks = 0
        let atomicNumber = store.current!.number, atomicNext = store.nextID
        rejects("cancellation midway through construction does not publish") {
            _ = try store.update(session: "pid:2", sections: sections, nodes: base, appName: "Example", check: {
                cancellationChecks += 1
                if cancellationChecks == 20 { throw ServiceError(.unknownError, "cancelled mid-build") }
            })
        }
        check("mid-build cancellation preserves revision and ID counter", store.current?.number == atomicNumber && store.nextID == atomicNext)
        var randomized = TreeRevisionStore<String>(), model = base, seed: UInt64 = 0xC0A2026
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        var before = try randomized.update(session: "fuzz", sections: sections, nodes: model, appName: "Example")
        for step in 0..<150 {
            switch random(6) {
            case 0:
                model.append(node("added-\(step)", "added-\(step)", title: "Added \(step)"))
            case 1 where model.count > 2:
                model.remove(at: 1 + random(model.count - 1))
            case 2 where model.count > 1:
                let index = 1 + random(model.count - 1), prior = model[index]
                var description = prior.description; description.title = "Updated \(step)"
                model[index] = TreeNode(reference: prior.reference, description: description, parent: prior.parent, section: prior.section)
            case 3 where model.count > 1:
                let index = 1 + random(model.count - 1), prior = model[index]
                model[index] = TreeNode(reference: "recreated-\(step)", description: prior.description, parent: prior.parent, section: prior.section)
            case 4 where model.count > 2:
                model.swapAt(1 + random(model.count - 1), 1 + random(model.count - 1))
            default:
                if model.count > 1 {
                    let index = 1 + random(model.count - 1), prior = model[index]
                    var description = prior.description
                    description.frame = ElementFrame(x: Double(step), y: 2, width: 20, height: 10)
                    model[index] = TreeNode(reference: prior.reference, description: description, parent: prior.parent, section: prior.section)
                }
            }
            let after = try randomized.update(session: "fuzz", sections: sections, nodes: model, appName: "Example")
            var reconstructed = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.id, $0) })
            for change in after.changes {
                if let entry = change.after { reconstructed[entry.id] = entry }
                else if let entry = change.before { reconstructed.removeValue(forKey: entry.id) }
            }
            precondition(Set(reconstructed.keys) == Set(after.entries.map(\.id)), "delta lost IDs at step \(step)")
            for entry in after.entries {
                let applied = reconstructed[entry.id]!
                precondition(applied.description == entry.description && applied.parentID == entry.parentID &&
                             applied.section == entry.section && applied.predecessorID == entry.predecessorID,
                             "delta could not reconstruct step \(step)")
            }
            let earlierIDs = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.reference, $0.id) })
            for entry in after.entries {
                if let retained = earlierIDs[entry.reference] { precondition(retained == entry.id, "renumbered surviving reference") }
            }
            before = after
        }
        check("150 seeded mutation sequences reconstruct from their differences", true)
        check("random insert/remove/reorder/recreation sequences keep surviving IDs", true)
        var identities = TreeRevisionStore<String>()
        let identityOld = try identities.update(session: "x", sections: sections, nodes: base, appName: "Example")
        var roleChanged = base
        var newRole = roleChanged[1].description; newRole.role = "AXTextField"
        roleChanged[1] = TreeNode(reference: roleChanged[1].reference, description: newRole, parent: 0, section: "window")
        let identityNew = try identities.update(session: "x", sections: sections, nodes: roleChanged, appName: "Example")
        check("a reused reference with a different role receives a new ID", identityOld.entries[1].id != identityNew.entries[1].id)
        rejects("a reused reference cannot validate a former role") { _ = try identityNew.validatedElement(expected: identityOld.entries[1]) }
        var newIdentifier = roleChanged[1].description; newIdentifier.identifier = "different-logical-item"
        roleChanged[1] = TreeNode(reference: roleChanged[1].reference, description: newIdentifier, parent: 0, section: "window")
        let identityAgain = try identities.update(session: "x", sections: sections, nodes: roleChanged, appName: "Example")
        check("a reused reference with a different identifier receives a new ID", identityNew.entries[1].id != identityAgain.entries[1].id)
        var bulk = TreeRevisionStore<String>()
        let largeNodes = [node("bulk-window", title: "Example", parent: nil)] + (0..<4999).map { node("bulk-\($0)", "bulk-id-\($0)", title: "Bulk \($0)") }
        let largeOld = try bulk.update(session: "large", sections: sections, nodes: largeNodes, appName: "Example")
        let largeReplacement = [largeNodes[0]] + largeNodes.dropFirst().map { TreeNode(reference: "new-" + $0.reference, description: $0.description, parent: $0.parent, section: $0.section) }
        let largeNew = try bulk.update(session: "large", sections: sections, nodes: largeReplacement, appName: "Example")
        check("5000-node recreation keeps each unique logical ID", largeOld.entries.map(\.id) == largeNew.entries.map(\.id))
        check("recreation at the traversal limit still validates the final control", try largeNew.validatedElement(expected: largeOld.entries.last!).reference == "new-bulk-4998")
        let beforeInvalidation = bulk.nextID
        bulk.invalidate()
        let afterInvalidation = try bulk.update(session: "large", sections: sections, nodes: [largeNodes[0]], appName: "Example")
        check("session invalidation drops the old tree and restores full context", !afterInvalidation.isDiff && afterInvalidation.entries.count == 1)
        check("session invalidation never recycles previously exposed IDs", afterInvalidation.entries[0].id >= beforeInvalidation)
        print("\(passed) revision/recovery checks passed")
    }
}
