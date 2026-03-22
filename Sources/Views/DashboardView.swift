import SwiftUI

struct DashboardView: View {
    @ObservedObject var state = DaemonState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats row
                HStack(spacing: 16) {
                    StatCard(title: "CLIENTS", value: "\(state.authenticatedClients)", icon: "person.2.fill")
                    StatCard(title: "WINDOWS", value: "\(state.trackedWindowCount)", icon: "rectangle.on.rectangle")
                    StatCard(title: "MODE", value: state.pollingMode.rawValue, icon: "speedometer")
                }

                // Pairing section
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Pairing", icon: "key.fill")
                    HStack {
                        Text(state.pairingToken)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer()
                        Button { copyToken() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                }

                // Tracked windows list
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Tracked Windows", icon: "rectangle.3.offgrid.fill")
                    if state.trackedWindows.isEmpty {
                        Text("No terminal windows detected")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    } else {
                        ForEach(state.trackedWindows, id: \.id) { window in
                            WindowRow(window: window)
                        }
                    }
                }

                // Power mode banner
                if state.powerSource == .battery {
                    HStack(spacing: 10) {
                        Image(systemName: "battery.50")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Power Saving Active")
                                .font(.system(size: 12, weight: .medium))
                            Text("Polling reduced to preserve battery")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding(20)
        }
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.pairingToken, forType: .string)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

private struct WindowRow: View {
    let window: WindowState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(window.status == .running ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text("\(Int(window.w))×\(Int(window.h))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if window.isFocused {
                Text("FOCUSED")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
