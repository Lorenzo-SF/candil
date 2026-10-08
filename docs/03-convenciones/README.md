# 03 · Convenciones — cómo se escribe una fase

> Este documento es el que hace que `docs/` sea un punto único de conocimiento y
> no una carpeta con opinions. Si una fase no sigue este plano, no está escrita.
>
> **Estado**: vigente para toda fase a partir de ahora.

---

## 1 · El plano de una fase

Cada fase es **un directorio** con este contenido exacto. Ni más, ni menos.

```
NN-nombre/
  README.md      ← el plano completo de la fase
  DECISIONES.md  ← opcional, solo si hubo una decisión que cambió el rumbo
```

El `README.md` tiene estas **ocho** secciones, siempre en este orden:

| # | Sección | Qué lleva |
|---|---|---|
| 1 | **Qué es** | El problema, en una frase, y por qué ahora |
| 2 | **Por qué así** | La decisión, con lo que se descartó y por qué |
| 3 | **Qué toca** | **Lista cerrada de ficheros.** Con nombre exacto |
| 4 | **Los tests primero** | El test escrito ANTES del código, literal |
| 5 | **Cómo se hace** | Pasos numerados, con el comando exacto de cada uno |
| 6 | **Las puertas** | Los gates, y qué falla si no pasan |
| 7 | **Cómo se sabe que funciona** | Cómo se verifica — y **cómo se verifica que falla** |
| 8 | **Cuando sale mal** | Los fallos esperados, y qué hacer con cada uno |

### Las tres secciones que no se pueden quitar

La 4, la 7 y la 8. Y la razón es la misma: **cada fallo real de este proyecto
ha salido de una de las tres.**

- Los tests primero, porque el día que escribí un módulo y sus tests juntos, los
  tests pasaron porque los escribí para pasar.
- Cómo se sabe que funciona **y cómo se sabe que falla**, porque un test que solo
  sabe decir «verde» no sabe decir nada. El test del «pin que no existía» cambió
  de `:default` a `:pinned` y nadie lo vio.
- Cuando sale mal, porque la mitad de las horas perdidas han sido buscando el
  motivo de un fallo que el mensaje no explicaba.

---

## 2 · El nivel de detalle

**Debe poder seguirlo alguien que no haya encendido un ordenador.**

Eso significa:

- **Comandos literales**, no `el comando que verifica esto`. Copiar y pegar.
- **Rutas completas.** `lib/candil/router/decision_engine.ex`, no «el motor».
- **Qué se espera ver**, escrito: `debe imprimir 800 tests, 0 failures`, no
  «debe pasar».
- **Qué hacer si no**, escrito: `si dice 84 failures con Mox.Server, el build
  dir está corrupto: rm -rf $MIX_BUILD_PATH y vuelve a compilar`.
- **Sin pasos saltados.** Si das por sabido cómo se instala Elixir, es que
  documentaste a alguien que ya sabe montar una máquina. Ese es el lector.

### Y con un techo

Detalle no es longitud. Detalle es **que no haya ninguna decisión que tomar
mientras se ejecuta**. Si quien lo sigue tiene que elegir entre dos caminos,
falta un paso.

---

## 3 · TDD

### El orden, y no es negociable

```
1. el test, escrito y rojo     ← se ve FALLAR antes de ver pasar
2. el código mínimo
3. el test, verde
4. refactor con el test verde
```

Un test escrito **después** del código no es un test: es una descripción de lo que
hice. Solo vale si alguna vez lo he visto fallar.

### Qué es un test bueno aquí

Un test que **falla cuando el código está mal**. Se comprueba así:

```bash
# rompe el codigo a proposito
mix test test/candil/router_test.exs          # debe decir 0 failures
# ahora rompe algo
mix test test/candil/router_test.exs          # debe decir 1 failure, y decir POR QUE
```

**Si el test pasa con el código roto, no es un test.** Es decoracion.

