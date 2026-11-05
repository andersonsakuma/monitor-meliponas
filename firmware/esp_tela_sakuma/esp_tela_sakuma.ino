/* ============================================================================
 * BeeMeter -- ESP32 HW-657A com TFT ST7789 integrado     firmware 2.2.0-BLE
 * Amazonia Bee  |  IPE / Fabrica de Inovacoes em Sociobioeconomia
 *
 * 2.2.0 -- registro em memoria e Bluetooth para o aplicativo Monitor Meliponas:
 *   - REGISTRO: a cada 10 min (ajustavel de 1 a 60 min) grava um registro de
 *     32 bytes com todas as medidas num arquivo circular na flash (LittleFS),
 *     com 4464 posicoes = 31 dias. Cada registro tem numero de sequencia
 *     (seq) que nunca se repete, o numero da partida (boot), o tempo desde a
 *     partida e, quando o relogio ja foi acertado pelo celular, a hora real.
 *   - BLUETOOTH (BLE, NimBLE): nome "BM-XXXXXX" (fim do MAC). O aplicativo
 *     conecta, acerta o relogio (HORA), le a medida do momento (AGORA) e
 *     baixa so os registros novos (LER <seq>). Detalhes na secao 11b e no
 *     arquivo PROTOCOLO_BLE.md.
 *   - A tela mostra o nome BM-XXXXXX no painel dos logotipos e avisa quando
 *     um celular esta conectado. Leituras, pinos, tara e serial nao mudaram;
 *     a serial aceita tambem os comandos INFO, EXPORTAR, HORA, INTERVALO,
 *     TARA e APAGAR (uma linha, terminada em Enter).
 *   - Bibliotecas novas: NimBLE-Arduino 1.4.x. Esquema de particoes:
 *     "Default 4MB with spiffs" (o LittleFS usa a particao spiffs).
 *
 * 2.1.1 -- textos dos paineis:
 * 2.1.1 -- textos dos paineis:
 *   "TEMPERATURA AMBIENTE" e "UMIDADE DO AMBIENTE"; iluminacao em "lux" e
 *   sem o rodape do BH1750; termopares viram "TEMPERATURA NA COLMEIA" com
 *   FUNDO (TC1), DIVISAO (TC2) e MELGUEIRA (TC3); "PESO DA COLMEIA" sem o
 *   rodape RAW/TARA/K. A fonte da Adafruit nao tem letra com til: o til e
 *   desenhado por cima (DIVISAO, ILUMINACAO com acento). A serial nao mudou.
 *
 * O que mudou na 2.1.0 em relacao a 2.0.0 (gravada e fotografada em 07/10/2026):
 *
 *  1. TELA COM O TAMANHO CERTO. A tela da HW-657A e um ST7789 de 1,14" com
 *     240 x 135 pixels visiveis, e nao 320 x 240. A 2.0 desenhava em 320 x 240
 *     e o painel mostrava so o miolo (x 40..279, y 52..186): cabecalho,
 *     letreiro e as bordas de cada pagina ficavam de fora. Agora o display e
 *     iniciado como 135 x 240 (a biblioteca aplica os deslocamentos 40/52 do
 *     painel) e todos os paineis foram redesenhados para 240 x 135.
 *
 *  2. CARROSSEL CONTINUO. No lugar do rodizio que trocava de pagina a cada 4 s,
 *     os paineis ficam lado a lado numa faixa que passa sem parar da direita
 *     para a esquerda e recomeca ao fim. E a mesma tecnica do letreiro da 2.0
 *     levada para a tela inteira: cada quadro e montado num buffer fora da tela
 *     (GFXcanvas16 240 x 135) e enviado de uma vez, sem piscar, e a posicao e
 *     funcao do relogio, entao a velocidade nao muda quando um sensor atrasa
 *     um quadro. CARROSSEL_PAUSA_MS > 0 faz cada painel parar enquadrado.
 *
 *  3. Os numeros grandes ficam alinhados a direita numa ancora fixa, com a
 *     unidade menor ao lado: quando o valor ganha um digito ele cresce para a
 *     esquerda e nada "pula" enquanto o painel passa.
 *
 *  4. Cabecalho e letreiro de rodape sairam: estavam fora da area visivel e o
 *     proprio carrossel passou a fazer o papel do letreiro.
 *
 * TC3: CS remanejado para TX2 / GPIO17. Mantidos os demais pinos e sensores
 * (HX711 com fator medido separadamente no sketch Q0481-Sketch-Calibrar,
 * tara por media de 10 e pesagem por media de 5, MAX6675 com conferencia dos
 * bits fixos, deteccao DHT11/DHT22), agendador cooperativo e formato serial.
 * Este firmware completo nao calibra o fator; ele usa o fator desta montagem.
 *
 * Placa na Arduino IDE: "ESP32 Dev Module". Serial: 115200.
 * ========================================================================== */

#include <Arduino.h>
#include <DHT.h>
#include <HX711.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <SPI.h>
#include <Wire.h>
#include <new>
#include <NimBLEDevice.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <esp_timer.h>
#include <esp_mac.h>

#include "logos.h"

#define FW_VERSAO "2.2.0-BLE"

/* ------------------------------------------------------------------------- */
/* 1. PINAGEM (TC3 em TX2 / GPIO17; demais pinos mantidos)                    */
/* ------------------------------------------------------------------------- */

/* DHT no D27 para nao compartilhar o RST do TFT. */
#define DHT_PIN 27

/* Tres MAX6675: SCK e SO compartilhados, CS individual. */
#define MAX6675_SCK  25  /* D25 / GPIO25 = SCK ou CLK, comum */
#define MAX6675_SO   26  /* D26 / GPIO26 = SO/DO, comum */
#define MAX6675_CS1  14  /* D14 / GPIO14 = CS do termopar 1 */
#define MAX6675_CS2  13  /* D13 / GPIO13 = CS do termopar 2 */
#define MAX6675_CS3  17  /* TX2 / GPIO17 = CS do termopar 3 */

/* HX711: uma celula de 3 fios (meia ponte) + complemento da folha 7, opcao B.
 * Ponto central da celula em A+; extremos em E+ e E- conforme o desenho.
 * Dois resistores casados de 1 kohm: E+ -> A- -> E-. B+/B- nao utilizados.
 * DT no D34 (so entrada), SCK no D19; demais GPIOs preservados. */
#define HX711_DT  34
#define HX711_SCK 19

/* BH1750FVI no I2C. */
#define I2C_SDA 21
#define I2C_SCL 22
#define BH1750_ADDR_PAD_LOW  0x23
#define BH1750_ADDR_PAD_HIGH 0x5C

/* Display ST7789 da HW-657A (SPI nativo: MOSI 23, SCLK 18).
 * Painel de 1,14": 135 x 240 em retrato. init(135, 240) faz a biblioteca
 * aplicar os deslocamentos do painel na memoria de 240 x 320 do controlador.
 * Rotacao 1 = paisagem 240 x 135, mesma orientacao da 2.0. */
#define TFT_CS   15
#define TFT_DC   2
#define TFT_RST  4
#define TFT_BL   32
#define TFT_PAINEL_W 135
#define TFT_PAINEL_H 240
#define TFT_ROT  1

/* 40 MHz = 80 MHz / 2, divisor exato no ESP32 (sem chuvisco na 2.0 gravada).
 * Se aparecer chuvisco na tela, volte para 26666666UL. */
#define TFT_SPI_HZ 40000000UL

/* ------------------------------------------------------------------------- */
/* 2. AJUSTES                                                                 */
/* ------------------------------------------------------------------------- */

/* Medicao feita no sketch separado Q0481-Sketch-Calibrar, com massa conhecida.
 * Este fator pertence somente a montagem validada; nao copiar para outra.
 * Para outra celula/HX711/mecanica, calibre no sketch separado e ajuste uma
 * copia identificada deste firmware antes de usar o peso em kg. */
#define HX711_CONTAGENS_POR_KG -42198.333f

#define PERIODO_DHT_MS       2500UL  /* DHT22 exige >= 2 s entre leituras */
#define PERIODO_LUX_MS       1000UL
#define PERIODO_TC_MS        2000UL  /* MAX6675 converte em ate 220 ms */
#define PERIODO_HX711_MS     1000UL
#define HX711_ESPERA_MS        20UL  /* reconsulta enquanto DT estiver alto */
#define HX711_ESPERAS_MAX      25    /* 25 x 20 ms = 500 ms, igual a 1.x */
#define BH1750_REDETECTA_MS 10000UL  /* sensor ausente: tenta de novo a cada 10 s */
#define DHT_FALHAS_REDETECTA    3    /* falhas seguidas antes de testar o outro tipo */

/* Registro em memoria (secao 11b). */
#define REGISTRO_INTERVALO_S   600UL   /* padrao: 10 min; o celular pode mudar */
#define REGISTRO_CAPACIDADE    4464UL  /* 31 dias a cada 10 min (143 kB) */

#define SPLASH_MIN_MS        2500UL  /* tempo minimo da tela de abertura */
#define PAINEL_LOGOS            1    /* 1 = painel dos logotipos no carrossel */

/* Carrossel: velocidade em pixels por segundo. A 30 px/s cada painel leva 8 s
 * para atravessar a tela; com os 5 paineis a volta completa dura 40 s. */
#define CARROSSEL_PX_S         30UL
/* 0 = passa continuamente, sem parar. Com, p. ex., 3000, cada painel para 3 s
 * enquadrado antes de seguir. */
#define CARROSSEL_PAUSA_MS      0UL
/* Maior intervalo entre redesenhos durante a pausa (valor novo aparece logo). */
#define CARROSSEL_REVISAO_MS   20UL

/* ------------------------------------------------------------------------- */
/* 3. GEOMETRIA E CORES DA TELA (paisagem 240 x 135)                          */
/* ------------------------------------------------------------------------- */

#define TELA_W  TFT_PAINEL_H                   /* 240 */
#define TELA_H  TFT_PAINEL_W                   /* 135 */

/* Cada painel ocupa exatamente uma tela. Molduras com 4 px de margem lateral:
 * entre dois paineis passa uma faixa preta de 8 px. */
#define PN_X      4
#define PN_W      (TELA_W - 2 * PN_X)          /* 232 */
#define PN_Y      3
#define PN_H      (TELA_H - 2 * PN_Y)          /* 129: y 3..131 */
#define PN_CX     (TELA_W / 2)                 /* centro horizontal */

