// The test suite. Run it with ./test, which compiles it against the app's own
// sources and points XDG_CONFIG_HOME at a scratch directory.
//
// Everything here is a pure function or a file round trip: no displayplacer, no
// m1ddc, no window. That is not a limitation so much as the point -- the parsers
// and the layout builder are where this project's bugs have actually been, and
// they need neither a monitor nor a person to exercise.

import Foundation

var failures = 0
var checks = 0

func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        failures += 1
        let d = detail()
        print("  FAIL  \(what)" + (d.isEmpty ? "" : "\n        \(d)"))
    }
}

func equal<T: Equatable>(_ what: String, _ got: T, _ want: T) {
    check(what, got == want, "got \(got)\n        want \(want)")
}

func section(_ name: String) { print("\(name)") }

// MARK: - Modes

section("Mode")
equal("extended parses", Mode(config: "extended"), .extended)
equal("mirrored parses", Mode(config: "mirrored"), .mirrored)
// The original names, which may still be sitting in someone's Shortcut.
equal("legacy 'mac' is extended", Mode(config: "mac"), .extended)
equal("legacy 'work' is mirrored", Mode(config: "work"), .mirrored)
equal("unknown falls back to mirrored", Mode(config: "banana"), .mirrored)
// The strict one, for output that has to be trusted.
check("exactly() takes a real mode", Mode(exactly: " Extended\n") == .extended)
check("exactly() rejects an error message", Mode(exactly: "screen-switch: no config") == nil)
check("exactly() rejects a legacy alias", Mode(exactly: "work") == nil)

// MARK: - Device names

section("Devices")
let messy = [Device(code: "16", label: "Home|Work", mode: .extended),
             Device(code: "17", label: "Kitchen\nTV", mode: .mirrored)]
try! Devices.save(messy)
let reloaded = Devices.load()
// The bug this is here for: '|' is the field separator, so "Home|Work" used to
// come back as *Home* in mirrored mode -- 'work' being the legacy alias -- and
// a newline dropped the machine entirely.
equal("a name with a pipe keeps its machine", reloaded.count, 2)
equal("...and its mode", reloaded.map(\.mode), [.extended, .mirrored])
equal("...with the pipe replaced", reloaded.first?.label, "Home/Work")
equal("a name with a newline is flattened", reloaded.last?.label, "Kitchen TV")
equal("clean() trims", Device.clean(label: "  spaced  "), "spaced")

// MARK: - Suggested input names

section("Input names")
equal("the standard table names HDMI 1",
      InputNames.label(for: "17", monitor: "DELL U2718Q"), "HDMI 1")
equal("...and DisplayPort 2, which is this Mac's port here",
      InputNames.label(for: "16", monitor: "DELL U2718Q"), "DisplayPort 2")
equal("whitespace around a code is still a code",
      InputNames.label(for: " 27\n", monitor: nil), "USB-C")
// The brand that ships a second numbering. m1ddc calls it `set input-alt`.
equal("LG's own numbering is read for an LG",
      InputNames.label(for: "208", monitor: "LG HDR 4K"), "DisplayPort 1")
equal("...including under its EDID id, which is what a panel with no marketing "
      + "name reports",
      InputNames.label(for: "144", monitor: "GSM 27GN950"), "HDMI 1")
equal("an LG that answers a standard code still gets the standard name",
      InputNames.label(for: "17", monitor: "LG HDR 4K"), "HDMI 1")
// The guess is per brand, so a Dell answering 208 is a Dell nobody has a table
// for -- and no name is better than a made-up one.
check("the LG table is not applied to everyone",
      InputNames.label(for: "208", monitor: "DELL U2718Q") == nil)
check("a model name containing the letters is not the brand",
      InputNames.label(for: "208", monitor: "BenQ PDLG1") == nil)
check("an unknown code has no name", InputNames.label(for: "99", monitor: nil) == nil)
check("nor does something that is not a code",
      InputNames.label(for: "HDMI", monitor: nil) == nil)

