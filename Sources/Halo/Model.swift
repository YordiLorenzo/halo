// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import Foundation
import ApplicationServices
import AppKit
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
    /// cloudphotod's CPU share. The only liveness signal here that is actually Photos'.
    var daemonCPU: Double?


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
    ///
    /// Ten minutes, not three: a single large video can hold the queue flat for minutes
    /// while genuinely transferring, and the daemon's CPU covers that case, but the two
    /// together still need slack for a slow link.
    private static let stallAfter: TimeInterval = 600

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var history = HistoryStore.load()
    @Published var range: HistoryStore.Range = .day {
        didSet { objectWillChange.send() }
    }
    @Published private(set) var library: URL?
    @Published var report: FolderReport?
    @Published var verifying = false
    @Published var verifyProgress: (Int, Int) = (0, 0)
    /// Precomputed once per poll. The menu bar label redraws far more often than the data
    /// changes, so formatting there burns CPU for no reason.
    @Published private(set) var menuBarLabel: String?

    /// What a button is doing, so the UI can say so. Fire-and-forget actions that take ten
    /// seconds and report nothing read as a broken button.
    enum ActionState: Equatable {
        case idle
        case running(String)
        case failed(String, canFix: Bool)
    }
    @Published private(set) var action: ActionState = .idle

    private var previous: Snapshot?
    /// Guards against overlapping polls. Without it a slow snapshot lets the next timer
    /// fire on top of it; the tasks stack, each opens its own connections, and the read
    /// locks pile up, the exact pattern that stops SQLite checkpointing the WAL.
    private var polling = false
    private var lastProgressAt = Date()
    /// Auto-restart bookkeeping. Cooldown so a sync that dies immediately after a restart
    /// cannot turn this into a loop that clicks Photos every few seconds.
    private var lastAutoRestart = Date.distantPast
    @AppStorage("autoRestart") var autoRestart = false
    @Published private(set) var autoRestarts = 0
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
            await MainActor.run {
                self.polling = false
                self.apply(snap)
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

            // Whole-machine wire traffic is deliberately NOT part of this. It cannot tell
            // Photos apart from a browser tab, so any web page kept the stall timer alive and
            // a stalled sync was reported as healthy indefinitely. The daemon's own CPU is
            // the signal that belongs to Photos: a queue that has not moved while
            // cloudphotod sits at zero is a stall, and a queue that has not moved while it
            // works is just a large file mid-flight.
            let moved = prev.queueBytes != snap.queueBytes
                     || prev.queueFiles != snap.queueFiles
                     || (snap.daemonCPU ?? 0) > 1.0
            if moved { lastProgressAt = snap.date }
        }

        history.record(queueBytes: snap.queueBytes, at: snap.date)
        snapshot = snap
        phase = derivePhase(snap)
        maybeAutoRestart()
        Log.write("phase=\(phase) idle=\(Int(Date().timeIntervalSince(lastProgressAt)))s "
                + "cpu=\(snap.daemonCPU.map { String(format: "%.1f", $0) } ?? "nil") "
                + "files=\(snap.queueFiles)")
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

    /// Restart a stall without being asked, when the user has opted in.
    ///
    /// The sync here dies within minutes of every restart, so a job measured in days cannot
    /// be finished by hand. Gated on the same preconditions as the button, plus a cooldown:
    /// without one, a sync that stalls again immediately would drive Photos' controls
    /// continuously.
    private func maybeAutoRestart() {
        guard autoRestart, phase == .stuck, action == .idle,
              Date().timeIntervalSince(lastAutoRestart) > 300,
              AXIsProcessTrusted(), snapshot?.photosRunning == true else { return }
        lastAutoRestart = Date()
        autoRestarts += 1
        Log.write("auto-restart #\(autoRestarts)")
        restartBackup()
    }

    /// The fix that reliably revives a stalled sync: Photos runs backup as a background
    /// task the scheduler starves, and Pause/Resume restarts it as a user-initiated one.
    func restartBackup() {
        guard action == .idle else { return }
        // Checked up front rather than discovered through a failure: without Accessibility
        // this cannot press anything, and saying so immediately beats a spinner that ends
        // in an error six seconds later.
        guard AXIsProcessTrusted() else {
            action = .failed("Halo needs Accessibility permission to press Pause and Resume in "
                           + "Photos for you. Grant it, then try again.", canFix: true)
            return
        }
        guard snapshot?.photosRunning == true else {
            action = .failed("Photos needs to be open for this. Open it and try again.",
                             canFix: false)
            return
        }
        action = .running("Pausing the backup")

        Task.detached {
            if let e = Self.click("Pause") {
                await MainActor.run { self.action = Self.failure(e) }
                return
            }
            await MainActor.run { self.action = .running("Waiting, then resuming") }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let e = Self.click("Resume")
            await MainActor.run {
                if let e { self.action = Self.failure(e) }
                else { self.action = .idle; self.lastProgressAt = Date() }
                self.refresh()
            }
        }
    }

    /// Click a button in Photos' window by name, in-process.
    ///
    /// Deliberately not `osascript`: shelling out makes that child process the sender of the
    /// Apple Event, so macOS checks *its* Accessibility permission, not Halo's. The grant the
    /// user gives Halo can never apply, and the call fails with -1719 forever.
    nonisolated private static func click(_ button: String) -> NSDictionary? {
        let src = """
        tell application "System Events" to tell process "Photos" ¬
          to click (first button of front window whose name contains "\(button)")
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err
    }

    nonisolated private static func failure(_ err: NSDictionary) -> ActionState {
        let code = err[NSAppleScript.errorNumber] as? Int ?? 0
        let msg = err[NSAppleScript.errorMessage] as? String ?? ""
        if code == -1719 || msg.contains("assistive access") {
            return .failed("Halo needs Accessibility permission to press Pause and Resume in "
                         + "Photos. Grant it, then try again.", canFix: true)
        }
        return .failed("Couldn't find Pause in the Photos window. Do it by hand: "
                     + "Photos › Settings › iCloud, press Pause, then Resume.", canFix: false)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func dismissAction() { action = .idle }

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

extension Array {
    /// Nil rather than [], so an empty result can be handled with `guard let`.
    var nonEmpty: Self? { isEmpty ? nil : self }
}
