# Fullscreen Timeline Refactor Summary

Last updated: 2026-04-14

## Outcome

The fullscreen timeline refactor is in consolidation mode. Current threshold goal is met: all `SimpleTimelineView*` files and associated fullscreen timeline production files are under 800 lines while ownership stays in the stores.

The original goal was to break the `SimpleTimelineView*` monolith into a smaller number of real subsystem owners without replacing it with helper-file sprawl. The final shape is still centered on a coordinator-style [SimpleTimelineViewModel.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/SimpleTimelineViewModel.swift) and the root shell [SimpleTimelineView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/SimpleTimelineView.swift), but the high-risk ownership seams now live behind coherent stores and same-file view compositions instead of being scattered inline.

Current key sizes:
- [SimpleTimelineViewModel.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/SimpleTimelineViewModel.swift): `788` lines
- [SimpleTimelineView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/SimpleTimelineView.swift): `560` lines
- [TimelineCommentSubmenu.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineCommentSubmenu.swift): `642` lines
- [TimelineFilterPanel.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineFilterPanel.swift): `384` lines
- [TimelineFilterDropdownHost.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineFilterDropdownHost.swift): `356` lines
- [TimelineTapeView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineTapeView.swift): `738` lines
- [TimelineFrameWindowStore.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineFrameWindowStore.swift): `295` lines
- [TimelineFrameWindowStateController.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineFrameWindowStateController.swift): `469` lines

Current file count:
- Swift files under [UI/ViewModels](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels) plus [UI/Views/FullscreenTimeline](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline): `117`

## Final Architecture

### Screen Shell

- [SimpleTimelineView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/SimpleTimelineView.swift)
  Root fullscreen timeline shell, frame-surface composition, chrome overlays, and screen lifecycle wiring.
- [TimelineTapeView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineTapeView.swift)
  Tape rendering, playhead layout, tape-local interaction, and date-jump/calendar presentation.
- [TimelineWindowController.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineWindowController.swift)
  Window lifecycle, AppKit monitor ownership, Escape/key routing, scroll ownership, and hide/show behavior.
- [TimelineSegmentContextMenu.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineSegmentContextMenu.swift)
  Tape context-menu presentation and shared tag/comment context actions.

### ViewModel Ownership

- [SimpleTimelineViewModel.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/SimpleTimelineViewModel.swift)
  Screen-level coordinator over the timeline stores plus inline media, overlay, viewport, zoom, selection, chrome, and shell state owners.
- [TimelineFrameWindowStore.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineFrameWindowStore.swift)
  Window replacement, paging, trim policy, optimistic frame mutation, boundary fallback, and refresh policy.
- [TimelineFilterStore.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineFilterStore.swift)
  Filter session state, filter support data, app lists, persistence, and cache behavior.
- [TimelineCommentsStore.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineCommentsStore.swift)
  Comment timeline/search/thread state, tag indicators, overlay state, comment creation, and snapshot fallout.
- [SimpleTimelineViewModel+PlaybackAndDateSearch.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/SimpleTimelineViewModel+PlaybackAndDateSearch.swift)
  Playback, tape interaction, and date-jump support.
- [TimelineDebugTestHooks.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineDebugTestHooks.swift)
  Timeline-only debug and test seams that do not belong in the main production state bag.

### Comment Subsystem

- [TimelineCommentSubmenu.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineCommentSubmenu.swift)
- [TimelineCommentAllCommentsHost.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineCommentAllCommentsHost.swift)
- [TimelineCommentCards.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineCommentCards.swift)
- [CommentMarkdownEditor.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/CommentMarkdownEditor.swift)

Comment UI is intentionally held to one submenu shell, one all-comments/browser host, one cards/presentation file, and one shared markdown editor.

### Filter Subsystem

