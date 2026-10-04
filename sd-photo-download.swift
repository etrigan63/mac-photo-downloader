// sd-photo-download.swift
//
// Native macOS port of sd-photo-download.sh.
//
// Downloads photos and videos from a mounted SD card into a photo library,
// organized by EXIF date and renamed by camera model. Adds a real progress
// window (AppKit) and drops the per-tag exiftool process spawning that made the
// shell version slow.
//
// Build:   swiftc -O -o sd-photo-download sd-photo-download.swift
// Usage:   sd-photo-download [--config FILE] [--card PATH] [--dry-run]
//                              [--no-eject] [--gui] [--no-gui]
//
// Config search order (same as the shell version):
//   1. --config FILE
//   2. $SD_CARD_DOWNLOADER_CONFIG
//   3. ./config (next to this binary)
//   4. ~/Library/Application Support/SD Photo Downloader/config

import AppKit
import CryptoKit
import Foundation

// MARK: - Configuration

struct Config {
    var configFile: String = ""
    var targetDir: String = ""
    var backupDir: String = ""
    var exiftool: String = ""
    var stateDir: String = ""
    var folderPattern: String = "%Y/%Y-%m-%d"
    var counterDigits: Int = 4
    var counterStart: Int = 1
    var counterPerModel: Bool = true
    var numberSource: String = "exif"
    var photoExts: String = "jpg jpeg jpe tif tiff nef cr2 cr3 arw dng orf rw2 raf pef srf sr2 rwl raw heic heif hif png gif bmp"
    var videoExts: String = "mp4 mov m4v avi mts m2ts 3gp mod"
    var sdCard: String = "auto"
    var logFile: String = ""
    var ejectCard: Bool = true
    var notify: Bool = true
    var notifyProgress: Int = 25
    var progressBar: Bool = true
    var progressFile: String = ""
    var exifBatch: Bool = true

    var photoExtList: [String] { photoExts.split(separator: " ").map(String.init) }
    var videoExtList: [String] { videoExts.split(separator: " ").map(String.init) }
    var allExtList: [String] { photoExtList + videoExtList }

    var ledgerPath: String { (stateDir as NSString).appendingPathComponent("imported.txt") }
    var countersDir: String { (stateDir as NSString).appendingPathComponent("counters") }
}

enum ImportError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case let .message(m) = self { return m }
        return "unknown error"
    }
}

func expandHome(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
    return path
}

/// Parse KEY=VALUE lines exactly like the shell version: `#` comments, blank
/// lines ignored, one optional layer of matching quotes stripped, surrounding
/// whitespace trimmed from the key.
func loadConfig(_ cfg: inout Config) throws {
    let text: String
    do {
        text = try String(contentsOfFile: cfg.configFile, encoding: .utf8)
    } catch {
        throw ImportError.message("config not found: \(cfg.configFile)")
    }

    func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2 {
            let first = v.first!, last = v.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                v = String(v.dropFirst().dropLast())
            }
        }
        return v
    }
    func yes(_ s: String) -> Bool {
        let v = s.lowercased()
        return v == "yes" || v == "true" || v == "1"
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let val = unquote(String(line[line.index(after: eq)...]))

        switch key {
        case "TARGET_DIR": cfg.targetDir = expandHome(val, home: NSHomeDirectory())
        case "BACKUP_DIR": cfg.backupDir = expandHome(val, home: NSHomeDirectory())
        case "EXIFTOOL": cfg.exiftool = expandHome(val, home: NSHomeDirectory())
        case "STATE_DIR": cfg.stateDir = expandHome(val, home: NSHomeDirectory())
        case "FOLDER_PATTERN": cfg.folderPattern = val
        case "COUNTER_DIGITS": cfg.counterDigits = Int(val) ?? cfg.counterDigits
        case "COUNTER_START": cfg.counterStart = Int(val) ?? cfg.counterStart
        case "COUNTER_PER_MODEL": cfg.counterPerModel = yes(val)
        case "NUMBER_SOURCE": if val == "exif" || val == "counter" { cfg.numberSource = val }
        case "PHOTO_EXTS": cfg.photoExts = val
        case "VIDEO_EXTS": cfg.videoExts = val
        case "SD_CARD": cfg.sdCard = val
        case "LOG_FILE": cfg.logFile = expandHome(val, home: NSHomeDirectory())
        case "EJECT_CARD": cfg.ejectCard = yes(val)
        case "NOTIFY": cfg.notify = yes(val)
        case "NOTIFY_PROGRESS":
            let cleaned = val.hasPrefix("-") ? String(val.dropFirst()) : val
            cfg.notifyProgress = Int(cleaned).map { $0 >= 0 ? $0 : 0 } ?? 25
        case "PROGRESS_BAR": cfg.progressBar = yes(val)
        case "PROGRESS_FILE": cfg.progressFile = expandHome(val, home: NSHomeDirectory())
        case "EXIF_BATCH": cfg.exifBatch = yes(val)
        default: break
        }
    }

    if cfg.targetDir.isEmpty {
        throw ImportError.message("TARGET_DIR is not set in config: \(cfg.configFile)")
    }
    if cfg.exiftool.isEmpty {
        for candidate in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] where FileManager.default.isExecutableFile(atPath: candidate) {
            cfg.exiftool = candidate
            break
        }
        if cfg.exiftool.isEmpty, let found = which("exiftool") { cfg.exiftool = found }
        if cfg.exiftool.isEmpty {
            throw ImportError.message("exiftool not found. Install it: brew install exiftool")
        }
    }
    if !FileManager.default.isExecutableFile(atPath: cfg.exiftool) {
        throw ImportError.message("exiftool not executable: \(cfg.exiftool)")
    }
    if cfg.stateDir.isEmpty {
        cfg.stateDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/SD Photo Downloader")
    }
    if cfg.logFile.isEmpty { cfg.logFile = (cfg.stateDir as NSString).appendingPathComponent("run.log") }
    if cfg.progressFile.isEmpty { cfg.progressFile = (cfg.stateDir as NSString).appendingPathComponent("progress.txt") }
    if cfg.counterDigits < 1 { throw ImportError.message("COUNTER_DIGITS must be >= 1") }
    if cfg.counterStart < 0 { throw ImportError.message("COUNTER_START must be >= 0") }
}

