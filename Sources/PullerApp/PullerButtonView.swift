import AppKit
import PullerCore

@MainActor
final class PullerButtonView: NSView {
    static let titleFontSize: CGFloat = 18
    static let countdownFontSize: CGFloat = 20
    static let cornerRadius: CGFloat = 10

    var onClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let titleLabel = NSTextField(labelWithString: "需要安装")
    private let countdownLabel = NSTextField(labelWithString: "")
    private var mouseDownLocation: NSPoint?
    private var lastDragLocation: NSPoint?
    private var isDragging = false
    private var isHovered = false
    private var isPressed = false
    private var renderedState: PullerState = .helperUnavailable
    private var renderedEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        configure(
            titleLabel,
            font: .systemFont(ofSize: Self.titleFontSize, weight: .semibold)
        )
        configure(
            countdownLabel,
            font: .monospacedDigitSystemFont(ofSize: Self.countdownFontSize, weight: .bold)
        )
        countdownLabel.isHidden = true

        let stack = NSStackView(views: [titleLabel, countdownLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .gravityAreas
        stack.spacing = 0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(_ viewModel: PanelStateViewModel) {
        renderedState = viewModel.state
        renderedEnabled = viewModel.isEnabled
        titleLabel.stringValue = viewModel.title
        countdownLabel.stringValue = viewModel.countdown ?? ""
        countdownLabel.isHidden = viewModel.countdown == nil
        setAccessibilityLabel(viewModel.accessibilityText)
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
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
            isPressed = false
            updateAppearance()
            mouseDownLocation = nil
            lastDragLocation = nil
            isDragging = false
        }
        if !isDragging { onClick?() }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func configure(_ label: NSTextField, font: NSFont) {
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.font = font
        label.textColor = .white
    }

    private func updateAppearance() {
        layer?.backgroundColor = color(for: renderedState).cgColor
        switch (renderedEnabled, isPressed, isHovered) {
        case (false, _, _): alphaValue = 0.78
        case (true, true, _): alphaValue = 0.82
        case (true, false, true): alphaValue = 0.94
        case (true, false, false): alphaValue = 1
        }
    }

    private func color(for state: PullerState) -> NSColor {
        switch state {
        case .helperUnavailable: NSColor(calibratedRed: 0.19, green: 0.38, blue: 0.66, alpha: 0.96)
        case .absent: NSColor(calibratedWhite: 0.25, alpha: 0.94)
        case .ready: NSColor(calibratedRed: 0.09, green: 0.50, blue: 0.30, alpha: 0.96)
        case .cutting: NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.18, alpha: 0.97)
        case .waitingForGameResponse: NSColor(calibratedRed: 0.56, green: 0.28, blue: 0.10, alpha: 0.97)
        case .notTriggered: NSColor(calibratedRed: 0.46, green: 0.35, blue: 0.12, alpha: 0.96)
        case .waitingForReconnect: NSColor(calibratedRed: 0.65, green: 0.37, blue: 0.08, alpha: 0.96)
        case .error: NSColor(calibratedRed: 0.66, green: 0.25, blue: 0.12, alpha: 0.97)
        }
    }
}