### Los cuatro patrones que hay en el repo

| Patrón | Para qué | Ejemplo |
|---|---|---|
| **Contrato** | una forma de retorno que no puede cambiar | el `@spec` de `send_message/2` |
| **De orden** | estado compartido entre tests que se filtra | los pins en ETS |
| **De frente** | leer algo y decir si está bien | que `nvidia-smi` diga la VRAM |
| **De necesidad** | que la documentación apunte a algo real | que `candil --help` liste lo declarado |

Cada fase dice cuál usa y por qué.

---

## 4 · SDD

**Especificación antes del código, y la especificación sobrevive al código.**

### El contrato va primero

Cada función pública empieza por su forma de error, no por su cuerpo:

```elixir
@spec decide([map()], [atom()], keyword()) :: {:ok, decision()} | {:error, term()}
```

Un contrato que no dice qué pasa cuando falla es un contrato que no existe.

### Los nombres son el contrato

Un alias se llama `coder`. Si el código dice `:verifier` donde la config dice
`coder`, no hay ningún error: **el router simplemente no encuentra nada**. Por
eso `String.to_existing_atom/1`, nunca `String.to_atom/1`: un nombre que no
existe tiene que ser un fallo ruidoso, no un `nil`.

### Lo que se escribe aquí y no en el chat

| | |
|---|---|
| **Contratos** | `@type`, `@spec`, formas de error |
| **Estructuras** | Los structs, campo a campo |
| **Invariantes** | Lo que no puede ser verdad a la vez |
| **Extensibilidad** | Cómo añade uno su cosa sin tocar Candil |

---

## 5 · Las puertas

Un cambio **no está hecho** porque compila. Está hecho cuando pasa todo:

```
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

Y hay una séptima, que no es una puerta sino una regla:

> **Ninguna fase se cierra con el resultado de un comando.** Se cierra con lo que
> pasó en la máquina del dueño.

### Y el orden de las siete

`format` · `compile` · `credo` · **`test`** · `dialyzer` · `escript`

El `test` está en medio a propósito: si el dialyzer falla antes de correr los
tests, se ha perdido la información de qué rompe de verdad.

### Verificación por semilla

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

**No es superstición.** El último rojo de la fase 7 era un test que dependía del
orden de ejecución: el pin vivía en una tabla ETS que sobrevive entre tests, y
con una semilla concreta el test «sin pin» cogía el pin del otro. Verde con una
semilla no es verde.

### Build limpio

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

Un `MIX_BUILD_PATH` sucio produce `Mox.Server` sin arrancar y 84 fallos que no
son de nadie. **Si salen muchos fallos de golpe y no sabes por qué, el build
está corrupto antes que tu código.**

---

## 6 · Lo que NO se hace aquí

| | |
|---|---|
| **Un `candil.toml` real** | El tuyo vive en `~/.config/candil/candil.toml`. En el repo solo hay el esqueleto generado y un fixture de test |
| **Lógica en el CLI** | El CLI declara con Alaja y llama. Toda la lógica está detrás de un módulo que se puede llamar con `mix run -e` |
| **Una assertion** | Cada fallo necesita su test. Un checker que puede dar un OK falso es peor que no tener checker |
| **Un número sin medirlo** | Si aquí pone «14 modelos», sale de `find lib -name '*.ex' \| wc -l`, no de un recuerdo |

---

## 7 · Las tres preguntas de cada fase

Antes de escribir el código, el autor se responde estas tres. Si alguna tiene
respuesta vaga, la fase no está lista:

1. **¿Cómo sé que está roto?** — el test que falla antes
2. **¿Cómo sé que está bien?** — el test que pasa después, y cómo se ve en la máquina
3. **¿Qué he descartado, y por qué?** — la alternativa, con su motivo

La tercera es la que más cuesta y la que más vale. Una fase sin alternativas
descartadas es una fase donde nadie ha pensado.
