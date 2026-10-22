import SwiftUI

/// The Account page (Profile → Account, app-shell + account-deletion specs):
/// a signed-in-only pushed page with system Back, no Done/sheet, and the tab
/// bar hidden at every nested depth. Shows the active account's full stored
/// email (read-only, wrapping, offline-capable), Sign out (confirmation-free,
/// files kept), device-only Delete local data (single confirmation,
/// server-untouched), and the visually separated permanent
/// **Delete account and local data** (exactly one explicit alert).
///
/// All copy comes from `L10n` (EN + RU); all colors from `Theme`. All three
/// destructive rows share one visual contract: shared `ListRow` geometry
/// with a leading icon and the danger tint. No new shared component —
///
/// `ListRow` is reused (`COMPONENTS.md` unchanged).
struct AccountView: View {
    @EnvironmentObject var container: AppContainer
    @EnvironmentObject var session: SessionStore
    @StateObject private var vm: AccountViewModel

    /// Permanent-deletion row/action identifiers (Account.md).
    static let emailAccessibilityId = "AccountEmailValue"
    static let deleteLocalDataAccessibilityId = "AccountDeleteLocalDataButton"
    static let deleteAccountAccessibilityId = "AccountDeleteAccountButton"
    static let deletionProgressAccessibilityId = "AccountDeletionProgress"

    init(container: AppContainer) {
        _vm = StateObject(wrappedValue: AccountViewModel(container: container))
    }

    var body: some View {
        List {
            identitySection
            thisDeviceSection
            permanentDeletionSection
        }
        .navigationTitle(L10n.accountTitle.text)
        .navigationBarTitleDisplayMode(.inline)
        // Exactly ONE deletion-confirmation alert (account-deletion spec):
        // the title and destructive button both name account + local data.
        // A native Apple authorization sheet (when required) is
        // authentication, not a second alert; cancelling it sends nothing.
        .alert(L10n.accountDeleteTitle.text, isPresented: $vm.isShowingDeleteConfirm) {
            Button(L10n.accountDeleteConfirm.text, role: .destructive) {
                Task { await vm.confirmDelete() }
            }
            .disabled(vm.isDeleting)
            Button(L10n.profileEraseCancel.text, role: .cancel) {}
        } message: {
            Text(L10n.accountDeleteMessage.text)
        }
        .alert(L10n.accountDeleteLocalData.text, isPresented: $vm.isShowingEraseConfirm) {
            Button(L10n.profileEraseConfirm.text, role: .destructive) {
                Task { await vm.eraseLocalData() }
            }
            Button(L10n.profileEraseCancel.text, role: .cancel) {}
        } message: {
            Text(L10n.profileEraseLocalDataConfirmMessage.text)
        }
        .alert(
            vm.deleteNoticeTitle,
            isPresented: Binding(
                get: { vm.deleteNotice != nil },
                set: { if !$0 { vm.deleteNotice = nil } }
            )
        ) {
            if vm.deleteNotice == .stillExists {
                Button(L10n.accountDeleteConfirm.text) {
                    vm.retryDelete()
                }
                Button(L10n.profileEraseCancel.text, role: .cancel) {
                    Task { await vm.cancelPendingDeletion() }
                }
            } else if vm.deleteNotice == .cleanupRetry {
                Button(L10n.accountCleanupRetryConfirm.text) {
                    Task { await vm.retryCleanup() }
                }
                Button(L10n.profileEraseCancel.text, role: .cancel) { vm.deleteNotice = nil }
            } else {
                Button(L10n.commonOk.text, role: .cancel) { vm.deleteNotice = nil }
            }
        } message: {
            Text(vm.deleteNoticeMessage ?? "")
        }
        .alert(
            L10n.accountDeleteLocalData.text,
            isPresented: Binding(
                get: { vm.eraseErrorMessage != nil },
                set: { if !$0 { vm.eraseErrorMessage = nil } }
            )
        ) {
            Button(L10n.commonOk.text, role: .cancel) { vm.eraseErrorMessage = nil }
        } message: {
            Text(vm.eraseErrorMessage ?? "")
        }
        .accessibilityIdentifier("Account")
    }

    // MARK: - Account identity

    private var identitySection: some View {
        Section(
            header: Text(L10n.accountIdentitySection.text),
            footer: Text(L10n.accountIdentityFooter.text)
        ) {
            ListRow(title: vm.email)
                .accessibilityIdentifier(Self.emailAccessibilityId)
                .accessibilityLabel("\(L10n.emailEntryEmail.text), \(vm.email)")
            Button(role: .destructive) {
                vm.isShowingSignOutConfirm = true
            } label: {
                ListRow(
                    title: L10n.profileSignOut.text,
                    icon: ProfileView.signOutIcon,
                    tint: Theme.danger
                )
            }
            .accessibilityIdentifier(ProfileView.signOutAccessibilityId)
            .disabled(vm.isDeleting)
            .alert(L10n.accountSignOutConfirmTitle.text, isPresented: $vm.isShowingSignOutConfirm) {
                Button(L10n.profileSignOut.text, role: .destructive) {
                    Task { await vm.signOut() }
                }
                Button(L10n.signOutCancel.text, role: .cancel) {}
            } message: {
                Text(L10n.accountSignOutConfirmMessage.text)
            }
        }
    }

    // MARK: - This device

    private var thisDeviceSection: some View {
        Section(
            header: Text(L10n.accountThisDeviceSection.text),
            footer: Text(L10n.accountThisDeviceFooter.text)
        ) {
            Button(role: .destructive) {
                vm.isShowingEraseConfirm = true
            } label: {
                ListRow(
                    title: L10n.accountDeleteLocalData.text,
                    icon: "trash",
                    tint: Theme.danger
                )
            }
            .accessibilityIdentifier(Self.deleteLocalDataAccessibilityId)
            .disabled(vm.isDeleting)
        }
    }

    // MARK: - Permanent deletion

    private var permanentDeletionSection: some View {
        Section(
            header: Text(L10n.accountPermanentSection.text),
            footer: Text(L10n.accountPermanentFooter.text)
        ) {
            Button(role: .destructive) {
                vm.isShowingDeleteConfirm = true
            } label: {
                ListRow(
                    title: L10n.accountDeleteConfirm.text,
                    icon: "person.crop.circle.badge.xmark",
                    tint: Theme.danger
                ) {
                    if vm.isDeleting {
                        ProgressView()
                            .accessibilityIdentifier(Self.deletionProgressAccessibilityId)
                            .accessibilityLabel(L10n.accountDeletingProgress.text)
                    }
                }
            }
            .accessibilityIdentifier(Self.deleteAccountAccessibilityId)
            .disabled(vm.isDeleting)
        }
    }
}

#if DEBUG
#Preview("Account") {
    let container = AppContainer.production()
    NavigationStack {
        AccountView(container: container)
            .environmentObject(container)
            .environmentObject(container.sessionStore)
    }
}
#endif
