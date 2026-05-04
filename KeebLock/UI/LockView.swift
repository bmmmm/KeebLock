import SwiftUI

struct LockView: View {
    @ObservedObject var controller: LockController
    let screenIndex: Int
    let backgroundColor: Color

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            HUDView(controller: controller, screenIndex: screenIndex)
        }
    }
}
