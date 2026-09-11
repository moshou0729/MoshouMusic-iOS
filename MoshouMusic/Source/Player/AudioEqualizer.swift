import Foundation
import AVFoundation
import MediaToolbox

/// v1.0.141：10 段均衡器 + 频谱分析（MTAudioProcessingTap 方案）。
///
/// AVPlayer 挂不了 AVAudioUnitEQ 节点，改用 MTAudioProcessingTap：挂在
/// AVPlayerItem 的音频轨（AVMutableAudioMixInputParameters.audioTapProcessor），
/// 在实时音频回调里做 RBJ biquad 滤波（-12~+12dB，10 段 31Hz~16kHz）。
/// 同一回调顺带并行带通滤波做 10 段频谱能量分析（供悬浮窗频谱条读取）。
///
/// 失败安全：轨道加载失败 / tap 创建失败 / 格式不支持 —— 一律静默跳过，
/// 音频保持原样，绝不影响播放链路。
final class AudioEqualizer {

    static let shared = AudioEqualizer()

    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let maxGainDb: Float = 12

    // MARK: - biquad 滤波器

    final class Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        @inline(__always) func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

        /// RBJ peaking EQ（中心频率增益）
        func setPeaking(f0: Float, sampleRate: Float, gainDb: Float, q: Float) {
            let A = pow(10, gainDb / 40)
            let w0 = 2 * Float.pi * f0 / sampleRate
            let cw = cos(w0), sw = sin(w0)
            let alpha = sw / (2 * q)
            let a0 = 1 + alpha / A
            b0 = (1 + alpha * A) / a0
            b1 = (-2 * cw) / a0
            b2 = (1 - alpha * A) / a0
            a1 = (-2 * cw) / a0
            a2 = (1 - alpha / A) / a0
        }