func which(_ tool: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":") {
        let full = (String(dir) as NSString).appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: full) { return full }
    }
    return nil
}

// MARK: - Logging, progress, notifications

final class Reporter {
    let logFile: String
    let barEnabled: Bool
    let progressFile: String
    let notifyEnabled: Bool
    let notifyEveryPercent: Int
    private let tty: Bool
    private var lastNotifyPercent = -1
    private let stamp: DateFormatter

    init(cfg: Config, dryRun: Bool, tty: Bool) {
        self.logFile = cfg.logFile
        self.barEnabled = cfg.progressBar && tty
        self.progressFile = cfg.progressFile
        self.notifyEnabled = cfg.notify && !dryRun
        self.notifyEveryPercent = cfg.notifyProgress
        self.tty = tty
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.stamp = f
    }

    private var timestamp: String { stamp.string(from: Date()) }

    /// Per-file lines: log file only while the progress bar owns the terminal
    /// line, terminal and log file otherwise, like log/logf in the shell version.
    func logPerFile(_ message: String) {
        if barEnabled { logQuiet(message) } else { log(message) }
    }

    /// Always to the log file, never to the terminal (used while the progress
    /// bar owns the terminal line).
    func logQuiet(_ message: String) {
        appendLog(message)
    }

    /// To the terminal and the log file.
    func log(_ message: String) {
        FileHandle.standardOutput.write(Data("[\(timestamp)] \(message)\n".utf8))
        appendLog(message)
    }

    /// Errors go to the log file and stderr but never stdout, like `die` in the
    /// shell version.
    func logError(_ message: String) {
        appendLog(message)
        FileHandle.standardError.write(Data("[\(timestamp)] \(message)\n".utf8))
    }

    private func appendLog(_ message: String) {
        guard !logFile.isEmpty else { return }
        let dir = (logFile as NSString).deletingLastPathComponent
        if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        if let fh = FileHandle(forWritingAtPath: logFile) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            fh.write(Data("[\(timestamp)] \(message)\n".utf8))
        } else {
            try? Data("[\(timestamp)] \(message)\n".utf8).write(to: URL(fileURLWithPath: logFile))
        }
    }

    /// In-place terminal bar: `[######------]  62% 7/11 IMG_0042.RAF (imported)`
    func drawBar(done: Int, total: Int, current: String, status: String) {
        guard barEnabled else { return }
        FileHandle.standardOutput.write(Data("\r\(barLine(done: done, total: total, current: current, status: status))".utf8))
    }

    func clearBar() {
        guard barEnabled else { return }
        let blanks = String(repeating: " ", count: 110)
        FileHandle.standardOutput.write(Data(("\r" + blanks + "\r").utf8))
    }

    func barLine(done: Int, total: Int, current: String, status: String) -> String {
        let width = 30
        let pct = total > 0 ? min(100, done * 100 / total) : 0
        let filled = pct * width / 100
        let bar = String(repeating: "#", count: filled) + String(repeating: "-", count: width - filled)
        var line = String(format: "[%@] %3d%% %d/%d %@", bar, pct, done, total, current)
        if !status.isEmpty { line += " (\(status))" }
        return line
    }

    /// Machine-readable state for other tools (Shortcuts, menu bar widgets).
    func writeProgress(status: String, percent: Int, done: Int, total: Int, message: String) {
        guard !progressFile.isEmpty else { return }
        let dir = (progressFile as NSString).deletingLastPathComponent
        if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let line = "status=\(status) pct=\(percent) done=\(done) total=\(total) message=\(message)\n"
        try? Data(line.utf8).write(to: URL(fileURLWithPath: progressFile))
    }

    /// Notification Center banner via osascript (works from any launch context).
    func notify(_ message: String) {
        guard notifyEnabled else { return }
        var escaped = message
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"SD Photo Downloader\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - Naming helpers

/// Camera model -> filename-safe token: "Canon EOS R5" -> "Canon-EOS-R5".
func sanitizeToken(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "UNKNOWN" }
    s = String(s.map { ch -> Character in
        let ok = ch.isASCII && (ch.isLetter || ch.isNumber)
        return ok ? ch : "-"
    })
    // Collapse runs of two or more dashes into one, then trim the ends.
    while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
    while s.hasPrefix("-") { s.removeFirst() }
    while s.hasSuffix("-") { s.removeLast() }
    return s.isEmpty ? "UNKNOWN" : s
}

struct DateParts {
    var year = "", month = "", day = "", hh = "", min = "", ss = ""
    var shortYear: String { String(year.dropFirst(2)) }
    var compact: String { "\(year)\(month)\(day)" }
}

/// Format FOLDER_PATTERN for a date. Accepts exiftool-style `%Y` tokens and
/// brace-style `{YYYY}` groups, matching the shell version.
func formatSubdir(_ pattern: String, _ d: DateParts) -> String {
    var expanded = ""
    var rest = Substring(pattern)
    while let open = rest.firstIndex(of: "{") {
        expanded += String(rest[rest.startIndex..<open])
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "}") else {
            expanded += String(rest[afterOpen...])
            rest = ""
            break
        }
        var group = String(rest[afterOpen..<close])
        for (token, value) in [("YYYY", d.year), ("YY", d.shortYear), ("MM", d.month),
                               ("DD", d.day), ("HH", d.hh), ("MI", d.min), ("SS", d.ss)] {
            group = group.replacingOccurrences(of: token, with: value)
        }
        expanded += group
        rest = rest[rest.index(after: close)...]
    }
    expanded += String(rest)

    var segments: [String] = []
    for seg in expanded.split(separator: "/", omittingEmptySubsequences: true) {
        var s = String(seg)
        for (token, value) in [("%Y", d.year), ("%y", d.shortYear), ("%m", d.month),
                               ("%d", d.day), ("%H", d.hh), ("%M", d.min), ("%S", d.ss)] {
            s = s.replacingOccurrences(of: token, with: value)
        }
        if !s.isEmpty { segments.append(s) }
    }
    return segments.joined(separator: "/")
}

