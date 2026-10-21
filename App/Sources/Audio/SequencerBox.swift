import Foundation
import AGRCore

/// Hand-over point between the main thread (which builds `SequencerEngine`s) and the audio render callback.
///
/// Design (mirrors the guard `SequencerEngine` uses for its own commands, see its header):
/// * `current` is touched by the audio thread only.
/// * `submit` (main) stores a new engine in `pending` under a `pthread_mutex_t`.
/// * `render` (audio) only ever uses `pthread_mutex_trylock`: if main holds the lock for its few nanoseconds the swap
///   simply happens one block later. The audio thread never blocks, waits or allocates.
/// * The engine being replaced is parked in `retired` instead of being released on the audio thread (deallocation
///   frees the synth's buffers - not real-time safe). The main thread drains `retired` on the next `submit` /
///   `releaseAll` and frees it there. `submit` drains and publishes in one critical section, so there is at most one
///   retired engine at any time.
final class SequencerBox: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var current: SequencerEngine?   // audio thread only
    private var pending: SequencerEngine?   // guarded by lock
    private var retired: SequencerEngine?   // guarded by lock

    init() {
        lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
    }

    deinit {
        pthread_mutex_destroy(lock)
        lock.deallocate()
    }

    // MARK: Main thread

    /// Publishes `engine`; the audio thread switches to it at the start of its next render block.
    func submit(_ engine: SequencerEngine) {
        pthread_mutex_lock(lock)
        let droppedPending = pending      // never reached the audio thread
        let oldRetired = retired
        retired = nil
        pending = engine
        pthread_mutex_unlock(lock)
        // `droppedPending` / `oldRetired` are released here, on the calling (main) thread.
        withExtendedLifetime((droppedPending, oldRetired)) {}
    }

    /// Frees everything. Only call while the render callback cannot run (the AVAudioEngine is stopped).
    func releaseAll() {
        pthread_mutex_lock(lock)
        let p = pending, r = retired
        pending = nil
        retired = nil
        let c = current
        current = nil
        pthread_mutex_unlock(lock)
        withExtendedLifetime((p, r, c)) {}
    }

    // MARK: Audio thread

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if pthread_mutex_trylock(lock) == 0 {
            if let next = pending, retired == nil {
                retired = current
                current = next
                pending = nil
            }
            pthread_mutex_unlock(lock)
        }
        if let engine = current {
            engine.render(into: buffer, frameCount: frameCount)
        } else {
            buffer.initialize(repeating: 0, count: frameCount)
        }
    }
}
