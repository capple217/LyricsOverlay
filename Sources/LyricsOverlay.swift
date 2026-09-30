// LyricsOverlay — floating, time-synced lyrics for Apple Music.
//
// How it works
//   • Reads the current track + playback position from Music via AppleScript
//     (polled every 0.5 s, plus an instant re-poll on Music's playerInfo notification).
//   • Interpolates position locally between polls so line changes land on time.
//   • Fetches synced LRC lyrics from LRCLIB (lrclib.net, free, no API key) and
//     caches them in ~/Library/Caches/LyricsOverlay.
//   • Draws a non-activating, always-on-top panel that follows you across Spaces
//     and over full-screen apps. Controlled from a menu-bar icon or right-click.

import AppKit
import CoreServices
import ServiceManagement

// MARK: - Models

struct LyricLine {
    let time: Double
    let text: String
}

enum LyricsState {
    case idle
    case loading
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case notFound
}

struct Track: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: Double

    var cacheKey: String {
        "\(artist.lowercased())|\(name.lowercased())|\(album.lowercased())|\(Int(duration.rounded()))"
    }
}

enum PlayerState {
    case notRunning, stopped, playing, paused, unauthorized
}

struct PlayerSnapshot {
    var state: PlayerState
    var position: Double? = nil
    var track: Track? = nil
}

// MARK: - Music bridge (AppleScript)

@MainActor
final class MusicBridge {
    static let bundleID = "com.apple.Music"

    private lazy var script: NSAppleScript? = {
        let source = """
        tell application id "com.apple.Music"
            with timeout of 2 seconds
                if player state is stopped then return {"stopped"}
                if player state is paused then
                    set stateName to "paused"
                else
                    set stateName to "playing"
                end if
                try
                    set trk to current track
                    return {stateName, player position, name of trk, artist of trk, album of trk, duration of trk}
                on error
                    try
                        return {stateName, player position}
                    on error
                        return {stateName}
                    end try
                end try
            end timeout
        end tell
        """
        guard let s = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        s.compileAndReturnError(&err)
        if let err { NSLog("LyricsOverlay: AppleScript compile error: \(err)") }
        return s
    }()

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Returns nil on a transient AppleScript failure (timeout, Music busy) so the caller keeps its last state.
    func poll() -> PlayerSnapshot? {
        // Never touch Music via AppleScript unless it is already running (that would launch it).
        guard isMusicRunning, let script else { return PlayerSnapshot(state: .notRunning) }

        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            NSLog("LyricsOverlay: AppleScript error \(code): \(err[NSAppleScript.errorMessage] ?? "")")
            if code == -1743 || code == -1744 { return PlayerSnapshot(state: .unauthorized) }
            if code == -600 { return PlayerSnapshot(state: .notRunning) }   // Music quit mid-call
            return nil
        }

        let n = result.numberOfItems
        func str(_ i: Int) -> String {
            guard i <= n else { return "" }
            return result.atIndex(i)?.stringValue ?? ""
        }
        func num(_ i: Int) -> Double? {
            guard i <= n, let d = result.atIndex(i),
                  let c = d.coerce(toDescriptorType: DescType(typeIEEE64BitFloatingPoint)) else { return nil }
            return c.doubleValue
        }

        let stateString = str(1)
        let state: PlayerState
        switch stateString {
        case "playing": state = .playing
        case "paused": state = .paused
        default: return PlayerSnapshot(state: .stopped)
        }

        var snap = PlayerSnapshot(state: state, position: num(2))
        if n >= 6 {
            let name = str(3)
            if !name.isEmpty {
                snap.track = Track(name: name, artist: str(4), album: str(5), duration: num(6) ?? 0)
            }
        }
        return snap
    }
}

// MARK: - Lyrics provider (LRCLIB + disk cache)

final class LyricsProvider {
    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private struct Cached: Codable {
        var synced: String?
        var plain: String?
        var instrumental: Bool
    }