/// Pull the trailing digit run out of a camera file name: "_DSF5099.RAF" -> 5099.
/// Parsed as decimal, so "0008" stays 8 (the shell version read it as octal).
func numberFromCameraName(_ name: String) -> Int? {
    guard !name.isEmpty else { return nil }
    var base = name
    if let dot = base.lastIndex(of: "."), dot != base.startIndex {
        base = String(base[base.startIndex..<dot])
    }
    var digits = ""
    for ch in base.reversed() {
        if ch.isNumber, let d = ch.wholeNumberValue, d >= 0, d <= 9 {
            digits.insert(ch, at: digits.startIndex)
        } else {
            break
        }
    }
    return digits.isEmpty ? nil : Int(digits)
}

/// Parse "YYYY:MM:DD HH:MM:SS" (exiftool form). Returns nil if unusable.
func parseExifDate(_ s: String) -> DateParts? {
    let chars = Array(s)
    guard chars.count >= 10 else { return nil }
    func digits(_ range: Range<Int>) -> String { String(chars[range]) }
    let y = digits(0..<4), m = digits(5..<7), d = digits(8..<10)
    guard y.allSatisfy(\.isNumber), m.allSatisfy(\.isNumber), d.allSatisfy(\.isNumber) else { return nil }
    var parts = DateParts()
    parts.year = y
    parts.month = m
    parts.day = d
    if chars.count >= 19 {
        let hh = digits(11..<13), mi = digits(14..<16), ss = digits(17..<19)
        if hh.allSatisfy(\.isNumber), mi.allSatisfy(\.isNumber), ss.allSatisfy(\.isNumber) {
            parts.hh = hh
            parts.min = mi
            parts.ss = ss
        }
    }
    return parts
}

func fileModificationDate(_ path: String) -> DateParts {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let date = (attrs?[.modificationDate] as? Date) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return parseExifDate(f.string(from: date)) ?? DateParts()
}

func md5Hex(ofFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - exiftool

struct Meta {
    var dateTimeOriginal = ""
    var createDate = ""
    var modifyDate = ""
    var model = ""
    var make = ""
    var fileName = ""
}

/// One batched `exiftool -json` pass over the card. Returns metadata keyed by
/// the exact source path exiftool reports, which is how the shell version
/// matched files up too.
func readMetadata(cfg: Config, cardPath: String, exifBatch: Bool, exts: [String]) -> [String: Meta] {
    if !exifBatch { return readMetadataPerFile(cfg: cfg, cardPath: cardPath, exts: exts) }
    var args = ["-q", "-q", "-json", "-r"]
    for e in exts { args += ["-ext", e] }
    args += ["-SourceFile", "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-Model", "-Make", "-FileName", cardPath]

    let tmp = NSTemporaryDirectory() + "sd-exif-\(UUID().uuidString).json"
    FileManager.default.createFile(atPath: tmp, contents: nil)
    guard let out = FileHandle(forWritingAtPath: tmp) else { return [:] }
    defer { try? out.close() }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: cfg.exiftool)
    proc.arguments = args
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return [:] }
    proc.waitUntilExit()
    try? out.close()

    guard let data = FileManager.default.contents(atPath: tmp) else { return [:] }
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var result: [String: Meta] = [:]
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return result }
    for item in parsed {
        func value(_ key: String) -> String {
            guard let raw = item[key] else { return "" }
            if let s = raw as? String { return s }
            if let list = raw as? [String] { return list.first ?? "" }
            return ""
        }
        let source = value("SourceFile")
        guard !source.isEmpty else { continue }
        var meta = Meta()
        meta.dateTimeOriginal = value("DateTimeOriginal")
        meta.createDate = value("CreateDate")
        meta.modifyDate = value("ModifyDate")
        meta.model = value("Model")
        meta.make = value("Make")
        meta.fileName = value("FileName")
        if result[source] == nil { result[source] = meta }
    }
    return result
}

/// Fallback for cards exiftool cannot walk in one pass: one small call per file.
func readMetadataPerFile(cfg: Config, cardPath: String, exts: [String]) -> [String: Meta] {
    var result: [String: Meta] = [:]
    guard let walker = FileManager.default.enumerator(atPath: cardPath) else { return result }
    // Deliberately not -json: this is the fallback for a batched pass that came
    // back empty, so it must not depend on the same exiftool feature failing.
    // -T prints one tab-separated line per file, in the order asked for.
    let tags = ["-FileName", "-DateTimeOriginal", "-CreateDate", "-ModifyDate", "-Model", "-Make"]
    while let item = walker.nextObject() as? String {
        let ext = (item as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, exts.contains(ext) else { continue }
        let full = (cardPath as NSString).appendingPathComponent(item)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cfg.exiftool)
        proc.arguments = ["-q", "-q", "-s", "-s", "-s", "-T"] + tags + [full]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { continue }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let row = text.split(separator: "\n", omittingEmptySubsequences: true).last else { continue }
        let cells = row.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ index: Int) -> String {
            guard index < cells.count, cells[index] != "-" else { return "" }
            return cells[index]
        }
        var meta = Meta()
        meta.fileName = value(0)
        meta.dateTimeOriginal = value(1)
        meta.createDate = value(2)
        meta.modifyDate = value(3)
        meta.model = value(4)
        meta.make = value(5)
        if result[full] == nil { result[full] = meta }
    }
    return result
}

