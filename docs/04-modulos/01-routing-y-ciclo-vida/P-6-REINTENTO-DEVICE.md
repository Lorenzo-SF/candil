# P-6 · El reintento en otro device — spec

> **Estado**: **borrador escrito por el consejero** (2026-10-23) ✓, a la espera
> de la decisión del dueño sobre alcance y evidencia ✓.
>
> **Qué es**: cuando `Engine.start_placed/2` decide un device y el arranque
> falla, **probar el siguiente device** en vez de devolver el error a la
> primera ✓. Es la última pieza de la 8b que queda abierta ✓.
>
> **Qué no es**: el **split** (`--split-mode layer`, `--tensor-split`) ✓. Eso
> es otro PR ✓, con dos GPUs reales ✓, y no se mezcla con este ✓.

---

## 1 · Lo que hay hoy

`Candil.Scheduler.plan/2` devuelve **una** decisión ✓:

- `{:ok, device}` — cabe tal cual ✓.
- `{:evict, victims, device}` — no cabe; hay que expulsar ✓.
- `{:error, :no_gpu | :memory_unknown | :gpu_layers_fixed | :no_room}` ✓.

`Candil.Engine.start_placed/2` hace, dentro de
`Engine.Resource.with_placement_lock/1` ✓:

1. `Scheduler.plan(model, binary)` ✓.
2. Si hay que expulsar, `Candil.Engine.stop/1` por víctima ✓.
3. `start(engine, model, device)` ✓.
4. Si `start/3` devuelve `{:error, reason}`, **se acaba** ✓: no hay segundo
   intento ✓.

El ledger **ya es por device** ✓: `Engine.Resource` registra
`Arrea.Resource` con el nombre del device ✓, `acquire/3` reserva en ese
device ✓ y `release/3` libera en ese device ✓. Y `start/3` **ya libera la
reserva** cuando `do_start/6` falla ✓ (`engine.ex`, `start_reserved/6` ✓):
un `init/1` fallido no pasa por `terminate/2` ✓.

> **Consecuencia**: P-6 **no necesita un ledger nuevo** ✓. Necesita que el
> engine pregunte al scheduler **más de una vez** ✓ y que el scheduler sepa
> dar **más de un device** ✓.

---

## 2 · El contrato propuesto

### 2.1 · `Scheduler.candidates/3`

```elixir
@type candidate ::
        {:ok, non_neg_integer()}
        | {:evict, [term()], non_neg_integer()}

@spec candidates(Candil.Model.t(), binary() | nil, keyword()) ::
        {:ok, [candidate()]} | {:error, term()}
def candidates(model, binary, opts \\ [])
```

- Devuelve **todos** los dispositivos donde el modelo cabe, en orden de
  preferencia ✓.
- `opts[:exclude]`: lista de índices ya intentados ✓. Se filtran antes de
  decidir ✓.
- Orden:
  1. Los devices donde **cabe sin expulsar** ✓, por `free_mb` descendente ✓
     (el mismo criterio que `place/3` ✓).
  2. Los devices donde **cabe expulsando** ✓, por número de víctimas y luego
     por megas liberados ✓ (el mismo criterio que `evict/3` ✓).
- `plan/2` **no cambia de comportamiento** ✓: pasa a ser
  `case candidates(model, binary, []) do {:ok, [first | _]} -> first; ... end` ✓.
  Así el camino de un solo device sigue diciendo lo mismo ✓.
- Los errores globales se quedan globales ✓:
  - `:no_gpu` si no hay ningún device ✓.
  - `:memory_unknown` si hay devices pero **ninguno** se puede medir ✓.
  - `:gpu_layers_fixed` si el modelo fija las capas y no es `--n-cpu-moe` ✓.
  - `:no_room` si hay devices medibles pero en ninguno cabe ✓.
- Un device **excluido** no se mide ni se propone ✓; el `exclude` no cambia
  el hecho de que los demás se puedan usar ✓.

### 2.2 · `Engine.start_placed/2`

El camino de CPU (`engine.cpu or model.gpu_layers == 0`) **no cambia** ✓.

Para GPU, dentro del mismo `with_placement_lock/1` ✓:

```
intentos = []
excluidos = []

while length(intentos) < @max_placement_attempts do
  case Scheduler.candidates(model, binary, exclude: excluidos) do
    {:ok, []} ->
      return ultimo_error(intentos)

    {:ok, [candidato | _]} ->
      device = device_de(candidato)
      if evict, stop victims
      case start(engine, model, device) do
        {:ok, pid} -> return {:ok, pid}
        {:error, reason} ->
          if retryable?(reason) do
            intentos = [{device, reason} | intentos]
            excluidos = [device | excluidos]
            continue
          else
            return {:error, reason}
          end
      end

    {:error, reason} ->
      return ultimo_error(intentos, reason)
  end
end
```

- `@max_placement_attempts` es **4** por defecto ✓, configurable en
  `[engine]` ✓; el límite existe para que un device que falla siempre no
  convierta un arranque en un bucle ✓.
