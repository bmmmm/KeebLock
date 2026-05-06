import Combine
import SwiftUI

struct LockView: View {
    var controller: LockController
    // Must be observed (not a bare `AppSettings.shared`) so toggling the
    // debug overlay level live in Settings actually re-renders the lock
    // window. A static read inside body() does NOT subscribe to the
    // ObservableObject — the overlay would only update on the next
    // unrelated invalidation.
    @ObservedObject private var settings: AppSettings = .shared
    @StateObject private var rendererProxy: RendererProxy
    let renderer: WipeRenderer?
    let screenIndex: Int

    init(controller: LockController, renderer: WipeRenderer?, screenIndex: Int) {
        self.controller = controller
        self.renderer = renderer
        self.screenIndex = screenIndex
        _rendererProxy = StateObject(wrappedValue: RendererProxy(renderer: renderer))
    }

    var body: some View {
        ZStack {
            if let renderer {
                WipeView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Color(hue: Double.random(in: 0..<1), saturation: 0.65, brightness: 0.5)
                    .ignoresSafeArea()
            }

            SparkOverlayView(triggerCount: controller.sparkTrigger)

            HUDView(
                controller: controller,
                rendererProxy: rendererProxy,
                screenIndex: screenIndex
            )
            .padding(36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))

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
