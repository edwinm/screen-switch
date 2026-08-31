// The Settings window.
//
// Built to the macOS Human Interface Guidelines, which shapes most of what is
// here: a non-resizable titled window with a preference-style toolbar, panes laid
// out in NSGridView with system fonts and colours only (so Dark Mode and Increase
// Contrast need no code), sheets rather than app-modal dialogs, and -- the rule
// that removes a whole button from the design -- changes that apply immediately
// instead of waiting behind Save/Cancel.

import AppKit

final class SettingsWindowController: NSWindowController {

    private unowned let app: AppDelegate
    private var config: Config
    private var devices: [Device]
    private var snapshot = DisplaySnapshot()

    private struct Pane {
        let id: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let view: NSView
    }
    private var panes: [Pane] = []

    // Controls we have to write back into when the model changes.
    private let mainDisplayPopup = NSPopUpButton()
    private let sharedDisplayPopup = NSPopUpButton()
    private let mirrorResPopup = NSPopUpButton()
    private let layoutSummary = NSTextField(labelWithString: "")
    private let followCheckbox = NSButton()
    private let switchBackCheckbox = NSButton()
    private let loginItemCheckbox = NSButton()
    private lazy var loginItemNote = secondary("")
    private let intervalPopup = NSPopUpButton()
    private let displayplacerField = NSTextField()
    private let m1ddcField = NSTextField()
    private let blockedField = NSTextField()
    private let ddcField = NSTextField()
    private let devicesTable = NSTableView()
    private let emptyLabel = NSTextField(
        labelWithString: "No machines yet — click + to add one.")

    // Sheet state, kept alive while the sheet is up.
    private var addSheet: NSWindow?
    private var sheetName: NSTextField?
    private var sheetCode: NSTextField?
    private var sheetMode: NSPopUpButton?

    init(app: AppDelegate) {
        self.app = app
        self.config = app.config
        self.devices = app.devices

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
            // No .resizable and no .miniaturizable: a settings window is sized by
            // its content, and is not a document.
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        snapshot = DisplayScanner.scan(config: config)
        buildPanes()
        seedDefaults()
        seedThisMac()
        buildToolbar()
        window.delegate = self
        window.setFrameAutosaveName("ScreenSwitchSettings")
        window.center()
        select(pane: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// First run should not be an empty form. Everything that can be worked out
    /// from what is attached is filled in, so all that is left is capturing the
    /// arrangement and naming the machines. Only empty fields are touched -- a
    /// config someone left half-finished on purpose stays that way.
    private func seedDefaults() {
        var changed = false
        if config.mainDisplayID.isEmpty, let main = snapshot.main {
            config.mainDisplayID = main.persistentID
            changed = true
        }
        if config.sharedDisplayID.isEmpty, let shared = snapshot.shared,
           shared.persistentID != config.mainDisplayID {
            config.sharedDisplayID = shared.persistentID
            changed = true
        }
        if config.mirrorCandidates.isEmpty,
           let main = snapshot.display(id: config.mainDisplayID),
           let mode = main.current ?? main.offeredModes.first {
            config.mirrorCandidates = LayoutBuilder.mirrorCandidates(
                main: config.mainDisplayID, shared: config.sharedDisplayID,
                mode: mode, from: main)
            changed = !config.mirrorCandidates.isEmpty
        }
        guard changed else { return }
        refreshControls()
        commitConfig()
    }

    /// The machine list cannot be detected: DDC reports which input is
    /// *selected* and nothing about the others, and sweeping input codes to see
    /// what answers is the one thing this project will not do -- on some panels
    /// a wrong code drops the Mac's link entirely. See AGENTS.md.
    ///
    /// One row is knowable, though: whoever the monitor is showing now, which on
    /// a first run is this Mac. Seeded only when the shared monitor is actually
    /// attached, and only into an empty list, so a machine list someone has
    /// already made is never touched.
    private func seedThisMac() {
        guard devices.isEmpty,
              !config.sharedDisplayID.isEmpty,
              snapshot.display(id: config.sharedDisplayID) != nil,
              let code = currentMonitorInput() else { return }
        devices = [Device(code: code, label: Device.clean(label: Self.thisMacName), mode: .extended)]
        config.thisMacInput = code
        reloadDevices()
        commitDevices()
        syncInputRoles()
        log("seeded the machine list with this Mac on input \(code)")
    }

    private static var thisMacName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "This Mac" : name
    }

    /// The live DDC reading, or nil if the monitor is not answering.
    private func currentMonitorInput() -> String? {
        let r = Shell.run(config.m1ddc, ["display", config.ddcTarget, "get", "input"])
        let value = (r.out.components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        return ddcFailed(value) ? nil : value
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        toolbar.selectedItemIdentifier = panes.first?.id
    }

    private func select(pane index: Int) {
        guard let window, panes.indices.contains(index) else { return }
        let pane = panes[index]
        window.title = pane.title

        // Grow or shrink the window to the pane, keeping the title bar where it
        // is rather than the bottom edge -- the standard macOS behaviour.
        let target = pane.view.fittingSize
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frame
        frame.size.width += target.width - content.width
        frame.size.height += target.height - content.height
        frame.origin.y -= target.height - content.height

        window.contentView = pane.view
        window.setFrame(frame, display: true, animate: window.isVisible)
        window.toolbar?.selectedItemIdentifier = pane.id
        window.initialFirstResponder = pane.view
    }

    // MARK: - Panes

    private func buildPanes() {
        panes = [
            Pane(id: .init("general"), title: "General", symbol: "gearshape",
                 view: wrap(generalPane())),
            Pane(id: .init("displays"), title: "Displays", symbol: "display.2",
                 view: wrap(displaysPane())),
            Pane(id: .init("devices"), title: "Devices", symbol: "list.bullet",
                 view: wrap(devicesPane())),
            Pane(id: .init("advanced"), title: "Advanced", symbol: "wrench.and.screwdriver",
                 view: wrap(advancedPane())),
        ]
        refreshControls()
    }

    /// 20 pt margins on every side, the standard macOS window inset.
    private func wrap(_ content: NSView) -> NSView {
        let box = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 20),
            box.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 20),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
        return box
    }

