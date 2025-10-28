// Home Programming Language - Threading Error Types

pub const ThreadError = error{
    // Thread errors
    ThreadCreationFailed,
    ThreadJoinFailed,
    ThreadDetachFailed,
    ThreadAlreadyDetached,
    ThreadNotJoinable,
    ThreadDeadlock,
    ThreadNotFound,
    TooManyThreads,

    // Stack errors
    StackAllocationFailed,
    StackTooSmall,
    StackOverflow,

    // Synchronization errors
    MutexLockFailed,
    MutexUnlockFailed,
    MutexAlreadyLocked,
    MutexNotOwned,
    MutexDestroyed,

    // Semaphore errors
    SemaphoreWaitFailed,
    SemaphorePostFailed,
    SemaphoreOverflow,
    SemaphoreInvalid,

    // Condition variable errors
    CondVarWaitFailed,
    CondVarSignalFailed,
    CondVarBroadcastFailed,
    CondVarTimedOut,

    // RwLock errors
    RwLockReadFailed,
    RwLockWriteFailed,
    RwLockUnlockFailed,
    RwLockDeadlock,

    // Barrier errors
    BarrierWaitFailed,
    BarrierDestroyed,

    // TLS errors
    TlsAllocationFailed,
    TlsKeyExhausted,
    TlsKeyInvalid,

    // Scheduling errors
    InvalidPriority,
    InvalidPolicy,
    InvalidCpuSet,
    AffinitySetFailed,
    SchedParamFailed,

    // Resource errors
    OutOfMemory,
    ResourceBusy,
    ResourceExhausted,
    PermissionDenied,

    // General errors
    InvalidArgument,
    OperationNotSupported,
    TimedOut,
    Interrupted,
};
