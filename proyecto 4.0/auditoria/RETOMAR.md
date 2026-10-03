# Candil 4.0 — cómo retomar

> **Documento de entrada para una sesión nueva.** Autosuficiente: no necesita
> leer nada más para saber qué hacer en los primeros 30 minutos.
>
> Premisa: *en la sesión principal se ha trabajado hasta la fase 5*.
> **Lo que hay que hacer NO es reimplementar, sino medir y continuar.**

---

## 0. La respuesta corta

**¿Ha cambiado el objetivo de alguna fase? No.**

Las enmiendas v4.1 son **aditivas**, y solo dos tocan fases ya cerradas:

| Enmienda | Fase | ¿Toca trabajo ya hecho? |
|---|---|---|
| D1 `quality_class` | 7 | no |
| D4 política de contexto | 6 | no |
| D5 `reasoning_effort` | 8 | no |
| D6 señal del router | 7 | no |
| D8 `Conversation` | 6 | no |
| D9 checks del doctor | 5, 6, 7, 8, 10 | no — en la F5 es el doctor que ya existe |
| D10 issue de botica | 11 | no |
| **D2** `EnginePool` interno | **4** | sí → **verificar**, 1 h |
| **D3** launcher del engine | **2** | sí → **verificar**, 30 min |
| **D7** paridad con ropero | **2**, 11 | sí → **verificar**, medio día |

**Lo que significa, en una frase:** las fases 2 a 5 tienen el mismo objetivo que
tenían, más una comprobación pendiente cada una. **Todo el trabajo nuevo vive de
la F6 en adelante**, que es justo donde aún no has llegado.

**Y de aquí sale la regla de esta sesión: no reimplementas nada. Mides, y
continúas.**

---

## 1. Lo primero: mide, no supongas

⚠ **Los números de los documentos están desactualizados a propósito.** Dijimos
"623 tests", luego "702", luego "687", y ninguno era el número real del momento en
que se leía. Un documento que miente es peor que uno que no existe.

**El primer trabajo de la sesión nueva es establecer el estado real. Nada de
implementar antes.**

### 1.1 El sondeo de 5 minutos

```bash
cd ~/cacafuti/candil      # o donde esté

# ¿en qué rama y con qué commit?
git status -sb
git log --oneline -20

# ¿qué fases tienen ya tag?  ← la señal más rápida de todas
git tag | grep -E 'candil' | sort -V

# ¿qué hay en el árbol?
git diff main --stat
```

**`git tag` es el mapa de fases.** Los tags son el único indicador fiable de qué
se ha cerrado, porque se ponen al mergear y no se pueden poner por descuido.

### 1.2 El estado de salud

```bash
CANDIL_DATA_DIR=$(mktemp -d) mix deps.get
CANDIL_DATA_DIR=$(mktemp -d) mix test --cover 2>&1 | tail -20
mix credo --strict --format=oneline
mix dialyzer 2>&1 | tail -5
```

Apunta **tres números**, textuales: tests, fallos, cobertura.

⚠ Si aparece `unknown_function` de apero/arrea/trebejo, **mira el PLT antes que
el código**. Ya mordió una vez: el PLT solo tenía OTP y Candil, y 15 llamadas nunca
se comprobaron.

---

## 2. El veredicto, fase por fase

Rellena esta tabla **con la salida real de los comandos**, no de memoria. La
columna de la derecha es la que decide qué haces después.