    private func generalPane() -> NSView {
        followCheckbox.setButtonType(.switch)
        followCheckbox.title = "Follow the monitor automatically"
        followCheckbox.target = self
        followCheckbox.action = #selector(followChanged)

        switchBackCheckbox.setButtonType(.switch)
        switchBackCheckbox.title = "Switch the monitor back to this Mac"
        switchBackCheckbox.target = self
        switchBackCheckbox.action = #selector(switchBackChanged)

        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        for s in [2, 3, 5, 10, 30] {
            intervalPopup.addItem(withTitle: "\(s) seconds")
            intervalPopup.lastItem?.tag = s
        }

        loginItemCheckbox.setButtonType(.switch)
        loginItemCheckbox.title = "Start Screen Switch at login"
        loginItemCheckbox.target = self
        loginItemCheckbox.action = #selector(loginItemChanged)

        // Two lines of secondary text, the second only when there is something
        // to say, so it is built by hand rather than with stack(help:).
        let loginItem = NSStackView(views: [
            loginItemCheckbox,
            secondary("Screen Switch is listed in System Settings › General › Login Items, where it can also be turned off."),
            loginItemNote,
        ])
        loginItem.orientation = .vertical
        loginItem.alignment = .leading
        loginItem.spacing = 4

        let grid = NSGridView(views: [
            [label("When the input changes:"),
             stack(followCheckbox,
                   help: "The Mac applies the layout that belongs to whichever machine the monitor is showing. It only reacts to a change, so mirroring by hand is never undone behind your back.")],
            [label("Check the monitor every:"), stack(intervalPopup, help: nil)],
            [label("Returning to this Mac:"),
             stack(switchBackCheckbox,
                   help: "Also pull the monitor’s input back over DDC. Whether that works depends on the monitor: some keep answering while showing another machine, some do not.")],
            [label("At login:"), loginItem],
        ])
        style(grid)
        return grid
    }

