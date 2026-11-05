"""Exercita as funcoes reais da pesagem com ADC controlado. Rodar no WSL: python3 verificar_hx711.py."""
from pathlib import Path
import re
import subprocess
import tempfile

base = Path(__file__).resolve().parent
source = (base / "esp_tela_sakuma.ino").read_text(encoding="utf-8")
constants = "\n".join(re.findall(
    r"^#define (?:HX711_\w+|PERIODO_HX711_MS)\b[^\n]*", source, re.MULTILINE))
ready = re.search(r"static inline bool hx711_pronto\(\) \{[^\n]*\}", source).group()
functions = "\n".join(re.search(
    rf"static (?:bool|float|uint32_t) {name}\([^)]*\) \{{.*?^\}}", source,
    re.MULTILINE | re.DOTALL).group() for name in (
        "hx711_bruto_utilizavel", "hx711_ler_quadro", "hx711_ler_bloqueante",
        "hx711_fazer_tara", "hx711_para_kg", "tarefa_hx711"))
program = r'''
#include <cstdint>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include <initializer_list>
''' + constants + r'''
#define LOW 0
#define HIGH 1
static std::vector<int32_t> entrada;
static size_t indice = 0;
static uint32_t tempo_ms = 0;
static int linha = HIGH;
static uint32_t millis() { return tempo_ms; }
static void delay(unsigned ms) { tempo_ms += ms; }
static int digitalRead(int) { return linha; }
// Somente a fronteira ADC e controlada; tara, media, conversao e tarefa sao reais.
class HX711 {
  long offset = 0;
  float escala = 1;
  bool dormindo = false;
public:
  bool is_ready() { return !dormindo && indice < entrada.size(); }
  long read() { assert(is_ready()); return entrada[indice++]; }
  void set_scale(float v) { escala = v; }
  float get_scale() { return escala; }
  void set_offset(long v) { offset = v; }
  long get_offset() { return offset; }
  void power_up() { dormindo = false; }
  void power_down() { dormindo = true; }
};
struct {
  void println(const char* s) { std::puts(s); }
  template<class... Args> void printf(const char* f, Args... a) { std::printf(f, a...); }
} Serial;
static HX711 balanca;
static bool hx711_tara_ok = false, carrossel_sujo = false;
static struct { int32_t hx_bruto = 0; bool hx_ok = false; } med;
''' + ready + "\n" + functions + r'''
static void fornecer(std::initializer_list<int32_t> valores, int nivel = HIGH) {
  entrada = valores;
  indice = 0;
  linha = nivel;
}
static void peso(int32_t bruto, float esperado) {
  for (unsigned i = 0; i < 5; ++i) {
    fornecer({bruto});
    const uint32_t antes = millis();
    const uint32_t espera = tarefa_hx711(antes);
    assert(millis() == antes);  // nao espera a proxima conversao dentro da tarefa
    assert(espera == (i < 4 ? HX711_ESPERA_MS : PERIODO_HX711_MS));
    delay(espera);
  }
  assert(med.hx_ok && med.hx_bruto == bruto);
  assert(std::fabs(hx711_para_kg(med.hx_bruto) - esperado) < 0.00003f);
}
int main() {
  balanca.set_scale(HX711_CONTAGENS_POR_KG);
  fornecer({1000,1000,1000,1000,1000,1000,1000,1000,1000,1100});
  assert(hx711_fazer_tara() && balanca.get_offset() == 1010); // media, nao mediana
  peso(1010, 0.0f);
  peso(-41188, 1.0f);
  peso(-842957, 20.0f);
  peso(43208, -1.0f);
  peso(588, 0.01f);  // nao apaga pesos abaixo de 30 g

  // Media de cinco com truncamento inteiro igual ao read_average da biblioteca.
  for (int32_t raw : {-41188,-41189,-41190,-41191,-41200}) {
    fornecer({raw});
    tarefa_hx711(millis());
  }
  assert(med.hx_ok && med.hx_bruto == -41191);

  // Uma perda de sinal descarta o lote incompleto, nao mistura pesos antigos.
  fornecer({100000}); tarefa_hx711(millis());
  fornecer({100000}); tarefa_hx711(millis());
  fornecer({});
  for (unsigned i = 0; i < HX711_ESPERAS_MAX; ++i) {
    const uint32_t antes = millis();
    const uint32_t espera = tarefa_hx711(antes);
    assert(millis() == antes);
    delay(espera);
  }
  assert(!med.hx_ok);
  peso(-41188, 1.0f);

  // RAW zero e proximos de zero sao validos; saturacao e DOUT preso nao sao.
  balanca.power_up();
  for (int32_t raw : {0,-1,500,-500,524287,-524288}) {
    fornecer({raw});
    int32_t lido = 0;
    assert(hx711_ler_bloqueante(&lido, 3) && lido == raw);
  }
  int32_t lido = 0;
  for (int32_t raw : {0x7FFFFF,-0x800000}) {
    fornecer({raw}); assert(!hx711_ler_bloqueante(&lido, 3));
  }
  fornecer({0}, LOW); assert(!hx711_ler_bloqueante(&lido, 3));
  fornecer({});
  const uint32_t antes = millis();
  assert(!hx711_ler_bloqueante(&lido, 3) && millis() - antes > 3);

  fornecer({1000,1000,1000,1000,1000,1000,1000,1000,1000,31001});
  assert(!hx711_fazer_tara());  // plataforma instavel nao vira referencia valida
  assert(tarefa_hx711(millis()) == PERIODO_HX711_MS && !med.hx_ok);
  fornecer({});
  const uint32_t inicio = millis();
  assert(!hx711_fazer_tara() && millis() - inicio < 13000);
  std::puts("HX711_OK: tara, kg assinados, media de 5, coleta incremental e falhas");
}
'''
with tempfile.TemporaryDirectory(prefix=".hx711_check_", dir=base) as work:
    cpp = Path(work) / "check.cpp"
    exe = Path(work) / "check"
    cpp.write_text(program, encoding="utf-8")
    subprocess.run(["g++", "-std=c++17", "-O2", str(cpp), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