// MARK: - Card detection

/// True when `path` holds a DCIM folder, or one level below it: some readers
/// mount cards as <volume>/DCIM while Android/MTP style volumes nest it.
func deviceID(_ path: String) -> dev_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_dev
}

func hasDCIMFolder(_ path: String) -> Bool {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return false }
    let volumeDevice = deviceID(path)
    for entry in entries {
        let full = (path as NSString).appendingPathComponent(entry)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
        if entry.lowercased() == "dcim" { return true }
        // Skip symlinked folders so a broken link never looks like a card.
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: full)) != nil
        // Skip nested mounts: cloud shares (nfs, smbfs, webdav) sit inside some
        // volumes and can hang for minutes when the server is unreachable.
        let isNestedMount = volumeDevice != nil && deviceID(full) != nil
            && deviceID(full) != volumeDevice
        if !isLink, !isNestedMount, let nested = try? fm.contentsOfDirectory(atPath: full) {
            for child in nested where child.lowercased() == "dcim" {
                let childPath = (full as NSString).appendingPathComponent(child)
                var childIsDir: ObjCBool = false
                if fm.fileExists(atPath: childPath, isDirectory: &childIsDir), childIsDir.boolValue {
                    return true
                }
            }
        }
    }
    return false
}

/// Where mounted volumes live. Overridable so the parity tests can supply
/// fake cards without touching the real /Volumes.
func volumesRoot() -> String {
    if let override = ProcessInfo.processInfo.environment["SD_VOLUMES_DIR"], !override.isEmpty {
        return override
    }
    return "/Volumes"
}

func diskutilOutput(_ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: which("diskutil") ?? "/usr/sbin/diskutil")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Volumes that look like a camera card, in mount order.
func scanCardVolumes() -> [String] {
    let root = volumesRoot()
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    var found: [String] = []
    for entry in entries.sorted() {
        if entry == "Macintosh HD" || entry.hasPrefix(".") { continue }
        let full = (root as NSString).appendingPathComponent(entry)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
        // A symlink here would be counted twice or point at nothing.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) != nil { continue }
        if hasDCIMFolder(full) { found.append(full) }
    }
    return found
}

/// macOS sometimes leaves a freshly inserted card unmounted, which used to end
/// the run with "no SD card found". Mount removable media, then look again.
/// Fixed disks (external SSDs, NAS mounts) are never touched, and a volume that
/// still has no DCIM folder is left alone for the caller to ignore.
func mountRemovableMedia() -> [String] {
    var log: [String] = []
    guard let listing = diskutilOutput(["list", "external", "physical"]) else { return log }
    let disks = listing.split(separator: "\n").compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/dev/disk"), trimmed.contains("(external") else { return nil }
        return String(trimmed.prefix(while: { !$0.isWhitespace }))
    }
    for disk in disks {
        guard let info = diskutilOutput(["info", disk]) else { continue }
        guard info.contains("Removable Media:"),
              info.range(of: "Removable Media:[^\\n]*Removable", options: .regularExpression) != nil else { continue }
        guard let partitions = diskutilOutput(["list", disk]) else { continue }
        // "diskutil list" prints device names in the last column, not at the
        // start of the line: "   1:  EFI EFI   209.7 MB   disk6s1".
        let diskName = disk.replacingOccurrences(of: "/dev/", with: "")
        for line in partitions.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.lastIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let id = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            let suffix = id.dropFirst(diskName.count + 1)
            guard id.hasPrefix(diskName + "s"), !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { continue }
            let part = "/dev/" + id
            if let partInfo = diskutilOutput(["info", part]),
               partInfo.range(of: "Mounted:[^\\n]*No", options: .regularExpression) != nil {
                if let mounted = diskutilOutput(["mount", part]) {
                    log.append("Mounted \(mounted.trimmingCharacters(in: .whitespacesAndNewlines)) (was not mounted)")
                }
            }
        }
    }
    return log
}

// MARK: - Single instance, with takeover

/// The GUI keeps its window open for a moment after a run so the result stays
/// on screen, and macOS treats a second launch of a running app as "activate
/// it". Without this, a Stream Deck press in that window would do nothing.
///
/// So a new instance does not kill the running one: it asks it to stop at a
/// safe point (between files, or while it is only waiting to close), waits for
/// it to exit, then takes over. If the running instance is genuinely mid-import
/// and does not stop, the new one gives up instead of writing the same files
/// twice.

/// How long a new instance waits for the running one to hand over. The test
/// harness shortens this; real runs want the default.
let lockWaitSeconds: Double = {
    if let raw = ProcessInfo.processInfo.environment["LOCK_WAIT_SECONDS"], let value = Double(raw), value >= 0 {
        return value
    }
    return 15
}()
var runLockPath = ""
var takeoverRequestPath = ""

func pidAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    return kill(pid, 0) == 0
}

func writePID(_ pid: Int32, to path: String) {
    try? "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
}

func readPID(_ path: String) -> Int32? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(trimmed), pid > 0 else { return nil }
    return pid
}

/// Returns nil when the lock is claimed, or the blocking pid when another live
/// instance refused to hand over.
func claimRunLock(stateDir: String, log: (String) -> Void) -> Int32? {
    let fm = FileManager.default
    runLockPath = (stateDir as NSString).appendingPathComponent("run.lock")
    takeoverRequestPath = (stateDir as NSString).appendingPathComponent("run.lock.takeover")
    let mine = ProcessInfo.processInfo.processIdentifier

    if let owner = readPID(runLockPath) {
        if pidAlive(owner) {
            writePID(mine, to: takeoverRequestPath)
            log("Another instance is running (pid \(owner)); asking it to stop.")
            let deadline = Date().addingTimeInterval(lockWaitSeconds)
            while pidAlive(owner) && Date() < deadline { usleep(200_000) }
            if pidAlive(owner) {
                try? fm.removeItem(atPath: takeoverRequestPath)
                return owner
            }
            log("Took over from a finished instance (pid \(owner)).")
        }
        try? fm.removeItem(atPath: runLockPath)
    }
    writePID(mine, to: runLockPath)
    return nil
}