// What the picker leaves in the field is a list entry, and what devices.conf
// holds is a number. code(from:) is the one place that difference is resolved.
equal("a picked entry is just its code", InputNames.code(from: "17 — HDMI 1"), "17")
equal("a typed code survives untouched", InputNames.code(from: " 208 "), "208")
equal("something that is not a code comes back for the field to reject",
      InputNames.code(from: "HDMI 1"), "HDMI 1")
equal("a picked entry names itself", InputNames.label(for: "17 — HDMI 1", monitor: nil), "HDMI 1")

equal("the list is the connectors in use today",
      InputNames.choices(monitor: "DELL U2718Q").map(\.code), ["15", "16", "17", "18", "27"])
equal("an LG is offered its own numbering first, then the standard one",
      InputNames.choices(monitor: "LG HDR 4K").map(\.code),
      ["144", "145", "208", "209", "210", "15", "16", "17", "18", "27"])
// A list entry that named itself differently from the field beside it would be
// the one bug this cannot be allowed to have.
for monitor in ["DELL U2718Q", "LG HDR 4K"] {
    let bad = InputNames.choices(monitor: monitor)
        .filter { InputNames.label(for: $0.code, monitor: monitor) != $0.name }
    check("every offer agrees with the name it gets back (\(monitor))", bad.isEmpty,
          "disagreed: \(bad)")
}

// MARK: - The bash subset

section("BashConfig")
let sample = """
# a comment
DISPLAYPLACER="/opt/homebrew/bin/displayplacer"
THIS_MAC_INPUT="${THIS_MAC_INPUT:-16}"
POLL_INTERVAL=5
FOLLOW_MONITOR=1
EXTENDED_LAYOUT=(
  "id:AAAA res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"
  "id:BBBB res:3840x2160 hz:60 color_depth:8 enabled:true scaling:off origin:(1728,0) degree:0"
)
BLOCKED_INPUTS=()
TRAILING=value # with a comment
"""
let cfg = BashConfig(sample)
equal("quoted scalar", cfg.string("DISPLAYPLACER"), "/opt/homebrew/bin/displayplacer")
equal("${NAME:-default} yields the default", cfg.string("THIS_MAC_INPUT"), "16")
equal("numbers", cfg.double("POLL_INTERVAL"), 5)
equal("flags", cfg.bool("FOLLOW_MONITOR"), true)
equal("trailing comments are stripped", cfg.string("TRAILING"), "value")
equal("array length", cfg.array("EXTENDED_LAYOUT")?.count, 2)
// The trap: every layout string contains origin:(0,0), so "find the closing
// paren" has to mean the first *unquoted* one.
check("origin:(0,0) survives the array parser",
      cfg.array("EXTENDED_LAYOUT")?.first?.hasSuffix("origin:(0,0) degree:0") == true,
      "got \(cfg.array("EXTENDED_LAYOUT")?.first ?? "nil")")
equal("empty array", cfg.array("BLOCKED_INPUTS")?.count, 0)

// MARK: - Config round trip

section("Config round trip")
var written = Config()
written.displayplacer = "/opt/homebrew/bin/displayplacer"
written.m1ddc = "/opt/homebrew/bin/m1ddc"
written.mainDisplayID = "AAAA-1111"
written.sharedDisplayID = "BBBB-2222"
written.extendedLayout = ["id:AAAA res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"]
written.mirrorCandidates = ["id:AAAA+BBBB res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"]
written.thisMacInput = "16"
written.otherInput = "17"
written.blockedInputs = ["15"]
written.followMonitor = false
written.tryInputSwitchBack = false
written.pollInterval = 10
try! written.save()
let read = Config.load()
equal("display ids", [read.mainDisplayID, read.sharedDisplayID], ["AAAA-1111", "BBBB-2222"])
equal("layout", read.extendedLayout, written.extendedLayout)
equal("mirror candidates", read.mirrorCandidates, written.mirrorCandidates)
equal("input codes", [read.thisMacInput, read.otherInput], ["16", "17"])
equal("blocked inputs", read.blockedInputs, ["15"])
// An automatic DDC display is written out as the shared monitor -- the shell tool
// has no fallback of its own -- and has to read back as automatic, or Settings
// would show an explicit choice nobody made.
equal("automatic DDC display stays automatic", read.ddcDisplay, "")
equal("automatic still aims at the shared monitor", read.ddcTarget, "BBBB-2222")

