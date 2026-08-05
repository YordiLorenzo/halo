// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import Foundation
import SwiftUI

/// Development log. An LSUIElement app has no console, so trace to a file.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("halo.log")
    static func write(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - what one poll sees

struct Snapshot {
    /// Bytes iCloud has confirmed over each window, read from the sync engine's own record
    /// rather than from watching the queue shrink, which only covers the app's uptime.
    var uploads = LibraryReader.UploadStats()

    struct Kind: Identifiable { let kind: String; let files: Int; let bytes: Int64
                                var id: String { kind } }
    let date: Date
    let library: URL

    /// From the sync engine's own work list, the honest figures.
    var queueBytes: Int64 = 0
    var queueFiles = 0
    var queueAssets = 0
    var breakdown: [Kind] = []

    /// From the library index, context only, never the headline.
    var libraryBytes: Int64 = 0
    var assetCount = 0
    var photoCount = 0
    var videoCount = 0
    var sharedCount = 0
    var resourceCount = 0
    var failedUploads = 0
    var pendingRecords = 0
    var pullBuffer = 0

    var integrityOK = true
    var walBytes: Int64 = 0
    var daemonRunning = false
    var photosRunning = false
    var wireOutBytes: Int64 = 0

    var backedUpBytes: Int64 { max(0, libraryBytes - queueBytes) }
    var fractionDone: Double {
        libraryBytes > 0 ? Double(backedUpBytes) / Double(libraryBytes) : 1
    }
    var isClear: Bool { queueBytes < 100 * 1024 * 1024 && queueFiles == 0 }
}

struct FolderReport {
    struct Item: Identifiable { let name: String; let size: Int64; let url: URL
                                var id: String { url.path } }
    let folder: URL
    var totalFiles = 0
    var totalBytes: Int64 = 0
    var confirmed = 0
    var missing: [Item] = []
    var isSafe: Bool { totalFiles > 0 && missing.isEmpty }
}

// MARK: - state

enum Phase {
    case unknown, safe, backingUp, stuck, broken

    var label: String {
        switch self {
        case .unknown:   "Checking…"
        case .safe:      "Everything is in iCloud"
        case .backingUp: "Uploading to iCloud"
        case .stuck:     "Upload stuck"
        case .broken:    "Not uploading"
        }
    }
    var tint: Color {
        switch self {
        case .unknown:   .secondary
        case .safe:      Palette.go
        case .backingUp: Palette.go
        case .stuck:     Palette.wait
        case .broken:    Palette.stop
        }
    }
    /// Menu bar glyph. A filled dot when there is nothing to do, a partial ring while
    /// there is, so the everyday state is silent and progress is legible at a glance.
    var symbol: String {
        switch self {
        case .safe:                     "circle.fill"
        case .backingUp, .stuck:        "circle.lefthalf.filled"
        case .broken:                   "exclamationmark.circle.fill"
        case .unknown:                  "circle.dotted"
        }
    }
}

// MARK: - the monitor

@MainActor
final class Monitor: ObservableObject {

    /// Sync is bursty, it goes quiet between batches, and satellite links drop out for
    /// seconds at a time. Declaring a stall from one idle sample is how a monitor cries
    /// wolf and gets muted. Only sustained silence counts.
    private static let stallAfter: TimeInterval = 180

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var history = HistoryStore.load()
    /// Apple's own record of what landed and when, retroactive, so the chart is full
    /// the first time the app opens.
    @Published private(set) var uploads: [(date: Date, count: Int)] = []
    @Published var range: HistoryStore.Range = .day {
        didSet { if oldValue != range { loadChart() } }
    }
    /// Set while the chart is being re-read. Usually ~50 ms, but the read waits on the
    /// same lock sync is writing through, so under load it is long enough to look broken
    /// without something on screen saying otherwise.
    @Published private(set) var chartLoading = false
    @Published private(set) var library: URL?
    @Published var report: FolderReport?
    @Published var verifying = false
    @Published var verifyProgress: (Int, Int) = (0, 0)
    /// Precomputed once per poll. The menu bar label redraws far more often than the data
    /// changes, so formatting there burns CPU for no reason.
    @Published private(set) var menuBarLabel: String?

    private var previous: Snapshot?
    /// Guards against overlapping polls. Without it a slow snapshot lets the next timer
    /// fire on top of it; the tasks stack, each opens its own connections, and the read
    /// locks pile up, the exact pattern that stops SQLite checkpointing the WAL.
    private var polling = false
    private var loadingChart = false
    private var lastProgressAt = Date()
    private var timer: Timer?
    private var popoverOpen = false

    /// A library the user picked explicitly. Auto-discovery depends on TCC, which is
    /// fragile for an unsigned build and silently resets on every rebuild, a bookmark
    /// the user granted through the open panel keeps working regardless.
    private static let bookmarkKey = "libraryBookmark"

    init() {
        let bm = Self.restoreBookmark()
        let disc = LibraryReader.discoverLibrary()
        Log.write("init bookmark=\(bm?.path ?? "nil") discovered=\(disc?.path ?? "nil")")
        library = bm ?? disc
        refresh()
        schedule()
    }

    private static func restoreBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Ask the user to point at the .photoslibrary. Choosing it through the panel grants
    /// this app access to that path even without Full Disk Access.
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Library"
        panel.message = "Select your Photos library (usually Pictures › Photos Library)."
        panel.treatsFilePackagesAsDirectories = false
        if let pics = try? FileManager.default.url(for: .picturesDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false) {
            panel.directoryURL = pics
        }
        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        Log.write("panel result=\(result.rawValue) url=\(panel.url?.path ?? "nil")")
        guard result == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        library = url
        previous = nil
        Log.write("library set to \(url.path) scoped=\(url.startAccessingSecurityScopedResource())")
        refresh()
    }

    func popoverDidChange(open: Bool) {
        popoverOpen = open
        schedule()
        if open { refresh() }
    }

    /// Adaptive cadence. One poll costs ~10 ms, so this is not about CPU, it is about
    /// holding a read lock as briefly and as rarely as the situation allows.
    private var scheduledInterval: TimeInterval = 0

    private func schedule() {
        let interval: TimeInterval = popoverOpen ? 5 : (phase == .safe ? 300 : 30)
        guard interval != scheduledInterval || timer == nil else { return }
        scheduledInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let library, !polling else { return }
        polling = true
        let lib = library
        Task.detached(priority: .utility) {
            let snap = LibraryReader.snapshot(library: lib)
            Log.write("snapshot queue=\(snap.queueBytes) files=\(snap.queueFiles) lib=\(snap.libraryBytes)")
            let bucket = await self.range.bucket
            let hist = LibraryReader.uploadHistory(library: lib, bucket: bucket)
            await MainActor.run {
                self.polling = false
                self.uploads = hist
                self.apply(snap)
            }
        }
    }

    /// Chart-only reload, for switching the range.
    ///
    /// Deliberately not `refresh()`: that reads the whole library snapshot and bails
    /// outright when a poll is in flight, so a range switch could do nothing at all and
    /// leave the old range's bars on screen under the new label.
    func loadChart() {
        guard let lib = library, !loadingChart else { return }
        loadingChart = true
        chartLoading = true
        let wanted = range
        Task.detached(priority: .userInitiated) {
            let hist = LibraryReader.uploadHistory(library: lib, bucket: wanted.bucket)
            await MainActor.run {
                self.loadingChart = false
                // Clicking through the ranges faster than the reads return would otherwise
                // leave whichever finished last on screen, not the one that is selected.
                guard self.range == wanted else { self.chartLoading = false; self.loadChart(); return }
                self.uploads = hist
                self.chartLoading = false
            }
        }
    }

    private func apply(_ snap: Snapshot) {
        defer { previous = snap; schedule() }

        if let prev = previous, snap.date > prev.date {
            let dt = snap.date.timeIntervalSince(prev.date)
            let drained = Double(max(0, prev.queueBytes - snap.queueBytes))
            let wired = Double(max(0, snap.wireOutBytes - prev.wireOutBytes))
            // Two independent measures. The queue only credits a file when it completes,
            // so during a large transfer the wire runs ahead; taking the max keeps the
            // reading honest in both directions.
            bytesPerSecond = max(drained, wired) / dt

            let moved = prev.queueBytes != snap.queueBytes
                     || prev.queueFiles != snap.queueFiles
                     || wired > 256 * 1024
            if moved { lastProgressAt = snap.date }
        }

        history.record(queueBytes: snap.queueBytes, at: snap.date)
        snapshot = snap
        phase = derivePhase(snap)
        menuBarLabel = (snap.isClear || phase == .unknown) ? nil : Fmt.bytes(snap.queueBytes)
    }

    private func derivePhase(_ s: Snapshot) -> Phase {
        if !s.integrityOK { return .broken }
        if s.isClear { return .safe }
        // The daemon is launch-on-demand: absent while Photos is closed is normal,
        // absent while there is queued work is not.
        if !s.daemonRunning && s.queueFiles > 0 && s.photosRunning { return .broken }
        if Date().timeIntervalSince(lastProgressAt) > Self.stallAfter { return .stuck }
        return .backingUp
    }

    // MARK: - actions

    /// The fix that reliably revives a stalled sync: Photos runs backup as a background
    /// task the scheduler starves, and Pause/Resume restarts it as a user-initiated one.
    func restartBackup() {
        let script = """
        tell application "System Events"
          tell process "Photos"
            try
              click (first button of front window whose name contains "Pause")
              delay 8
              click (first button of front window whose name contains "Resume")
            end try
          end tell
        end tell
        """
        Task.detached {
            LibraryReader.shell("/usr/bin/osascript", ["-e", script])
            await MainActor.run { self.lastProgressAt = Date(); self.refresh() }
        }
    }

    func restartService() {
        let uid = getuid()
        Task.detached {
            LibraryReader.shell("/bin/launchctl",
                ["kickstart", "-k", "gui/\(uid)/com.apple.cloudphotod"])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { self.lastProgressAt = Date(); self.refresh() }
        }
    }

    func openPhotos() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
    }

    func verify(folder: URL) {
        guard let library else { return }
        verifying = true
        verifyProgress = (0, 0)
        Task.detached(priority: .userInitiated) {
            let r = LibraryReader.verify(folder: folder, library: library) { done, total in
                Task { @MainActor in self.verifyProgress = (done, total) }
            }
            await MainActor.run { self.report = r; self.verifying = false }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Check"
        panel.message = "Choose a folder to check against iCloud before erasing it."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { verify(folder: url) }
    }
}

