import OmiTheme
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SettingsContentView {
  var floatingBarSection: some View {
    VStack(spacing: OmiSpacing.xl) {
      settingsCard(settingId: "floatingbar.show") {
        HStack(spacing: OmiSpacing.lg) {
          Text("Show floating bar")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          Toggle("", isOn: $showAskOmiBar)
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
            .onChange(of: showAskOmiBar) { _, newValue in
              // A change that merely mirrors the preference (arriving via
              // `.floatingBarEnabledDidChange`) is already applied; only a user flip acts.
              guard newValue != FloatingControlBarManager.shared.isEnabled else { return }
              if newValue {
                FloatingControlBarManager.shared.show()
              } else {
                FloatingControlBarManager.shared.hide()
              }
            }
        }
      }

      // HIDDEN DELIBERATELY (Nik, 2026-08-25): Notification Previews, Background Style, and
      // Draggable Floating Bar are intentionally not rendered (their stored settings still
      // apply). Product direction, not dead code — do not re-wire without asking Nik.
      // settingsCard(settingId: "floatingbar.notificationpreviews") {
      // HStack(spacing: OmiSpacing.lg) {
      // VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
      // Text("Notification Previews")
      // .scaledFont(size: OmiType.subheading, weight: .semibold)
      // .foregroundColor(Ink.primary)
      // Text(
      // "Show assistant notifications under the Floating Bar. When off, notifications use macOS banners instead."
      // )
      // .scaledFont(size: OmiType.body)
      // .foregroundColor(Ink.secondary)
      // }
      // Spacer()
      // Toggle("", isOn: $shortcutSettings.floatingBarNotificationPreviewsEnabled)
      // .toggleStyle(OmiToggleStyle())
      // }
      // }

      // settingsCard(settingId: "floatingbar.background") {
      // VStack(alignment: .leading, spacing: OmiSpacing.lg) {
      // Text("Background Style")
      // .scaledFont(size: OmiType.subheading, weight: .semibold)
      // .foregroundColor(Ink.primary)
      //
      // HStack(spacing: OmiSpacing.lg) {
      // Text("Transparent")
      // .scaledFont(size: OmiType.body, weight: shortcutSettings.solidBackground ? .regular : .semibold)
      // .foregroundColor(
      // shortcutSettings.solidBackground ? Ink.secondary : Ink.primary)
      //
      // Toggle("", isOn: $shortcutSettings.solidBackground)
      // .toggleStyle(OmiToggleStyle())
      // .labelsHidden()
      //
      // Text("Solid Dark")
      // .scaledFont(size: OmiType.body, weight: shortcutSettings.solidBackground ? .semibold : .regular)
      // .foregroundColor(
      // shortcutSettings.solidBackground ? Ink.primary : Ink.secondary)
      //
      // Spacer()
      // }
      // }
      // }

      // settingsCard(settingId: "floatingbar.draggable") {
      // HStack(spacing: OmiSpacing.lg) {
      // VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
      // Text("Draggable Floating Bar")
      // .scaledFont(size: OmiType.subheading, weight: .semibold)
      // .foregroundColor(Ink.primary)
      // Text("Allow repositioning the floating bar by dragging it.")
      // .scaledFont(size: OmiType.body)
      // .foregroundColor(Ink.secondary)
      // }
      // Spacer()
      // Toggle("", isOn: $shortcutSettings.draggableBarEnabled)
      // .toggleStyle(OmiToggleStyle())
      // }
      // }

      settingsCard(settingId: "floatingbar.typedvoiceanswers") {
        HStack(spacing: OmiSpacing.lg) {
          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text("Typed Questions")
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)
            Text("Speak answers aloud when you submit a typed question from the floating bar.")
              .scaledFont(size: OmiType.body)
              .foregroundColor(Ink.secondary)
          }
          Spacer()
          Toggle("", isOn: floatingBarTypedVoiceAnswersBinding)
            .toggleStyle(OmiToggleStyle())
        }
      }

      settingsCard(settingId: "floatingbar.screenshare") {
        HStack(spacing: OmiSpacing.lg) {
          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text("Screen Sharing in Chat")
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)
            Text("Let Ask Omi capture your screen when you ask about what's on it.")
              .scaledFont(size: OmiType.body)
              .foregroundColor(Ink.secondary)
          }
          Spacer()
          Toggle("", isOn: $chatScreenshotSharingEnabled)
            .toggleStyle(OmiToggleStyle())
            .labelsHidden()
        }
      }

      // Voice replies are always spoken; the voice itself, its speed, and the
      // Live/Transcript distinction live together in Settings → Voice & Models
      // so the speaking model is never confused with the transcription model.
    }
  }

  var shortcutsSection: some View {
    ShortcutsSettingsSection(highlightedSettingId: $highlightedSettingId)
  }

  /// The AI Chat tools that have no other door: the Ask/Act toggle, the
  /// discovered CLAUDE.md files, and the skill list. The provider, workspace,
  /// browser extension, and Dev Mode cards live in AI & Automation
  /// (`aiSetupSubsection`) — one door per setting; this pane used to carry
  /// second copies that had already drifted apart.
  var aiChatSection: some View {
    VStack(spacing: OmiSpacing.xl) {
      // Ask Mode card
      settingsCard(settingId: "aichat.askmode") {
        VStack(alignment: .leading, spacing: OmiSpacing.md) {
          HStack {
            Image(systemName: "bubble.left.and.bubble.right")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            Text("Ask Mode")
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)

            Spacer()

            Toggle("", isOn: $askModeEnabled)
              .toggleStyle(OmiToggleStyle())
              .controlSize(.small)
              .labelsHidden()
          }

          Text(
            "When enabled, shows an Ask/Act toggle in the chat. Ask mode restricts the AI to read-only actions. When disabled, the AI always runs in Act mode."
          )
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
        }
      }

      // Workspace card

      // CLAUDE.md card
      settingsCard(settingId: "aichat.claudemd") {
        VStack(alignment: .leading, spacing: OmiSpacing.md) {
          HStack {
            Image(systemName: "doc.text")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            Text("CLAUDE.md")
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)

            Spacer()
          }

          Text("Reference only — CLAUDE.md content is never injected into chat instructions.")
            .scaledFont(size: OmiType.caption)
            .foregroundColor(Ink.secondary)

          // Global CLAUDE.md
          VStack(alignment: .leading, spacing: OmiSpacing.sm) {
            HStack {
              Text("Global")
                .scaledFont(size: OmiType.caption, weight: .medium)
                .foregroundColor(Ink.secondary)
                .padding(.horizontal, OmiSpacing.xs)
                .padding(.vertical, OmiSpacing.hairline)
                .background(
                  RoundedRectangle(cornerRadius: OmiChrome.stripRadius, style: .continuous)
                    .fill(Ink.wash)
                )

              Spacer()

              if aiChatClaudeMdContent != nil {
                Button("View") {
                  fileViewerTitle = "Global CLAUDE.md"
                  fileViewerContent = aiChatClaudeMdContent ?? ""
                  showFileViewer = true
                }
                .buttonStyle(OmiButtonStyle(.primary, size: .compact))
              }
            }

            if let path = aiChatClaudeMdPath, let content = aiChatClaudeMdContent {
              let sizeKB = Double(content.utf8.count) / 1024.0
              Text("\(path) (\(String(format: "%.1f", sizeKB)) KB)")
                .scaledFont(size: OmiType.caption)
                .foregroundColor(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            } else {
              Text("No CLAUDE.md found at ~/.claude/CLAUDE.md")
                .scaledFont(size: OmiType.caption)
                .foregroundColor(Ink.secondary)
            }
          }

          // Project CLAUDE.md (only show if workspace is set)
          if !aiChatWorkingDirectory.isEmpty {
            GlassSeparator()

            VStack(alignment: .leading, spacing: OmiSpacing.sm) {
              HStack {
                Text("Project")
                  .scaledFont(size: OmiType.caption, weight: .medium)
                  .foregroundColor(Ink.secondary)
                  .padding(.horizontal, OmiSpacing.xs)
                  .padding(.vertical, OmiSpacing.hairline)
                  .background(
                    RoundedRectangle(cornerRadius: OmiChrome.stripRadius, style: .continuous)
                      .fill(Ink.rowFill)
                  )

                Spacer()

                if aiChatProjectClaudeMdContent != nil {
                  Button("View") {
                    fileViewerTitle = "Project CLAUDE.md"
                    fileViewerContent = aiChatProjectClaudeMdContent ?? ""
                    showFileViewer = true
                  }
                  .buttonStyle(OmiButtonStyle(.primary, size: .compact))
                }
              }

              if let path = aiChatProjectClaudeMdPath, let content = aiChatProjectClaudeMdContent {
                let sizeKB = Double(content.utf8.count) / 1024.0
                Text("\(path) (\(String(format: "%.1f", sizeKB)) KB)")
                  .scaledFont(size: OmiType.caption)
                  .foregroundColor(Ink.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              } else {
                Text("No CLAUDE.md found at \(aiChatWorkingDirectory)/CLAUDE.md")
                  .scaledFont(size: OmiType.caption)
                  .foregroundColor(Ink.secondary)
              }
            }
          }
        }
      }

      // Skills card
      settingsCard(settingId: "aichat.skills") {
        VStack(alignment: .leading, spacing: OmiSpacing.md) {
          HStack {
            Image(systemName: "sparkles")
              .scaledFont(size: OmiType.subheading)
              .foregroundColor(Ink.secondary)

            if aiChatProjectDiscoveredSkills.isEmpty {
              Text("Skills (\(aiChatDiscoveredSkills.count) discovered)")
                .scaledFont(size: OmiType.subheading, weight: .semibold)
                .foregroundColor(Ink.primary)
            } else {
              Text(
                "Skills (\(aiChatDiscoveredSkills.count) global + \(aiChatProjectDiscoveredSkills.count) project)"
              )
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)
            }

            Spacer()

            Button(action: { Task { await rediscoverAIChatConfig() } }) {
              Image(systemName: "arrow.clockwise")
                .scaledFont(size: OmiType.body)
            }
            .buttonStyle(OmiButtonStyle(.primary, size: .compact))
          }

          let allSkills: [(skill: (name: String, description: String, path: String), origin: String)] =
            aiChatDiscoveredSkills.map { ($0, "Global") }
            + aiChatProjectDiscoveredSkills.map { ($0, "Project") }

          if allSkills.isEmpty {
            Text("No skills found in ~/.claude/skills/")
              .scaledFont(size: OmiType.caption)
              .foregroundColor(Ink.secondary)
          } else {
            Text("Skill descriptions are included in the AI chat system prompt")
              .scaledFont(size: OmiType.caption)
              .foregroundColor(Ink.secondary)

            // Search field
            HStack(spacing: OmiSpacing.sm) {
              Image(systemName: "magnifyingglass")
                .scaledFont(size: OmiType.caption)
                .foregroundColor(Ink.secondary)

              TextField("Search skills...", text: $skillSearchQuery)
                .textFieldStyle(.plain)
                .scaledFont(size: OmiType.body)
                .foregroundColor(Ink.primary)

              if !skillSearchQuery.isEmpty {
                Button(action: { skillSearchQuery = "" }) {
                  Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: OmiType.caption)
                    .foregroundColor(Ink.secondary)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(OmiSpacing.sm)
            .background(
              RoundedRectangle(cornerRadius: SettingsGlassMetrics.controlRadius, style: .continuous)
                .fill(Ink.wash)
            )

            ScrollView {
              let filteredSkills = allSkills.enumerated().filter { _, item in
                skillSearchQuery.isEmpty
                  || item.skill.name.localizedStandardContains(skillSearchQuery)
                  || item.skill.description.localizedStandardContains(skillSearchQuery)
              }

              VStack(spacing: 0) {
                ForEach(filteredSkills, id: \.element.skill.path) { item in
                  let skill = item.element.skill
                  let origin = item.element.origin
                  HStack(spacing: OmiSpacing.sm) {
                    Toggle(
                      "Enable \(skill.name)",
                      isOn: Binding(
                        get: { !aiChatDisabledSkills.contains(skill.name) },
                        set: { enabled in
                          if enabled {
                            aiChatDisabledSkills.remove(skill.name)
                          } else {
                            aiChatDisabledSkills.insert(skill.name)
                          }
                          saveDisabledSkills()
                        }
                      )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: OmiSpacing.hairline) {
                      HStack(spacing: OmiSpacing.xs) {
                        Text(skill.name)
                          .scaledFont(size: OmiType.body, weight: .medium)
                          .foregroundColor(Ink.primary)

                        // Project beats Global when both define a skill, so the two origins have
                        // to be told apart at a glance. Both branches had collapsed onto
                        // `Ink.secondary` over two washes four thousandths of an alpha apart,
                        // which is the same chip drawn twice. The chip composes its ground from
                        // its own tint, the way `SettingsStatusChip` does, so the pair cannot
                        // drift into a contrast the label does not clear.
                        let originTint = origin == "Project" ? Ink.accent : Ink.secondary
                        Text(origin)
                          .scaledFont(size: OmiType.micro, weight: .medium)
                          .foregroundColor(originTint)
                          .padding(.horizontal, OmiSpacing.xxs)
                          .padding(.vertical, OmiSpacing.hairline)
                          .background(
                            RoundedRectangle(cornerRadius: OmiChrome.stripRadius, style: .continuous)
                              .fill(originTint.opacity(0.14))
                          )
                      }

                      if !skill.description.isEmpty {
                        Text(skill.description)
                          .scaledFont(size: OmiType.caption)
                          .foregroundColor(Ink.secondary)
                          .lineLimit(1)
                          .truncationMode(.tail)
                      }
                    }

                    Spacer()

                    Button("View") {
                      fileViewerTitle = "\(skill.name)/SKILL.md"
                      fileViewerContent =
                        (try? String(contentsOfFile: skill.path, encoding: .utf8))
                        ?? "Unable to read file"
                      showFileViewer = true
                    }
                    .buttonStyle(OmiButtonStyle(.primary, size: .compact))
                  }
                  .padding(.vertical, OmiSpacing.xs)
                  .padding(.horizontal, OmiSpacing.xxs)

                  if item.offset != filteredSkills.last?.offset {
                    GlassSeparator()
                  }
                }
              }
            }
            .frame(maxHeight: 300)
          }
        }
      }
    }
    .onAppear {
      refreshAIChatConfig()
    }
    // The file viewer is this pane's only sheet; the browser-setup sheet is
    // presented by `SettingsContentView.body` because the Browser Extension
    // card lives in AI & Automation.
    .sheet(isPresented: $showFileViewer) {
      fileViewerSheet
    }
  }

  var fileViewerSheet: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text(fileViewerTitle)
          .scaledFont(size: OmiType.subheading, weight: .semibold)
          .foregroundColor(Ink.primary)

        Spacer()

        Button(action: { showFileViewer = false }) {
          Image(systemName: "xmark.circle.fill")
            .scaledFont(size: OmiType.heading)
            .foregroundColor(Ink.secondary)
        }
        .buttonStyle(.plain)
      }
      .padding(OmiSpacing.lg)

      GlassSeparator()

      // Content
      ScrollView {
        Text(fileViewerContent)
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(Ink.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(OmiSpacing.lg)
      }
    }
    .frame(width: 600, height: 500)
    .background(Ink.wash)
  }

  /// Re-scan CLAUDE.md and skills from disk, then republish them into the cards.
  ///
  /// `refreshAIChatConfig()` copies `ChatProvider`'s already-discovered snapshot, so on its own it
  /// cannot see a skill added to `~/.claude/skills` since launch, nor a workspace chosen a moment
  /// ago. Refresh and the workspace picker both *looked* like a rescan and were a re-read of the
  /// same stale answer.
  func rediscoverAIChatConfig() async {
    if let provider = chatProvider {
      await provider.discoverClaudeConfig()
    }
    refreshAIChatConfig()
  }

  func refreshAIChatConfig() {
    // Pull skill and CLAUDE.md data directly from ChatProvider (already discovered at startup).
    // Fall back to reading from disk only when ChatProvider is unavailable.
    if let provider = chatProvider {
      aiChatClaudeMdContent = provider.claudeMdContent
      aiChatClaudeMdPath = provider.claudeMdPath
      aiChatDiscoveredSkills = provider.discoveredSkills
      aiChatProjectClaudeMdContent = provider.projectClaudeMdContent
      aiChatProjectClaudeMdPath = provider.projectClaudeMdPath
      aiChatProjectDiscoveredSkills = provider.projectDiscoveredSkills
      loadDisabledSkills()
      return
    }

    // Fallback: read from disk (used when Settings is shown before ChatProvider initializes)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let claudeDir = "\(home)/.claude"

    let mdPath = "\(claudeDir)/CLAUDE.md"
    if FileManager.default.fileExists(atPath: mdPath),
      let content = try? String(contentsOfFile: mdPath, encoding: .utf8)
    {
      aiChatClaudeMdContent = content
      aiChatClaudeMdPath = mdPath
    } else {
      aiChatClaudeMdContent = nil
      aiChatClaudeMdPath = nil
    }

    var skills: [(name: String, description: String, path: String)] = []
    let skillsDir = "\(claudeDir)/skills"
    if let skillDirs = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) {
      for dir in skillDirs.sorted() {
        let skillPath = "\(skillsDir)/\(dir)/SKILL.md"
        if FileManager.default.fileExists(atPath: skillPath),
          let content = try? String(contentsOfFile: skillPath, encoding: .utf8)
        {
          let desc = ChatProvider.extractSkillDescription(from: content)
          skills.append((name: dir, description: desc, path: skillPath))
        }
      }
    }
    aiChatDiscoveredSkills = skills

    let workspace = aiChatWorkingDirectory
    if !workspace.isEmpty, FileManager.default.fileExists(atPath: workspace) {
      let projectMdPath = "\(workspace)/CLAUDE.md"
      if FileManager.default.fileExists(atPath: projectMdPath),
        let content = try? String(contentsOfFile: projectMdPath, encoding: .utf8)
      {
        aiChatProjectClaudeMdContent = content
        aiChatProjectClaudeMdPath = projectMdPath
      } else {
        aiChatProjectClaudeMdContent = nil
        aiChatProjectClaudeMdPath = nil
      }

      var projectSkills: [(name: String, description: String, path: String)] = []
      let projectSkillsDir = "\(workspace)/.claude/skills"
      if let skillDirs = try? FileManager.default.contentsOfDirectory(atPath: projectSkillsDir) {
        for dir in skillDirs.sorted() {
          let skillPath = "\(projectSkillsDir)/\(dir)/SKILL.md"
          if FileManager.default.fileExists(atPath: skillPath),
            let content = try? String(contentsOfFile: skillPath, encoding: .utf8)
          {
            let desc = ChatProvider.extractSkillDescription(from: content)
            projectSkills.append((name: dir, description: desc, path: skillPath))
          }
        }
      }
      aiChatProjectDiscoveredSkills = projectSkills
    } else {
      aiChatProjectClaudeMdContent = nil
      aiChatProjectClaudeMdPath = nil
      aiChatProjectDiscoveredSkills = []
    }

    loadDisabledSkills()
  }

  func loadDisabledSkills() {
    let json = UserDefaults.standard.string(forKey: "disabledSkillsJSON") ?? ""
    guard let data = json.data(using: .utf8),
      let names = try? JSONDecoder().decode([String].self, from: data)
    else {
      aiChatDisabledSkills = []  // Default: nothing disabled = all enabled
      return
    }
    aiChatDisabledSkills = Set(names)
  }

  func saveDisabledSkills() {
    if let data = try? JSONEncoder().encode(Array(aiChatDisabledSkills)),
      let json = String(data: data, encoding: .utf8)
    {
      UserDefaults.standard.set(json, forKey: "disabledSkillsJSON")
    }
  }

  // MARK: - About Section

  // MARK: - Advanced Section

  struct UserStats {
    let conversations: Int
    let appsInstalled: Int
    let screenshotsTotal: Int
    let focusSessions: Int
    let tasksTodo: Int
    let tasksDone: Int
    let tasksDeleted: Int
    let goalsCount: Int
    let memoriesTotal: Int
  }

}
