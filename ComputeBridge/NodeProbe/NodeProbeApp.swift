import Foundation
import SwiftUI

@main
struct NodeProbeApp: App {
    @StateObject private var model = NextRuntimeModel()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 18) {
                Text("Next.js on iPhone")
                    .font(.largeTitle.bold())
                Text(model.status)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("Keep this app open while developing.")
                    .foregroundStyle(.secondary)
                Text("Transfer address")
                    .font(.headline)
                Text("http://\(model.address):3100")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("Pairing token")
                    .font(.headline)
                Text(model.token)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("Next.js address after start: http://\(model.address):3001")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(24)
            .onAppear { model.start() }
        }
    }
}