static const uint16_t COR_FUNDO      = 0x0000;
static const uint16_t COR_PAINEL     = 0x1082;
static const uint16_t COR_CINZA      = 0xBDF7;
static const uint16_t COR_FAVO_MALHA = 0x7A40;
static const uint16_t COR_BRANCO     = 0xFFFF;
static const uint16_t COR_ROTULO     = ST77XX_CYAN;
static const uint16_t COR_OK         = ST77XX_GREEN;
static const uint16_t COR_FALHA      = ST77XX_YELLOW;

/* Fonte classica da Adafruit em modo CP437: 0xF8 = simbolo de grau. */
#define GRAU_C "\xF8" "C"

/* ------------------------------------------------------------------------- */
/* 4. TIPOS, OBJETOS E ESTADO                                                 */
/* (Tipos ficam aqui no topo: a IDE gera prototipos antes da 1a funcao.)      */
/* ------------------------------------------------------------------------- */

struct LeituraDht {
  bool ok;
  uint8_t tipo;
  float temperatura;
  float umidade;
};

/* Ultima leitura de cada sensor. O estado reflete a ULTIMA tentativa, sem
 * segurar valor antigo: TC3 intermitente precisa aparecer como falha. */
struct Medidas {
  LeituraDht dht;
  float lux;
  bool lux_ok;
  float tc[3];
  bool tc_ok[3];
  int32_t hx_bruto;
  bool hx_ok;
};

enum Painel : uint8_t { PN_LOGOS, PN_AMBIENTE, PN_LUZ, PN_TERMOPARES, PN_PESO };

/* Uma cena desenha a tela inteira no quadro; oy desloca na vertical quando o
 * quadro e menor que a tela (ver quadro_alocar). */
typedef void (*FuncaoCena)(GFXcanvas16& c, int16_t oy);

/* Tarefa do agendador: faz um pedaco curto de trabalho e devolve em quantos
 * ms quer rodar de novo. */
typedef uint32_t (*FuncaoTarefa)(uint32_t agora);

struct Tarefa {
  FuncaoTarefa executar;
  uint32_t atraso_inicial_ms;   /* escalona as leituras para nao coincidirem */
  uint32_t proxima_ms;
};

DHT dht11(DHT_PIN, DHT11);
DHT dht22(DHT_PIN, DHT22);
Adafruit_ST7789 tft(TFT_CS, TFT_DC, TFT_RST);

/* Quadro fora da tela: 240 x 135 x 2 bytes = 64,8 kB de heap, alocado no
 * setup. Se o heap nao tiver um bloco desse tamanho, o quadro vira uma faixa
 * menor e a tela e enviada em partes (mesmo desenho, so mais lento). */
static GFXcanvas16* quadro = nullptr;
static int16_t quadro_h = 0;

static HX711 balanca;
static bool hx711_tara_ok = false;
static uint8_t bh1750_addr = 0;

static Medidas med = {{false, 0, NAN, NAN}, NAN, false,
                      {NAN, NAN, NAN}, {false, false, false}, 0, false};

/* Ordem dos paineis no carrossel. */
static const uint8_t ORDEM_PAINEIS[] = {
#if PAINEL_LOGOS
  PN_LOGOS,
#endif
  PN_AMBIENTE, PN_LUZ, PN_TERMOPARES, PN_PESO
};
static const uint8_t N_PAINEIS = sizeof(ORDEM_PAINEIS) / sizeof(ORDEM_PAINEIS[0]);

static uint32_t carrossel_t0 = 0;        /* millis() do inicio do carrossel */
static uint32_t carrossel_pos = 0;       /* posicao da faixa em px */
static bool carrossel_sujo = true;       /* alguma medida mudou */

/* Estado da tela de abertura (desenhada com o mesmo painel dos logotipos). */
static const char* abertura_status = "firmware " FW_VERSAO "  |  HW-657A";
static uint8_t abertura_pct = 0;

/* Bluetooth e registro (secao 11b): o painel dos logotipos mostra o nome do
 * aparelho e se ha celular conectado. */
static char ble_nome[12] = "BM-??????";
static volatile bool ble_conectado = false;
static volatile bool ble_transferindo = false;
static const char* rodape_logos();
static uint16_t rodape_cor();

/* Malha de favos: o desenho se repete a cada 14 x 24 px. Cada linha guarda 14
 * bits (1 = pixel da malha). Preenchida uma vez no setup. */
static uint16_t malha_mascara[24];

/* ------------------------------------------------------------------------- */
/* 5. SENSORES                                                                */
/* ------------------------------------------------------------------------- */

static bool faixa_dht11(float temperatura, float umidade) {
  const bool faixa = !isnan(temperatura) && !isnan(umidade) &&
                     temperatura >= 0.0f && temperatura <= 50.0f &&
                     umidade >= 20.0f && umidade <= 90.0f;
  const bool inteiros = fabsf(temperatura - roundf(temperatura)) < 0.05f &&
                        fabsf(umidade - roundf(umidade)) < 0.05f;
  return faixa && inteiros;
}

static bool faixa_dht22(float temperatura, float umidade) {
  return !isnan(temperatura) && !isnan(umidade) &&
         temperatura >= -10.0f && temperatura <= 60.0f &&
         umidade >= 0.0f && umidade <= 100.0f;
}

static LeituraDht ler_dht(DHT& sensor, uint8_t tipo) {
  LeituraDht leitura = {false, tipo, NAN, NAN};
  leitura.umidade = sensor.readHumidity();
  leitura.temperatura = sensor.readTemperature();
  leitura.ok = (tipo == DHT11)
                 ? faixa_dht11(leitura.temperatura, leitura.umidade)
                 : faixa_dht22(leitura.temperatura, leitura.umidade);
  return leitura;
}

/* Quadro de 16 bits do MAX6675:
 *   D15 = 0 (bit de sinal fixo)   D14..D3 = temperatura x 4
 *   D2  = 1 com termopar aberto   D1 = 0 (ID fixo)   D0 = tri-state
 * Barramento solto (pull-up) le 0xFFFF; preso em GND le 0x0000. */
static bool max6675_quadro_valido(uint16_t bruto) {
  return bruto != 0x0000 && bruto != 0xFFFF &&
         (bruto & 0x8000) == 0 &&  /* D15 */
         (bruto & 0x0004) == 0 &&  /* D2: termopar aberto */
         (bruto & 0x0002) == 0;    /* D1 */
}

static bool max6675_ler(uint8_t cs, float* temperatura) {
  for (uint8_t tentativa = 0; tentativa < 3; ++tentativa) {
    uint16_t bruto = 0;

    digitalWrite(cs, LOW);
    delayMicroseconds(2);
    for (int8_t bit = 15; bit >= 0; --bit) {
      digitalWrite(MAX6675_SCK, HIGH);
      delayMicroseconds(1);
      if (digitalRead(MAX6675_SO)) bruto |= (uint16_t)1 << bit;
      digitalWrite(MAX6675_SCK, LOW);
      delayMicroseconds(1);
    }
    digitalWrite(cs, HIGH);

    if (max6675_quadro_valido(bruto)) {
      *temperatura = (float)((bruto >> 3) & 0x0FFF) * 0.25f;
      return true;
    }
    delay(3);
  }
  return false;
}

/* Uma ponte equilibrada pode produzir zero, -1 e outros RAW proximos de zero.
 * Rejeitar os limites de saturacao do ADC de 24 bits, nao o zero da ponte. */
static bool hx711_bruto_utilizavel(int32_t bruto) {
  return bruto > -0x00800000L && bruto < 0x007FFFFFL;
}

static inline bool hx711_pronto() { return balanca.is_ready(); }

/* A mesma biblioteca do Q0481 faz os 25 pulsos e protege a secao critica.
 * Pre-condicao: hx711_pronto(), sem espera entre conversoes no agendador. */
static bool hx711_ler_quadro(int32_t* valor) {
  *valor = (int32_t)balanca.read();
  return digitalRead(HX711_DT) == HIGH && hx711_bruto_utilizavel(*valor);
}

/* Versao com espera, usada so na tara durante a abertura. */
static bool hx711_ler_bloqueante(int32_t* valor, uint32_t limite_ms) {
  const uint32_t inicio = millis();
  while (!hx711_pronto()) {
    if (millis() - inicio > limite_ms) return false;
    delay(1);
  }
  return hx711_ler_quadro(valor);
}

static bool hx711_fazer_tara() {
  int32_t soma = 0;
  int32_t minimo = 0x007FFFFF, maximo = -0x00800000;
  uint8_t quantidade = 0;
  const uint32_t inicio = millis();

  hx711_tara_ok = false;
  delay(2000);
  while (quantidade < 10 && (uint32_t)(millis() - inicio) < 12000UL) {
    int32_t bruto = 0;
    if (hx711_ler_bloqueante(&bruto, 500UL)) {
      soma += bruto;
      if (bruto < minimo) minimo = bruto;
      if (bruto > maximo) maximo = bruto;
      ++quantidade;
    }
    delay(20);
  }
  if (quantidade < 10 || (int64_t)maximo - (int64_t)minimo > 20000LL) return false;

  balanca.set_offset(soma / 10);  /* mesma media de scale.tare() do Q0481 */
  hx711_tara_ok = true;
  return true;
}

/* Mesma conversao de get_units(): (media RAW - tara) / fator assinado.
 * Sem corte artificial de zero: preserva a leitura do sketch calibrado. */
static float hx711_para_kg(int32_t bruto) {
  return ((double)bruto - (double)balanca.get_offset()) / balanca.get_scale();
}

static bool i2c_existe(uint8_t endereco) {
  Wire.beginTransmission(endereco);
  return Wire.endTransmission() == 0;
}

static void escanear_i2c() {
  Serial.println("I2C: varredura iniciada em SDA=GPIO21 SCL=GPIO22");
  uint8_t encontrados = 0;
  for (uint8_t endereco = 0x03; endereco <= 0x77; ++endereco) {
    if (i2c_existe(endereco)) {
      Serial.printf("I2C encontrado: 0x%02X\n", endereco);
      ++encontrados;
    }
  }
  if (encontrados == 0) Serial.println("I2C: nenhum dispositivo respondeu");
}

static bool bh1750_iniciar() {
  if (i2c_existe(BH1750_ADDR_PAD_LOW)) {
    bh1750_addr = BH1750_ADDR_PAD_LOW;
  } else if (i2c_existe(BH1750_ADDR_PAD_HIGH)) {
    bh1750_addr = BH1750_ADDR_PAD_HIGH;
  } else {
    bh1750_addr = 0;
    return false;
  }

  Wire.beginTransmission(bh1750_addr);
  Wire.write(0x01);  /* power on */
  if (Wire.endTransmission() != 0) { bh1750_addr = 0; return false; }

  Wire.beginTransmission(bh1750_addr);
  Wire.write(0x07);  /* reset */
  Wire.endTransmission();
  delay(10);

  Wire.beginTransmission(bh1750_addr);
  Wire.write(0x10);  /* continuo, alta resolucao, 1 lx */
  if (Wire.endTransmission() != 0) { bh1750_addr = 0; return false; }
  delay(180);
  return true;
}

