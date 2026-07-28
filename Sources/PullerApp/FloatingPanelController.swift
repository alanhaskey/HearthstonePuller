import AppKit

@MainActor
final class FloatingPanelController {
    static let panelSize = NSSize(width: 144, height: 72)
    private static let originXKey = "floatingPanelOriginX"
    private static let originYKey = "floatingPanelOriginY"

    let panel: NSPanel
    let buttonView: PullerButtonView

    init() {
        buttonView = PullerButtonView(frame: NSRect(origin: .zero, size: Self.panelSize))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = buttonView
        panel.isMovableByWindowBackground = false

        buttonView.onDrag = { [weak self] delta in self?.move(by: delta) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampToVisibleScreen() }
        }
        restorePosition()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func move(by delta: NSPoint) {
        var origin = panel.frame.origin
        origin.x += delta.x
        origin.y += delta.y
        panel.setFrameOrigin(origin)
        clampToVisibleScreen()
        persistPosition()
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil,
           defaults.object(forKey: Self.originYKey) != nil {
            panel.setFrameOrigin(NSPoint(
                x: defaults.double(forKey: Self.originXKey),
                y: defaults.double(forKey: Self.originYKey)
            ))
        } else if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - Self.panelSize.width - 20,
                y: frame.maxY - Self.panelSize.height - 20
            ))
        }
        clampToVisibleScreen()
    }

    private func persistPosition() {
        UserDefaults.standard.set(panel.frame.origin.x, forKey: Self.originXKey)
        UserDefaults.standard.set(panel.frame.origin.y, forKey: Self.originYKey)
    }

    private func clampToVisibleScreen() {
        guard let screen = bestScreen(for: panel.frame) else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: min(max(panel.frame.minX, visible.minX), visible.maxX - Self.panelSize.width),
            y: min(max(panel.frame.minY, visible.minY), visible.maxY - Self.panelSize.height)
        )
        panel.setFrameOrigin(origin)
        persistPosition()
    }

    private func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        } ?? NSScreen.main
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
