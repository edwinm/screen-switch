// Reading and writing ~/.config/screen-switch/{config.sh,devices.conf}.
//
// config.sh stays a file bash can source, because `screen-switch` is the single
// source of truth for display work and must remain usable on its own. So this is
// a small bash-subset parser on one side and a generator on the other -- the
// Settings window rewrites the whole file rather than patching it.

import Foundation

// MARK: - Mode

enum Mode: String, CaseIterable {
    case extended
    case mirrored

    /// Exactly one of the two names, or nil. For output that has to be trusted
    /// -- `screen-switch status` -- where init(config:)'s permissive default
    /// would turn an error message into a confident "mirrored".
    init?(exactly raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "extended": self = .extended
        case "mirrored": self = .mirrored
        default: return nil
        }
    }

    /// 'mac' and 'work' were the original names and may still be in someone's
    /// devices.conf or Shortcut.
    init(config raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mac", "extended": self = .extended
        case "work", "mirrored": self = .mirrored
        default: self = .mirrored
        }
    }

    /// Title case, per the macOS HIG for anything shown in a control.
    var displayName: String {
        switch self {
        case .extended: return "Extended"
        case .mirrored: return "Mirrored"
        }
    }
}

struct Device: Equatable {
    var code: String
    var label: String
    var mode: Mode

    /// devices.conf is one machine per line, fields split on '|', so a name
    /// containing either character does not survive the round trip -- and it
    /// fails silently in the worst way: "Home|Work" reloads as *Home* in
    /// mirrored mode, because 'work' is the legacy alias for mirrored, and a
    /// name with a newline in it loses the machine altogether. Names are
    /// therefore cleaned where they are entered, not just where they are
    /// written, so what the list shows is what the file holds.
    static func clean(label: String) -> String {
        label
            .replacingOccurrences(of: "|", with: "/")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Input names

/// A guess at what a monitor calls one of its inputs, used for exactly one
/// thing: the name a machine gets when nobody has typed one.
///
/// MCCS assigns VCP 0x60 values to connectors, and plenty of monitors follow it
/// -- Dell is close to reliable about it -- but the exceptions are not rare
/// enough to build on. LG ships a second numbering entirely, up in the range
/// MCCS leaves undefined, which is why m1ddc has a `set input-alt` command at
/// all. Others advertise the standard values in their capabilities string and
/// then act on different ones.
///
/// So this never produces a *code*. Codes come from the monitor, by reading
/// VCP 0x60, and a wrong one can take the DDC channel down with the picture.
/// A wrong name costs a word that was editable anyway, which is the whole
/// reason the guess is allowed to live here and nowhere else.
enum InputNames {

    /// The MCCS table, as documented for `m1ddc set input`.
    private static let standard: [Int: String] = [
        1: "VGA 1", 2: "VGA 2",
        3: "DVI 1", 4: "DVI 2",
        5: "Composite 1", 6: "Composite 2",
        7: "S-Video 1", 8: "S-Video 2",
        9: "Tuner 1", 10: "Tuner 2", 11: "Tuner 3",
        12: "Component 1", 13: "Component 2", 14: "Component 3",
        15: "DisplayPort 1", 16: "DisplayPort 2",
        17: "HDMI 1", 18: "HDMI 2",
        27: "USB-C",
    ]

    /// LG's own numbering, the one `m1ddc set input-alt` documents. It does not
    /// collide with the standard table, so an LG that answers 17 still gets
    /// "HDMI 1" -- some of them do.
    private static let lgAlternate: [Int: String] = [
        144: "HDMI 1", 145: "HDMI 2",
        208: "DisplayPort 1", 209: "DisplayPort 2",
        210: "USB-C",
    ]

    /// `monitor` is the DDC display's marketing name, e.g. "DELL U2718Q". Only
    /// the brand is read out of it, and only LG changes the answer; everything
    /// else is guessed from the standard table, which is right more often than
    /// it is not. An unknown code gets nil -- no name is better than a made-up
    /// one.
    static func label(for code: String, monitor: String?) -> String? {
        guard let n = Int(self.code(from: code)) else { return nil }
        if isLG(monitor), let name = lgAlternate[n] { return name }
        return standard[n]
    }

    /// What to offer in the input picker: the connectors a machine plugged into
    /// a monitor today actually has. The naming tables stay longer than this on
    /// purpose -- a panel that answers 5 still gets "Composite 1" -- but nobody
    /// picking a machine off a list is reaching for composite video.
    ///
    /// An LG gets its own numbering first, because that is what an LG that needs
    /// this list at all is using; the standard codes follow, since some LGs
    /// answer those instead.
    static func choices(monitor: String?) -> [(code: String, name: String)] {
        let modern = [15, 16, 17, 18, 27]
        var out: [(code: String, name: String)] = []
        if isLG(monitor) {
            out += lgAlternate.keys.sorted().map { (String($0), lgAlternate[$0]!) }
        }
        out += modern.map { (String($0), standard[$0]!) }
        return out
    }

    /// The code out of a picked list entry ("17 - HDMI 1" is code 17), or out of
    /// something typed by hand. Anything that does not start with a number comes
    /// back trimmed and unchanged, so the field's own validation still gets to
    /// reject it and say so.
    static func code(from entry: String) -> String {
        let t = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = t.prefix { $0.isNumber }
        return digits.isEmpty ? t : String(digits)
    }

    /// First word only, so a model name that happens to contain the letters
    /// cannot pass for the brand. "GSM" is LG's EDID id, which is what shows up
    /// in place of a marketing name on panels that do not report one.
    private static func isLG(_ monitor: String?) -> Bool {
        let first = (monitor ?? "")
            .uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map(String.init) ?? ""
        return first == "LG" || first == "LGE" || first == "GSM"
    }
}

// MARK: - Locations

enum Paths {
    /// XDG rather than Application Support: this config is shared with shell
    /// scripts, and a path with a space in it is friction for every one of them.
    static var configDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("screen-switch")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/screen-switch")
    }

    static var configFile: URL { configDir.appendingPathComponent("config.sh") }
    static var devicesFile: URL { configDir.appendingPathComponent("devices.conf") }
    /// SCREEN_SWITCH_LOG redirects it. Note that NSHomeDirectory() ignores
    /// $HOME, so without an override of its own there is no way to point this
    /// somewhere scratch -- which is how a test of the log trimming came to
    /// overwrite a real log.
    static var logFile: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SCREEN_SWITCH_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/screen-switch.log")
    }

