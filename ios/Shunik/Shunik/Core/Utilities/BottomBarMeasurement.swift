import SwiftUI

/// A `PreferenceKey` that carries the height of a measured bottom bar up the
/// view tree. Used by auth screens that pin their action bar in a
/// `.safeAreaInset(edge: .bottom)` so the scrollable content can reserve the
/// same amount of space and avoid being overlapped on small screens.
enum BottomBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Measures the size of its content and reports the height via
/// `BottomBarHeightPreferenceKey`. Place this around the content of a
/// `.safeAreaInset(edge: .bottom)` closure.
struct MeasuredBottomBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: BottomBarHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                }
            )
    }
}

extension View {
    /// Pins a bottom action bar in a `.safeAreaInset(edge: .bottom)` and
    /// reports its measured height into `height` (via
    /// `BottomBarHeightPreferenceKey`), so callers can reserve matching space
    /// in their scrollable content. Wraps the two-step
    /// `MeasuredBottomBar` + `.onPreferenceChange(...)` boilerplate once.
    func measuredBottomBar<Content: View>(
        height: Binding<CGFloat>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self
            .safeAreaInset(edge: .bottom) {
                MeasuredBottomBar { content() }
            }
            .onPreferenceChange(BottomBarHeightPreferenceKey.self) { height.wrappedValue = $0 }
    }
}
