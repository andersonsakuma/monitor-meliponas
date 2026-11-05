package br.org.fis.meliponas;

import android.Manifest;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.media.MediaPlayer;
import android.media.MediaRecorder;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.MediaStore;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.UUID;

public class MainActivity extends Activity {
    private static final int REQ_CSV = 3, REQ_CAMERA = 1, REQ_GALERIA = 2, PERM_AUDIO = 10, PERM_ARMAZ = 11, PERM_BLE = 12;
    private BeeMeter beemeter;
    private Runnable acaoBle;
    private String chaveBle;
    private WebView web;
    private Uri fotoUri;
    private String chaveFoto;
    private MediaRecorder gravador;
    private String audioId, chaveAudio;
    private long audioInicio;
    private MediaPlayer player;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(Color.parseColor("#3B2414"));
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setTextZoom(100);
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Ponte(), "Android");
        beemeter = new BeeMeter(this, new BeeMeter.Saida() { public void js(String c) { MainActivity.this.js(c); } });
        web.loadUrl("file:///android_asset/index.html");
        FrameLayout caixa = new FrameLayout(this);
        caixa.setFitsSystemWindows(true);
        caixa.setBackgroundColor(Color.parseColor("#3B2414"));
        caixa.addView(web, new FrameLayout.LayoutParams(-1, -1));
        setContentView(caixa);
    }

    @Override
    protected void onResume() {
        super.onResume();
        js("window.aoVoltarAoApp && window.aoVoltarAoApp()");
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (player != null) { try { player.release(); } catch (Exception e) {} player = null; }
    }

    @Override
    public void onBackPressed() {
        web.evaluateJavascript("window.voltar ? String(window.voltar()) : 'false'", new ValueCallback<String>() {
            public void onReceiveValue(String v) {
                if (v == null || !v.contains("true")) MainActivity.super.onBackPressed();
            }
        });
    }

    private void js(final String codigo) {
        runOnUiThread(new Runnable() { public void run() { web.evaluateJavascript(codigo, null); } });
    }

    private static String q(String s) {
        if (s == null) return "null";
        return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ") + "'";
    }

    private File pastaMidias() {
        File d = new File(getFilesDir(), "midias");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    /* ---------- fotos ---------- */
    private void abrirCamera() {
        try {
            ContentValues cv = new ContentValues();
            cv.put(MediaStore.Images.Media.DISPLAY_NAME, "meliponas_" + System.currentTimeMillis() + ".jpg");
            cv.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
            if (Build.VERSION.SDK_INT >= 29) cv.put("relative_path", "Pictures/MonitorMeliponas");
            fotoUri = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv);
            Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            i.putExtra(MediaStore.EXTRA_OUTPUT, fotoUri);
            i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            startActivityForResult(i, REQ_CAMERA);
        } catch (Exception e) {
            js("window.midiaErro && midiaErro(" + q(chaveFoto) + "," + q("Não foi possível abrir a câmera: " + e.getMessage()) + ")");
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req == REQ_CSV) {
            if (res == RESULT_OK && data != null && data.getData() != null) {
                final Uri destino = data.getData();
                new Thread(new Runnable() { public void run() {
                    try {
                        OutputStream out = getContentResolver().openOutputStream(destino);
                        beemeter.exportarCsv(out);
                        out.close();
                        js("window.toast && toast('Planilha salva')");
                    } catch (Exception e) { js("window.toast && toast('Não foi possível salvar a planilha')"); }
                }}).start();
            }
            return;
        }
        if (req != REQ_CAMERA && req != REQ_GALERIA) return;
        Uri origem = null;
        if (req == REQ_CAMERA) {
            if (res == RESULT_OK) origem = fotoUri;
            else if (fotoUri != null) { try { getContentResolver().delete(fotoUri, null, null); } catch (Exception e) {} }
        } else if (res == RESULT_OK && data != null) {
            origem = data.getData();
        }
        if (origem == null) { js("window.midiaErro && midiaErro(" + q(chaveFoto) + ",null)"); return; }
        final Uri u = origem;
        new Thread(new Runnable() { public void run() { processarFoto(u); } }).start();
    }

    private void processarFoto(Uri u) {
        String id = "f" + UUID.randomUUID().toString().replace("-", "");
        try {
            File tmp = new File(getCacheDir(), "tmp.jpg");
            InputStream in = getContentResolver().openInputStream(u);
            OutputStream out = new FileOutputStream(tmp);
            byte[] buf = new byte[16384]; int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            in.close(); out.close();
            int rot = 0;
            try {
                int o = new ExifInterface(tmp.getAbsolutePath()).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1);
                rot = o == 6 ? 90 : o == 3 ? 180 : o == 8 ? 270 : 0;
            } catch (Exception e) {}
            BitmapFactory.Options op = new BitmapFactory.Options();
            op.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(tmp.getAbsolutePath(), op);
            int maior = Math.max(op.outWidth, op.outHeight), amostra = 1;
            while (maior / (amostra * 2) >= 1600) amostra *= 2;
            op = new BitmapFactory.Options();
            op.inSampleSize = amostra;
            Bitmap bm = BitmapFactory.decodeFile(tmp.getAbsolutePath(), op);
            float esc = Math.min(1f, 1600f / Math.max(bm.getWidth(), bm.getHeight()));
            Matrix m = new Matrix();
            m.postScale(esc, esc);
            if (rot != 0) m.postRotate(rot);
            Bitmap fim = Bitmap.createBitmap(bm, 0, 0, bm.getWidth(), bm.getHeight(), m, true);
            FileOutputStream fo = new FileOutputStream(new File(pastaMidias(), id + ".jpg"));
            fim.compress(Bitmap.CompressFormat.JPEG, 80, fo);
            fo.close();
            float em = 240f / Math.max(fim.getWidth(), fim.getHeight());
            Bitmap mini = Bitmap.createScaledBitmap(fim, Math.round(fim.getWidth() * em), Math.round(fim.getHeight() * em), true);
            FileOutputStream fm = new FileOutputStream(new File(pastaMidias(), id + "_mini.jpg"));
            mini.compress(Bitmap.CompressFormat.JPEG, 70, fm);
            fm.close();
            tmp.delete();
            long tam = new File(pastaMidias(), id + ".jpg").length();
            js("window.midiaPronta && midiaPronta(" + q(chaveFoto) + ",{id:" + q(id) + ",tipo:'foto',tamanho:" + tam + "})");
        } catch (Throwable e) {
            js("window.midiaErro && midiaErro(" + q(chaveFoto) + "," + q("Erro ao salvar a foto: " + e.getMessage()) + ")");
        }
    }

    /* ---------- áudio ---------- */
    private void comecarGravacao() {
        try {
            audioId = "a" + UUID.randomUUID().toString().replace("-", "");
            gravador = new MediaRecorder();
            gravador.setAudioSource(MediaRecorder.AudioSource.MIC);
            gravador.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            gravador.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            gravador.setAudioEncodingBitRate(64000);
            gravador.setAudioSamplingRate(44100);
            gravador.setMaxDuration(180000);
            gravador.setOutputFile(new File(pastaMidias(), audioId + ".m4a").getAbsolutePath());
            gravador.setOnInfoListener(new MediaRecorder.OnInfoListener() {
                public void onInfo(MediaRecorder mr, int what, int extra) {
                    if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) js("window.pararAudio && pararAudio(true)");
                }
            });
            gravador.prepare();
            gravador.start();
            audioInicio = System.currentTimeMillis();
            js("window.audioIniciado && audioIniciado(" + q(chaveAudio) + ")");
        } catch (Exception e) {
            gravador = null;
            js("window.midiaErro && midiaErro(" + q(chaveAudio) + "," + q("Não foi possível gravar: " + e.getMessage()) + ")");
        }
    }

    private String[] permissoesBle() {
        if (Build.VERSION.SDK_INT >= 31) return new String[]{"android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT", Manifest.permission.ACCESS_FINE_LOCATION};
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private void comBluetooth(String chave, Runnable acao) {
        if (Build.VERSION.SDK_INT >= 23) {
            java.util.ArrayList<String> faltam = new java.util.ArrayList<String>();
            for (String p : permissoesBle()) if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) faltam.add(p);
            if (!faltam.isEmpty()) {
                acaoBle = acao; chaveBle = chave;
                requestPermissions(faltam.toArray(new String[0]), PERM_BLE);
                return;
            }
        }
        android.bluetooth.BluetoothAdapter a = beemeter.adaptador();
        if (a == null) { js("window.bleErro && bleErro(" + q(chave) + ",'Este celular não tem Bluetooth.')"); return; }
        if (!a.isEnabled()) {
            try { startActivity(new Intent(android.bluetooth.BluetoothAdapter.ACTION_REQUEST_ENABLE)); } catch (Exception e) { }
            js("window.bleErro && bleErro(" + q(chave) + ",'Ligue o Bluetooth e toque de novo.')");
            return;
        }
        acao.run();
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] p, int[] r) {
        boolean ok = r.length > 0 && r[0] == PackageManager.PERMISSION_GRANTED;
        if (req == PERM_BLE) {
            boolean todas = r.length > 0;
            for (int x : r) if (x != PackageManager.PERMISSION_GRANTED) todas = false;
            Runnable acao = acaoBle; acaoBle = null;
            if (todas && acao != null) comBluetooth(chaveBle, acao);
            else js("window.bleErro && bleErro(" + q(chaveBle) + "," + q("Sem permissão para Bluetooth e localização. Libere em Configurações > Apps > Monitor Meliponas > Permissões (Dispositivos por perto e Localização).") + ")");
            return;
        }
        if (req == PERM_AUDIO) {
            if (ok) comecarGravacao();
            else js("window.midiaErro && midiaErro(" + q(chaveAudio) + "," + q("Sem permissão para usar o microfone. Libere em Configurações > Apps > Monitor Meliponas > Permissões.") + ")");
        } else if (req == PERM_ARMAZ) {
            if (ok) abrirCamera();
            else js("window.midiaErro && midiaErro(" + q(chaveFoto) + "," + q("Sem permissão para salvar fotos.") + ")");
        }
    }

    class Ponte {
        @JavascriptInterface
        public void compartilhar(final String texto, final String titulo) {
            runOnUiThread(new Runnable() { public void run() {
                Intent i = new Intent(Intent.ACTION_SEND);
                i.setType("text/plain");
                i.putExtra(Intent.EXTRA_SUBJECT, titulo);
                i.putExtra(Intent.EXTRA_TEXT, texto);
                startActivity(Intent.createChooser(i, "Enviar por"));
            }});
        }

        @JavascriptInterface
        public void tirarFoto(final String chave) {
            chaveFoto = chave;
            runOnUiThread(new Runnable() { public void run() {
                if (Build.VERSION.SDK_INT < 29 && Build.VERSION.SDK_INT >= 23
                        && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, PERM_ARMAZ);
                } else abrirCamera();
            }});
        }

        @JavascriptInterface
        public void escolherFoto(final String chave) {
            chaveFoto = chave;
            runOnUiThread(new Runnable() { public void run() {
                Intent i = new Intent(Intent.ACTION_GET_CONTENT);
                i.setType("image/*");
                startActivityForResult(Intent.createChooser(i, "Escolher foto"), REQ_GALERIA);
            }});
        }

        @JavascriptInterface
        public void iniciarAudio(final String chave) {
            chaveAudio = chave;
            runOnUiThread(new Runnable() { public void run() {
                if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, PERM_AUDIO);
                } else comecarGravacao();
            }});
        }

        @JavascriptInterface
        public String finalizarAudio() {
            if (gravador == null) return "";
            long dur = System.currentTimeMillis() - audioInicio;
            try { gravador.stop(); } catch (Exception e) { dur = 0; }
            try { gravador.release(); } catch (Exception e) {}
            gravador = null;
            File f = new File(pastaMidias(), audioId + ".m4a");
            if (dur < 700 || !f.exists()) { f.delete(); return ""; }
            return "{\"id\":\"" + audioId + "\",\"tipo\":\"audio\",\"duracao\":" + (dur / 1000) + ",\"tamanho\":" + f.length() + "}";
        }

        @JavascriptInterface
        public void tocarAudio(final String id) {
            runOnUiThread(new Runnable() { public void run() {
                try {
                    if (player != null) { player.release(); player = null; }
                    player = new MediaPlayer();
                    player.setDataSource(new File(pastaMidias(), id + ".m4a").getAbsolutePath());
                    player.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                        public void onCompletion(MediaPlayer mp) { js("window.audioTerminou && audioTerminou()"); }
                    });
                    player.prepare();
                    player.start();
                } catch (Exception e) { js("window.toast && toast('Não foi possível tocar o áudio')"); }
            }});
        }

        @JavascriptInterface
        public void pararReproducao() {
            runOnUiThread(new Runnable() { public void run() {
                if (player != null) { try { player.stop(); player.release(); } catch (Exception e) {} player = null; }
            }});
        }

        @JavascriptInterface
        public String miniatura(String id) {
            File f = new File(pastaMidias(), id + "_mini.jpg");
            if (!f.exists()) return "";
            return "data:image/jpeg;base64," + lerB64(f);
        }

        @JavascriptInterface
        public String lerMidiaBase64(String id, String tipo) {
            File f = new File(pastaMidias(), id + ("audio".equals(tipo) ? ".m4a" : ".jpg"));
            return f.exists() ? lerB64(f) : "";
        }

        @JavascriptInterface
        public void apagarMidia(String id) {
            new File(pastaMidias(), id + ".jpg").delete();
            new File(pastaMidias(), id + "_mini.jpg").delete();
            new File(pastaMidias(), id + ".m4a").delete();
        }

        @JavascriptInterface
        public String rede() {
            try {
                ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
                NetworkInfo ni = cm.getActiveNetworkInfo();
                if (ni == null || !ni.isConnected()) return "nenhuma";
                return ni.getType() == ConnectivityManager.TYPE_WIFI || ni.getType() == ConnectivityManager.TYPE_ETHERNET ? "wifi" : "movel";
            } catch (Exception e) { return "desconhecida"; }
        }

        @JavascriptInterface
        public String versao() { return "3.2"; }

        @JavascriptInterface
        public void bleBuscar(final String chave, final int segundos) {
            runOnUiThread(new Runnable() { public void run() {
                comBluetooth(chave, new Runnable() { public void run() { beemeter.buscar(chave, segundos, null, null); } });
            }});
        }

        @JavascriptInterface
        public void bleBaixar(final String chave, final String id, final String desde, final int colonia) {
            runOnUiThread(new Runnable() { public void run() {
                comBluetooth(chave, new Runnable() { public void run() {
                    long d = 0; try { d = Long.parseLong(desde); } catch (Exception e) { }
                    beemeter.baixar(chave, id, d, colonia);
                } });
            }});
        }

        @JavascriptInterface
        public void bleIdentificar(final String chave, final String id) {
            runOnUiThread(new Runnable() { public void run() {
                comBluetooth(chave, new Runnable() { public void run() { beemeter.identificar(chave, id); } });
            }});
        }

        @JavascriptInterface
        public void bleAoVivo(final String chave, final String id, final String desde, final int colonia, final String visita) {
            runOnUiThread(new Runnable() { public void run() {
                comBluetooth(chave, new Runnable() { public void run() {
                    long d = 0; try { d = Long.parseLong(desde); } catch (Exception e) { }
                    beemeter.aoVivo(chave, id, d, colonia, visita);
                } });
            }});
        }

        @JavascriptInterface
        public void bleParar() { runOnUiThread(new Runnable() { public void run() { beemeter.parar(); } }); }

        @JavascriptInterface
        public String historico(int colonia, String desde) {
            long d = 0; try { d = Long.parseLong(desde); } catch (Exception e) { }
            return beemeter.historico(colonia, d);
        }

        @JavascriptInterface
        public void exportarHistorico() {
            runOnUiThread(new Runnable() { public void run() {
                Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                i.addCategory(Intent.CATEGORY_OPENABLE);
                i.setType("text/csv");
                i.putExtra(Intent.EXTRA_TITLE, "medicoes_meliponas_" + new java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(new java.util.Date()) + ".csv");
                try { startActivityForResult(i, REQ_CSV); } catch (Exception e) { js("window.toast && toast('Este celular não permite salvar arquivos')"); }
            }});
        }

        @JavascriptInterface
        public void bleCancelar() { runOnUiThread(new Runnable() { public void run() { beemeter.cancelar(); } }); }

        @JavascriptInterface
        public String lotesPendentes() { return beemeter.lotesPendentes(); }

        @JavascriptInterface
        public String lerLote(String nome) { return beemeter.lerLote(nome); }

        @JavascriptInterface
        public void apagarLote(String nome) { beemeter.apagarLote(nome); }
    }

    private static String lerB64(File f) {
        try {
            FileInputStream in = new FileInputStream(f);
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[16384]; int n;
            while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
            in.close();
            return Base64.encodeToString(bo.toByteArray(), Base64.NO_WRAP);
        } catch (Exception e) { return ""; }
    }
}
