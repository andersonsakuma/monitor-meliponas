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
        var piscar = false
        var aoVivo = false
        var visita = ""
        var inicioVivo = Date()
        var vivoBuffer: [[String: Any]] = []
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
                self.erro(s.chave, "Aparelho \(alvo) não encontrado. Chegue mais perto da caixa e confira se a tela está acesa. Se outro celular estiver conectado a ele, espere terminar.")
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
        var col = ""
        if let fab = adv[CBAdvertisementDataManufacturerDataKey] as? Data, fab.count >= 5 {
            let b = [UInt8](fab)
            if b[2] == UInt8(ascii: "B") && b[3] == UInt8(ascii: "M") { col = ",colonia:\(b[4])" }
        }
        if novo { saida("window.bleAchado && bleAchado(\(q(chaveBusca)),{id:\(q(nome)),rssi:\(RSSI.intValue)\(col)})") }
    }

    // MARK: download

    func identificar(chave: String, id: String) {
        iniciar(chave: chave, id: id, desde: 0, colonia: 0, piscar: true)
    }

    func baixar(chave: String, id: String, desde: Int64, colonia: Int) {
        iniciar(chave: chave, id: id, desde: desde, colonia: colonia, piscar: false)
    }

    /// Baixa os registros novos e continua lendo o aparelho a cada 10 s, até parar().
    func aoVivo(chave: String, id: String, desde: Int64, colonia: Int, visita: String) {
        iniciar(chave: chave, id: id, desde: desde, colonia: colonia, piscar: false, aoVivo: true, visita: visita)
    }

    func parar() {
        DispatchQueue.main.async {
            if self.central != nil { self.pararBusca() }
            self.encerrar(nil)
        }
    }

    private func iniciar(chave: String, id: String, desde: Int64, colonia: Int, piscar: Bool,
                         aoVivo: Bool = false, visita: String = "") {
        comBluetooth(chave) {
            if self.sessao != nil { self.erro(chave, "Já há uma conexão em andamento."); return }
            self.sessao = Sessao(chave: chave, id: id, desde: desde, colonia: colonia)
            self.sessao!.piscar = piscar
            self.sessao!.aoVivo = aoVivo
            self.sessao!.visita = visita
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
            let vivo = (self?.sessao?.etapa ?? 0) >= 20
            self?.encerrar(vivo ? "O aparelho parou de responder. A leitura ao vivo foi encerrada." : "O aparelho parou de responder. Chegue mais perto e tente de novo.")
        }
    }

    private func conectar() {
        guard let s = sessao, let p = s.periferico else { return }
        progresso(s.chave, "Conectando ao \(s.id)…", 15)
        vivo()
        p.delegate = self
        central.connect(p, options: nil)
    }

    private var timerVivo: Timer?

    private func encerrar(_ msgErro: String?) {
        vigia?.invalidate()
        vigia = nil
        timerVivo?.invalidate()
        timerVivo = nil
        guard let s = sessao else { return }
        sessao = nil
        if let p = s.periferico, central != nil { central.cancelPeripheralConnection(p) }
        if s.etapa >= 20 {
            salvarVivo(s)
            saida("window.bleVivoFim && bleVivoFim(\(q(s.chave)),\(q(msgErro ?? "")))")
        } else if let m = msgErro { erro(s.chave, m) }
    }

    // MARK: histórico permanente (nunca apagado)

    private let filaHist = DispatchQueue(label: "historico")
    private var arqHistorico: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("historico", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("historico.csv")
    }

    private func txt(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }

    private func linhaHistorico(_ m: Int64, _ col: Int, _ ap: String, _ origem: String, _ seq: Int64, _ r: [String: Any]) -> String {
        "\(m);\(col);\(ap);\(origem);\(seq >= 0 ? String(seq) : "");\(txt(r["t"]));\(txt(r["ur"]));\(txt(r["lux"]));\(txt(r["tc1"]));\(txt(r["tc2"]));\(txt(r["tc3"]));\(txt(r["p"]))\n"
    }

    private func anexarHistorico(_ linhas: String) {
        guard !linhas.isEmpty else { return }
        filaHist.sync {
            let url = arqHistorico
            let dados = Data(linhas.utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(dados); h.closeFile()
            } else {
                try? dados.write(to: url)
            }
        }
    }

    /// Médias por hora (mesmo formato do Android).
    func historico(colonia: Int, desde: Int64) -> String {
        var texto = ""
        filaHist.sync { texto = (try? String(contentsOf: arqHistorico, encoding: .utf8)) ?? "" }
        var ag: [String: [Double]] = [:]
        for l in texto.split(separator: "\n") {
            let c = l.split(separator: ";", omittingEmptySubsequences: false)
            guard c.count >= 12, let m = Int64(c[0]), let col = Int(c[1]), m >= desde, col > 0,
                  colonia == 0 || col == colonia else { continue }
            let hora = (m / 3600) * 3600
            let k = String(format: "%012lld;%02d", hora, col)
            var a = ag[k] ?? { var x = [Double](repeating: 0, count: 17); x[15] = .greatestFiniteMagnitude; x[16] = -.greatestFiniteMagnitude; return x }()
            a[0] += 1
            for i in 0..<7 {
                guard let x = Double(c[5 + i]) else { continue }
                a[1 + i * 2] += x; a[2 + i * 2] += 1
                if i == 6 { a[15] = min(a[15], x); a[16] = max(a[16], x) }
            }
            ag[k] = a
        }
        var sb = ""
        for k in ag.keys.sorted() {
            let a = ag[k]!, p = k.split(separator: ";")
            sb += "\(Int64(p[0])!);\(Int(p[1])!);\(Int(a[0]))"
            for i in 0..<7 {
                sb += ";" + (a[2 + i * 2] > 0 ? String(format: "%.3f", a[1 + i * 2] / a[2 + i * 2]) : "") + ";\(Int(a[2 + i * 2]))"
            }
            sb += ";" + (a[14] > 0 ? String(format: "%.3f", a[15]) : "") + ";" + (a[14] > 0 ? String(format: "%.3f", a[16]) : "") + "\n"
        }
        return sb
    }

    /// Arquivo CSV completo com cabeçalho e data legível.
    func arquivoCsv() -> URL? {
        var texto = ""
        filaHist.sync { texto = (try? String(contentsOf: arqHistorico, encoding: .utf8)) ?? "" }
        let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        var sb = "\u{FEFF}momento_epoca;data_hora;colonia;aparelho;origem;seq;temp_amb;umidade;lux;tc_fundo;tc_divisao;tc_melgueira;peso_kg\n"
        for l in texto.split(separator: "\n") {
            guard let i = l.firstIndex(of: ";"), let m = Double(l[..<i]) else { continue }
            let resto = String(l[l.index(after: i)...]).replacingOccurrences(of: ";v;", with: ";ao vivo;")
                .replacingOccurrences(of: ";r;", with: ";registro;").replacingOccurrences(of: ".", with: ",")
            sb += "\(l[..<i]);\(f.string(from: Date(timeIntervalSince1970: m)));\(resto)\n"
        }
        let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("medicoes_meliponas_\(f2.string(from: Date())).csv")
        do { try sb.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    // MARK: leitura ao vivo

    private func registrarVivo(_ a: [String: Any]) {
        guard var s = sessao else { return }
        let m = Int64(Date().timeIntervalSince1970)
        let tc = a["tc"] as? [Any] ?? []
        let r: [String: Any] = ["m": m, "t": a["t"] ?? NSNull(), "ur": a["ur"] ?? NSNull(), "lux": a["lux"] ?? NSNull(),
                                "tc1": tc.count > 0 ? tc[0] : NSNull(), "tc2": tc.count > 1 ? tc[1] : NSNull(),
                                "tc3": tc.count > 2 ? tc[2] : NSNull(), "p": a["peso"] ?? NSNull()]
        s.vivoBuffer.append(r)
        sessao = s
        anexarHistorico(linhaHistorico(m, abs(s.colonia), s.id, "v", -1, r))
        var env = a
        env["m"] = m
        env["n"] = s.vivoBuffer.count
        if let d = try? JSONSerialization.data(withJSONObject: env), let j = String(data: d, encoding: .utf8) {
            saida("window.bleLeitura && bleLeitura(\(q(s.chave)),\(j))")
        }
    }

    private func salvarVivo(_ s: Sessao) {
        guard !s.vivoBuffer.isEmpty else { return }
        let lote: [String: Any] = ["tipo": "vivo", "aparelho": s.id, "colonia": abs(s.colonia), "visita": s.visita, "registros": s.vivoBuffer]
        if let d = try? JSONSerialization.data(withJSONObject: lote) {
            try? d.write(to: pastaLotes.appendingPathComponent("vivo_\(s.id)_\(Int64(Date().timeIntervalSince1970)).json"))
        }
    }

    private func agendarVivo() {
        timerVivo?.invalidate()
        timerVivo = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self, let s = self.sessao, let p = s.periferico, let c = s.cAgora else { return }
            if Date().timeIntervalSince(s.inicioVivo) > 1800 { self.encerrar("Leitura ao vivo encerrada após 30 minutos."); return }
            p.readValue(for: c)
        }
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
        if s.etapa >= 20 { encerrar("A conexão com o aparelho caiu. A leitura ao vivo foi encerrada."); return }
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
        if s.piscar {
            s.etapa = 9
            sessao = s
            escrever(p, "PISCAR")
            return
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
            let colAparelho = (o["colonia"] as? NSNumber)?.intValue ?? 0
            let colPedida = abs(s.colonia)
            if colPedida > 0 && colAparelho > 0 && colAparelho != colPedida && s.colonia > 0 {
                let chave = s.chave
                encerrar(nil)
                saida("window.bleErro && bleErro(\(q(chave)),\(q("Este aparelho está gravado como colônia \(colAparelho), não \(colPedida). Confira se está na caixa certa.")),'colonia',\(colAparelho))")
                return
            }
            let proximo = (o["proximo"] as? NSNumber)?.int64Value ?? 1
            let primeiro = (o["primeiro"] as? NSNumber)?.int64Value ?? 1
            if s.desde > proximo { s.desde = 0 }
            s.esperados = max(0, proximo - max(s.desde, primeiro))
            s.etapa = 3
            sessao = s
            escrever(p, "HORA \(s.epocaCelular)" + (colPedida > 0 && colAparelho != colPedida ? " \(colPedida)" : ""))
        case BeeMeterBLE.C_AGORA where s.etapa >= 20:
            if let a = (try? JSONSerialization.jsonObject(with: v)) as? [String: Any] { registrarVivo(a) }
            agendarVivo()
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
                if v.count >= 9 {
                    let f = [UInt8](v)
                    let crcAparelho = UInt32(f[5]) | UInt32(f[6]) << 8 | UInt32(f[7]) << 16 | UInt32(f[8]) << 24
                    if BeeMeterBLE.crc32([UInt8](s.fluxo)) != crcAparelho {
                        encerrar("Os dados chegaram com falha. Toque em Tentar de novo."); return
                    }
                }
                concluir(s)
            }
        default: break
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard var s = sessao else { return }
        vivo()
        if error != nil { encerrar("Não foi possível enviar o comando ao aparelho."); return }
        if s.etapa == 9 {
            let chave = s.chave, id = s.id
            encerrar(nil)
            saida("window.bleIdentificado && bleIdentificado(\(q(chave)),\(q(id)))")
            return
        }
        if s.etapa == 3 {
            s.etapa = 4
            sessao = s
            p.readValue(for: s.cAgora!)
        }
    }

    /// CRC32 igual ao do firmware e do zlib (polinômio 0xEDB88320).
    static func crc32(_ dados: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in dados {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
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
        var hist = ""
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
            if momento > 0 { hist += linhaHistorico(momento, abs(s.colonia), s.id, "r", seq, r) }
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
            "id": s.id, "colonia": abs(s.colonia), "fw": s.info["fw"] ?? "", "boot": s.info["boot"] ?? 0, "intervalo": s.info["intervalo"] ?? 0,
            "tara": s.info["tara"] ?? false, "proximo": s.info["proximo"] ?? 0, "n": n, "primeiro": primeiroSeq,
            "ultimo": ultimoSeq, "mIni": mIni, "mFim": mFim, "lote": nomeLote, "agora": s.agora, "quando": s.epocaCelular,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: res)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let chave = s.chave
        anexarHistorico(hist)
        if s.aoVivo {
            saida("window.bleConcluido && bleConcluido(\(q(chave)),\(json))")
            guard var atualizada = sessao else { return }
            atualizada.etapa = 20
            atualizada.inicioVivo = Date()
            sessao = atualizada
            vivo()
            if let a = s.agora as? [String: Any] { registrarVivo(a) }
            agendarVivo()
        } else {
            encerrar(nil)
            saida("window.bleConcluido && bleConcluido(\(q(chave)),\(json))")
        }
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
