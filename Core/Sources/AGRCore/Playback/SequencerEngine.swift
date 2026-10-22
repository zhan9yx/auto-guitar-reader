import Foundation

// MARK: - SequencerEngine
//
// Schedules NoteEvents against a sample clock and drives a GuitarSynth. Used by the app's
// AVAudioSourceNode render block and by OfflineRenderer.
//
// Sample accuracy: `render` splits the block at every scheduled item, so a pluck due at sample S is
// triggered exactly before sample S is generated.
//
// Thread-safety design (documented choice): the app calls `seek` / `isPlaying` / `positionSeconds` from the main
// thread while `render` runs on the audio thread. A tiny shared struct (pending commands + a mirror of the audio
// thread's position) is guarded by a `pthread_mutex_t` (available on Darwin and Linux alike).
// * The audio thread only ever uses `pthread_mutex_trylock`: if the main thread happens to hold the lock for its few
//   nanoseconds, the audio thread simply applies the commands on the next block (one block of latency) and skips
//   publishing the position. It never blocks, allocates, or waits.
// * The main thread uses a blocking lock; critical sections are a handful of loads/stores.
// All other state (schedule, synth, clicks) is touched only by the audio thread.

public final class SequencerEngine {
    public let synth: GuitarSynth
    public let sampleRate: Double

    private struct Item {
        var sample: Int
        var kind: UInt8        // 0 = mute, 1 = pluck, 2 = click, 3 = melody off, 4 = melody on
        var midi: Int32
        var string: Int32
        var velocity: Float
        var id: Int32
    }

    private let items: UnsafeMutablePointer<Item>
    private let itemCount: Int
    private let activeID: UnsafeMutablePointer<Int32>
    private var nextItem = 0
    private var pos = 0                 // frames since start of the piece
    private var playing = false

    // Click voice.
    private var clickRemaining = 0
    private var clickIndex = 0
    private var clickAmp: Float = 0
    private var clickPhase: Float = 0
    private var clickStep: Float = 0
    private var clickNoise: UInt32 = 0x2468_ACE1
    private let clickLength: Int

    // Melody voice (monophonic, soft sine-ish with a slow pluck decay).
    private var melodyOn = false
    private var melodyID: Int32 = -1
    private var melodyPhase: Double = 0
    private var melodyStep: Double = 0
    private var melodyAmp: Float = 0
    private var melodyEnv: Float = 0
    private var melodyDecay: Float = 1
    private var melodyAttack: Float = 0
    private var melodyRelease: Float = 0

    // Shared state (guarded by `lock`).
    private let lock: UnsafeMutablePointer<pthread_mutex_t>
    private var pendingPlaying: Bool?
    private var pendingSeek: Double?
    private var mirrorPosition: Double = 0
    private var mirrorPlaying = false

    /// End of the last scheduled note (seconds).
    public let durationSeconds: Double

    public init(sampleRate: Double, events: [NoteEvent]) {
        self.sampleRate = sampleRate
        self.synth = GuitarSynth(sampleRate: sampleRate)
        self.clickLength = max(Int(0.02 * sampleRate), 8)
        var list: [Item] = []
        list.reserveCapacity(events.count * 2)
        var end = 0.0
        for (i, e) in events.enumerated() {
            let s = max(Int((e.time * sampleRate).rounded()), 0)
            if e.isMelody {
                list.append(Item(sample: s, kind: 4, midi: Int32(e.midi), string: 0, velocity: e.velocity, id: Int32(i)))
                let off = Int(((e.time + e.duration) * sampleRate).rounded())
                list.append(Item(sample: max(off, s), kind: 3, midi: 0, string: 0, velocity: 0, id: Int32(i)))
                end = max(end, e.time + e.duration)
                continue
            }
            if e.isClick {
                list.append(Item(sample: s, kind: 2, midi: 0, string: 0, velocity: e.velocity, id: Int32(i)))
                continue
            }
            list.append(Item(sample: s, kind: 1, midi: Int32(e.midi), string: Int32(e.stringIndex),
                             velocity: e.velocity, id: Int32(i)))
            if e.duration > 0 {
                let off = Int(((e.time + e.duration) * sampleRate).rounded())
                list.append(Item(sample: max(off, s), kind: 0, midi: 0, string: Int32(e.stringIndex),
                                 velocity: 0, id: Int32(i)))
            }
            end = max(end, e.time + e.duration)
        }
        // Stable order: sample, then mutes before plucks before clicks.
        let order = list.indices.sorted { a, b in
            let x = list[a], y = list[b]
            if x.sample != y.sample { return x.sample < y.sample }
            if x.kind != y.kind { return x.kind < y.kind }
            return a < b
        }
        itemCount = list.count
        items = UnsafeMutablePointer<Item>.allocate(capacity: max(list.count, 1))
        for (k, i) in order.enumerated() { (items + k).initialize(to: list[i]) }
        activeID = UnsafeMutablePointer<Int32>.allocate(capacity: GuitarSynth.voiceCount)
        activeID.initialize(repeating: -1, count: GuitarSynth.voiceCount)
        lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
        durationSeconds = end
        melodyAttack = Float(1 - exp(-1.0 / (0.012 * sampleRate)))
        melodyRelease = Float(exp(-1.0 / (0.06 * sampleRate)))
        melodyDecay = Float(exp(-1.0 / (1.2 * sampleRate)))
    }

