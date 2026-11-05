/* Monitor Meliponas — ponte para o navegador (iPhone, Android ou computador).
 * Cria window.Android com os mesmos nomes do aplicativo instalado, usando
 * recursos do navegador: IndexedDB (fotos, áudios, medições), câmera pelo
 * seletor de arquivos, MediaRecorder (áudio) e Web Bluetooth quando existir
 * (Chrome no Android/computador e o navegador Bluefy no iPhone). */
(function () {
  if (window.Android) return;               // aplicativo instalado: já tem a ponte
  window.MM_WEB = true;
  window.MM_WEB_BLE = !!(navigator.bluetooth && navigator.bluetooth.requestDevice);

  /* ---------------- armazenamento (IndexedDB) ---------------- */
  var bancoP = new Promise(function (ok, falha) {
    var req = indexedDB.open('monitor-meliponas', 1);
    req.onupgradeneeded = function () {
      var db = req.result;
      db.createObjectStore('midias');   // id -> {tipo, blob, mini}
      db.createObjectStore('lotes');    // nome -> texto JSON
    };
    req.onsuccess = function () { ok(req.result); };
    req.onerror = function () { falha(req.error); };
  });
  function tx(loja, modo, fn) {
    return bancoP.then(function (db) {
      return new Promise(function (ok, falha) {
        var t = db.transaction(loja, modo), s = t.objectStore(loja), r = fn(s);
        t.oncomplete = function () { ok(r && r.result); };
        t.onerror = function () { falha(t.error); };
      });
    });
  }
  var minis = {}, urlsAudio = {}, lotes = [];
  tx('midias', 'readonly', function (s) {
    var r = s.openCursor();
    r.onsuccess = function () {
      var c = r.result; if (!c) return;
      if (c.value.mini) minis[c.key] = c.value.mini;
      if (c.value.tipo === 'audio') urlsAudio[c.key] = URL.createObjectURL(c.value.blob);
      c.continue();
    };
    return null;
  }).catch(function () {});
  tx('lotes', 'readonly', function (s) { return s.getAllKeys(); }).then(function (k) { lotes = k || []; }).catch(function () {});
  if (navigator.storage && navigator.storage.persist) navigator.storage.persist();

  function js(fn) { setTimeout(fn, 0); }
  function novoId(p) { return p + Date.now().toString(36) + Math.random().toString(36).slice(2, 10); }
  function blobParaBase64(b) {
    return new Promise(function (ok) { var f = new FileReader(); f.onload = function () { ok(String(f.result).split(',')[1] || ''); }; f.readAsDataURL(b); });
  }

  /* ---------------- fotos ---------------- */
  function escolherImagem(chave, camera) {
    var inp = document.createElement('input');
    inp.type = 'file'; inp.accept = 'image/*';
    if (camera) inp.setAttribute('capture', 'environment');
    inp.style.display = 'none';
    document.body.appendChild(inp);
    inp.onchange = function () {
      var f = inp.files && inp.files[0];
      document.body.removeChild(inp);
      if (!f) { window.midiaErro && midiaErro(chave, null); return; }
      var img = new Image();
      img.onload = function () {
        function reduzir(maior, q) {
          var e = Math.min(1, maior / Math.max(img.naturalWidth, img.naturalHeight));
          var c = document.createElement('canvas');
          c.width = Math.round(img.naturalWidth * e); c.height = Math.round(img.naturalHeight * e);
          c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
          return c.toDataURL('image/jpeg', q);
        }
        var grande = reduzir(1600, 0.8), mini = reduzir(240, 0.7);
        fetch(grande).then(function (r) { return r.blob(); }).then(function (blob) {
          var id = novoId('f');
          return tx('midias', 'readwrite', function (s) { s.put({ tipo: 'foto', blob: blob, mini: mini }, id); }).then(function () {
            minis[id] = mini;
            URL.revokeObjectURL(img.src);
            window.midiaPronta && midiaPronta(chave, { id: id, tipo: 'foto', tamanho: blob.size });
          });
        }).catch(function () { window.midiaErro && midiaErro(chave, 'Não foi possível guardar a foto. Verifique o espaço do celular.'); });
      };
      img.onerror = function () { window.midiaErro && midiaErro(chave, 'Não foi possível abrir a foto.'); };
      img.src = URL.createObjectURL(f);
    };
    inp.click();
  }

  /* ---------------- áudio ---------------- */
  var gravador = null, pedacos = [], inicio = 0, chaveAudio = '', limite = null, porLimite = false;
  function tipoAudio() {
    var tipos = ['audio/mp4', 'audio/mp4;codecs=mp4a.40.2', 'audio/webm;codecs=opus', 'audio/webm'];
    for (var i = 0; i < tipos.length; i++) if (window.MediaRecorder && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(tipos[i])) return tipos[i];
    return '';
  }
  function iniciarAudio(chave) {
    chaveAudio = chave;
    if (!navigator.mediaDevices || !window.MediaRecorder) { js(function () { midiaErro(chave, 'Este navegador não grava áudio.'); }); return; }
    navigator.mediaDevices.getUserMedia({ audio: true }).then(function (fluxo) {
      var t = tipoAudio();
      gravador = new MediaRecorder(fluxo, t ? { mimeType: t, audioBitsPerSecond: 64000 } : undefined);
      pedacos = []; porLimite = false;
      gravador.ondataavailable = function (e) { if (e.data && e.data.size) pedacos.push(e.data); };
      gravador.onstop = function () {
        fluxo.getTracks().forEach(function (k) { k.stop(); });
        var dur = (Date.now() - inicio) / 1000, chave = chaveAudio;
        if (dur < 0.7 || !pedacos.length) { window.toast && toast('Áudio muito curto, não foi guardado'); window.redesenharMantendoRolagem && redesenharMantendoRolagem(); return; }
        var blob = new Blob(pedacos, { type: gravador.mimeType || 'audio/mp4' }), id = novoId('a');
        tx('midias', 'readwrite', function (s) { s.put({ tipo: 'audio', blob: blob }, id); }).then(function () {
          urlsAudio[id] = URL.createObjectURL(blob);
          window.midiaPronta && midiaPronta(chave, { id: id, tipo: 'audio', duracao: Math.round(Math.min(dur, 180)), tamanho: blob.size });
          if (porLimite && window.toast) toast('Limite de 3 minutos atingido');
        });
      };
      inicio = Date.now();
      gravador.start();
      limite = setTimeout(function () { porLimite = true; window.pararAudio && pararAudio(true); }, 180000);
      window.audioIniciado && audioIniciado(chave);
    }).catch(function () {
      window.midiaErro && midiaErro(chave, 'Sem permissão para o microfone. No iPhone: Ajustes > Safari > Microfone.');
    });
  }
  function finalizarAudio() {
    clearTimeout(limite);
    if (!gravador || gravador.state === 'inactive') return '';
    gravador.stop();
    return 'PENDENTE';
  }
  var tocando = null;
  function tocarAudio(id) {
    if (tocando) { tocando.pause(); tocando = null; }
    var u = urlsAudio[id];
    if (!u) { window.toast && toast('Áudio ainda carregando, toque de novo'); return; }
    tocando = new Audio(u);
    tocando.onended = function () { window.audioTerminou && audioTerminou(); };
    tocando.play().catch(function () { window.toast && toast('Não foi possível tocar o áudio'); });
  }

  /* ---------------- Bluetooth (Web Bluetooth) ---------------- */
  var SERV = '6e7a0001-b5a3-4f4b-9a3e-6d656c697061';
  var U = function (n) { return '6e7a000' + n + '-b5a3-4f4b-9a3e-6d656c697061'; };
  var aparelhos = {};  // nome -> BluetoothDevice já escolhido nesta sessão
  var sessao = null;
  function bleErro(chave, msg) { js(function () { window.bleErro && window.bleErro(chave, msg); }); }
  function semBle(chave) { bleErro(chave, 'Este navegador não tem Bluetooth para aparelhos. No iPhone, abra o endereço no navegador Bluefy; no Android, use o Chrome ou o aplicativo instalado.'); }

  function bleBuscar(chave) {
    if (!window.MM_WEB_BLE) { semBle(chave); return; }
    navigator.bluetooth.requestDevice({ filters: [{ namePrefix: 'BM-' }], optionalServices: [SERV] }).then(function (d) {
      aparelhos[d.name] = d;
      window.bleAchado && bleAchado(chave, { id: d.name, rssi: -50 });
      window.bleBuscaFim && bleBuscaFim(chave, []);
    }).catch(function () { window.bleBuscaFim && bleBuscaFim(chave, []); });
  }

  function texto(dv) { return new TextDecoder().decode(dv.buffer.slice(dv.byteOffset, dv.byteOffset + dv.byteLength)); }

  function bleBaixar(chave, id, desdeTxt, colonia) {
    if (!window.MM_WEB_BLE) { semBle(chave); return; }
    if (sessao) { bleErro(chave, 'Já há um download em andamento.'); return; }
    var desde = parseInt(desdeTxt, 10) || 0;
    var prog = function (t, p) { window.bleProgresso && bleProgresso(chave, t, p); };
    var s = sessao = { cancelado: false };
    var pDev = aparelhos[id] ? Promise.resolve(aparelhos[id])
      : navigator.bluetooth.requestDevice({ filters: [{ name: id }], optionalServices: [SERV] });
    prog('Escolha o aparelho ' + id + ' na lista…', 5);
    var gatt, info, agora, epoca, fluxo = [], tamFluxo = 0, esperados = 0, cDados, aoChegar;
    pDev.then(function (d) {
      aparelhos[id] = d; s.dev = d;
      prog('Conectando ao ' + id + '…', 15);
      return d.gatt.connect();
    }).then(function (g) {
      gatt = g; prog('Conectado. Lendo o aparelho…', 25);
      return g.getPrimaryService(SERV);
    }).then(function (svc) {
      return Promise.all([svc.getCharacteristic(U(2)), svc.getCharacteristic(U(3)), svc.getCharacteristic(U(4)), svc.getCharacteristic(U(5))]);
    }).then(function (cs) {
      var cInfo = cs[0], cAgora = cs[1], cCmd = cs[2]; cDados = cs[3];
      var escrever = function (t) { var b = new TextEncoder().encode(t); return cCmd.writeValueWithResponse ? cCmd.writeValueWithResponse(b) : cCmd.writeValue(b); };
      var fim = new Promise(function (ok) {
        aoChegar = function (ev) {
          var v = ev.target.value, u8 = new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
          if (u8[0] === 68) {             // 'D'
            fluxo.push(u8.slice(1)); tamFluxo += u8.length - 1;
            if (esperados) prog('Baixando registros: ' + Math.floor(tamFluxo / 32) + ' de ' + esperados, 40 + Math.round(55 * Math.min(1, tamFluxo / 32 / esperados)));
          } else if (u8[0] === 70) ok();  // 'F'
        };
        cDados.addEventListener('characteristicvaluechanged', aoChegar);
      });
      return cDados.startNotifications().then(function () { return cInfo.readValue(); }).then(function (v) {
        info = JSON.parse(texto(v));
        epoca = Math.floor(Date.now() / 1000);
        if (desde > info.proximo) desde = 0;
        esperados = Math.max(0, info.proximo - Math.max(desde, info.primeiro));
        return escrever('HORA ' + epoca);
      }).then(function () { return cAgora.readValue(); }).then(function (v) {
        agora = JSON.parse(texto(v));
        prog(esperados ? 'Baixando ' + esperados + ' registros…' : 'Sem registros novos. Concluindo…', 40);
        return escrever('LER ' + desde);
      }).then(function () {
        return Promise.race([fim, new Promise(function (_, falha) { s.vigia = setInterval(function () {
          if (s.ultimo && Date.now() - s.ultimo > 20000) falha(new Error('O aparelho parou de responder. Chegue mais perto e tente de novo.'));
        }, 2000); s.ultimo = Date.now(); cDados.addEventListener('characteristicvaluechanged', function () { s.ultimo = Date.now(); }); })]);
      });
    }).then(function () {
      if (s.cancelado) return;
      var b = new Uint8Array(tamFluxo), o = 0;
      fluxo.forEach(function (p) { b.set(p, o); o += p.length; });
      var dv = new DataView(b.buffer), n = Math.floor(b.length / 32), regs = [], pri = -1, ult = -1, mIni = 0, mFim = 0;
      for (var i = 0; i < n; i++) {
        var k = i * 32, seq = dv.getUint32(k, true), ep = dv.getUint32(k + 4, true), up = dv.getUint32(k + 8, true), boot = dv.getUint16(k + 12, true);
        var val = dv.getUint8(k + 30), m = ep > 0 ? ep : (boot === info.boot ? epoca - (info.up - up) : null);
        regs.push({ seq: seq, m: m, b: boot, u: up,
          t: val & 1 ? dv.getInt16(k + 14, true) / 10 : null, ur: val & 1 ? dv.getUint16(k + 16, true) / 10 : null,
          lux: val & 2 ? dv.getUint16(k + 18, true) : null,
          tc1: val & 4 ? dv.getInt16(k + 20, true) / 4 : null, tc2: val & 8 ? dv.getInt16(k + 22, true) / 4 : null,
          tc3: val & 16 ? dv.getInt16(k + 24, true) / 4 : null, p: val & 32 ? dv.getInt32(k + 26, true) / 1000 : null });
        if (pri < 0) pri = seq; ult = seq;
        if (m) { if (!mIni) mIni = m; mFim = m; }
      }
      var nome = n ? id + '_' + epoca + '.json' : null;
      var salvar = nome ? tx('lotes', 'readwrite', function (st) { st.put(JSON.stringify({ aparelho: id, colonia: colonia, fw: info.fw, baixado: epoca, registros: regs }), nome); })
        .then(function () { if (lotes.indexOf(nome) < 0) lotes.push(nome); }) : Promise.resolve();
      return salvar.then(function () {
        encerrar();
        window.bleConcluido && bleConcluido(chave, { id: id, fw: info.fw, boot: info.boot, intervalo: info.intervalo, tara: info.tara, proximo: info.proximo,
          n: n, primeiro: pri, ultimo: ult, mIni: mIni, mFim: mFim, lote: nome, agora: agora, quando: epoca });
      });
    }).catch(function (e) {
      var cancelado = s.cancelado;
      encerrar();
      if (cancelado) return;
      var msg = e && e.name === 'NotFoundError' ? 'Nenhum aparelho escolhido. Toque de novo e escolha ' + id + ' na lista.' : (e && e.message ? e.message : 'Falha na conexão com o aparelho.');
      bleErro(chave, msg);
    });
    function encerrar() {
      clearInterval(s.vigia);
      try { if (cDados && aoChegar) cDados.removeEventListener('characteristicvaluechanged', aoChegar); } catch (x) {}
      try { if (gatt && gatt.connected) gatt.disconnect(); } catch (x) {}
      if (sessao === s) sessao = null;
    }
  }

  /* ---------------- ponte ---------------- */
  window.Android = {
    compartilhar: function (t, titulo) {
      if (navigator.share) { navigator.share({ title: titulo, text: t }).catch(function () {}); return; }
      if (navigator.clipboard) navigator.clipboard.writeText(t).then(function () { alert('Texto copiado. Cole no WhatsApp.'); });
      else prompt('Copie o texto:', t);
    },
    tirarFoto: function (c) { escolherImagem(c, true); },
    escolherFoto: function (c) { escolherImagem(c, false); },
    iniciarAudio: iniciarAudio,
    finalizarAudio: finalizarAudio,
    tocarAudio: tocarAudio,
    pararReproducao: function () { if (tocando) { tocando.pause(); tocando = null; } },
    miniatura: function (id) { return minis[id] || ''; },
    lerMidiaBase64: function (id) {
      return tx('midias', 'readonly', function (s) { return s.get(id); }).then(function (v) { return v && v.blob ? blobParaBase64(v.blob) : ''; });
    },
    apagarMidia: function (id) {
      delete minis[id]; if (urlsAudio[id]) { URL.revokeObjectURL(urlsAudio[id]); delete urlsAudio[id]; }
      tx('midias', 'readwrite', function (s) { s.delete(id); });
    },
    rede: function () {
      if (!navigator.onLine) return 'nenhuma';
      var c = navigator.connection;
      return c && c.type === 'cellular' ? 'movel' : 'wifi';
    },
    versao: function () { return '3.0-web'; },
    bleBuscar: function (c) { bleBuscar(c); },
    bleBaixar: bleBaixar,
    bleCancelar: function () { if (sessao) { sessao.cancelado = true; try { if (sessao.dev && sessao.dev.gatt.connected) sessao.dev.gatt.disconnect(); } catch (x) {} sessao = null; } },
    lotesPendentes: function () { return JSON.stringify(lotes); },
    lerLote: function (nome) { return tx('lotes', 'readonly', function (s) { return s.get(nome); }).then(function (v) { return v || ''; }); },
    apagarLote: function (nome) { lotes = lotes.filter(function (x) { return x !== nome; }); tx('lotes', 'readwrite', function (s) { s.delete(nome); }); }
  };

  window.addEventListener('online', function () { window.aoVoltarAoApp && window.aoVoltarAoApp(); });
  document.addEventListener('visibilitychange', function () { if (!document.hidden && window.aoVoltarAoApp) window.aoVoltarAoApp(); });
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(function () {});
})();
