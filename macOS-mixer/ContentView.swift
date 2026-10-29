//
//  ContentView.swift
//  macOS-mixer
//
//  Created by James on 28/10/26.
//

import SwiftUI

struct ContentView: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MasterRow(model: model)

            Divider()

            if model.entries.isEmpty {
                Text("No apps playing sounds.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.entries) { entry in
                    AppRow(model: model, entry: entry)
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}

/// The system volume: controls the default output device, and its icon's tooltip is that device's name.
private struct MasterRow: View {
    let model: MixerModel

    var body: some View {
        let name = model.outputDeviceName.isEmpty ? "Output device" : model.outputDeviceName

        VolumeRow(
            icon: Image(systemName: "speaker.wave.3.fill")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.primary),
            name: name,
            volume: model.masterMuted ? 0 : model.masterVolume,
            isMuted: model.masterMuted,
            isEnabled: model.masterAvailable,
            slashesIcon: model.masterMuted,
            onIconClick: { model.toggleMasterMute() },
            onVolumeChange: { model.setMasterVolume($0) }
        )
    }
}

private struct AppRow: View {
    let model: MixerModel
    let entry: MixerModel.Entry

    var body: some View {
        // While the system is muted every app looks muted and can't be changed; each app's own volume and mute
        // state are untouched, so they come back when the system is unmuted.
        let systemMuted = model.masterMuted
        let muted = model.isMuted(entry.id) || systemMuted

        VolumeRow(
            icon: Image(nsImage: entry.icon).resizable(),
            name: entry.name,
            volume: muted ? 0 : model.volume(for: entry.id),
            isMuted: muted,
            isEnabled: !systemMuted,
            slashesIcon: muted,
            onIconClick: { model.toggleMute(entry.id) },
            onVolumeChange: { model.setVolume($0, for: entry.id) }
        )
    }
}

/// One line: icon (a mute button with a hover tooltip of `name`), slider and editable percentage.
private struct VolumeRow<Icon: View>: View {
    let icon: Icon
    let name: String
    /// The effective volume, 0 when muted.
    let volume: Float
    let isMuted: Bool
    var isEnabled = true
    /// Draws a diagonal line across the icon to show it is muted.
    var slashesIcon = false
    /// Clicking the icon runs this (toggles mute).
    let onIconClick: () -> Void
    let onVolumeChange: (Float) -> Void

    /// Moves the volume by whole percentage points; used by scroll-wheel adjustment.
    private func nudge(by steps: Int) {
        let current = Int((volume * 100).rounded())
        onVolumeChange(Float(min(max(current + steps, 0), 100)) / 100)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onIconClick) { icon }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .overlay {
                    if slashesIcon || volume == 0 { MuteSlash() }
                }
                .accessibilityLabel(isMuted ? "Unmute \(name)" : "Mute \(name)")
                .background(HoverTooltip(text: name))

            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: { onVolumeChange(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .accessibilityLabel("\(name) volume")
            .background(ScrollWheelAdjuster(horizontal: true, isEnabled: isEnabled, onStep: nudge))

            PercentField(percent: Int((volume * 100).rounded())) { percent in
                onVolumeChange(Float(percent) / 100)
            }
            .background(ScrollWheelAdjuster(horizontal: false, isEnabled: isEnabled, onStep: nudge))
        }
        // Not `.disabled`, which would also dim the row; it still can't be interacted with.
        .allowsHitTesting(isEnabled)
    }
}

