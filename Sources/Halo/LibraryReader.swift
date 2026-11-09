// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import Foundation
import SQLite3

/// Reads Apple Photos' own sync state.
///
/// Two databases matter and they disagree, so which one you trust IS the product:
///
///   Photos.sqlite            the library index. Its `ZREMOTEAVAILABILITY` flag is set when
///                            Photos *creates* a cloud record, NOT when iCloud confirms
///                            receipt, it over-reported one real library by ~550 GB.
///   store.cloudphotodb       the CPL sync engine's own work list. `outgoingResources` is
///                            what it still intends to send, with real byte sizes. This is
///                            the honest number and every headline figure comes from it.
///
/// Every connection is opened read-only and closed immediately. A held read lock stops
/// SQLite checkpointing the WAL; a leaked reader once grew one to 1.5 GB and throttled the
/// whole library. Short-lived connections are a correctness requirement, not tidiness.
enum LibraryReader {

    // MARK: - locating the library

    /// Prefer whatever `photolibraryd` has open, that is the live System Photo Library,
    /// which may not be the one in ~/Pictures.
    static func discoverLibrary() -> URL? {
        if let open = libraryHeldByPhotolibraryd() { return open }
        let fm = FileManager.default
        var candidates: [URL] = []
        if let pics = try? fm.url(for: .picturesDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            candidates.append(pics)
        }
        candidates.append(URL(fileURLWithPath: "/Volumes"))
        for base in candidates {
            guard let items = try? fm.contentsOfDirectory(at: base,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "photoslibrary" { return item }
                // one level down, for libraries sitting on an external volume
                if let subs = try? fm.contentsOfDirectory(at: item,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    if let hit = subs.first(where: { $0.pathExtension == "photoslibrary" }) {
                        return hit
                    }
                }
            }
        }
        return nil
    }