func releaseRunLock() {
    guard !runLockPath.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: runLockPath)
}

/// True when a newer live instance asked us to stop. Only call this at safe
/// points: between files, or while idling before exit.
func takeoverRequested() -> Bool {
    guard !takeoverRequestPath.isEmpty, let req = readPID(takeoverRequestPath),
          req != ProcessInfo.processInfo.processIdentifier else { return false }
    try? FileManager.default.removeItem(atPath: takeoverRequestPath)
    return pidAlive(req)
}

func detectCard(cfg: Config, requested: String?, log: (String) -> Void = { _ in }) throws -> String {
    if let requested, !requested.isEmpty {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.message("card path is not a directory: \(requested)")
        }
        return requested
    }
    if cfg.sdCard != "auto" {
        let path = expandHome(cfg.sdCard, home: NSHomeDirectory())
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.message("configured SD_CARD is not a directory: \(path)")
        }
        return path
    }
    var found = scanCardVolumes()
    if found.isEmpty {
        for line in mountRemovableMedia() { log(line) }
        found = scanCardVolumes()
    }
    let root = volumesRoot()
    if found.isEmpty {
        throw ImportError.message("no SD card found: no volume under \(root) has a DCIM folder")
    }
    if found.count > 1 {
        throw ImportError.message("multiple SD cards found; pass one explicitly with --card (or drop it on the action)")
    }
    return found[0]
}

// MARK: - Import engine

final class Importer {
    let cfg: Config
    let reporter: Reporter
    let dryRun: Bool
    let eject: Bool
    private var ledger: [String: String] = [:]
    private var ledgerOrder: [String] = []
    private var counters: [String: Int] = [:]
    var copied = 0
    var skipped = 0
    var handedOver = false
    var total = 0
    var done = 0
    var onUpdate: ((Int, Int, String, String) -> Void)?

    init(cfg: Config, dryRun: Bool, eject: Bool, reporter: Reporter) {
        self.cfg = cfg
        self.dryRun = dryRun
        self.eject = eject
        self.reporter = reporter
    }

    func run(cards: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: cfg.stateDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cfg.targetDir, withIntermediateDirectories: true)
        if !cfg.backupDir.isEmpty { try? fm.createDirectory(atPath: cfg.backupDir, withIntermediateDirectories: true) }
        try? fm.createDirectory(atPath: cfg.countersDir, withIntermediateDirectories: true)
        loadLedger()
        loadCounters()

