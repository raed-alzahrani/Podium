import XCTest
@testable import Podium

final class S5L8930XI2CTests: XCTestCase {
    private var line = false
    private var i2c: S5L8930XI2C!
    private var pmu: D1815PMU!

    override func setUp() {
        line = false
        i2c = S5L8930XI2C { [unowned self] asserted in self.line = asserted }
        pmu = D1815PMU()
        i2c.attach(pmu, at: D1815PMU.address)
    }

    /// The register sequence AppleS5L8920XI2CController's transfer routine
    /// writes: address, register byte, count, (data), then the command.
    private func start(address: UInt8, register: UInt8, count: Int, write data: [UInt8]? = nil) {
        i2c.writeRegister(UInt32(address), at: 0x00)
        i2c.writeRegister(UInt32(register), at: 0x10)
        i2c.writeRegister(UInt32(count), at: 0x18)
        for byte in data ?? [] { i2c.writeRegister(UInt32(byte), at: 0x20) }
        i2c.writeRegister(data == nil ? 4 : 5, at: 0x24)
    }

    /// Its interrupt handler: read status, write the same value back.
    private func acknowledgeInterrupt() -> UInt32 {
        let status = i2c.readRegister(at: 0x0C)
        i2c.writeRegister(status, at: 0x0C)
        return status
    }

    func testWriteThenReadBackThroughThePMURegisterFile() {
        start(address: 0x74, register: 0x50, count: 3, write: [0x11, 0x22, 0x33])
        XCTAssertTrue(line)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        XCTAssertFalse(line)
        XCTAssertEqual(Array(pmu.registers[0x50...0x52]), [0x11, 0x22, 0x33])

        start(address: 0x74, register: 0x51, count: 2)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        XCTAssertEqual([i2c.readRegister(at: 0x20), i2c.readRegister(at: 0x20)], [0x22, 0x33])
    }

    /// The codec answers at 0x4a with a real chip ID, the speaker path
    /// unmuted, and mid-scale volume. Both power-down bits make status
    /// bit 3 come up immediately.
    func testCodecReportsSpeakerUnmutedUntilPoweredDown() {
        let codec = CS42L59Codec()
        i2c.attach(codec, at: CS42L59Codec.address)
        start(address: CS42L59Codec.address, register: 0x01, count: 1)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        XCTAssertEqual(i2c.readRegister(at: 0x20), 0x59)

        start(address: CS42L59Codec.address, register: 0x20, count: 1)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        XCTAssertEqual(i2c.readRegister(at: 0x20), 0x18, "master volume reads back above mute")

        start(address: CS42L59Codec.address, register: 0x38, count: 1)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        let awake = i2c.readRegister(at: 0x20)
        XCTAssertEqual(awake & (1 << 3), 0)
        XCTAssertEqual(awake & (1 << 4), 1 << 4, "speaker path is unmuted")
        XCTAssertEqual(awake & (3 << 5), 0, "no accessory, so playback stays on the speaker")

        start(address: CS42L59Codec.address, register: 0x06, count: 1, write: [0x03])
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        start(address: CS42L59Codec.address, register: 0x38, count: 1)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusDone)
        XCTAssertEqual(i2c.readRegister(at: 0x20) & (1 << 3), 1 << 3)
    }

    /// Nothing at the address: the handler sees the not-acknowledged bit
    /// and fails the transfer instead of waiting forever.
    func testTransferToAnAbsentDeviceIsNotAcknowledged() {
        start(address: 0x4A, register: 0, count: 1)
        XCTAssertTrue(line)
        XCTAssertEqual(acknowledgeInterrupt(), S5L8930XI2C.statusNotAcknowledged)
        XCTAssertFalse(line)
    }
}
