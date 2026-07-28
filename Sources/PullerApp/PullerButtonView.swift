import AppKit
import PullerCore

@MainActor
final class PullerButtonView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let label = NSTextField(labelWithString: "需要安装")
    private var mouseDownLocation: NSPoint?
    private var lastDragLocation: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(_ viewModel: PanelStateViewModel) {
        label.stringValue = viewModel.label
        alphaValue = viewModel.isEnabled ? 1 : 0.78
        layer?.backgroundColor = color(for: viewModel.state).cgColor
        setAccessibilityLabel(viewModel.label)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        lastDragLocation = mouseDownLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        guard let origin = mouseDownLocation, let last = lastDragLocation else { return }
        if hypot(location.x - origin.x, location.y - origin.y) >= 4 {
            isDragging = true
        }
        if isDragging {
            onDrag?(NSPoint(x: location.x - last.x, y: location.y - last.y))
        }
        lastDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            lastDragLocation = nil
            isDragging = false
        }
        if !isDragging { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func color(for state: PullerState) -> NSColor {
        switch state {
        case .helperUnavailable: NSColor(calibratedRed: 0.19, green: 0.38, blue: 0.66, alpha: 0.96)
        case .absent: NSColor(calibratedWhite: 0.25, alpha: 0.94)
        case .ready: NSColor(calibratedRed: 0.09, green: 0.50, blue: 0.30, alpha: 0.96)
        case .cutting: NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.18, alpha: 0.97)
        case .notTriggered: NSColor(calibratedRed: 0.46, green: 0.35, blue: 0.12, alpha: 0.96)
        case .waitingForReconnect: NSColor(calibratedRed: 0.65, green: 0.37, blue: 0.08, alpha: 0.96)
        case .error: NSColor(calibratedRed: 0.66, green: 0.25, blue: 0.12, alpha: 0.97)
        }
    }
}
