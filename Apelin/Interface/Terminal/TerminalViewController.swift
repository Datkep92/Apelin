import ApelinCore
import ApelinProtocol
import UIKit

final class TerminalViewController: UIViewController {
    private let projectID: String?
    private let initialCommand: String?
    private var sessionID: String?
    private var taskID: TaskID?
    private var descriptor: OwnedDescriptor?
    private var readThread: Thread?
    private var isRunning = false

    private let outputView = UITextView()
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private var readBuffer = Data()

    init(projectID: String? = nil, initialCommand: String? = nil) {
        self.projectID = projectID
        self.initialCommand = initialCommand
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Terminal")
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = .systemBackground

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        outputView.backgroundColor = .black
        outputView.textColor = .green
        outputView.alwaysBounceVertical = true
        outputView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outputView)

        inputField.borderStyle = .roundedRect
        inputField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputField.placeholder = String(localized: "Command")
        inputField.autocapitalizationType = .none
        inputField.autocorrectionType = .no
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputField)

        sendButton.setTitle(String(localized: "Send"), for: .normal)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            outputView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            outputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outputView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),

            inputField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            inputField.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
        ])

        Task { await start() }
    }

    private func start() async {
        do {
            let cols = 80
            let rows = 24
            let response = try await ApelinService.app.ptyOpen(PtyOpenRequest(columns: cols, rows: rows, projectID: projectID, initialInput: initialCommand.map { $0 + "\n" }))
            sessionID = response.sessionID
            taskID = response.task.taskID

            isRunning = true
            let (batch, owned) = try await ApelinService.app.ptyAttach(taskID: response.task.taskID)
            descriptor = owned
            // Show initial output from events
            for event in batch.events {
                handleEvent(event)
            }
            if let owned {
                startReading(fd: owned.rawValue)
            }
        } catch {
            appendOutput("\n[Error: \(error.readableMessage)]\n")
        }
    }

    private func handleEvent(_ event: TaskEvent) {
        if let payload = event.payload,
           let text = payload["text"]?.stringValue {
            appendOutput(text)
        } else if let payload = event.payload,
                  let b64 = payload["base64"]?.stringValue,
                  let data = Data(base64Encoded: b64),
                  let text = String(data: data, encoding: .utf8) {
            appendOutput(text)
        } else if event.kind == "exit" {
            appendOutput("\n[Process exited]\n")
            isRunning = false
        }
    }

    private func startReading(fd: Int32) {
        readThread = Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while self.isRunning {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    DispatchQueue.main.async {
                        if let text = String(data: data, encoding: .utf8) {
                            self.appendOutput(text)
                        } else {
                            self.appendOutput(String(decoding: data, as: UTF8.self))
                        }
                    }
                } else if n == 0 {
                    break
                } else {
                    if errno == EINTR { continue }
                    break
                }
            }
        }
        readThread?.start()
    }

    private func appendOutput(_ text: String) {
        let attributed = NSMutableAttributedString(string: text)
        outputView.textStorage.append(attributed)
        outputView.scrollRangeToVisible(NSRange(location: outputView.text.count, length: 0))
    }

    @objc private func send() {
        guard let text = inputField.text, !text.isEmpty else { return }
        inputField.text = ""
        writeInput(text + "\n")
    }

    private func writeInput(_ text: String) {
        guard let fd = descriptor?.rawValue, fd >= 0 else { return }
        if let data = text.data(using: .utf8) {
            data.withUnsafeBytes { ptr in
                _ = Darwin.write(fd, ptr.baseAddress, data.count)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isRunning = false
        readThread?.cancel()
        if let sid = sessionID {
            Task { try? await ApelinService.app.ptyClose(sessionID: sid) }
        }
        descriptor?.close()
    }
}

extension TerminalViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }
}
\ No newline at end of file