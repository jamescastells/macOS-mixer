//
//  VolumeCurve.swift
//  macOS-mixer
//

import Foundation

/// How loud each position of the system volume slider is on an output device.
///
/// The slider isn't linear in loudness, and the system only reports the current position's decibels, so the curve
/// starts with the device's quietest and loudest points, interpolates linearly in decibels between known points,
/// and gets more accurate as the system slider is used.
struct VolumeCurve {
    private var points: [(position: Float, decibels: Float)]
    let maxDecibels: Float

    init(minDecibels: Float, maxDecibels: Float) {
        points = [(0, minDecibels), (1, maxDecibels)]
        self.maxDecibels = maxDecibels
    }

    mutating func record(position: Float, decibels: Float) {
        guard position > 0.001, position < 0.999 else { return }
        if let index = points.firstIndex(where: { abs($0.position - position) < 0.002 }) {
            points[index].decibels = decibels
        } else {
            let index = points.firstIndex { $0.position > position } ?? points.count
            points.insert((position, decibels), at: index)
        }
    }

    /// Output amplitude (1 = the device's loudest) at a slider position from 0 to 1.
    func amplitude(at position: Float) -> Float {
        guard position > 0 else { return 0 }
        let position = min(position, 1)
        guard let upper = points.firstIndex(where: { $0.position >= position }), upper > 0 else {
            return 1
        }
        let low = points[upper - 1], high = points[upper]
        let fraction = (position - low.position) / (high.position - low.position)
        let decibels = low.decibels + fraction * (high.decibels - low.decibels)
        return min(Float(pow(10, Double(decibels - maxDecibels) / 20)), 1)
    }
}
