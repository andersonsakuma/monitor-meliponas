import Foundation
import CoreBluetooth

/// Comunicação com o BeeMeter (firmware 2.2.0-BLE). Mesmo protocolo e mesmo
/// formato de lote do Android (ver firmware/PROTOCOLO_BLE.md).
final class BeeMeterBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let SERVICO = CBUUID(string: "6E7A0001-B5A3-4F4B-9A3E-6D656C697061")
    static let C_INFO = CBUUID(string: "6E7A0002-B5A3-4F4B-9A3E-6D656C697061")
    static let C_AGORA = CBUUID(string: "6E7A0003-B5A3-4F4B-9A3E-6D656C697061")
    static let C_COMANDO = CBUUID(string: "6E7A0004-B5A3-4F4B-9A3E-6D656C697061")
    static let C_DADOS = CBUUID(string: "6E7A0005-B5A3-4F4B-9A3E-6D656C697061")
    static let TAM = 32

    private let saida: (String) -> Void
    private var central: CBCentralManager!
    private var aoLigar: (() -> Void)?
    private var chaveAoLigar = ""

    // busca
    private var buscando = false
    private var chaveBusca = ""
    private var alvo: String?
    private var achados: [String: Int] = [:]
    private var tempoBusca: Timer?

    // download
    private var sessao: Sessao?

    private struct Sessao {
        var chave: String
        var id: String
        var desde: Int64
        var colonia: Int
        var periferico: CBPeripheral?
        var etapa = 0
        var tentativas = 0
        var info: [String: Any] = [:]
        var agora: Any = NSNull()
        var epocaCelular: Int64 = 0
        var esperados: Int64 = 0
        var fluxo = Data()
        var ultimoAviso = Date.distantPast
        var cInfo: CBCharacteristic?
        var cAgora: CBCharacteristic?
        var cComando: CBCharacteristic?
        var cDados: CBCharacteristic?
    }

    private var vigia: Timer?

    init(saida: @escaping (String) -> Void) {
        self.saida = saida
        super.init()
    }

    private var pastaLotes: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("lotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func q(_ s: String) -> String { Midias.q(s) }
    private func erro(_ chave: String, _ msg: String) { saida("window.bleErro && bleErro(\(q(chave)),\(q(msg)))") }
    private func progresso(_ chave: String, _ txt: String, _ pct: Int) {
        saida("window.bleProgresso && bleProgresso(\(q(chave)),\(q(txt)),\(pct))")
    }

    // MARK: estado do Bluetooth

    private func comBluetooth(_ chave: String, _ acao: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.central == nil {
                self.chaveAoLigar = chave
                self.aoLigar = acao
                self.central = CBCentralManager(delegate: self, queue: .main)   // mostra o pedido de permissão
                return
            }
            self.verificar(chave, acao)
        }
    }

    private func verificar(_ chave: String, _ acao: @escaping () -> Void) {
        switch central.state {
        case .poweredOn: acao()
        case .unknown, .resetting: chaveAoLigar = chave; aoLigar = acao
        case .poweredOff: erro(chave, "O Bluetooth está desligado. Ligue o Bluetooth na Central de Controle e tente de novo.")
        case .unauthorized: erro(chave, "Sem permissão para usar o Bluetooth. Libere em Ajustes > Monitor Meliponas > Bluetooth.")
        default: erro(chave, "Bluetooth indisponível neste aparelho.")
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard let acao = aoLigar else { return }
        if c.state == .unknown || c.state == .resetting { return }
        aoLigar = nil
        verificar(chaveAoLigar, acao)
    }

    // MARK: busca

    func buscar(chave: String, segundos: Int) {
        comBluetooth(chave) { self.iniciarBusca(chave: chave, segundos: segundos, alvo: nil) }
    }

    private func iniciarBusca(chave: String, segundos: Int, alvo: String?) {
        pararBusca()
        chaveBusca = chave
        self.alvo = alvo
        achados = [:]
        buscando = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        tempoBusca = Timer.scheduledTimer(withTimeInterval: TimeInterval(segundos), repeats: false) { [weak self] _ in
            guard let self = self, self.buscando else { return }
            self.pararBusca()
            if let alvo = self.alvo, let s = self.sessao {
                self.sessao = nil
                self.erro(s.chave, "Aparelho \(alvo) não encontrado. Chegue mais perto da caixa, confira se a tela do aparelho está acesa e tente de novo.")
            } else {
                let lista = self.achados.map { "{\"id\":\"\($0.key)\",\"rssi\":\($0.value)}" }.joined(separator: ",")
                self.saida("window.bleBuscaFim && bleBuscaFim(\(self.q(self.chaveBusca)),[\(lista)])")
            }
        }
    }

    private func pararBusca() {
        tempoBusca?.invalidate()
        tempoBusca = nil
        if buscando, central != nil, central.isScanning { central.stopScan() }
        buscando = false
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi RSSI: NSNumber) {
        let nome = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard nome.hasPrefix("BM-") else { return }
        if let alvo = alvo {
            guard nome == alvo, buscando, sessao != nil else { return }
            pararBusca()
            sessao!.periferico = p
            conectar()
            return
        }
        let novo = achados[nome] == nil
        achados[nome] = RSSI.intValue
        if novo { saida("window.bleAchado && bleAchado(\(q(chaveBusca)),{id:\(q(nome)),rssi:\(RSSI.intValue)})") }
    }

    // MARK: download

    func baixar(chave: String, id: String, desde: Int64, colonia: Int) {
        comBluetooth(chave) {
            if self.sessao != nil { self.erro(chave, "Já há um download em andamento."); return }
            self.sessao = Sessao(chave: chave, id: id, desde: desde, colonia: colonia)
            self.progresso(chave, "Procurando \(id)…", 5)
            self.iniciarBusca(chave: chave, segundos: 15, alvo: id)
        }
    }

    func cancelar() {
        DispatchQueue.main.async {
            if self.central != nil { self.pararBusca() }
            self.encerrar(nil)
        }
    }

    private func vivo() {
        vigia?.invalidate()
        vigia = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.encerrar("O aparelho parou de responder. Chegue mais perto e tente de novo.")
        }
    }

    private func conectar() {
        guard let s = sessao, let p = s.periferico else { return }
        progresso(s.chave, "Conectando ao \(s.id)…", 15)
        vivo()
        p.delegate = self
        central.connect(p, options: nil)
    }

    private func encerrar(_ msgErro: String?) {
        vigia?.invalidate()
        vigia = nil
        guard let s = sessao else { return }
        sessao = nil
        if let p = s.periferico, central != nil { central.cancelPeripheralConnection(p) }
        if let m = msgErro { erro(s.chave, m) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard let s = sessao else { return }
        vivo()
        progresso(s.chave, "Conectado. Lendo o aparelho…", 25)
        p.discoverServices([BeeMeterBLE.SERVICO])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        tentarDeNovoOuFalhar()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard sessao != nil else { return }
        tentarDeNovoOuFalhar()
    }

    private func tentarDeNovoOuFalhar() {
        guard var s = sessao else { return }
        if s.etapa < 3 && s.tentativas < 2 {
            s.tentativas += 1
            s.etapa = 0
            sessao = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.conectar() }
        } else {
            encerrar("A conexão com o aparelho caiu. Tente de novo.")
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard sessao != nil else { return }
        vivo()
        guard let srv = p.services?.first(where: { $0.uuid == BeeMeterBLE.SERVICO }) else {
            encerrar("Este aparelho não tem o firmware BeeMeter 2.2 ou mais novo."); return
        }
        p.discoverCharacteristics([BeeMeterBLE.C_INFO, BeeMeterBLE.C_AGORA, BeeMeterBLE.C_COMANDO, BeeMeterBLE.C_DADOS], for: srv)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor srv: CBService, error: Error?) {
        guard var s = sessao else { return }
        vivo()
        for c in srv.characteristics ?? [] {
            switch c.uuid {
            case BeeMeterBLE.C_INFO: s.cInfo = c
            case BeeMeterBLE.C_AGORA: s.cAgora = c
            case BeeMeterBLE.C_COMANDO: s.cComando = c
            case BeeMeterBLE.C_DADOS: s.cDados = c
            default: break
            }
        }
        sessao = s
        guard let d = s.cDados, s.cInfo != nil, s.cAgora != nil, s.cComando != nil else {
            encerrar("Aparelho sem o serviço completo do BeeMeter."); return
        }
        s.etapa = 1
        sessao = s
        p.setNotifyValue(true, for: d)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard var s = sessao, c.uuid == BeeMeterBLE.C_DADOS else { return }
        vivo()
        if error != nil { encerrar("Não foi possível abrir o canal de dados."); return }
        s.etapa = 2
        sessao = s
        p.readValue(for: s.cInfo!)
    }

    private func escrever(_ p: CBPeripheral, _ texto: String) {
        guard let c = sessao?.cComando else { return }
        p.writeValue(Data(texto.utf8), for: c, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard var s = sessao, let v = c.value else { return }
        vivo()
        switch c.uuid {
        case BeeMeterBLE.C_INFO:
            guard let o = (try? JSONSerialization.jsonObject(with: v)) as? [String: Any] else { encerrar("Resposta inválida do aparelho."); return }
            s.info = o
            s.epocaCelular = Int64(Date().timeIntervalSince1970)
            let proximo = (o["proximo"] as? NSNumber)?.int64Value ?? 1
            let primeiro = (o["primeiro"] as? NSNumber)?.int64Value ?? 1
            if s.desde > proximo { s.desde = 0 }
            s.esperados = max(0, proximo - max(s.desde, primeiro))
            s.etapa = 3
            sessao = s
            escrever(p, "HORA \(s.epocaCelular)")
        case BeeMeterBLE.C_AGORA:
            s.agora = (try? JSONSerialization.jsonObject(with: v)) ?? NSNull()
            s.etapa = 5
            sessao = s
            progresso(s.chave, s.esperados > 0 ? "Baixando \(s.esperados) registros…" : "Sem registros novos. Concluindo…", 40)
            escrever(p, "LER \(s.desde)")
        case BeeMeterBLE.C_DADOS:
            guard let t = v.first else { return }
            if t == UInt8(ascii: "D") {
                s.fluxo.append(v.dropFirst())
                let n = Int64(s.fluxo.count / BeeMeterBLE.TAM)
                if s.esperados > 0 && Date().timeIntervalSince(s.ultimoAviso) > 0.4 {
                    s.ultimoAviso = Date()
                    let pct = 40 + Int(55 * min(1.0, Double(n) / Double(s.esperados)))
                    progresso(s.chave, "Baixando registros: \(n) de \(s.esperados)", pct)
                }
                sessao = s
            } else if t == UInt8(ascii: "F") {
                concluir(s)
            }
        default: break
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard var s = sessao else { return }
        vivo()
        if error != nil { encerrar("Não foi possível enviar o comando ao aparelho."); return }
        if s.etapa == 3 {
            s.etapa = 4
            sessao = s
            p.readValue(for: s.cAgora!)
        }
    }

    private func u32(_ d: [UInt8], _ i: Int) -> Int64 {
        Int64(d[i]) | Int64(d[i + 1]) << 8 | Int64(d[i + 2]) << 16 | Int64(d[i + 3]) << 24
    }
    private func u16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    private func s16(_ d: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(d, i)))) }
    private func s32(_ d: [UInt8], _ i: Int) -> Int { Int(Int32(bitPattern: UInt32(u32(d, i)))) }

    private func concluir(_ s: Sessao) {
        let b = [UInt8](s.fluxo)
        let n = b.count / BeeMeterBLE.TAM
        let bootInfo = (s.info["boot"] as? NSNumber)?.int64Value ?? -1
        let upInfo = (s.info["up"] as? NSNumber)?.int64Value ?? 0
        var regs: [[String: Any]] = []
        var primeiroSeq: Int64 = -1, ultimoSeq: Int64 = -1, mIni: Int64 = 0, mFim: Int64 = 0
        for i in 0..<n {
            let o = i * BeeMeterBLE.TAM
            let seq = u32(b, o), epoca = u32(b, o + 4), up = u32(b, o + 8)
            let boot = Int64(u16(b, o + 12))
            let t10 = s16(b, o + 14), ur10 = u16(b, o + 16), lux = u16(b, o + 18)
            let tc1 = s16(b, o + 20), tc2 = s16(b, o + 22), tc3 = s16(b, o + 24)
            let pesoG = s32(b, o + 26)
            let val = Int(b[o + 30])
            var momento: Int64 = 0
            if epoca > 0 { momento = epoca } else if boot == bootInfo { momento = s.epocaCelular - (upInfo - up) }
            func campo(_ ok: Bool, _ x: Any) -> Any { ok ? x : NSNull() }
            let r: [String: Any] = [
                "seq": seq, "m": campo(momento > 0, momento), "b": boot, "u": up,
                "t": campo(val & 0x01 != 0, Double(t10) / 10.0),
                "ur": campo(val & 0x01 != 0, Double(ur10) / 10.0),
                "lux": campo(val & 0x02 != 0, lux),
                "tc1": campo(val & 0x04 != 0, Double(tc1) / 4.0),
                "tc2": campo(val & 0x08 != 0, Double(tc2) / 4.0),
                "tc3": campo(val & 0x10 != 0, Double(tc3) / 4.0),
                "p": campo(val & 0x20 != 0, Double(pesoG) / 1000.0),
            ]
            regs.append(r)
            if primeiroSeq < 0 { primeiroSeq = seq }
            ultimoSeq = seq
            if momento > 0 { if mIni == 0 { mIni = momento }; mFim = momento }
        }
        var nomeLote: Any = NSNull()
        if n > 0 {
            let lote: [String: Any] = ["aparelho": s.id, "colonia": s.colonia, "fw": s.info["fw"] ?? "",
                                       "baixado": s.epocaCelular, "registros": regs]
            let nome = "\(s.id)_\(s.epocaCelular).json"
            if let d = try? JSONSerialization.data(withJSONObject: lote) {
                do { try d.write(to: pastaLotes.appendingPathComponent(nome)); nomeLote = nome }
                catch { encerrar("Erro ao guardar os registros."); return }
            }
        }
        let res: [String: Any] = [
            "id": s.id, "fw": s.info["fw"] ?? "", "boot": s.info["boot"] ?? 0, "intervalo": s.info["intervalo"] ?? 0,
            "tara": s.info["tara"] ?? false, "proximo": s.info["proximo"] ?? 0, "n": n, "primeiro": primeiroSeq,
            "ultimo": ultimoSeq, "mIni": mIni, "mFim": mFim, "lote": nomeLote, "agora": s.agora, "quando": s.epocaCelular,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: res)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let chave = s.chave
        encerrar(nil)
        saida("window.bleConcluido && bleConcluido(\(q(chave)),\(json))")
    }

    // MARK: lotes guardados

    func lotesPendentes() -> String {
        let nomes = ((try? FileManager.default.contentsOfDirectory(atPath: pastaLotes.path)) ?? []).filter { $0.hasSuffix(".json") }
        let d = (try? JSONSerialization.data(withJSONObject: nomes)) ?? Data("[]".utf8)
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    func lerLote(nome: String) -> String {
        let url = pastaLotes.appendingPathComponent((nome as NSString).lastPathComponent)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func apagarLote(nome: String) {
        try? FileManager.default.removeItem(at: pastaLotes.appendingPathComponent((nome as NSString).lastPathComponent))
    }
}