        var grandTotal = 0
        for (index, card) in cards.enumerated() {
            reporter.log("SD card:   \(card)\(cards.count > 1 ? " (\(index + 1)/\(cards.count))" : "")")
            reporter.log("Target:    \(cfg.targetDir)")
            if !cfg.backupDir.isEmpty { reporter.log("Backup:    \(cfg.backupDir)") }
            if index == 0 { reporter.notify("Importing from \((card as NSString).lastPathComponent)...") }
            handedOver = false
            try importCard(card)
            grandTotal += total
            if handedOver { break }
            ejectCard(card)
        }
        reporter.clearBar()
        if handedOver {
            reporter.log("Stopped: a newer instance took over.")
            reporter.writeProgress(status: "done", percent: 100, done: done, total: total,
                                   message: "stopped, a newer instance took over")
            return
        }
        reporter.log("Done: \(copied) imported, \(skipped) already present.")
        reporter.writeProgress(status: "done", percent: 100, done: done, total: total,
                               message: "\(copied) imported, \(skipped) skipped\(dryRun ? " (dry run)" : "")")
        if dryRun {
            reporter.log("DRY RUN - no files were written.")
        } else {
            reporter.notify("Done: \(copied) imported, \(skipped) skipped.")
        }
        _ = grandTotal
    }

    // MARK: ledger & counters

    private func loadLedger() {
        guard let text = try? String(contentsOfFile: cfg.ledgerPath, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let hash = String(parts[0])
            if ledger[hash] == nil { ledgerOrder.append(hash) }
            ledger[hash] = parts.count > 1 ? String(parts[1]) : ""
        }
    }

    private func appendLedger(_ hash: String, relativePath: String) {
        guard !dryRun, !hash.isEmpty else { return }
        // Update the map too: a later file in this same run with identical
        // content has to see the entry the shell version greps from disk.
        ledger[hash] = relativePath
        let line = "\(hash)\t\(relativePath)\n"
        if FileManager.default.fileExists(atPath: cfg.ledgerPath), let fh = FileHandle(forWritingAtPath: cfg.ledgerPath) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            fh.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: cfg.ledgerPath))
        }
    }

    private func loadCounters() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cfg.countersDir) else { return }
        for entry in entries where entry.hasSuffix(".txt") {
            let name = String(entry.dropLast(4))
            if let text = try? String(contentsOfFile: (cfg.countersDir as NSString).appendingPathComponent(entry), encoding: .utf8),
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                counters[name] = value
            }
        }
    }

    private func bumpCounter(_ key: String, to value: Int) {
        counters[key] = value
        guard !dryRun else { return }
        try? Data("\(value)\n".utf8).write(to: URL(fileURLWithPath: (cfg.countersDir as NSString).appendingPathComponent("\(key).txt")))
    }

    /// Highest image number already in the library for this camera model, by
    /// matching `<model>-YYYYMMDD-<digits>.<ext>` the way the shell version did.
    private func scanMaxNumber(model: String) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: cfg.targetDir), includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var best = 0
        while let url = walker.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: "-")
            guard parts.count >= 3 else { continue }
            let digits = parts[parts.count - 1]
            let date = parts[parts.count - 2]
            let token = parts[0..<(parts.count - 2)].joined(separator: "-")
            guard digits.count == cfg.counterDigits, digits.allSatisfy(\.isNumber),
                  date.count == 8, !token.isEmpty else { continue }
            if cfg.counterPerModel, token != model { continue }
            guard let value = Int(digits) else { continue }
            best = max(best, value)
        }
        return best
    }

    private func nextNumber(model: String, key: String) -> Int {
        if let stored = counters[key] { return stored }
        return max(scanMaxNumber(model: model) + 1, cfg.counterStart)
    }

    // MARK: per-card work

    private func importCard(_ card: String) throws {
        let fm = FileManager.default
        let exts = Set(cfg.allExtList.map { $0.lowercased() })
        guard !exts.isEmpty else { throw ImportError.message("no file extensions configured") }

        reporter.log("Scanning for photos/videos...")
        if !reporter.progressFile.isEmpty { reporter.log("Progress: \(reporter.progressFile)") }
        var files = try enumerateMedia(under: card, exts: exts)
        // LC_ALL=C sort in the shell version: byte order, not locale collation.
        files.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let base = done
        total += files.count
        reporter.log("Found \(files.count) file(s).")
        reporter.writeProgress(status: "starting", percent: 0, done: 0, total: total, message: "scanning")

        var meta: [String: Meta] = [:]
        if files.isEmpty {
            // Nothing to read: the shell version skips the pass entirely.
        } else if cfg.exifBatch {
            reporter.log("Reading metadata in one pass...")
            meta = readMetadata(cfg: cfg, cardPath: card, exifBatch: true, exts: Array(exts))
        } else {
            reporter.log("Reading metadata file by file...")
            meta = readMetadata(cfg: cfg, cardPath: card, exifBatch: false, exts: Array(exts))
        }
        // If the batched pass produced nothing (exiftool too old for -json, a
        // broken install, an odd card), read the tags file by file rather than
        // silently naming everything from mtime.
        if meta.isEmpty && !files.isEmpty {
            if cfg.exifBatch {
                reporter.log("WARN: batch metadata unavailable; falling back to per-file reads.")
                reporter.log("Reading metadata file by file...")
                meta = readMetadata(cfg: cfg, cardPath: card, exifBatch: false, exts: Array(exts))
            } else {
                reporter.log("WARN: no metadata returned by exiftool; using file dates.")
            }
        }

        for (index, path) in files.enumerated() {
            if takeoverRequested() {
                reporter.log("Handing over: a newer instance asked me to stop.")
                handedOver = true
                break
            }
            let m = meta[path] ?? Meta()
            let dest = destination(for: path, meta: m)
            let name = dest.name
            let ext = (path as NSString).pathExtension.lowercased()
            let date = resolveDate(for: path, meta: m)
            let subdir = formatSubdir(cfg.folderPattern, date)
            let target = subdir.isEmpty
                ? (cfg.targetDir as NSString).appendingPathComponent(name)
                : ((cfg.targetDir as NSString).appendingPathComponent(subdir) as NSString).appendingPathComponent(name)
            let backup = cfg.backupDir.isEmpty ? nil : ((subdir.isEmpty
                ? cfg.backupDir
                : (cfg.backupDir as NSString).appendingPathComponent(subdir)) as NSString).appendingPathComponent(name)

            var copied = false
            if fm.fileExists(atPath: target) {
                // EXIF numbers give deterministic names, so an existing target
                // means "already imported". A counter-generated name can collide
                // with an unrelated file, which would silently drop a photo.
                if dest.usedCounter { reporter.logPerFile("WARN: name collision, not importing: \(name)") }
                skipped += 1
                reporter.logPerFile("skip     (already imported): \(name)")
            } else if let hash = md5Hex(ofFile: path), let previous = ledger[hash],
                      !previous.isEmpty,
                      fm.fileExists(atPath: (cfg.targetDir as NSString).appendingPathComponent(previous)) {
                // Same content, recorded copy still present: already imported.
                skipped += 1
                reporter.logPerFile("skip     (already imported and still in library): \(name)")
            } else {
                reporter.logPerFile("import   \(name)")
                reporter.logPerFile("         from: \(path)")
                if let backup { reporter.logPerFile("         backup to: \((backup as NSString).deletingLastPathComponent)") }
                if !dryRun {
                    let targetDirPath = (target as NSString).deletingLastPathComponent
                    try? fm.createDirectory(atPath: targetDirPath, withIntermediateDirectories: true)
                    do {
                        try fm.copyItem(atPath: path, toPath: target)
                        copied = true
                    } catch {
                        reporter.log("WARN: copy to target failed for \(name): \(error.localizedDescription)")
                    }
                    if copied, let backup {
                        let backupDirPath = (backup as NSString).deletingLastPathComponent
                        try? fm.createDirectory(atPath: backupDirPath, withIntermediateDirectories: true)
                        if !fm.fileExists(atPath: backup) {
                            do { try fm.copyItem(atPath: path, toPath: backup) }
                            catch { reporter.log("WARN: backup copy failed for \(name): \(error.localizedDescription)") }
                        }
                    }
                    if copied {
                        // Ledger and counter only move forward on a real copy,
                        // and the ledger is independent of BACKUP_DIR.
                        if let hash = md5Hex(ofFile: path) {
                            let relative = String(target.dropFirst(cfg.targetDir.count + 1))
                            appendLedger(hash, relativePath: relative)
                        }
                        if dest.usedCounter { bumpCounter(dest.counterKey, to: dest.counterValue + 1) }
                    }
                } else {
                    copied = true
                }
                if copied { self.copied += 1 }
            }

            done = base + index + 1
            let percent = total > 0 ? min(100, done * 100 / total) : 0
            reporter.drawBar(done: done, total: total, current: name, status: copied ? "imported" : "skipped")
            reporter.writeProgress(status: copied ? "imported" : "skipped", percent: percent,
                                   done: done, total: total, message: name)
            maybeNotifyProgress(percent: percent, done: done)
            onUpdate?(done, total, name, copied ? "imported" : "skipped")
            _ = ext
        }
    }

    private func maybeNotifyProgress(percent: Int, done: Int) {
        let step = reporter.notifyEveryPercent
        guard step > 0, percent >= lastNotifyPercent + step else { return }
        lastNotifyPercent = percent / step * step
        reporter.notify("Importing: \(percent)% (\(done)/\(total))")
    }

    private var lastNotifyPercent = -1

    private struct Destination {
        var name: String
        var usedCounter: Bool
        var counterKey: String
        var counterValue: Int
    }

    private func destination(for path: String, meta: Meta) -> Destination {
        let ext = (path as NSString).pathExtension.lowercased()
        let date = resolveDate(for: path, meta: meta)
        let model = !meta.model.isEmpty ? meta.model : meta.make
        let token = sanitizeToken(model)
        let key = cfg.counterPerModel ? token : "ALL"

        var number: Int?
        var usedCounter = false
        if cfg.numberSource == "exif" { number = numberFromCameraName(meta.fileName) }
        if number == nil {
            number = nextNumber(model: token, key: key)
            usedCounter = true
        }
        let value = number ?? 0
        let digits = String(format: "%0*d", cfg.counterDigits, value)
        return Destination(name: "\(token)-\(date.compact)-\(digits).\(ext)",
                           usedCounter: usedCounter, counterKey: key, counterValue: value)
    }

    private func resolveDate(for path: String, meta: Meta) -> DateParts {
        for candidate in [meta.dateTimeOriginal, meta.createDate, meta.modifyDate] {
            if !candidate.isEmpty, let parsed = parseExifDate(candidate) { return parsed }
        }
        return fileModificationDate(path)
    }

    private func enumerateMedia(under root: String, exts: Set<String>) throws -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        guard let walker = fm.enumerator(atPath: root) else {
            throw ImportError.message("cannot read card: \(root)")
        }
        while let item = walker.nextObject() as? String {
            let ext = (item as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, exts.contains(ext) else { continue }
            let full = (root as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            results.append(full)
        }
        return results
    }

    /// One card, right after its own import, like `maybe_eject` in the shell
    /// version. Never touches a real volume unless it lives under /Volumes.
    func ejectCard(_ card: String) {
        guard eject else {
            reporter.log("Eject skipped (EJECT_CARD=\(cfg.ejectCard ? "yes" : "no")).")
            return
        }
        if dryRun {
            reporter.log("DRY RUN - would eject \(card)")
            return
        }
        guard card.hasPrefix("/Volumes/") else {
            reporter.log("Not ejecting non-volume path: \(card)")
            return
        }
        do {
            let diskutil = which("diskutil") ?? "/usr/sbin/diskutil"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: diskutil)
            proc.arguments = ["eject", card]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                reporter.log("Ejected \(card)")
            } else {
                reporter.log("WARN: could not eject \(card) (not a mountable volume?)")
            }
        } catch {
            reporter.log("WARN: could not eject \(card): \(error.localizedDescription)")
        }
    }
}

