import Foundation

/// Bounded timings only: no key text, pointer coordinates or document contents.
final class TimingMetrics {
    private let lock = NSLock()
    private var values: [String: [Double]] = [:]
    private var offsets: [String: Int] = [:]
    private var counts: [String: Int] = [:]
    private var maxima: [String: Int] = [:]

    func recordMaximum(_ name: String, value: Int) {
        lock.lock(); defer { lock.unlock() }
        maxima[name] = max(maxima[name] ?? 0, value)
    }

    func add(_ name: String, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var series = values[name] ?? []
        if series.count < 1024 { series.append(milliseconds) }
        else {
            let offset = offsets[name] ?? 0
            series[offset] = milliseconds
            offsets[name] = (offset + 1) % 1024
        }
        values[name] = series
        counts[name, default: 0] += 1
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        let copied = values, totals = counts, maximumCounts = maxima
        lock.unlock()
        var result: [String: Any] = [:]
        result["maximum_counts"] = maximumCounts
        for (name, values) in copied {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { continue }
            result[name] = ["samples": sorted.count, "total_samples": totals[name] ?? 0,
                            "p50_ms": sorted[(sorted.count - 1) / 2],
                            "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                            "max_ms": sorted.last!] as [String: Any]
        }
        return result
    }
}