static bool bh1750_ler(float* lux) {
  if (bh1750_addr == 0) return false;
  if (Wire.requestFrom(bh1750_addr, (uint8_t)2) != 2) return false;
  const uint16_t bruto = ((uint16_t)Wire.read() << 8) | Wire.read();
  if (bruto == 0xFFFF) return false;
  *lux = (float)bruto / 1.2f;
  return true;
}

/* ------------------------------------------------------------------------- */
/* 6. LOGOTIPOS (decodificador RLE de logos.h)                                */
/* ------------------------------------------------------------------------- */

/* Fluxo de pixels de um logo: cada byte = (indice << 4) | (repeticoes - 1). */
class LeitorLogo {
 public:
  explicit LeitorLogo(const LogoRLE& logo)
      : logo_(logo), p_(logo.rle), fim_(logo.rle + logo.rle_len) {}

  uint16_t proximo() {
    if (resta_ == 0) {
      if (p_ >= fim_) {          /* dado truncado: completa sem ler alem */
        cor_ = COR_BRANCO;
        resta_ = 0xFF;
      } else {
        const uint8_t b = pgm_read_byte(p_++);
        cor_ = pgm_read_word(&logo_.paleta[b >> 4]);
        resta_ = (uint8_t)((b & 0x0F) + 1);
      }
    }
    --resta_;
    return cor_;
  }

 private:
  const LogoRLE& logo_;
  const uint8_t* p_;
  const uint8_t* fim_;
  uint8_t resta_ = 0;
  uint16_t cor_ = 0;
};

/* Desenha no quadro, recortando o que sair dele (o carrossel corta logos). */
static void desenhar_logo(GFXcanvas16& c, const LogoRLE& logo, int16_t x, int16_t y) {
  uint16_t* buf = c.getBuffer();
  if (buf == nullptr) return;
  const int16_t cw = c.width();
  const int16_t ch = c.height();
  if (x >= cw || y >= ch || x + (int16_t)logo.w <= 0 || y + (int16_t)logo.h <= 0) return;
  LeitorLogo leitor(logo);
  for (int16_t j = 0; j < (int16_t)logo.h; ++j) {
    const int16_t py = y + j;
    const bool linha_dentro = py >= 0 && py < ch;
    uint16_t* linha = buf + (int32_t)(linha_dentro ? py : 0) * cw;
    for (int16_t i = 0; i < (int16_t)logo.w; ++i) {
      const uint16_t cor = leitor.proximo();  /* consome sempre, mesmo fora */
      const int16_t px = x + i;
      if (linha_dentro && px >= 0 && px < cw) linha[px] = cor;
    }
  }
}

/* ------------------------------------------------------------------------- */
/* 7. PRIMITIVAS DE DESENHO (favos e abelhas da 1.x)                          */
/* ------------------------------------------------------------------------- */

/* Acentos do portugues. A fonte classica segue o CP437, que tem o C cedilha
 * (0x80) mas nao tem letra com til. Os textos usam estas sequencias UTF-8
 * (o arquivo continua so em ASCII) e texto() desenha o til por cima da letra.
 * Qualquer outro byte acima de 0x7F segue sendo glifo CP437 (ex.: 0xF8 = grau). */
#define A_TIL "\xC3\x83"
#define O_TIL "\xC3\x95"
#define C_CED "\xC3\x87"

static int16_t largura_texto(const char* texto, uint8_t tamanho) {
  /* Fonte classica: 6 px por caractere (5 de desenho + 1 de espaco). */
  int16_t n = 0;
  for (const uint8_t* p = (const uint8_t*)texto; *p; ++p) {
    if (*p == 0xC3 && p[1]) ++p;   /* letra acentuada: 2 bytes, 1 caractere */
    ++n;
  }
  return n > 0 ? n * 6 * tamanho - tamanho : 0;
}

/* Til de 5 x 2 pontos, uma linha acima do topo da maiuscula. */
static void desenhar_til(GFXcanvas16& c, int16_t x, int16_t y, uint8_t t, uint16_t cor) {
  static const uint8_t LINHAS[2] = {0x0D, 0x12};   /* .XX.X  e  X..X. */
  for (uint8_t r = 0; r < 2; ++r) {
    for (uint8_t col = 0; col < 5; ++col) {
      if (LINHAS[r] & (0x10 >> col)) {
        c.fillRect(x + col * t, y - (int16_t)(3 - r) * t, t, t, cor);
      }
    }
  }
}

static void texto(GFXcanvas16& c, const char* s, int16_t x, int16_t y,
                  uint8_t tamanho, uint16_t cor) {
  c.setTextSize(tamanho);
  c.setTextColor(cor);
  c.setCursor(x, y);
  for (const uint8_t* p = (const uint8_t*)s; *p; ++p) {
    if (*p != 0xC3 || p[1] == 0) {
      c.write(*p);
      continue;
    }
    const uint8_t b = *++p;
    const int16_t xl = c.getCursorX();
    if (b == 0x83 || b == 0x95) {          /* A ou O com til */
      c.write(b == 0x83 ? 'A' : 'O');
      desenhar_til(c, xl, y, tamanho, cor);
    } else if (b == 0x87) {
      c.write(0x80);                       /* C cedilha do CP437 */
    } else {
      c.write('?');
    }
  }
}

static void texto_centro(GFXcanvas16& c, const char* s, int16_t cx, int16_t y,
                         uint8_t tamanho, uint16_t cor) {
  texto(c, s, cx - largura_texto(s, tamanho) / 2, y, tamanho, cor);
}

/* Numero alinhado a direita em 'ancora' e unidade logo depois, com as bases
 * alinhadas. Se o numero ganha um digito ele cresce para a esquerda: unidade
 * e ultimos digitos ficam parados enquanto o painel passa. */
static void valor_ancorado(GFXcanvas16& c, const char* numero, const char* unidade,
                           int16_t ancora, int16_t y, uint8_t tam_num,
                           uint8_t tam_uni, uint16_t cor) {
  texto(c, numero, ancora - largura_texto(numero, tam_num), y, tam_num, cor);
  const int16_t y_uni = y + 7 * (int16_t)tam_num - 7 * (int16_t)tam_uni;
  texto(c, unidade, ancora + 2 + 2 * (int16_t)tam_uni, y_uni, tam_uni, cor);
}

/* --- Malha de favos ------------------------------------------------------ */

static void malha_ponto(int16_t x, int16_t y) {
  x %= 14; if (x < 0) x += 14;
  y %= 24; if (y < 0) y += 24;
  malha_mascara[y] |= (uint16_t)(1u << x);
}

static void malha_reta(int16_t x0, int16_t y0, int16_t x1, int16_t y1) {
  const int16_t dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
  const int16_t dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  int16_t erro = dx + dy;
  for (;;) {
    malha_ponto(x0, y0);
    if (x0 == x1 && y0 == y1) break;
    const int16_t e2 = 2 * erro;
    if (e2 >= dy) { erro += dy; x0 += sx; }
    if (e2 <= dx) { erro += dx; y0 += sy; }
  }
}

/* Mesmo hexagono vazado da 1.x (15 x 13 px), em passo de 14 x 12 com as
 * linhas impares deslocadas 7 px: o padrao se repete a cada 14 x 24 px. */
static void malha_hexagono(int16_t x, int16_t y) {
  malha_reta(x + 3, y, x + 11, y);
  malha_reta(x + 11, y, x + 14, y + 6);
  malha_reta(x + 14, y + 6, x + 11, y + 12);
  malha_reta(x + 11, y + 12, x + 3, y + 12);
  malha_reta(x + 3, y + 12, x, y + 6);
  malha_reta(x, y + 6, x + 3, y);
}

static void malha_preparar() {
  memset(malha_mascara, 0, sizeof(malha_mascara));
  malha_hexagono(0, 0);
  malha_hexagono(7, 12);
}

/* Preenche o retangulo com a malha, presa ao canto do retangulo (anda junto
 * com o painel) e recortada nas bordas do quadro. */
static void malha(GFXcanvas16& c, int16_t x, int16_t y, int16_t w, int16_t h, uint16_t cor) {
  uint16_t* buf = c.getBuffer();
  if (buf == nullptr) return;
  const int16_t cw = c.width();
  const int16_t ch = c.height();
  const int16_t x0 = x < 0 ? 0 : x;
  const int16_t x1 = (x + w) > cw ? cw : (x + w);
  const int16_t y0 = y < 0 ? 0 : y;
  const int16_t y1 = (y + h) > ch ? ch : (y + h);
  if (x0 >= x1 || y0 >= y1) return;
  for (int16_t py = y0; py < y1; ++py) {
    const uint16_t m = malha_mascara[(py - y) % 24];
    if (m == 0) continue;
    uint16_t* linha = buf + (int32_t)py * cw;
    uint8_t fase = (uint8_t)((x0 - x) % 14);
    for (int16_t px = x0; px < x1; ++px) {
      if (m & (1u << fase)) linha[px] = cor;
      if (++fase == 14) fase = 0;
    }
  }
}

/* Painel arredondado com fundo escuro, malha de favos e borda ciano. */
static void moldura(GFXcanvas16& c, int16_t x, int16_t y, int16_t w, int16_t h) {
  c.fillRoundRect(x, y, w, h, 8, COR_PAINEL);
  malha(c, x + 3, y + 3, w - 6, h - 6, COR_FAVO_MALHA);
  c.drawRoundRect(x, y, w, h, 8, ST77XX_CYAN);
}

/* --- Abelhas e favos ------------------------------------------------------ */

static void desenhar_hexagono(Adafruit_GFX& g, int16_t x, int16_t y, uint16_t cor) {
  for (int16_t linha = 0; linha < 14; ++linha) {
    const int16_t margem = (linha < 3) ? (3 - linha)
                         : (linha > 10) ? (linha - 10) : 0;
    g.drawFastHLine(x + margem, y + linha, 16 - 2 * margem, cor);
  }
}

static void desenhar_favo(Adafruit_GFX& g, int16_t x, int16_t y) {   /* 29 x 24 */
  desenhar_hexagono(g, x, y, ST77XX_YELLOW);
  desenhar_hexagono(g, x + 13, y, ST77XX_YELLOW);
  desenhar_hexagono(g, x + 6, y + 10, ST77XX_YELLOW);
}