// MARK: - GUI

final class ProgressWindowController {
    private var window: NSWindow!
    private let bar = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Importing…")
    private let countLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SD Photo Downloader"
        window.center()

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .tertiaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        closeButton.target = NSApp
        closeButton.action = #selector(NSApplication.terminate(_:))
        closeButton.isHidden = true

        let stack = NSStackView(views: [titleLabel, bar, countLabel, fileLabel, closeButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            countLabel.widthAnchor.constraint(equalTo: bar.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: bar.widthAnchor),
        ])
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back to the pre-run state, for a second run in the same process.
    func beginRun() {
        bar.doubleValue = 0
        titleLabel.stringValue = "Importing…"
        titleLabel.textColor = .labelColor
        countLabel.stringValue = ""
        fileLabel.stringValue = ""
        closeButton.isHidden = true
        window.makeKeyAndOrderFront(nil)
    }

    func update(done: Int, total: Int, name: String, status: String) {
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        bar.doubleValue = fraction
        countLabel.stringValue = "\(done) of \(total) files  (\(Int(fraction * 100))%)  —  \(status)"
        fileLabel.stringValue = name
        titleLabel.stringValue = total > 1 && done < total
            ? "Importing \(done)/\(total)…"
            : "Importing…"
    }

    func finish(message: String, isError: Bool) {
        bar.doubleValue = 1
        titleLabel.stringValue = message
        titleLabel.textColor = isError ? .systemRed : .systemGreen
        countLabel.stringValue = isError ? "" : "You can close this window."
        fileLabel.stringValue = ""
        closeButton.isHidden = false
    }
}

var guiController: ProgressWindowController?

// MARK: - Entry point

let usageText = """
sd-photo-download — import photos and videos from an SD card into a photo library.

Options:
  -c, --config FILE   use FILE instead of the default config
      --card PATH     import from PATH (repeatable)
      --dry-run       show what would happen, write nothing, don't eject
      --no-eject      do not eject the card when done
      --gui           show a progress window
      --no-gui        terminal output only
  -h, --help          show this help
"""

var configFile = ProcessInfo.processInfo.environment["SD_CARD_DOWNLOADER_CONFIG"] ?? ""
if configFile.isEmpty {
    let sibling = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    let candidate = (sibling as NSString).appendingPathComponent("config")
    if FileManager.default.fileExists(atPath: candidate) { configFile = candidate }
}
if configFile.isEmpty {
    // Same search order as the shell version: next to the binary, then the
    // installer's directory, then Application Support.
    let installed = (NSHomeDirectory() as NSString).appendingPathComponent(".sd-photo-downloader/config")
    if FileManager.default.fileExists(atPath: installed) { configFile = installed }
}
if configFile.isEmpty {
    configFile = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/SD Photo Downloader/config")
}

