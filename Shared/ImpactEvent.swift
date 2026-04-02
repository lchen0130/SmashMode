import Foundation

/// Transmitted from daemon -> app over the Unix domain socket as newline-delimited JSON.
struct ImpactEvent: Codable {
    /// Unix timestamp of the impact
    let timestamp: Double
    /// Normalised impact force, 0.0 (gentle tap) … 1.0 (hard slap)
    let magnitude: Float
    /// Which detection algorithms voted for this impact
    let algorithms: [String]
}