    deinit {
        items.deallocate()
        activeID.deallocate()
        pthread_mutex_destroy(lock)
        lock.deallocate()
    }

    // MARK: Main-thread API

    public var isPlaying: Bool {
        get {
            pthread_mutex_lock(lock); defer { pthread_mutex_unlock(lock) }
            return pendingPlaying ?? mirrorPlaying
        }
        set {
            pthread_mutex_lock(lock); defer { pthread_mutex_unlock(lock) }
            pendingPlaying = newValue
        }
    }

    public var positionSeconds: Double {
        pthread_mutex_lock(lock); defer { pthread_mutex_unlock(lock) }
        return pendingSeek ?? mirrorPosition
    }

    public func seek(toSeconds: Double) {
        pthread_mutex_lock(lock); defer { pthread_mutex_unlock(lock) }
        pendingSeek = max(0, toSeconds)
    }

    // MARK: Audio-thread API

    /// Renders `frameCount` mono frames (overwrites `buffer`).
    public func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        applyCommands()
        var done = 0
        while done < frameCount {
            if playing { fireDue() }
            var n = frameCount - done
            if playing, nextItem < itemCount {
                n = min(n, max(1, items[nextItem].sample - pos))
            }
            synth.render(into: buffer + done, frameCount: n)
            if clickRemaining > 0 { renderClick(buffer + done, n) }
            if melodyOn || melodyEnv > 1e-5 { renderMelody(buffer + done, n) }
            if playing { pos += n }
            done += n
        }
        publish()
    }

    private func applyCommands() {
        guard pthread_mutex_trylock(lock) == 0 else { return }
        let seek = pendingSeek, play = pendingPlaying
        pendingSeek = nil
        pendingPlaying = nil
        pthread_mutex_unlock(lock)
        if let s = seek { doSeek(s) }
        if let p = play {
            if playing && !p { synth.mute(stringIndex: nil); stopMelody() }
            playing = p
        }
    }

    private func publish() {
        guard pthread_mutex_trylock(lock) == 0 else { return }
        mirrorPosition = Double(pos) / sampleRate
        mirrorPlaying = playing
        pthread_mutex_unlock(lock)
    }

    private func doSeek(_ seconds: Double) {
        pos = Int((seconds * sampleRate).rounded())
        var lo = 0, hi = itemCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].sample < pos { lo = mid + 1 } else { hi = mid }
        }
        nextItem = lo
        synth.mute(stringIndex: nil)
        for i in 0..<GuitarSynth.voiceCount { activeID[i] = -1 }
        clickRemaining = 0
        stopMelody()
    }

    private func stopMelody() {
        melodyOn = false
        melodyEnv = 0
        melodyID = -1
    }

    private func fireDue() {
        while nextItem < itemCount, items[nextItem].sample <= pos {
            let it = items[nextItem]
            nextItem += 1
            switch it.kind {
            case 1:
                let s = Int(it.string)
                synth.pluck(midi: Int(it.midi), velocity: it.velocity, stringIndex: s)
                if s >= 0, s < GuitarSynth.voiceCount { activeID[s] = it.id }
            case 0:
                let s = Int(it.string)
                if s >= 0, s < GuitarSynth.voiceCount, activeID[s] == it.id {
                    synth.mute(stringIndex: s)
                    activeID[s] = -1
                }
            case 4:
                melodyOn = true
                melodyID = it.id
                melodyStep = 2 * Double.pi * 440.0 * pow(2.0, (Double(it.midi) - 69.0) / 12.0) / sampleRate
                melodyAmp = 0.22 * min(max(it.velocity, 0), 1)
                melodyEnv = 0
            case 3:
                if melodyID == it.id { melodyOn = false }
            default:
                startClick(accent: it.velocity)
            }
        }
    }

    private func renderMelody(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            if melodyOn {
                melodyEnv += (1 - melodyEnv) * melodyAttack
                melodyAmp *= melodyDecay
                if melodyAmp < 0.05 { melodyAmp = max(melodyAmp, 0.05) }   // keeps a quiet sustain
            } else {
                melodyEnv *= melodyRelease
            }
            let p = Float(melodyPhase)
            let s = sinf(p) + 0.22 * sinf(2 * p) + 0.06 * sinf(3 * p)
            melodyPhase += melodyStep
            if melodyPhase > 2 * Double.pi { melodyPhase -= 2 * Double.pi }
            out[i] = min(max(out[i] + melodyAmp * melodyEnv * s, -1), 1)
        }
        if !melodyOn && melodyEnv < 1e-5 { melodyEnv = 0 }
    }

    // MARK: Clicks (short noise burst + tone)

    private func startClick(accent: Float) {
        clickRemaining = clickLength
        clickIndex = 0
        clickAmp = 0.25 + 0.3 * min(max(accent, 0), 1)
        clickPhase = 0
        let f = accent >= 0.85 ? 1800.0 : 1200.0
        clickStep = Float(2 * Double.pi * f / sampleRate)
    }

    private func renderClick(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let decay = Float(1.0 / (0.004 * sampleRate))
        let m = min(n, clickRemaining)
        for i in 0..<m {
            clickNoise ^= clickNoise << 13; clickNoise ^= clickNoise >> 17; clickNoise ^= clickNoise << 5
            let noise = Float(Int32(bitPattern: clickNoise)) * (1.0 / 2_147_483_648.0)
            let env = expf(-Float(clickIndex) * decay)
            let s = clickAmp * env * (0.6 * sinf(clickPhase) + 0.4 * noise)
            clickPhase += clickStep
            clickIndex += 1
            let y = out[i] + s
            out[i] = min(max(y, -1), 1)
        }
        clickRemaining -= m
    }
}

