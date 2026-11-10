import ApelinProtocol
import Foundation
import UIKit

final class GatewaySettingsController: UIViewController {
    private let statusLabel = UILabel()
    private let toggleSwitch = UISwitch()
    private let refreshButton = UIButton()
    private var observable: Task<Void, Never>?
    private var isRunning = false
    private var isHung = false
    private var isUpdating = false

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

        let hbox = UIStackView()
        hbox.axis = .horizontal
        hbox.distribution = .equalSpacing
        hbox.alignment = .center
        hbox.translatesAutoresizingMaskIntoConstraints = false

        toggleSwitch.addTarget(self, action: #selector(toggleSwitchChanged(_:)), for: .valueChanged)
        toggleSwitch.accessibilityLabel = String(localized: "Gateway")

        refreshButton.configuration = .tinted()
        refreshButton.setTitle(String(localized: "Refresh"), for: .normal)
        refreshButton.accessibilityLabel = String(localized: "Refresh Status")
        refreshButton.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)

        hbox.addArrangedSubview(toggleSwitch)
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await ApelinService.app.gatewayStatus()
                await MainActor.run {
                    self.isRunning = response.record.state == .dang_chay
                    self.isHung = response.record.state == .dang_treo
                    self.updateUI()
                }
            } catch {
                await MainActor.run { self.updateUI() }
            }
        }
    }

    private func startObserving() {
        observable = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { break }
                await MainActor.run { self.refreshStatus() }
            }
        }
    }

    private func updateUI() {
        if isRunning {
            statusLabel.text = String(localized: "Gateway is running")
        } else if isHung {
            statusLabel.text = String(localized: "Gateway is not responding")
        } else {
            statusLabel.text = String(localized: "Gateway is stopped")
        }
        // The switch controls the process, not only a port that answers: a hung
        // gateway stays on so it can be turned off from here.
        toggleSwitch.isOn = isRunning || isHung
        toggleSwitch.isEnabled = !isUpdating
        toggleSwitch.accessibilityValue = (isRunning || isHung)
            ? String(localized: "On")
            : String(localized: "Off")
    }

    @objc private func toggleSwitchChanged(_ sender: UISwitch) {
        guard !isUpdating else {
            sender.setOn(isRunning, animated: true)
            return
        }
        let target = sender.isOn
        isUpdating = true
        toggleSwitch.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ApelinService.app.gatewaySetEnabled(target)
                await self.refreshStatus()
            } catch {
                await MainActor.run {
                    let alert = UIAlertController(
                        title: String(localized: "Gateway"),
                        message: error.readableMessage,
                        preferredStyle: .alert,
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
            await MainActor.run {
                self.isUpdating = false
                self.updateUI()
            }
        }
    }

    @objc private func refreshTapped() {
        refreshStatus()
    }
}