    private let session: URLSession
    private let cacheDir: URL

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.httpAdditionalHeaders = ["User-Agent": "LyricsOverlay/1.0 (personal macOS lyrics overlay)"]
        session = URLSession(configuration: cfg)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Calls `completion` on the main queue.
    func fetch(_ track: Track, bypassCache: Bool, completion: @escaping (LyricsState) -> Void) {
        let cacheURL = cacheDir.appendingPathComponent(Self.fnv1a(track.cacheKey) + ".json")

        if !bypassCache,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(Cached.self, from: data),
           let state = Self.state(synced: cached.synced, plain: cached.plain, instrumental: cached.instrumental) {
            completion(state)
            return
        }

        let finish: (Record?) -> Void = { record in
            var result: LyricsState = .notFound
            if let r = record,
               let s = Self.state(synced: r.syncedLyrics, plain: r.plainLyrics, instrumental: r.instrumental ?? false) {
                result = s
                let cached = Cached(synced: r.syncedLyrics, plain: r.plainLyrics, instrumental: r.instrumental ?? false)
                if let data = try? JSONEncoder().encode(cached) { try? data.write(to: cacheURL) }
            }
            DispatchQueue.main.async { completion(result) }
        }

        // 1) Exact match   2) search by title+artist   3) search with cleaned title / primary artist
        var params: [(String, String)] = [("track_name", track.name), ("artist_name", track.artist)]
        if !track.album.isEmpty { params.append(("album_name", track.album)) }
        if track.duration > 0 { params.append(("duration", String(Int(track.duration.rounded())))) }

        request("get", params) { [self] data in
            if let data, let r = try? JSONDecoder().decode(Record.self, from: data), Self.hasContent(r) {
                finish(r); return
            }
            search(track.name, track.artist, duration: track.duration) { [self] r in
                if let r { finish(r); return }
                let cleanName = Self.cleanTitle(track.name)
                let cleanArtist = Self.primaryArtist(track.artist)
                if cleanName == track.name && cleanArtist == track.artist { finish(nil); return }
                search(cleanName, cleanArtist, duration: track.duration) { r in finish(r) }
            }
        }
    }

    private func search(_ name: String, _ artist: String, duration: Double, completion: @escaping (Record?) -> Void) {
        request("search", [("track_name", name), ("artist_name", artist)]) { data in
            guard let data, let records = try? JSONDecoder().decode([Record].self, from: data) else {
                completion(nil); return
            }
            func score(_ r: Record) -> Int {
                var s: Int
                if !(r.syncedLyrics ?? "").isEmpty { s = 100 }
                else if !(r.plainLyrics ?? "").isEmpty { s = 40 }
                else if r.instrumental == true { s = 30 }
                else { return -1 }
                if let d = r.duration, duration > 0 {
                    let diff = abs(d - duration)
                    if diff <= 2 { s += 50 } else if diff <= 5 { s += 25 } else if diff > 15 { s -= 60 }
                }
                return s
            }
            let best = records.map { ($0, score($0)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
            completion(best?.0)
        }
    }

    private func request(_ endpoint: String, _ params: [(String, String)], completion: @escaping (Data?) -> Void) {
        let query = params.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        guard let url = URL(string: "https://lrclib.net/api/\(endpoint)?\(query)") else { completion(nil); return }
        session.dataTask(with: url) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(code == 200 ? data : nil)
        }.resume()
    }

    // MARK: helpers

    private static func hasContent(_ r: Record) -> Bool {
        !(r.syncedLyrics ?? "").isEmpty || !(r.plainLyrics ?? "").isEmpty || r.instrumental == true
    }

    private static func state(synced: String?, plain: String?, instrumental: Bool) -> LyricsState? {
        if let synced, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { return .plain(lines) }
        }
        if instrumental { return .instrumental }
        return nil
    }

    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = timestampRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? s : t
    }

    private static func primaryArtist(_ s: String) -> String {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ",&"))
        var first = parts.first ?? s
        for sep in [" feat.", " feat ", " ft.", " ft ", " x ", " and ", " with "] {
            if let r = first.range(of: sep, options: .caseInsensitive) { first = String(first[..<r.lowerBound]) }
        }
        first = first.trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? s : first
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

