import SwiftUI

/// The Track capture screen (timer-capture-experience spec): a centered
/// numeric timer whose only purpose is displaying the exact duration while
/// the user enters, starts, or stops a name.
///
/// Content uses the adaptive dual-flow layout (refine-track-recents D1):
/// title → top spacer → completion mark → timer numbers/status → reserved
/// error region → central separator → name field → main action → running
/// tags / Recents → bottom spacer → tab bar, with the top and bottom
/// spacers capped at 48 pt and surplus slack going to the central separator.
/// Track itself has no editing affordance and no offline hint.
///
/// Capture is plain text (remove-activities-layer): no search sheet, no
/// quick-create, no refinement editor, no activity undo — typing is the only
/// input and the recents chips are exact-text shortcuts.
struct TrackView: View {
    @ObservedObject var vm: TrackViewModel
    /// Opens the shared name picker through the owning tab's path
    /// (fix-tab-bar-return-jump). Defaults to no-op for previews.
    var onOpenNamePicker: () -> Void = {}
    /// Opens the running notes editor through the owning tab's path
    /// (fix-tab-bar-return-jump). Defaults to no-op for previews.
    var onOpenNotesEditor: () -> Void = {}
    /// Opens the inline category editor through the owning tab's path
    /// (inline-category-creation). Defaults to no-op for previews.
    var onOpenCategoryEditor: () -> Void = {}

    var body: some View {
        content
            .navigationTitle(L10n.tabTrack.text)
            .navigationBarTitleDisplayMode(.inline)
            // First appear: pull recents + categories and restore a persisted
            // running draft (guarded: re-entry while loading retries on the
            // next appear). Returns to this tab refresh via AppShellView.
            .task { await vm.loadIfNeeded() }
            // Island Stop while this screen is up: the draft is gone under
            // a live `.running` state — reload reconciles back to ready
            // instead of ticking stale (live-activities D8).
            .onReceive(NotificationCenter.default.publisher(for: .timerStoppedExternally)) { _ in
                Task { await vm.load() }
            }
    }

    private var content: some View {
        TrackContent(
            vm: vm,
            onOpenNamePicker: onOpenNamePicker,
            onOpenNotesEditor: onOpenNotesEditor,
            onOpenCategoryEditor: onOpenCategoryEditor
        )
    }
}

#if DEBUG
#Preview("Track — Idle EN Light") {
    TrackContent(vm: .preview())
}

#Preview("Track — Ready EN Light") {
    let categories = [
        Category(id: "preview-c-work", name: "Work", icon: "laptopcomputer"),
        Category(id: "preview-c-study", name: "Study", icon: "book")
    ]
    TrackContent(vm: .preview(
        state: .ready(TrackState.Draft(text: "Deep work", categoryIDs: ["preview-c-work"])),
        recents: [
            ExactName(text: "Deep work", categoryIDs: ["preview-c-work"], firstCategoryID: "preview-c-work")
        ],
        categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    ))
}

#Preview("Track — Running EN Light") {
    TrackContent(vm: .preview(
        state: .running(TrackState.Draft(text: "Reading"), startedAt: Date().addingTimeInterval(-120))
    ))
}

#Preview("Track — Saved EN Light") {
    TrackContent(vm: .preview(
        state: .saved(TrackState.Draft(text: "Reading"), duration: 65)
    ))
}

#Preview("Track — Error EN Light") {
    let vm = TrackViewModel.preview(
        state: .error(TrackState.Draft(text: "Reading"), startedAt: Date().addingTimeInterval(-120))
    )
    vm.errorMessage = L10n.text(in: .default, code: "error.unknown")
    return TrackContent(vm: vm)
}

#Preview("Track — Long Name, Empty Recents") {
    let longName = String(repeating: "Very Long Entry Name ", count: 3)
    TrackContent(vm: .preview(state: .ready(TrackState.Draft(text: longName)), recents: []))
}
#endif