    /// Where `screen-switch` and `lib.sh` live. Nothing is hardcoded: the bundle
    /// normally sits in its own checkout, so its parent directory is the answer.
    /// SCREEN_SWITCH_DIR overrides for development; Resources/ is the fallback
    /// for a bundle that was copied out of the checkout.
    static var scriptDir: URL {
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let override = env["SCREEN_SWITCH_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let res = Bundle.main.resourceURL { candidates.append(res) }

        for dir in candidates {
            let script = dir.appendingPathComponent("screen-switch")
            if FileManager.default.isExecutableFile(atPath: script.path) { return dir }
        }
        return candidates.first ?? URL(fileURLWithPath: ".")
    }

    static var screenSwitch: String { scriptDir.appendingPathComponent("screen-switch").path }
}

// MARK: - Config

struct Config {
    var displayplacer = ""
    var m1ddc = ""
    var mainDisplayID = ""
    var sharedDisplayID = ""
    var extendedLayout: [String] = []
    var mirrorCandidates: [String] = []
    var ddcDisplay = ""
    var thisMacInput = ""
    var otherInput = ""
    var blockedInputs: [String] = []
    var tryInputSwitchBack = true
    var followMonitor = true
    var pollInterval = 5.0

    /// Enough to actually switch anything. The menu says so when this is false,
    /// and the Settings window opens by itself on first launch.
    var isConfigured: Bool {
        !mainDisplayID.isEmpty && !sharedDisplayID.isEmpty
            && !extendedLayout.isEmpty && !mirrorCandidates.isEmpty
    }

    /// What to hand m1ddc as its display argument.
    var ddcTarget: String { ddcDisplay.isEmpty ? sharedDisplayID : ddcDisplay }

    /// The mirror resolution is not stored separately -- it is whatever the first
    /// candidate says, which keeps one fact in one place.
    var mirrorMode: DisplayMode? {
        mirrorCandidates.first.flatMap(DisplayMode.init(spec:))
    }

    static func load() -> Config {
        var c = Config()
        c.displayplacer = Tools.find("displayplacer")
        c.m1ddc = Tools.find("m1ddc")

        guard let text = try? String(contentsOf: Paths.configFile, encoding: .utf8) else {
            return c
        }
        let v = BashConfig(text)

        if let s = v.string("DISPLAYPLACER"), !s.isEmpty { c.displayplacer = s }
        if let s = v.string("M1DDC"), !s.isEmpty { c.m1ddc = s }
        c.mainDisplayID = v.string("MAIN_DISPLAY_ID") ?? v.string("BUILTIN_ID") ?? ""
        c.sharedDisplayID = v.string("SHARED_DISPLAY_ID") ?? v.string("EXTERNAL_ID") ?? ""
        c.extendedLayout = v.array("EXTENDED_LAYOUT") ?? v.array("MAC_LAYOUT") ?? []
        c.mirrorCandidates = v.array("MIRROR_CANDIDATES") ?? []
        c.ddcDisplay = v.string("DDC_DISPLAY") ?? ""
        // The file always names a display outright, because the shell tool has no
        // notion of "whichever monitor is the shared one". In here, naming the
        // shared monitor *is* the default, so it reads back as empty -- otherwise
        // Settings could never show "Automatic" again after its first save.
        if c.ddcDisplay == c.sharedDisplayID { c.ddcDisplay = "" }
        c.thisMacInput = v.string("THIS_MAC_INPUT") ?? v.string("MAC_INPUT") ?? ""
        c.otherInput = v.string("OTHER_INPUT") ?? v.string("WORK_INPUT") ?? ""
        c.blockedInputs = v.array("BLOCKED_INPUTS") ?? v.array("FORBIDDEN_INPUTS") ?? []
        c.tryInputSwitchBack = v.bool("TRY_INPUT_SWITCH_BACK") ?? true
        c.followMonitor = v.bool("FOLLOW_MONITOR") ?? true
        c.pollInterval = v.double("POLL_INTERVAL") ?? 5.0

        // Substitute the ids back into layouts written with ${...} references, so
        // a hand-edited config still parses into something the app can display.
        c.extendedLayout = c.extendedLayout.map { c.expand($0) }
        c.mirrorCandidates = c.mirrorCandidates.map { c.expand($0) }
        return c
    }