static void desenhar_abelha(Adafruit_GFX& g, int16_t x, int16_t y) {  /* 31 x 18 */
  g.fillCircle(x + 7, y + 3, 4, ST77XX_WHITE);
  g.fillCircle(x + 17, y + 3, 4, ST77XX_WHITE);
  g.fillRoundRect(x, y + 6, 26, 12, 5, ST77XX_YELLOW);
  g.drawRoundRect(x, y + 6, 26, 12, 5, ST77XX_BLACK);
  g.drawFastVLine(x + 8, y + 7, 10, ST77XX_BLACK);
  g.drawFastVLine(x + 16, y + 7, 10, ST77XX_BLACK);
  g.fillCircle(x + 28, y + 12, 2, ST77XX_YELLOW);
}

static void desenhar_abelha_mini(Adafruit_GFX& g, int16_t x, int16_t y) {  /* 19 x 11 */
  g.fillCircle(x + 4, y + 2, 2, ST77XX_WHITE);
  g.fillCircle(x + 10, y + 2, 2, ST77XX_WHITE);
  g.fillRoundRect(x, y + 3, 15, 8, 3, ST77XX_YELLOW);
  g.drawRoundRect(x, y + 3, 15, 8, 3, ST77XX_BLACK);
  g.drawFastVLine(x + 5, y + 4, 6, ST77XX_BLACK);
  g.drawFastVLine(x + 10, y + 4, 6, ST77XX_BLACK);
  g.fillCircle(x + 17, y + 7, 1, ST77XX_YELLOW);
}

static void desenhar_abelha_inteira(Adafruit_GFX& g, int16_t x, int16_t y) {  /* 44 x 30 */
  g.fillCircle(x + 9, y + 7, 5, ST77XX_WHITE);
  g.fillCircle(x + 19, y + 5, 5, ST77XX_WHITE);
  g.drawLine(x + 25, y + 9, x + 29, y + 2, ST77XX_WHITE);
  g.drawLine(x + 28, y + 10, x + 34, y + 5, ST77XX_WHITE);
  g.fillRoundRect(x + 3, y + 9, 28, 16, 6, ST77XX_YELLOW);
  g.drawRoundRect(x + 3, y + 9, 28, 16, 6, ST77XX_BLACK);
  g.drawFastVLine(x + 12, y + 10, 14, ST77XX_BLACK);
  g.drawFastVLine(x + 21, y + 10, 14, ST77XX_BLACK);
  g.fillCircle(x + 32, y + 17, 6, ST77XX_YELLOW);
  g.drawCircle(x + 32, y + 17, 6, ST77XX_BLACK);
  g.fillCircle(x + 34, y + 15, 1, ST77XX_BLACK);
  g.drawLine(x + 37, y + 17, x + 43, y + 17, ST77XX_YELLOW);
  g.drawLine(x + 10, y + 25, x + 7, y + 29, ST77XX_BLACK);
  g.drawLine(x + 23, y + 25, x + 26, y + 29, ST77XX_BLACK);
}

/* ------------------------------------------------------------------------- */
/* 8. PAINEIS (240 x 135 cada; ox, oy = canto superior esquerdo no quadro)    */
/* ------------------------------------------------------------------------- */

/* Logotipos. Tambem e a tela de abertura: com progresso < 100 o filete
 * laranja vira barra de progresso e a ultima linha mostra a etapa. Assim a
 * abertura se transforma no primeiro painel do carrossel sem salto. */
#define LOGOS_Y        7                      /* logos de 84 px: y 7..90 */
#define LOGOS_VAO     10
#define FILETE_Y      95
#define FILETE_X      16
#define FILETE_W     (TELA_W - 2 * FILETE_X)

static void painel_logos(GFXcanvas16& c, int16_t ox, int16_t oy,
                         const char* rodape, uint16_t cor_rodape, uint8_t pct) {
  c.fillRoundRect(ox + PN_X, oy + PN_Y, PN_W, PN_H, 8, COR_BRANCO);
  const int16_t total = (int16_t)LOGO_ABELHA_84.w + LOGOS_VAO + (int16_t)LOGO_IPE_84.w;
  const int16_t x0 = ox + (TELA_W - total) / 2;
  desenhar_logo(c, LOGO_ABELHA_84, x0, oy + LOGOS_Y);
  desenhar_logo(c, LOGO_IPE_84, x0 + (int16_t)LOGO_ABELHA_84.w + LOGOS_VAO, oy + LOGOS_Y);

  const int16_t cheio = (int16_t)((int32_t)FILETE_W * (pct > 100 ? 100 : pct) / 100);
  if (pct < 100) c.fillRect(ox + FILETE_X, oy + FILETE_Y, FILETE_W, 2, COR_CINZA);
  c.fillRect(ox + FILETE_X, oy + FILETE_Y, cheio, 2, COR_MARCA_LARANJA);

  texto_centro(c, "BEEMETER", ox + PN_CX, oy + 100, 2, COR_MARCA_MARROM);
  texto_centro(c, rodape, ox + PN_CX, oy + 119, 1, cor_rodape);
}

/* Temperatura e umidade: dois paineis de 62 px, um sobre o outro. */
#define AMB_H          62
#define AMB_Y1         PN_Y                   /* 3..64 */
#define AMB_Y2        (PN_Y + AMB_H + 5)      /* 70..131 */
#define AMB_ANCORA_T  145   /* "24.6" + "oC" centrado em x = 120 */
#define AMB_ANCORA_UR 154   /* "77.3" + "%"  centrado em x = 120 */

static void painel_ambiente(GFXcanvas16& c, int16_t ox, int16_t oy) {
  const LeituraDht& d = med.dht;
  const uint16_t cor = d.ok ? COR_OK : COR_FALHA;
  char num[16];

  moldura(c, ox + PN_X, oy + AMB_Y1, PN_W, AMB_H);
  desenhar_abelha(c, ox + 14, oy + AMB_Y1 + 26);
  desenhar_favo(c, ox + 196, oy + AMB_Y1 + 23);
  texto_centro(c, "TEMPERATURA AMBIENTE", ox + PN_CX, oy + AMB_Y1 + 7, 1, COR_ROTULO);
  if (d.ok) snprintf(num, sizeof(num), "%.1f", d.temperatura);
  else      snprintf(num, sizeof(num), "--.-");
  valor_ancorado(c, num, GRAU_C, ox + AMB_ANCORA_T, oy + AMB_Y1 + 22, 4, 3, cor);

  moldura(c, ox + PN_X, oy + AMB_Y2, PN_W, AMB_H);
  desenhar_favo(c, ox + 12, oy + AMB_Y2 + 23);
  desenhar_abelha(c, ox + 194, oy + AMB_Y2 + 26);
  texto_centro(c, "UMIDADE DO AMBIENTE", ox + PN_CX, oy + AMB_Y2 + 7, 1, COR_ROTULO);
  if (d.ok) snprintf(num, sizeof(num), "%.1f", d.umidade);
  else      snprintf(num, sizeof(num), "--.-");
  valor_ancorado(c, num, "%", ox + AMB_ANCORA_UR, oy + AMB_Y2 + 22, 4, 3, cor);
}

/* Paineis de valor unico (luz e peso), sem rodape: rotulo, numero e uma
 * faixa de abelhas, distribuidos na altura do painel. */
#define ROTULO_Y      20    /* rotulo tamanho 1: y 20..26 */
#define VALOR_Y       40    /* numero tamanho 4: y 40..67 */
#define ABELHAS_Y     82    /* faixa de abelhas: y 82..111 */
#define LUZ_ANCORA   126    /* 3 a 4 digitos + "lux" perto do centro; 5 cabem */
#define PESO_ANCORA  158    /* 5 a 6 caracteres perto do centro; "125.30" cabe */

static void faixa_abelhas(GFXcanvas16& c, int16_t ox, int16_t oy) {
  desenhar_abelha_inteira(c, ox + 16, oy + ABELHAS_Y);
  desenhar_abelha_mini(c, ox + 84, oy + ABELHAS_Y + 12);
  desenhar_abelha_mini(c, ox + 138, oy + ABELHAS_Y + 6);
  desenhar_favo(c, ox + 192, oy + ABELHAS_Y + 4);
}

static void painel_luz(GFXcanvas16& c, int16_t ox, int16_t oy) {
  char linha[16];
  moldura(c, ox + PN_X, oy + PN_Y, PN_W, PN_H);
  faixa_abelhas(c, ox, oy);
  texto_centro(c, "ILUMINA" C_CED A_TIL "O", ox + PN_CX, oy + ROTULO_Y, 1, COR_ROTULO);
  if (med.lux_ok) snprintf(linha, sizeof(linha), "%.0f", med.lux);
  else            snprintf(linha, sizeof(linha), "--");
  valor_ancorado(c, linha, "lux", ox + LUZ_ANCORA, oy + VALOR_Y, 4, 3,
                 med.lux_ok ? COR_OK : COR_FALHA);
}

/* Tres faixas de 36 px; titulo em cima. Posicao dos termopares na colmeia
 * (ver arranjo vertical no projeto): TC1 no fundo (ninho), TC2 na divisao,
 * TC3 na melgueira. */
#define TC_Y0        16
#define TC_H         36
#define TC_PASSO     40     /* 16..51, 56..91, 96..131 */
#define TC_NOME_X    12     /* "MELGUEIRA" vai ate x = 117 */
#define TC_ANCORA   199     /* "22.50" a partir de x = 141; "oC" termina em 226 */

static const char* const NOME_TC[3] = {"FUNDO", "DIVIS" A_TIL "O", "MELGUEIRA"};

static void painel_termopares(GFXcanvas16& c, int16_t ox, int16_t oy) {
  char num[16];
  texto_centro(c, "TEMPERATURA NA COLMEIA", ox + PN_CX, oy + 5, 1, COR_ROTULO);
  desenhar_hexagono(c, ox + 32, oy + 1, ST77XX_YELLOW);
  desenhar_hexagono(c, ox + TELA_W - 32 - 16, oy + 1, ST77XX_YELLOW);
  for (uint8_t i = 0; i < 3; ++i) {
    const int16_t y = oy + TC_Y0 + (int16_t)i * TC_PASSO;
    const bool ok = med.tc_ok[i];
    const uint16_t cor = ok ? COR_OK : COR_FALHA;
    moldura(c, ox + PN_X, y, PN_W, TC_H);
    texto(c, NOME_TC[i], ox + TC_NOME_X, y + 11, 2, cor);
    if (ok) snprintf(num, sizeof(num), "%.2f", med.tc[i]);
    else    snprintf(num, sizeof(num), "--.--");
    valor_ancorado(c, num, GRAU_C, ox + TC_ANCORA, y + 11, 2, 2, cor);
  }
}

