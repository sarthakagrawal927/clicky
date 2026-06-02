//
//  PaceActionApprovalTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

struct PaceActionApprovalTests {
    @Test func approvalRequestRequiresEnabledPreferenceAndNonEmptySummary() async throws {
        let summary = "1: [system mutation] Open app Safari"

        let enabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: true
        )
        #expect(enabledRequest?.approvalSummary == summary)

        let disabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: false
        )
        #expect(disabledRequest == nil)

        let emptyRequest = PaceActionApprovalRequest(
            approvalSummary: "   ",
            requiresActionApproval: true
        )
        #expect(emptyRequest == nil)
    }

    @Test func approvalRequestBuildsPopupCopyWithRiskSummary() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [input injection] Type text",
            requiresActionApproval: true
        ))

        #expect(request.messageText == "Approve Pace actions?")
        #expect(request.informativeText.contains("Pace wants to control your Mac:"))
        #expect(request.informativeText.contains("[input injection] Type text"))
        #expect(request.informativeText.contains("Only approve this if it matches what you asked for."))
    }

    @Test func cancellationBlocksExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [system mutation] Open app Music",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .cancel
        )

        #expect(shouldExecute == false)
    }

    @Test func allowOncePermitsExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [read-only] Read calendar",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .allowOnce
        )

        #expect(shouldExecute == true)
    }

    @Test func missingApprovalRequestPassesThrough() async throws {
        #expect(PaceActionApprovalPolicy.shouldExecuteActions(
            request: nil,
            decision: .cancel
        ))
    }
}
