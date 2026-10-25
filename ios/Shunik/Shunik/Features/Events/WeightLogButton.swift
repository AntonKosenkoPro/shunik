import SwiftUI

/// One-tap weight entry for one pet: a button presenting the weight
/// `EventFormView` in a sheet. The pets agent embeds this with exactly
/// `WeightLogButton(petID:)`; the optional `onLogged` hook lets parents
/// reload after the sheet dismisses.
struct WeightLogButton: View {
    let petID: String

    var onLogged: (() -> Void)?

    @State private var showingForm = false

    init(petID: String) {
        self.petID = petID
    }

    var body: some View {
        Button {
            showingForm = true
        } label: {
            Label(L10n.weightLog.text, systemImage: "plus")
        }
        .sheet(isPresented: $showingForm, onDismiss: { onLogged?() }, content: {
            EventFormView(eventID: nil, petID: petID, kind: "weight")
        })
    }
}

#if DEBUG
#Preview("Weight log button") {
    let container = AppContainer.production()
    WeightLogButton(petID: "pet-1")
        .environmentObject(container)
}
#endif