    private static func libraryHeldByPhotolibraryd() -> URL? {
        guard let pids = shell("/usr/bin/pgrep", ["photolibraryd"])?
            .split(separator: "\n").map(String.init), !pids.isEmpty else { return nil }
        for pid in pids {
            guard let out = shell("/usr/sbin/lsof", ["-p", pid]) else { continue }
            for line in out.split(separator: "\n") {
                guard let r = line.range(of: #"/.*?\.photoslibrary"#, options: .regularExpression)
                else { continue }
                return URL(fileURLWithPath: String(line[r]))
            }
        }
        return nil
    }

    // MARK: - snapshot

    static func snapshot(library: URL) -> Snapshot {
        var s = Snapshot(date: Date(), library: library)
        let photosDB = library.appendingPathComponent("database/Photos.sqlite")
        let cplDB = library.appendingPathComponent(
            "resources/cpl/cloudsync.noindex/storage/store.cloudphotodb")

        // ── the queue: what the engine still intends to send ──────────────
        withReadOnly(cplDB) { db in
            // Metadata records waiting to go up: album membership, edits, moves. These
            // are NOT files, and conflating them with upload work is how the item counter
            // in Photos becomes meaningless.
            query(db, "SELECT count(*) FROM pushRepository") { row in
                s.pendingRecords = Int(sqlite3_column_int64(row, 0))
            }
            query(db, "SELECT count(*) FROM transientPullRepository") { row in
                s.pullBuffer = Int(sqlite3_column_int64(row, 0))
            }
            query(db, """
                SELECT count(*), COALESCE(SUM(fileSize),0), count(DISTINCT itemIdentifier)
                FROM outgoingResources
            """) { row in
                s.queueFiles  = Int(sqlite3_column_int64(row, 0))
                s.queueBytes  = sqlite3_column_int64(row, 1)
                s.queueAssets = Int(sqlite3_column_int64(row, 2))
            }
            // resourceType 17 = the RAW half of a RAW+JPEG pair; 1 = the original,
            // where fileKind separates stills from video.
            query(db, """
                SELECT CASE WHEN resourceType=17 THEN 'RAW'
                            WHEN resourceType=1 AND fileKind=1 THEN 'Videos'
                            WHEN resourceType=1 THEN 'Photos' ELSE 'Other' END,
                       count(*), COALESCE(SUM(fileSize),0)
                FROM outgoingResources GROUP BY 1 ORDER BY 3 DESC
            """) { row in
                let kind = String(cString: sqlite3_column_text(row, 0))
                let files = Int(sqlite3_column_int64(row, 1))
                let bytes = sqlite3_column_int64(row, 2)
                if bytes > 100 * 1024 * 1024 {
                    s.breakdown.append(.init(kind: kind, files: files, bytes: bytes))
                }
            }
        }

        // ── the library, for the completion percentage and asset count ────
        withReadOnly(photosDB) { db in
            query(db, """
                SELECT count(*),
                       SUM(CASE WHEN ZKIND=0 THEN 1 ELSE 0 END),
                       SUM(CASE WHEN ZKIND=1 THEN 1 ELSE 0 END),
                       SUM(CASE WHEN ZLIBRARYSCOPE IS NOT NULL THEN 1 ELSE 0 END)
                FROM ZASSET WHERE ZTRASHEDSTATE=0
            """) { row in
                s.assetCount  = Int(sqlite3_column_int64(row, 0))
                s.photoCount  = Int(sqlite3_column_int64(row, 1))
                s.videoCount  = Int(sqlite3_column_int64(row, 2))
                s.sharedCount = Int(sqlite3_column_int64(row, 3))
            }
            query(db, "SELECT count(*) FROM ZINTERNALRESOURCE") { row in
                s.resourceCount = Int(sqlite3_column_int64(row, 0))
            }
            // ZUPLOADATTEMPTS counts attempts, NOT failures, every file currently
            // uploading has been "attempted once". Only repeated attempts mean a photo
            // is stuck in a retry loop and genuinely needs a human.
            query(db, """
                SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES aa
                JOIN ZASSET a ON a.Z_PK = aa.ZASSET
                WHERE COALESCE(aa.ZUPLOADATTEMPTS,0) >= 3 AND a.ZTRASHEDSTATE = 0
            """) { row in
                s.failedUploads = Int(sqlite3_column_int64(row, 0))
            }
            // originals only: type 0 subtype >1 are locally-generated previews that
            // never occupy iCloud storage and would inflate the total by ~5%.
            query(db, """
                SELECT COALESCE(SUM(ZDATALENGTH),0) FROM ZINTERNALRESOURCE
                WHERE ZRESOURCETYPE IN (1,4) OR (ZRESOURCETYPE=0 AND ZDATASTORESUBTYPE=1)
            """) { row in
                s.libraryBytes = sqlite3_column_int64(row, 0)
            }
            // NB: PRAGMA quick_check scans the whole file, 3 minutes on a 2.2 GB
            // library, and holds a read lock the entire time, which is precisely what
            // stops SQLite checkpointing the WAL. It is an on-demand diagnostic, never
            // part of a poll. `integrityOK` stays true unless someone asks explicitly.
        }

        // A WAL that cannot checkpoint makes every read scan it first. Watch our own
        // footprint so the monitor never becomes the bottleneck it is reporting on.
        s.walBytes = fileSize(photosDB.appendingPathExtension("wal"))

        s.daemonCPU     = processCPU("cloudphotod")
        s.daemonRunning = s.daemonCPU != nil
        s.photosRunning = isRunning("Photos")
        s.wireOutBytes  = interfaceBytesOut()
        return s
    }

    static func checkIntegrity(library: URL) -> Bool {
        var ok = true
        withReadOnly(library.appendingPathComponent("database/Photos.sqlite")) { db in
            query(db, "PRAGMA quick_check") { row in
                ok = String(cString: sqlite3_column_text(row, 0)) == "ok"
            }
        }
        return ok
    }

    // MARK: - folder verification

    /// Answers "is it safe to erase this folder?" by verification, not assumption.
    ///
    /// Photos records no import path, `ZIMPORTSESSIONID` is empty on every asset, so
    /// there is no way to ask "what came from this card". Instead: match each file by
    /// name AND exact byte size, then confirm that asset's data actually reached iCloud.
    static func verify(folder: URL, library: URL,
                       progress: (@Sendable (Int, Int) -> Void)? = nil) -> FolderReport {
        let photosDB = library.appendingPathComponent("database/Photos.sqlite")
        var report = FolderReport(folder: folder)

        let mediaExts: Set<String> = ["jpg","jpeg","png","heic","heif","gif","tif","tiff","webp",
                                      "dng","arw","cr2","cr3","nef","raf","orf","rw2","raw",
                                      "mov","mp4","m4v","avi"]
        var files: [(name: String, size: Int64, url: URL)] = []
        if let walker = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard mediaExts.contains(url.pathExtension.lowercased()) else { continue }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                guard size > 0 else { continue }
                files.append((url.lastPathComponent, size, url))
            }
        }
        report.totalFiles = files.count
        report.totalBytes = files.reduce(0) { $0 + $1.size }

