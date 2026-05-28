//
//  PaceActionExecutor.swift
//  leanring-buddy
//
//  Executes mouse and keyboard actions on the user's behalf via
//  CGEvent. This is the layer that turns pace from a pointer into an
//  agent: it actually clicks, types, and presses keys.
//
//  All actions are gated by `EnableActions` in Info.plist. When the
//  flag is off, every method here becomes a no-op and we log instead.
//  When it's on, we still introduce small inter-action delays so the
//  target app has time to respond to focus / hover / key-down state
//  changes — without these, fast multi-step sequences race the UI.
//

import AppKit
import CoreGraphics
import Foundation

/// A single mouse position expressed in *screenshot pixel space*. The
/// executor converts to display-points and CG global coords internally
/// using the same screen-capture metadata the pointing layer uses, so
/// callers never need to think about coordinate spaces.
struct ScreenshotPixelLocation {
    let xInScreenshotPixels: Int
    let yInScreenshotPixels: Int
    /// 1-based screen index from the screenshot label. nil = cursor screen.
    let screenNumber: Int?
}

@MainActor
final class PaceActionExecutor {
    /// Read from Info.plist at construction so a release build with the
    /// flag set false is guaranteed not to execute anything.
    let actionsAreEnabled: Bool

    /// Delay between consecutive actions when a single planner response
    /// chains several (e.g. click then type). Gives the focused app
    /// time to accept input. 75ms is the smallest reliable value across
    /// the common macOS apps tested during development.
    private let interActionDelay: TimeInterval = 0.075

    /// Hybrid targeter that tries the accessibility tree first before
    /// falling back to raw CGEvent clicks. Single-click only — double-
    /// click and drag still go through CGEvent because AX doesn't have
    /// a built-in "double-press" action.
    private let axTargeter = PaceAXTargeter()

    init() {
        let rawFlag = AppBundleConfiguration.stringValue(forKey: "EnableActions")?.lowercased()
        self.actionsAreEnabled = (rawFlag == "true" || rawFlag == "1" || rawFlag == "yes")
        if actionsAreEnabled {
            print("🤖 PaceActionExecutor: actions ENABLED — real clicks and keystrokes will be sent")
        } else {
            print("🤖 PaceActionExecutor: actions DISABLED (Info.plist EnableActions != true) — dry-run only")
        }
    }

    // MARK: - High-level entry point

    /// Executes a sequence of actions parsed from Claude's response.
    /// Each action waits `interActionDelay` after the previous one so
    /// the target app can react. When `actionsAreEnabled` is false,
    /// every call is logged but no system event is posted.
    func executeActionSequence(
        _ actions: [PaceParsedAction],
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard !actions.isEmpty else { return }

        for (actionIndex, action) in actions.enumerated() {
            await executeSingleAction(action, screenCaptures: screenCaptures)
            let isLastAction = (actionIndex == actions.count - 1)
            if !isLastAction {
                try? await Task.sleep(nanoseconds: UInt64(interActionDelay * 1_000_000_000))
            }
        }
    }

    private func executeSingleAction(
        _ action: PaceParsedAction,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        switch action {
        case .click(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 1)
        case .doubleClick(let location):
            await clickAtScreenshotLocation(location, screenCaptures: screenCaptures, clickCount: 2)
        case .type(let textToType):
            await typeText(textToType)
        case .pressKey(let keyName, let modifiers):
            await pressKey(named: keyName, withModifiers: modifiers)
        case .scroll(let direction, let amount):
            await scroll(direction: direction, amountInLines: amount)
        }
    }

    // MARK: - Mouse