// MARK: - Offline rendering

public enum OfflineRenderer {
    /// Renders events to mono Float samples. `tail` seconds are appended after the last note.
    public static func render(_ events: [NoteEvent], sampleRate: Double, tail: Double = 1.5,
                              configure: ((GuitarSynth) -> Void)? = nil) -> [Float] {
        let engine = SequencerEngine(sampleRate: sampleRate, events: events)
        configure?(engine.synth)
        engine.isPlaying = true
        let end = events.map { $0.time + max($0.duration, 0) }.max() ?? 0
        let total = max(Int(((end + max(tail, 0)) * sampleRate).rounded(.up)), 0)
        var out = [Float](repeating: 0, count: total)
        let block = 512
        out.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            var done = 0
            while done < total {
                let n = min(block, total - done)
                engine.render(into: base + done, frameCount: n)
                done += n
            }
        }
        return out
    }

    /// 16-bit PCM mono WAV (RIFF) file contents.
    public static func wavData(_ samples: [Float], sampleRate: Double) -> Data {
        var d = Data()
        d.reserveCapacity(44 + samples.count * 2)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate.rounded())
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples {
            let c = min(max(s, -1), 1)
            u16(UInt16(bitPattern: Int16((c * 32767).rounded())))
        }
        return d
    }
}
