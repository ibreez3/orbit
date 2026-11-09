import Foundation

/// Converts agent-supplied JSON numbers without trapping on out-of-range,
/// non-integral, NaN, or infinite values.
public enum AgentNumeric {
    public static func int32(_ value: Double?, default defaultValue: Int32) -> Int32 {
        guard let value, value.isFinite else { return defaultValue }
        let clamped = min(max(value, Double(Int32.min)), Double(Int32.max))
        return Int32(clamped.rounded(.towardZero))
    }

    public static func int(
        _ value: Double?,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard let value, value.isFinite else { return defaultValue }
        let clamped = min(max(value, Double(range.lowerBound)), Double(range.upperBound))
        return Int(clamped.rounded(.towardZero))
    }

    public static func uint32(
        _ value: Double?,
        default defaultValue: UInt32,
        range: ClosedRange<UInt32>
    ) -> UInt32 {
        guard let value, value.isFinite else { return defaultValue }
        let clamped = min(max(value, Double(range.lowerBound)), Double(range.upperBound))
        return UInt32(clamped.rounded(.towardZero))
    }
}