    private func displaysPane() -> NSView {
        mainDisplayPopup.target = self
        mainDisplayPopup.action = #selector(mainDisplayChanged)
        sharedDisplayPopup.target = self
        sharedDisplayPopup.action = #selector(sharedDisplayChanged)
        mirrorResPopup.target = self
        mirrorResPopup.action = #selector(mirrorResChanged)

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshDisplays))
        refresh.bezelStyle = .rounded

        let capture = NSButton(title: "Capture Current Arrangement",
                               target: self, action: #selector(captureLayout))
        capture.bezelStyle = .rounded

        layoutSummary.font = .systemFont(ofSize: NSFont.systemFontSize)
        layoutSummary.lineBreakMode = .byTruncatingTail

        let captureStack = NSStackView(views: [layoutSummary, capture])
        captureStack.orientation = .vertical
        captureStack.alignment = .leading
        captureStack.spacing = 6

        let grid = NSGridView(views: [
            [label("Mac display:"),
             stack(mainDisplayPopup,
                   help: "The screen that is still yours when the monitor goes to another machine. Its resolution is the one mirroring uses.")],
            [label("Shared monitor:"),
             stack(sharedDisplayPopup,
                   help: "The monitor that moves between machines.")],
            [NSGridCell.emptyContentView, refresh],
            [label("Extended layout:"),
             stack(captureStack,
                   help: "Arrange your screens in System Settings the way you want them, then capture. This is what gets restored when the monitor comes back.")],
            [label("Mirrored resolution:"),
             stack(mirrorResPopup,
                   help: "What both screens show while the monitor is on another machine.")],
        ])
        style(grid)
        return grid
    }

    private func devicesPane() -> NSView {
        devicesTable.dataSource = self
        devicesTable.delegate = self
        devicesTable.usesAlternatingRowBackgroundColors = true
        devicesTable.rowSizeStyle = .default
        devicesTable.allowsMultipleSelection = false
        devicesTable.style = .inset

        func column(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            return c
        }
        devicesTable.addTableColumn(column("label", "Name", width: 200))
        devicesTable.addTableColumn(column("code", "Input", width: 60))
        devicesTable.addTableColumn(column("mode", "Displays", width: 120))
        devicesTable.addTableColumn(column("thisMac", "This Mac", width: 70))
        devicesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = devicesTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // An empty list should say what to do, not just sit there. The label
        // goes in a container over the scroll view rather than inside it -- a
        // subview of an NSScrollView scrolls with the content and lands under
        // the header.
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let listBox = NSView()
        listBox.translatesAutoresizingMaskIntoConstraints = false
        listBox.addSubview(scroll)
        listBox.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            listBox.heightAnchor.constraint(equalToConstant: 150),
            listBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            scroll.topAnchor.constraint(equalTo: listBox.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listBox.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listBox.centerYAnchor, constant: 10),
        ])

        // The +/- segmented control under a list is the standard macOS idiom for
        // this; a pair of push buttons is not.
        let addRemove = NSSegmentedControl(
            images: [NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Device")!,
                     NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Device")!],
            trackingMode: .momentary, target: self, action: #selector(addOrRemoveDevice(_:)))
        addRemove.segmentStyle = .smallSquare
        addRemove.setWidth(32, forSegment: 0)
        addRemove.setWidth(32, forSegment: 1)
        addRemove.setToolTip("Add a machine", forSegment: 0)
        addRemove.setToolTip("Remove the selected machine", forSegment: 1)

        // Detection can honestly fill in exactly one machine: whichever one the
        // monitor is showing right now. That is this Mac if the user is looking
        // at it, which is why the button says so rather than saying "scan".
        let addThisMac = NSButton(title: "Add This Mac", target: self,
                                  action: #selector(addThisMacDevice))
        addThisMac.bezelStyle = .rounded
        addThisMac.controlSize = .small
        addThisMac.toolTip = "Read the input the monitor is showing now"

        let controls = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        addThisMac.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(addRemove)
        controls.addSubview(addThisMac)
        NSLayoutConstraint.activate([
            controls.heightAnchor.constraint(equalTo: addThisMac.heightAnchor),
            addRemove.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            addRemove.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            addThisMac.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            addThisMac.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])

        let stack = NSStackView(views: [
            listBox, controls,
            secondary("Every machine that shares the monitor, in menu order. "
                    + "Click a name or an input code to change it. “This Mac” marks "
                    + "the one you are sitting at, and “Add This Mac” reads the input "
                    + "the monitor is on right now."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Only now do the two share an ancestor, which a cross-view constraint
        // needs: the row of buttons spans the list it belongs to.
        controls.widthAnchor.constraint(equalTo: listBox.widthAnchor).isActive = true
        return stack
    }

    private func advancedPane() -> NSView {
        for field in [displayplacerField, m1ddcField, blockedField, ddcField] {
            field.delegate = self
            field.isEditable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        displayplacerField.placeholderString = "/opt/homebrew/bin/displayplacer"
        m1ddcField.placeholderString = "/opt/homebrew/bin/m1ddc"
        blockedField.placeholderString = "none"
        ddcField.placeholderString = "the shared monitor"

        let chooseDP = NSButton(title: "Choose…", target: self, action: #selector(chooseDisplayplacer))
        let chooseDDC = NSButton(title: "Choose…", target: self, action: #selector(chooseM1ddc))
        let reveal = NSButton(title: "Reveal Config in Finder",
                              target: self, action: #selector(revealConfig))
        for b in [chooseDP, chooseDDC, reveal] { b.bezelStyle = .rounded }

        func pathRow(_ field: NSTextField, _ button: NSButton) -> NSStackView {
            let s = NSStackView(views: [field, button])
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }

        let grid = NSGridView(views: [
            [label("displayplacer:"), pathRow(displayplacerField, chooseDP)],
            [label("m1ddc:"), pathRow(m1ddcField, chooseDDC)],
            [label("DDC display:"),
             stack(ddcField,
                   help: "Which display m1ddc talks to — a screen id, or an index from “m1ddc display list”. Leave it empty to use the shared monitor, which is almost always what you want.")],
            [label("Never select inputs:"),
             stack(blockedField,
                   help: "Comma-separated input codes to refuse, whatever asks for them. Some monitors drop the link to the Mac when a particular input is chosen — the picture and the DDC channel go together, and only the monitor’s own buttons bring them back. If yours has one, list it here.")],
            [NSGridCell.emptyContentView, reveal],
        ])
        style(grid)
        return grid
    }

    // MARK: - Small layout helpers

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.alignment = .right
        return f
    }

    private func secondary(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.isSelectable = false
        f.preferredMaxLayoutWidth = 340
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    private func stack(_ control: NSView, help: String?) -> NSView {
        guard let help else { return control }
        let s = NSStackView(views: [control, secondary(help)])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func style(_ grid: NSGridView) {
        grid.columnSpacing = 10
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .top }
    }

    // MARK: - Model -> controls

    private func refreshControls() {
        followCheckbox.state = config.followMonitor ? .on : .off
        switchBackCheckbox.state = config.tryInputSwitchBack ? .on : .off
        intervalPopup.selectItem(withTag: Int(config.pollInterval))
        if intervalPopup.selectedItem == nil { intervalPopup.selectItem(at: 2) }

        fill(mainDisplayPopup, selecting: config.mainDisplayID)
        fill(sharedDisplayPopup, selecting: config.sharedDisplayID)
        fillMirrorResolutions()
        refreshLoginItem()

        layoutSummary.stringValue = layoutDescription()
        displayplacerField.stringValue = config.displayplacer
        m1ddcField.stringValue = config.m1ddc
        blockedField.stringValue = config.blockedInputs.joined(separator: ", ")
        ddcField.stringValue = config.ddcDisplay
        reloadDevices()
    }

    private func reloadDevices() {
        devicesTable.reloadData()
        emptyLabel.isHidden = !devices.isEmpty
    }

    private func fill(_ popup: NSPopUpButton, selecting id: String) {
        popup.removeAllItems()
        for d in snapshot.displays {
            popup.addItem(withTitle: d.menuLabel)
            popup.lastItem?.representedObject = d.persistentID
            popup.lastItem?.toolTip = d.persistentID
        }
        if snapshot.displays.isEmpty {
            popup.addItem(withTitle: "No displays detected")
            popup.isEnabled = false
            return
        }
        popup.isEnabled = true
        if id.isEmpty {
            // Never let the popup imply a choice the config has not made.
            popup.insertItem(withTitle: "Select a display", at: 0)
            popup.selectItem(at: 0)
            return
        }
        // An id from the config that is not attached right now must still show,
        // or opening Settings on the road would silently change the setup.
        if !id.isEmpty, !snapshot.displays.contains(where: { $0.persistentID == id }) {
            popup.addItem(withTitle: "\(id) (not connected)")
            popup.lastItem?.representedObject = id
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == id }) {
            popup.select(item)
        }
    }

    private func fillMirrorResolutions() {
        mirrorResPopup.removeAllItems()
        guard let main = snapshot.display(id: config.mainDisplayID) else {
            mirrorResPopup.addItem(withTitle: "Pick a Mac display first")
            mirrorResPopup.isEnabled = false
            return
        }
        mirrorResPopup.isEnabled = true
        for m in main.offeredModes {
            mirrorResPopup.addItem(withTitle: m.label)
            mirrorResPopup.lastItem?.representedObject = m
        }
        let wanted = config.mirrorMode ?? main.current
        if let wanted, let item = mirrorResPopup.itemArray.first(where: {
            ($0.representedObject as? DisplayMode).map {
                $0.resolution == wanted.resolution && $0.hz == wanted.hz
            } ?? false
        }) {
            mirrorResPopup.select(item)
        }
    }

    private func layoutDescription() -> String {
        guard !config.extendedLayout.isEmpty else { return "Not captured yet" }
        let modes = config.extendedLayout.compactMap(DisplayMode.init(spec:))
        let biggest = modes.max { $0.pixels < $1.pixels }
        let count = config.extendedLayout.count
        let screens = count == 1 ? "1 screen" : "\(count) screens"
        guard let biggest else { return screens }
        return "\(screens), largest \(biggest.label)"
    }

    /// The toggle also lives in System Settings, so the checkbox is read from
    /// SMAppService rather than remembered. refreshControls() runs on
    /// windowDidBecomeKey, which is enough to catch a change made over there.
    private func refreshLoginItem() {
        let status = LoginItem.status
        loginItemCheckbox.state = status == .enabled ? .on : .off
        loginItemCheckbox.isEnabled = LoginItem.isAvailable

        let note: String
        if !LoginItem.isAvailable {
            note = "Only available when running from Screen Switch.app."
        } else if LoginItem.legacyAgentInstalled {
            // No shell commands in the UI: the other entry can be switched off
            // in System Settings, which is where the user already is.
            note = "Another copy of Screen Switch is also set to start at login, listed as “ScreenSwitch”. Switch that one off in System Settings › General › Login Items."
        } else if status == .requiresApproval {
            note = "Switched off in System Settings › General › Login Items. Turn it back on there."
        } else {
            note = ""
        }
        loginItemNote.stringValue = note
        loginItemNote.isHidden = note.isEmpty
    }

    // MARK: - Persisting
    //
    // No Save button: the HIG asks settings to take effect as they are changed,
    // so every action lands here and the running app picks it up at once.

    private func commitConfig() {
        do {
            try config.save()
            app.reloadConfig()
            app.rebuildMenu()
        } catch {
            present(error: "Could not save your settings.",
                    detail: "\(Paths.configFile.path)\n\n\(error.localizedDescription)")
        }
    }

    private func commitDevices() {
        do {
            try Devices.save(devices)
            app.reloadConfig()
            app.rebuildMenu()
        } catch {
            present(error: "Could not save the machine list.",
                    detail: "\(Paths.devicesFile.path)\n\n\(error.localizedDescription)")
        }
    }

    private func present(error message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Both mirror candidates and the DDC index follow from the chosen displays,
    /// so they are regenerated rather than asked for.
    private func regenerateDerivedValues() {
        let main = snapshot.display(id: config.mainDisplayID)
        let mode = (mirrorResPopup.selectedItem?.representedObject as? DisplayMode)
            ?? config.mirrorMode ?? main?.current
        if let mode {
            config.mirrorCandidates = LayoutBuilder.mirrorCandidates(
                main: config.mainDisplayID, shared: config.sharedDisplayID,
                mode: mode, from: main)
        }
        ddcField.stringValue = config.ddcDisplay
    }

    // MARK: - Actions

    @objc private func followChanged() {
        config.followMonitor = followCheckbox.state == .on
        commitConfig()
    }

    @objc private func switchBackChanged() {
        config.tryInputSwitchBack = switchBackCheckbox.state == .on
        commitConfig()
    }

    @objc private func loginItemChanged() {
        let wanted = loginItemCheckbox.state == .on
        do {
            try LoginItem.set(wanted)
        } catch {
            loginItemCheckbox.state = wanted ? .off : .on
            present(error: wanted ? "Screen Switch could not be set to open at login."
                                  : "Screen Switch could not be removed from login items.",
                    detail: error.localizedDescription)
            return
        }
        // register() reports success even when the user has the item switched
        // off in System Settings; only the status afterwards tells the truth.
        if wanted, LoginItem.status == .requiresApproval { askForApproval() }
        refreshLoginItem()
    }

    /// A real failure -- the registration did not take -- and the fix is in
    /// System Settings, so it gets an alert with a verb button that goes there.
    private func askForApproval() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Switch is switched off in Login Items."
        alert.informativeText =
            "It will not open at login until it is turned back on in System Settings › General › Login Items."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Not Now")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { LoginItem.openSystemSettings() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(alert.runModal()) }
    }

    @objc private func intervalChanged() {
        config.pollInterval = Double(intervalPopup.selectedTag())
        commitConfig()
    }

    @objc private func mainDisplayChanged() {
        config.mainDisplayID = mainDisplayPopup.selectedItem?.representedObject as? String ?? ""
        fillMirrorResolutions()
        regenerateDerivedValues()
        commitConfig()
    }

    @objc private func sharedDisplayChanged() {
        config.sharedDisplayID = sharedDisplayPopup.selectedItem?.representedObject as? String ?? ""
        regenerateDerivedValues()
        commitConfig()
    }

    @objc private func mirrorResChanged() {
        regenerateDerivedValues()
        commitConfig()
    }

    @objc private func refreshDisplays() {
        snapshot = DisplayScanner.scan(config: config)
        refreshControls()
        if !snapshot.toolsMissing.isEmpty {
            present(error: "\(snapshot.toolsMissing.joined(separator: " and ")) could not be run.",
                    detail: "Install them with:\n\nbrew install displayplacer m1ddc\n\n"
                          + "If they are somewhere unusual, set the paths in Advanced.")
        }
    }

    @objc private func captureLayout() {
        snapshot = DisplayScanner.scan(config: config)
        let arrangement = snapshot.currentArrangement
        guard !arrangement.isEmpty else {
            present(error: "Could not read the current arrangement.",
                    detail: "displayplacer did not print one. Check its path in Advanced.")
            return
        }
        // Capturing while mirrored would store the mirrored set as the layout to
        // return to, which is exactly backwards.
        if arrangement.contains(where: { $0.contains("+") }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Your screens are mirrored right now."
            alert.informativeText = "The extended layout is the arrangement to come back "
                + "to, so capture it while the screens are showing separate desktops. "
                + "Turn mirroring off in System Settings, then capture."
            alert.addButton(withTitle: "Capture Anyway")
            alert.addButton(withTitle: "Cancel")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.store(arrangement: arrangement)
            }
            return
        }
        store(arrangement: arrangement)
    }

    private func store(arrangement: [String]) {
        config.extendedLayout = arrangement
        layoutSummary.stringValue = layoutDescription()
        commitConfig()
        log("settings: captured extended layout (\(arrangement.count) screens)")
    }

    @objc private func chooseDisplayplacer() { chooseTool(into: displayplacerField) }
    @objc private func chooseM1ddc() { chooseTool(into: m1ddcField) }

    private func chooseTool(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            field.stringValue = url.path
            self.readToolPaths()
        }
    }

    @objc private func revealConfig() {
        try? FileManager.default.createDirectory(
            at: Paths.configDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { commitConfig() }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile])
    }

    private func readToolPaths() {
        let dp = displayplacerField.stringValue.trimmingCharacters(in: .whitespaces)
        let dd = m1ddcField.stringValue.trimmingCharacters(in: .whitespaces)
        if !dp.isEmpty { config.displayplacer = dp }
        if !dd.isEmpty { config.m1ddc = dd }
        commitConfig()
        refreshDisplays()
    }

    // MARK: - Devices

    @objc private func addOrRemoveDevice(_ sender: NSSegmentedControl) {
        // A momentary control reports -1 when no segment is pressed. Treat that
        // as "nothing asked for" rather than letting it fall through to Remove.
        switch sender.selectedSegment {
        case 0: beginAddDevice()
        case 1: removeSelectedDevice()
        default: break
        }
    }

    func removeSelectedDevice() {
        let row = devicesTable.selectedRow
        guard devices.indices.contains(row), let window else { return }
        let device = devices[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(device.label)” from the menu?"
        alert.informativeText = "The monitor keeps input \(device.code); only this entry goes away."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.devices.remove(at: row)
            self.reloadDevices()
            self.commitDevices()
        }
    }

    /// A sheet, not an app-modal dialog: it belongs to this window and blocks
    /// nothing else.
    func beginAddDevice() {
        guard let window else { return }

        let name = NSTextField(string: "")
        name.placeholderString = "Work laptop"
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let code = NSTextField(string: "")
        code.placeholderString = "17"
        code.translatesAutoresizingMaskIntoConstraints = false
        code.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // The reason nobody has to probe their monitor: switch it over with its
        // own buttons, then click, and the live DDC value is read back.
        let useCurrent = NSButton(title: "Use Monitor’s Current Input",
                                  target: self, action: #selector(useCurrentInput))
        useCurrent.bezelStyle = .rounded

        let mode = NSPopUpButton()
        for m in Mode.allCases {
            mode.addItem(withTitle: m.displayName)
            mode.lastItem?.representedObject = m.rawValue
        }
        mode.selectItem(at: 1)

        let codeRow = NSStackView(views: [code, useCurrent])
        codeRow.orientation = .horizontal
        codeRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Name:"), name],
            [label("Input code:"),
             stack(codeRow,
                   help: "Switch the monitor to that machine with its own buttons, then click — the code is read from the monitor. Some monitors drop the link to the Mac when certain inputs are chosen; if that happens, the monitor’s buttons bring it back.")],
            [label("Displays:"),
             stack(mode,
                   help: "“Extended” restores your captured arrangement — that is this Mac. “Mirrored” puts everything on your own screen, for a machine that takes the monitor away.")],
        ])
        style(grid)

        let add = NSButton(title: "Add", target: self, action: #selector(confirmAddDevice))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"                     // Return commits
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAddDevice))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"              // Escape cancels

        let buttons = NSStackView(views: [NSView(), cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let content = NSStackView(views: [grid, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20).isActive = true
        buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20).isActive = true

        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
        sheet.initialFirstResponder = name

        sheetName = name
        sheetCode = code
        sheetMode = mode
        addSheet = sheet
        window.beginSheet(sheet)
    }

    @objc private func useCurrentInput() {
        guard let value = currentMonitorInput() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The monitor is not answering."
            alert.informativeText = "m1ddc could not read that display. "
                + "Check the monitor is on and connected, and that the shared monitor in "
                + "Displays is the right one."
            alert.addButton(withTitle: "OK")
            if let sheet = addSheet { alert.beginSheetModal(for: sheet) } else { alert.runModal() }
            return
        }
        sheetCode?.stringValue = value
    }

    /// Same reading as the Add sheet's button, straight into a row. An input
    /// already in the list is marked as this Mac rather than added twice.
    @objc private func addThisMacDevice() {
        guard let code = currentMonitorInput() else {
            present(error: "The monitor is not answering.",
                    detail: "m1ddc could not read that display. Check the monitor is on and "
                          + "connected, and that the shared monitor in Displays is the right one.")
            return
        }
        if let existing = devices.firstIndex(where: { $0.code == code }) {
            devices[existing].mode = .extended
        } else {
            devices.append(Device(code: code, label: Device.clean(label: Self.thisMacName),
                                  mode: .extended))
        }
        config.thisMacInput = code
        reloadDevices()
        commitDevices()
        syncInputRoles()
        if let row = devices.firstIndex(where: { $0.code == code }) {
            devicesTable.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    @objc private func cancelAddDevice() { endAddSheet() }

    @objc private func confirmAddDevice() {
        let code = (sheetCode?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let name = (sheetName?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard let number = Int(code), (0...255).contains(number) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That input code is not valid."
            alert.informativeText = "Input codes are whole numbers from 0 to 255. Use "
                + "“Use Monitor’s Current Input” to read yours."
            alert.addButton(withTitle: "OK")
            if let sheet = addSheet { alert.beginSheetModal(for: sheet) } else { alert.runModal() }
            return
        }
        let mode = Mode(config: sheetMode?.selectedItem?.representedObject as? String ?? "mirrored")
        let label = Device.clean(label: name)
        devices.append(Device(code: code, label: label.isEmpty ? "Input \(code)" : label, mode: mode))
        reloadDevices()
        commitDevices()
        // Both roles, not just THIS_MAC_INPUT: OTHER_INPUT is what
        // `screen-switch toggle` reaches for, and it was being left empty.
        syncInputRoles()
        endAddSheet()
    }

    private func endAddSheet() {
        guard let window, let sheet = addSheet else { return }
        window.endSheet(sheet)
        addSheet = nil
        sheetName = nil
        sheetCode = nil
        sheetMode = nil
    }

    @objc private func deviceLabelEdited(_ sender: NSTextField) {
        guard devices.indices.contains(sender.tag) else { return }
        let cleaned = Device.clean(label: sender.stringValue)
        // Show what was stored: silently keeping a name the file cannot hold is
        // how the mode used to change behind the user's back.
        if cleaned != sender.stringValue { sender.stringValue = cleaned }
        guard !cleaned.isEmpty else {
            NSSound.beep()
            sender.stringValue = devices[sender.tag].label
            return
        }
        devices[sender.tag].label = cleaned
        commitDevices()
    }

    @objc private func deviceCodeEdited(_ sender: NSTextField) {
        guard devices.indices.contains(sender.tag) else { return }
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let number = Int(value), (0...255).contains(number) else {
            NSSound.beep()
            sender.stringValue = devices[sender.tag].code
            return
        }
        let was = devices[sender.tag].code
        devices[sender.tag].code = value
        if config.thisMacInput == was { config.thisMacInput = value; commitConfig() }
        if config.otherInput == was { config.otherInput = value; commitConfig() }
        commitDevices()
    }

    @objc private func deviceModeChanged(_ sender: NSPopUpButton) {
        guard devices.indices.contains(sender.tag) else { return }
        devices[sender.tag].mode = Mode(
            config: sender.selectedItem?.representedObject as? String ?? "mirrored")
        commitDevices()
        syncInputRoles()
    }

    /// "This Mac" behaves like a radio group: exactly one machine is this one.
    @objc private func thisMacChanged(_ sender: NSButton) {
        guard devices.indices.contains(sender.tag) else { return }
        config.thisMacInput = devices[sender.tag].code
        devices[sender.tag].mode = .extended
        reloadDevices()
        commitDevices()
        syncInputRoles()
    }

    /// THIS_MAC_INPUT and OTHER_INPUT are what `screen-switch toggle` uses, and
    /// they should never disagree with the machine list.
    private func syncInputRoles() {
        if config.thisMacInput.isEmpty || !devices.contains(where: { $0.code == config.thisMacInput }) {
            config.thisMacInput = devices.first(where: { $0.mode == .extended })?.code ?? ""
        }
        let other = devices.first { $0.mode == .mirrored && $0.code != config.thisMacInput }
        config.otherInput = other?.code ?? config.otherInput
        commitConfig()
    }
}

// MARK: - Toolbar delegate

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.id)
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.id)
    }
    func toolbarSelectableItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.id)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let index = panes.firstIndex(where: { $0.id == sender.itemIdentifier }) else { return }
        select(pane: index)
    }
}