- [TimelineFilterPanel.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineFilterPanel.swift)
- [TimelineFilterDropdownHost.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/TimelineFilterDropdownHost.swift)
- [TimelineFilterStore.swift](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels/TimelineFilterStore.swift)

Filter UI is intentionally held to one panel shell, one dropdown host, and one store.

### Search And Sidecar UI

- [SpotlightSearchOverlay.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/SpotlightSearchOverlay.swift)
- [SearchFilterBar.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/SearchFilterBar.swift)
- [StandaloneQuickCommentView.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/StandaloneQuickCommentView.swift)
- [StandaloneCommentComposerWindowController.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/StandaloneCommentComposerWindowController.swift)
- [CommentComposerChrome.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/CommentComposerChrome.swift)
- [CommentContextPreviewCard.swift](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline/CommentContextPreviewCard.swift)

## Refactor Results

Completed architecture passes:
- ViewModel state ownership finalization
- Frame surface and overlay completion
- Tape, navigation, and window-controller finalization
- Comments, filters, and timeline sidecar consolidation
- File-count reduction
- Stability and regression hardening

Notable closeout changes:
- dead fullscreen-timeline production files were deleted instead of being left as compatibility residue
- [UI/AGENTS.md](/Users/haseab/Desktop/retrace-wt-7/UI/AGENTS.md) was trimmed back to subsystem-level guidance
- the previous migration diary was replaced by this steady-state architecture summary

## Verification Baseline

Required verification for future fullscreen timeline work:

1. Build:
```bash
swift build
```

2. Mixed baseline:
```bash
swift test --filter 'InFrameSearchTests|TimelineHeadlessPrerenderStateTests|HyperlinkResolutionTests|SearchHighlightQueryParsingTests|TimelineFilteredEmptyStateTests|TimelineRefreshTrimRegressionTests|DateJumpFrameIDFallbackTests|CommandDragTextSelectionTests'
```

3. Store ownership / timeline behavior slice:
```bash
swift test --filter 'TimelineCommentOverlaySessionControllerTests|TimelineCommentThreadSessionControllerTests|TimelineCommentSearchControllerTests|TimelineCommentTimelineControllerTests|TimelineTagIndicatorStateControllerTests|CommentComposerTargetContextTests|TimelineFilterSupportDataControllerTests|TimelineFilterSessionControllerTests|TimelineFilterStateSupportTests|SearchViewModelAvailableAppsTests|TimelineBoundaryOlderFallbackTests|TimelineBoundaryNewerFallbackTests|TimelineRefreshTrimRegressionTests|TimelineFilteredEmptyStateTests|TimelineFrameWindowTrimSupportTests|DateJumpFrameIDFallbackTests'
```

4. Shell / chrome / navigation slice:
```bash
swift test --filter 'TimelineHeadlessPrerenderStateTests|TimelineKeyboardShortcutDecisionTests|TimelineNavigationShortcutDecisionTests|TimelinePositionRecoveryHintTests|SearchHighlightTooltipTests|TimelineCopyFeedbackTests'
```

Finish-6 closeout verification on 2026-04-13:
- `swift build`
- mixed baseline: passed
- store ownership / timeline behavior slice: `69` tests passed
- shell / chrome / navigation slice: `67` tests passed

## Maintenance Rules

- Keep ownership in the existing stores and inline state owners; do not route state back through ad-hoc VM bridges.
- Do not add production files under [UI/Views/FullscreenTimeline](/Users/haseab/Desktop/retrace-wt-7/UI/Views/FullscreenTimeline) or the timeline area of [UI/ViewModels](/Users/haseab/Desktop/retrace-wt-7/UI/ViewModels) unless the same pass deletes or merges more production files than it adds.
- Prefer subsystem-level units over micro-files.
- If the fullscreen timeline file inventory changes, update [UI/AGENTS.md](/Users/haseab/Desktop/retrace-wt-7/UI/AGENTS.md) in the same change.
- Treat this file as a finished architecture summary, not a migration diary.
