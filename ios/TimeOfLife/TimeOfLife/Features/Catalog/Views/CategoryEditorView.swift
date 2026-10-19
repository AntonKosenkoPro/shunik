import SwiftUI

/// The shared Category Editor sheet (Design/SCREENS/CategoryEditor.md,
/// category-management D4): full-height sheet hosting the pushable
/// `CategoryEditorForm` in its own `NavigationStack` with Log Time toolbar
/// chrome (X dismiss, checkmark save), compact name field, catalog icon
/// grid, and field validation. Create mode starts with an empty name and
/// the default `tag` icon; edit mode prefills from the passed-in category.
///
/// Push hosts (entry form, Track) render `CategoryEditorForm` directly as a
/// `navigationDestination` instead of using this wrapper — one form, one
/// view model, identical behavior in both presentations
/// (inline-category-creation D3).
struct CategoryEditorView: View {
    private let store: LocalStore
    private let category: Category?
    private let onSaved: (Category) -> Void
    private let onDuplicate: (Category) -> Void
    private let onDeleted: (() -> Void)?

    init(
        store: LocalStore,
        category: Category?,
        onSaved: @escaping (Category) -> Void,
        onDuplicate: @escaping (Category) -> Void,
        onDeleted: (() -> Void)? = nil
    ) {
        self.store = store
        self.category = category
        self.onSaved = onSaved
        self.onDuplicate = onDuplicate
        self.onDeleted = onDeleted
    }

    var body: some View {
        NavigationStack {
            CategoryEditorForm(
                store: store,
                category: category,
                onSaved: onSaved,
                onDuplicate: onDuplicate,
                onDeleted: onDeleted
            )
        }
    }
}

#if DEBUG
#Preview("Category Editor — Create EN Light") {
    let container = AppContainer.production()
    CategoryEditorView(
        store: container.localStore,
        category: nil,
        onSaved: { _ in },
        onDuplicate: { _ in }
    )
    .environmentObject(container)
}

#Preview("Category Editor — Edit RU Dark") {
    let container = AppContainer.production()
    CategoryEditorView(
        store: container.localStore,
        category: TimeOfLife.Category(
            id: "preview", name: L10n.categorySeedSport.text, icon: "figure.run",
            createdAt: Date(), updatedAt: Date()
        ),
        onSaved: { _ in },
        onDuplicate: { _ in }
    )
    .environmentObject(container)
    .preferredColorScheme(.dark)
    .environment(\.locale, .init(identifier: "ru"))
}
#endif
