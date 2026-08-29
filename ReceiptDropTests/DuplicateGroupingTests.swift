import XCTest
@testable import ReceiptDrop

/// Tests `DuplicateDetectionService.findGroups` — the layer on top of
/// `findPairs` that collapses an `.identicalFile` cluster of N entries into
/// one group instead of N*(N-1)/2 pairs. See `findGroups`'s doc comment for
/// the full transitivity argument; these tests cover the user-visible
/// consequence of getting that argument wrong.
final class DuplicateGroupingTests: XCTestCase {
    private func makeEntry(vendor: String, workDate: String, amount: String,
                           category: String = "Test", fileHash: String = "",
                           timestamp: Date = Date()) -> HistoryEntry {
        HistoryEntry(
            category: category, vendor: vendor, workDate: workDate, amount: amount,
            receiptLink: "\(UUID().uuidString).jpg", timestamp: timestamp, fileHash: fileHash)
    }

    /// The exact real-world regression this feature exists to fix: one
    /// $5700.00 receipt filed three times under a shared fileHash — two
    /// "Noom" entries (work dates 2026-08-29 and 2026-07-24) and one
    /// "Armando cabinets" entry (2026-08-28, a vendor misread on the third
    /// scan that didn't stop the hash from matching), in two different
    /// categories. Before `findGroups` existed, `findPairs` alone rendered
    /// this as THREE separate "Duplicate — Same File" cards (one per pair
    /// among the 3 entries), each showing only 2 of the 3 copies with no
    /// card ever showing all three, or telling the user there were three
    /// total. This must now collapse to exactly ONE group containing all
    /// three entries.
    func testThreeCopiesOfOneReceiptCollapseToOneGroupNotThreeGroups() throws {
        let sharedHash = ReceiptFileHash.hash(of: Data("noom-and-armando-shared-file".utf8))
        let noomLater = makeEntry(vendor: "Noom", workDate: "2026-08-29", amount: "5700.00",
                                   category: "Health", fileHash: sharedHash)
        let noomEarlier = makeEntry(vendor: "Noom", workDate: "2026-07-24", amount: "5700.00",
                                     category: "Health", fileHash: sharedHash)
        let armando = makeEntry(vendor: "Armando cabinets", workDate: "2026-08-28", amount: "5700.00",
                                 category: "Home Improvement", fileHash: sharedHash)

        let groups = DuplicateDetectionService.findGroups(in: [noomLater, noomEarlier, armando])

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.confidence, .identicalFile)
        XCTAssertEqual(Set(group.entries.map(\.id)), Set([noomLater.id, noomEarlier.id, armando.id]))
    }

    /// Four copies of one file must produce one group of 4, not
    /// 4*(4-1)/2 = 6 pairs each rendered as its own card.
    func testFourCopiesOfOneReceiptCollapseToOneGroupOfFour() {
        let sharedHash = ReceiptFileHash.hash(of: Data("four-copies-shared-file".utf8))
        let entries = (0..<4).map { i in
            makeEntry(vendor: "Costco", workDate: "2026-0\(i + 1)-01", amount: "88.88", fileHash: sharedHash)
        }

        let groups = DuplicateDetectionService.findGroups(in: entries)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.entries.count, 4)
        XCTAssertEqual(groups.first?.confidence, .identicalFile)
    }

    /// Two independent hash clusters (e.g. two different receipts, each
    /// scanned twice) must never merge into each other — union-find only
    /// connects entries that actually share a fileHash somewhere in the
    /// chain, so an unrelated cluster sitting alongside one shouldn't bleed
    /// into it.
    func testTwoSeparateHashClustersProduceTwoSeparateGroupsWithNoCrossContamination() {
        let hashA = ReceiptFileHash.hash(of: Data("cluster-a-file".utf8))
        let hashB = ReceiptFileHash.hash(of: Data("cluster-b-file".utf8))
        let a1 = makeEntry(vendor: "Shell", workDate: "2026-01-01", amount: "40.00", fileHash: hashA)
        let a2 = makeEntry(vendor: "Shell", workDate: "2026-01-02", amount: "40.00", fileHash: hashA)
        let b1 = makeEntry(vendor: "Walgreens", workDate: "2026-02-01", amount: "5.00", fileHash: hashB)
        let b2 = makeEntry(vendor: "Walgreens", workDate: "2026-02-05", amount: "5.00", fileHash: hashB)

        let groups = DuplicateDetectionService.findGroups(in: [a1, a2, b1, b2])

        XCTAssertEqual(groups.count, 2)
        let entrySets = Set(groups.map { Set($0.entries.map(\.id)) })
        XCTAssertTrue(entrySets.contains(Set([a1.id, a2.id])))
        XCTAssertTrue(entrySets.contains(Set([b1.id, b2.id])))
    }

    /// A fuzzy (non-identicalFile) pair stays pairwise even when one of its
    /// members also happens to belong to an identical-file cluster — the
    /// two groups must stay separate, not merge, since "A resembles C" was
    /// never actually detected just because "A is the same file as B" and
    /// "B resembles C" both happen to be true.
    func testFuzzyPairStaysSeparateFromAnIdenticalFileGroupEvenWhenSharingAnEntry() throws {
        let sharedHash = ReceiptFileHash.hash(of: Data("identical-file-cluster".utf8))
        // A and B: identical file.
        let a = makeEntry(vendor: "Home Depot", workDate: "2026-03-01", amount: "60.00", fileHash: sharedHash)
        let b = makeEntry(vendor: "Home Depot", workDate: "2026-03-15", amount: "60.00", fileHash: sharedHash)
        // C: same date+amount as B (Signal 1 → .likely, since vendor also
        // matches), but a different, empty fileHash — never grouped with A/B.
        let c = makeEntry(vendor: "Home Depot", workDate: "2026-03-15", amount: "60.00", fileHash: "")

        let groups = DuplicateDetectionService.findGroups(in: [a, b, c])

        XCTAssertEqual(groups.count, 2)
        let identicalGroup = try XCTUnwrap(groups.first { $0.confidence == .identicalFile })
        XCTAssertEqual(Set(identicalGroup.entries.map(\.id)), Set([a.id, b.id]))
        let fuzzyGroup = try XCTUnwrap(groups.first { $0.confidence != .identicalFile })
        XCTAssertEqual(Set(fuzzyGroup.entries.map(\.id)), Set([b.id, c.id]))
    }

    /// Entries within an identical-file group are ordered oldest-timestamp-
    /// first, regardless of the order they were passed in or the order
    /// union-find happened to visit them — so the card doesn't reshuffle
    /// its row order between reloads.
    func testEntriesWithinAnIdenticalFileGroupAreOrderedOldestTimestampFirst() {
        let sharedHash = ReceiptFileHash.hash(of: Data("ordering-shared-file".utf8))
        let newest = makeEntry(vendor: "Noom", workDate: "2026-08-29", amount: "5700.00",
                                fileHash: sharedHash, timestamp: Date(timeIntervalSince1970: 3000))
        let oldest = makeEntry(vendor: "Noom", workDate: "2026-07-24", amount: "5700.00",
                                fileHash: sharedHash, timestamp: Date(timeIntervalSince1970: 1000))
        let middle = makeEntry(vendor: "Armando cabinets", workDate: "2026-08-28", amount: "5700.00",
                                fileHash: sharedHash, timestamp: Date(timeIntervalSince1970: 2000))

        // Deliberately passed in an order that doesn't match timestamp order.
        let groups = DuplicateDetectionService.findGroups(in: [newest, middle, oldest])

        XCTAssertEqual(groups.first?.entries.map(\.id), [oldest.id, middle.id, newest.id])
    }

    /// `.identicalFile` groups must sort above `.likely` groups — the
    /// highest-confidence signal has to actually surface first on the
    /// review screen, same guarantee `findPairs` already provides for pairs.
    func testIdenticalFileGroupsSortAboveLikelyGroups() {
        let sharedHash = ReceiptFileHash.hash(of: Data("group-ordering-shared-file".utf8))
        let likelyA = makeEntry(vendor: "Costco", workDate: "2026-03-01", amount: "88.88", fileHash: "")
        let likelyB = makeEntry(vendor: "Costco", workDate: "2026-03-01", amount: "88.88", fileHash: "")
        let hashedA = makeEntry(vendor: "Walgreens", workDate: "2026-04-01", amount: "5.00", fileHash: sharedHash)
        let hashedB = makeEntry(vendor: "Walgreens", workDate: "2026-06-01", amount: "5.00", fileHash: sharedHash)

        let groups = DuplicateDetectionService.findGroups(in: [likelyA, likelyB, hashedA, hashedB])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.confidence, .identicalFile)
        XCTAssertEqual(groups.last?.confidence, .likely)
    }
}
