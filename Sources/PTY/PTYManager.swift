import Darwin
import Foundation

// MARK: - PTY Session

struct PTYSession {
    let id: String
    let masterFd: Int32
    let pid: pid_t
    var rows: UInt16
    var cols: UInt16
}

// MARK: - PTY Manager

final class PTYManager {

    var onOutput: ((String, Data) -> Void)?
    var onExit: ((String, Int32) -> Void)?

    private var sessions: [String: PTYSession] = [:]
    private var readSources: [String: DispatchSourceRead] = [:]
    private let queue = DispatchQueue(label: "dispatch.pty", qos: .userInitiated)

    // MARK: - Create Session

    func createSession(id: String, rows: UInt16 = 24, cols: UInt16 = 80) -> Bool {
        guard sessions[id] == nil else {
            print("[PTYManager] Session \(id) already exists")
            return false
        }

        var masterFd: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let pid = forkpty(&masterFd, nil, nil, &size)
        if pid < 0 {
            print("[PTYManager] forkpty failed: \(String(cString: strerror(errno)))")
            return false
        }

        if pid == 0 {
            runChildProcess(shell: shell)
        }

        let session = PTYSession(id: id, masterFd: masterFd, pid: pid, rows: rows, cols: cols)
        sessions[id] = session

        let flags = fcntl(masterFd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)
        }

        startReading(session: session)

        print("[PTYManager] Created session \(id) (pid: \(pid), fd: \(masterFd))")
        return true
    }

    // MARK: - Write to Session

    func write(sessionID: String, data: Data) {
        guard let session = sessions[sessionID] else { return }

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(session.masterFd, baseAddress, data.count)
        }
    }

    // MARK: - Resize Session

    func resize(sessionID: String, rows: UInt16, cols: UInt16) {
        guard var session = sessions[sessionID] else { return }

        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(session.masterFd, TIOCSWINSZ, &size)

        session.rows = rows
        session.cols = cols
        sessions[sessionID] = session
    }

    // MARK: - Close Session

    func close(sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }

        readSources.removeValue(forKey: sessionID)?.cancel()
        kill(session.pid, SIGKILL)
        Darwin.close(session.masterFd)

        var status: Int32 = 0
        _ = waitpid(session.pid, &status, 0)

        print("[PTYManager] Closed session \(sessionID)")
    }

    // MARK: - Active Session IDs

    var activeSessionIDs: [String] {
        Array(sessions.keys)
    }

    // MARK: - Private

    private func startReading(session: PTYSession) {
        let source = DispatchSource.makeReadSource(fileDescriptor: session.masterFd, queue: queue)
        let bufferSize = 65_536

        source.setEventHandler { [weak self] in
            guard let self else { return }

            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let bytesRead = Darwin.read(session.masterFd, &buffer, bufferSize)

            if bytesRead > 0 {
                let data = Data(buffer.prefix(Int(bytesRead)))
                self.onOutput?(session.id, data)
                return
            }

            if bytesRead < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }

            self.handleSessionExit(session.id)
        }

        source.setCancelHandler { [weak self] in
            self?.handleSessionExit(session.id)
        }

        readSources[session.id] = source
        source.resume()
    }

    private func handleSessionExit(_ sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }

        readSources.removeValue(forKey: sessionID)?.cancel()
        Darwin.close(session.masterFd)

        var status: Int32 = 0
        let waitResult = waitpid(session.pid, &status, 0)
        let exitCode: Int32

        if waitResult == session.pid, didExit(status) {
            exitCode = exitStatus(status)
        } else if waitResult == session.pid, wasTerminatedBySignal(status) {
            exitCode = terminationSignal(status)
        } else {
            exitCode = -1
        }

        print("[PTYManager] Session \(sessionID) exited with code \(exitCode)")
        onExit?(sessionID, exitCode)
    }

    private func runChildProcess(shell: String) -> Never {
        signal(SIGINT, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGPIPE, SIG_DFL)

        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)

        var argv = [strdup(shell), strdup("-l"), nil]
        defer {
            for pointer in argv where pointer != nil {
                free(pointer)
            }
        }

        _ = shell.withCString { shellPath in
            argv.withUnsafeMutableBufferPointer { buffer in
                execv(shellPath, buffer.baseAddress)
            }
        }

        _ = Darwin.write(STDERR_FILENO, "execv failed\n", 13)
        _exit(1)
    }

    private func didExit(_ status: Int32) -> Bool {
        (status & 0x7f) == 0
    }

    private func exitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private func wasTerminatedBySignal(_ status: Int32) -> Bool {
        let signal = status & 0x7f
        return signal != 0 && signal != 0x7f
    }

    private func terminationSignal(_ status: Int32) -> Int32 {
        status & 0x7f
    }

    deinit {
        for id in sessions.keys {
            close(sessionID: id)
        }
    }
}
