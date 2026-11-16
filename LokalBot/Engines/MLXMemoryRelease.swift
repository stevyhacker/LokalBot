import Foundation
import MLX

/// MLX keeps freed GPU buffers in a process-wide pool for reuse. Dropping a
/// model reference does not return that pool to the system: after one meeting
/// LokalBot held 4.3 GB of GPU memory while idle (peak footprint 11.1 GB),
/// the Qwen3-ASR scratch cap. Every MLX engine releases the pool when it
/// unloads. Buffers still in use by another loaded model are unaffected.
enum MLXMemoryRelease {
    static func releaseCachedBuffers(after label: String) {
        let cached = Memory.cacheMemory
        Memory.clearCache()
        lokalbotLog("mlx cache released after=\(label) bytes=\(cached) active=\(Memory.activeMemory)")
    }
}
