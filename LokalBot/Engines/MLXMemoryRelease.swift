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

    /// Frees the pool once it holds more than `limit` bytes, between the
    /// passes of an engine that runs many inputs of different sizes back to
    /// back. The result is the bytes freed, or 0 when the pool was within it.
    @discardableResult
    static func trimCachedBuffers(above limit: Int) -> Int {
        let cached = Memory.cacheMemory
        guard cached > limit else { return 0 }
        Memory.clearCache()
        return cached
    }
}
