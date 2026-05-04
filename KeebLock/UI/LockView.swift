import Combine
import SwiftUI

struct LockView: View {
    @ObservedObject var controller: LockController
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
        }
    }
}
