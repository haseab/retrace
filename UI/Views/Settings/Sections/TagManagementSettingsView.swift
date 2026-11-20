import SwiftUI
import Shared
import AppKit
import App
import Database
import Carbon.HIToolbox
import ScreenCaptureKit
import SQLCipher
import ServiceManagement
import Darwin
import Carbon
import UniformTypeIdentifiers

extension SettingsView {
    var tagManagementSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            manageTagsCard
        }
        .task {
            await loadTagsForSettings()
        }
        .alert("Delete Tag", isPresented: $showTagDeleteConfirmation, presenting: tagToDelete) { tag in
            Button("Cancel", role: .cancel) {
                tagToDelete = nil
            }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteTag(tag)
                }
            }
        } message: { tag in
            let count = tagSegmentCounts[tag.id] ?? 0
            if count == 0 {
                Text("This tag is not applied to any segments.")
            } else {
                Text("This tag is applied to \(count) segment\(count == 1 ? "" : "s"). The segments will remain, but the tag will be removed from them.")
            }
        }
    }

    // MARK: - Tags Cards (extracted for search)

    @ViewBuilder
    var manageTagsCard: some View {
        ModernSettingsCard(title: "Manage Tags", icon: "tag") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Create and manage tags for organizing your recordings. Choose a color for each tag to make it easier to scan across the app.")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)

                    // Create tag section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Tag name", text: $newTagName)
                                .textFieldStyle(.plain)
                                .font(.retraceCallout)
                                .foregroundColor(.retracePrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.retraceSecondary.opacity(0.05))
                                .cornerRadius(8)
                                .disabled(isCreatingTag)
                                .onSubmit {
                                    Task {
                                        await createTag()
                                    }
                                }

                            ColorPicker("Tag color", selection: $newTagColor, supportsOpacity: false)
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 40, height: 22)
                                .disabled(isCreatingTag)

                            ModernButton(
                                title: isCreatingTag ? "Creating..." : "Create Tag",
                                icon: "plus",
                                style: .secondary
                            ) {
                                Task {
                                    await createTag()
                                }
                            }
                            .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty || isCreatingTag)
                        }

                        if let error = tagCreationError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.retraceWarning)
                                    .font(.system(size: 12))
                                Text(error)
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceWarning)
                            }
                            .transition(.opacity)
                        }
                    }

                    if !tagsForSettings.isEmpty {
                        Divider()
                            .background(Color.retraceBorder)
                            .padding(.vertical, 4)

                        VStack(spacing: 0) {
                            ForEach(tagsForSettings, id: \.id) { tag in
                                tagRow(for: tag)

                                if tag.id != tagsForSettings.last?.id {
                                    Divider()
                                        .background(Color.retraceBorder)
                                }
                            }
                        }
                    } else {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "tag.slash")
                                    .font(.system(size: 24))
                                    .foregroundColor(.retraceSecondary.opacity(0.5))
                                Text("No tags created yet")
                                    .font(.retraceCaption2)
                                    .foregroundColor(.retraceSecondary.opacity(0.6))
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                }
            }
        }

    func tagRow(for tag: Tag) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tagColorBinding(for: tag).wrappedValue)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                let count = tagSegmentCounts[tag.id] ?? 0
                Text("\(count) segment\(count == 1 ? "" : "s")")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            ColorPicker("Tag color", selection: tagColorBinding(for: tag), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 40, height: 22)

            Button {
                tagToDelete = tag
                showTagDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.retraceSecondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 8)
    }

    func tagColorBinding(for tag: Tag) -> Binding<Color> {
        Binding(
            get: {
                tagColorsForSettings[tag.id] ?? TagColorStore.color(for: tag)
            },
            set: { newColor in
                tagColorsForSettings[tag.id] = newColor
                TagColorStore.setColor(newColor, for: tag.id)
            }
        )
    }

    func loadTagsForSettings() async {
        let coordinator = coordinatorWrapper.coordinator

        do {
            let allTags = try await coordinator.getAllTags()
            // Filter out the hidden system tag
            let userTags = allTags.filter { !$0.isHidden }
            let validTagIDs = Set(userTags.map { $0.id.value })
            TagColorStore.pruneColors(keeping: validTagIDs)

            // Get segment counts for each tag
            var counts: [TagID: Int] = [:]
            for tag in userTags {
                counts[tag.id] = try await coordinator.getSegmentCountForTag(tagId: tag.id)
            }

            let colors: [TagID: Color] = userTags.reduce(into: [:]) { map, tag in
                map[tag.id] = TagColorStore.color(for: tag)
            }

            await MainActor.run {
                self.tagsForSettings = userTags
                self.tagSegmentCounts = counts
                self.tagColorsForSettings = colors
            }
        } catch {
            Log.error("[Settings] Failed to load tags: \(error)", category: .ui)
        }
    }

    func deleteTag(_ tag: Tag) async {
        let coordinator = coordinatorWrapper.coordinator

        do {
            try await coordinator.deleteTag(tagId: tag.id)
            TagColorStore.removeColor(for: tag.id)
            await MainActor.run {
                _ = tagColorsForSettings.removeValue(forKey: tag.id)
            }
            await loadTagsForSettings()
        } catch {
            Log.error("[Settings] Failed to delete tag: \(error)", category: .ui)
        }
    }

    func createTag() async {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let selectedColor = newTagColor

        await MainActor.run {
            isCreatingTag = true
            tagCreationError = nil
        }

        let coordinator = coordinatorWrapper.coordinator

        do {
            // Check if tag already exists
            if try await coordinator.getTag(name: trimmedName) != nil {
                await MainActor.run {
                    tagCreationError = "Tag '\(trimmedName)' already exists"
                    isCreatingTag = false
                }
                return
            }

            // Create the tag
            let createdTag = try await coordinator.createTag(name: trimmedName)
            TagColorStore.setColor(selectedColor, for: createdTag.id)

            await MainActor.run {
                newTagName = ""
                tagColorsForSettings[createdTag.id] = selectedColor
                isCreatingTag = false
            }

            // Reload the tags list
            await loadTagsForSettings()

            // Clear error after success (with delay)
            try? await Task.sleep(for: .nanoseconds(Int64(3_000_000_000)), clock: .continuous)
            await MainActor.run {
                tagCreationError = nil
            }
        } catch {
            await MainActor.run {
                tagCreationError = "Failed to create tag: \(error.localizedDescription)"
                isCreatingTag = false
            }
            Log.error("[Settings] Failed to create tag: \(error)", category: .ui)
        }
    }

    // MARK: - Search Settings
    // TODO: Add Search settings later
