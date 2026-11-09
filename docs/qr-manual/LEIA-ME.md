# QR code do Manual do Monitor Meliponas — 95 × 65 mm

O código abre o manual em PDF: `https://andersonsakuma.github.io/monitor-meliponas/manual.pdf`
(o arquivo publicado é `painel/manual.pdf`; ao atualizar o manual, o mesmo QR continua valendo).

| Arquivo | Uso |
| --- | --- |
| `QR_Manual_Meliponas_95x65.pdf` | Página 1: etiqueta em tamanho real, 65 × 95 mm. Página 2: folha A4 com 6 etiquetas e marcas de corte (imprimir em 100 %, sem ajustar à página). |
| `QR_Manual_Meliponas_95x65_completo.stl` | Placa inteira numa peça só (base + relevo), para impressão com troca de filamento. |
| `QR_Manual_Meliponas_95x65_base.stl` e `..._relevo.stl` | As duas partes separadas, para impressora com duas cores (mesmas coordenadas). |
| `vista_superior_95x65.png` | Vista de cima do relevo, usada para conferir a leitura do código. |

## Placa para impressora 3D

- Tamanho: **95 mm de comprimento × 65 mm de largura**, base de 2,0 mm e relevo de 1,2 mm (altura total 3,2 mm).
- QR code com módulos de 1,51 mm e margem clara de 4 módulos, moldura e o texto "MANUAL MELIPONAS · Dúvidas: (41) 99193-2677".
- Relevo **escuro** e base **clara**.

### Impressão com troca de filamento

1. Abra `QR_Manual_Meliponas_95x65_completo.stl` no fatiador.
2. PLA, camada de 0,2 mm, bico de 0,4 mm, preenchimento de 20 %.
3. **Pausa ou troca de filamento na altura de 2,0 mm**: base em filamento claro, relevo em escuro.

### Impressão em duas cores

Importe a base e o relevo juntos como uma peça de várias partes, sem mover, com filamento claro na base e escuro no relevo.

Teste com a câmera do celular a cerca de 15 cm. Para uso ao ar livre, prefira PETG ou ASA.

Dúvidas: Anderson Sakuma (IPÊ/FIS) · (41) 99193-2677 · anderson.sakuma.tecpar@gmail.com