    private func clickAtScreenshotLocation(
        _ screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture],
        clickCount: Int
    ) async {
        guard let displayGlobalPoint = convertScreenshotPixelToDisplayGlobalPoint(
            screenshotPixelLocation: screenshotPixelLocation,
            screenCaptures: screenCaptures
        ) else {
            print("⚠️ PaceActionExecutor: could not resolve display coordinates for click — skipping")
            return
        }

        print("🖱️  Click x\(clickCount) at \(Int(displayGlobalPoint.x)),\(Int(displayGlobalPoint.y)) (enabled: \(actionsAreEnabled))")

        guard actionsAreEnabled else { return }

        // Try the AX path first for single clicks. If AX finds a
        // pressable element and the press succeeds, we skip the CGEvent
        // path entirely — it's more robust against layout shifts and
        // synthesises a semantically correct activation event.
        // Double-clicks still go through CGEvent because AX has no
        // "double-press" primitive.
        if clickCount == 1, axTargeter.tryClickViaAccessibility(atGlobalCGPoint: displayGlobalPoint) {
            return
        }

        // Move the system cursor first so the visual position matches the
        // synthetic click and so any hover state (tooltips, menu reveals)
        // settles before the click lands.
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: displayGlobalPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms hover settle

        for clickIndex in 0..<clickCount {
            let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            downEvent?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms hold

            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: displayGlobalPoint,
                mouseButton: .left
            )
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex + 1))
            upEvent?.post(tap: .cghidEventTap)

            if clickIndex < clickCount - 1 {
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms between clicks of a double-click
            }
        }
    }

    private func scroll(direction: PaceScrollDirection, amountInLines: Int) async {
        print("🖱️  Scroll \(direction) by \(amountInLines) lines (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        let verticalDelta: Int32 = {
            switch direction {
            case .up: return Int32(amountInLines)
            case .down: return -Int32(amountInLines)
            }
        }()

        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: verticalDelta,
            wheel2: 0,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    private func typeText(_ textToType: String) async {
        print("⌨️  Type \(textToType.count) chars (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        // Use unicode-string CGEvents so we don't have to map every char to
        // a key code. This works for any printable text including emoji.
        // Each grapheme gets its own keyDown + keyUp pair.
        for unicodeCharacter in textToType {
            let utf16Units = Array(String(unicodeCharacter).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyDownEvent.post(tap: .cghidEventTap)

            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
            keyUpEvent.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: 8_000_000) // 8ms between chars feels natural
        }
    }

    private func pressKey(named keyName: String, withModifiers modifiers: [PaceKeyboardModifier]) async {
        print("⌨️  Press \(keyName) with modifiers \(modifiers) (enabled: \(actionsAreEnabled))")
        guard actionsAreEnabled else { return }

        guard let virtualKeyCode = Self.virtualKeyCode(forKeyName: keyName) else {
            print("⚠️ PaceActionExecutor: unknown key name \(keyName)")
            return
        }

        let modifierFlags = Self.cgEventFlags(forModifiers: modifiers)

        if let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: true) {
            keyDownEvent.flags = modifierFlags
            keyDownEvent.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyCode, keyDown: false) {
            keyUpEvent.flags = modifierFlags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key name → virtual key code

    private static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        // Subset of common named keys. Add more on demand. Letter/number
        // keys are intentionally NOT included — use the [TYPE:...] action
        // for those, which goes through unicode-string events.
        switch keyName.lowercased() {
        case "return", "enter": return 0x24
        case "tab": return 0x30
        case "space": return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc": return 0x35
        case "up", "uparrow": return 0x7E
        case "down", "downarrow": return 0x7D
        case "left", "leftarrow": return 0x7B
        case "right", "rightarrow": return 0x7C
        case "home": return 0x73
        case "end": return 0x77
        case "pageup": return 0x74
        case "pagedown": return 0x79
        default:
            return nil
        }
    }

    private static func cgEventFlags(forModifiers modifiers: [PaceKeyboardModifier]) -> CGEventFlags {
        var combinedFlags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: combinedFlags.insert(.maskCommand)
            case .option: combinedFlags.insert(.maskAlternate)
            case .control: combinedFlags.insert(.maskControl)
            case .shift: combinedFlags.insert(.maskShift)
            }
        }
        return combinedFlags
    }

    // MARK: - Coordinate conversion

    /// Maps a screenshot-pixel coordinate to a global CG point (the
    /// coordinate space CGEvent expects: top-left origin, points). The
    /// math mirrors the pointing logic in CompanionManager so what the
    /// user sees the cursor *point at* is exactly where a click would land.
    private func convertScreenshotPixelToDisplayGlobalPoint(
        screenshotPixelLocation: ScreenshotPixelLocation,
        screenCaptures: [CompanionScreenCapture]
    ) -> CGPoint? {
        let targetCapture: CompanionScreenCapture? = {
            if let screenNumber = screenshotPixelLocation.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()

        guard let capture = targetCapture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedScreenshotX = max(0, min(CGFloat(screenshotPixelLocation.xInScreenshotPixels), screenshotWidth))
        let clampedScreenshotY = max(0, min(CGFloat(screenshotPixelLocation.yInScreenshotPixels), screenshotHeight))

        let displayLocalX = clampedScreenshotX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedScreenshotY * (displayHeight / screenshotHeight)

        // CG global coordinates have top-left origin on the main screen.
        // CompanionScreenCapture.displayFrame is in AppKit coords (bottom-left
        // origin), so we need to convert here. The main screen's height in
        // AppKit coords minus the AppKit y of the top of the display gives
        // the CG y of the top of the display.
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = mainScreen.frame.height
        let displayCGTopY = mainScreenHeight - (displayFrame.origin.y + displayHeight)

        let globalCGPoint = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayLocalY + displayCGTopY
        )

        return globalCGPoint
    }
}