// MARK: - Overlay window

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent view on top of the overlay: drag to move, right-click for the menu.
final class DragCatcherView: NSView {
    var menuProvider: (() -> NSMenu?)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

enum TextSize: Int, CaseIterable {
    case small = 0, medium = 1, large = 2

    var title: String { ["Small", "Medium", "Large"][rawValue] }
    var width: CGFloat { [520, 640, 800][rawValue] }
    var currentPt: CGFloat { [17, 22, 28][rawValue] }
    var adjacentPt: CGFloat { [12, 15, 18][rawValue] }
}

enum TextTheme: Int, CaseIterable {
    case light = 0, dark = 1

    var title: String { ["Light", "Dark"][rawValue] }
    /// Text fill colour.
    var base: NSColor { self == .light ? .white : .black }
    /// Opposite colour, used for the outline and the legibility glow.
    var contrast: NSColor { self == .light ? .black : .white }
}

@MainActor
final class OverlayController {
    let panel: OverlayPanel
    let catcher = DragCatcherView()

    private let container = NSView()
    private let effect = NSVisualEffectView()
    private let titleLabel = OverlayController.makeLabel(lines: 1)
    private let prevLabel = OverlayController.makeLabel(lines: 1)
    private let currentLabel = OverlayController.makeLabel(lines: 2)
    private let nextLabel = OverlayController.makeLabel(lines: 1)

    private let pad: CGFloat = 14
    private let gap: CGFloat = 6
    private var currentSlot = NSRect.zero

    private var titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var adjacentFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private var currentFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    private var texts = (title: "", prev: "", current: "", next: "")

    private static let autosaveName = "LyricsOverlayPanel"

    var size: TextSize {
        didSet { applySize() }
    }

    /// 0 = text only, 1 = full frosted HUD background. Text always stays fully opaque.
    var backgroundOpacity: CGFloat {
        didSet { applyOpacity() }
    }

    var theme: TextTheme {
        didSet { applyStyle() }
    }

    /// Draws every glyph with an outline in the opposite colour, so text reads on any background.
    var outline: Bool {
        didSet { applyStyle() }
    }

    var isVisible: Bool { panel.isVisible }

    init(size: TextSize, backgroundOpacity: CGFloat, theme: TextTheme, outline: Bool) {
        self.size = size
        self.backgroundOpacity = backgroundOpacity
        self.theme = theme
        self.outline = outline
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: size.width, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        // The background (effect view) and the text are siblings, so fading the background
        // leaves the lyrics fully opaque. The container keeps a practically invisible fill so
        // the panel stays draggable even at 0% (fully transparent pixels let clicks fall through).
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.004).cgColor
        panel.contentView = container
        effect.frame = container.bounds
        container.addSubview(effect)

        for v in [titleLabel, prevLabel, currentLabel, nextLabel] { container.addSubview(v) }
        container.addSubview(catcher)