//    var searchSettings: some View {
//        VStack(alignment: .leading, spacing: 20) {
//            ModernSettingsCard(title: "Search Behavior", icon: "magnifyingglass") {
//                ModernToggleRow(
//                    title: "Show suggestions as you type",
//                    subtitle: "Display search suggestions in real-time",
//                    isOn: .constant(true)
//                )
//
//                ModernToggleRow(
//                    title: "Include audio transcriptions",
//                    subtitle: "Search through transcribed audio content",
//                    isOn: .constant(false),
//                    disabled: true,
//                    badge: "Coming Soon"
//                )
//            }
//
//            ModernSettingsCard(title: "Results", icon: "list.bullet.rectangle") {
//                VStack(alignment: .leading, spacing: 16) {
//                    HStack {
//                        Text("Default result limit")
//                            .font(.retraceCalloutMedium)
//                            .foregroundColor(.retracePrimary)
//                        Spacer()
//                        Text("50")
//                            .font(.retraceCalloutBold)
//                            .foregroundColor(.white)
//                            .padding(.horizontal, 12)
//                            .padding(.vertical, 6)
//                            .background(Color.retraceAccent.opacity(0.3))
//                            .cornerRadius(8)
//                    }
//
//                    ModernSlider(value: .constant(50), range: 10...200, step: 10)
//                }
//            }
//
//            ModernSettingsCard(title: "Ranking", icon: "chart.bar") {
//                VStack(alignment: .leading, spacing: 12) {
//                    HStack {
//                        Text("Relevance")
//                            .font(.retraceCaptionMedium)
//                            .foregroundColor(.retraceSecondary)
//                        Spacer()
//                        Text("Recency")
//                            .font(.retraceCaptionMedium)
//                            .foregroundColor(.retraceSecondary)
//                    }
//
//                    ModernSlider(value: .constant(0.7), range: 0...1, step: 0.1)
//                }
//            }
//        }
//    }

    // MARK: - Advanced Settings
}
