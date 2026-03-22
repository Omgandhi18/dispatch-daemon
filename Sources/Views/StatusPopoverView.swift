import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var state = DaemonState.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("DISPATCH")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Circle().fill(state.isRunning ? Color.green : Color.red).frame(width: 6, height: 6)
            }

            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("\(state.authenticatedClients)").font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text("CLIENTS").font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                }
                VStack(spacing: 2) {
                    Text("\(state.trackedWindowCount)").font(.system(size: 16, weight: .bold, design: .monospaced))
                    Text("WINDOWS").font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 200)
    }
}