// MARK: - Window delegate

extension SettingsWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        // This window holds its own copy of the config, taken when it was built.
        // Anything that changed it since -- the first-run seeding, a device
        // picked from the menu -- is on the app, so take those back before
        // redrawing, or the next commit here writes a stale copy over them.
        config = app.config
        devices = app.devices
        // Displays get plugged in while the window is open; pick them up rather
        // than making the user find Refresh.
        snapshot = DisplayScanner.scan(config: config)
        refreshControls()
    }
}

// MARK: - Text field commits

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case displayplacerField, m1ddcField:
            readToolPaths()
        case ddcField:
            config.ddcDisplay = field.stringValue.trimmingCharacters(in: .whitespaces)
            commitConfig()
        case blockedField:
            config.blockedInputs = field.stringValue
                .components(separatedBy: CharacterSet(charactersIn: ", "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && Int($0) != nil }
            field.stringValue = config.blockedInputs.joined(separator: ", ")
            commitConfig()
        default:
            break
        }
    }
}

// MARK: - Devices table

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, devices.indices.contains(row) else { return nil }
        let device = devices[row]

        switch column.identifier.rawValue {
        case "label", "code":
            let isLabel = column.identifier.rawValue == "label"
            let field = NSTextField(string: isLabel ? device.label : device.code)
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.tag = row
            field.target = self
            field.action = isLabel ? #selector(deviceLabelEdited(_:)) : #selector(deviceCodeEdited(_:))
            field.setAccessibilityLabel(isLabel ? "Name" : "Input code")
            return field

        case "mode":
            let popup = NSPopUpButton()
            popup.isBordered = false
            for m in Mode.allCases {
                popup.addItem(withTitle: m.displayName)
                popup.lastItem?.representedObject = m.rawValue
            }
            popup.selectItem(at: device.mode == .extended ? 0 : 1)
            popup.tag = row
            popup.target = self
            popup.action = #selector(deviceModeChanged(_:))
            popup.setAccessibilityLabel("Displays")
            return popup

        case "thisMac":
            let button = NSButton(checkboxWithTitle: "", target: self,
                                  action: #selector(thisMacChanged(_:)))
            button.state = device.code == config.thisMacInput ? .on : .off
            button.tag = row
            button.setAccessibilityLabel("This Mac")
            return button

        default:
            return nil
        }
    }
}
