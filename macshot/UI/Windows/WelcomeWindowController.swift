import AppKit
import UniformTypeIdentifiers

/// Shown at launch when nothing else is opening (Markclip Phase 1 identity —
/// see ROADMAP.md): a Recent Projects list, "Open Video…"/"Record Screen…"
/// buttons, and drag-and-drop of a video file. Reopened from the Dock icon
/// (`applicationShouldHandleReopen`) whenever no other window is visible.
///
/// Visually matches the video editor (`VideoEditorStyle`) — a dark, quiet
/// surface — rather than the light system-default window chrome.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    /// Video extensions this app's editor can open — kept in sync with
    /// `AppDelegate.handleOpenURLs` and the Info.plist `CFBundleDocumentTypes`.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    var onOpenVideo: (() -> Void)?
    var onRecordScreen: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private var tableView: NSTableView!
    private var emptyLabel: NSTextField!
    private var recents: [URL] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = BuildVariant.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VideoEditorStyle.window
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        let restoredFrame = window.setFrameAutosaveName("markclip.welcome")
        if !restoredFrame { window.center() }
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the window, refreshing the recents list first (files opened,
    /// deleted or renamed since it was last shown should be reflected).
    func show() {
        reloadRecents()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window = window else { return }
        let root = WelcomeDropView()
        root.wantsLayer = true
        root.layer?.backgroundColor = VideoEditorStyle.window.cgColor
        root.onDropFile = { [weak self] url in self?.onOpenURL?(url) }
        window.contentView = root

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = VideoEditorStyle.label(BuildVariant.displayName, size: 22, weight: .semibold)
        // Not routed through the L(...) lookup helper — this is new-to-this-window copy, and
        // LocalizationTests requires every L() key to exist (translated) in
        // all 40 shipped locales. Reusing an existing key would misdescribe
        // this window (e.g. "Recent Captures" implies screenshots), so this
        // one stays English-only for now, matching other un-translated
        // literals already in AppDelegate.setupMainMenu ("File", "Cut", …).
        let subtitle = VideoEditorStyle.label("Mark up your recordings — drawings, zooms, overlays and captions.",
                                               size: 12, color: VideoEditorStyle.textSecondary)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.cell?.wraps = true

        let openButton = VideoPillButton(title: L("Open Video..."), symbol: "film",
                                          target: self, action: #selector(openVideoTapped))
        openButton.fill = VideoEditorStyle.control
        let recordButton = VideoPillButton(title: L("Record Screen"), symbol: "record.circle",
                                            target: self, action: #selector(recordScreenTapped))
        recordButton.fill = VideoEditorStyle.accent.withAlphaComponent(0.85)
        recordButton.textColor = .white

        let buttonRow = NSStackView(views: [openButton, recordButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let recentHeader = InspectorSectionHeader("Recent")

        emptyLabel = VideoEditorStyle.label("No recent videos", size: 12, color: VideoEditorStyle.textTertiary)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("recent"))
        column.width = 560
        tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedRecent)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        root.addSubview(icon)
        root.addSubview(headerStack)
        root.addSubview(buttonRow)
        root.addSubview(recentHeader)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        recentHeader.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            headerStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            headerStack.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            buttonRow.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),

            recentHeader.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 26),
            recentHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            recentHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            scroll.topAnchor.constraint(equalTo: recentHeader.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
        ])
    }

    // MARK: - Actions

    @objc private func openVideoTapped() { onOpenVideo?() }
    @objc private func recordScreenTapped() { onRecordScreen?() }

    @objc private func openSelectedRecent() {
        let row = tableView.clickedRow
        guard row >= 0, row < recents.count else { return }
        onOpenURL?(recents[row])
    }

    // MARK: - Recents

    private func reloadRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        tableView.reloadData()
        emptyLabel.isHidden = !recents.isEmpty
        tableView.isHidden = recents.isEmpty
    }

    // Deliberately no `windowWillClose` focus handoff here: unlike the
    // screenshot overlay flow, Welcome never captured a `previousApp` to
    // return to, and this is a regular Dock app now (Markclip Phase 1 —
    // ROADMAP.md) — closing its Welcome window shouldn't jump focus to some
    // other running app, it should just leave Markclip frontmost with no
    // windows, like any normal Mac app.
}

// MARK: - NSTableViewDataSource / Delegate

extension WelcomeWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < recents.count else { return nil }
        let url = recents[row]
        let identifier = NSUserInterfaceItemIdentifier("recentRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: nil) as? WelcomeRecentRowView)
            ?? WelcomeRecentRowView()
        rowView.identifier = identifier
        rowView.configure(url: url)
        return rowView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = WelcomeTableRowView()
        return rowView
    }
}

/// A single recent-file row: file icon, name, and folder path.
private final class WelcomeRecentRowView: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = VideoEditorStyle.label("", size: 13)
    private let pathLabel = VideoEditorStyle.label("", size: 10.5, color: VideoEditorStyle.textTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [nameLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL) {
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        nameLabel.stringValue = url.deletingPathExtension().lastPathComponent
        pathLabel.stringValue = url.deletingLastPathComponent().path
    }
}

/// Transparent row background — the table itself sits on the dark window.
private final class WelcomeTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        VideoEditorStyle.control.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Content view that accepts a dragged video file anywhere in the window.
private final class WelcomeDropView: NSView {
    var onDropFile: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func videoURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first else { return nil }
        return WelcomeWindowController.videoExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        videoURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = videoURL(from: sender) else { return false }
        onDropFile?(url)
        return true
    }
}
