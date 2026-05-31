//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let paceDismissPanel = Notification.Name("paceDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var statusItemStateCancellable: AnyCancellable?
    private var panel: NSPanel?
    private var panelAnchorFrameOverride: NSRect?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let statusItemWidth: CGFloat = 24
    private let statusItemHeight: CGFloat = 24
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .paceDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.hidePanel()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemWidth)
        statusItem?.isVisible = true

        guard let button = statusItem?.button else { return }

        configureStatusButtonAppearance(button)
        button.action = #selector(statusItemClicked)
        button.target = self

        statusItemStateCancellable = companionManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatusItemImage()
                }
            }
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    private func refreshStatusItemImage() {
        guard let button = statusItem?.button else { return }
        configureStatusButtonAppearance(button)
    }

    private func configureStatusButtonAppearance(_ button: NSStatusBarButton) {
        button.image = nil
        button.imagePosition = .noImage
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.96).cgColor
        button.layer?.cornerRadius = statusItemHeight / 2
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.attributedTitle = makeStatusItemAttributedTitle()
        button.toolTip = statusText
    }

    private func makeStatusItemAttributedTitle() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributedTitle = NSMutableAttributedString(
            string: "Pace  \(statusText)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle
            ]
        )

        attributedTitle.addAttributes(
            [
                .foregroundColor: connectionColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold)
            ],
            range: NSRange(location: 0, length: 4)
        )

        return attributedTitle
    }

    private var statusText: String {
        guard companionManager.allPermissionsGranted else {
            return "Setup"
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isLMStudioReachable ? "Pace" : "Local offline"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    private var connectionColor: NSColor {
        if !companionManager.allPermissionsGranted {
            return .systemOrange
        }
        return companionManager.isLMStudioReachable
            ? .systemGreen
            : NSColor.white.withAlphaComponent(0.40)
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func togglePanel(anchoredTo anchorFrame: NSRect) {
        panelAnchorFrameOverride = anchorFrame
        togglePanel()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        let statusItemFrame: NSRect
        if let panelAnchorFrameOverride {
            statusItemFrame = panelAnchorFrameOverride
        } else if let buttonWindow = statusItem?.button?.window {
            statusItemFrame = buttonWindow.frame
        } else {
            return
        }
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