// MARK: - formatting

enum Fmt {
    private static let big: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB]
        f.isAdaptive = false                 // one decimal, not two
        return f
    }()
    private static let small: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useMB, .useKB]
        return f
    }()
    /// Coarse, because it appears next to a byte count and the reader is comparing
    /// magnitudes, not timing anything.
    static func duration(_ s: TimeInterval) -> String {
        if s < 5400 { return "\(Int((s / 60).rounded())) min" }
        if s < 172_800 { return "\(Int((s / 3600).rounded())) h" }
        return "\(Int((s / 86400).rounded())) days"
    }

    static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "none" }
        let gb = Double(n) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 100  { return String(format: "%.0f GB", gb) }   // 682 GB, not 681.63 GB
        if gb >= 1    { return String(format: "%.1f GB", gb) }
        return small.string(fromByteCount: n)
    }
    /// Split so the view can set the numeral large and the unit small.
    static func split(_ n: Int64) -> (value: String, unit: String) {
        let s = bytes(n).split(separator: " ")
        return (String(s.first ?? "0"), s.count > 1 ? String(s[1]) : "B")
    }
    static func rate(_ bps: Double) -> String {
        bps < 1024 ? "—" : bytes(Int64(bps)) + "/s"
    }
    static func eta(_ remaining: Int64, _ bps: Double) -> String? {
        guard bps > 1024 else { return nil }
        let s = Double(remaining) / bps
        if s < 5400 { return "about \(Int(s / 60)) minutes to go" }
        if s < 172_800 { return String(format: "about %.0f hours to go", s / 3600) }
        return String(format: "about %.1f days to go", s / 86400)
    }
    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

enum Palette {
    static let go   = Color(red: 0.26, green: 0.84, blue: 0.55)
    static let wait = Color(red: 0.95, green: 0.68, blue: 0.29)
    static let stop = Color(red: 1.00, green: 0.43, blue: 0.38)
    static let warm = Color(red: 0.96, green: 0.65, blue: 0.31)
}