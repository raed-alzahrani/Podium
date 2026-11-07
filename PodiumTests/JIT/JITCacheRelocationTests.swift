import XCTest
@testable import Podium

final class JITCacheRelocationTests: XCTestCase {
    private let window: UInt64 = 64 << 20
    /// Bases from two real launches. The region moves with host ASLR.
    private let savedRX: UInt64 = 0x1_50f8_c000
    private let currentRX: UInt64 = 0x1_102a_8000
    private let savedRW: UInt64 = 0x2_80ab_0000
    private let currentRW: UInt64 = 0x2_10cc_4000

    func testExecutablePointerBecomesAnOffsetThenTheCurrentBase() {
        let target = savedRX + 0x4000
        var words = pointer(target, register: 3)
        let relocations = JITCacheImage.relativize(&words, rx: savedRX, rw: savedRW, window: window)
        XCTAssertEqual(relocations, [JITCacheImage.Relocation(wordIndex: 0, kind: JITCacheImage.kindExecutable)])
        XCTAssertEqual(JITCacheImage.chainedValue(words, at: 0), 0x4000)

        XCTAssertTrue(JITCacheImage.rebase(&words, relocations: relocations ?? [], rx: currentRX, rw: currentRW, window: window))
        XCTAssertEqual(JITCacheImage.chainedValue(words, at: 0), currentRX + 0x4000)
    }

    func testWritableAliasUsesTheWritableBase() {
        let target = savedRW + 0x8100
        var words = pointer(target, register: 4)
        let relocations = JITCacheImage.relativize(&words, rx: savedRX, rw: savedRW, window: window)
        XCTAssertEqual(relocations, [JITCacheImage.Relocation(wordIndex: 0, kind: JITCacheImage.kindWritable)])

        XCTAssertTrue(JITCacheImage.rebase(&words, relocations: relocations ?? [], rx: currentRX, rw: currentRW, window: window))
        XCTAssertEqual(JITCacheImage.chainedValue(words, at: 0), currentRW + 0x8100)
    }

    func testGuestConstantOutsideTheRegionIsLeftAlone() {
        var assembler = A64Assembler()
        assembler.mov(x: 1, 0x0000_0000_0000_1234)
        let original = assembler.finalizedWords()
        var words = original
        let relocations = JITCacheImage.relativize(&words, rx: savedRX, rw: savedRW, window: window)
        XCTAssertEqual(relocations?.count, 0)
        XCTAssertEqual(words, original)
    }

    func testOffsetPastTheRegionIsRejected() {
        var words = pointer(window, register: 2)
        let relocations = [JITCacheImage.Relocation(wordIndex: 0, kind: JITCacheImage.kindExecutable)]
        XCTAssertFalse(JITCacheImage.rebase(&words, relocations: relocations, rx: currentRX, rw: currentRW, window: window))
    }

    func testAddressThatDoesNotFitTheSavedSlotsIsRejected() {
        // Only the low 16 bits have a slot. The new base needs bit 32.
        var words = [UInt32(0xD280_0000 | (1 << 5))]
        let relocations = [JITCacheImage.Relocation(wordIndex: 0, kind: JITCacheImage.kindExecutable)]
        XCTAssertFalse(JITCacheImage.rebase(&words, relocations: relocations, rx: 0x1_0000_0000, rw: 0, window: window))
    }

    func testBranchIntoTheRegionStaysAndABranchPastItDoesNot() {
        let backToEntry = UInt32(bitPattern: Int32(-100)) & 0x03FF_FFFF
        var words = [0x1400_0000 | backToEntry]
        XCTAssertTrue(JITCacheImage.jumpsStayInRegion(words, regionWord: 100, regionWords: 16_777_216))

        words = [0x1400_0000 | 50]
        XCTAssertFalse(JITCacheImage.jumpsStayInRegion(words, regionWord: 100, regionWords: 120))
    }

    private func pointer(_ value: UInt64, register: Int) -> [UInt32] {
        var assembler = A64Assembler()
        assembler.mov(x: register, value)
        return assembler.finalizedWords()
    }
}