static void painel_peso(GFXcanvas16& c, int16_t ox, int16_t oy) {
  char linha[16];
  const uint16_t cor = med.hx_ok ? COR_OK : COR_FALHA;
  moldura(c, ox + PN_X, oy + PN_Y, PN_W, PN_H);
  faixa_abelhas(c, ox, oy);
  texto_centro(c, "PESO DA COLMEIA", ox + PN_CX, oy + ROTULO_Y, 1, COR_ROTULO);
  if (med.hx_ok) {
    const float kg = hx711_para_kg(med.hx_bruto);
    /* 3 casas ate 100 kg; acima, 2 casas para caber na mesma largura. */
    snprintf(linha, sizeof(linha), fabsf(kg) < 100.0f ? "%.3f" : "%.2f", kg);
    valor_ancorado(c, linha, "kg", ox + PESO_ANCORA, oy + VALOR_Y, 4, 3, cor);
  } else {
    texto_centro(c, hx711_tara_ok ? "SEM LEITURA" : "SEM TARA", ox + PN_CX,
                 oy + VALOR_Y + 4, 3, cor);
  }
}

static void desenhar_painel(GFXcanvas16& c, uint8_t painel, int16_t ox, int16_t oy) {
  switch (painel) {
    case PN_LOGOS:
      painel_logos(c, ox, oy, rodape_logos(), rodape_cor(), 100);
      break;
    case PN_AMBIENTE:   painel_ambiente(c, ox, oy); break;
    case PN_LUZ:        painel_luz(c, ox, oy); break;
    case PN_TERMOPARES: painel_termopares(c, ox, oy); break;
    default:            painel_peso(c, ox, oy); break;
  }
}

/* ------------------------------------------------------------------------- */
/* 9. QUADRO FORA DA TELA E CENAS                                             */
/* ------------------------------------------------------------------------- */

/* Limpa a memoria inteira do controlador (240 x 320), inclusive as faixas que
 * o painel de 1,14" nao mostra: se algum lote de painel tiver o deslocamento
 * 1 px diferente do previsto, a linha a mais na borda sai preta, e nao com
 * lixo da memoria. As coordenadas "negativas" cancelam o deslocamento que a
 * biblioteca soma (aritmetica de 16 bits sem sinal). */
static void tft_limpar_memoria_toda() {
  const uint16_t dx = (320 - TFT_PAINEL_H) / 2;   /* 40: _rowstart da biblioteca */
  const uint16_t dy = (240 - TFT_PAINEL_W) / 2;   /* 52: _colstart2 na rotacao 1 */
  tft.startWrite();
  tft.setAddrWindow((uint16_t)(0 - dx), (uint16_t)(0 - dy), 320, 240);
  tft.writeColor(COR_FUNDO, 320UL * 240UL);
  tft.endWrite();
}

static bool quadro_alocar() {
  /* Tela inteira de uma vez (sem rasgo); se faltar heap, faixas menores. */
  static const int16_t ALTURAS[] = {TELA_H, 68, 45, 27, 15};
  for (int16_t h : ALTURAS) {
    GFXcanvas16* c = new (std::nothrow) GFXcanvas16(TELA_W, h);
    if (c != nullptr && c->getBuffer() != nullptr) {
      c->cp437(true);
      c->setTextWrap(false);
      quadro = c;
      quadro_h = h;
      return true;
    }
    delete c;
  }
  return false;
}

/* Desenha a cena no quadro e envia; com quadro menor que a tela, repete a
 * cena para cada faixa, deslocada para cima. */
static void renderizar(FuncaoCena cena) {
  if (quadro == nullptr) return;
  for (int16_t y0 = 0; y0 < TELA_H; y0 += quadro_h) {
    const int16_t h = (TELA_H - y0) < quadro_h ? (TELA_H - y0) : quadro_h;
    cena(*quadro, (int16_t)-y0);
    tft.drawRGBBitmap(0, y0, quadro->getBuffer(), TELA_W, h);
  }
}

static void cena_abertura(GFXcanvas16& c, int16_t oy) {
  c.fillScreen(COR_FUNDO);
  painel_logos(c, 0, oy, abertura_status, COR_MARCA_MARROM, abertura_pct);
}

/* Faixa de paineis: mostra o painel em que a posicao cai e o seguinte. */
static void cena_carrossel(GFXcanvas16& c, int16_t oy) {
  c.fillScreen(COR_FUNDO);
  const uint8_t i = (uint8_t)((carrossel_pos / TELA_W) % N_PAINEIS);
  const int16_t desloc = (int16_t)(carrossel_pos % TELA_W);
  desenhar_painel(c, ORDEM_PAINEIS[i], (int16_t)-desloc, oy);
  if (desloc != 0) {
    desenhar_painel(c, ORDEM_PAINEIS[(i + 1) % N_PAINEIS], (int16_t)(TELA_W - desloc), oy);
  }
}

static void abertura_etapa(const char* texto_etapa, uint8_t pct) {
  abertura_status = texto_etapa;
  abertura_pct = pct;
  renderizar(cena_abertura);
}

/* ------------------------------------------------------------------------- */
/* 10. CARROSSEL -- posicao em funcao do tempo                                */
/* ------------------------------------------------------------------------- */

#define CARROSSEL_MOV_MS   ((uint32_t)TELA_W * 1000UL / CARROSSEL_PX_S)
#define CARROSSEL_CICLO_MS (CARROSSEL_PAUSA_MS + CARROSSEL_MOV_MS)

/* t = ms desde o inicio. Cada ciclo: pausa (opcional) com o painel enquadrado
 * e depois TELA_W px a CARROSSEL_PX_S. Sem pausa, o movimento nao para. */
static uint32_t carrossel_posicao(uint32_t t) {
  const uint32_t ciclo = t / CARROSSEL_CICLO_MS;
  /* ms de movimento dentro do ciclo; negativo = ainda na pausa. */
  const int32_t mov = (int32_t)(t % CARROSSEL_CICLO_MS) - (int32_t)CARROSSEL_PAUSA_MS;
  uint32_t px = mov > 0 ? (uint32_t)mov * CARROSSEL_PX_S / 1000UL : 0;
  if (px >= TELA_W) px = TELA_W - 1;
  return (ciclo % N_PAINEIS) * TELA_W + px;
}

/* Quanto falta para a posicao andar 1 px (ou para a pausa acabar). */
static uint32_t carrossel_espera(uint32_t t) {
  const int32_t mov = (int32_t)(t % CARROSSEL_CICLO_MS) - (int32_t)CARROSSEL_PAUSA_MS;
  if (mov < 0) return (uint32_t)(-mov);
  const uint32_t d = (uint32_t)mov;
  const uint32_t px = d * CARROSSEL_PX_S / 1000UL;
  const uint32_t d_proximo = ((px + 1) * 1000UL + CARROSSEL_PX_S - 1) / CARROSSEL_PX_S;
  return d_proximo > d ? d_proximo - d : 1;
}

/* ------------------------------------------------------------------------- */
/* 11. TAREFAS                                                                */
/* ------------------------------------------------------------------------- */

static uint32_t tarefa_carrossel(uint32_t) {
  const uint32_t t = millis() - carrossel_t0;
  const uint32_t pos = carrossel_posicao(t);
  if (pos != carrossel_pos || carrossel_sujo) {
    carrossel_pos = pos;
    carrossel_sujo = false;
    renderizar(cena_carrossel);
  }
  /* Medido depois de desenhar: o agendador soma a espera ao relogio de agora,
   * entao as leituras dos sensores ganham a vez entre dois quadros. */
  uint32_t espera = carrossel_espera(millis() - carrossel_t0);
  if (espera > CARROSSEL_REVISAO_MS) espera = CARROSSEL_REVISAO_MS;
  return espera;
}

/* DHT: tenta DHT11 e DHT22 alternadamente ate um responder; depois fixa o
 * tipo e so volta a procurar apos DHT_FALHAS_REDETECTA falhas seguidas. */
static uint32_t tarefa_dht(uint32_t) {
  static uint8_t tipo_confirmado = 0;
  static uint8_t tipo_tentativa = DHT11;
  static uint8_t falhas = 0;

  const uint8_t tipo = tipo_confirmado ? tipo_confirmado : tipo_tentativa;
  const LeituraDht leitura = (tipo == DHT11) ? ler_dht(dht11, DHT11) : ler_dht(dht22, DHT22);
  med.dht = leitura;

  if (leitura.ok) {
    tipo_confirmado = leitura.tipo;
    falhas = 0;
    Serial.printf("DHT%u OK GPIO27: T=%.1f C UR=%.1f %%\n",
                  (unsigned)leitura.tipo, leitura.temperatura, leitura.umidade);
  } else if (tipo_confirmado) {
    Serial.println("DHT sem leitura valida no GPIO27");
    if (++falhas >= DHT_FALHAS_REDETECTA) {
      tipo_confirmado = 0;
      falhas = 0;
    }
  } else {
    Serial.printf("DHT%u GPIO27 sem resposta valida: T=%.1f UR=%.1f\n",
                  (unsigned)tipo, leitura.temperatura, leitura.umidade);
    tipo_tentativa = (tipo_tentativa == DHT11) ? DHT22 : DHT11;
  }
  carrossel_sujo = true;
  return PERIODO_DHT_MS;
}

static uint32_t tarefa_lux(uint32_t agora) {
  static uint32_t ultima_deteccao = 0;
  if (bh1750_addr == 0 && agora - ultima_deteccao >= BH1750_REDETECTA_MS) {
    ultima_deteccao = agora;
    if (bh1750_iniciar()) Serial.printf("BH1750 OK no endereco 0x%02X\n", bh1750_addr);
  }
  float lux = NAN;
  med.lux_ok = bh1750_ler(&lux);
  med.lux = lux;
  if (med.lux_ok) Serial.printf("BH1750 OK 0x%02X: %.1f lux\n", bh1750_addr, lux);
  else            Serial.println("BH1750 sem leitura");
  carrossel_sujo = true;
  return PERIODO_LUX_MS;
}

static uint32_t tarefa_termopares(uint32_t) {
  static const uint8_t CS[3] = {MAX6675_CS1, MAX6675_CS2, MAX6675_CS3};
  for (uint8_t i = 0; i < 3; ++i) {
    float t = NAN;
    med.tc_ok[i] = max6675_ler(CS[i], &t);
    med.tc[i] = t;
    Serial.printf("MAX6675 TC%u CS%u: %s T=%.2f C\n", (unsigned)(i + 1),
                  (unsigned)CS[i], med.tc_ok[i] ? "OK" : "ERRO", t);
  }
  carrossel_sujo = true;
  return PERIODO_TC_MS;
}

