import SwiftUI

struct LockView: View {
    var controller: LockController
    // Must be observed (not a bare `AppSettings.shared`) so toggling the
    // debug overlay level live in Settings actually re-renders the lock
    // window. A static read inside body() does NOT subscribe to the
    // ObservableObject — the overlay would only update on the next
    // unrelated invalidation.
    @ObservedObject private var settings: AppSettings = .shared
    let renderer: WipeRenderer
    let screenIndex: Int

    // Fixed once when the view is created, not re-rolled on every body
    // re-evaluation. Computing Double.random() inside body would pick a new
    // hue on every invalidation (displayTick, settings change…), flashing the
    // placeholder background random colours on Metal-unavailable devices.
    @State private var placeholderHue: Double = .random(in: 0..<1)

    var body: some View {
        ZStack {
            if renderer.isPlaceholder {
                Color(hue: placeholderHue, saturation: 0.65, brightness: 0.5)
                    .ignoresSafeArea()
            } else {
                WipeView(renderer: renderer)
                    .ignoresSafeArea()
            }

            SparkOverlayView(triggerCount: controller.sparkTrigger)

            HUDView(
                controller: controller,
                renderer: renderer,
                screenIndex: screenIndex
            )
            .padding(36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.xl))

            // Border-strip live debug HUD. Layered on top of HUD so the
            // strips draw above the codeword card; non-interactive so it
            // can't swallow unlock-button clicks.
            if settings.lockOverlayDebugLevel != .off {
                LockOverlayDebug(
                    controller: controller,
                    level: settings.lockOverlayDebugLevel
                )
            }
        }
    }
}
