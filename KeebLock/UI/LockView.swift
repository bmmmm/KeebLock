import Combine
import SwiftUI

struct LockView: View {
    @ObservedObject var controller: LockController
    @StateObject private var rendererProxy: RendererProxy
    let renderer: WipeRenderer?
    let screenIndex: Int
    let screenFrame: CGRect  // AppKit coords, used for spark coordinate conversion

    init(controller: LockController, renderer: WipeRenderer?, screenIndex: Int, screenFrame: CGRect) {
        self.controller = controller
        self.renderer = renderer
        self.screenIndex = screenIndex
        self.screenFrame = screenFrame
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

            SparkOverlayView(
                triggerCount: controller.sparkTrigger,
                lastMouseScreenPoint: controller.lastMouseScreenPoint,
                screenFrame: screenFrame
            )

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
