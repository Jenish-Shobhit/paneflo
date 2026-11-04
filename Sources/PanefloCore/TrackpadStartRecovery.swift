/// What a trackpad start does after the device refused to start or to run. A device object can outlive the
/// multitouch service it was created against (for example across sleep and wake), and then every start on it fails
/// the same way. After a clean stop the lease is dropped so the next start creates a new device, and the same start
/// tries once more on that new device before it reports. After an unclean stop the lease is kept: the old device may
/// still hold the callback, so nothing new is created.
public enum TrackpadStartRecovery {
    public enum Decision: Sendable, Equatable {
        /// Keep the device lease and report the failure.
        case report
        /// Drop the device lease and report the failure; the next start creates a new device.
        case discardAndReport
        /// Drop the device lease and try once more right away on a new device.
        case discardAndRetry
    }

    /// Extra attempts one start may make on a new device.
    public static let maximumRetries = 1

    /// `attempt` counts from 0 (the first try within one start).
    public static func decide(stoppedCleanly: Bool, attempt: Int) -> Decision {
        guard stoppedCleanly else { return .report }
        return attempt < maximumRetries ? .discardAndRetry : .discardAndReport
    }

    /// A start status as decimal and as its 32-bit hex form, for example `268435459, 0x10000003`.
    public static func describe(status: Int32) -> String {
        let hex = String(UInt32(bitPattern: status), radix: 16, uppercase: true)
        return "\(status), 0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}