static uint32_t tarefa_hx711(uint32_t) {
  static uint8_t esperas = 0, quantidade = 0;
  static int32_t soma = 0;

  if (!hx711_tara_ok) {
    esperas = quantidade = 0;
    soma = 0;
    med.hx_ok = false;
    Serial.println("HX711 sem leitura: tara invalida ou ausente");
    carrossel_sujo = true;
    return PERIODO_HX711_MS;
  }

  if (quantidade == 0 && esperas == 0) balanca.power_up();
  if (!hx711_pronto()) {                     /* conversao em andamento */
    if (++esperas < HX711_ESPERAS_MAX) return HX711_ESPERA_MS;
    esperas = quantidade = 0;
    soma = 0;
    med.hx_ok = false;
    Serial.println("HX711 sem leitura: DT alto, modulo ausente ou RAW invalido");
    carrossel_sujo = true;
    return PERIODO_HX711_MS;
  }
  esperas = 0;

  int32_t bruto = 0;
  if (!hx711_ler_quadro(&bruto)) {
    quantidade = 0;
    soma = 0;
    med.hx_ok = false;
    Serial.println("HX711 sem leitura: DT alto, modulo ausente ou RAW invalido");
    carrossel_sujo = true;
    return PERIODO_HX711_MS;
  }

  /* Equivalente a get_units(5), mas uma conversao por chamada para a tela rodar. */
  soma += bruto;
  if (++quantidade < 5) return HX711_ESPERA_MS;
  med.hx_bruto = soma / 5;
  quantidade = 0;
  soma = 0;
  med.hx_ok = true;
  Serial.printf("HX711 OK DT34/SCK19: RAW=%ld PESO=%.3f kg\n",
                (long)med.hx_bruto, hx711_para_kg(med.hx_bruto));
  balanca.power_down();
  carrossel_sujo = true;
  return PERIODO_HX711_MS;
}

/* ------------------------------------------------------------------------- */
/* 11b. REGISTRO EM MEMORIA E BLUETOOTH                                       */
/*                                                                           */
/* Registro: arquivo circular /registro.bin no LittleFS. Cabecalho de 32 bytes */
/* e REGISTRO_CAPACIDADE posicoes de 32 bytes. O registro mais antigo tem     */
/* seq = proximo_seq - quantidade; os seguintes vem em ordem, sem buracos.    */
/*                                                                           */
/* Bluetooth: servico BLE_SERVICO com quatro caracteristicas:                 */
/*   INFO    (leitura)     JSON com nome, firmware, partida, relogio e fila   */
/*   AGORA   (leitura)     JSON com a ultima medida de cada sensor            */
/*   COMANDO (escrita)     texto: HORA <epoca>, LER <seq>, INTERVALO <s>,     */
/*                         TARA, APAGAR                                       */
/*   DADOS   (notificacao) resposta ao LER: pacotes 'D' + bytes dos registros */
/*                         em sequencia (o celular remonta de 32 em 32) e,    */
/*                         no fim, 'F' + quantidade enviada (uint32 LE).      */
/* ------------------------------------------------------------------------- */

#define BLE_SERVICO "6e7a0001-b5a3-4f4b-9a3e-6d656c697061"
#define BLE_INFO    "6e7a0002-b5a3-4f4b-9a3e-6d656c697061"
#define BLE_AGORA   "6e7a0003-b5a3-4f4b-9a3e-6d656c697061"
#define BLE_COMANDO "6e7a0004-b5a3-4f4b-9a3e-6d656c697061"
#define BLE_DADOS   "6e7a0005-b5a3-4f4b-9a3e-6d656c697061"

#define REGISTRO_ARQUIVO "/registro.bin"
#define REGISTRO_MAGICO  0x31524D42UL  /* "BMR1" */
#define REGISTRO_VERSAO  1

/* Bits de 'validos' */
#define V_DHT  0x01
#define V_LUX  0x02
#define V_TC1  0x04
#define V_TC2  0x08
#define V_TC3  0x10
#define V_PESO 0x20

struct __attribute__((packed)) RegistroCab {
  uint32_t magico;
  uint16_t versao;
  uint16_t tamanho;       /* sizeof(Registro) */
  uint32_t capacidade;
  uint32_t inicio;        /* posicao do registro mais antigo */
  uint32_t quantidade;
  uint32_t proximo_seq;
  uint32_t intervalo_s;
  uint32_t reservado;
};

struct __attribute__((packed)) Registro {
  uint32_t seq;
  uint32_t epoca;         /* hora real (s desde 1970, UTC); 0 = relogio nao acertado */
  uint32_t uptime_s;      /* segundos desde a partida */
  uint16_t boot;          /* numero da partida */
  int16_t  t_amb_x10;     /* temperatura ambiente x 10 */
  uint16_t ur_x10;        /* umidade do ambiente x 10 */
  uint16_t lux;           /* iluminacao (limitada a 65535) */
  int16_t  tc_x4[3];      /* termopares x 4: fundo, divisao, melgueira */
  int32_t  peso_g;        /* peso da colmeia em gramas */
  uint8_t  validos;       /* bits V_* */
  uint8_t  dht_tipo;      /* 11 ou 22 */
};

static_assert(sizeof(RegistroCab) == 32, "cabecalho deve ter 32 bytes");
static_assert(sizeof(Registro) == 32, "registro deve ter 32 bytes");

static RegistroCab reg_cab;
static bool reg_ok = false;
static uint16_t boot_num = 0;
static int64_t epoca_base = 0;        /* hora real no instante uptime 0 */

static NimBLEServer* ble_servidor = nullptr;
static NimBLECharacteristic* ch_info = nullptr;
static NimBLECharacteristic* ch_agora = nullptr;
static NimBLECharacteristic* ch_dados = nullptr;

static char cmd_ble[64];
static volatile bool cmd_ble_novo = false;
static char cmd_serial[64];
static uint8_t cmd_serial_n = 0;

/* Transferencia em andamento (resposta ao LER) */
static uint32_t tr_seq = 0, tr_fim = 0, tr_enviados = 0;
static Registro tr_reg;
static uint8_t tr_off = sizeof(Registro);

static uint32_t uptime_s() { return (uint32_t)(esp_timer_get_time() / 1000000ULL); }
static uint32_t epoca_agora() { return epoca_base > 0 ? (uint32_t)(epoca_base + uptime_s()) : 0; }
static uint32_t reg_seq_antigo() { return reg_cab.proximo_seq - reg_cab.quantidade; }

static bool reg_gravar_cab() {
  File f = LittleFS.open(REGISTRO_ARQUIVO, "r+");
  if (!f) return false;
  f.seek(0);
  const bool ok = f.write((const uint8_t*)&reg_cab, sizeof(reg_cab)) == sizeof(reg_cab);
  f.close();
  return ok;
}

static bool reg_criar() {
  memset(&reg_cab, 0, sizeof(reg_cab));
  reg_cab.magico = REGISTRO_MAGICO;
  reg_cab.versao = REGISTRO_VERSAO;
  reg_cab.tamanho = sizeof(Registro);
  reg_cab.capacidade = REGISTRO_CAPACIDADE;
  reg_cab.proximo_seq = 1;
  reg_cab.intervalo_s = REGISTRO_INTERVALO_S;
  File f = LittleFS.open(REGISTRO_ARQUIVO, "w");
  if (!f) return false;
  f.write((const uint8_t*)&reg_cab, sizeof(reg_cab));
  static uint8_t zeros[512];
  memset(zeros, 0, sizeof(zeros));
  uint32_t falta = REGISTRO_CAPACIDADE * sizeof(Registro);
  while (falta > 0) {
    const uint32_t n = falta > sizeof(zeros) ? sizeof(zeros) : falta;
    if (f.write(zeros, n) != n) { f.close(); return false; }
    falta -= n;
  }
  f.close();
  return true;
}

static bool reg_iniciar() {
  if (!LittleFS.begin(true)) {
    Serial.println("REGISTRO: LittleFS nao montou (esquema de particoes com spiffs?)");
    return false;
  }
  const uint32_t tamanho = sizeof(RegistroCab) + REGISTRO_CAPACIDADE * sizeof(Registro);
  File f = LittleFS.open(REGISTRO_ARQUIVO, "r");
  bool valido = false;
  if (f) {
    valido = f.size() == tamanho &&
             f.read((uint8_t*)&reg_cab, sizeof(reg_cab)) == sizeof(reg_cab) &&
             reg_cab.magico == REGISTRO_MAGICO && reg_cab.versao == REGISTRO_VERSAO &&
             reg_cab.tamanho == sizeof(Registro) && reg_cab.capacidade == REGISTRO_CAPACIDADE &&
             reg_cab.quantidade <= REGISTRO_CAPACIDADE && reg_cab.inicio < REGISTRO_CAPACIDADE;
    f.close();
  }
  if (!valido && !reg_criar()) {
    Serial.println("REGISTRO: nao foi possivel criar o arquivo");
    return false;
  }
  if (reg_cab.intervalo_s < 60 || reg_cab.intervalo_s > 3600) reg_cab.intervalo_s = REGISTRO_INTERVALO_S;
  Serial.printf("REGISTRO: %lu registros, seq %lu..%lu, a cada %lu s\n",
                (unsigned long)reg_cab.quantidade, (unsigned long)reg_seq_antigo(),
                (unsigned long)(reg_cab.proximo_seq - 1), (unsigned long)reg_cab.intervalo_s);
  return true;
}

static bool reg_ler(uint32_t seq, Registro* r) {
  if (seq < reg_seq_antigo() || seq >= reg_cab.proximo_seq) return false;
  const uint32_t pos = (reg_cab.inicio + (seq - reg_seq_antigo())) % REGISTRO_CAPACIDADE;
  File f = LittleFS.open(REGISTRO_ARQUIVO, "r");
  if (!f) return false;
  f.seek(sizeof(RegistroCab) + pos * sizeof(Registro));
  const bool ok = f.read((uint8_t*)r, sizeof(Registro)) == sizeof(Registro);
  f.close();
  return ok && r->seq == seq;
}

static int16_t arred16(float v, float escala) {
  const float x = roundf(v * escala);
  return (int16_t)(x > 32767.0f ? 32767 : (x < -32768.0f ? -32768 : x));
}

