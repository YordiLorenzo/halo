// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import Foundation

/// Persistent time series of how much is left to upload.
///
/// An in-memory buffer only ever shows the minutes since launch, which is useless for a
/// job measured in days, you cannot see whether last night went well. This keeps samples
/// on disk so the graph is populated the instant the app opens, and so "overnight" is a
/// question it can actually answer.
///
/// Storage is a flat array of (time, bytes-remaining). One sample is 16 bytes; even a
/// year at 5-minute resolution is under 2 MB, so this stays a single small JSON file
/// rather than another SQLite database to keep healthy.
struct HistoryStore {

    struct Sample: Codable {
        let t: Double        // seconds since 1970
        let q: Int64         // queue bytes remaining
        var date: Date { Date(timeIntervalSince1970: t) }
    }

    private(set) var samples: [Sample] = []

    /// Newest data is kept at full resolution; older data is thinned. A day-old sample
    /// every ten minutes is plenty to see the shape of a night's progress.
    private static let retention: [(age: TimeInterval, spacing: TimeInterval)] = [
        (   3 * 3600,   60),      // last 3 hours  , every minute
        (  48 * 3600,  600),      // last 2 days   , every 10 minutes
        (  30 * 86400, 3600),     // last 30 days  , hourly
    ]

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> HistoryStore {
        var s = HistoryStore()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            s.samples = decoded
        }
        return s
    }

    mutating func record(queueBytes: Int64, at date: Date = Date()) {
        // Skip a sample if the previous one is very recent AND unchanged, a queue that
        // has not moved does not need a data point every five seconds.
        if let last = samples.last {
            let dt = date.timeIntervalSince1970 - last.t
            if dt < 30 || (dt < 55 && last.q == queueBytes) { return }
        }
        samples.append(.init(t: date.timeIntervalSince1970, q: queueBytes))
        compact(now: date)
        save()
    }

    /// Thin old samples according to the retention ladder. Runs on every append but is
    /// cheap: it is a single ordered pass over a few thousand elements.
    private mutating func compact(now: Date) {
        guard samples.count > 64 else { return }
        let t0 = now.timeIntervalSince1970
        var kept: [Sample] = []
        kept.reserveCapacity(samples.count)
        var lastKept: Double = -.greatestFiniteMagnitude

        for s in samples {
            let age = t0 - s.t
            if age > Self.retention.last!.age { continue }              // older than 30 days
            let spacing = Self.retention.first { age <= $0.age }?.spacing
                       ?? Self.retention.last!.spacing
            if s.t - lastKept >= spacing {
                kept.append(s)
                lastKept = s.t
            }
        }
        // always keep the newest reading, whatever the spacing rule says
        if let last = samples.last, kept.last?.t != last.t { kept.append(last) }
        samples = kept
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - reading

    enum Range: String, CaseIterable, Identifiable {
        case hour = "1H", day = "24H", week = "7D"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self { case .hour: 3600; case .day: 86400; case .week: 604_800 }
        }
        var label: String {
            switch self { case .hour: "last hour"; case .day: "last 24 hours"; case .week: "last week" }
        }
        /// Chosen so each range draws a comparable number of bars.
        var bucketSeconds: Int {
            switch self { case .hour: 120; case .day: 3600; case .week: 21600 }
        }
    }

    func series(_ range: Range, now: Date = Date()) -> [Sample] {
        let cutoff = now.timeIntervalSince1970 - range.seconds
        return samples.filter { $0.t >= cutoff }
    }

    /// Bytes cleared per bucket across the window, for the chart.
    ///
    /// Same source as every other figure on the card. Deriving the bars from iCloud's
    /// per-asset acknowledgements instead put a count of new registrations next to a byte
    /// total measuring actual transfer, and once a library is mostly registered those two
    /// stop resembling each other.
    func drainSeries(_ range: Range, now: Date = Date()) -> [(date: Date, bytes: Int64)] {
        let s = series(range, now: now)
        guard s.count >= 2 else { return [] }
        let size = range.bucketSeconds
        var out: [(date: Date, bytes: Int64)] = []
        var prev = s[0]
        for bucket in stride(from: (s[0].t / Double(size)).rounded(.down) * Double(size),
                             through: now.timeIntervalSince1970, by: Double(size)) {
            guard let last = s.last(where: { $0.t < bucket + Double(size) }) else { continue }
            out.append((Date(timeIntervalSince1970: bucket), max(0, prev.q - last.q)))
            prev = last
        }
        return out
    }

    /// Bytes cleared over the window, the number that answers "did last night go well?".
    ///
    /// Returns the span actually covered, which is usually less than the range asked for:
    /// on a fresh install the history is minutes old, and reporting those minutes as
    /// "cleared in the last 24 hours" is off by orders of magnitude.
    func progress(_ range: Range, now: Date = Date())
        -> (cleared: Int64, perHour: Double, elapsed: TimeInterval)? {
        let s = series(range, now: now)
        guard let first = s.first, let last = s.last, s.count >= 2 else { return nil }
        let elapsed = last.t - first.t
        guard elapsed > 300 else { return nil }
        let cleared = first.q - last.q
        return (cleared, Double(cleared) / (elapsed / 3600), elapsed)
    }
}