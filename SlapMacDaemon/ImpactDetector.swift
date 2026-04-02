import Foundation

/// Decides whether an incoming acceleration sample represents a deliberate slap.
///
/// Uses a four-algorithm voting system inspired by seismology / industrial
/// vibration monitoring.  An "impact" fires only when `requiredVotes` or more
/// algorithms agree on the same sample, and the cooldown has elapsed.
///
///  Algorithm    What it detects
///  ----------   -------------------------------------------------
///  magnitude    Raw dynamic acceleration above a force floor
///  sta_lta      Short-term vs long-term energy ratio (earthquake detector)
///  cusum        Cumulative deviation from a slowly drifting baseline
///  kurtosis     Statistical "spikiness" — impacts look very non-Gaussian
final class ImpactDetector {

    // MARK: - Tuneable parameters

    /// 0 = trigger on the lightest tap, 1 = only fire on a hard slap.
    var sensitivity: Float = 0.5

    /// How many of the four algorithms must agree before an impact fires.
    var requiredVotes: Int = 2

    /// Minimum time between consecutive impacts (prevents mechanical ringing).
    var cooldown: TimeInterval = 0.4

    // MARK: - Output

    /// Called on the caller's thread whenever an impact is confirmed.
    /// - Parameters:
    ///   - normalizedForce: 0.0 … 1.0
    ///   - algorithms: names of the algorithms that voted
    var onImpact: ((_ normalizedForce: Float, _ algorithms: [String]) -> Void)?

    // MARK: - Internal state

    // Rolling window of dynamic-acceleration magnitudes
    private var window: [Float] = []
    private let windowCapacity = 400   // ~500 ms @ 800 Hz
    private let staLen         = 16    // short-term  ~20 ms
    private let ltaLen         = 400   // long-term  ~500 ms

    // Gravity removal — slow exponential moving average of total magnitude
    private var gravityEMA: Float = 9.81
    private let gravityAlpha: Float = 0.995  // very slow decay

    // CUSUM state
    private var cusumS: Float = 0      // cumulative sum (positive branch)
    private var cusumRef: Float = 0    // slowly-adapting reference level

    private var lastImpactTime: Date = .distantPast

    // MARK: - Public API

    /// Feed every accelerometer sample here.
    func process(x: Float, y: Float, z: Float) {
        let magnitude = (x*x + y*y + z*z).squareRoot()

        // Update gravity EMA
        gravityEMA = gravityAlpha * gravityEMA + (1 - gravityAlpha) * magnitude

        // Dynamic acceleration with gravity removed
        let dyn = max(0, magnitude - gravityEMA)

        // Maintain rolling window
        window.append(dyn)
        if window.count > windowCapacity { window.removeFirst() }

        // Enforce cooldown
        guard Date().timeIntervalSince(lastImpactTime) > cooldown else { return }
        guard window.count >= staLen else { return }

        // Scaled thresholds (higher sensitivity → lower thresholds)
        let forceFloor  = 0.5  + Double(sensitivity) * 2.0   // 0.5 – 2.5 m/s²-ish
        let staRatio    = 6.0  - Double(sensitivity) * 3.0   // 3.0 – 6.0
        let kurtTarget  = 7.0  - Double(sensitivity) * 2.0   // 5.0 – 7.0
        let cusumLimit  = 10.0 - Double(sensitivity) * 6.0   // 4.0 – 10.0

        var votes: [String] = []

        // ── Algorithm 1: Magnitude threshold ──────────────────────────────
        if Double(dyn) > forceFloor {
            votes.append("magnitude")
        }

        // ── Algorithm 2: STA / LTA ─────────────────────────────────────────
        let sta = window.suffix(staLen).reduce(0, +) / Float(staLen)
        let ltaCount = min(window.count, ltaLen)
        let lta = window.suffix(ltaCount).reduce(0, +) / Float(ltaCount)
        if lta > 1e-4 && Double(sta / lta) > staRatio {
            votes.append("sta_lta")
        }

        // ── Algorithm 3: CUSUM ─────────────────────────────────────────────
        let k: Float = 0.4
        cusumRef = 0.9995 * cusumRef + 0.0005 * dyn   // very slow drift
        cusumS = max(0, cusumS + dyn - cusumRef - k)
        if Double(cusumS) > cusumLimit {
            votes.append("cusum")
            cusumS = 0  // reset after firing
        }

        // ── Algorithm 4: Kurtosis ──────────────────────────────────────────
        if window.count >= 32 {
            let recent = Array(window.suffix(32))
            let mean   = recent.reduce(0, +) / Float(recent.count)
            let variance = recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(recent.count)
            let sd = variance.squareRoot()
            if sd > 1e-4 {
                let kurt = recent.map { pow(($0 - mean) / sd, 4) }.reduce(0, +) / Float(recent.count)
                if Double(kurt) > kurtTarget {
                    votes.append("kurtosis")
                }
            }
        }

        // ── Fire if enough algorithms agree ───────────────────────────────
        guard votes.count >= requiredVotes else { return }

        lastImpactTime = Date()

        // Normalize force: map dyn into 0…1 with a soft cap at 6 m/s²
        let normalizedForce = min(1.0, dyn / 6.0)
        onImpact?(normalizedForce, votes)
    }
}