static void reg_montar(Registro* r) {
  memset(r, 0, sizeof(*r));
  r->seq = reg_cab.proximo_seq;
  r->epoca = epoca_agora();
  r->uptime_s = uptime_s();
  r->boot = boot_num;
  if (med.dht.ok) {
    r->validos |= V_DHT;
    r->t_amb_x10 = arred16(med.dht.temperatura, 10.0f);
    r->ur_x10 = (uint16_t)arred16(med.dht.umidade, 10.0f);
    r->dht_tipo = med.dht.tipo;
  }
  if (med.lux_ok) {
    r->validos |= V_LUX;
    r->lux = (uint16_t)(med.lux > 65535.0f ? 65535 : (med.lux < 0 ? 0 : lroundf(med.lux)));
  }
  for (uint8_t i = 0; i < 3; ++i) {
    if (med.tc_ok[i]) {
      r->validos |= (uint8_t)(V_TC1 << i);
      r->tc_x4[i] = arred16(med.tc[i], 4.0f);
    }
  }
  if (med.hx_ok && hx711_tara_ok) {
    r->validos |= V_PESO;
    r->peso_g = (int32_t)lround((double)hx711_para_kg(med.hx_bruto) * 1000.0);
  }
}

static bool reg_acrescentar() {
  if (!reg_ok) return false;
  Registro r;
  reg_montar(&r);
  const uint32_t pos = (reg_cab.inicio + reg_cab.quantidade) % REGISTRO_CAPACIDADE;
  File f = LittleFS.open(REGISTRO_ARQUIVO, "r+");
  if (!f) return false;
  f.seek(sizeof(RegistroCab) + pos * sizeof(Registro));
  bool ok = f.write((const uint8_t*)&r, sizeof(r)) == sizeof(r);
  if (ok) {
    if (reg_cab.quantidade < REGISTRO_CAPACIDADE) ++reg_cab.quantidade;
    else reg_cab.inicio = (reg_cab.inicio + 1) % REGISTRO_CAPACIDADE;
    ++reg_cab.proximo_seq;
    f.seek(0);
    ok = f.write((const uint8_t*)&reg_cab, sizeof(reg_cab)) == sizeof(reg_cab);
  }
  f.close();
  return ok;
}

/* ---- JSON das caracteristicas ---- */

static void json_num(char* dst, size_t n, bool ok, float v, const char* fmt) {
  if (ok && !isnan(v)) snprintf(dst, n, fmt, v);
  else snprintf(dst, n, "null");
}

static size_t montar_info(char* buf, size_t n) {
  return (size_t)snprintf(buf, n,
    "{\"id\":\"%s\",\"fw\":\"%s\",\"boot\":%u,\"up\":%lu,\"epoca\":%lu,"
    "\"primeiro\":%lu,\"proximo\":%lu,\"n\":%lu,\"intervalo\":%lu,\"reg\":%s,\"tara\":%s}",
    ble_nome, FW_VERSAO, (unsigned)boot_num, (unsigned long)uptime_s(),
    (unsigned long)epoca_agora(), (unsigned long)reg_seq_antigo(),
    (unsigned long)reg_cab.proximo_seq, (unsigned long)reg_cab.quantidade,
    (unsigned long)reg_cab.intervalo_s, reg_ok ? "true" : "false",
    hx711_tara_ok ? "true" : "false");
}

static size_t montar_agora(char* buf, size_t n) {
  char t[12], ur[12], lux[12], tc[3][12], peso[16];
  json_num(t, sizeof(t), med.dht.ok, med.dht.temperatura, "%.1f");
  json_num(ur, sizeof(ur), med.dht.ok, med.dht.umidade, "%.1f");
  json_num(lux, sizeof(lux), med.lux_ok, med.lux, "%.0f");
  for (uint8_t i = 0; i < 3; ++i) json_num(tc[i], sizeof(tc[i]), med.tc_ok[i], med.tc[i], "%.2f");
  json_num(peso, sizeof(peso), med.hx_ok && hx711_tara_ok,
           (med.hx_ok && hx711_tara_ok) ? hx711_para_kg(med.hx_bruto) : NAN, "%.3f");
  return (size_t)snprintf(buf, n,
    "{\"t\":%s,\"ur\":%s,\"dht\":%u,\"lux\":%s,\"tc\":[%s,%s,%s],\"peso\":%s,\"up\":%lu}",
    t, ur, (unsigned)(med.dht.ok ? med.dht.tipo : 0), lux, tc[0], tc[1], tc[2], peso,
    (unsigned long)uptime_s());
}

/* ---- Comandos (BLE e serial usam o mesmo interpretador) ---- */

static void tr_iniciar(uint32_t desde) {
  const uint32_t antigo = reg_seq_antigo();
  tr_seq = desde < antigo ? antigo : desde;
  tr_fim = reg_cab.proximo_seq;
  if (tr_seq > tr_fim) tr_seq = tr_fim;
  tr_enviados = 0;
  tr_off = sizeof(Registro);
  ble_transferindo = true;
  carrossel_sujo = true;
  Serial.printf("BLE: enviando seq %lu..%lu\n", (unsigned long)tr_seq, (unsigned long)tr_fim);
}

static void exportar_serial() {
  Serial.println("seq;epoca;uptime_s;boot;t_amb;ur;lux;tc_fundo;tc_divisao;tc_melgueira;peso_kg;validos");
  Registro r;
  for (uint32_t s = reg_seq_antigo(); s < reg_cab.proximo_seq; ++s) {
    if (!reg_ler(s, &r)) continue;
    Serial.printf("%lu;%lu;%lu;%u;%.1f;%.1f;%u;%.2f;%.2f;%.2f;%.3f;%u\n",
      (unsigned long)r.seq, (unsigned long)r.epoca, (unsigned long)r.uptime_s, (unsigned)r.boot,
      r.t_amb_x10 / 10.0, r.ur_x10 / 10.0, (unsigned)r.lux, r.tc_x4[0] / 4.0, r.tc_x4[1] / 4.0,
      r.tc_x4[2] / 4.0, r.peso_g / 1000.0, (unsigned)r.validos);
    if ((s & 31) == 0) delay(1);
  }
  Serial.println("FIM");
}

static void executar_comando(char* cmd, bool pela_serial) {
  while (*cmd == ' ') ++cmd;
  char* arg = strchr(cmd, ' ');
  if (arg) { *arg++ = 0; while (*arg == ' ') ++arg; }
  for (char* p = cmd; *p; ++p) *p = (char)toupper((unsigned char)*p);

  if (!strcmp(cmd, "HORA") && arg) {
    const long long e = atoll(arg);
    if (e > 1600000000LL) {
      epoca_base = e - (int64_t)uptime_s();
      Serial.printf("RELOGIO: acertado para %lld\n", e);
    }
  } else if (!strcmp(cmd, "LER") && !pela_serial) {
    tr_iniciar(arg ? (uint32_t)strtoul(arg, nullptr, 10) : 0);
  } else if (!strcmp(cmd, "INTERVALO") && arg) {
    uint32_t s = (uint32_t)strtoul(arg, nullptr, 10);
    if (s >= 60 && s <= 3600) {
      reg_cab.intervalo_s = s;
      reg_gravar_cab();
      Serial.printf("REGISTRO: intervalo %lu s\n", (unsigned long)s);
    }
  } else if (!strcmp(cmd, "TARA")) {
    Serial.println(hx711_fazer_tara() ? "HX711: tara refeita" : "HX711: tara nao realizada");
    carrossel_sujo = true;
  } else if (!strcmp(cmd, "APAGAR")) {
    reg_cab.inicio = 0;
    reg_cab.quantidade = 0;
    reg_gravar_cab();
    Serial.println("REGISTRO: apagado (a sequencia continua)");
  } else if (!strcmp(cmd, "INFO") && pela_serial) {
    char buf[320];
    montar_info(buf, sizeof(buf));
    Serial.println(buf);
    montar_agora(buf, sizeof(buf));
    Serial.println(buf);
  } else if (!strcmp(cmd, "EXPORTAR") && pela_serial) {
    exportar_serial();
  }
}

/* ---- Bluetooth ---- */

class CbServidor : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*) override {
    ble_conectado = true;
    carrossel_sujo = true;
  }
  void onDisconnect(NimBLEServer*) override {
    ble_conectado = false;
    ble_transferindo = false;
    carrossel_sujo = true;
  }
};

class CbCaracteristica : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* c) override {
    char buf[320];
    const size_t n = (c == ch_info) ? montar_info(buf, sizeof(buf)) : montar_agora(buf, sizeof(buf));
    c->setValue((const uint8_t*)buf, n < sizeof(buf) ? n : sizeof(buf) - 1);
  }
  void onWrite(NimBLECharacteristic* c) override {
    if (cmd_ble_novo) return;  /* o anterior ainda nao foi tratado */
    NimBLEAttValue v = c->getValue();
    size_t n = v.length();
    if (n >= sizeof(cmd_ble)) n = sizeof(cmd_ble) - 1;
    memcpy(cmd_ble, v.data(), n);
    cmd_ble[n] = 0;
    cmd_ble_novo = true;
  }
};

static CbServidor cb_servidor;
static CbCaracteristica cb_caracteristica;

static void ble_iniciar() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  snprintf(ble_nome, sizeof(ble_nome), "BM-%02X%02X%02X", mac[3], mac[4], mac[5]);

  NimBLEDevice::init(ble_nome);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(247);
  ble_servidor = NimBLEDevice::createServer();
  ble_servidor->setCallbacks(&cb_servidor);

  NimBLEService* srv = ble_servidor->createService(BLE_SERVICO);
  ch_info = srv->createCharacteristic(BLE_INFO, NIMBLE_PROPERTY::READ);
  ch_agora = srv->createCharacteristic(BLE_AGORA, NIMBLE_PROPERTY::READ);
  NimBLECharacteristic* ch_cmd = srv->createCharacteristic(BLE_COMANDO, NIMBLE_PROPERTY::WRITE);
  ch_dados = srv->createCharacteristic(BLE_DADOS, NIMBLE_PROPERTY::NOTIFY);
  ch_info->setCallbacks(&cb_caracteristica);
  ch_agora->setCallbacks(&cb_caracteristica);
  ch_cmd->setCallbacks(&cb_caracteristica);
  srv->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData dados_adv, resposta;
  dados_adv.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  dados_adv.setName(ble_nome);
  resposta.setCompleteServices(NimBLEUUID(BLE_SERVICO));
  adv->setAdvertisementData(dados_adv);
  adv->setScanResponseData(resposta);
  adv->start();
  Serial.printf("BLE: anunciando como %s\n", ble_nome);
}

static uint16_t ble_carga_max() {
  if (!ble_servidor || ble_servidor->getConnectedCount() == 0) return 20;
  const uint16_t mtu = ble_servidor->getPeerInfo(0).getMTU();
  uint16_t carga = mtu > 3 ? mtu - 3 : 20;
  if (carga > 244) carga = 244;
  return carga < 20 ? 20 : carga;
}

