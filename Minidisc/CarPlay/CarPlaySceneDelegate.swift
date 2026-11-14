import CarPlay

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var connection: UUID?
    private var startup: Task<Void, Never>?
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        disconnect()
        let connection = UUID()
        self.connection = connection
        let loading = CPListItem(text: String(localized: "Loading…"), detailText: nil)
        loading.isEnabled = false
        interfaceController.setRootTemplate(
            CPListTemplate(title: "Minidisc", sections: [CPListSection(items: [loading])]),
            animated: false, completion: nil)
        startup = Task { [weak self, weak templateApplicationScene] in
            do {
                let container = try await MinidiscRuntime.shared.container()
                guard let self, self.connection == connection, !Task.isCancelled else { return }
                let controller = CarPlayController(container: container, interface: interfaceController)
                self.controller = controller
                controller.start()
            } catch {
                guard let self, self.connection == connection, !Task.isCancelled else { return }
                let item = CPListItem(text: String(localized: "Open Minidisc on your iPhone to finish setup.", table: "CarPlay"),
                                      detailText: String(localized: "Retry"))
                item.handler = { [weak self, weak templateApplicationScene] _, completion in
                    completion()
                    guard let self, let templateApplicationScene else { return }
                    self.templateApplicationScene(templateApplicationScene, didConnect: interfaceController)
                }
                interfaceController.setRootTemplate(CPListTemplate(title: "Minidisc", sections: [CPListSection(items: [item])]),
                                                    animated: false, completion: nil)
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        disconnect()
    }

    func sceneDidBecomeActive(_ scene: UIScene) { controller?.refresh() }

    private func disconnect() {
        connection = nil
        startup?.cancel()
        startup = nil
        controller?.stop()
        controller = nil
    }
}
