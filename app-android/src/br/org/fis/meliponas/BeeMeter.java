package br.org.fis.meliponas;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Comunicacao com o BeeMeter (firmware 2.2.0-BLE) pelo Bluetooth de baixa energia.
 * Protocolo: ver docs/PROTOCOLO_BLE.md no repositorio.
 */
public class BeeMeter {
    public interface Saida { void js(String codigo); }

    static final UUID SERVICO = UUID.fromString("6e7a0001-b5a3-4f4b-9a3e-6d656c697061");
    static final UUID C_INFO = UUID.fromString("6e7a0002-b5a3-4f4b-9a3e-6d656c697061");
    static final UUID C_AGORA = UUID.fromString("6e7a0003-b5a3-4f4b-9a3e-6d656c697061");
    static final UUID C_COMANDO = UUID.fromString("6e7a0004-b5a3-4f4b-9a3e-6d656c697061");
    static final UUID C_DADOS = UUID.fromString("6e7a0005-b5a3-4f4b-9a3e-6d656c697061");
    static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    static final int TAM_REGISTRO = 32;
    static final long LIMITE_SILENCIO_MS = 20000;

    private final Context ctx;
    private final Saida saida;
    private final Handler h = new Handler(Looper.getMainLooper());
    private final File pastaLotes;
    private final File arqHistorico;
    static final long INTERVALO_VIVO_MS = 10000, LIMITE_VIVO_MS = 30 * 60 * 1000;

    public BeeMeter(Context ctx, Saida saida) {
        this.ctx = ctx;
        this.saida = saida;
        this.pastaLotes = new File(ctx.getFilesDir(), "lotes");
        if (!pastaLotes.exists()) pastaLotes.mkdirs();
        File ph = new File(ctx.getFilesDir(), "historico");
        if (!ph.exists()) ph.mkdirs();
        this.arqHistorico = new File(ph, "historico.csv");
    }

    /* ------------------------------------------- histórico permanente */
    /* Uma linha por medida, nunca apagada:
       momento;colonia;aparelho;origem(r=registro do aparelho, v=ao vivo);seq;t;ur;lux;tc1;tc2;tc3;peso */
    static final String CABECALHO = "momento_epoca;data_hora;colonia;aparelho;origem;seq;temp_amb;umidade;lux;tc_fundo;tc_divisao;tc_melgueira;peso_kg";

    static String n(Object o) { return (o == null || o == JSONObject.NULL) ? "" : String.valueOf(o); }

    synchronized void anexarHistorico(StringBuilder linhas) {
        if (linhas.length() == 0) return;
        try {
            FileOutputStream fo = new FileOutputStream(arqHistorico, true);
            fo.write(linhas.toString().getBytes("UTF-8"));
            fo.close();
        } catch (Exception e) { }
    }

    static String linhaHistorico(long m, int col, String ap, String origem, long seq, JSONObject r) {
        return m + ";" + col + ";" + ap + ";" + origem + ";" + (seq >= 0 ? String.valueOf(seq) : "") + ";" +
            n(r.opt("t")) + ";" + n(r.opt("ur")) + ";" + n(r.opt("lux")) + ";" + n(r.opt("tc1")) + ";" +
            n(r.opt("tc2")) + ";" + n(r.opt("tc3")) + ";" + n(r.opt("p")) + "\n";
    }

