# Category Editor Screen

Implements F2/U1/U2 of `Requirements/FURPS/Activity_Catalog_and_Categories.md`. Shared editor for creating and editing a category: the `CategoryEditorForm` (name + icon + validation + toolbar grammar, no presentation chrome) hosted either as a full-height `.sheet` (`CategoryEditorView`, reached from Manage Categories) or pushed as a `navigationDestination` (inline creation from the entry form and the running-tag row). Per decision D21.

---

## Screen: CategoryEditorView (sheet host)

- **File**: `ios/TimeOfLife/TimeOfLife/Features/Catalog/Views/CategoryEditorView.swift` (thin wrapper; behavior lives in `CategoryEditorForm.swift`)
- **Route**: presented as a `.sheet`. Create / edit modes.
- **ViewModel**: `CategoryEditorViewModel`

### Layout

Full-height `.sheet` (no detents — closed or fully open). `ScrollView` → `VStack(spacing: Theme.spacingLarge)` with horizontal padding `Theme.screenHorizontalPadding`, vertical padding `Theme.spacingMedium`, and `Theme.maxContentWidth`:

1. Inline navigation title via the view's own `NavigationStack` (Log Time parity — no collapsing large title). Create: `L10n.categoryEditorCreateTitle`; edit: `L10n.categoryEditorEditTitle`. Toolbar: `xmark` at `.cancellationAction` (dismiss, `CategoryEditorCancelButton`, VoiceOver `L10n.categoryEditorDismissLabel`) and `checkmark` at `.confirmationAction` (save, `CategoryEditorSaveButton`, VoiceOver `L10n.categoryEditorConfirmSaveLabel`, disabled while the draft is invalid or saving).
2. `TextFieldWithError` for name:
   - `accessibilityId`: `CategoryEditorNameField`
   - title / placeholder: `L10n.categoryEditorNameLabel` / `L10n.categoryEditorNamePlaceholder`
   - `submitLabel`: `.done`
   - `autocapitalization`: `.sentences`
   - error: `vm.fieldErrors.name`
   - Focused on appear, after the sheet presentation settles (a short settle delay keeps keyboard-driven auto-scroll on final layout).
3. `SectionHeader(L10n.categoryEditorIconLabel)` + `IconPickerGrid(options: CatalogIcon.renderableSymbols, selection: $vm.icon, accessibilityId: "CategoryEditorIcon")`. A valid synchronized icon unavailable on the current OS remains selected by raw value and is displayed with the `tag` fallback until the user changes it.
4. `ErrorBanner` if `vm.errorMessage != nil`:
   - `accessibilityId`: `CategoryEditorErrorBanner`
5. Reserve matching the measured pinned bottom action bar height.

Background: `Theme.backgroundPrimary`.

The save action lives in the toolbar (`checkmark`, gated on a valid draft and idle state) — there is no pinned bottom bar. Cancel via the toolbar `xmark` and swipe-down; both dismiss paths are disabled while saving.

### Keyboard handling

Follows `Design/INTERACTIONS.md` → **Editor sheets and keyboard placement** (D13 / D21). The name field sits in the upper scrollable area, focused on appear (after the presentation settles). The `checkmark` save action lives in the always-visible toolbar so it stays tappable with the keyboard open. Dismiss the sheet on save success or cancel; do not leave the keyboard up after save.

### Behaviors

- Focus the name field on appear.
- Validate (U1/U2): name non-empty and ≤ 60 chars → unified `validation.name*` message; collapse multiple rules into a single message per field (U2).
- Edit mode pre-fills `vm.name` and `vm.icon` from the passed-in `Category`.
- On 422 show field errors beneath the name field.
- On a normalized duplicate, keep the editor open with the draft intact, show `L10n.errorCategoryExists`, and allow correction. Relay collision recovery remaps local references to the surviving id in `SyncController`.
- Save success: dismiss the sheet. The new category is available in the `TagSelector` options immediately.
- Clear field error when `vm.name` changes.
- Disable Save while `vm.isLoading` or name is empty/whitespace-only.

### Push hosting (inline-category-creation)

