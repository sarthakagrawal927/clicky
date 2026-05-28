//
//  PaceActionTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for the pure-function parser that pulls action tags out of
//  Claude's response. Covers: each tag type, screen suffix, modifier
//  chains, multi-tag order preservation, and the no-tag passthrough.
//

import Testing
@testable import Pace

struct PaceActionTagParserTests {

    @Test func plainTextWithNoTagsPassesThroughUnchanged() async throws {
        let inputResponse = "hey there, html stands for hypertext markup language."
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == inputResponse)
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.firstClickVisualisationLocation == nil)
    }

    @Test func pointTagIsNotConsumedByActionParser() async throws {
        // The POINT tag is owned by the existing pointing parser. The
        // action parser must leave it alone so the two layers compose.
        let inputResponse = "see the button up top. [POINT:285,11:source control]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == inputResponse)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func singleClickTagIsExtractedAndStripped() async throws {
        let inputResponse = "saving it now. [CLICK:400,300]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == "saving it now.")
        #expect(parseResult.actions.count == 1)

        guard case .click(let location) = parseResult.actions[0] else {
            Issue.record("Expected a CLICK action, got \(parseResult.actions[0])")
            return
        }
        #expect(location.xInScreenshotPixels == 400)
        #expect(location.yInScreenshotPixels == 300)
        #expect(location.screenNumber == nil)
        #expect(parseResult.firstClickVisualisationLocation?.xInScreenshotPixels == 400)
    }

    @Test func clickTagWithScreenSuffixCapturesScreenNumber() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[CLICK:120,240:screen2]")

        guard case .click(let location) = parseResult.actions.first else {
            Issue.record("Expected a CLICK action")
            return
        }
        #expect(location.xInScreenshotPixels == 120)
        #expect(location.yInScreenshotPixels == 240)
        #expect(location.screenNumber == 2)
    }

    @Test func doubleClickTagYieldsDoubleClickAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[DOUBLE_CLICK:50,75]")

        guard case .doubleClick(let location) = parseResult.actions.first else {
            Issue.record("Expected a DOUBLE_CLICK action")
            return
        }
        #expect(location.xInScreenshotPixels == 50)
        #expect(location.yInScreenshotPixels == 75)
    }

    @Test func typeTagPreservesMultiWordTextVerbatim() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "ok. [TYPE:hello world, ready?]")

        #expect(parseResult.spokenText == "ok.")
        guard case .type(let typedText) = parseResult.actions.first else {
            Issue.record("Expected a TYPE action")
            return
        }
        #expect(typedText == "hello world, ready?")
    }

    @Test func keyTagWithoutModifiersReturnsBareKey() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[KEY:Return]")

        guard case .pressKey(let keyName, let modifiers) = parseResult.actions.first else {
            Issue.record("Expected a KEY action")
            return
        }
        #expect(keyName == "return")
        #expect(modifiers.isEmpty)
    }

    @Test func keyTagWithModifierChainParsesEachModifier() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[KEY:cmd+shift+t]")

        guard case .pressKey(let keyName, let modifiers) = parseResult.actions.first else {
            Issue.record("Expected a KEY action")
            return
        }
        #expect(keyName == "t")
        #expect(modifiers.contains(.command))
        #expect(modifiers.contains(.shift))
        #expect(modifiers.count == 2)
    }

    @Test func scrollTagParsesDirectionAndAmount() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[SCROLL:down:5]")

        guard case .scroll(let direction, let amountInLines) = parseResult.actions.first else {
            Issue.record("Expected a SCROLL action")
            return
        }
        #expect(direction == .down)
        #expect(amountInLines == 5)
    }

    @Test func scrollTagWithoutAmountFallsBackToDefault() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: "[SCROLL:up]")

        guard case .scroll(let direction, let amountInLines) = parseResult.actions.first else {
            Issue.record("Expected a SCROLL action")
            return
        }
        #expect(direction == .up)
        #expect(amountInLines == 3) // documented default
    }

    @Test func chainedActionTagsPreserveSourceOrder() async throws {
        let inputResponse = "on it. [CLICK:740,80][TYPE:whisper flow][KEY:Return]"
        let parseResult = PaceActionTagParser.parseActions(from: inputResponse)

        #expect(parseResult.spokenText == "on it.")
        #expect(parseResult.actions.count == 3)

        if case .click(let firstLocation) = parseResult.actions[0] {
            #expect(firstLocation.xInScreenshotPixels == 740)
            #expect(firstLocation.yInScreenshotPixels == 80)
        } else {
            Issue.record("First action should be CLICK")
        }

        if case .type(let typedText) = parseResult.actions[1] {
            #expect(typedText == "whisper flow")
        } else {
            Issue.record("Second action should be TYPE")
        }

        if case .pressKey(let keyName, _) = parseResult.actions[2] {
            #expect(keyName == "return")
        } else {
            Issue.record("Third action should be KEY")
        }
    }

    @Test func firstClickIsReportedForCursorFlightVisualisation() async throws {
        // The first CLICK or DOUBLE_CLICK should be exposed so the
        // existing cursor-flight visualisation has a target.
        let parseResult = PaceActionTagParser.parseActions(
            from: "[TYPE:no click yet][CLICK:200,150][CLICK:9,9]"
        )

        #expect(parseResult.firstClickVisualisationLocation?.xInScreenshotPixels == 200)
        #expect(parseResult.firstClickVisualisationLocation?.yInScreenshotPixels == 150)
    }

    @Test func tagsInterleavedWithSentencesAreAllStripped() async throws {
        let parseResult = PaceActionTagParser.parseActions(
            from: "first i'll click here [CLICK:100,200] then type [TYPE:hi] done."
        )

        #expect(parseResult.spokenText == "first i'll click here  then type  done.")
        #expect(parseResult.actions.count == 2)
    }

    @Test func unknownTagBodyIsTreatedAsAbsent() async throws {
        // [CLICK:nonsense] has no parseable x,y so it should not produce
        // an action and should not appear in the spoken text either.
        let parseResult = PaceActionTagParser.parseActions(from: "ok. [CLICK:nonsense]")

        // The tag is still stripped because the regex matched, but the
        // payload didn't parse so no action was emitted.
        #expect(parseResult.actions.isEmpty)
        #expect(parseResult.spokenText == "ok.")
    }
}
