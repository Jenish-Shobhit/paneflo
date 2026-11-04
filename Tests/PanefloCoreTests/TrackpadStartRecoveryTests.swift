import Testing
@testable import PanefloCore

struct TrackpadStartRecoveryTests {
    @Test func cleanFailureDropsTheLeaseAndRetriesOnce() {
        #expect(TrackpadStartRecovery.decide(stoppedCleanly: true, attempt: 0) == .discardAndRetry)
        #expect(TrackpadStartRecovery.decide(stoppedCleanly: true, attempt: 1) == .discardAndReport,
                "exactly one extra attempt; the next start still gets a new device")
        #expect(TrackpadStartRecovery.decide(stoppedCleanly: true, attempt: 7) == .discardAndReport)
    }

    @Test func uncleanStopKeepsTheLeaseAndNeverRetries() {
        #expect(TrackpadStartRecovery.decide(stoppedCleanly: false, attempt: 0) == .report,
                "the old device may still hold the callback")
        #expect(TrackpadStartRecovery.decide(stoppedCleanly: false, attempt: 1) == .report)
    }

    @Test func retriesPerStartAreBounded() {
        var attempts = 0
        while TrackpadStartRecovery.decide(stoppedCleanly: true, attempt: attempts) == .discardAndRetry { attempts += 1 }
        #expect(attempts == TrackpadStartRecovery.maximumRetries)
        #expect(attempts == 1)
    }

    @Test func statusReadsAsDecimalAndHex() {
        #expect(TrackpadStartRecovery.describe(status: 268_435_459) == "268435459, 0x10000003")
        #expect(TrackpadStartRecovery.describe(status: 1) == "1, 0x00000001")
        #expect(TrackpadStartRecovery.describe(status: -536_870_212) == "-536870212, 0xE00002BC")
    }
}
