import SwiftUI

/// The category editor form (Design/SCREENS/CategoryEditor.md,
/// inline-category-creation D3): name field, catalog icon grid, field
/// validation, toolbar X/✓ grammar, and delete flow — without any
/// presentation chrome. The sheet wrapper (`CategoryEditorView`) hosts it in
/// its own `NavigationStack`; push hosts (entry form, Track) render it
/// directly as a `navigationDestination`. Both presentations share one
/// behavior owner: this form plus `CategoryEditorViewModel`.
///
/// Save dismissal is self-contained: on success the form dismisses itself
/// through the environment — closing the sheet in sheet hosts, popping the
/// push in push hosts. Callers' `onSaved`/`onDuplicate` do host bookkeeping
/// only (reload, select, conflict copy) and never dismiss.
struct CategoryEditorForm: View {
    @StateObject private var vm: CategoryEditorViewModel
    @Environment(\.dismiss)
    private var dismiss
    @FocusState private var isNameFocused: Bool
    /// Drives the delete confirmation alert (edit mode).
    @State private var isShowingDeleteConfirm = false
    /// Called after a confirmed deletion so the presenter can reload.
    private let onDeleted: (() -> Void)?
    /// Whether the toolbar shows the X dismiss button. True in the sheet
    /// host (no back stack — X is the only exit); false on push hosts,
    /// where the system Back button cancels (LogTime pushed-form parity).
    private let showsDismiss: Bool

    init(
        store: LocalStore,
        category: Category?,
        onSaved: @escaping (Category) -> Void,
        onDuplicate: @escaping (Category) -> Void,
        onDeleted: (() -> Void)? = nil,
        showsDismiss: Bool = true
    ) {
        _vm = StateObject(wrappedValue: CategoryEditorViewModel(
            store: store,
            category: category,
            onSaved: onSaved,
            onDuplicate: onDuplicate
        ))
        self.onDeleted = onDeleted
        self.showsDismiss = showsDismiss
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLarge) {
                TextFieldWithError(
                    title: L10n.categoryEditorNameLabel.text,
                    placeholder: L10n.categoryEditorNamePlaceholder.text,
                    text: $vm.name,
                    error: vm.fieldErrors.name,
                    keyboardType: .default,
                    textContentType: nil,
                    submitLabel: .done,
                    autocapitalization: .sentences,
                    accessibilityId: "CategoryEditorNameField",
                    onSubmit: { isNameFocused = false },
                    focused: $isNameFocused,
                    showClear: ClearButtonVisibility.shouldShow(
                        isFocused: isNameFocused,
                        text: vm.name
                    ),
                    onClear: { vm.name = "" },
                    clearAccessibilityId: "CategoryNameClearButton",
                    clearAccessibilityLabel: L10n.nameClear.text
                )
                .onChange(of: vm.name) {
                    vm.nameDidChange()
                }

                VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                    Text(L10n.categoryEditorIconLabel.text)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    IconPickerGrid(
                        options: iconOptions,
                        selection: Binding(
                            get: { vm.icon.rawValue },
                            set: { vm.icon = CatalogIcon(validated: $0) }
                        ),
                        accessibilityId: "CategoryEditorIcon"
                    )
                }

                if let errorMessage = vm.errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        accessibilityId: "CategoryEditorErrorBanner"
                    )
                }

                if !vm.isCreateMode {
                    deleteSection
                }
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.vertical, Theme.spacingMedium)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle(vm.isCreateMode ? L10n.categoryEditorCreateTitle.text : L10n.categoryEditorEditTitle.text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Calendar grammar (Log Time parity): X dismisses, checkmark
            // saves. The checkmark mirrors the old Save bar's gate.
            EditorToolbar(
                showsDismiss: showsDismiss,
                dismissAccessibilityLabel: L10n.categoryEditorDismissLabel.text,
                dismissAccessibilityId: "CategoryEditorCancelButton",
                isDismissDisabled: vm.isLoading,
                onDismiss: dismiss(),
                showsConfirm: true,
                confirmAccessibilityLabel: L10n.categoryEditorConfirmSaveLabel.text,
                confirmAccessibilityId: "CategoryEditorSaveButton",
                isConfirmDisabled: !vm.canSave
            ) {
                vm.save()
            }
        }
        // Scroll-away dismisses the keyboard (native interactive behavior).
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(vm.isLoading)
        // Sheet parity on push hosts: gate the system Back while a save is
        // in flight (hides the chevron and disables the pop gesture), so a
        // mid-save pop cannot race the committing Task.
        .navigationBarBackButtonHidden(vm.isLoading)
        .task {
            // Autofocus waits out the presentation (issue #82, NamePicker
            // precedent): focusing instantly fires the keyboard
            // mid-animation, and the keyboard-driven auto-scroll computes
            // against moving layout, landing the field partly out of
            // viewport. Cancelled automatically on dismiss.
            guard await FocusDelay.settle() else { return }
            isNameFocused = true
        }
        .alert(
            L10n.deleteCategoryTitle.text,
            isPresented: $isShowingDeleteConfirm
        ) {
            Button(L10n.deleteCategoryConfirm.text, role: .destructive) {
                Task { await deleteCategory() }
            }
            Button(L10n.categoryEditorCancel.text, role: .cancel) {}
        } message: {
            Text(String(format: L10n.deleteCategoryMessage.text, vm.name))
        }
        // Dismiss only after a successful save. Duplicate and stale
        // outcomes keep the editor open with actionable context.
        .onChange(of: vm.isSavedOrDuplicate) { _, saved in
            if saved {
                dismiss()
            }
        }
    }

    // MARK: - Delete

    /// Bottom-of-page destructive Delete (edit mode only). Mirrors the entry
    /// form's delete section.
    private var deleteSection: some View {
        DestructiveBottomButton(
            title: L10n.categoryEditorDelete.text,
            accessibilityId: "CategoryEditorDeleteButton"
        ) {
            guard !vm.isLoading else { return }
            isShowingDeleteConfirm = true
        }
        .disabled(vm.isLoading)
    }

    /// Deletes the category into the durable undo buffer; notifies the
    /// presenter and dismisses on success. On failure the editor stays open
    /// with the error banner.
    private func deleteCategory() async {
        if await vm.deleteConfirmed() {
            onDeleted?()
            dismiss()
        }
    }

    /// Keeps a valid synchronized icon visible in the picker even when the
    /// current OS cannot render it. The cell displays the `tag` fallback while
    /// preserving the stored raw value until the user explicitly changes it.
    private var iconOptions: [String] {
        let selected = vm.icon.rawValue
        guard CatalogIcon.canRender(selected) || !CatalogIcon.allSymbols.contains(selected) else {
            return CatalogIcon.renderableSymbols + [selected]
        }
        return CatalogIcon.renderableSymbols
    }
}

#if DEBUG
#Preview("Category Editor Form — Pushed Create EN") {
    let container = AppContainer.production()
    NavigationStack {
        CategoryEditorForm(
            store: container.localStore,
            category: nil,
            onSaved: { _ in },
            onDuplicate: { _ in },
            showsDismiss: false
        )
    }
    .environmentObject(container)
}
#endif