    private func expand(_ s: String) -> String {
        var out = s
        for (name, value) in [("MAIN_DISPLAY_ID", mainDisplayID),
                              ("SHARED_DISPLAY_ID", sharedDisplayID),
                              ("BUILTIN_ID", mainDisplayID),
                              ("EXTERNAL_ID", sharedDisplayID)] {
            guard !value.isEmpty else { continue }
            out = out.replacingOccurrences(of: "${\(name)}", with: value)
            out = out.replacingOccurrences(of: "$\(name)", with: value)
        }
        return out
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Paths.configDir, withIntermediateDirectories: true)
        try render().write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }

    private func render() -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func arr(_ name: String, _ items: [String]) -> String {
            guard !items.isEmpty else { return "\(name)=()" }
            return "\(name)=(\n" + items.map { "  " + q($0) }.joined(separator: "\n") + "\n)"
        }

        return """
        # Screen Switch configuration.
        #
        # Written by the app's Settings... window, which rewrites this file whole
        # every time you change something there -- comments you add will not
        # survive. `screen-switch` sources it, so it stays valid bash.

        # --- Tools -----------------------------------------------------------
        # Absolute paths: launchd and Shortcuts run with a minimal PATH and will
        # not find Homebrew binaries on their own.
        DISPLAYPLACER=\(q(displayplacer))
        M1DDC=\(q(m1ddc))

        # --- Displays --------------------------------------------------------
        # Persistent screen ids from `displayplacer list`, stable per display.
        # MAIN is the screen that stays yours; SHARED is the monitor that moves
        # between machines.
        MAIN_DISPLAY_ID=\(q(mainDisplayID))
        SHARED_DISPLAY_ID=\(q(sharedDisplayID))

        # --- Extended mode ---------------------------------------------------
        # Your normal arrangement, captured from `displayplacer list`.
        \(arr("EXTENDED_LAYOUT", extendedLayout))

        # --- Mirrored mode ---------------------------------------------------
        # MAIN_DISPLAY_ID is listed FIRST on purpose: displayplacer only lets you
        # choose the resolution of the first screen in a mirror set, so the mode
        # that gets set is your own screen's and the monitor scales a copy nobody
        # is looking at. Reversing the order inherits the monitor's resolution.
        #
        # Tried in order; the first that applies cleanly wins.
        \(arr("MIRROR_CANDIDATES", mirrorCandidates))

        # --- Monitor input switching (DDC/CI) --------------------------------
        # Which display m1ddc talks to. A persistent screen id rather than the
        # index from `m1ddc display list`: m1ddc accepts either, and indices move
        # when you plug or unplug a display while an id never does.
        DDC_DISPLAY=\(q(ddcDisplay.isEmpty ? sharedDisplayID : ddcDisplay))

        # VCP 0x60 input codes. Monitors disagree about these, so they are read
        # from yours rather than guessed.
        THIS_MAC_INPUT="${THIS_MAC_INPUT:-\(thisMacInput)}"
        OTHER_INPUT="${OTHER_INPUT:-\(otherInput)}"

        # --- Safety ----------------------------------------------------------
        # Inputs that must never be selected. Some panels drop the link to the Mac
        # when a particular input is chosen -- the display and the DDC channel go
        # together, and only the monitor's own buttons bring them back.
        \(arr("BLOCKED_INPUTS", blockedInputs))

        # Coming back to extended mode, also pull the input back over DDC.
        TRY_INPUT_SWITCH_BACK=\(tryInputSwitchBack ? 1 : 0)

        # --- Menu bar app ----------------------------------------------------
        FOLLOW_MONITOR=\(followMonitor ? 1 : 0)
        POLL_INTERVAL=\(Int(pollInterval))

        """
    }
}

