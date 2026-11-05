# BeeMeter 2.2.0-BLE — registro e protocolo Bluetooth

Firmware do aparelho de medição (ESP32 HW-657A) usado pelo aplicativo **Monitor Meliponas**.
Sensores, pinos, tara e tela são os da versão 2.1.1; esta versão acrescenta o **registro em memória** e o **Bluetooth**.

## Registro em memória

- A cada **10 minutos** (ajustável de 1 a 60 min) o aparelho grava um registro com todas as medidas.
- Arquivo circular `/registro.bin` no LittleFS (partição `spiffs` do esquema *Default 4MB with spiffs*): cabeçalho de 32 bytes e **4464 posições de 32 bytes = 31 dias**. Quando enche, o mais antigo é substituído.
- Cada registro tem um número de sequência (`seq`) que nunca se repete, mesmo depois de desligar.
- O ESP32 não tem relógio com bateria. Cada registro guarda o **número da partida** (`boot`) e os **segundos desde a partida** (`uptime_s`). Depois que o celular acerta o relógio (`HORA`), os registros passam a ter também a hora real (`epoca`). O aplicativo reconstitui a hora dos registros da partida atual; registros de partidas anteriores sem hora real chegam ao banco com `momento` vazio.

### Formato do registro (32 bytes, little-endian)

| Byte | Tipo | Campo |
| --- | --- | --- |
| 0 | uint32 | seq |
| 4 | uint32 | epoca (s desde 1970, UTC; 0 = relógio não acertado) |
| 8 | uint32 | uptime_s |
| 12 | uint16 | boot |
| 14 | int16 | temperatura ambiente × 10 |
| 16 | uint16 | umidade × 10 |
| 18 | uint16 | iluminação em lux (máx. 65535) |
| 20 | int16 ×3 | termopares × 4: fundo, divisão, melgueira |
| 26 | int32 | peso em gramas |
| 30 | uint8 | válidos: bit0 DHT, bit1 luz, bit2–4 termopares 1–3, bit5 peso |
| 31 | uint8 | tipo do DHT (11 ou 22) |

## Bluetooth (BLE)

Nome anunciado: **`BM-XXXXXX`** (final do endereço Bluetooth), mostrado também na tela do aparelho, no painel dos logotipos.

Serviço `6e7a0001-b5a3-4f4b-9a3e-6d656c697061`:

| Característica | UUID (final) | Tipo | Conteúdo |
| --- | --- | --- | --- |
| INFO | `…0002…` | leitura | JSON: `id, fw, boot, up, epoca, primeiro, proximo, n, intervalo, reg, tara` |
| AGORA | `…0003…` | leitura | JSON: `t, ur, dht, lux, tc[3], peso, up` (null quando o sensor falha) |
| COMANDO | `…0004…` | escrita | texto: `HORA <epoca>`, `LER <seq>`, `INTERVALO <s>`, `TARA`, `APAGAR` |
| DADOS | `…0005…` | notificação | resposta ao `LER` |

Resposta ao `LER <seq>`: pacotes `'D'` + bytes dos registros, em sequência, do `seq` pedido (ou do mais antigo disponível) até o último. Um registro pode vir partido entre dois pacotes; o celular junta tudo e lê de 32 em 32 bytes. No fim vem `'F'` + quantidade enviada (uint32). Funciona com qualquer MTU (o celular pede 247).

### Sequência usada pelo aplicativo

1. Procura `BM-XXXXXX` e conecta.
2. Pede MTU 247 e ativa as notificações de DADOS.
3. Lê INFO, envia `HORA <hora do celular>` e lê AGORA.
4. Envia `LER <último seq baixado + 1>` e recebe os registros novos.
5. Desconecta, grava o lote no celular e envia ao banco quando houver internet (tabela `medicoes`).

## Comandos pela serial (115200, terminados em Enter)

`INFO` (mostra INFO e AGORA), `EXPORTAR` (todos os registros em CSV), `HORA <epoca>`, `INTERVALO <s>`, `TARA`, `APAGAR`. As mensagens de diagnóstico da 2.1.1 continuam iguais.

## Compilar e gravar

- **Arduino IDE:** placa *ESP32 Dev Module*, esquema de partições *Default 4MB with spiffs*. Bibliotecas: Adafruit GFX, Adafruit ST7735 and ST7789, DHT sensor library, HX711 (bogde) e **NimBLE-Arduino 1.4.x**.
- **Sem IDE:** grave `binarios/BeeMeter_2.2.0-BLE_completo.bin` no endereço `0x0` com o esptool ou pelo navegador em <https://espressif.github.io/esptool-js/>.
- O fator `HX711_CONTAGENS_POR_KG` pertence à montagem calibrada. Para outra célula de carga, calibre e ajuste uma cópia do firmware.
- Na primeira partida o aparelho cria o arquivo de registro (alguns segundos a mais na abertura).

Testado: compilação para ESP32 (720 kB, 54 % da memória de programa) e teste no computador do arquivo circular, da sequência, do `LER` incremental, de MTU 23 e 247 e da reabertura do arquivo. A comunicação com um celular real ainda precisa ser conferida no aparelho.
