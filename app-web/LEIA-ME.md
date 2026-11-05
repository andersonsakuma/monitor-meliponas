# Monitor Meliponas no navegador

Mesmas telas do aplicativo (`app-android/assets`), com a ponte `web-ponte.js` no lugar do código do Android:

| Recurso | No navegador |
| --- | --- |
| Registros da visita | Guardados no navegador e enviados ao servidor como no aplicativo |
| Fotos | Câmera ou galeria pelo seletor do próprio celular; reduzidas para 1600 px; guardadas no IndexedDB |
| Áudios | Gravados pelo navegador (MediaRecorder), até 3 minutos |
| Sem internet | Depois da primeira abertura, as telas ficam guardadas (`sw.js`) |
| Bluetooth com o BeeMeter | Chrome no Android e no computador; no iPhone, só no navegador **Bluefy** (o Safari não tem Bluetooth para aparelhos). Sem Bluetooth, a pergunta "dados baixados" sai da ficha |

Endereço publicado: `https://andersonsakuma.github.io/monitor-meliponas/app/` (montado pelo fluxo do GitHub Pages com `montar.sh`).

## No iPhone

1. Abrir o endereço no Safari (ou no Bluefy, para usar o Bluetooth).
2. **Compartilhar > Adicionar à Tela de Início.** Isso é importante: no iPhone, sites que não estão na Tela de Início podem ter os dados apagados pelo sistema depois de alguns dias sem uso.
3. Abrir sempre pelo ícone. Sincronizar com frequência (o ideal é ao terminar cada visita).

## Testar no computador

```bash
./montar.sh /tmp/site/app
cd /tmp/site && python3 -m http.server 8765
# abrir http://localhost:8765/app/
```
