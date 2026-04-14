import SwiftUI

struct DashboardView: View {
    @ObservedObject var state = DaemonState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats row
                HStack(spacing: 16) {
                    StatCard(title: "CLIENTS", value: "\(state.authenticatedClients)", icon: "person.2.fill")
                    StatCard(title: "SESSIONS", value: "\(state.activeSessions)", icon: "rectangle.on.rectangle")
                    StatCard(title: "MODE", value: "PTY", icon: "speedometer")
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

                // Active sessions list
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Active Sessions", icon: "rectangle.3.offgrid.fill")
                    if state.activeSessions == 0 {
                        Text("No active sessions")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    } else {
                        Text("\(state.activeSessions) session(s) running")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
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

private struct SessionRow: View {
    let session: SessionState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text("\(session.cols)×\(session.rows)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
