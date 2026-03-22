import SwiftUI

struct MainWindow: View {
    @ObservedObject var state = DaemonState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.green)
                Text("DISPATCH")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(state.isRunning ? "Running" : "Stopped")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            DashboardView()
        }
        .frame(width: 480, height: 520)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
