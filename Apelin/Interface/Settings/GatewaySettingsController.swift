import ApelinCore
import Foundation
import UIKit

final class GatewaySettingsController: UIViewController {
    private let statusLabel = UILabel()
    private let toggleButton = UIButton()
    private let refreshButton = UIButton()
    private var observable: Task<Void, Never>?
    private var isRunning = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Gateway")
        view.backgroundColor = .systemBackground
        buildUI()
        refreshStatus()
        startObserving()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observable?.cancel()
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        let statusText = String(localized: "Gateway status will be updated automatically")
        statusLabel.text = statusText

        let hbox = UIStackView()
        hbox.axis = .horizontal
        hbox.distribution = .equalSpacing
        hbox.alignment = .center
        hbox.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.configuration = .filled()
        toggleButton.setTitle(String(localized: "Start"), for: .normal)
        toggleButton.accessibilityLabel = String(localized: "Start Gateway")
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        refreshButton.configuration = .tinted()
        refreshButton.setTitle(String(localized: "Refresh"), for: .normal)
        refreshButton.accessibilityLabel = String(localized: "Refresh Status")
        refreshButton.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)

        hbox.addArrangedSubview(toggleButton)
        hbox.addArrangedSubview(refreshButton)

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(hbox)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    private func refreshStatus() {
        isRunning = checkGatewayRunning()
        updateUI()
    }

    private func checkGatewayRunning() -> Bool {
        let bin = "/var/jb/usr/bin/gateway-session"
        let exists = FileManager.default.fileExists(atPath: bin)
        let pidURL = URL(fileURLWithPath: "/var/run/gateway-session.pid")
        let pid: Int?
        do {
            let data = try Data(contentsOf: pidURL)
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
            pid = Int(text ?? "")
        } catch {
            pid = nil
        }
        let isRunning = pid.map { kill(Int32($0), 0) == 0 } ?? false
        return exists && isRunning
    }

    private func startObserving() {
        // For simplicity, refresh periodically
        observable = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                await MainActor.run { self.refreshStatus() }
            }
        }
    }

    private func updateUI() {
        isRunning = checkGatewayRunning()
        if isRunning {
            statusLabel.text = String(localized: "Gateway is running")
            toggleButton.setTitle(String(localized: "Stop"), for: .normal)
        } else {
            statusLabel.text = String(localized: "Gateway is stopped")
            toggleButton.setTitle(String(localized: "Start"), for: .normal)
        }
    }

    @objc private func toggleTapped() {
        let bin = "/var/jb/usr/bin/gateway-session"
        let pidURL = URL(fileURLWithPath: "/var/run/gateway-session.pid")

        if isRunning {
            // Reaching to pidURL: get pid, kill 0, remove it
            if let data = try? Data(contentsOf: pidURL),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
               let pid = Int(text) {
                kill(Int32(pid), 0) // check it's alive
                kill(Int32(pid), 9)
                try? FileManager.default.removeItem(at: pidURL)
            } else {
                // Force kill any process listening? Too complex.
            }
        } else {
            // Maybe needed a wheel of expand to start gateway.
            // For now, treat as unavailable.
        }
    }

    @objc private func refreshTapped() {
        refreshStatus()
    }
}