// MARK: - Parsed action types

/// One action Claude wants pace to perform on the user's behalf.
/// Parsed out of the assistant's response by `PaceActionTagParser`.
enum PaceParsedAction {
    case click(ScreenshotPixelLocation)
    case doubleClick(ScreenshotPixelLocation)
    case type(String)
    case pressKey(name: String, modifiers: [PaceKeyboardModifier])
    case scroll(PaceScrollDirection, amountInLines: Int)
}

enum PaceKeyboardModifier: String {
    case command, option, control, shift
}

enum PaceScrollDirection: String, CustomStringConvertible {
    case up, down

    var description: String { rawValue }
}

// MARK: - Action tag parser

/// Result of pulling all action tags out of Claude's response.
struct PaceActionTagParseResult {
    /// The assistant text with every recognised action tag stripped.
    /// Safe to feed to TTS.
    let spokenText: String
    /// The parsed actions, in the order they appeared in the response.
    let actions: [PaceParsedAction]
    /// The first click/double-click coordinate, if any — used by the
    /// existing cursor-flight visualization so the user sees pace
    /// move to the target before it executes.
    let firstClickVisualisationLocation: ScreenshotPixelLocation?
}

enum PaceActionTagParser {
    /// Tag formats supported (case-insensitive on tag name):
    ///   [CLICK:x,y]                or [CLICK:x,y:screen2]
    ///   [DOUBLE_CLICK:x,y]         or [DOUBLE_CLICK:x,y:screen2]
    ///   [TYPE:hello world]
    ///   [KEY:Return]               or [KEY:cmd+s]   or [KEY:cmd+shift+t]
    ///   [SCROLL:up:3]              or [SCROLL:down:5]
    ///
    /// Order of tags in the response is preserved in the returned actions array.
    static func parseActions(from responseText: String) -> PaceActionTagParseResult {
        // One regex that matches any of the supported tag shapes. We use a
        // single pass so we can walk matches in source order. Group 1 is the
        // tag name; group 2 is the everything-after-the-colon payload.
        let actionTagPattern = #"\[(CLICK|DOUBLE_CLICK|TYPE|KEY|SCROLL):([^\]]+)\]"#

        guard let actionTagRegex = try? NSRegularExpression(
            pattern: actionTagPattern,
            options: [.caseInsensitive]
        ) else {
            return PaceActionTagParseResult(
                spokenText: responseText,
                actions: [],
                firstClickVisualisationLocation: nil
            )
        }

        let entireRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = actionTagRegex.matches(in: responseText, options: [], range: entireRange)

        var parsedActions: [PaceParsedAction] = []
        var firstClickVisualisationLocation: ScreenshotPixelLocation? = nil
        var spokenTextWithoutActionTags = responseText

        // Build spoken text by removing matches in reverse so ranges stay valid.
        let matchesInForwardOrder = matches
        let matchesInReverseOrder = matches.reversed()

        for match in matchesInForwardOrder {
            guard let fullRange = Range(match.range, in: responseText),
                  let nameRange = Range(match.range(at: 1), in: responseText),
                  let payloadRange = Range(match.range(at: 2), in: responseText) else {
                continue
            }
            let tagName = String(responseText[nameRange]).uppercased()
            let payload = String(responseText[payloadRange])

            if let parsedAction = parseSingleAction(tagName: tagName, payload: payload) {
                parsedActions.append(parsedAction)

                // Record the first CLICK / DOUBLE_CLICK location so the
                // cursor flight animation has somewhere to fly to.
                if firstClickVisualisationLocation == nil {
                    switch parsedAction {
                    case .click(let loc), .doubleClick(let loc):
                        firstClickVisualisationLocation = loc
                    default:
                        break
                    }
                }
            }
            _ = fullRange // silence unused warning; we use it via the reverse loop below
        }

        for match in matchesInReverseOrder {
            guard let fullRange = Range(match.range, in: spokenTextWithoutActionTags) else { continue }
            spokenTextWithoutActionTags.removeSubrange(fullRange)
        }

        let cleanedSpokenText = spokenTextWithoutActionTags
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return PaceActionTagParseResult(
            spokenText: cleanedSpokenText,
            actions: parsedActions,
            firstClickVisualisationLocation: firstClickVisualisationLocation
        )
    }