var cardArgs: [String] = []
var dryRun = false
var noEject = false
// Launched from an .app bundle there is no terminal, so show the progress window
// unless --no-gui says otherwise.
var gui = Bundle.main.bundleURL.pathExtension == "app"
    || ProcessInfo.processInfo.environment["SD_GUI"] == "1"

var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let arg = argv[i]
    func nextValue(_ flag: String) -> String {
        guard i + 1 < argv.count else {
            FileHandle.standardError.write(Data("ERROR: \(flag) needs an argument\n".utf8))
            exit(1)
        }
        i += 1
        return argv[i]
    }
    switch arg {
    case "-c", "--config": configFile = nextValue(arg)
    case "--card": cardArgs.append(nextValue(arg))
    case "--dry-run": dryRun = true
    case "--no-eject": noEject = true
    case "--gui": gui = true
    case "--no-gui": gui = false
    case "-h", "--help": print(usageText); exit(0)
    default: cardArgs.append(arg)   // a folder dropped on an Automator action
    }
    i += 1
}

var cfg = Config()
cfg.configFile = configFile

// Assigned once the config is parsed: the log, progress and notification paths
// all depend on it, so a pre-config failure only goes to stderr.
var reporter: Reporter!
var exitCode: Int32 = 0

/// True only while the app is idling after a run, waiting to close. macOS
/// activates a running app instead of launching a second copy, so a Stream Deck
/// press during that window arrives here as an activation - treat it as
/// "run again" rather than doing nothing.
var guiIdleAfterRun = false
var countdownGeneration = 0

/// How long the result stays on screen before the app quits. Kept short on
/// purpose: while the app is running, macOS activates it instead of starting a
/// second copy, and AppKit does not even report that activation when the app is
/// already frontmost. A short linger keeps that blind window tiny - a Stream
/// Deck press after this point always starts a fresh run.
let guiLingerSeconds: Double = 5

func applicationDidBecomeActive() {
    guard guiIdleAfterRun else { return }  // importing, or nothing has run yet
    guiIdleAfterRun = false                // consume it, so showing the window cannot loop
    countdownGeneration += 1              // stop the pending quit
    DispatchQueue.global(qos: .userInitiated).async(execute: runImport)
}

/// Stay up for `seconds` so the result stays on screen, but hand the process
/// over immediately if a newer instance asks for it, or start a fresh run if
/// the app is activated again.
func guiCountdown(_ seconds: Double) {
    guiIdleAfterRun = true
    countdownGeneration += 1
    let generation = countdownGeneration
    var waited = 0.0
    func tick() {
        guard generation == countdownGeneration else { return }  // a new run took over
        if takeoverRequested() {
            reporter?.log("Handing over: a newer instance asked me to stop.")
            releaseRunLock()
            NSApp.terminate(nil)
            return
        }
        waited += 0.25
        if waited >= seconds {
            guiIdleAfterRun = false
            releaseRunLock()
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: tick)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: tick)
}

func finish(_ error: Error?) {
    releaseRunLock()
    if let error {
        if let reporter {
            reporter.logError("ERROR: \(error)")
            reporter.writeProgress(status: "error", percent: 0, done: 0, total: 0, message: "\(error)")
            reporter.notify("Failed: \(error)")
        } else {
            // Config failed to load, so there is no log file or progress file
            // yet: stderr is the only place the reason can go.
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
        }
        if gui {
            DispatchQueue.main.async {
                guiController?.finish(message: "Failed", isError: true)
                guiCountdown(guiLingerSeconds)
            }
        }
        exitCode = 1
    } else {
        if gui {
            DispatchQueue.main.async {
                guiController?.finish(message: "Done", isError: false)
                guiCountdown(guiLingerSeconds)
            }
        }
        exitCode = 0
    }
}

func runImport() {
    guiIdleAfterRun = false
    if gui {
        DispatchQueue.main.async { guiController?.beginRun() }
    }
    do {
        try loadConfig(&cfg)
        if noEject { cfg.ejectCard = false }
        // Reporter needs the final config (log/progress paths).
        let rep = Reporter(cfg: cfg, dryRun: dryRun, tty: isatty(STDOUT_FILENO) != 0)
        reporter = rep
        let importer = Importer(cfg: cfg, dryRun: dryRun, eject: cfg.ejectCard, reporter: rep)
        if gui {
            importer.onUpdate = { done, total, name, status in
                DispatchQueue.main.async { guiController?.update(done: done, total: total, name: name, status: status) }
            }
        }
        if let busy = claimRunLock(stateDir: cfg.stateDir, log: { reporter?.log($0) }) {
            finish(ImportError.message("another import is already in progress (pid \(busy))"))
            return
        }
        let resolved = cardArgs.isEmpty
            ? [try detectCard(cfg: cfg, requested: nil, log: { reporter?.log($0) })]
            : try cardArgs.map { try detectCard(cfg: cfg, requested: $0) }
        try importer.run(cards: resolved)
        finish(nil)
    } catch {
        finish(error)
    }
}

// Launching a running app again (Stream Deck press, `open -a`, Dock click) is
// delivered here, and unlike activation it also arrives while the app is
// already frontmost. Every press therefore starts a fresh import.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: () -> Void = {}
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen()
        return false  // the progress window stays as it is
    }
}

if gui {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.onReopen = { applicationDidBecomeActive() }
    app.delegate = delegate
    let controller = ProgressWindowController()
    guiController = controller
    controller.show()
    NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        applicationDidBecomeActive()
    }
    DispatchQueue.global(qos: .userInitiated).async(execute: runImport)
    app.run()
} else {
    runImport()
}

exit(exitCode)