import UIKit
import AVFoundation
import PhotosUI

/// Fotos (câmera e galeria) e áudios, guardados na pasta do aplicativo.
/// Mesmos nomes e formatos do Android: <id>.jpg (até 1600 px), <id>_mini.jpg (240 px), <id>.m4a.
final class Midias: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                    PHPickerViewControllerDelegate, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private weak var tela: UIViewController?
    private let saida: (String) -> Void
    private var chaveFoto = ""
    private var chaveAudio = ""
    private var gravador: AVAudioRecorder?
    private var audioId = ""
    private var inicioGravacao = Date()
    private var paradoPeloApp = false
    private var player: AVAudioPlayer?

    init(tela: UIViewController, saida: @escaping (String) -> Void) {
        self.tela = tela
        self.saida = saida
    }

    private var pasta: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("midias", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ") + "'"
    }

    private func erro(_ chave: String, _ msg: String?) {
        saida("window.midiaErro && midiaErro(\(Midias.q(chave)),\(msg.map { Midias.q($0) } ?? "null"))")
    }

    private func novoId(_ prefixo: String) -> String {
        prefixo + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: fotos

    func tirarFoto(chave: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tela = self.tela else { return }
            self.chaveFoto = chave
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                self.erro(chave, "Câmera indisponível neste aparelho."); return
            }
            let p = UIImagePickerController()
            p.sourceType = .camera
            p.delegate = self
            tela.present(p, animated: true)
        }
    }

    func escolherFoto(chave: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tela = self.tela else { return }
            self.chaveFoto = chave
            var cfg = PHPickerConfiguration()
            cfg.filter = .images
            cfg.selectionLimit = 1
            let p = PHPickerViewController(configuration: cfg)
            p.delegate = self
            tela.present(p, animated: true)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let img = info[.originalImage] as? UIImage { guardarFoto(img) } else { erro(chaveFoto, nil) }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        erro(chaveFoto, nil)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let item = results.first?.itemProvider, item.canLoadObject(ofClass: UIImage.self) else {
            erro(chaveFoto, nil); return
        }
        item.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
            guard let self = self else { return }
            if let img = obj as? UIImage { self.guardarFoto(img) } else { self.erro(self.chaveFoto, "Não foi possível abrir a foto.") }
        }
    }

    private func redimensionar(_ img: UIImage, maior: CGFloat) -> UIImage {
        let esc = min(1, maior / max(img.size.width, img.size.height))
        let tam = CGSize(width: round(img.size.width * esc), height: round(img.size.height * esc))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: tam, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: tam)) }
    }

    private func guardarFoto(_ img: UIImage) {
        let chave = chaveFoto
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let id = self.novoId("f")
            let grande = self.redimensionar(img, maior: 1600)
            let mini = self.redimensionar(grande, maior: 240)
            guard let dg = grande.jpegData(compressionQuality: 0.8), let dm = mini.jpegData(compressionQuality: 0.7) else {
                self.erro(chave, "Erro ao salvar a foto."); return
            }
            do {
                try dg.write(to: self.pasta.appendingPathComponent(id + ".jpg"))
                try dm.write(to: self.pasta.appendingPathComponent(id + "_mini.jpg"))
                self.saida("window.midiaPronta && midiaPronta(\(Midias.q(chave)),{id:\(Midias.q(id)),tipo:'foto',tamanho:\(dg.count)})")
            } catch {
                self.erro(chave, "Erro ao salvar a foto: \(error.localizedDescription)")
            }
        }
    }

    // MARK: áudio

    func iniciarAudio(chave: String) {
        chaveAudio = chave
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok { self.comecarGravacao() }
                else { self.erro(chave, "Sem permissão para usar o microfone. Libere em Ajustes > Monitor Meliponas > Microfone.") }
            }
        }
    }

    private func comecarGravacao() {
        do {
            let sessao = AVAudioSession.sharedInstance()
            try sessao.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try sessao.setActive(true)
            audioId = novoId("a")
            let ajustes: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
            let g = try AVAudioRecorder(url: pasta.appendingPathComponent(audioId + ".m4a"), settings: ajustes)
            g.delegate = self
            paradoPeloApp = false
            guard g.record(forDuration: 180) else { throw NSError(domain: "audio", code: 1) }
            gravador = g
            inicioGravacao = Date()
            saida("window.audioIniciado && audioIniciado(\(Midias.q(chaveAudio)))")
        } catch {
            gravador = nil
            erro(chaveAudio, "Não foi possível gravar.")
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !paradoPeloApp { saida("window.pararAudio && pararAudio(true)") }
    }

    /// Chamado pelo JavaScript; devolve o JSON do áudio ou "" se ficou curto demais.
    func finalizarAudio() -> String {
        let dur = Date().timeIntervalSince(inicioGravacao)
        if let g = gravador {
            paradoPeloApp = true
            if g.isRecording { g.stop() }
        } else if audioId.isEmpty { return "" }
        gravador = nil
        let url = pasta.appendingPathComponent(audioId + ".m4a")
        let tam = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let id = audioId
        audioId = ""
        if dur < 0.7 || tam == 0 {
            try? FileManager.default.removeItem(at: url)
            return ""
        }
        return "{\"id\":\"\(id)\",\"tipo\":\"audio\",\"duracao\":\(Int(min(dur, 180))),\"tamanho\":\(tam)}"
    }

    func tocar(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                self.player = try AVAudioPlayer(contentsOf: self.pasta.appendingPathComponent(id + ".m4a"))
                self.player?.delegate = self
                self.player?.play()
            } catch {
                self.saida("window.toast && toast('Não foi possível tocar o áudio')")
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        saida("window.audioTerminou && audioTerminou()")
    }

    func pararReproducao() { DispatchQueue.main.async { [weak self] in self?.player?.stop(); self?.player = nil } }

    // MARK: arquivos

    func miniatura(id: String) -> String {
        guard let d = try? Data(contentsOf: pasta.appendingPathComponent(id + "_mini.jpg")) else { return "" }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    func base64(id: String, tipo: String) -> String {
        let nome = id + (tipo == "audio" ? ".m4a" : ".jpg")
        guard let d = try? Data(contentsOf: pasta.appendingPathComponent(nome)) else { return "" }
        return d.base64EncodedString()
    }

    func apagar(id: String) {
        for ext in [".jpg", "_mini.jpg", ".m4a"] { try? FileManager.default.removeItem(at: pasta.appendingPathComponent(id + ext)) }
    }
}