- La lista se **recalcula en cada intento** ✓, no se congela antes del
  primero: un arranque fallido puede haber liberado memoria ✓, y las
  víctimas de un intento anterior ya no están ✓.
- El **cerrojo de colocación** se mantiene durante todos los intentos ✓.
  Es más lento que soltarlo entre intentos ✓, pero impide que otro proceso
  ocupe el device que acabamos de elegir ✓. La corrección manda sobre la
  latencia ✓.
- Si el primer y único candidato falla, se devuelve **el error original** ✓
  (`:no_room`, `:memory_unknown`…) para no romper a quien ya lo maneja ✓.
- Si hubo **más de un intento**, se devuelve
  `{:error, {:placement_failed, [{device, reason}, ...]}}` ✓. Es un error
  nuevo ✓, solo aparece cuando el camino viejo no habría llegado tan lejos ✓,
  y lleva los intentos para que el siguiente depurador no empiece de cero ✓.

### 2.3 · Qué errores se reintentan

| Error | ¿Se reintenta? | Por qué |
|---|---|---|
| `:no_room` | **Sí** ✓ | Otro device puede tener sitio; es el caso central de P-6 ✓ |
| `:memory_unknown` | **Sí** ✓ | Un device sin medición no dice «no cabe»; otro puede medirse ✓ |
| `:gpu_layers_fixed` | **No** ✓ | Es del modelo, no del device ✓ |
| `:no_gpu` | **No** ✓ | Es de la máquina ✓ |
| `:model_not_found` / `:no_engine` | **No** ✓ | Es del catálogo ✓ |
| `:eaddrinuse` / `:already_started` | **No** ✓ | El puerto o el alias no cambian de device ✓ |
| `{:exit_status, _}` / `:timeout` | **No** ✓ | Un fallo del binario o de los argumentos no se arregla cambiando de GPU ✓ |

La lista es **una lista blanca** ✓, no una lista negra: un error nuevo no se
reintenta hasta que alguien decida que tiene sentido ✓.

---

## 3 · Los cambios, por archivo

### 3.1 · `lib/candil/scheduler.ex`

- **Nuevo** `candidates/3` ✓.
- **Refactor** de `evict/3`: extraer `evict_candidates/3` ✓, que devuelve
  **todas** las decisiones `{:ok, victims, device}` ordenadas ✓; `evict/3`
  devuelve la primera ✓. Sin cambio de comportamiento ✓.
- **Nuevo** `place_all/3` (o `evict_candidates/3`) si hace falta para no
  duplicar el cálculo ✓.
- `place/3` **no se toca** ✓: sigue siendo la función pura de siempre ✓.
- Tests: `scheduler_candidates_test.exs` ✓, con `FakeGPU` de dos devices ✓.

### 3.2 · `lib/candil/engine.ex`

- `start_placed/2` pasa a tener el bucle de §2.2 ✓.
- **Seam de test**: `@doc false def start_placed(engine, model, starter)`
  donde `starter` es `fn device -> start(engine, model, device) end` ✓.
  `start_placed/2` llama a `start_placed/3` con `&start/3` ✓. El seam no
  cambia producción ✓ y permite probar el reintento sin un binario real ✓.
- `@max_placement_attempts` en `@moduledoc`/`@doc` ✓, no una constante
  escondida ✓.
- El `Candil.Engine.stop/1` de las víctimas no cambia ✓.

### 3.3 · `lib/candil/engine/resource.ex`

- **Nada** ✓. El ledger ya es por device ✓, y `start/3` ya libera la reserva
  en el fallo ✓. Si el test demuestra que no lo hace, el bug es de `start/3`,
  no de P-6 ✓.

### 3.4 · `test/support/fake_gpu.ex`

- Hoy simula **una** GPU ✓. P-6 necesita **dos** ✓.
- Extender `install/2` con `devices: [%{total_mb: ..., free_mb: ...}, ...]` ✓,
  manteniendo `total_mb`/`free_mb` como atajo de un device ✓.
- El script debe responder a `-L`, `--query-gpu=index,name,memory.total,memory.free`
  y `--query-gpu=index,uuid` con **una línea por device** ✓, y
  `--query-compute-apps` vacío ✓.
- `no_gpu: true` sigue igual ✓.
- Los tests que usan `FakeGPU` son `async: false` ✓; se mantiene ✓.

---

## 4 · La evidencia

### 4.1 · Tests unitarios (sin GPU)

- `candidates/3` con dos devices donde los dos caben: orden por `free_mb`
  descendente ✓.
- `candidates/3` con el primero lleno y el segundo con sitio: el primero
  sale como `{:evict, [...], 0}` y el segundo como `{:ok, 1}` ✓, y el orden
  pone primero el que **cabe sin expulsar** ✓.
- `candidates/3` con `exclude: [0]`: solo el 1 ✓.
- `candidates/3` sin GPU: `:no_gpu` ✓.
- `candidates/3` con los dos devices ilegibles: `:memory_unknown` ✓.
- `candidates/3` con los dos llenos y sin víctimas: `:no_room` ✓.
- `candidates/3` con `gpu_layers_fixed`: `:gpu_layers_fixed` ✓.
- `plan/2` devuelve **exactamente** el primer candidato ✓ (test de que el
  refactor no cambió el camino viejo ✓).