        /// RBJ bandpass（峰值增益 1，用于频谱分析）
        func setBandpass(f0: Float, sampleRate: Float, q: Float) {
            let w0 = 2 * Float.pi * f0 / sampleRate
            let cw = cos(w0), sw = sin(w0)
            let alpha = sw / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b1 = 0
            b2 = (-alpha) / a0
            a1 = (-2 * cw) / a0
            a2 = (1 - alpha) / a0
        }
    }

    // MARK: - tap 上下文（实时线程访问，锁仅保护增益刷新）

    final class TapContext {
        var sampleRate: Float = 44100
        var channels = 2
        var interleaved = false
        var floatFormat = true

        var eqChain: [[Biquad]] = []      // [channel][band]
        var analyzer: [[Biquad]] = []     // [channel][band] 并行带通
        var gains: [Float] = Array(repeating: 0, count: 10)
        var gainsDirty = true
        /// 10 段频谱电平（0~1，峰值保持 + 衰减平滑），悬浮窗频谱条每帧读取
        var levels: [Float] = Array(repeating: 0, count: 10)
        /// v1.0.148：每段自适应参考峰值（慢衰减）—— 把各频段归一到自己的动态范围。
        /// 固定增益下低频段（带通捕能少）和小音量几乎看不出起伏，重音没有冲击感。
        var peaks: [Float] = Array(repeating: 0, count: 10)
        var lock = os_unfair_lock_s()

        init() {
            rebuild(sampleRate: 44100, channels: 2, interleaved: false)
        }

        func rebuild(sampleRate: Float, channels: Int, interleaved: Bool) {
            self.sampleRate = sampleRate
            self.channels = max(1, min(channels, 2))
            self.interleaved = interleaved
            eqChain = (0..<self.channels).map { _ in (0..<10).map { _ in Biquad() } }
            analyzer = (0..<self.channels).map { _ in (0..<10).map { _ in Biquad() } }
            refreshCoefficients()
        }

        func refreshCoefficients() {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            for c in 0..<channels {
                for b in 0..<10 {
                    eqChain[c][b].setPeaking(f0: AudioEqualizer.bandFrequencies[b],
                                             sampleRate: sampleRate, gainDb: gains[b], q: 1.1)
                    analyzer[c][b].setBandpass(f0: AudioEqualizer.bandFrequencies[b],
                                               sampleRate: sampleRate, q: 1.4)
                }
            }
            gainsDirty = false
        }
    }

    private var currentContext: TapContext?
    private var currentTapObject: MTAudioProcessingTap?
    private var attachedItemId: Int = 0
    /// v1.0.144：挂载成功后的回调（PlayerManager 注入 seek —— audioMix 在播放中设置
    /// 不会自动生效，必须 seek 一次强制音频管线重渲染）
    var onMounted: (() -> Void)?

    /// 频谱条当前电平（主线程 CADisplayLink 读取）
    func currentLevels() -> [Float] {
        return currentContext?.levels ?? Array(repeating: 0, count: 10)
    }

    // MARK: - 增益

    func setGain(band: Int, value: Float) {
        var g = ConfigStore.shared.eqGains
        g[band] = value
        ConfigStore.shared.eqGains = g
        currentContext?.gains = g
        currentContext?.gainsDirty = true
    }

    func refreshGains() {
        currentContext?.gains = ConfigStore.shared.eqGains
        currentContext?.gainsDirty = true
    }

    // MARK: - 挂载

    /// 在 commitStartPlayback 里调用：异步等音轨加载后把 tap 挂上
    func attachIfNeeded(to item: AVPlayerItem) {
        let cfg = ConfigStore.shared
        guard cfg.eqEnabled || cfg.floatingSpectrumOn else {
            item.audioMix = nil
            detach()
            return
        }
        detach()
        attachedItemId = ObjectIdentifier(item).hashValue
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
            var err: NSError?
            let st = asset.statusOfValue(forKey: "tracks", error: &err)
            guard st == .loaded else {
                Logger.warn("均衡器音轨加载失败(status=\(st.rawValue))，EQ/频谱本首不生效")
                return
            }
            guard let track = asset.tracks(withMediaType: .audio).first else {
                Logger.warn("均衡器音轨挂载失败：无音频轨")
                return
            }
            DispatchQueue.main.async {
                guard let self = self,
                      self.attachedItemId == ObjectIdentifier(item).hashValue else { return }
                self.mount(item: item, track: track)
            }
        }
    }

    private func mount(item: AVPlayerItem, track: AVAssetTrack) {
        let ctx = TapContext()
        ctx.gains = ConfigStore.shared.eqGains
        ctx.gainsDirty = true
        var callbacks = AudioEqualizer.tapCallbacks
        // 🚨 v1.0.145：clientInfo 必须经 callbacks.clientInfo 传入！MTAudioProcessingTapCreate
        // 没有独立 clientInfo 形参，此前恒为 nil → init 回调把 nil 写进 tapStorage →
        // prepare/process 里 GetStorage 取到空指针再解引用 = SIGSEGV（v1.0.144 真机崩溃）。
        let clientInfo = Unmanaged.passRetained(ctx).toOpaque()
        callbacks.clientInfo = clientInfo
        var tapOut: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects, &tapOut)
        guard err == noErr, let tapRef = tapOut else {
            Unmanaged.passUnretained(ctx).release()
            Logger.warn("均衡器音轨挂载失败：MTAudioProcessingTapCreate 失败(\(err))")
            return
        }
        let tap = tapRef.takeRetainedValue()
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
        currentContext = ctx
        currentTapObject = tap
        Logger.info("EQ tap 已挂载（track \(track.trackID)，均衡器\(ConfigStore.shared.eqEnabled ? "开" : "关")，频谱\(ConfigStore.shared.floatingSpectrumOn ? "开" : "关")）")
        Logger.info("EQ tap clientInfo 已接入（存储指针非空）")
        // v1.0.144：挂载完成 → seek 强制 audioMix 生效
        onMounted?()
    }

    private func detach() {
        attachedItemId = 0
        currentTapObject = nil
        currentContext = nil
    }

    // MARK: - tap 回调（C 函数指针，必须保持静态存活）

    private static var tapCallbacks: MTAudioProcessingTapCallbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: nil,
        init: { _, clientInfo, tapStorageOut in
            tapStorageOut.pointee = clientInfo
        },
        finalize: { tap in
            let p = MTAudioProcessingTapGetStorage(tap)
            guard UInt(bitPattern: p) != 0 else { return }
            Unmanaged<TapContext>.fromOpaque(p).release()
        },
        prepare: { tap, _, format in
            let p = MTAudioProcessingTapGetStorage(tap)
            guard UInt(bitPattern: p) != 0 else { return }
            let ctx = Unmanaged<TapContext>.fromOpaque(p).takeUnretainedValue()
            let asbd = format.pointee
            // 只处理线性 PCM Float32；其余格式直接透传（process 里守卫）
            // kAudioFormatLinearPCM='lpcm' kAudioFormatFlagIsFloat=0x1 IsNonInterleaved=0x20
            let isFloatPCM = asbd.mFormatID == 0x6C70636D && (asbd.mFormatFlags & 0x01) != 0
            ctx.floatFormat = isFloatPCM
            if isFloatPCM {
                let interleaved = (asbd.mFormatFlags & 0x20) == 0
                ctx.rebuild(sampleRate: Float(asbd.mSampleRate),
                            channels: Int(max(1, min(asbd.mChannelsPerFrame, 2))),
                            interleaved: interleaved)
            }
        },
        unprepare: { tap in
            let p = MTAudioProcessingTapGetStorage(tap)
            guard UInt(bitPattern: p) != 0 else { return }
            let ctx = Unmanaged<TapContext>.fromOpaque(p).takeUnretainedValue()
            for c in ctx.eqChain { for b in c { b.reset() } }
            for c in ctx.analyzer { for b in c { b.reset() } }
            ctx.levels = Array(repeating: 0, count: 10)
            ctx.peaks = Array(repeating: 0, count: 10)
        },
        process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, _ in
            var srcFlags: MTAudioProcessingTapFlags = 0
            let p = MTAudioProcessingTapGetStorage(tap)
            // v1.0.145：存储指针为空（clientInfo 未接入）→ 原样透传，绝不解引用空指针
            guard UInt(bitPattern: p) != 0, numberFrames > 0 else {
                _ = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, &srcFlags, nil, nil)
                numberFramesOut.pointee = numberFrames
                return
            }
            let ctx = Unmanaged<TapContext>.fromOpaque(p).takeUnretainedValue()
            // v1.0.145：非 Float32 PCM 也原样透传（旧实现返回 0 帧 = 整段静音）
            guard ctx.floatFormat else {
                _ = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, &srcFlags, nil, nil)
                numberFramesOut.pointee = numberFrames
                return
            }
            if ctx.gainsDirty { ctx.refreshCoefficients() }

            let status = MTAudioProcessingTapGetSourceAudio(
                tap, numberFrames, bufferListInOut, &srcFlags, nil, nil)
            guard status == noErr else {
                numberFramesOut.pointee = 0
                return
            }
            numberFramesOut.pointee = numberFrames

            let n = Int(numberFrames)
            var energy = Array(repeating: Float(0), count: 10)
            let useEQ = ctx.gains.contains { $0 != 0 }

            withUnsafeMutablePointer(to: &bufferListInOut.pointee.mBuffers) { firstBuf in
                let bufCount = Int(bufferListInOut.pointee.mNumberBuffers)
                guard bufCount >= 1 else { return }

                func analyzeChannel(_ ch: Int, _ sample: Float) {
                    for band in 0..<10 {
                        let y = ctx.analyzer[ch][band].process(sample)
                        energy[band] += y * y
                    }
                }

                if !ctx.interleaved, bufCount >= ctx.channels {
                    // 非交错：每 buffer 一声道
                    for c in 0..<ctx.channels {
                        let buf = firstBuf[c]
                        guard let data = buf.mData else { continue }
                        let ptr = data.bindMemory(to: Float.self, capacity: n)
                        for i in 0..<n {
                            var x = ptr[i]
                            if useEQ {
                                for band in 0..<10 where ctx.gains[band] != 0 {
                                    x = ctx.eqChain[c][band].process(x)
                                }
                            }
                            ptr[i] = x
                            analyzeChannel(c, x)
                        }
                    }
                } else if ctx.interleaved, bufCount == 1 {
                    // 交错：单 buffer，按声道步进
                    let buf = firstBuf[0]
                    guard let data = buf.mData else { return }
                    let ch = ctx.channels
                    let ptr = data.bindMemory(to: Float.self, capacity: n * ch)
                    for i in 0..<n {
                        for c in 0..<ch {
                            let idx = i * ch + c
                            var x = ptr[idx]
                            if useEQ {
                                for band in 0..<10 where ctx.gains[band] != 0 {
                                    x = ctx.eqChain[c][band].process(x)
                                }
                            }
                            ptr[idx] = x
                            analyzeChannel(c, x)
                        }
                    }
                }
            }

            // 频谱电平：RMS → 0~1 映射。
            // v1.0.148：改用「每段自适应峰值归一化」—— 固定增益 (rms*7) 在低频段
            // （31/62Hz 带通捕能少）与小音量下几乎看不出起伏，重音没有冲击感。
            // 现在每段各自跟踪近期峰值作为参考，配合噪声门 + 幂曲线：
            // 鼓点/重低音一击即到高位，随后按衰减系数平滑回落。
            let fn = Float(max(n, 1))
            for band in 0..<10 {
                let rms = sqrt(energy[band] / fn)
                let prevPeak = ctx.peaks[band]
                ctx.peaks[band] = max(rms, prevPeak * 0.992)
                let ref = max(ctx.peaks[band] * 1.12, 1e-4)
                var norm = rms / ref
                norm = max(0, min(1, (norm - 0.15) / 0.85))
                let shaped = pow(norm, 0.62)
                let decayed = ctx.levels[band] * 0.86
                ctx.levels[band] = shaped > decayed ? shaped : decayed
            }
        }
    )
}
