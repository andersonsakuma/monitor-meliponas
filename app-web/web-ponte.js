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
    var req = indexedDB.open('monitor-meliponas', 2);
    req.onupgradeneeded = function (ev) {
      var db = req.result;
      if (ev.oldVersion < 1) {
        db.createObjectStore('midias');   // id -> {tipo, blob, mini}
        db.createObjectStore('lotes');    // nome -> texto JSON
      }
      if (ev.oldVersion < 2) {            // histórico permanente: nunca apagado
        var h = db.createObjectStore('historico', { autoIncrement: true });
        h.createIndex('m', 'm');
      }
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

  function crc32(b) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < b.length; i++) {
      crc ^= b[i];
      for (var k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    return (~crc) >>> 0;
  }
  function escolherAparelho(id) {
    return aparelhos[id] ? Promise.resolve(aparelhos[id])
      : navigator.bluetooth.requestDevice({ filters: [{ name: id }], optionalServices: [SERV] });
  }
  function bleIdentificar(chave, id) {
    if (!window.MM_WEB_BLE) { semBle(chave); return; }
    var dev;
    escolherAparelho(id).then(function (d) { aparelhos[id] = dev = d; return d.gatt.connect(); })
      .then(function (g) { return g.getPrimaryService(SERV); })
      .then(function (svc) { return svc.getCharacteristic(U(4)); })
      .then(function (c) { var b = new TextEncoder().encode('PISCAR'); return c.writeValueWithResponse ? c.writeValueWithResponse(b) : c.writeValue(b); })
      .then(function () { try { dev.gatt.disconnect(); } catch (x) {} window.bleIdentificado && bleIdentificado(chave, id); })
      .catch(function () { try { dev && dev.gatt.disconnect(); } catch (x) {} bleErro(chave, 'Não foi possível conectar ao ' + id + '.'); });
  }
  function texto(dv) { return new TextDecoder().decode(dv.buffer.slice(dv.byteOffset, dv.byteOffset + dv.byteLength)); }

  var vivoAtual = null;
  function bleAoVivo(chave, id, desdeTxt, colonia, visita) { bleBaixar(chave, id, desdeTxt, colonia, { aoVivo: true, visita: visita }); }
  function bleParar() {
    if (vivoAtual) { vivoAtual.parar(''); return; }
    if (sessao) { sessao.cancelado = true; try { if (sessao.dev && sessao.dev.gatt.connected) sessao.dev.gatt.disconnect(); } catch (x) {} sessao = null; }
  }
  function bleBaixar(chave, id, desdeTxt, colonia, opcoes) {
    opcoes = opcoes || {};
    if (!window.MM_WEB_BLE) { semBle(chave); return; }
    if (sessao) { bleErro(chave, 'Já há um download em andamento.'); return; }
    var desde = parseInt(desdeTxt, 10) || 0;
    var colPedida = Math.abs(colonia), forcar = colonia < 0, erroColonia = null;
    var prog = function (t, p) { window.bleProgresso && bleProgresso(chave, t, p); };
    var s = sessao = { cancelado: false };
    var pDev = escolherAparelho(id);
    prog('Escolha o aparelho ' + id + ' na lista…', 5);
    var gatt, info, agora, epoca, fluxo = [], tamFluxo = 0, esperados = 0, cDados, aoChegar, cAgoraVivo;
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
      var cInfo = cs[0], cAgora = cs[1], cCmd = cs[2]; cDados = cs[3]; cAgoraVivo = cAgora;
      var escrever = function (t) { var b = new TextEncoder().encode(t); return cCmd.writeValueWithResponse ? cCmd.writeValueWithResponse(b) : cCmd.writeValue(b); };
      var fim = new Promise(function (ok) {
        aoChegar = function (ev) {
          var v = ev.target.value, u8 = new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
          if (u8[0] === 68) {             // 'D'
            fluxo.push(u8.slice(1)); tamFluxo += u8.length - 1;
            if (esperados) prog('Baixando registros: ' + Math.floor(tamFluxo / 32) + ' de ' + esperados, 40 + Math.round(55 * Math.min(1, tamFluxo / 32 / esperados)));
          } else if (u8[0] === 70) {      // 'F' + quantidade + CRC32
            if (u8.length >= 9) {
              var crcAparelho = (u8[5] | u8[6] << 8 | u8[7] << 16 | u8[8] << 24) >>> 0;
              var junto = new Uint8Array(tamFluxo), o2 = 0;
              fluxo.forEach(function (p) { junto.set(p, o2); o2 += p.length; });
              if (crc32(junto) !== crcAparelho) { s.falhaCrc = true; }
            }
            ok();
          }
        };
        cDados.addEventListener('characteristicvaluechanged', aoChegar);
      });
      return cDados.startNotifications().then(function () { return cInfo.readValue(); }).then(function (v) {
        info = JSON.parse(texto(v));
        epoca = Math.floor(Date.now() / 1000);
        var colAparelho = info.colonia || 0;
        if (colPedida && colAparelho && colAparelho !== colPedida && !forcar) {
          erroColonia = colAparelho;
          throw new Error('Este aparelho está gravado como colônia ' + colAparelho + ', não ' + colPedida + '. Confira se está na caixa certa.');
        }
        if (desde > info.proximo) desde = 0;
        esperados = Math.max(0, info.proximo - Math.max(desde, info.primeiro));
        return escrever('HORA ' + epoca + (colPedida && (info.colonia || 0) !== colPedida ? ' ' + colPedida : ''));
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
      if (s.falhaCrc) throw new Error('Os dados chegaram com falha. Toque em Tentar de novo.');
      var b = new Uint8Array(tamFluxo), o = 0;
      fluxo.forEach(function (p) { b.set(p, o); o += p.length; });
      var dv = new DataView(b.buffer), n = Math.floor(b.length / 32), regs = [], pri = -1, ult = -1, mIni = 0, mFim = 0;
      for (var i = 0; i < n; i++) {
        var k = i * 32, seq = dv.getUint32(k, true), ep = dv.getUint32(k + 4, true), up = dv.getUint32(k + 8, true), boot = dv.getUint16(k + 12, true);
        var val = dv.getUint8(k + 30), m = ep > 0 ? ep : (boot === info.boot ? epoca - (info.up - up) : null);
        regs.push({ seq: seq, m: m, b: boot, u: up, c: colPedida, a: id,
          t: val & 1 ? dv.getInt16(k + 14, true) / 10 : null, ur: val & 1 ? dv.getUint16(k + 16, true) / 10 : null,
          lux: val & 2 ? dv.getUint16(k + 18, true) : null,
          tc1: val & 4 ? dv.getInt16(k + 20, true) / 4 : null, tc2: val & 8 ? dv.getInt16(k + 22, true) / 4 : null,
          tc3: val & 16 ? dv.getInt16(k + 24, true) / 4 : null, p: val & 32 ? dv.getInt32(k + 26, true) / 1000 : null });
        if (pri < 0) pri = seq; ult = seq;
        if (m) { if (!mIni) mIni = m; mFim = m; }
      }
      var hist = regs.filter(function (r) { return r.m; }).map(function (r) { return { m: r.m, c: colPedida, a: id, o: 'r', seq: r.seq, t: r.t, ur: r.ur, lux: r.lux, tc1: r.tc1, tc2: r.tc2, tc3: r.tc3, p: r.p }; });
      regs.forEach(function (r) { delete r.c; delete r.a; });
      var nome = n ? id + '_' + epoca + '.json' : null;
      var salvar = nome ? tx('lotes', 'readwrite', function (st) { st.put(JSON.stringify({ aparelho: id, colonia: colonia, fw: info.fw, baixado: epoca, registros: regs }), nome); })
        .then(function () { if (lotes.indexOf(nome) < 0) lotes.push(nome); }) : Promise.resolve();
      return salvar.then(function () { return anexarHistorico(hist); }).then(function () {
        var res = { id: id, colonia: colPedida, fw: info.fw, boot: info.boot, intervalo: info.intervalo, tara: info.tara, proximo: info.proximo,
          n: n, primeiro: pri, ultimo: ult, mIni: mIni, mFim: mFim, lote: nome, agora: agora, quando: epoca };
        if (!opcoes.aoVivo) { encerrar(); window.bleConcluido && bleConcluido(chave, res); return; }
        window.bleConcluido && bleConcluido(chave, res);
        iniciarVivo();
      });
    }).catch(function (e) {
      var cancelado = s.cancelado;
      encerrar();
      if (cancelado) return;
      var msg = e && e.name === 'NotFoundError' ? 'Nenhum aparelho escolhido. Toque de novo e escolha ' + id + ' na lista.' : (e && e.message ? e.message : 'Falha na conexão com o aparelho.');
      if (erroColonia) { js(function () { window.bleErro && window.bleErro(chave, msg, 'colonia', erroColonia); }); return; }
      bleErro(chave, msg);
    });
    function iniciarVivo() {
      var buffer = [], inicio = Date.now(), parado = false, temporizador;
      clearInterval(s.vigia);
      function registrar(a) {
        var m = Math.floor(Date.now() / 1000), tc = a.tc || [];
        var r = { m: m, t: a.t, ur: a.ur, lux: a.lux, tc1: tc[0], tc2: tc[1], tc3: tc[2], p: a.peso };
        buffer.push(r);
        anexarHistorico([{ m: m, c: colPedida, a: id, o: 'v', seq: null, t: r.t, ur: r.ur, lux: r.lux, tc1: r.tc1, tc2: r.tc2, tc3: r.tc3, p: r.p }]);
        var env = JSON.parse(JSON.stringify(a)); env.m = m; env.n = buffer.length;
        window.bleLeitura && bleLeitura(chave, env);
      }
      function parar(motivo) {
        if (parado) return; parado = true; clearTimeout(temporizador);
        if (buffer.length) {
          var nome = 'vivo_' + id + '_' + Math.floor(Date.now() / 1000) + '.json';
          tx('lotes', 'readwrite', function (st) { st.put(JSON.stringify({ tipo: 'vivo', aparelho: id, colonia: colPedida, visita: opcoes.visita || '', registros: buffer }), nome); })
            .then(function () { if (lotes.indexOf(nome) < 0) lotes.push(nome); });
        }
        vivoAtual = null; encerrar();
        window.bleVivoFim && bleVivoFim(chave, motivo || '');
      }
      function ciclo() {
        if (parado) return;
        if (Date.now() - inicio > 1800000) { parar('Leitura ao vivo encerrada após 30 minutos.'); return; }
        cAgoraVivo.readValue().then(function (v) { registrar(JSON.parse(texto(v))); temporizador = setTimeout(ciclo, 10000); })
          .catch(function () { parar('A conexão com o aparelho caiu. A leitura ao vivo foi encerrada.'); });
      }
      vivoAtual = { parar: parar };
      registrar(agora);
      temporizador = setTimeout(ciclo, 10000);
    }
    function encerrar() {
      clearInterval(s.vigia);
      try { if (cDados && aoChegar) cDados.removeEventListener('characteristicvaluechanged', aoChegar); } catch (x) {}
      try { if (gatt && gatt.connected) gatt.disconnect(); } catch (x) {}
      if (sessao === s) sessao = null;
    }
  }

  /* ---------------- histórico permanente ---------------- */
  function anexarHistorico(linhas) {
    if (!linhas.length) return Promise.resolve();
    return tx('historico', 'readwrite', function (st) { linhas.forEach(function (l) { st.add(l); }); });
  }
  function lerHistorico(desde) {
    return bancoP.then(function (db) {
      return new Promise(function (ok) {
        var out = [], t = db.transaction('historico', 'readonly');
        var r = t.objectStore('historico').index('m').openCursor(IDBKeyRange.lowerBound(desde));
        r.onsuccess = function () { var c = r.result; if (c) { out.push(c.value); c.continue(); } else ok(out); };
        r.onerror = function () { ok(out); };
      });
    });
  }
  var CAMPOS_H = ['t', 'ur', 'lux', 'tc1', 'tc2', 'tc3', 'p'];
  function historico(colonia, desdeTxt) {
    var desde = parseInt(desdeTxt, 10) || 0;
    return lerHistorico(desde).then(function (linhas) {
      var ag = {};
      linhas.forEach(function (l) {
        if (!l.c || (colonia > 0 && l.c !== colonia)) return;
        var hora = Math.floor(l.m / 3600) * 3600, k = hora + ';' + l.c, a = ag[k];
        if (!a) { a = ag[k] = { h: hora, c: l.c, n: 0, s: [0, 0, 0, 0, 0, 0, 0], q: [0, 0, 0, 0, 0, 0, 0], min: Infinity, max: -Infinity }; }
        a.n++;
        CAMPOS_H.forEach(function (f, i) { var x = l[f]; if (x == null || isNaN(x)) return; a.s[i] += +x; a.q[i]++; if (i === 6) { a.min = Math.min(a.min, x); a.max = Math.max(a.max, x); } });
      });
      return Object.keys(ag).map(function (k) { return ag[k]; }).sort(function (x, y) { return x.h - y.h || x.c - y.c; }).map(function (a) {
        var p = [a.h, a.c, a.n];
        for (var i = 0; i < 7; i++) p.push(a.q[i] ? (a.s[i] / a.q[i]).toFixed(3) : '', a.q[i]);
        p.push(a.q[6] ? a.min.toFixed(3) : '', a.q[6] ? a.max.toFixed(3) : '');
        return p.join(';');
      }).join('\n');
    });
  }
  function exportarHistorico() {
    lerHistorico(0).then(function (linhas) {
      var dois = function (n) { return (n < 10 ? '0' : '') + n; };
      var t = '\ufeffmomento_epoca;data_hora;colonia;aparelho;origem;seq;temp_amb;umidade;lux;tc_fundo;tc_divisao;tc_melgueira;peso_kg\n';
      linhas.forEach(function (l) {
        var d = new Date(l.m * 1000), dh = dois(d.getDate()) + '/' + dois(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + dois(d.getHours()) + ':' + dois(d.getMinutes()) + ':' + dois(d.getSeconds());
        t += [l.m, dh, l.c, l.a, l.o === 'v' ? 'ao vivo' : 'registro', l.seq == null ? '' : l.seq].concat(CAMPOS_H.map(function (f) { return l[f] == null ? '' : String(l[f]).replace('.', ','); })).join(';') + '\n';
      });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([t], { type: 'text/csv;charset=utf-8' }));
      a.download = 'medicoes_meliponas_' + new Date().toISOString().slice(0, 10) + '.csv';
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
    });
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
    versao: function () { return '3.4-web'; },
    bleBuscar: function (c) { bleBuscar(c); },
    bleBaixar: function (c, i, d, col) { bleBaixar(c, i, d, col); },
    bleAoVivo: bleAoVivo,
    bleParar: bleParar,
    historico: historico,
    exportarHistorico: exportarHistorico,
    salvarArquivo: function (b64, nome, mime, acao, assunto) {
      var bin = atob(b64), u = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
      var blob = new Blob([u], { type: mime });
      function baixar() { var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = nome; document.body.appendChild(a); a.click(); document.body.removeChild(a); }
      if (acao === 'salvar') { baixar(); return; }
      var arq = new File([blob], nome, { type: mime });
      if (navigator.canShare && navigator.canShare({ files: [arq] })) {
        navigator.share({ files: [arq], title: assunto, text: assunto }).catch(function () {});
      } else {
        baixar();
        if (window.toast) toast('O PDF foi baixado. Anexe o arquivo no WhatsApp ou no e-mail.');
      }
    },
    bleIdentificar: bleIdentificar,
    bleCancelar: bleParar,
    lotesPendentes: function () { return JSON.stringify(lotes); },
    lerLote: function (nome) { return tx('lotes', 'readonly', function (s) { return s.get(nome); }).then(function (v) { return v || ''; }); },
    apagarLote: function (nome) { lotes = lotes.filter(function (x) { return x !== nome; }); tx('lotes', 'readwrite', function (s) { s.delete(nome); }); }
  };

  window.addEventListener('online', function () { window.aoVoltarAoApp && window.aoVoltarAoApp(); });
  document.addEventListener('visibilitychange', function () { if (!document.hidden && window.aoVoltarAoApp) window.aoVoltarAoApp(); });
  if ('serviceWorker' in navigator) {
    // Com internet, as telas novas já chegam pela rede; aqui também se renova a cópia guardada para uso sem internet.
    navigator.serviceWorker.register('sw.js').then(function (r) { if (navigator.onLine) r.update(); }).catch(function () {});
  }
})();