        let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.autosaveName)") != nil
        panel.setFrameAutosaveName(Self.autosaveName)
        applySize()
        applyStyle()
        if !hadSavedFrame { resetPosition() }
    }

    private func applyStyle() {
        // Light text sits on the dark HUD glass; dark text on light frosted glass.
        panel.appearance = NSAppearance(named: theme == .light ? .darkAqua : .aqua)
        effect.material = theme == .light ? .hudWindow : .popover
        applyOpacity()
        renderTexts()
    }

    private func applyOpacity() {
        let a = min(max(backgroundOpacity, 0), 1)
        effect.alphaValue = a
        effect.isHidden = a < 0.01

        // With little or no background, a soft shadow keeps the text legible on any content.
        let textShadow: NSShadow? = {
            guard a < 0.6 else { return nil }
            let s = NSShadow()
            s.shadowColor = theme.contrast.withAlphaComponent(0.85)
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        for l in [titleLabel, prevLabel, currentLabel, nextLabel] { l.shadow = textShadow }

        panel.hasShadow = a >= 0.35      // a window drop shadow around invisible glass looks odd
        panel.invalidateShadow()
    }

    func setVisible(_ visible: Bool) {
        if visible, !panel.isVisible { panel.orderFrontRegardless() }
        else if !visible, panel.isVisible { panel.orderOut(nil) }
    }

    func setClickThrough(_ on: Bool) { panel.ignoresMouseEvents = on }

    func setTitle(_ s: String) {
        texts.title = s
        renderTexts()
    }

    func setLines(prev: String, current: String, next: String, animated: Bool) {
        texts.prev = prev
        texts.current = current
        texts.next = next
        renderTexts()
        guard animated else { currentLabel.alphaValue = 1; return }
        currentLabel.alphaValue = 0.2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.currentLabel.animator().alphaValue = 1
        }
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.minY + 60))
    }

    // MARK: layout

    private func applySize() {
        adjacentFont = NSFont.systemFont(ofSize: size.adjacentPt, weight: .regular)
        currentFont = NSFont.systemFont(ofSize: size.currentPt, weight: .semibold)

        let w = size.width
        let inner = w - 2 * pad
        let titleH = Self.height(of: titleFont, lines: 1)
        let smallH = Self.height(of: adjacentFont, lines: 1)
        let bigH = Self.height(of: currentFont, lines: 2)
        let h = pad + titleH + gap + smallH + gap + bigH + gap + smallH + pad

        // Keep the panel's center fixed when resizing.
        let old = panel.frame
        let center = NSPoint(x: old.midX, y: old.midY)
        panel.setFrame(NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), display: true)

        var y = h - pad - titleH
        titleLabel.frame = NSRect(x: pad, y: y, width: inner, height: titleH)
        y -= gap + smallH
        prevLabel.frame = NSRect(x: pad, y: y, width: inner, height: smallH)
        y -= gap + bigH
        currentSlot = NSRect(x: pad, y: y, width: inner, height: bigH)
        y -= gap + smallH
        nextLabel.frame = NSRect(x: pad, y: y, width: inner, height: smallH)

        currentLabel.preferredMaxLayoutWidth = inner
        catcher.frame = NSRect(x: 0, y: 0, width: w, height: h)
        renderTexts()
    }

    // MARK: text styling

    private func renderTexts() {
        let dim: CGFloat = outline ? 0.85 : 0.62     // outlined text stays legible at higher opacity
        titleLabel.attributedStringValue = styled(texts.title, font: titleFont, alpha: outline ? 0.75 : 0.5, wraps: false)
        prevLabel.attributedStringValue = styled(texts.prev, font: adjacentFont, alpha: dim, wraps: false)
        currentLabel.attributedStringValue = styled(texts.current, font: currentFont, alpha: 1, wraps: true)
        nextLabel.attributedStringValue = styled(texts.next, font: adjacentFont, alpha: dim, wraps: false)
        layoutCurrent()
    }

    private func styled(_ s: String, font: NSFont, alpha: CGFloat, wraps: Bool) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.base.withAlphaComponent(alpha),
            .paragraphStyle: para,
        ]
        if outline {
            attrs[.strokeColor] = theme.contrast.withAlphaComponent(0.9)
            attrs[.strokeWidth] = -3.0   // negative = fill and stroke; value is % of the point size
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    /// Vertically center the (1- or 2-line) current lyric inside its slot.
    private func layoutCurrent() {
        let fit = currentLabel.sizeThatFits(NSSize(width: currentSlot.width, height: .greatestFiniteMagnitude))
        let h = min(ceil(fit.height), currentSlot.height)
        currentLabel.frame = NSRect(x: currentSlot.minX,
                                    y: currentSlot.minY + (currentSlot.height - h) / 2,
                                    width: currentSlot.width, height: h)
    }

    private static func makeLabel(lines: Int) -> NSTextField {
        let l = lines > 1 ? NSTextField(wrappingLabelWithString: "") : NSTextField(labelWithString: "")
        l.alignment = .center
        l.maximumNumberOfLines = lines
        l.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        l.cell?.truncatesLastVisibleLine = true
        l.isSelectable = false
        return l
    }

    private static func height(of font: NSFont, lines: Int) -> CGFloat {
        let probe = NSTextField(labelWithString: Array(repeating: "Ag", count: lines).joined(separator: "\n"))
        probe.font = font
        return ceil(probe.fittingSize.height)
    }
}