- The same `CategoryEditorForm` renders as a `navigationDestination`: the entry form pushes it on the nearest stack (CREATE sheet's internal stack, History stack for pushed EDIT forms) via a local `navigationDestination(isPresented:)`; Track pushes it on `trackPath` via the `ShellRoute.categoryEditor` value. Never a stacked sheet.
- Pushed editor shows no toolbar X — the system Back button is the only cancel (LogTime pushed-form parity); the sheet keeps X. Save pops the push via the form's own self-dismissal; the host's `onSaved` only attaches the new category (entry-form `categoryIDs` / running draft, tap-ordered) and reloads options. Duplicates keep the editor open with the banner everywhere — no winner-selection shortcut.
- The creation chip that opens the editor is reachable only while the timer runs or from the entry form; in non-running Track states the slot shows Recents and the tag row is hidden and ignores hits.

### Delete flow (unify-catalog-deletion, edit mode only)

The editor is the single deletion chokepoint for categories (the Manage
Categories list offers no delete affordance): a bottom destructive Delete
button (`CategoryEditorDeleteButton`, `Theme.danger`, entry-form grammar)
opens the tag-only destructive confirmation alert (`L10n.deleteCategoryTitle`
/ message naming the category, entries kept, until-restart shake hint). Confirming
enters the durable undo buffer (category + ordered entry assignments, no
outbox row), notifies the presenter via `onDeleted`, and dismisses; the list
reloads. `deleteConfirmed` shares the save `isLoading` gate (refuses while busy,
sets `true` / `defer` `false`), matching the disabled save/dismiss paths above,
so a mid-delete dismiss cannot swallow the failure banner. The Delete button
itself is disabled while `vm.isLoading` (`.disabled(vm.isLoading)` plus an
action `guard !vm.isLoading`), so the confirmation alert is unreachable while
busy instead of presenting and then being silently refused. Until the app restarts, the system Undo confirmation on Manage Categories
restores identity + assignments; a restart commits the hard delete on
cold launch. Create mode offers no Delete.

### States

| State | Visual |
|---|---|
| Create | Empty name field, default `tag` icon selected, Save disabled (name empty) |
| Edit | Name + icon pre-filled from the existing `Category`, Save enabled |
| Saving | Save button shows `ProgressView`; fields and swatches disabled |
| Validation error | Name field border + error label in `Theme.danger`; Save disabled if name empty/invalid |
| Duplicate name | Editor remains open with the draft and a localized correction error |

### Data model

```swift
struct CategoryEditorDraft {
    var name: String
    var icon: CatalogIcon?
}

struct Category: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var icon: CatalogIcon
    var updatedAt: Date
}
```

- The draft holds `name` and `icon`.
- On save, the ViewModel produces a `Category`: `POST` (create) or `PATCH` (edit) carrying `updated_at` (R2, last-write-wins).

### Implementation checklist

- [x] All strings use `L10n.*` keys (EN + RU).
- [x] Accessibility identifiers: `CategoryEditorNameField`, `CategoryEditorIcon`, `CategoryEditorSaveButton`, `CategoryEditorCancelButton`, `CategoryEditorErrorBanner`, `CategoryEditorDeleteButton` (edit mode).
- [x] Keyboard placement follows D13 (name upper, toolbar checkmark save, full-height sheet).
- [x] Validation uses unified category-name messages (U2).
- [x] Duplicate names preserve the draft and keep the editor open.
- [x] Push hosting: form renders as `navigationDestination` (entry form, Track `ShellRoute.categoryEditor`); Back cancels like X; save pops with host attach; pushed-form preview exists.
- [x] Edit mode pre-fills name + icon from the passed-in `Category`.
- [x] iOS 18 floor — no availability guards (plain `.sheet`, no detents).
- [ ] Screen previews exist for light/dark and EN/RU.
- [x] SwiftLint passes with zero findings.

---

## New localization keys

Add to `en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`, then to `L10n`:

```text
// Category editor
"categoryEditor.createTitle" = "New category";
"categoryEditor.editTitle" = "Edit category";
"categoryEditor.nameLabel" = "Name";
"categoryEditor.namePlaceholder" = "e.g. Sport";
"categoryEditor.iconLabel" = "Icon";
"categoryEditor.save" = "Save";
"categoryEditor.cancel" = "Cancel";

// Errors
"error.categoryExists" = "A category with this name already exists.";
```

Russian:

```text
// Category editor
"categoryEditor.createTitle" = "Новая категория";
"categoryEditor.editTitle" = "Изменить категорию";
"categoryEditor.nameLabel" = "Название";
"categoryEditor.namePlaceholder" = "напр. Спорт";
"categoryEditor.iconLabel" = "Значок";
"categoryEditor.save" = "Сохранить";
"categoryEditor.cancel" = "Отмена";

// Errors
"error.categoryExists" = "Категория с таким названием уже существует.";
```
