//
//  PaceSkillsView.swift
//  leanring-buddy
//
//  Skills sidebar tab for PaceMainWindow. Auto-generated from one
//  source of truth per category:
//
//    - Local skills      ← PaceToolRegistry.localTools
//    - MCP skills (per server) ← PaceMCPServerRegistry.loadConfiguredServers()
//
//  Drift-proof by construction: the new `exampleUtterance` field on
//  every PaceLocalToolDefinition is validated at startup, so an empty
//  utterance crashes the app before users can see this tab.
//
//  Searchable. Each row has copy-to-clipboard for the example utterance.
//  MCP servers are listed by name; tool-level introspection (a real
//  tools/list probe) needs an async stdio handshake — deliberately
//  deferred to v2 because the v1 win is "show the user that MCP exists
//  and which servers are wired up", not "render every MCP tool name".
//

import AppKit
import SwiftUI

// MARK: - PaceSkillsView

struct PaceSkillsView: View {
    @State private var searchQuery: String = ""
    @State private var configuredMCPServerNames: [String] = []
    @State private var lastCopiedExampleUtteranceSlug: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    localSkillsSection
                    if !configuredMCPServerNames.isEmpty {
                        mcpSkillsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            configuredMCPServerNames = Array(PaceMCPServerRegistry
                .loadConfiguredServers()
                .keys)
                .sorted()
        }
    }

    // MARK: - Header + search

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skills")
                .font(.system(size: 22, weight: .semibold))
            Text("Everything Pace can run. Local skills are built in. MCP servers add extra skills via stdio bridges configured at ~/.config/pace/mcp-servers.json.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var searchField: some View {
        TextField("Search skills…", text: $searchQuery)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 24)
    }

    // MARK: - Local skills

    private var localSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local skills")
                .font(.system(size: 14, weight: .semibold))
            Text("On-device. No network. Always available.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(filteredLocalTools(), id: \.canonicalName) { definition in
                    localSkillRow(definition: definition)
                    Divider().opacity(0.25)
                }
                if filteredLocalTools().isEmpty {
                    Text("No skills match \"\(searchQuery)\".")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func localSkillRow(definition: PaceLocalToolDefinition) -> some View {
        let isCopiedRecently = lastCopiedExampleUtteranceSlug == definition.canonicalName
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(definition.canonicalName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(definition.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\u{201C}\(definition.exampleUtterance)\u{201D}")
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundColor(.primary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(definition.riskLevel.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(riskBadgeBackground(for: definition.riskLevel))
                    .clipShape(Capsule())
                Button(action: {
                    copyExampleUtteranceToClipboard(slug: definition.canonicalName, text: definition.exampleUtterance)
                }) {
                    Image(systemName: isCopiedRecently ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(isCopiedRecently ? "Copied" : "Copy example utterance")
            }
        }
        .padding(.vertical, 10)
    }

    private func riskBadgeBackground(for riskLevel: PaceToolRiskLevel) -> Color {
        switch riskLevel {
        case .readOnly:
            return Color.green.opacity(0.18)
        case .appOrSystemMutation:
            return Color.blue.opacity(0.18)
        case .inputInjection:
            return Color.orange.opacity(0.18)
        case .destructive:
            return Color.red.opacity(0.22)
        case .externalIntegration:
            return Color.purple.opacity(0.18)
        }
    }

    private func filteredLocalTools() -> [PaceLocalToolDefinition] {
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            return PaceToolRegistry.localTools
        }
        return PaceToolRegistry.localTools.filter { definition in
            definition.canonicalName.lowercased().contains(normalizedQuery)
                || definition.description.lowercased().contains(normalizedQuery)
                || definition.exampleUtterance.lowercased().contains(normalizedQuery)
                || definition.aliases.contains { alias in alias.lowercased().contains(normalizedQuery) }
        }
    }

    private func copyExampleUtteranceToClipboard(slug: String, text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastCopiedExampleUtteranceSlug = slug
        // Reset the checkmark after a short delay so the user sees the
        // affirmation but the row goes back to its idle state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if lastCopiedExampleUtteranceSlug == slug {
                lastCopiedExampleUtteranceSlug = nil
            }
        }
    }

    // MARK: - MCP skills

    private var mcpSkillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP servers")
                .font(.system(size: 14, weight: .semibold))
            Text("Configured at ~/.config/pace/mcp-servers.json. Each server adds external skills via the Model Context Protocol.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(spacing: 0) {
                ForEach(filteredMCPServerNames(), id: \.self) { serverName in
                    mcpServerRow(serverName: serverName)
                    Divider().opacity(0.25)
                }
                if filteredMCPServerNames().isEmpty {
                    Text("No MCP servers match \"\(searchQuery)\".")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func mcpServerRow(serverName: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(serverName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("MCP server registered in ~/.config/pace/mcp-servers.json. Pace calls it via stdio JSON-RPC when the planner emits an mcp tool call targeting this server.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(PaceToolRiskLevel.externalIntegration.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.18))
                .clipShape(Capsule())
        }
        .padding(.vertical, 10)
    }

    private func filteredMCPServerNames() -> [String] {
        let normalizedQuery = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return configuredMCPServerNames }
        return configuredMCPServerNames.filter { serverName in
            serverName.lowercased().contains(normalizedQuery)
        }
    }
}
