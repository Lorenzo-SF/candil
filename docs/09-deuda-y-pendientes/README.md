# 09 · Deuda, pendientes y lo que falta por probar

> **Lo que está sin terminar, lo que se sabe roto, y lo que no se ha podido
> verificar porque no había con qué — y que desde el 2026-10-12 sí se puede,
> porque hay una máquina con una RTX 5080 delante.**
>
> 2026-10-12 · `main` `5a28e71` (936 tests) · rama de trabajo
> `fase-4-politica-turno` (967 tests)

---

## 1 · Progreso real

| Fase | Qué | Estado |
|---|---|---|
| **0** | Probar lo que existe sin probar | ✅ `01-inventario/HALLAZGOS-FASE-0.md` |
| **1** | Los behaviours que faltaban | ✅ mergeada |
| **2** | `Arrea.Resource` (Arrea 4.0.0) | ✅ mergeada y publicada en Hex |
| **3** | **El enrutado: las capas `:embedding` y `:llm`** | ✅ mergeada |
| **4** | **La política: quién va primero** | 🟡 en PR #48, **verde, sin mergear** |
| **5** | El refusal, en los tres tipos | ⬜ **bloqueada por D-09** |
| 6-12 | RAG · MCP · Gateway · mesa camilla · agentes · stats · CLI | ⬜ |

**`main` hoy**: 936 tests + 27 doctests, 0 fallos, credo 0, dialyzer 0.
**Con la fase 4**: **967 tests + 27 doctests, 0 fallos**, los cinco gates en verde.

---

## 2 · Lo que NO se ha podido probar, y por qué

Todo lo de esta tabla se ha escrito y aprobado sin ejecutarse, porque el entorno
donde se escribió **no tenía GPU, ni modelos, ni `nvidia-smi`, ni `cmake`**.

### 2.1 · La cola con un destino REALMENTE exclusivo — **lo más importante**

**Lo que se ha probado**: la cola con modelos remotos falsos. Entran, esperan y
se sirven de uno en uno.

**Lo que no se ha probado**: qué pasa cuando el destino es **una GPU con un
modelo de verdad**. Porque un destino "exclusivo" de mentira no se parece a uno
real en tres cosas que importan aquí:

- **no tarda en arrancar** — una inferencia real dura segundos, no microsegundos;
- **no se puede tumbar a mitad** — y una GPU se puede tumbar;
- **no ocupa 16 GB** — y de eso trata `Arrea.Resource`.

| # | Qué mirar | Cómo se sabe que ha ido bien |
|---|---|---|
| **1.1** | **El turno dura lo que dura la inferencia** | `candil doctor` y el log de la cola: un turno real dura segundos. **Si sale 0 ms, el reloj no está midiendo y la política no sirve** |
| **1.2** | La segunda petición **espera de verdad** y sale cuando la primera suelta | dos peticiones a la vez al mismo alias local |
| **1.3** | Dos peticiones al **mismo** destino se serializan | y la segunda ve la GPU ocupada, no un error raro |
| **1.4** | Dos peticiones a **destinos distintos NO se estorban** | una en la GPU, otra a un proveedor remoto: la remota no espera |
| **1.5** | **Tumbar un motor con el turno tomado** deja el destino libre | `candil stop <modelo>` en mitad de una inferencia: la siguiente entra, no se queda colgada |

### 2.2 · Las capas del enrutado, con modelos de verdad

`scripts/router-layers-check.exs` tiene dos secciones. La **1** (mecanismo, con
un embedder y un clasificador falsos) corre en cualquier máquina. La **2**, que
es la medición, hay que rellenarla:

```elixir
defmodule Medir do
  @prompts [
    {"refactoriza este modulo de Elixir y dime por que esta roto", :coder},
    # las TUyas, con el modelo que TU quieres que gane en cada una
  ]
end
```

**Con un embedder de mentira el recuento no significa nada**, y el script lo dice
en su salida: `RECUENTO: 0/5`.

| # | Qué | Por qué importa |
|---|---|---|
| **2.1** | Qué fracción de prompts llega **al modelo que tú esperabas** | >90%: la capa sirve y lo que falta es bajar el umbral. <90%: **no cambies el umbral**, suele estar en las `description` de tus modelos |
| **2.2** | Qué **similitud** da cada pairing prompt↔modelo | la tabla que permite mover el umbral mirándola, no adivinando |
| **2.3** | El recuento de la **tribunal** (§3) | ver abajo |

### 2.3 · El hardware que Candil ve — **ya verificado, pero en un solo modelo**

`Candil.Detector.Devices` se probó en la RTX 5080 Laptop:

```
NVIDIA GeForce RTX 5080 Laptop GPU   total_mb: 16303   free_mb: 13271   usable: true
```