    private static func parseSingleAction(tagName: String, payload: String) -> PaceParsedAction? {
        switch tagName {
        case "CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .click($0) }
        case "DOUBLE_CLICK":
            return parseScreenshotPixelLocationPayload(payload).map { .doubleClick($0) }
        case "TYPE":
            // TYPE payload is free text — pass through verbatim.
            return .type(payload)
        case "KEY":
            return parseKeyPayload(payload)
        case "SCROLL":
            return parseScrollPayload(payload)
        default:
            return nil
        }
    }

    /// Parses `x,y` or `x,y:screenN` into a ScreenshotPixelLocation.
    private static func parseScreenshotPixelLocationPayload(_ payload: String) -> ScreenshotPixelLocation? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard let coordinateComponent = payloadComponents.first else { return nil }

        let xyComponents = coordinateComponent.split(separator: ",", omittingEmptySubsequences: false)
        guard xyComponents.count == 2,
              let xPixel = Int(xyComponents[0].trimmingCharacters(in: .whitespaces)),
              let yPixel = Int(xyComponents[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        var screenNumber: Int? = nil
        for trailingComponent in payloadComponents.dropFirst() {
            let trimmedTrailingComponent = trailingComponent.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmedTrailingComponent.hasPrefix("screen") {
                let digitsString = trimmedTrailingComponent.dropFirst("screen".count)
                screenNumber = Int(digitsString)
            }
        }

        return ScreenshotPixelLocation(
            xInScreenshotPixels: xPixel,
            yInScreenshotPixels: yPixel,
            screenNumber: screenNumber
        )
    }

    /// Parses `Return`, `cmd+s`, `cmd+shift+t` into a pressKey action.
    private static func parseKeyPayload(_ payload: String) -> PaceParsedAction? {
        let plusSeparatedTokens = payload.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let mainKeyToken = plusSeparatedTokens.last, !mainKeyToken.isEmpty else { return nil }

        var modifiers: [PaceKeyboardModifier] = []
        for modifierToken in plusSeparatedTokens.dropLast() {
            switch modifierToken {
            case "cmd", "command", "meta": modifiers.append(.command)
            case "opt", "option", "alt": modifiers.append(.option)
            case "ctrl", "control": modifiers.append(.control)
            case "shift": modifiers.append(.shift)
            default: continue
            }
        }

        return .pressKey(name: mainKeyToken, modifiers: modifiers)
    }

    /// Parses `up:3` / `down:5` into a scroll action.
    private static func parseScrollPayload(_ payload: String) -> PaceParsedAction? {
        let payloadComponents = payload.split(separator: ":", omittingEmptySubsequences: true)
        guard let directionString = payloadComponents.first,
              let direction = PaceScrollDirection(rawValue: directionString.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }

        let amountInLines: Int = {
            if payloadComponents.count >= 2,
               let parsedAmount = Int(payloadComponents[1].trimmingCharacters(in: .whitespaces)) {
                return max(1, min(parsedAmount, 50)) // clamp to a reasonable range
            }
            return 3
        }()

        return .scroll(direction, amountInLines: amountInLines)
    }
}
