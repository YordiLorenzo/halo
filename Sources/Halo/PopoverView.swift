// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import SwiftUI
import UniformTypeIdentifiers

// MARK: - glass primitives
//
// On macOS 26 `.glassEffect` gives real Liquid Glass, refraction, correct light/dark,
// and the morph behaviour when views change. Below that we fall back to a plain material
// so the app still looks native on 14/15 rather than shipping a hand-rolled fake.

private struct GlassCard<C: View>: View {
    var radius: CGFloat = 15
    @ViewBuilder var content: C
    var body: some View {
        content.padding(13)
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.clear).glassEffect(in: .rect(cornerRadius: radius))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                }
            }
    }
}

/// Quiet capsule. Primary actions tint rather than fill, a menu bar popover is not a
/// landing page, and a solid slab reads as an advert.
private struct Pill: View {
    let title: String
    var tint: Color? = nil
    var quiet = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, quiet ? 8 : 13)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background {
            if !quiet {
                Capsule().fill(tint?.opacity(0.15) ?? Color.primary.opacity(0.07))
                    .overlay(Capsule().strokeBorder(
                        tint?.opacity(0.45) ?? Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
        .opacity(quiet ? (hovering ? 0.9 : 0.6) : (hovering ? 0.85 : 1))
        .onHover { hovering = $0 }
    }
}

private struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.go
    var body: some View {
        GeometryReader { geo in
            let vals = Array(values.suffix(24))
            let peak = max(vals.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                    let h = max(2, geo.size.height * (v / peak))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(v > peak * 0.75 ? 1 : 0.42))
                        .frame(height: h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 30)
    }
}

private struct Meter: View {
    let fraction: Double
    var tint: Color = Palette.warm
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.65)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                    .shadow(color: tint.opacity(0.5), radius: 6)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - popover

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @State private var dropTargeted = false
    @AppStorage("advanced") private var advanced = false

    var body: some View {
        VStack(spacing: 0) {
            if let report = monitor.report {
                folderResult(report)
            } else if monitor.verifying {
                verifyingRow
            } else if let s = monitor.snapshot {
                main(s)
            } else {
                noLibrary
            }
        }
        .frame(width: 352)
        .background {
            if #available(macOS 26.0, *) { Color.clear.glassEffect(in: .rect(cornerRadius: 0)) }
        }
    }

    // ── the everyday view ────────────────────────────────────────────────

    @ViewBuilder private func main(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(s)
            if !s.isClear {
                divider
                rateBlock
                if !s.breakdown.isEmpty { divider; breakdownBlock(s) }
            }
            if monitor.phase == .stuck || monitor.phase == .broken {
                divider
                problemBlock(s)
            }
            if s.isClear {
                divider
                dropZone
            } else {
                divider
                riskNote(s)
            }
            if case .failed = monitor.action { divider; actionFailure }
            if advanced { divider; advancedPanel(s) }
            divider
            actions(s)
        }
    }

    private func header(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(monitor.phase.tint).frame(width: 8, height: 8)
                    .shadow(color: monitor.phase.tint, radius: 5)
                Text(monitor.phase.label.uppercased())
                    .font(.system(size: 11, weight: .bold)).kerning(0.5)
                    .foregroundStyle(monitor.phase.tint)
                Spacer()
                Text(statusDetail(s))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            let figure = s.isClear ? Fmt.split(s.libraryBytes) : Fmt.split(s.queueBytes)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figure.value)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(s.isClear ? "\(figure.unit) in iCloud" : "\(figure.unit) to go")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            Text(subtitle(s)).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Meter(fraction: s.fractionDone, tint: s.isClear ? Palette.go : Palette.warm)
                .padding(.top, 11)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 15)
    }

    private func statusDetail(_ s: Snapshot) -> String {
        switch monitor.phase {
        case .safe:      "checked just now"
        case .backingUp: Fmt.rate(monitor.bytesPerSecond)
        case .stuck:     "no movement"
        case .broken:    "needs attention"
        case .unknown:   ""
        }
    }

    private func subtitle(_ s: Snapshot) -> String {
        if s.isClear {
            return "\(Fmt.count(s.assetCount)) photos and videos · nothing waiting"
        }
        return "\(Int(s.fractionDone * 100))% of your library is in iCloud · "
             + "\(Fmt.count(s.queueAssets)) photos left"
    }

    private var rateBlock: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(uploadedLabel.uppercased())
                        .font(.system(size: 10, weight: .bold)).kerning(0.5)
                        .foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    RangePicker(range: $monitor.range)
                }
                UploadBars(data: monitor.history.drainSeries(monitor.range),
                           tint: monitor.phase == .stuck ? Palette.wait : Palette.go,
                           bucketSeconds: monitor.range.bucketSeconds)
                Text(progressLine)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// Apple's own count of what landed in the window, no observation period needed.
    private var uploadedLabel: String {
        let total = monitor.history.drainSeries(monitor.range).reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return "uploaded" }
        return "\(Fmt.bytes(total)) uploaded"
    }

    /// What cleared over the window shown in the chart, then how long the rest will take.
    ///
    /// The two use different rates on purpose. "Cleared" describes the bars above it, so it
    /// follows the range buttons. The estimate does not: sync is bursty enough that an hour's
    /// rate projects to anything from a day to never, and an estimate that changes when you
    /// press a chart button is not an estimate. It always uses the last 24 hours, idle time
    /// included, because idle time is part of how long this will really take.
    private var progressLine: String {
        let cleared = monitor.history.progress(monitor.range).map {
            "\(Fmt.bytes($0.cleared)) cleared in \(Fmt.duration($0.elapsed))"
        }
        guard let parts = [cleared, dailyETA].compactMap({ $0 }).nonEmpty else {
            return "measuring…"
        }
        return parts.joined(separator: " · ")
    }

    /// Estimate from the last 24 hours of real drain. Nil until there is enough history to
    /// say anything, rather than extrapolating from a few minutes.
    private var dailyETA: String? {
        guard let p = monitor.history.progress(.day), p.cleared > 0, p.elapsed > 3600,
              let remaining = monitor.snapshot?.queueBytes, remaining > 0 else { return nil }
        let hours = Double(remaining) / max(p.perHour, 1)
        let eta = hours > 48 ? String(format: "%.0f days left", hours / 24)
                             : String(format: "%.0f hours left", hours)
        return p.elapsed < 82_800 ? "\(eta), partial day" : eta
    }

    private func breakdownBlock(_ s: Snapshot) -> some View {
        VStack(spacing: 10) {
            ForEach(s.breakdown) { k in
                HStack(spacing: 11) {
                    Text(k.kind).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                    Meter(fraction: Double(k.bytes) / Double(max(s.queueBytes, 1)),
                          tint: k.kind == "RAW" ? Palette.warm : .secondary)
                    Text(Fmt.bytes(k.bytes))
                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).frame(width: 74, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func problemBlock(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(monitor.phase.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(problemText(s)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if monitor.phase == .stuck { autoRestartToggle }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// Offered inside the stall message, which is the one moment it is obviously relevant.
    private var autoRestartToggle: some View {
        Toggle(isOn: $monitor.autoRestart) {
            Text(monitor.autoRestarts > 0
                 ? "Restart automatically · done \(monitor.autoRestarts)× so far"
                 : "Restart automatically when this happens")
                .font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
        .foregroundStyle(.secondary)
    }

    private func problemText(_ s: Snapshot) -> String {
        if !s.integrityOK { return "Your photo library reports a database problem." }
        if !s.daemonRunning { return "The backup service isn't running. It won't restart on its own." }
        return "Backup stopped making progress. Restarting the session usually clears it, "
             + "about ten seconds, and nothing is lost."
    }

    private func riskNote(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 12)).foregroundStyle(Palette.wait).frame(width: 16)
            Text("\(Fmt.bytes(s.queueBytes)) exists only on this Mac. "
               + "Keep your originals until this reaches zero.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var dropZone: some View {
        GlassCard(radius: 14) {
            VStack(spacing: 3) {
                Text("Check a folder before you erase it")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Drop an SD card, a Downloads folder, an old drive")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.go, lineWidth: 2)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in monitor.verify(folder: url) }
            }
            return true
        }
        .onTapGesture { monitor.chooseFolder() }
    }

    private func actions(_ s: Snapshot) -> some View {
        HStack(spacing: 6) {
            switch monitor.action {
            case .running(let what):
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text(what + "…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            case .failed:
                EmptyView()      // the message row above carries it
            case .idle:
                actionButton(s)
            }
            Spacer()

            Pill(title: advanced ? "Less" : "Details", quiet: true) {
                withAnimation(.easeInOut(duration: 0.18)) { advanced.toggle() }
            }
            Pill(title: "Quit", quiet: true) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 15)
    }

    // ── advanced ────────────────────────────────────────────────────────
    //
    // Everything here is a number Photos has but never shows. Grouped by which
    // layer it comes from, because conflating those layers is what makes the
    // built-in item counter meaningless.

    @ViewBuilder private func advancedPanel(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            statGroup("STILL TO UPLOAD", [
                ("photos and videos", Fmt.count(s.queueAssets)),
                ("individual files",  Fmt.count(s.queueFiles)),
                ("album and edit changes", Fmt.count(s.pendingRecords)),
            ], note: "A photo can be several files, a RAW and a JPEG count as one photo "
                   + "but two uploads. Album changes carry no image data at all.")

            statGroup("YOUR LIBRARY", [
                ("photos",            Fmt.count(s.photoCount)),
                ("videos",            Fmt.count(s.videoCount)),
                ("shared with others", s.sharedCount == 0 ? "none" : Fmt.count(s.sharedCount)),
                ("total size",        Fmt.bytes(s.libraryBytes)),
            ])

            VStack(alignment: .leading, spacing: 5) {
                Text("WHEN IT STALLS").font(.system(size: 9.5, weight: .bold)).kerning(0.6)
                    .foregroundStyle(.tertiary)
                autoRestartToggle
                Text("Presses Pause and Resume in Photos for you, at most once every "
                   + "five minutes. Needs Accessibility and Automation permission.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            statGroup("SPEED", [
                ("in the last hour", drainText(.hour)),
                ("in the last day",  drainText(.day)),
                ("in the last week", drainText(.week)),
            ], note: "Measured by what actually left the upload queue. "
                   + "Uploads run in bursts, so an idle minute is normal.")

            healthGroup(s)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// Health reads as prose, not a dashboard: a green line when there is nothing to do,
    /// and a plain-language explanation with the fix when there is.
    @ViewBuilder private func healthGroup(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HEALTH").font(.system(size: 9.5, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)

            // "Running" while the header says stuck reads as the app disagreeing with itself.
            // The daemon being alive is not the same as it doing anything.
            healthRow(ok: s.daemonRunning && monitor.phase != .stuck,
                      good: "Upload service is running",
                      bad: s.daemonRunning ? "Upload service is idle and not sending anything"
                                           : "Upload service has stopped")

            healthRow(ok: s.walBytes < 100_000_000,
                      good: "Library database is healthy",
                      bad: "Another app is holding your library open, which slows uploads. "
                         + "Quitting and reopening Photos clears it.")

            healthRow(ok: s.failedUploads == 0,
                      good: "No photos are stuck",
                      bad: "\(Fmt.count(s.failedUploads)) photos have failed repeatedly. "
                         + "Find them in Photos under View › Utilities › Unable to Upload.")

            Text(s.library.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).padding(.top, 2)
        }
    }

    private func healthRow(ok: Bool, good: String, bad: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Palette.go : Palette.wait)
                .frame(width: 13)
            Text(ok ? good : bad)
                .font(.system(size: 12)).foregroundStyle(ok ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bytes that actually left the queue over the window.
    ///
    /// This is the same measurement the headline uses, deliberately. An estimate derived from
    /// iCloud's per-asset acknowledgements was tried here and disagreed with the queue by 20%
    /// on the same window, which put two different answers to one question on screen at once.
    /// The queue is the one that is definitionally right: a file leaves it when it is sent.
    ///
    /// The cost is that it only knows about time Halo was running, so a window it cannot cover
    /// says so rather than quietly reporting a shorter period's total.
    private func drainText(_ r: HistoryStore.Range) -> String {
        guard let p = monitor.history.progress(r) else { return "not measured yet" }
        guard p.cleared > 0 else { return "nothing" }
        let covered = p.elapsed > r.seconds * 0.9
        return "\(Fmt.bytes(p.cleared)) uploaded"
             + (covered ? "" : " in \(Fmt.duration(p.elapsed))")
    }

    @ViewBuilder private func actionButton(_ s: Snapshot) -> some View {
        switch monitor.phase {
        case .stuck:
            Pill(title: "Restart backup", tint: Palette.go) { monitor.restartBackup() }
        case .broken where !s.daemonRunning:
            // The daemon is launch-on-demand and SIP refuses launchctl kickstart, so opening
            // Photos is the only thing that actually starts it.
            Pill(title: "Open Photos", tint: Palette.stop) { monitor.openPhotos() }
        case .backingUp:
            Pill(title: "Open Photos") { monitor.openPhotos() }
        default:
            Pill(title: "Check a folder") { monitor.chooseFolder() }
        }
    }

    /// Shown when an action failed, with the one control that resolves it.
    @ViewBuilder private var actionFailure: some View {
        if case .failed(let message, let canFix) = monitor.action {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.wait).frame(width: 16)
                VStack(alignment: .leading, spacing: 7) {
                    Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if canFix {
                            Pill(title: "Open Accessibility settings", tint: Palette.go) {
                                monitor.openAccessibilitySettings()
                            }
                        }
                        Pill(title: "Dismiss", quiet: true) { monitor.dismissAction() }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private func statGroup(_ title: String, _ rows: [(String, String)],
                           note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9.5, weight: .bold)).kerning(0.6)
                .foregroundStyle(.tertiary)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1).font(.system(size: 12, design: .monospaced))
                        .monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
            }
        }
    }

    // ── folder verification ──────────────────────────────────────────────

    private var verifyingRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHECKING FOLDER").font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(.secondary)
            let (done, total) = monitor.verifyProgress
            Text("\(Fmt.count(done)) of \(Fmt.count(total))")
                .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Meter(fraction: total > 0 ? Double(done) / Double(total) : 0, tint: Palette.go)
        }
        .padding(18)
    }

    private func folderResult(_ r: FolderReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(r.isSafe ? Palette.go : Palette.wait)
                        .frame(width: 8, height: 8)
                    Text("FOLDER CHECKED").font(.system(size: 11, weight: .bold)).kerning(0.5)
                        .foregroundStyle(r.isSafe ? Palette.go : Palette.wait)
                    Spacer()
                    Text("\(Fmt.count(r.totalFiles)) files · \(Fmt.bytes(r.totalBytes))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.isSafe ? Fmt.count(r.confirmed) : Fmt.count(r.missing.count))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(r.isSafe ? "of \(Fmt.count(r.totalFiles))" : "not backed up")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                Text(r.isSafe
                     ? "Every file is confirmed in iCloud"
                     : "\(Fmt.count(r.confirmed)) of \(Fmt.count(r.totalFiles)) confirmed in iCloud")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 15)

            divider
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: r.isSafe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(r.isSafe ? Palette.go : Palette.wait).frame(width: 16)
                Text(r.isSafe
                     ? "Safe to erase “\(r.folder.lastPathComponent)”. Matched by name and exact "
                     + "size, then confirmed against iCloud."
                     : "Don't erase this yet, these files exist nowhere else.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            if !r.missing.isEmpty {
                divider
                GlassCard {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(r.missing.prefix(4)) { item in
                            HStack {
                                Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(item.size))
                                    .font(.system(size: 12)).monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if r.missing.count > 4 {
                            Text("and \(Fmt.count(r.missing.count - 4)) more…")
                                .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }

            divider
            HStack(spacing: 6) {
                Pill(title: "Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: r.folder.path)
                }
                Spacer()
                Pill(title: "Done", quiet: true) { monitor.report = nil }
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 15)
        }
    }

    private var noLibrary: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("CHOOSE YOUR PHOTO LIBRARY").font(.system(size: 11, weight: .bold)).kerning(0.5)
                .foregroundStyle(Palette.wait)
            Text("Point Halo at your Photos library once and it will remember. "
               + "It's usually in Pictures, or on an external drive.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Pill(title: "Choose Library…", tint: Palette.go) { monitor.chooseLibrary() }
                Spacer()
                Pill(title: "Quit", quiet: true) { NSApp.terminate(nil) }
            }
            Text("Halo only ever reads. It never moves, edits or deletes anything.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(18)
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
    }
}