**Lo que no se ha probado**: nada más que una GPU. Con **dos** GPUs, con una
**ROCM/Intel Arc**, y con una máquina **sin GPU** (ahí solo se ha comprobado que
`detect/0` contesta `{:ok, %{backend: :cpu, devices: []}}`).

### 2.4 · La suite en una máquina que no tiene `zip`

12 tests de `Build.PrecompiledTest` llaman a `System.cmd("zip", ...)` y fallan
con `:enoent` en una máquina sin ese binario. **Un rojo que no habla de
Candil**, y por eso merece arreglo aparte: `sudo pacman -S zip` lo desbloquea,
pero el arreglo de fondo es que la suite no dependa de un binario del sistema.

### 2.5 · La ruta de librería

Sin `libcandil` de producción ni documentación de consumo. Es la **fase 10** del
plan, y sigue sin dueño.

---

## 3 · El tribunal: lo que decide si el LLM entra

`DISENO-MOTOR.md` §10 pone una condición antes de meter un modelo de lenguaje
como clasificador:

> Se mide **qué fracción de decisiones resolvió la política**. Si es el 97%, al
> LLM se le llama el 3% y es ruido caro. **Si es el 60%, el motor estático
> está mal hecho y hay que arreglarlo antes de meter un modelo.**

**Esa métrica no existe.** No hay telemetría de decisiones por capa, así que hoy
**no hay forma de saber** si el clasificador por LLM está justificado.

Es lo más pequeño que falta (un evento de telemetría en la decisión con la capa
que la produjo, y un contador) y decide lo más gordo que queda.

**Cuidado con una trampa que ya se ha pagado**: el evento existe, pero
**tomar el turno cuenta como turno servido y emite su propio evento**. Una
petición que espera son **tres** eventos, no dos: el de `run/3` que no espera, el
de `enter/2` que toma el turno, y el de la que espera de verdad. Un contador mal
pensado cuenta turnos donde cuentan peticiones.

---

## 4 · Deuda técnica

| # | Qué | Dónde | Coste |
|---|---|---|---|
| **T-1** | **12 tests dependen del binario `zip`** | `test/candil/build/precompiled_test.exs` | fallan en máquinas sin `zip`, y el rojo no habla de Candil |
| **T-2** | **4 tests de cmake solo existen si hay `cmake`** | `test/candil/build/source_real_test.exs` | sin cmake la suite corre **878 en vez de 882** y **no son las mismas pruebas** |
| **T-3** | **`charlist` deprecado en el lexer de `toml`** | dependencia, `lib/decoder.ex` | ruido en cada compilación; no es nuestro |
| **T-4** | **`.credo.exs` nombra un check inexistente** | `.credo.exs` | `NestedModules` no existe en Credo 1.7.19; lo ignora y avisa en cada ejecución |
| **T-5** | **17 ramas sin mergear**, de las que 4 son de la era `proyecto 4.0/` | GitHub | no se han revisado una a una; **no se borran sin mirarlas** |
| **T-6** | **El `SLOT` de `candil status` es teatro**: `if rem(port, 100) >= 90, do: "dGPU"` | `lib/candil/cli/lifecycle.ex` | una columna que **miente** sobre el hardware. Deuda del trabajo local aparcado |
| **T-7** | **No hay telemetría de decisiones del router** | — | bloquea al LLM y al `candil stats` (§3) |
| **T-8** | **3 PR de dependabot abiertos** | #41, #42, #43 | solo CI; se pueden mergear o cerrar |

### Sobre T-5, y por qué no se han borrado

A diferencia de Arrea —donde las ramas eran **más antiguas** que `main` y se
verificó fichero a fichero que no apportaban nada—, aquí las ramas traen **más
líneas que `main`**, porque son de la estructura vieja `proyecto 4.0/`. **Que
traigan más contenido no significa que apporten nada**: significa que `main`
restructuró. Borrarlas sin mirar el contenido sería exactamente el error del
`git add -A` de esta semana.

---

## 5 · Problemas sin resolver

| # | Problema | Por qué sigue abierto |
|---|---|---|
| **P-1** | El defecto del refusal | es decisión del dueño (D-09) y **bloquea la fase 5** |
| **P-2** | La métrica del tribunal | no existe la instrumentación (§3) |
| **P-3** | `rest_for_one` sin implementar | **a propósito**: no tiene caso hasta que exista un destino que ceda el turno (D-02) |
| **P-4** | Quién escribe la verdad de la VRAM | se **lee**, no se escribe. Sin dueño |
| **P-5** | La fase 4 sin mergear | en PR #48, verde, esperando la medición de §2.1 |
| **P-6** | La colocación de modelos en varias GPUs | es la parte de la 8b que falta, y **depende de P-4** |

---

## 6 · El resumen, en una frase

> Hay **967 tests en verde** y **cinco preguntas sin responder**.
> Las cinco necesitan una máquina con GPU, un modelo cargado y respuestas
> reales — y por eso están escritas una a una, con lo que habría que mirar.
