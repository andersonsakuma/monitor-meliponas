# QR code do Manual do Monitor Meliponas

O código abre o manual em PDF: `https://andersonsakuma.github.io/monitor-meliponas/manual.pdf`
(o arquivo publicado é `painel/manual.pdf`; ao atualizar o manual, o mesmo QR continua valendo).

| Arquivo | Uso |
| --- | --- |
| `QR_Manual_Meliponas.pdf` | Página 1: cartaz A4 com o QR grande e o contato. Página 2: seis etiquetas para recortar. |
| `QR_Manual_Meliponas_completo.stl` | Placa inteira numa peça só (base + relevo), para impressão com troca de filamento. |
| `QR_Manual_Meliponas_base.stl` e `QR_Manual_Meliponas_relevo.stl` | As duas partes separadas, para impressora com duas cores (atribua uma cor a cada arquivo, nas mesmas coordenadas). |
| `vista_superior.png` | Vista de cima do relevo, usada para conferir que o código lê corretamente. |

## Placa para impressora 3D

- Tamanho: **94,2 × 111,2 mm**. Base de 2,0 mm e relevo de 1,2 mm (altura total 3,2 mm).
- Módulos do QR de 1,8 mm, com margem clara de 4 módulos, moldura e o texto "MANUAL MELIPONAS · Dúvidas: (41) 99193-2677".
- O relevo deve ficar **escuro** e a base **clara** (por exemplo, base branca e relevo preto ou marrom).

### Impressão com troca de filamento (uma cor por vez)

1. Abra `QR_Manual_Meliponas_completo.stl` no fatiador (Cura, PrusaSlicer, Bambu Studio).
2. Material PLA, camada de 0,2 mm, bico de 0,4 mm, preenchimento de 20 % (as faces de cima ficam cheias).
3. Coloque uma **pausa ou troca de filamento na altura de 2,0 mm** (início da 11ª camada com camada de 0,2 mm).
4. Imprima a base em filamento claro; na pausa, troque para o escuro e continue.

### Impressão em duas cores

Importe `QR_Manual_Meliponas_base.stl` e `QR_Manual_Meliponas_relevo.stl` juntos como uma peça de várias partes, sem mover, e atribua filamento claro à base e escuro ao relevo.

### Depois de imprimir

Teste com a câmera do celular a cerca de 20 cm. Para uso ao ar livre, prefira PETG ou ASA e afixe com parafuso ou fita dupla-face de uso externo.

Dúvidas: Anderson Sakuma (IPÊ/FIS) · (41) 99193-2677 · anderson.sakuma.tecpar@gmail.com