var aimed = written
aimed.ddcDisplay = "CCCC-3333"
try! aimed.save()
equal("an explicit DDC display survives", Config.load().ddcDisplay, "CCCC-3333")
try! written.save()
equal("flags survive being false", [read.followMonitor, read.tryInputSwitchBack], [false, false])
equal("poll interval", read.pollInterval, 10)

section("Config migration from the old key names")
let old = """
BUILTIN_ID="AAAA-1111"
EXTERNAL_ID="BBBB-2222"
MAC_INPUT="16"
WORK_INPUT="17"
FORBIDDEN_INPUTS=(
  "15"
)
MAC_LAYOUT=(
  "id:${BUILTIN_ID} res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"
)
"""
try! old.write(to: Paths.configFile, atomically: true, encoding: .utf8)
let migrated = Config.load()
equal("BUILTIN_ID -> mainDisplayID", migrated.mainDisplayID, "AAAA-1111")
equal("EXTERNAL_ID -> sharedDisplayID", migrated.sharedDisplayID, "BBBB-2222")
equal("MAC_INPUT -> thisMacInput", migrated.thisMacInput, "16")
equal("FORBIDDEN_INPUTS -> blockedInputs", migrated.blockedInputs, ["15"])
check("${BUILTIN_ID} in a layout is expanded",
      migrated.extendedLayout.first?.hasPrefix("id:AAAA-1111 ") == true,
      "got \(migrated.extendedLayout.first ?? "nil")")

// MARK: - Display modes

section("DisplayMode")
let mode = DisplayMode(spec: "  mode 12: res:1728x1117 hz:120 color_depth:8 scaling:on <-- current mode")
equal("resolution", mode?.resolution, "1728x1117")
equal("refresh rate", mode?.hz, 120)
equal("scaling", mode?.scaling, true)
check("a line without res: is not a mode", DisplayMode(spec: "Type: MacBook built in screen") == nil)
equal("spec fragment round trips",
      DisplayMode(spec: mode!.specFragment)?.specFragment, mode?.specFragment)

// MARK: - displayplacer output

section("parseDisplayplacer")
let dpOutput = """
Persistent screen id: AAAA-1111
Contextual screen id: 1
Type: MacBook built in screen
Resolution: 1728x1117
Hertz: 120
Origin: (0,0) - main display
Rotation: 0
Enabled: true
  mode 0: res:1728x1117 hz:120 color_depth:8 scaling:on <-- current mode
  mode 1: res:1512x982 hz:120 color_depth:8 scaling:on

Persistent screen id: BBBB-2222
Contextual screen id: 2
Type: 27 inch external screen
Resolution: 3840x2160
Hertz: 60
Origin: (1728,0)
Rotation: 0
Enabled: true
  mode 0: res:3840x2160 hz:60 color_depth:8 scaling:off <-- current mode

Execute the command below to set your screens to the current arrangement:

displayplacer "id:AAAA-1111 res:1728x1117 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" "id:BBBB-2222 res:3840x2160 hz:60 color_depth:8 enabled:true scaling:off origin:(1728,0) degree:0"
"""
let (displays, arrangement) = DisplayScanner.parseDisplayplacer(dpOutput)
equal("two displays", displays.count, 2)
equal("ids", displays.map(\.persistentID), ["AAAA-1111", "BBBB-2222"])
equal("the built-in is recognised by its Type line", displays.first?.isBuiltin, true)
equal("the external one is not", displays.last?.isBuiltin, false)
equal("current mode is the marked one", displays.first?.current?.hz, 120)
equal("modes are collected", displays.first?.modes.count, 2)
// The bottom line of `list` is the capture payload, and it has to come back as
// separate arguments rather than one string.
equal("arrangement is split into arguments", arrangement.count, 2)
check("arrangement keeps origin:(0,0)",
      arrangement.first?.hasSuffix("origin:(0,0) degree:0") == true)
equal("Origin's ' - main display' suffix is trimmed off the value",
      displays.first?.kind, "MacBook built in screen")

// MARK: - m1ddc output