// MARK: - Devices

enum Devices {
    static func load() -> [Device] {
        guard let text = try? String(contentsOf: Paths.devicesFile, encoding: .utf8) else {
            return []
        }
        return text.components(separatedBy: .newlines).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            let f = l.components(separatedBy: "|")
            guard f.count >= 3 else { return nil }
            return Device(code: f[0].trimmingCharacters(in: .whitespaces),
                          label: f[1].trimmingCharacters(in: .whitespaces),
                          mode: Mode(config: f[2]))
        }
    }

    static func save(_ devices: [Device]) throws {
        try FileManager.default.createDirectory(
            at: Paths.configDir, withIntermediateDirectories: true)
        let body = devices
            .map { "\($0.code)|\(Device.clean(label: $0.label))|\($0.mode.rawValue)" }
            .joined(separator: "\n")
        let text = """
        # Machines that share the monitor, one per line, in menu order:
        #   <input code>|<name>|<mode>
        #
        # mode is 'extended' (restore your normal arrangement -- this Mac) or
        # 'mirrored' (mirror onto your own screen -- another machine has the
        # monitor). Written by the app's Settings... window.

        \(body)

        """
        try text.write(to: Paths.devicesFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Tools

enum Tools {
    /// Homebrew is at /opt/homebrew on Apple Silicon, but a custom prefix is
    /// allowed, so ask the shell before falling back to the usual places.
    static func find(_ name: String) -> String {
        let known = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for p in known where FileManager.default.isExecutableFile(atPath: p) { return p }
        let r = Shell.run("/usr/bin/env", ["which", name])
        if r.ok, !r.out.isEmpty { return r.out }
        return known[0]
    }
}

// MARK: - Bash config parsing

/// Understands exactly the subset the generator emits: `KEY=value`,
/// `KEY="value"`, `KEY="${KEY:-value}"` and multi-line `KEY=( "a" "b" )`.
struct BashConfig {
    private var scalars: [String: String] = [:]
    private var arrays: [String: [String]] = [:]

    init(_ text: String) {
        var lines = text.components(separatedBy: .newlines)[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var rhs = String(line[line.index(after: eq)...])

            if rhs.hasPrefix("(") {
                // Arrays may be one line or many; collect until the closing paren.
                // It has to be an *unquoted* paren: every layout string contains
                // an origin:(0,0), and a naive contains(")") stops on that.
                var body = String(rhs.dropFirst())
                while BashConfig.unquotedClose(body) == nil, let next = lines.first {
                    lines = lines.dropFirst()
                    body += "\n" + next
                }
                if let close = BashConfig.unquotedClose(body) {
                    body = String(body[body.startIndex..<close])
                }
                arrays[key] = BashConfig.words(body)
            } else {
                rhs = BashConfig.stripComment(rhs).trimmingCharacters(in: .whitespaces)
                scalars[key] = BashConfig.unquote(rhs)
            }
        }
    }

    // Only strips a trailing comment that starts outside quotes -- layout strings
    // contain parentheses and colons, and must survive intact.
    private static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        for (i, ch) in zip(s.indices, s) {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble {
                return String(s[s.startIndex..<i])
            }
        }
        return s
    }

    /// Index of the first ')' that is not inside quotes, if any.
    fileprivate static func unquotedClose(_ s: String) -> String.Index? {
        var quote: Character? = nil
        for (i, ch) in zip(s.indices, s) {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ")" {
                return i
            }
        }
        return nil
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2)
            || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
        }
        // "${NAME:-default}" -- the default is the value we want.
        if v.hasPrefix("${"), v.hasSuffix("}"), let sep = v.range(of: ":-") {
            v = String(v[sep.upperBound..<v.index(before: v.endIndex)])
        }
        return v.replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Splits an array body into quoted or bare words, keeping spaces inside
    /// quotes (every layout string has them).
    private static func words(_ rawBody: String) -> [String] {
        let body = rawBody.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        var started = false
        for ch in body {
            if let q = quote {
                if ch == q { quote = nil; out.append(current); current = ""; started = false }
                else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started && !current.isEmpty { out.append(current) }
                current = ""; started = false
            } else {
                current.append(ch); started = true
            }
        }
        if started && !current.isEmpty { out.append(current) }
        return out.filter { !$0.isEmpty }
    }

    func string(_ key: String) -> String? { scalars[key] }
    func array(_ key: String) -> [String]? { arrays[key] }
    func int(_ key: String) -> Int? { scalars[key].flatMap { Int($0) } }
    func double(_ key: String) -> Double? { scalars[key].flatMap { Double($0) } }
    func bool(_ key: String) -> Bool? {
        guard let v = scalars[key]?.lowercased() else { return nil }
        return v == "1" || v == "true" || v == "yes"
    }
}
