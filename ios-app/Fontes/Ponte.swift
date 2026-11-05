import UIKit

/// Recebe as chamadas de `window.Android.*` e devolve texto (como no Android).
final class Ponte {
    private weak var tela: TelaPrincipal?
    private let midias: Midias
    private let bee: BeeMeterBLE

    init(tela: TelaPrincipal) {
        self.tela = tela
        let saida: (String) -> Void = { [weak tela] codigo in tela?.js(codigo) }
        midias = Midias(tela: tela, saida: saida)
        bee = BeeMeterBLE(saida: saida)
    }

    func executar(_ json: String) -> String {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = o["m"] as? String else { return "" }
        let a = o["a"] as? [Any] ?? []
        func s(_ i: Int) -> String {
            guard i < a.count else { return "" }
            if let x = a[i] as? String { return x }
            if let x = a[i] as? NSNumber { return x.stringValue }
            return ""
        }
        func n(_ i: Int) -> Int { Int(s(i)) ?? Int(Double(s(i)) ?? 0) }

        switch m {
        case "compartilhar": compartilhar(texto: s(0), titulo: s(1))
        case "tirarFoto": midias.tirarFoto(chave: s(0))
        case "escolherFoto": midias.escolherFoto(chave: s(0))
        case "iniciarAudio": midias.iniciarAudio(chave: s(0))
        case "finalizarAudio": return midias.finalizarAudio()
        case "tocarAudio": midias.tocar(id: s(0))
        case "pararReproducao": midias.pararReproducao()
        case "miniatura": return midias.miniatura(id: s(0))
        case "lerMidiaBase64": return midias.base64(id: s(0), tipo: s(1))
        case "apagarMidia": midias.apagar(id: s(0))
        case "rede": return Rede.compartilhada.estado
        case "versao": return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.0"
        case "bleBuscar": bee.buscar(chave: s(0), segundos: max(3, n(1)))
        case "bleBaixar": bee.baixar(chave: s(0), id: s(1), desde: Int64(s(2)) ?? 0, colonia: n(3))
        case "bleIdentificar": bee.identificar(chave: s(0), id: s(1))
        case "bleAoVivo": bee.aoVivo(chave: s(0), id: s(1), desde: Int64(s(2)) ?? 0, colonia: n(3), visita: s(4))
        case "bleParar": bee.parar()
        case "historico": return bee.historico(colonia: n(0), desde: Int64(s(1)) ?? 0)
        case "exportarHistorico": exportar()
        case "salvarArquivo": entregarArquivo(b64: s(0), nome: s(1), assunto: s(4))
        case "bleCancelar": bee.cancelar()
        case "lotesPendentes": return bee.lotesPendentes()
        case "lerLote": return bee.lerLote(nome: s(0))
        case "apagarLote": bee.apagarLote(nome: s(0))
        default: break
        }
        return ""
    }

    /// Relatório em PDF: abre a folha do iPhone (Salvar em Arquivos, WhatsApp, Mail…).
    private func entregarArquivo(b64: String, nome: String, assunto: String) {
        guard let dados = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((nome as NSString).lastPathComponent)
        do { try dados.write(to: url) } catch { return }
        DispatchQueue.main.async { [weak self] in
            guard let tela = self?.tela else { return }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = tela.view
                pop.sourceRect = CGRect(x: tela.view.bounds.midX, y: tela.view.bounds.maxY - 80, width: 1, height: 1)
            }
            tela.present(vc, animated: true)
        }
    }

    private func exportar() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let url = self.bee.arquivoCsv() else { return }
            DispatchQueue.main.async {
                guard let tela = self.tela else { return }
                let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let pop = vc.popoverPresentationController {
                    pop.sourceView = tela.view
                    pop.sourceRect = CGRect(x: tela.view.bounds.midX, y: tela.view.bounds.maxY - 80, width: 1, height: 1)
                }
                tela.present(vc, animated: true)
            }
        }
    }

    private func compartilhar(texto: String, titulo: String) {
        DispatchQueue.main.async { [weak self] in
            guard let tela = self?.tela else { return }
            let vc = UIActivityViewController(activityItems: [texto], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = tela.view
                pop.sourceRect = CGRect(x: tela.view.bounds.midX, y: tela.view.bounds.maxY - 80, width: 1, height: 1)
            }
            tela.present(vc, animated: true)
        }
    }
}
