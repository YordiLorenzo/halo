// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import SwiftUI

/// Photos actually uploaded, per time bucket.
///
/// Bars, not a line: this is a count per period, and each bar is one hour or one day of
/// work. The shape immediately shows the thing that matters on a slow connection, that
/// almost everything happens overnight while the Mac is idle.
struct UploadBars: View {
    let data: [(date: Date, count: Int)]
    var tint: Color = Palette.go
    var unitLabel: String = "hour"
    var loading: Bool = false

    @State private var hover: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Reserve the row whether or not anything is hovered, so the chart does not
            // jump when the pointer enters it.
            Text(hoverText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(hover == nil ? .clear : .secondary)
                .frame(height: 13)

            GeometryReader { geo in
                if data.count >= 2 {
                    let peak = max(data.map(\.count).max() ?? 1, 1)
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(Array(data.enumerated()), id: \.offset) { i, d in
                            let h = max(2, geo.size.height * logFraction(d.count, peak))
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(barColor(i, d.count, peak))
                                .frame(height: h)
                                .contentShape(Rectangle())
                                .onHover { inside in hover = inside ? i : (hover == i ? nil : hover) }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    Text("no uploads recorded yet")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 50)
            .opacity(loading ? 0.25 : 1)
            .overlay {
                if loading {
                    ProgressView().controlSize(.small)
                }
            }
            .animation(.easeOut(duration: 0.15), value: loading)
        }
    }

    /// Log scale. Upload volume is wildly bursty, an overnight hour can be 2,400 items
    /// against 14 in the afternoon, so on a linear axis every quiet period flattens to
    /// nothing and the chart reads as "dead" when it isn't.
    private func logFraction(_ count: Int, _ peak: Int) -> Double {
        guard count > 0 else { return 0 }
        return log(Double(count) + 1) / log(Double(peak) + 1)
    }

    private func barColor(_ i: Int, _ count: Int, _ peak: Int) -> Color {
        if hover == i { return tint }
        if count == 0 { return tint.opacity(0.16) }
        return tint.opacity(0.34 + logFraction(count, peak) * 0.5)
    }

    private var hoverText: String {
        guard let i = hover, data.indices.contains(i) else { return " " }
        let d = data[i]
        let f = DateFormatter()
        f.dateFormat = unitLabel == "minute" ? "HH:mm"
                     : unitLabel == "hour"   ? "EEE HH:mm" : "EEE d MMM, HH:mm"
        return "\(f.string(from: d.date))  ·  \(d.count.formatted()) uploaded"
    }
}

/// Remaining-to-upload over time.
///
/// A rate sparkline looks busy but answers nothing: sync is bursty, so it is mostly noise
/// with occasional spikes. The descending queue line is the honest shape, you can see a
/// night's progress, a stall as a flat run, and project the finish by eye.
struct QueueChart: View {
    let samples: [HistoryStore.Sample]
    var tint: Color = Palette.go
    var flat: Bool = false          // stalled: draw it in the warning colour

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                gridLines(geo.size)
                if pts.count >= 2 {
                    // filled area, so a shrinking queue reads as ground being gained
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.34), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: .init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    // emphasise where we are now
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .shadow(color: tint, radius: 4)
                        .position(pts.last!)
                } else {
                    Text("collecting…")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 54)
    }

    private func gridLines(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3) { _ in
                Rectangle().fill(.primary.opacity(0.05)).frame(height: 1)
                Spacer(minLength: 0)
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let ts = samples.map(\.t)
        let qs = samples.map { Double($0.q) }
        let t0 = ts.first!, t1 = ts.last!
        // Scale from zero so the fill height means "how much is left", not just variance
        // within the window, a line hovering near the top is a lot of work remaining.
        let qMax = max(qs.max() ?? 1, 1)
        let span = max(t1 - t0, 1)
        let w: Double = size.width
        let h: Double = size.height
        var out: [CGPoint] = []
        out.reserveCapacity(ts.count)
        for i in ts.indices {
            let x: Double = (ts[i] - t0) / span * w
            let y: Double = h - (qs[i] / qMax) * h * 0.92 - 2
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}

/// Segmented range picker, sized for a popover.
struct RangePicker: View {
    @Binding var range: HistoryStore.Range
    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryStore.Range.allCases) { r in
                Button { range = r } label: {
                    Text(r.rawValue)
                        .font(.system(size: 10.5, weight: range == r ? .semibold : .regular))
                        .foregroundStyle(range == r ? .primary : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background {
                            if range == r {
                                Capsule().fill(.primary.opacity(0.10))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}