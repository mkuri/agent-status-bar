import AppKit

// MARK: - State directory (contract location)

let stateDirURL: URL = {
    let env = ProcessInfo.processInfo.environment
    if let xdg = env["XDG_STATE_HOME"], !xdg.isEmpty {
        return URL(fileURLWithPath: xdg).appendingPathComponent("claude-sessions")
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/claude-sessions")
}()

// MARK: - Bar rendering (composed template image, monochrome)

enum BarRenderer {
    static let glyphs: [SessionState: String] = [
        .running: "play.fill",
        .permission: "hand.raised.fill",
        .idle: "checkmark.circle",
    ]

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// Draws glyph+count segments in black into a single image and marks it
    /// as a template, so the menu bar tints it (white on dark, black on
    /// light) automatically. Blink is a per-segment alpha dip: template
    /// rendering derives shape from the alpha channel, so 0.25-alpha
    /// drawing shows as dimmed.
    static func image(for segments: [BarSegment], blinkOn: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let height: CGFloat = 18
        let gap: CGFloat = 7
        let innerGap: CGFloat = 2

        var items: [(glyph: NSImage, count: NSAttributedString, alpha: CGFloat)] = []
        if segments.isEmpty {
            if let g = symbol("terminal") {
                items.append((g, NSAttributedString(), 0.35))
            }
        } else {
            for seg in segments {
                guard let g = symbol(glyphs[seg.state]!) else { continue }
                let alpha: CGFloat = (seg.blinking && !blinkOn) ? 0.25 : 1.0
                let count = NSAttributedString(
                    string: "\(seg.count)",
                    attributes: [.font: font, .foregroundColor: NSColor.black])
                items.append((g, count, alpha))
            }
        }

        var width: CGFloat = 0
        for item in items {
            width += item.glyph.size.width
            if item.count.length > 0 { width += innerGap + item.count.size().width }
            width += gap
        }
        width = max(width - gap, 1)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                let glyphY = (height - item.glyph.size.height) / 2
                item.glyph.draw(at: NSPoint(x: x, y: glyphY), from: .zero,
                                operation: .sourceOver, fraction: item.alpha)
                x += item.glyph.size.width
                if item.count.length > 0 {
                    x += innerGap
                    let faded = NSMutableAttributedString(attributedString: item.count)
                    faded.addAttribute(
                        .foregroundColor,
                        value: NSColor.black.withAlphaComponent(item.alpha),
                        range: NSRange(location: 0, length: faded.length))
                    let size = faded.size()
                    faded.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                    x += size.width
                }
                x += gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Controller

final class StatusController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = StateModel()
    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var lastOutput = DisplayOutput(segments: [], rows: [], soundsToPlay: [])

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // .common mode keeps both timers firing while the dropdown menu is
        // open (menu tracking runs the run loop outside .default mode).
        let poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        let blink = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.lastOutput.segments.contains(where: \.blinking) else { return }
            self.blinkOn.toggle()
            self.render()
        }
        RunLoop.main.add(blink, forMode: .common)
        blinkTimer = blink
        watchDirectory()
        refresh()
    }

    /// The directory may not exist until the producer first writes; the
    /// 5 s poll retries the watch until it attaches.
    private func watchDirectory() {
        dirSource?.cancel()
        dirSource = nil
        let fd = open(stateDirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func loadSnapshots() -> [SessionSnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDirURL, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(SessionSnapshot.decode) }
    }

    private func refresh() {
        if dirSource == nil { watchDirectory() }
        let config = Config.load()
        let now = Date()

        let all = loadSnapshots()
        let livePIDs = Set(all.map(\.pid).filter(ProcessProbe.isAlive))
        let (live, staleIDs) = StateModel.splitStale(all, livePIDs: livePIDs, now: now)
        for id in staleIDs {
            try? FileManager.default.removeItem(
                at: stateDirURL.appendingPathComponent("\(id).json"))
        }

        var activePIDs: Set<Int32> = []
        if config.activityDetection, live.contains(where: { $0.state == .permission }) {
            let cpu = ProcessProbe.treeCPU(roots: Set(live.map(\.pid)),
                                           entries: ProcessProbe.samplePS())
            activePIDs = Set(cpu.filter { $0.value >= config.activityCpuThresholdPct }
                                .map(\.key))
        }

        let out = model.evaluate(live, activePIDs: activePIDs, now: now, config: config)
        for name in out.soundsToPlay { NSSound(named: name)?.play() }
        lastOutput = out
        if !out.segments.contains(where: \.blinking) { blinkOn = true }
        render()
        rebuildMenu()
    }

    private func render() {
        statusItem.button?.image = BarRenderer.image(for: lastOutput.segments,
                                                     blinkOn: blinkOn)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        for row in lastOutput.rows {
            let suffix = row.overThreshold ? "  !" : ""
            let item = NSMenuItem(title: "\(row.name)  \(formatElapsed(row.elapsed))\(suffix)",
                                  action: nil, keyEquivalent: "")
            item.image = BarRenderer.symbol(BarRenderer.glyphs[row.state]!)
            menu.addItem(item)
        }
        if lastOutput.rows.isEmpty {
            menu.addItem(NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = StatusController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