section("parseM1ddc")
let ddc = DisplayScanner.parseM1ddc("""
[1] (null) (AAAA-1111)
[2] DELL U2718Q (BBBB-2222)
""")
equal("index and name", ddc["BBBB-2222"]?.index, 2)
equal("marketing name", ddc["BBBB-2222"]?.name, "DELL U2718Q")
equal("the built-in reports (null) for a name", ddc["AAAA-1111"]?.name, "(null)")

// MARK: - DDC failure text

section("ddcFailed")
// Anything but a number is a failure. m1ddc has more than one thing to say when
// it cannot reach a display, and a guard that lists the phrases it knows treats
// the rest as a good read -- which is how an early probe marched into a
// destructive input, and how the log ended up recording a whole sentence as an
// input code.
check("m1ddc's real failure string", ddcFailed("Could not find a suitable external display."))
check("the other failure string, which named no error",
      ddcFailed("The specified display does not exist. Use 'display list' to list "
              + "displays and use it's number (1, 2...) or its UUID to specify display!"))
check("empty is a failure", ddcFailed(""))
check("a plain reading is not", !ddcFailed("16"))
check("nor is one with whitespace around it", !ddcFailed(" 16\n"))
// A code nothing expects is still a reading -- the panel returned 32 mid-switch
// once -- so this guard must not double as a range check.
check("an unexpected code is still a reading", !ddcFailed("32"))

// MARK: - Mirror candidates

section("LayoutBuilder")
let panel = DisplayInfo(persistentID: "AAAA", kind: "MacBook built in screen", ddcName: nil,
                        systemName: nil, ddcIndex: nil, isBuiltin: true,
                        current: DisplayMode(spec: "res:1728x1117 hz:120 scaling:on"),
                        modes: [DisplayMode(spec: "res:1728x1117 hz:120 scaling:on")!,
                                DisplayMode(spec: "res:1728x1117 hz:60 scaling:on")!,
                                DisplayMode(spec: "res:1512x982 hz:120 scaling:on")!])
let candidates = LayoutBuilder.mirrorCandidates(
    main: "AAAA", shared: "BBBB", mode: panel.current!, from: panel)
// The entire trick: displayplacer only lets you choose the resolution of the
// first screen in a mirror set, so the Mac's own screen has to lead. Reversing
// this makes macOS inherit the monitor's resolution.
check("the Mac's screen is first in every candidate",
      candidates.allSatisfy { $0.hasPrefix("id:AAAA+BBBB ") },
      "got \(candidates)")
check("more than one candidate, since a mirror set can refuse a refresh rate",
      candidates.count > 1, "got \(candidates.count)")
equal("no duplicate resolution/rate pairs", candidates.count, Set(candidates).count)
equal("nothing to build without both ids",
      LayoutBuilder.mirrorCandidates(main: "", shared: "BBBB", mode: panel.current!, from: panel).count, 0)

// MARK: - The log

section("log trimming")
// Only reachable because Paths.logFile takes an override: NSHomeDirectory()
// ignores $HOME, so without one a test like this writes to the real log -- and
// the trim below then eats the real history. It did, once.
let logURL = Paths.logFile
check("the test log is the scratch one, not ~/Library/Logs",
      logURL.path.hasPrefix(NSHomeDirectory() + "/Library/Logs") == false,
      "got \(logURL.path)")
if logURL.path.hasPrefix(NSHomeDirectory() + "/Library/Logs") == false {
    try? FileManager.default.removeItem(at: logURL)
    let filler = String(repeating: "x", count: 200)
    for i in 0..<1600 { log("line \(i) \(filler)") }
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
    check("the file is held under the limit", text.utf8.count < 256 * 1024,
          "got \(text.utf8.count) bytes")
    check("the newest line survives", lines.last?.contains("line 1599") == true)
    check("no half line is left at the top",
          lines.first?.prefix(4).allSatisfy(\.isNumber) == true,
          "got \(lines.first ?? "nil")")
}

// MARK: - Result

print("")
if failures == 0 {
    print("\(checks) checks, all passed")
} else {
    print("\(checks) checks, \(failures) FAILED")
}
exit(failures == 0 ? 0 : 1)