/// A white diagonal line from top-left to bottom-right.
private struct MuteSlash: View {
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 3))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 3))
            return path
        }
    }

    var body: some View {
        Line()
            .stroke(.white, style: StrokeStyle(lineWidth: 1.25, lineCap: .butt))
            .clipShape(Rectangle())   // never draws outside the icon's frame
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shows the volume as a percentage; clicking it turns it into a field where a value can be typed.
private struct PercentField: View {
    let percent: Int
    let onCommit: (Int) -> Void

    @State private var isEditing = false
    @State private var text = ""
    @State private var originalPercent = 0
    @State private var clickMonitor: Any?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $text)
                    .accessibilityLabel("Volume")
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onSubmit(commit)
                    .onChange(of: text) { _, newValue in applyLive(newValue) }
                    .onKeyPress(.upArrow) { step(by: 1) }
                    .onKeyPress(.downArrow) { step(by: -1) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onExitCommand {   // Escape cancels and restores the previous volume
                        isEditing = false
                        onCommit(originalPercent)
                    }
            } else {
                Button("\(percent)%") {
                    originalPercent = percent
                    text = "\(percent)"
                    isEditing = true
                }
                .buttonStyle(.plain)
                .accessibilityHint("Type a volume percentage")
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 38, alignment: .trailing)
        .onChange(of: isEditing) { _, editing in
            if editing { startMonitoringClicks() } else { stopMonitoringClicks() }
        }
        .onDisappear(perform: stopMonitoringClicks)
        .onChange(of: percent) { _, newPercent in
            if isEditing, Int(text.filter(\.isNumber)) != newPercent { text = String(newPercent) }
        }
        .task(id: isEditing) {
            // Clicking outside the menu-bar panel closes it by resigning key, which never reaches the click monitor.
            guard isEditing else { return }
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didResignKeyNotification) {
                commit()
                break
            }
        }
    }

    /// Clicking empty space or a non-text control doesn't move focus away from the field on its own,
    /// so watch for clicks outside it and treat them as the end of editing.
    private func startMonitoringClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            let hit = event.window?.contentView?.hitTest(event.locationInWindow)
            let editor = event.window?.firstResponder as? NSView
            let insideField = hit.map { view in
                (view as? NSTextField)?.currentEditor() != nil || editor.map { view === $0 || view.isDescendant(of: $0) } == true
            } ?? false
            if !insideField { commit() }
            return event   // the click still reaches whatever was clicked
        }
    }

    private func stopMonitoringClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Moves the typed value up or down; the change is applied through `applyLive` via the text binding.
    private func step(by delta: Int) -> KeyPress.Result {
        let current = Int(text.filter(\.isNumber)) ?? originalPercent
        text = String(min(max(current + delta, 0), 100))
        return .handled
    }

    /// Applies the typed value immediately so the slider and sound follow as you type.
    private func applyLive(_ newValue: String) {
        guard isEditing, let value = Int(newValue.filter(\.isNumber)) else { return }
        let clamped = min(max(value, 0), 100)
        if String(clamped) != newValue { text = String(clamped) }   // also strips non-digits and caps at 100
        onCommit(clamped)
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let digits = text.filter(\.isNumber)
        guard let value = Int(digits) else { return }
        onCommit(min(max(value, 0), 100))
    }
}

/// Turns scroll-wheel/trackpad scrolling over the view it is attached to (as a background) into whole steps.
/// Scrolling down increases; with `horizontal`, scrolling left increases too.
private struct ScrollWheelAdjuster: NSViewRepresentable {
    let horizontal: Bool
    var isEnabled = true
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> ScrollTrackingView { ScrollTrackingView() }

    func updateNSView(_ view: ScrollTrackingView, context: Context) {
        view.horizontal = horizontal
        view.isEnabled = isEnabled
        view.onStep = onStep
    }
}

private final class ScrollTrackingView: NSView {
    var horizontal = false
    /// When false, scrolling is ignored and passes through untouched.
    var isEnabled = true
    var onStep: (Int) -> Void = { _ in }

    private var monitor: Any?
    private var remainder: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit { removeMonitor() }

    /// Never intercept clicks; this view only observes scrolling.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }

        var delta = -event.scrollingDeltaY
        if horizontal, abs(event.scrollingDeltaX) > abs(delta) { delta = event.scrollingDeltaX }

        // A wheel notch is one step; trackpads report points, so need more movement per step.
        remainder += delta / (event.hasPreciseScrollingDeltas ? 8 : 1)
        let steps = Int(remainder)
        if steps != 0 {
            remainder -= CGFloat(steps)
            onStep(steps)
        }
        return nil   // consumed, so nothing underneath scrolls
    }
}

/// Draws a tooltip in its own small window while the mouse is over the view it is attached to (as a background).
/// The system tooltip only appears in the key window, which the menu-bar panel usually isn't, so this tracks the
/// mouse itself (`.activeAlways`) and doesn't depend on focus.
private struct HoverTooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> HoverTooltipView { HoverTooltipView() }

    func updateNSView(_ view: HoverTooltipView, context: Context) {
        view.text = text
    }
}

private final class HoverTooltipView: NSView {
    var text = ""

    private var showTask: Task<Void, Never>?
    private var tooltipWindow: NSPanel?
    private var observer: NSObjectProtocol?
    private var clickMonitor: Any?

    /// Never intercept clicks; this view only observes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.showTooltip()
        }
    }

    override func mouseExited(with event: NSEvent) { hideTooltip() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hideTooltip()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let newWindow else { return }
        // Clicking the icon dismisses the tooltip (and cancels one that hasn't appeared yet).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === newWindow,
               bounds.contains(convert(event.locationInWindow, from: nil)) {
                hideTooltip()
            }
            return event
        }
        // The panel can close without the mouse ever "exiting" the icon.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main
        ) { [weak self, weak newWindow] _ in
            if newWindow?.occlusionState.contains(.visible) != true { self?.hideTooltip() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    private func showTooltip() {
        guard let window, window.isVisible, !text.isEmpty else { return }
        hideTooltip()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.sizeToFit()

        let padding = NSSize(width: 12, height: 6)
        let size = NSSize(width: label.frame.width + padding.width, height: label.frame.height + padding.height)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        background.layer?.masksToBounds = true
        label.setFrameOrigin(NSPoint(x: padding.width / 2, y: padding.height / 2))
        background.addSubview(label)

        // Just below the icon, kept on screen.
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 4)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.orderFrontRegardless()
        tooltipWindow = panel
    }

    private func hideTooltip() {
        showTask?.cancel()
        showTask = nil
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }
}