| Fase | Cómo se comprueba | Sin modelos | Veredicto |
|---|---|---|---|
| **F2** Build | `mix test test/candil/build/ test/candil/source_test.exs`<br>`git tag \| grep 3.3.0` | ✅ | ✅ hecha y medida · `3 doctests, 59 tests, 0 failures` |
| **F3** CLI | `mix escript.build && ./candil --help`<br>`git tag \| grep alpha.1` | ✅ | ✅ hecha y medida · `--help` lista 7 comandos · `version` = 4.0.0 |
| **F4** Instancias | `mix test test/candil/instances_test.exs`<br>`./candil status` | ⚠️ parcial | ✅ hecha y medida · `15 tests, 0 failures` · criterio L4 **no ejecutado**: sin modelo |
| **F5** Doctor | `mix test test/candil/doctor_test.exs`<br>`./candil doctor` | ✅ | ✅ hecha y medida · `17 tests, 0 failures` · `0 errores · 5 advertencias` |
| **F6** Context | `mix test test/candil/context_test.exs test/candil/context_builder_test.exs` | ✅ | 🟡 parcial · 33 tests verdes; falta `chat_with_context/4`, la causa en el `reason` del Builder, y D4 y D8 |
| **F7** Router | `mix test test/candil/router_test.exs` | ✅ | 🟡 parcial · `26 tests, 0 failures` · la clave de caché **sí** incluye el consumer |
| **F8** Gateway | `mix test test/candil/gateway_test.exs` | ✅ | 🟡 parcial · `22 tests, 0 failures` · `Endpoint.listen/4` sigue stub (es la fase 8) |
| **F9** MCP | `mix test test/candil/mcp_protocol_test.exs` | ✅ | 🔴 **bloqueada por A1** · 22 tests verdes contra `2025-11-25` (Legacy) |
| **F10** RAG | `mix test test/candil/rag_test.exs` | ✅ | 🔴 **bloqueada por A2** · 16 tests verdes, las 5 funciones públicas son stub |
| **F11** Cierre | `./candil doctor` + tag `4.0.0` | ✅ | 🔴 no empezada · **no existe el tag `4.0.0`** |

**Sobre la columna "sin modelos":** algunas cosas no se pueden comprobar sin los
17 GB de GGUF. `./candil run coder --detach` con un `STATE` en `ON` es el criterio
de la F4 y **no se puede ejecutar en un sandbox sin GPU**. Eso no significa que la
fase esté mal: significa que el veredicto es *"verificada en todo lo verificable"*, y
se anota como tal. **Escribir un veredicto que no has medido es el único error
irrecuperable de esta fase.**

### 2.1 Los tres veredictos que importan

| Veredicto | Qué significa | Qué haces |
|---|---|---|
| **✅ Hecha y medida** | el criterio pasa y lo has ejecutado | no la toques. Sal a la siguiente |
| **🟡 Parcial** | compila, algo pasa, falta parte | **lee el README de la fase**, que tiene la lista de lo que falta con su nivel |
| **🔴 No empezada** | no hay ficheros, o son stubs | empieza por su §3, en orden |

**⚠ El caso `🟡` es el que más engaña.** "Compila y los tests pasan" no es "está
hecha": la F5 tenía los siete checks funcionando y **cero tests**, y eso no se ve
hasta que miras `test/candil/doctor_test.exs`.

---

## 3. Las dos verificaciones que sí adds trabajo

Solo si la F2 y la F4 dan 🟡 o ✅ con margen. **No son obligatorias para
continuar** — son deudas que se pueden pagar al final.

### 3.1 D3 · El launcher vive en el Engine — 30 min, `high`

```bash
grep -n "launcher" lib/candil/model.ex
grep -rn "launcher" priv/ 2>/dev/null
```

**Lo que tiene que pasar:** `Model.validate/1` para `:external` exige `engine` +
`base_url`, y **no** `launcher`. El launcher se lee del engine.

**Cómo se verifica que está mal:** dos modelos con el mismo `engine` declaran
`launcher` distinto, o el TOML del Apéndice A lo pone en los dos sitios.

### 3.2 D7 · La paridad con ropero, como test — medio día, `high`

**Solo si tienes ropero corriendo y 5 minutos.** La versión completa (bajar el
Apéndice A a `priv/ropero_argv.json` y escribir el test) es media jornada y puede
esperar a la F11, donde además sirve de criterio de cierre.

El sondeo rápido es este, y vale por sí solo:

```bash
# con ropero parado, y candil gestionando el mismo modelo
./candil run coder --detach && sleep 40
pgrep -a llama-server | grep -- --model
```

**Lo que tiene que pasar:** la línea coincide con la de `ropero coder`, salvo en
`--host`, `--port`, `--alias` y `--api-key` (los pone el engine).

**Si no coincide, la diferencia va al TOML, no al código.**

---

## 4. Por dónde se continúa

El orden es **riesgo primero**, y la razón es el calendario: el riesgo del plan
está en F6, F7, F9 y F10, y con el orden viejo del gantt se llegaba a la F7 —la
única fase con `max` de base y decisiones sin escribir— en el día 23 de 41.

```
F6 → F7 → F8 → F9 → F10 → F11
```

**Con dos desviaciones respecto a la secuencia del documento de diseño:**

1. **F3 y F4 ya están hechas** (por lo que el sondeo dirá). No se repiten.
2. **F9 y F10 arrancan con la puerta de decisiones cerrada** (§6).

### 4.1 Por fase, en orden

