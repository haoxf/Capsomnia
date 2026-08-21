enum SleepStateDriftPolicy {
    static func acceptsExternalPrevention(
        desiredState: Bool,
        actualState: Bool,
        respectExternalSleepPrevention: Bool
    ) -> Bool {
        respectExternalSleepPrevention && !desiredState && actualState
    }
}

enum SleepStateOwnershipPolicy {
    static func shouldRestoreOnTerminate(
        capsLockOn: Bool,
        respectExternalSleepPrevention: Bool
    ) -> Bool {
        capsLockOn || !respectExternalSleepPrevention
    }
}
