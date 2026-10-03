# Candil 4.0 — cierre hasta F5 · entregable

> **Rama**: `f5-cierre` (desde `main` @ `7fc0920`) · **PR**: [#30](https://github.com/Lorenzo-SF/candil/pull/30)
> **Fecha**: 2026-10-03
> **Toolchain**: OTP 28.5.0.7 · Elixir 1.19.5-otp-28
>
> Alcance: terminar lo que faltaba o estaba mal **hasta la fase 5 incluida**, para
> que la F6 se pueda retomar. La primera pasada de esta sesión fue de medición
> pura; esto es lo que se ha hecho después con lo que salió.

---

## 1. Los números, antes y después

| | Antes (`7fc0920`, `main`) | Después (`f5-cierre`) |
|---|---|---|
| Tests | 701 + 26 doctests | **705 + 26 doctests** |
| Fallos | **1** | **0** |
| Cobertura | 66.1 % | **66.3 %** |
| Gates | 7 de 8 | **8 de 8** |

El número **subió** y el rojo **desapareció**. Ningún test se borró, se saltó ni se
debilitó para getting un gate en verde; dos se **corrigieron** porque congelaban un
contrato que contradecía a otro más fuerte del mismo fichero (§3).

⚠ **La cobertura se mueve entre ejecuciones de la misma suite**: 66.0 → 66.1 antes
de tocar nada, 66.2 → 66.3 después. Cuatro cifras, cuatro ejecuciones. No lo he
investigado y **no lo maquillo**: es información, y alguien debería mirar por qué
`mix test --cover` no es determinista aquí.

---

## 2. Lo que estaba roto, y estaba declarado cerrado

### 2.1 B6 · `Detector.safe_arch/0` — el único test rojo

`HANDOFF.md` §3-quater declaraba `B6 ✅ … el motivo viaja en :arch_error`. No viajaba.

```elixir
# lib/candil/detector.ex, antes
def safe_arch do
  if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
    {:ok, Trebejo.OS.arch()}      # <-- :unknown envuelto en un ÉXITO
  else
    {:error, :trebejo_not_available}
  end
end
```

Cadena de causa, medida:

1. `Trebejo.OS.arch/0` tiene `@spec arch() :: :x86_64 | :arm64 | :arm | :i386 | :unknown`
   y devuelve un **átomo desnudo**. `:unknown` es un valor *de ese tipo*, no una
   excepción: es lo que devuelve cuando no puede leer la arquitectura.
2. El guard solo comprobaba "el módulo está cargado", así que envolvía `:unknown`
   en `{:ok, :unknown}`.
3. `arch/0` mapea `{:ok, arch} -> {arch, nil}`: **`arch_error` quedaba en `nil`**,
   no se logueaba nada, y la descarga precompilada fallaba después sin decir por qué.

**Arreglado**: `:unknown` es ahora el error que parece, y `detect/0` lleva
`:trebejo_not_available` en `:arch_error` y lo loguea.

```
$ mix test test/candil/detector_test.exs
14 tests, 0 failures
```

### 2.2 D3 · un campo que nada leía y que no se podía rellenar

`RETOMAR.md` §3.1 sospechaba que el launcher estaba duplicado. Lo estaba, y era
peor de lo sospechado: **el tipo `:external` era imposible de declarar.**

| Comprobación | Resultado |
|---|---|
| ¿`Config.Schema` valida una clave `launcher`? | **no** (`grep` → 0) |
| ¿`Config.Hydrate` lee un `launcher`? | **no** (`grep` → 0) |
| ¿Quién **lee** `launcher`? | solo `Engine.launch/3`, desde `engine.launcher` |
| ¿`Model.validate/1` lo **exigía**? | **sí**, para `:external` |

Un modelo externo en un TOML no podía satisfacer un requisito que **no había
manera de cumprir**: no hay clave que lo fije y la validación lo exige. Un
deadlock con forma de campo.

**Arreglado** (`RETOMAR.md` §3.1, textual): `:external` exige ahora `engine` +
`base_url`, y nada exige `launcher`. `Model` ya no tiene el campo.

```
$ mix test test/candil/model_v4_test.exs test/candil/model_test.exs
21 tests, 0 failures
```

> El comentario del propio código, tres líneas más arriba del bug, ya decía la
> verdad: *"it needs a URL and nothing else"*.

### 2.3 F5 §3.2 · `--fix` honraba la mitad de las rutas configurables

`general.log_dir` lo validaba el schema, lo declaraba el TOML de ejemplo y **no lo
leía nadie**. `--fix` creaba `<data_dir>/logs` y **anunciaba ese camino**, así que
el fichero y el comportamiento discrepaban y el usuario se fiaba del fichero.

**Arreglado**: nuevo `Candil.Instances.log_dir/0` (resuelve el `log_dir`
configurado, cae a `<data_dir>/logs`), y el informe nombra los directorios que ha
creado de verdad.

```
$ mix test test/candil/doctor_test.exs
17 tests, 0 failures      (eran 15; +2 nuevos)
```

### 2.4 La documentación: 6 criterios que no se ejecutaban

Cinco de los diez criterios de aceptación de `RETOMAR.md` §2 apuntaban a
`test/candil/<fase>/`, y **ningún directorio de ese nombre existe**: los tests
son planos.

```
$ mix test test/candil/context/
Paths given to "mix test" did not match any directory/file: test/candil/context/
```

21 líneas corregidas en 6 ficheros, y **los seis paths nuevos se ejecutaron antes
de escribirlos**:

| Criterio documentado | Antes | Ahora (verificado) |
|---|---|---|
| F4 | `test/candil/instances*` | `15 tests, 0 failures` |
| F6 | `test/candil/context/` | `4 doctests, 33 tests, 0 failures` |
| F7 | `test/candil/router/` | `26 tests, 0 failures` |
| F8 | `test/candil/gateway/` | `1 doctest, 22 tests, 0 failures` |
| F9 | `test/candil/mcp/` | `5 doctests, 22 tests, 0 failures` |
| F10 | `test/candil/rag/` | `7 doctests, 16 tests, 0 failures` |

**Y la columna "Veredicto" de `RETOMAR.md` §2, que era el mandato literal del
prompt de arranque, estaba vacía. Rellena** con los veredictos reales.

### 2.5 La base de tests, que era decorativa

Decía 702, luego 687 + 26, luego 623 + 25. **Ninguna era cierta.** Un gate de
"si baja de X, para" contra un número inventado hace que el agente haga lo que sea
para llegar a X. Los cinco README de fase dicen ahora la base medida
(**705 + 26**) y, sobre todo, que **hay que volver a medirla al abrir la rama**.

### 2.6 La documentación, dentro del repo

El juego de documentos auditados **solo existía dentro de un ZIP de entrega**, que
es exactamente por qué las cifras derivaban: nadie lo tenía delante al trabajar.
Ahora está en `proyecto 4.0/auditoria/`, con su `README.md` explicando la relación
con `proyecto 4.0/fases/` (que se queda quieto a propósito: es el registro de lo
que había cuando se escribió cada fase).

---

## 3. Los ocho gates, con su salida real

```
$ mix format --check-formatted                              rc=0
$ mix compile --force --warnings-as-errors                  rc=0   (0 warnings)
$ mix credo --strict --format=oneline                       rc=0   (0 líneas)
$ mix test --cover                    26 doctests, 705 tests, 0 failures   rc=0
                                               [TOTAL]  66.3%
$ mix dialyzer   Total errors: 0, Skipped: 0, Unnecessary Skips: 0
                done (passed successfully)                            rc=0
$ mix docs --warnings-as-errors                               rc=0
$ mix hex.audit      No retired or security advisory packages found rc=0
$ mix deps.unlock --check-unused                             rc=0
```

**8 de 8.**

> `mix hex.audit` imprimió el error de TLS del sandbox (`asn1 bad_range` contra
> `repo.hex.pm`) y **siguió con la caché**. El `rc=0` es honesto pero **no se
> comprobó contra el registro real**. Queda dicho.

El PLT de dialyzer **incluye las apps hermanas** (`apero`, `arrea`, `trebejo`,
`alaja`, `botica`, `pote`) y no aparece ni un `unknown_function`: el fallo que ya
había mordido una vez no se repite.

## 4. L4 — el binario

```
$ mix escript.build          rc=0
$ ./candil --help           7 comandos (doctor, help, models, run, status, stop, version)
$ ./candil version          Candil 4.0.0
$ ./candil run              [✗] usage: candil run <model> [--detach] [--port N]
$ ./candil status           [i] no hay instancias
$ ./candil doctor           0 errores · 5 advertencias
```

Los cuatro fallos de `HANDOFF.md` §6 están arreglados y verificados a mano.

⚠ `escript.build` **sobrescribe el binario trackeado**. Restaurado con
`git checkout -- candil`; el árbol queda limpio. La trampa sigue viva.

**NO ejecutado**: `./candil run coder --detach` con un `STATE` en `ON` (criterio de
F4). *Criterio ejecutado: unitario, no integración, porque no hay modelo, ni GPU,
ni GGUF en este sandbox.*

## 5. Ficheros tocados

| Fichero | Qué |
|---|---|
| `lib/candil/detector.ex` | `safe_arch/0` trata `:unknown` como error |
| `lib/candil/instances.ex` | nuevo `log_dir/0` |
| `lib/candil/doctor.ex` | `repair/1` honra el `log_dir` y anuncia lo que creó |
| `lib/candil/model.ex` | sin campo `launcher`; `:external` exige `engine` + `base_url` |
| `test/candil/detector_test.exs` | el test que contradecía al contrato congelado |
| `test/candil/doctor_test.exs` | +2 casos: `log_dir` configurado, y el informe nombra lo que creó |
| `test/candil/model_v4_test.exs` | +2 casos: `engine` obligatorio, y el campo que ya no existe |
| `CHANGELOG.md` | con los nombres de función reales |
| `proyecto 4.0/HANDOFF.md` | §1 con los números medidos |
| `proyecto 4.0/auditoria/**` | 15 documentos corregidos + `README.md` |

## 6. Lo que se ha encontrado y **no** se ha tocado

| | Por qué |
|---|---|
| **A1** · revisión del protocolo MCP | El código está contra `2025-11-25` (Legacy) y la Current es `2026-07-28`, sin handshake. **Decisión de diseño.** No empiezo F9. |
| **A2** · diseño del RAG | Dos documentos, ocho divergencias, dos RAG distintos. **Decisión.** No empieco F10. |
| **A4** · cierre a `main` | `main` pide 1 approving review y el PAT es admin. Mergear saltándosela es saltarse la única protección del repo. **Por eso esto está en una rama y no mergeado.** |
| El puente TOML → `Store` | `HANDOFF.md` §5-bis: sin asignar a ninguna fase, y con una pregunta abierta de `to_existing_atom/1` en la primera carga. |
| Los cuatro `String.to_atom/1` | Dos de la CLI, dos del TOML. Ninguno viene de la red. La regla dura está escrita sin excepción y la decisión ya está anotada en §5-bis. |
| `### Added` duplicado en el CHANGELOG | Preexistente en `7fc0920` y cosmético. El README de F5 dice que si algo ya commiteado te parece mal, **lo digas en vez de tocarlo**. |
| La cobertura no determinista | 4 cifras distintas en 4 ejecuciones. Información, no resultado. |

## 7. La rama `4.0` está parada, y HANDOFF §1 la sigueelines gibt como rama de trabajo

`HANDOFF.md` §1 dice que la rama de trabajo es `4.0` y que el flujo es
`4.0-fN-algo → PR a 4.0 → sync main → PR 4.0 → main`. **Eso ya no describe la
realidad**, y hay que comprobarlo comparando **árboles**, no ancestros
(`HANDOFF.md` §6 avisa de que GitHub squashea los merges).

16 ficheros difieren entre `main` y `4.0`, y en **los 16 la versión buena es la de
`main`**:

| | `main` | `4.0` |
|---|---|---|
| `mix.exs` | `version: "4.0.0"` | `version: "3.0.0"` |
| `lib/candil/cli/help.ex` | los nombres salen de `CLI.commands()` | lista fija de 4 comandos |
| `lib/candil/cli/lifecycle.ex` | `run_model([])` da el mensaje de uso | revienta con `FunctionClauseError` |
| `.github/workflows/ci.yml` | construye y prueba el escript (−33 líneas) | no lo hace |
| `config/config.exs` | logger a `:warning` (`--json` parseable) | sin el arreglo |
| `test/candil/cli_test.exs` | comprueba help ↔ tabla de despacho | sin ese test |
| `HANDOFF.md` / `README.md` / fases | 539 / 217 / 111 líneas | 469 / 172 / 108 |

**Nada se ha quedado atrapado en `4.0`**: no tiene ni una línea que `main` no
tenga. Está simplemente tres commits atrás, con los bugs ya arreglados en `main`.

⚠ **No la he sincronizado**, porque decidir si `4.0` se actualiza, se archiva o se
borra es política del repo, no una línea de código. Lo que sí conviene es que
`HANDOFF.md` §1 deje de anunciar `4.0` como rama de trabajo: si el próximo agente
lo lee, abre una rama desde un sitio donde faltan cinco arreglos.

## 8. Cómo se retoma

```bash
git fetch origin && git checkout main && git pull --ff-only origin main
cd proyecto 4.0/auditoria && cat RETOMAR.md      # el punto de entrada, §2 ya rellena
# la siguiente fase es la 6: auditoria/fase-6-README.md
```

⚠ **Antes de la F6**, dos cosas que no dependen de la decisión y que se pueden
hacer ya: `chat_with_context/4` no existe, y el `reason` del `Builder` no duplica
la causa (0 ocurrencias de `:no_room_to_truncate`, `:budget_exhausted` y
`:no_room_for_system` en todo `lib/`).