### 4.2 · Test del bucle de reintento (sin GPU, con `starter`)

- `start_placed/3` con dos candidatos y un `starter` que devuelve
  `{:error, :no_room}` en el device 0 y `{:ok, pid}` en el 1 ✓:
  - dos llamadas al `starter` ✓;
  - la segunda con el device 1 ✓;
  - resultado `{:ok, pid}` ✓;
  - la lista de intentos tiene `{0, :no_room}` ✓.
- `start_placed/3` con un `starter` que falla en los dos: devuelve
  `{:error, {:placement_failed, [{0, :no_room}, {1, :no_room}]}}` ✓.
- `start_placed/3` con un error **no reintentable** (`:gpu_layers_fixed`):
  **una** llamada y el error original ✓.
- `start_placed/3` con un solo candidato que falla: el error original ✓, no
  el `:placement_failed` ✓ (compatibilidad ✓).

### 4.3 · Test del ledger

- Antes del intento, `Engine.Resource.available(0)` es `X` ✓.
- El `starter` falso **no** toca el ledger ✓; el test del ledger se hace con
  `start/3` real y un binario que falla ✓:
  - `start/3` con un engine cuyo binario no existe devuelve error **antes**
    de reservar ✓;
  - `start/3` con un `llama-server` que arranca y muere en `init/1` libera
    la reserva ✓ (ya cubierto por `holder_generation_test.exs` ✓; P-6 añade
    la aserción de que `available/1` vuelve al valor anterior ✓).
- Si el intento 0 reservó y falló, el intento 1 no ve la reserva del 0 ✓:
  `available(1)` no cambia por el intento 0 ✓.

### 4.4 · La puerta simulada (FakeGPU, dos devices)

- `FakeGPU` con dos devices ✓.
- El `starter` falla en el 0 y acierta en el 1 ✓.
- El test corre el **camino real** `start_placed/2` con un engine de test y
  el `starter` inyectado ✓; no se saltan el scheduler ni el bucle ✓.
- Se comprueba que las víctimas del intento 0 se pararon **una vez** ✓ y que
  el intento 1 no las vuelve a parar ✓.

### 4.5 · La puerta real (dos GPUs)

- Máquina con **dos GPUs** ✓ y un modelo que quepa en la segunda ✓.
- Ocupar la primera con otro modelo ✓; arrancar el nuevo ✓; comprobar que
  aterriza en la segunda ✓ y que el ledger de la primera no cambia ✓.
- Forzar el fallo del primer device **no es determinista** en hardware real
  ✓. La puerta real cubre la **selección** multi-device ✓; el **reintento**
  se cubre con la puerta simulada ✓. Si el dueño exige un fallo real en la
  primera GPU, hay que decidir cómo provocarlo sin romper la máquina ✓.
- La puerta real **no corre en CI** ✓: necesita las dos GPUs ✓.

### 4.6 · Las puertas de siempre

- `mix test` con semillas 0 y 1 ✓.
- `mix credo` ✓.
- `mix dialyzer` ✓.
- `mix docs` ✓.
- `grep` de que no aparece `--split-mode` ni `--tensor-split` en el diff ✓.

---

## 5 · Lo que este spec no decide

- **El split** ✓: `--split-mode layer` / `--tensor-split` es otro PR ✓, con
  dos GPUs reales ✓, y no se toca aquí ✓.
- **El reparto de un modelo entre dos GPUs** ✓: P-6 elige **un** device por
  intento ✓; no parte el modelo ✓.
- **La política de expulsión** ✓: no cambia ✓; P-6 solo repite la decisión
  en otro device ✓.
- **El número de intentos** ✓: 4 es el valor de fábrica ✓; el dueño puede
  cambiarlo ✓.
- **La evidencia real** ✓: si `FakeGPU` con dos devices basta o si la puerta
  de dos GPUs es obligatoria para cerrar P-6 ✓. Es la decisión abierta ✓.

---

## 6 · Las decisiones del dueño

1. **Alcance**: ¿solo reintento ✓, solo split ✓, o los dos ✓? Este spec
   asume **solo reintento** ✓; el split va aparte ✓.
2. **Evidencia**: ¿basta la puerta simulada con `FakeGPU` de dos devices ✓,
   o P-6 no se cierra sin dos GPUs reales ✓? La puerta real de §4.5 es la
   que el dueño pidió ✓; la simulada es la que se puede correr en CI ✓.
3. **Error agregado**: ¿`{:placement_failed, intentos}` ✓ o el último error
   a secas ✓? Este spec propone el agregado solo cuando hay más de un
   intento ✓, para no romper el caso de un device ✓.
4. **Tamaño del lote**: ¿4 intentos ✓ o tantos como devices ✓? Este spec
   propone 4 ✓; con dos GPUs el límite práctico son dos ✓.