    /** Médias por hora: hora;colonia;n;t;nt;ur;nur;lux;nlux;tc1;ntc1;tc2;ntc2;tc3;ntc3;peso;npeso;pmin;pmax */
    public synchronized String historico(int colonia, long desde) {
        java.util.TreeMap<String, double[]> ag = new java.util.TreeMap<String, double[]>();
        try {
            if (!arqHistorico.exists()) return "";
            java.io.BufferedReader br = new java.io.BufferedReader(new java.io.InputStreamReader(new java.io.FileInputStream(arqHistorico), "UTF-8"));
            String l;
            while ((l = br.readLine()) != null) {
                String[] c = l.split(";", -1);
                if (c.length < 12) continue;
                long m; int col;
                try { m = Long.parseLong(c[0]); col = Integer.parseInt(c[1]); } catch (Exception e) { continue; }
                if (m < desde || col <= 0 || (colonia > 0 && col != colonia)) continue;
                long hora = (m / 3600) * 3600;
                String k = String.format(java.util.Locale.US, "%012d;%02d", hora, col);
                double[] a = ag.get(k);
                if (a == null) { a = new double[17]; a[15] = Double.MAX_VALUE; a[16] = -Double.MAX_VALUE; ag.put(k, a); }
                a[0]++;
                for (int i = 0; i < 7; i++) {
                    String v = c[5 + i];
                    if (v.length() == 0) continue;
                    try { double x = Double.parseDouble(v); a[1 + i * 2] += x; a[2 + i * 2]++; if (i == 6) { a[15] = Math.min(a[15], x); a[16] = Math.max(a[16], x); } } catch (Exception e) { }
                }
            }
            br.close();
        } catch (Exception e) { return ""; }
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, double[]> e : ag.entrySet()) {
            String[] k = e.getKey().split(";");
            double[] a = e.getValue();
            sb.append(Long.parseLong(k[0])).append(';').append(Integer.parseInt(k[1])).append(';').append((long) a[0]);
            for (int i = 0; i < 7; i++) {
                sb.append(';');
                if (a[2 + i * 2] > 0) sb.append(String.format(java.util.Locale.US, "%.3f", a[1 + i * 2] / a[2 + i * 2]));
                sb.append(';').append((long) a[2 + i * 2]);
            }
            sb.append(';').append(a[14] > 0 ? String.format(java.util.Locale.US, "%.3f", a[15]) : "");
            sb.append(';').append(a[14] > 0 ? String.format(java.util.Locale.US, "%.3f", a[16]) : "");
            sb.append('\n');
        }
        return sb.toString();
    }

    /** CSV completo, com cabeçalho e data legível, para guardar fora do aplicativo. */
    public synchronized void exportarCsv(java.io.OutputStream out) throws Exception {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("dd/MM/yyyy HH:mm:ss", java.util.Locale.US);
        out.write(("\uFEFF" + CABECALHO + "\n").getBytes("UTF-8"));
        if (!arqHistorico.exists()) return;
        java.io.BufferedReader br = new java.io.BufferedReader(new java.io.InputStreamReader(new java.io.FileInputStream(arqHistorico), "UTF-8"));
        String l;
        StringBuilder sb = new StringBuilder();
        while ((l = br.readLine()) != null) {
            int i = l.indexOf(';');
            if (i < 0) continue;
            String data;
            try { data = f.format(new java.util.Date(Long.parseLong(l.substring(0, i)) * 1000L)); } catch (Exception e) { data = ""; }
            String resto = l.substring(i + 1).replace(";v;", ";ao vivo;").replace(";r;", ";registro;").replace('.', ',');
            sb.append(l, 0, i).append(';').append(data).append(';').append(resto).append('\n');
            if (sb.length() > 65536) { out.write(sb.toString().getBytes("UTF-8")); sb.setLength(0); }
        }
        br.close();
        out.write(sb.toString().getBytes("UTF-8"));
    }

    static String q(String s) {
        if (s == null) return "null";
        return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ") + "'";
    }

    BluetoothAdapter adaptador() {
        BluetoothManager bm = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        return bm == null ? null : bm.getAdapter();
    }

    /* ------------------------------------------------------------- busca */

    private ScanCallback buscaCb;
    private BluetoothLeScanner buscador;

    public void buscar(final String chave, int segundos, final String alvo, final Achou aoAchar) {
        BluetoothAdapter a = adaptador();
        if (a == null || !a.isEnabled()) { erro(chave, "O Bluetooth está desligado. Ligue o Bluetooth e tente de novo."); return; }
        pararBusca();
        buscador = a.getBluetoothLeScanner();
        if (buscador == null) { erro(chave, "Bluetooth indisponível neste celular."); return; }
        final Map<String, JSONObject> achados = new HashMap<String, JSONObject>();
        final boolean[] fim = {false};
        buscaCb = new ScanCallback() {
            @Override
            public void onScanResult(int tipo, ScanResult r) {
                String nome = null;
                if (r.getScanRecord() != null) nome = r.getScanRecord().getDeviceName();
                if (nome == null) { try { nome = r.getDevice().getName(); } catch (SecurityException e) { nome = null; } }
                if (nome == null || !nome.startsWith("BM-")) return;
                if (alvo != null) {
                    if (nome.equals(alvo) && !fim[0]) { fim[0] = true; pararBusca(); aoAchar.achou(r.getDevice()); }
                    return;
                }
                boolean novo = !achados.containsKey(nome);
                try {
                    JSONObject o = new JSONObject();
                    o.put("id", nome); o.put("rssi", r.getRssi());
                    byte[] fab = r.getScanRecord() != null ? r.getScanRecord().getManufacturerSpecificData(0xFFFF) : null;
                    if (fab != null && fab.length >= 3 && fab[0] == 'B' && fab[1] == 'M') o.put("colonia", fab[2] & 0xFF);
                    achados.put(nome, o);
                    if (novo) saida.js("window.bleAchado && bleAchado(" + q(chave) + "," + o.toString() + ")");
                } catch (Exception e) { }
            }
            @Override
            public void onScanFailed(int codigo) {
                atualPendente = null;
                if (!fim[0]) { fim[0] = true; erro(chave, "Falha ao procurar aparelhos (código " + codigo + ")."); }
            }
        };
        ScanSettings cfg = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
        try { buscador.startScan(null, cfg, buscaCb); }
        catch (SecurityException e) { erro(chave, "Sem permissão para usar o Bluetooth."); return; }
        h.postDelayed(new Runnable() { public void run() {
            if (fim[0]) return;
            fim[0] = true;
            pararBusca();
            if (alvo != null) { aoAchar.naoAchou(); return; }
            JSONArray lista = new JSONArray();
            for (JSONObject o : achados.values()) lista.put(o);
            saida.js("window.bleBuscaFim && bleBuscaFim(" + q(chave) + "," + lista.toString() + ")");
        }}, segundos * 1000L);
    }

    public void pararBusca() {
        try { if (buscador != null && buscaCb != null) buscador.stopScan(buscaCb); } catch (Exception e) { }
        buscaCb = null;
    }

    interface Achou { void achou(BluetoothDevice d); void naoAchou(); }

    /* ------------------------------------------------------- download */

    private Sessao atual;

    public void baixar(final String chave, final String id, final long desde, final int colonia) {
        iniciar(chave, id, desde, colonia, false);
    }

    /** Baixa os registros novos e continua conectado lendo o aparelho a cada 10 s, até parar(). */
    public void aoVivo(final String chave, final String id, final long desde, final int colonia, final String visita) {
        iniciar(chave, id, desde, colonia, false);
        if (atualPendente != null) { atualPendente.aoVivo = true; atualPendente.visita = visita; }
    }

    public void parar() {
        pararBusca();
        if (atual != null) atual.encerrar(null);
        atualPendente = null;
    }

    /** Faz a tela do aparelho piscar com a colônia e o nome, para conferir a caixa. */
    public void identificar(final String chave, final String id) {
        iniciar(chave, id, 0, 0, true);
    }

    private Sessao atualPendente;

    private void iniciar(final String chave, final String id, final long desde, final int colonia, final boolean piscar) {
        if (atual != null || atualPendente != null) { erro(chave, "Já há uma conexão em andamento."); return; }
        final Sessao nova = new Sessao(chave, id, desde, colonia, null);
        nova.piscar = piscar;
        atualPendente = nova;
        progresso(chave, "Procurando " + id + "…", 5);
        buscar(chave, 15, id, new Achou() {
            public void achou(BluetoothDevice d) {
                if (atualPendente != nova) return;
                atualPendente = null;
                nova.dispositivo = d;
                atual = nova;
                atual.conectar();
            }
            public void naoAchou() {
                if (atualPendente != nova) return;
                atualPendente = null;
                erro(chave, "Aparelho " + id + " não encontrado. Chegue mais perto da caixa e confira se a tela está acesa. Se outro celular estiver conectado a ele, espere terminar.");
            }
        });
        if (buscaCb == null) atualPendente = null;  /* a busca nem começou (Bluetooth desligado) */
    }

    public void cancelar() { parar(); }

    void progresso(String chave, String texto, int pct) {
        saida.js("window.bleProgresso && bleProgresso(" + q(chave) + "," + q(texto) + "," + pct + ")");
    }

    void erro(String chave, String msg) {
        saida.js("window.bleErro && bleErro(" + q(chave) + "," + q(msg) + ")");
    }

    private class Sessao extends BluetoothGattCallback {
        final String chave, id;
        long desde;
        final int colonia;
        BluetoothDevice dispositivo;
        boolean aoVivo = false;
        String visita = "";
        long inicioVivo = 0;
        final JSONArray vivoBuffer = new JSONArray();
        BluetoothGatt gatt;
        int etapa = 0, tentativas = 0;
        boolean terminado = false, piscar = false;
        JSONObject info, agora;
        long epocaCelular;
        final ByteArrayOutputStream fluxo = new ByteArrayOutputStream();
        long esperados = 0;
        final Runnable vigia = new Runnable() { public void run() {
            encerrar(etapa >= 20 ? "O aparelho parou de responder. A leitura ao vivo foi encerrada." : "O aparelho parou de responder. Chegue mais perto e tente de novo.");
        }};

        Sessao(String chave, String id, long desde, int colonia, BluetoothDevice d) {
            this.chave = chave; this.id = id; this.desde = desde; this.colonia = colonia; this.dispositivo = d;
        }

        void vivo() { h.removeCallbacks(vigia); h.postDelayed(vigia, LIMITE_SILENCIO_MS); }

        void conectar() {
            progresso(chave, "Conectando ao " + id + "…", 15);
            vivo();
            try { gatt = dispositivo.connectGatt(ctx, false, this, BluetoothDevice.TRANSPORT_LE); }
            catch (SecurityException e) { encerrar("Sem permissão para usar o Bluetooth."); }
        }

        void encerrarSilencioso() {
            terminado = true;
            h.removeCallbacks(vigia);
            try { if (gatt != null) { gatt.disconnect(); gatt.close(); } } catch (Exception e) { }
            atual = null;
        }

        void encerrar(String msgErro) {
            if (terminado) return;
            terminado = true;
            h.removeCallbacks(vigia);
            h.removeCallbacks(lerVivo);
            try { if (gatt != null) { gatt.disconnect(); gatt.close(); } } catch (Exception e) { }
            atual = null;
            if (etapa >= 20) {
                salvarVivo();
                saida.js("window.bleVivoFim && bleVivoFim(" + q(chave) + "," + q(msgErro == null ? "" : msgErro) + ")");
            } else if (msgErro != null) erro(chave, msgErro);
        }

        final Runnable lerVivo = new Runnable() { public void run() {
            if (terminado) return;
            if (System.currentTimeMillis() - inicioVivo > LIMITE_VIVO_MS) { encerrar("Leitura ao vivo encerrada após 30 minutos."); return; }
            ler(C_AGORA);
        }};

        void registrarVivo(JSONObject a) {
            try {
                long m = System.currentTimeMillis() / 1000L;
                JSONArray tc = a.optJSONArray("tc");
                JSONObject r = new JSONObject();
                r.put("m", m);
                r.put("t", a.opt("t")); r.put("ur", a.opt("ur")); r.put("lux", a.opt("lux"));
                r.put("tc1", tc != null ? tc.opt(0) : JSONObject.NULL);
                r.put("tc2", tc != null ? tc.opt(1) : JSONObject.NULL);
                r.put("tc3", tc != null ? tc.opt(2) : JSONObject.NULL);
                r.put("p", a.opt("peso"));
                vivoBuffer.put(r);
                StringBuilder sb = new StringBuilder();
                sb.append(linhaHistorico(m, Math.abs(colonia), id, "v", -1, r));
                anexarHistorico(sb);
                JSONObject env = new JSONObject(a.toString());
                env.put("m", m);
                env.put("n", vivoBuffer.length());
                saida.js("window.bleLeitura && bleLeitura(" + q(chave) + "," + env.toString() + ")");
            } catch (Exception e) { }
        }

        void salvarVivo() {
            if (vivoBuffer.length() == 0) return;
            try {
                JSONObject lote = new JSONObject();
                lote.put("tipo", "vivo");
                lote.put("aparelho", id);
                lote.put("colonia", Math.abs(colonia));
                lote.put("visita", visita);
                lote.put("registros", vivoBuffer);
                FileOutputStream fo = new FileOutputStream(new File(pastaLotes, "vivo_" + id + "_" + (System.currentTimeMillis() / 1000L) + ".json"));
                fo.write(lote.toString().getBytes("UTF-8"));
                fo.close();
            } catch (Exception e) { }
        }

        BluetoothGattCharacteristic car(UUID u) {
            BluetoothGattService s = gatt.getService(SERVICO);
            return s == null ? null : s.getCharacteristic(u);
        }

        void escrever(String comando) {
            BluetoothGattCharacteristic c = car(C_COMANDO);
            if (c == null) { encerrar("Aparelho sem o serviço do BeeMeter."); return; }
            c.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            c.setValue(comando.getBytes());
            if (!gatt.writeCharacteristic(c)) encerrar("Não foi possível enviar o comando ao aparelho.");
        }

        void ler(UUID u) {
            BluetoothGattCharacteristic c = car(u);
            if (c == null || !gatt.readCharacteristic(c)) encerrar("Não foi possível ler o aparelho.");
        }

        @Override
        public void onConnectionStateChange(final BluetoothGatt g, int status, int novo) {
            if (terminado) return;
            if (novo == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                vivo();
                progresso(chave, "Conectado. Lendo o aparelho…", 25);
                h.postDelayed(new Runnable() { public void run() { if (!terminado) g.discoverServices(); } }, 400);
            } else if (novo == BluetoothProfile.STATE_DISCONNECTED) {
                try { g.close(); } catch (Exception e) { }
                if (etapa >= 20) { encerrar("A conexão com o aparelho caiu. A leitura ao vivo foi encerrada."); return; }
                if (etapa < 3 && tentativas < 2) {
                    tentativas++;
                    h.postDelayed(new Runnable() { public void run() { if (!terminado) conectar(); } }, 800);
                } else {
                    encerrar("A conexão com o aparelho caiu. Tente de novo.");
                }
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            if (terminado) return;
            vivo();
            if (g.getService(SERVICO) == null) { encerrar("Este aparelho não tem o firmware BeeMeter 2.2 ou mais novo."); return; }
            if (piscar) { etapa = 9; escrever("PISCAR"); return; }
            etapa = 1;
            if (!g.requestMtu(247)) ativarNotificacoes();
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            if (terminado) return;
            vivo();
            ativarNotificacoes();
        }

        void ativarNotificacoes() {
            BluetoothGattCharacteristic d = car(C_DADOS);
            if (d == null) { encerrar("Aparelho sem o canal de dados."); return; }
            gatt.setCharacteristicNotification(d, true);
            BluetoothGattDescriptor ds = d.getDescriptor(CCCD);
            if (ds == null) { encerrar("Aparelho sem o canal de dados."); return; }
            ds.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            if (!gatt.writeDescriptor(ds)) encerrar("Não foi possível abrir o canal de dados.");
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            if (terminado) return;
            vivo();
            etapa = 2;
            ler(C_INFO);
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (terminado) return;
            vivo();
            try {
                String txt = new String(c.getValue(), "UTF-8");
                if (C_INFO.equals(c.getUuid())) {
                    info = new JSONObject(txt);
                    epocaCelular = System.currentTimeMillis() / 1000L;
                    int colAparelho = info.optInt("colonia", 0), colPedida = Math.abs(colonia);
                    boolean forcar = colonia < 0;
                    if (colPedida > 0 && colAparelho > 0 && colAparelho != colPedida && !forcar) {
                        final int ca = colAparelho;
                        encerrarSilencioso();
                        saida.js("window.bleErro && bleErro(" + q(chave) + "," + q("Este aparelho está gravado como colônia " + ca + ", não " + colPedida + ". Confira se está na caixa certa.") + ",'colonia'," + ca + ")");
                        return;
                    }
                    long proximo = info.optLong("proximo", 1), primeiro = info.optLong("primeiro", 1);
                    if (desde > proximo) desde = 0;  /* registro do aparelho foi refeito */
                    esperados = Math.max(0, proximo - Math.max(desde, primeiro));
                    etapa = 3;
                    escrever("HORA " + epocaCelular + (colPedida > 0 && colAparelho != colPedida ? " " + colPedida : ""));
                } else if (C_AGORA.equals(c.getUuid()) && etapa >= 20) {
                    registrarVivo(new JSONObject(txt));
                    h.postDelayed(lerVivo, INTERVALO_VIVO_MS);
                } else if (C_AGORA.equals(c.getUuid())) {
                    agora = new JSONObject(txt);
                    etapa = 5;
                    progresso(chave, esperados > 0 ? "Baixando " + esperados + " registros…" : "Sem registros novos. Concluindo…", 40);
                    escrever("LER " + desde);
                }
            } catch (Exception e) {
                encerrar("Resposta inválida do aparelho.");
            }
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (terminado) return;
            vivo();
            if (etapa == 9) {
                final String js = "window.bleIdentificado && bleIdentificado(" + q(chave) + "," + q(id) + ")";
                encerrar(null);
                saida.js(js);
                return;
            }
            if (etapa == 3) { etapa = 4; ler(C_AGORA); }
        }

        long ultimoAviso = 0;

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            if (terminado || !C_DADOS.equals(c.getUuid())) return;
            vivo();
            byte[] v = c.getValue();
            if (v == null || v.length == 0) return;
            if (v[0] == 'D') {
                fluxo.write(v, 1, v.length - 1);
                long n = fluxo.size() / TAM_REGISTRO;
                long t = System.currentTimeMillis();
                if (esperados > 0 && t - ultimoAviso > 400) {
                    ultimoAviso = t;
                    progresso(chave, "Baixando registros: " + n + " de " + esperados, (int) (40 + 55 * Math.min(1.0, n / (double) esperados)));
                }
            } else if (v[0] == 'F') {
                if (v.length >= 9) {
                    long crcAparelho = ByteBuffer.wrap(v, 5, 4).order(ByteOrder.LITTLE_ENDIAN).getInt() & 0xFFFFFFFFL;
                    java.util.zip.CRC32 crc = new java.util.zip.CRC32();
                    crc.update(fluxo.toByteArray());
                    if (crc.getValue() != crcAparelho) { encerrar("Os dados chegaram com falha. Toque em Tentar de novo."); return; }
                }
                concluir();
            }
        }

        void concluir() {
            try {
                byte[] b = fluxo.toByteArray();
                int n = b.length / TAM_REGISTRO;
                ByteBuffer bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN);
                long bootInfo = info.optLong("boot", -1), upInfo = info.optLong("up", 0);
                JSONArray regs = new JSONArray();
                StringBuilder hist = new StringBuilder();
                long primeiroSeq = -1, ultimoSeq = -1, mIni = 0, mFim = 0;
                for (int i = 0; i < n; i++) {
                    bb.position(i * TAM_REGISTRO);
                    long seq = bb.getInt() & 0xFFFFFFFFL;
                    long epoca = bb.getInt() & 0xFFFFFFFFL;
                    long up = bb.getInt() & 0xFFFFFFFFL;
                    int boot = bb.getShort() & 0xFFFF;
                    short t10 = bb.getShort();
                    int ur10 = bb.getShort() & 0xFFFF;
                    int lux = bb.getShort() & 0xFFFF;
                    short tc1 = bb.getShort(), tc2 = bb.getShort(), tc3 = bb.getShort();
                    int pesoG = bb.getInt();
                    int val = bb.get() & 0xFF;
                    long momento = 0;
                    if (epoca > 0) momento = epoca;
                    else if (boot == bootInfo) momento = epocaCelular - (upInfo - up);
                    JSONObject r = new JSONObject();
                    r.put("seq", seq);
                    r.put("m", momento > 0 ? momento : JSONObject.NULL);
                    r.put("b", boot);
                    r.put("u", up);
                    r.put("t", (val & 0x01) != 0 ? t10 / 10.0 : JSONObject.NULL);
                    r.put("ur", (val & 0x01) != 0 ? ur10 / 10.0 : JSONObject.NULL);
                    r.put("lux", (val & 0x02) != 0 ? (Object) lux : JSONObject.NULL);
                    r.put("tc1", (val & 0x04) != 0 ? tc1 / 4.0 : JSONObject.NULL);
                    r.put("tc2", (val & 0x08) != 0 ? tc2 / 4.0 : JSONObject.NULL);
                    r.put("tc3", (val & 0x10) != 0 ? tc3 / 4.0 : JSONObject.NULL);
                    r.put("p", (val & 0x20) != 0 ? pesoG / 1000.0 : JSONObject.NULL);
                    regs.put(r);
                    if (momento > 0) hist.append(linhaHistorico(momento, Math.abs(colonia), id, "r", seq, r));
                    if (primeiroSeq < 0) primeiroSeq = seq;
                    ultimoSeq = seq;
                    if (momento > 0) { if (mIni == 0) mIni = momento; mFim = momento; }
                }
                String nomeLote = null;
                if (n > 0) {
                    JSONObject lote = new JSONObject();
                    lote.put("aparelho", id);
                    lote.put("colonia", colonia);
                    lote.put("fw", info.optString("fw"));
                    lote.put("baixado", epocaCelular);
                    lote.put("registros", regs);
                    nomeLote = id + "_" + epocaCelular + ".json";
                    FileOutputStream fo = new FileOutputStream(new File(pastaLotes, nomeLote));
                    fo.write(lote.toString().getBytes("UTF-8"));
                    fo.close();
                }
                JSONObject res = new JSONObject();
                res.put("id", id);
                res.put("colonia", Math.abs(colonia));
                res.put("fw", info.optString("fw"));
                res.put("boot", info.optLong("boot"));
                res.put("intervalo", info.optLong("intervalo"));
                res.put("tara", info.optBoolean("tara"));
                res.put("proximo", info.optLong("proximo"));
                res.put("n", n);
                res.put("primeiro", primeiroSeq);
                res.put("ultimo", ultimoSeq);
                res.put("mIni", mIni);
                res.put("mFim", mFim);
                res.put("lote", nomeLote == null ? JSONObject.NULL : nomeLote);
                res.put("agora", agora);
                res.put("quando", epocaCelular);
                anexarHistorico(hist);
                final String js = "window.bleConcluido && bleConcluido(" + q(chave) + "," + res.toString() + ")";
                if (aoVivo) {
                    saida.js(js);
                    etapa = 20;
                    inicioVivo = System.currentTimeMillis();
                    vivo();
                    registrarVivo(agora);
                    h.postDelayed(lerVivo, INTERVALO_VIVO_MS);
                } else {
                    encerrar(null);
                    saida.js(js);
                }
            } catch (Exception e) {
                encerrar("Erro ao guardar os registros: " + e.getMessage());
            }
        }
    }

    /* --------------------------------------------- lotes guardados */

    public String lotesPendentes() {
        JSONArray a = new JSONArray();
        File[] fs = pastaLotes.listFiles();
        if (fs != null) for (File f : fs) if (f.getName().endsWith(".json")) a.put(f.getName());
        return a.toString();
    }

    public String lerLote(String nome) {
        try {
            File f = new File(pastaLotes, new File(nome).getName());
            byte[] b = new byte[(int) f.length()];
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            int lido = 0;
            while (lido < b.length) { int r = in.read(b, lido, b.length - lido); if (r < 0) break; lido += r; }
            in.close();
            return new String(b, 0, lido, "UTF-8");
        } catch (Exception e) { return ""; }
    }

    public void apagarLote(String nome) { new File(pastaLotes, new File(nome).getName()).delete(); }
}