| Orden | Fase | Empieza por | Nivel |
|---|---|---|---|
| 1 | **F6** Context | §3.1 particionar por consumer | `max` |
| 2 | **F7** Router | §3.1 `pin/2` | `max` |
| 3 | **F8** Gateway | §3.4 auth + model de la red | `max` |
| 4 | **F9** MCP | **la puerta** (§6), luego §3.1 | `max` |
| 5 | **F10** RAG | **la puerta** (§6), luego §3.2 chunker | `max` |
| 6 | **F11** Cierre | §3.1 borrar `LLM.Ropero` | `max` |

**Las cinco empiezan en `max` o en el bloqueo que las precede.** No es casualidad:
son las fases con decisiones que el documento no contiene, y una sub-tarea que
empieza en `max` y no cabe en media hora **es una fase, no una sub-tarea**.

### 4.2 El ciclo, en cada una

```bash
git checkout main && git fetch origin && git pull --ff-only origin main
git checkout -b f6-context
# … implementar la fase COMPLETA, sub-tarea por sub-tarea …
git push -u origin f6-context
# PR contra main, mirar el CI, merge, cerrar el ciclo
```

El detalle completo está en `PLAN-EJECUCION.md` y en la sección **"Cómo se ejecuta
esta fase"** de cada README de fase. No lo repito aquí.

---

## 5. Lo que la F5 te deja en concreto

Si el sondeo dice que la F5 está **completa**, mira solo estas tres cosas, porque
son las que el README señalaba como pendientes y las únicas que no se ven
compilando:

- [ ] `test/candil/doctor_test.exs` **existe y tiene los ocho casos**. Cero tests
      era el hueco real de esa fase.
- [ ] `--fix` **arregla de verdad** los tres directorios. Antes solo creaba el de
      datos, que es un placeholder honesto pero poco.
- [ ] `Cost` está en fichero de datos y el moduledoc de `Application` dice
      `arrea 3.0.0` y no `2.1.0`.

Y una cuarta, que es la que hace que un doctor sirva:

- [ ] `./candil doctor` da **0 errores** y cada warning **nombra el comando** que
      lo arregla. Un check que sabe qué está mal y no dice cómo arreglarlo es la
      mitad del trabajo.

---

## 6. La puerta de decisiones, antes de F9 y F10

**No arranques estas dos fases con la decisión abierta.** Un agente que empieza
sin ella la toma por su cuenta, y es un día de trabajo tirado.

| | Decisión | Por qué bloquea |
|---|---|---|
| **F9** | ¿`2026-07-28` (Current) o `2025-11-25` (Legacy)? | En `2026-07-28` **no hay handshake `initialize`**: hay `server/discover` y la versión va en `_meta`. Es un día de diferencia de trabajo |
| **F10** | ¿el diseño del README (SQLite FTS5 + chunking por función) o el del plan (memoria + chunker configurable)? | Ocho divergencias. Los dos documentos vivos producen dos RAG distintos |

Caben en **una mañana**. Se anotan en `HANDOFF.md` con un párrafo cada una, y los
carriles arrancan.

**Lo que sí puedes hacer mientras tanto:** F6, F7 y F8 no dependen de ninguna de las
dos.

---

## 7. Las reglas de esta sesión, en seis líneas

1. **Mide antes de tocar.** El primer trabajo de la sesión es el sondeo de §1.
2. **Una fase por sesión.** La fase se implementa **completa**, no por partes.
3. **El nivel se cambia por sub-tarea** con `/model`. No lo dejes sin fijar: omitirlo
   es `max`, que es lo más caro.
4. **El presupuesto alto va a la verificación, no a la implementación.**
5. **Si la decisión no está escrita, PARA y pregunta.** No la tomes.
6. **Si un criterio no se ejecutó porque el entorno no lo permite, dilo.** En el
   `deliverable.md`, con la frase exacta. Un "criterio ejecutado" a medias es una
   mentira que la siguiente sesión da por buena.

---

## 8. Lo que esta sesión NO hace

- **No reimplementa la F2 a la F5.** Se miden, y si dan 🟡 se terminan con su README
  como guía.
- **No rehace el diseño.** El original está cerrado, y las enmiendas v4.1 son
  adiciones, no sustituciones.
- **No automatiza la verificación.** La capa L4 sigue siendo alguien mirando una
  salida. Lo que hay es un contrato de qué mirar.
- **No toca ropero.** Ni un byte, en ninguna fase.