/* Envia um pacote por chamada para nao segurar a tela. */
static void ble_enviar_pacote() {
  static uint8_t pac[245];
  const uint16_t carga = ble_carga_max();
  if (tr_seq >= tr_fim && tr_off >= sizeof(Registro)) {
    pac[0] = 'F';
    memcpy(pac + 1, &tr_enviados, 4);
    ch_dados->setValue(pac, 5);
    ch_dados->notify();
    ble_transferindo = false;
    carrossel_sujo = true;
    Serial.printf("BLE: %lu registros enviados\n", (unsigned long)tr_enviados);
    return;
  }
  uint16_t n = 1;
  pac[0] = 'D';
  while (n < carga) {
    if (tr_off >= sizeof(Registro)) {
      if (tr_seq >= tr_fim) break;
      if (!reg_ler(tr_seq, &tr_reg)) {   /* nao deveria acontecer: pula */
        ++tr_seq;
        continue;
      }
      ++tr_seq;
      ++tr_enviados;
      tr_off = 0;
    }
    uint16_t pedaco = (uint16_t)(sizeof(Registro) - tr_off);
    if (pedaco > carga - n) pedaco = carga - n;
    memcpy(pac + n, ((const uint8_t*)&tr_reg) + tr_off, pedaco);
    n += pedaco;
    tr_off += pedaco;
  }
  ch_dados->setValue(pac, n);
  ch_dados->notify();
}

static uint32_t tarefa_ble(uint32_t) {
  while (Serial.available()) {
    const char ch = (char)Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (cmd_serial_n) {
        cmd_serial[cmd_serial_n] = 0;
        executar_comando(cmd_serial, true);
        cmd_serial_n = 0;
      }
    } else if (cmd_serial_n < sizeof(cmd_serial) - 1) {
      cmd_serial[cmd_serial_n++] = ch;
    }
  }
  if (cmd_ble_novo) {
    char cmd[sizeof(cmd_ble)];
    memcpy(cmd, cmd_ble, sizeof(cmd));
    cmd_ble_novo = false;
    executar_comando(cmd, false);
  }
  if (ble_transferindo) {
    if (!ble_conectado) { ble_transferindo = false; return 50; }
    ble_enviar_pacote();
    return 12;
  }
  return 50;
}

static uint32_t tarefa_registro(uint32_t) {
  if (reg_acrescentar()) {
    Serial.printf("REGISTRO: seq %lu gravado\n", (unsigned long)(reg_cab.proximo_seq - 1));
  }
  return reg_cab.intervalo_s * 1000UL;
}

static const char* rodape_logos() {
  static char txt[40];
  if (ble_transferindo) return "ENVIANDO DADOS AO CELULAR";
  if (ble_conectado) return "CELULAR CONECTADO";
  snprintf(txt, sizeof(txt), "%s  |  AMAZONIA BEE  |  IPE", ble_nome);
  return txt;
}

static uint16_t rodape_cor() { return ble_conectado ? COR_IPE_VERDE : COR_MARCA_MARROM; }

/* ------------------------------------------------------------------------- */
/* 12. AGENDADOR COOPERATIVO                                                  */
/* Uma tarefa por volta do loop, na ordem da tabela: o carrossel, primeiro da */
/* lista, nunca espera mais que uma tarefa curta para ganhar a vez.           */
/* ------------------------------------------------------------------------- */

static Tarefa tarefas[] = {
  {tarefa_carrossel,  0,    0},
  {tarefa_hx711,      200,  0},
  {tarefa_termopares, 450,  0},
  {tarefa_lux,        700,  0},
  {tarefa_dht,        950,  0},
  {tarefa_ble,        1100, 0},
  {tarefa_registro,   60000, 0},  /* 1o registro 1 min apos a partida */
};

static void agendador_iniciar() {
  const uint32_t agora = millis();
  for (Tarefa& t : tarefas) t.proxima_ms = agora + t.atraso_inicial_ms;
}

static void agendador_executar() {
  const uint32_t agora = millis();
  for (Tarefa& t : tarefas) {
    if ((int32_t)(agora - t.proxima_ms) >= 0) {
      const uint32_t espera = t.executar(agora);
      /* Conta a partir do fim da tarefa: um quadro demorado nao deixa o
       * carrossel vencido de novo na volta seguinte e tomar a vez de todos. */
      t.proxima_ms = millis() + espera;
      return;
    }
  }
  delay(1);  /* nada vencido: cede a CPU ao FreeRTOS */
}

/* ------------------------------------------------------------------------- */
/* 13. SETUP E LOOP                                                           */
/* ------------------------------------------------------------------------- */

static void imprimir_pinagem() {
  Serial.println();
  Serial.println("=== BeeMeter " FW_VERSAO " | carrossel continuo | HW-657A ===");
  Serial.println("DHT22: DATA = D27 / GPIO27");
  Serial.println("BH1750: SDA = D21 / GPIO21  SCL = D22 / GPIO22");
  Serial.println("Tela: ST7789 240x135 (1,14\")  CS15 DC2 RST4 MOSI23 SCLK18 BL32");
  Serial.println("MAX6675 comum: SCK=D25/GPIO25  SO=D26/GPIO26");
  Serial.println("MAX6675 TC1: CS=D14/GPIO14");
  Serial.println("MAX6675 TC2: CS=D13/GPIO13");
  Serial.println("MAX6675 TC3: CS=TX2/GPIO17");
  Serial.println("Os tres MAX6675 compartilham SCK e SO; CS e separado");
  Serial.println("HX711: DT=D34/GPIO34  SCK=D19/GPIO19");
  Serial.printf("HX711: fator=%.3f contagens/kg; media de 5 leituras\n",
                (double)HX711_CONTAGENS_POR_KG);
}

void setup() {
  Serial.setTxBufferSize(1024);  /* prints nao seguram o carrossel */
  Serial.begin(115200);
  delay(300);
  const uint32_t inicio = millis();

  /* Display e abertura */
  pinMode(TFT_BL, OUTPUT);
  digitalWrite(TFT_BL, HIGH);
  SPI.begin(18, -1, 23, -1);  /* TFT sem MISO: GPIO19 fica exclusivo do HX711 */
  tft.init(TFT_PAINEL_W, TFT_PAINEL_H);
  tft.setSPISpeed(TFT_SPI_HZ);
  tft.setRotation(TFT_ROT);
  tft.invertDisplay(true);
  tft_limpar_memoria_toda();

  malha_preparar();
  imprimir_pinagem();
  if (quadro_alocar()) {
    Serial.printf("Tela: quadro %dx%d (%u bytes de heap)%s\n", TELA_W, quadro_h,
                  (unsigned)(TELA_W * quadro_h * 2),
                  quadro_h < TELA_H ? " -- enviado em faixas" : "");
  } else {
    Serial.println("ERRO: sem memoria para o quadro da tela");
  }
  abertura_etapa("firmware " FW_VERSAO "  |  HW-657A", 10);

  /* Sensores */
  dht11.begin();
  dht22.begin();

  pinMode(MAX6675_SCK, OUTPUT);
  digitalWrite(MAX6675_SCK, LOW);
  pinMode(MAX6675_SO, INPUT_PULLUP);
  pinMode(MAX6675_CS1, OUTPUT);
  pinMode(MAX6675_CS2, OUTPUT);
  pinMode(MAX6675_CS3, OUTPUT);
  digitalWrite(MAX6675_CS1, HIGH);
  digitalWrite(MAX6675_CS2, HIGH);
  digitalWrite(MAX6675_CS3, HIGH);
  abertura_etapa("DHT e termopares configurados", 25);
  delay(250);

  balanca.begin(HX711_DT, HX711_SCK);
  balanca.set_scale(HX711_CONTAGENS_POR_KG);
  balanca.power_up();

  /* 1a tentativa do DHT (DHT11). Se falhar, a 2a (DHT22) vem depois da tara,
   * que ja da os 2 s exigidos entre leituras -- sem custo no tempo de boot. */
  tarefa_dht(millis());
  const uint32_t dht_primeira_ms = millis();

  abertura_etapa("Tara: deixe a balanca sem peso", 40);
  Serial.println("HX711: fazendo tara; deixe a balanca sem peso");
  static char texto_etapa[40];
  if (hx711_fazer_tara()) {
    Serial.printf("HX711 tara RAW=%ld\n", balanca.get_offset());
    snprintf(texto_etapa, sizeof(texto_etapa), "HX711 tara RAW=%ld", balanca.get_offset());
  } else {
    Serial.println("HX711 tara nao realizada");
    snprintf(texto_etapa, sizeof(texto_etapa), "HX711: tara nao realizada");
  }
  abertura_etapa(texto_etapa, 70);

  Wire.begin(I2C_SDA, I2C_SCL, 100000UL);
  Wire.setTimeOut(50);
  escanear_i2c();
  if (bh1750_iniciar()) {
    Serial.printf("BH1750 OK no endereco 0x%02X\n", bh1750_addr);
    snprintf(texto_etapa, sizeof(texto_etapa), "BH1750 OK no endereco 0x%02X", bh1750_addr);
  } else {
    Serial.println("BH1750 nao encontrado em 0x23 nem 0x5C");
    snprintf(texto_etapa, sizeof(texto_etapa), "BH1750 nao encontrado");
  }
  abertura_etapa(texto_etapa, 85);

  /* Registro em memoria e Bluetooth */
  {
    Preferences pref;
    pref.begin("beemeter", false);
    boot_num = (uint16_t)(pref.getUShort("boot", 0) + 1);
    pref.putUShort("boot", boot_num);
    pref.end();
  }
  reg_ok = reg_iniciar();
  ble_iniciar();
  snprintf(texto_etapa, sizeof(texto_etapa), "%s  |  %lu registros", ble_nome,
           (unsigned long)reg_cab.quantidade);
  abertura_etapa(texto_etapa, 92);

  /* Primeira rodada de leituras: os paineis ja nascem com dados. */
  tarefa_termopares(millis());
  tarefa_lux(millis());
  if (!med.dht.ok) {
    while (millis() - dht_primeira_ms < 2200UL) delay(10);
    tarefa_dht(millis());
  }
  if (hx711_tara_ok && hx711_pronto()) tarefa_hx711(millis());
  abertura_etapa("Pronto", 100);

  while (millis() - inicio < SPLASH_MIN_MS) delay(10);

  /* Carrossel: comeca com o painel dos logotipos enquadrado, igual a abertura. */
  carrossel_t0 = millis();
  carrossel_pos = 0;
  carrossel_sujo = true;
  agendador_iniciar();
}

void loop() {
  agendador_executar();
}