// MARK: - App

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // NSApplication.delegate is weak: without this strong reference the optimizer may free the
    // delegate right after assignment, so applicationDidFinishLaunching never runs.
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }

    private let bridge = MusicBridge()
    private let provider = LyricsProvider()
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!

    private var snapshot = PlayerSnapshot(state: .notRunning)
    private var currentTrack: Track?
    private var lyrics: LyricsState = .idle
    private var basePosition: Double = 0
    private var baseTime: CFTimeInterval = 0
    private var generation = 0          // bumps whenever lyrics/track/state change → forces a redraw
    private var lastRenderKey = ""

    // MARK: settings

    private let defaults = UserDefaults.standard
    private enum Key {
        static let show = "showOverlay", clickThrough = "clickThrough", hidePaused = "hideWhenPaused"
        static let hideFront = "hideWhenMusicFront", offset = "timingOffset", size = "textSize"
        static let opacity = "backgroundOpacity"
        static let theme = "textTheme", outline = "textOutline"
    }
    private var showOverlay: Bool {
        get { defaults.bool(forKey: Key.show) } set { defaults.set(newValue, forKey: Key.show) }
    }
    private var clickThrough: Bool {
        get { defaults.bool(forKey: Key.clickThrough) } set { defaults.set(newValue, forKey: Key.clickThrough) }
    }
    private var hideWhenPaused: Bool {
        get { defaults.bool(forKey: Key.hidePaused) } set { defaults.set(newValue, forKey: Key.hidePaused) }
    }
    private var hideWhenMusicFront: Bool {
        get { defaults.bool(forKey: Key.hideFront) } set { defaults.set(newValue, forKey: Key.hideFront) }
    }
    /// Added to the playback position before looking up the line. Positive = lyrics appear earlier.
    private var offset: Double {
        get { defaults.double(forKey: Key.offset) } set { defaults.set(newValue, forKey: Key.offset) }
    }
    private var backgroundOpacity: Double {
        get { defaults.double(forKey: Key.opacity) } set { defaults.set(newValue, forKey: Key.opacity) }
    }
    private weak var opacityValueLabel: NSTextField?
    private var textTheme: TextTheme {
        get { TextTheme(rawValue: defaults.integer(forKey: Key.theme)) ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Key.theme) }
    }
    private var textOutline: Bool {
        get { defaults.bool(forKey: Key.outline) } set { defaults.set(newValue, forKey: Key.outline) }
    }
    private var textSize: TextSize {
        get { TextSize(rawValue: defaults.integer(forKey: Key.size)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.size) }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Key.show: true, Key.clickThrough: false, Key.hidePaused: true,
            Key.hideFront: true, Key.offset: 0.0, Key.size: TextSize.medium.rawValue,
            Key.opacity: 1.0, Key.theme: TextTheme.light.rawValue, Key.outline: false,
        ])

        overlay = OverlayController(size: textSize, backgroundOpacity: CGFloat(backgroundOpacity),
                                    theme: textTheme, outline: textOutline)
        overlay.setClickThrough(clickThrough)
        overlay.catcher.menuProvider = { [weak self] in
            guard let self else { return nil }
            let m = NSMenu()
            self.populate(m)
            return m
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "Lyrics Overlay")
            img?.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(musicNotification(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(workspaceChanged(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(workspaceChanged(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        let pollTimer = Timer(timeInterval: 0.5, target: self, selector: #selector(pollTick),
                              userInfo: nil, repeats: true)
        pollTimer.tolerance = 0.1
        RunLoop.main.add(pollTimer, forMode: .common)

        let renderTimer = Timer(timeInterval: 0.05, target: self, selector: #selector(renderTick),
                                userInfo: nil, repeats: true)
        renderTimer.tolerance = 0.01
        RunLoop.main.add(renderTimer, forMode: .common)

        poll()
    }

    // MARK: polling

    @objc private func pollTick() { poll() }
    @objc private func renderTick() { render() }
    @objc private func musicNotification(_ n: Notification) { poll() }
    @objc private func workspaceChanged(_ n: Notification) { poll() }

    private func poll() {
        guard let snap = bridge.poll() else { return }
        if snap.state != snapshot.state { generation += 1 }
        snapshot = snap

        if let p = snap.position {
            basePosition = p
            baseTime = CACurrentMediaTime()
        }

        switch snap.state {
        case .notRunning, .stopped:
            if currentTrack != nil { currentTrack = nil; lyrics = .idle; generation += 1 }
        default:
            if let t = snap.track, t != currentTrack { trackChanged(t, bypassCache: false) }
        }

        updateVisibility()
        render()
    }

    private func trackChanged(_ t: Track, bypassCache: Bool) {
        currentTrack = t
        lyrics = .loading
        generation += 1
        provider.fetch(t, bypassCache: bypassCache) { [weak self] result in
            guard let self, self.currentTrack?.cacheKey == t.cacheKey else { return }
            self.lyrics = result
            self.generation += 1
            self.render()
        }
    }

    private var position: Double {
        snapshot.state == .playing ? basePosition + (CACurrentMediaTime() - baseTime) : basePosition
    }

    // MARK: visibility + rendering

    private func updateVisibility() {
        var visible = showOverlay
        switch snapshot.state {
        case .notRunning, .stopped: visible = false
        case .paused: if hideWhenPaused { visible = false }
        case .playing, .unauthorized: break
        }
        if hideWhenMusicFront, snapshot.state != .unauthorized,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MusicBridge.bundleID {
            visible = false
        }
        overlay.setVisible(visible)
    }

    private func render() {
        guard overlay.isVisible else { return }

        if snapshot.state == .unauthorized {
            let key = "unauth"
            guard key != lastRenderKey else { return }
            lastRenderKey = key
            overlay.setTitle("LyricsOverlay needs permission to read Music")
            overlay.setLines(prev: "System Settings › Privacy & Security › Automation",
                             current: "Allow LyricsOverlay → Music",
                             next: "then relaunch LyricsOverlay", animated: false)
            return
        }

        var title = ""
        if let t = currentTrack { title = t.artist.isEmpty ? t.name : "\(t.name) — \(t.artist)" }

        var prev = "", cur = "", next = "", idx = 0, animated = false
        switch lyrics {
        case .idle, .loading:
            cur = "Loading lyrics…"
        case .notFound:
            cur = "No lyrics found"
        case .instrumental:
            cur = "♪  Instrumental  ♪"
        case .synced(let lines):
            idx = Self.lineIndex(lines, at: position + offset)
            animated = true
            if idx < 0 {
                cur = "♪"
                next = Self.display(lines[0].text)
            } else {
                prev = idx > 0 ? Self.display(lines[idx - 1].text) : ""
                cur = Self.display(lines[idx].text)
                next = idx + 1 < lines.count ? Self.display(lines[idx + 1].text) : ""
            }
        case .plain(let lines):
            // No timestamps available: estimate the line from progress through the song.
            let dur = currentTrack?.duration ?? 0
            let frac = dur > 0 ? min(max(position / dur, 0), 0.9999) : 0
            idx = Int(frac * Double(lines.count))
            animated = true
            prev = idx > 0 ? lines[idx - 1] : ""
            cur = lines[idx]
            next = idx + 1 < lines.count ? lines[idx + 1] : ""
            title += "  ·  unsynced (estimated)"
        }

        let key = "\(generation)|\(idx)"
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        overlay.setTitle(title)
        overlay.setLines(prev: prev, current: cur, next: next, animated: animated)
    }

    private static func display(_ s: String) -> String { s.isEmpty ? "♪" : s }

    /// Index of the last line whose timestamp is <= t, or -1 if t precedes the first line.
    private static func lineIndex(_ lines: [LyricLine], at t: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        if let t = currentTrack {
            let header = NSMenuItem(title: t.artist.isEmpty ? t.name : "\(t.name) — \(t.artist)",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        menu.addItem(item("Show Lyrics Overlay", #selector(toggleShow), on: showOverlay))
        menu.addItem(item("Click-Through (Lock Position)", #selector(toggleClickThrough), on: clickThrough))
        menu.addItem(item("Hide When Paused", #selector(toggleHidePaused), on: hideWhenPaused))
        menu.addItem(item("Hide While Music Is in Front", #selector(toggleHideFront), on: hideWhenMusicFront))
        menu.addItem(.separator())

        let offsetInfo = NSMenuItem(title: String(format: "Timing Offset: %+.2f s", offset), action: nil, keyEquivalent: "")
        offsetInfo.isEnabled = false
        menu.addItem(offsetInfo)
        menu.addItem(item("Show Lyrics Earlier (+0.25 s)", #selector(offsetEarlier)))
        menu.addItem(item("Show Lyrics Later (−0.25 s)", #selector(offsetLater)))
        menu.addItem(item("Reset Timing", #selector(offsetReset)))
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for s in TextSize.allCases {
            let i = item(s.title, #selector(setSize(_:)), on: s == textSize)
            i.tag = s.rawValue
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        let opacityItem = NSMenuItem()
        opacityItem.view = makeOpacityControl()
        menu.addItem(opacityItem)

        let themeItem = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for t in TextTheme.allCases {
            let i = item(t.title, #selector(setTheme(_:)), on: t == textTheme)
            i.tag = t.rawValue
            themeMenu.addItem(i)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        menu.addItem(item("High-Contrast Outline", #selector(toggleOutline), on: textOutline))
        menu.addItem(item("Reset Overlay Position", #selector(resetPosition)))
        menu.addItem(item("Reload Lyrics", #selector(reloadLyrics)))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit LyricsOverlay", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    private func settingsChanged() {
        generation += 1
        updateVisibility()
        render()
    }

    @objc private func toggleShow() { showOverlay.toggle(); settingsChanged() }
    @objc private func toggleHidePaused() { hideWhenPaused.toggle(); settingsChanged() }
    @objc private func toggleHideFront() { hideWhenMusicFront.toggle(); settingsChanged() }
    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        overlay.setClickThrough(clickThrough)
    }
    @objc private func offsetEarlier() { offset += 0.25; settingsChanged() }
    @objc private func offsetLater() { offset -= 0.25; settingsChanged() }
    @objc private func offsetReset() { offset = 0; settingsChanged() }
    /// "Background Opacity" label + live slider, embedded directly in the menu.
    private func makeOpacityControl() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 46))

        let title = NSTextField(labelWithString: "Background Opacity")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 20, y: 24, width: 150, height: 18)

        let value = NSTextField(labelWithString: Self.percent(backgroundOpacity))
        value.font = .menuFont(ofSize: 0)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: 170, y: 24, width: 64, height: 18)
        opacityValueLabel = value

        let slider = NSSlider(value: backgroundOpacity, minValue: 0, maxValue: 1,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 20, y: 4, width: 214, height: 18)

        for v in [title, value, slider] { view.addSubview(v) }
        return view
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    @objc private func opacityChanged(_ sender: NSSlider) {
        backgroundOpacity = sender.doubleValue
        overlay.backgroundOpacity = CGFloat(sender.doubleValue)
        opacityValueLabel?.stringValue = Self.percent(sender.doubleValue)
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let t = TextTheme(rawValue: sender.tag) else { return }
        textTheme = t
        overlay.theme = t
    }

    @objc private func toggleOutline() {
        textOutline.toggle()
        overlay.outline = textOutline
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let s = TextSize(rawValue: sender.tag) else { return }
        textSize = s
        overlay.size = s
        settingsChanged()
    }
    @objc private func resetPosition() { overlay.resetPosition() }
    @objc private func reloadLyrics() {
        if let t = currentTrack { trackChanged(t, bypassCache: true); render() }
    }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
                + "\n\nTip: run bash build.sh install so the app lives in ~/Applications, then try again."
            alert.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