        withReadOnly(photosDB) { db in
            // One prepared statement reused across the whole folder. Matching on name +
            // exact size and then requiring the resource to be remotely available means a
            // "safe" verdict is backed by iCloud confirming that exact byte count.
            let sql = """
                SELECT count(*) FROM ZADDITIONALASSETATTRIBUTES aa
                JOIN ZASSET a ON a.Z_PK = aa.ZASSET
                JOIN ZINTERNALRESOURCE r ON r.ZASSET = a.Z_PK
                WHERE aa.ZORIGINALFILENAME = ?1 AND r.ZDATALENGTH = ?2
                  AND r.ZREMOTEAVAILABILITY = 1 AND a.ZTRASHEDSTATE = 0
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            for (i, f) in files.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, (f.name as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 2, f.size)
                var confirmed = false
                if sqlite3_step(stmt) == SQLITE_ROW {
                    confirmed = sqlite3_column_int64(stmt, 0) > 0
                }
                if confirmed {
                    report.confirmed += 1
                } else {
                    report.missing.append(.init(name: f.name, size: f.size, url: f.url))
                }
                if i % 200 == 0 { progress?(i, files.count) }
            }
        }
        progress?(files.count, files.count)
        return report
    }

    // MARK: - sqlite plumbing

    /// mode=ro, never `immutable=1`: immutable ignores the -wal and reports a perfectly
    /// healthy live database as malformed.
    private static func withReadOnly(_ url: URL, _ body: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { sqlite3_close_v2(db); return }
        sqlite3_busy_timeout(db, 2000)
        defer { sqlite3_close_v2(db) }
        body(db)
    }

    private static func query(_ db: OpaquePointer, _ sql: String,
                              _ each: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW, let stmt { each(stmt) }
    }

    // MARK: - host

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func isRunning(_ name: String) -> Bool {
        !(shell("/usr/bin/pgrep", ["-x", name])?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// CPU percentage for a process, or nil when it is not running.
    ///
    /// Needed because whole-machine network traffic cannot tell Photos apart from a browser
    /// tab, so it is useless as a liveness signal for this one daemon.
    static func processCPU(_ name: String) -> Double? {
        guard let out = shell("/bin/ps", ["-Aco", "pid=,%cpu=,comm="]) else { return nil }
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, f[2...].joined(separator: " ") == name else { continue }
            return Double(f[1])
        }
        return nil
    }

    /// Bytes sent on the default interface. Locate `Obytes` from the header rather than a
    /// fixed column, a tunnel interface has no MAC address, which shifts every later
    /// field left by one and silently reads `Coll` (always zero) instead.
    private static func interfaceBytesOut() -> Int64 {
        guard let route = shell("/sbin/route", ["get", "default"]),
              let m = route.range(of: #"interface:\s*(\S+)"#, options: .regularExpression)
        else { return 0 }
        let iface = route[m].split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces) ?? "en0"
        guard let out = shell("/usr/sbin/netstat", ["-ibn"]) else { return 0 }
        let lines = out.split(separator: "\n")
        guard let header = lines.first?.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init), let col = header.firstIndex(of: "Obytes") else { return 0 }
        for line in lines.dropFirst() {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count > 3, f[0] == iface, f[2].hasPrefix("<Link") else { continue }
            let shift = f.count == header.count ? 0 : header.count - f.count
            let idx = col - shift
            guard idx >= 0, idx < f.count else { return 0 }
            return Int64(f[idx]) ?? 0
        }
        return 0
    }

    @discardableResult
    static func shell(_ launchPath: String, _ args: [String]) -> String? {
        run(launchPath, args).out
    }

    /// Same, but keeps stderr and the exit status.
    ///
    /// Discarding stderr is how the restart button came to fail silently for a week: the
    /// AppleScript it runs cannot touch Photos without Accessibility permission, and the
    /// refusal went to a null device.
    static func run(_ launchPath: String, _ args: [String]) -> (out: String?, err: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (nil, "\(error)", false) }
        let o = outPipe.fileHandleForReading.readDataToEndOfFile()
        let e = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: o, encoding: .utf8),
                String(data: e, encoding: .utf8) ?? "",
                p.terminationStatus == 0)
    }
}