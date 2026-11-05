import Foundation
import Network

/// Situação da conexão: "wifi", "movel" ou "nenhuma" (mesmos valores do Android).
final class Rede {
    static let compartilhada = Rede()
    private let monitor = NWPathMonitor()
    private let fila = DispatchQueue(label: "rede")
    private(set) var estado = "desconhecida"

    func iniciar() {
        monitor.pathUpdateHandler = { [weak self] caminho in
            if caminho.status != .satisfied {
                self?.estado = "nenhuma"
            } else if caminho.usesInterfaceType(.wifi) || caminho.usesInterfaceType(.wiredEthernet) {
                self?.estado = "wifi"
            } else {
                self?.estado = "movel"
            }
        }
        monitor.start(queue: fila)
    }
}
