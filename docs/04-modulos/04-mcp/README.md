# 04 · Módulo 4 — Protocolo MCP

> **Que las herramientas de Candil sirvan a cualquier cliente, y que las de
> otros sirvan a Candil.**

> **Qué es este bloque**: el plano de las fases que convierten `lib/candil/mcp.ex`
> —una fachada con dos stubs— en un servidor **y** un cliente.
>
> **Base**: rama `docs-v2`, `main` en `e168ccd` · **Medido el**: 2026-10-07
> **Fase en el orden global**: la **6** de [`docs/02-orden/`](../../02-orden/README.md),
> cuyo prerrequisito declarado es la **1** (los behaviours que faltan).
> **Estado**: **el protocolo está escrito y desfasado.** El resto no existe.

---

## 1 · Qué es

**El problema, en una frase**: hay herramientas fuera de Candil y hay
herramientas dentro, y un LLM no distingue entre las dos: solo sabe que existe
un protocolo por el que se le piden y por el que contesta.

**Por qué ahora**: porque la fase 4 de [`docs/02-orden/`](../../02-orden/README.md)
—`candil serve`— es la primera vez que Candil va a tener un endpoint. Y
[`docs/01-inventario/README.md`](../../01-inventario/README.md) §6 avisa de que el
router está terminado **y sin consumidor**: MCP es el segundo sitio donde ponerlo.

**Las dos mitades, y no son la misma mitad:**

| | Qué es | Dónde |
|---|---|---|
| **Servidor** | Candil **expone** sus herramientas a un host de LLM | `Candil.MCP.serve/1` |
| **Cliente** | Candil **consume** herramientas de otros servidores MCP y las expone como suyas | `Candil.MCP.connect/1` + `Candil.Tool.define/1` |

### ⚠️ La idea central de este bloque

> **«Candil TIENE un MCP» y «Candil DEJA CONSTRUIR un MCP» no son lo mismo.**

Un producto con un servidor MCP es una función: `tools/list` devuelve una lista
fija y `tools/call` despacha a un `case`. Se escribe en una tarde, y funciona.

Un **framework** es otra cosa: un tercero escribe un módulo fuera del repo, lo
registra, y **funciona sin tocar Candil**. Eso solo pasa si hay un `behaviour`, un
registro, y un punto por el que lo suyo entra sin que nadie en `lib/candil/` sepa
que existe.

**El criterio de aceptación de este módulo es una sola frase**:

> *Un tercero define esto y funciona **sin tocar Candil**.*

Y el test de eso está escrito literalmente en §4. Es el test que decide si la
fase 6 está hecha. Sin él, la columna «framework» de
[`docs/01-inventario/`](../../01-inventario/README.md) §2 es una intención.

### ⚠️ Y aquí está lo que hay que decir de entrada

**`Candil.AtomTable` no existe.** En `lib/`, en `test/`, en `deps/` y en
`git log --all`, `AtomTable` **no aparece**. Se comprobó:

```bash
grep -rn "AtomTable" --include="*.ex" --include="*.exs" lib/ test/ deps/*/lib
git log --oneline --all -- '*atom_table*'
```

**Las dos órdenes no devuelven nada.** Este bloque no inventa ese módulo ni
explica por qué existe. Lo que **sí** existe, y es la misma preocupación, está
en tres sitios y se documentan en §2.4:

| Dónde | Qué hace |
|---|---|
| `lib/candil/rag.ex:142-151` | `String.to_existing_atom/1` y `rescue ArgumentError -> {:error, {:unknown_embedder, name}}` |
| `lib/candil/config/hydrate.ex` | el puente TOML → `Store`, que está en la lista de decisiones abiertas de [`docs/01-inventario/`](../../01-inventario/README.md) §7 |
| `docs/03-convenciones/` §4 | *«un nombre que no existe tiene que ser un fallo ruidoso, no un `nil`»* |

**El riesgo real de los átomos no está en Candil todavía.** Está en el otro
lado: en el MCP, cada `tools/call` trae un `name` que es una cadena **de fuera**.
Si eso se convierte con `String.to_atom/1` una vez por llamada, alguien que
mande un million de nombres distintos **mata la VM**, porque la tabla de átomos
de Erlang **no se recoge**. Esa es la fase donde el asunto se vuelve serio.

---

## 2 · Por qué así

### 2.1 · La revisión es `2026-07-28`, y el código dice `2025-11-25`

**Este es el hallazgo más importante del bloque y va primero.**

La revisión de protocolo **decidida** es **`2026-07-28`**, marcada *Current* por la
propia especificación. Lo que hay en `lib/candil/mcp/protocol.ex` hoy es
`2025-11-25`, con `initialize`, con handshake, con sesiones.

| | `2025-11-25` (lo que hay) | `2026-07-28` (lo decidido) |
|---|---|---|
| `initialize` / `notifications/initialized` | **obligatorio**, el primero | **eliminado** (SEP-2575) |
| `Mcp-Session-Id` | existe | **eliminado** (SEP-2567) |
| Dónde va la versión | en la respuesta del handshake | en `_meta` de **cada** petición |
| Cómo se pregunta qué soporta el servidor | `initialize` | **`server/discover`** |
| Desajuste de versión | `400` en HTTP | **`UnsupportedProtocolVersionError`, `-32022`** |
| `resultType` | no existe | **obligatorio**: `"complete"` o `"input_required"` |
| Estado | protocolo con estado | **sin estado** |

**Verificado contra la especificación, no de memoria**: la documentación de
versioning de `modelcontextprotocol.io` dice *«There is no negotiation
handshake. Every request carries its protocol…»*, y el changelog enumera los
métodos que desaparecen.

### 2.2 · Se compara contra la TUPLA de la revisión, no la cadena

Esto **no** es una preferencia de estilo, y la razón es concreta.

Una revisión de MCP es **una fecha, y una fecha tiene un conjunto de rasgos que
la acompañan**: sin handshake, `server/discover` obligatorio, `_meta` con versión,
`resultType`, los errores de protocolo en el rango `-32020`…`-32099`. **Nada de
eso se deduce de la cadena `"2026-07-28"`**, que es solo una etiqueta.

Si el código compara cadenas, entonces:

- `supported?("2026-07-28 ")` — con un espacio detrás — **no coincide**, y el
  cliente recibe un error que no puede interpretar.
- Un cliente que presenta una revisión **futura** que no se conoce **no se puede
  distinguir** de uno que presenta una revisión que existe pero no se soporta. Las
  dos son `{:error, :unsupported_version}`, y solo una de las dos se puede
  arreglar.

Con una tupla, la comparación es sobre lo que el protocolo **es**:

```elixir
@revision %{
  id: "2026-07-28",
  handshake: false,
  sessions: false,
  requires_discover: true,
  requires_meta: true,
  requires_result_type: true
}
```

Y `UnsupportedProtocolVersionError` **siempre lleva `data.supported`**, que es la
forma en que el cliente se recupera: elige de la lista y repite. Un error de
versión que no dice qué versiones hay es un callejón sin salida para el cliente.

### 2.3 · El batching se eliminó en `2025-06-18`, y sigue eliminado

Un array de peticiones **es un error**, y el único error que puede ser.
`lib/candil/mcp/protocol.ex:163-173` ya tiene esa forma exacta:

```elixir
code: -32_600,
message: "JSON-RPC batching was removed in MCP 2025-06-18. Send one request per message."
```

`-32600` es *Invalid Request* de JSON-RPC 2.0. **Está bien elegido y ya está
probado** (`test/candil/mcp_protocol_test.exs:63-79`, incluido el caso de que un
array vacío **también** es un batch, porque es un array).

> Lo que hay que cambiar aquí es **el mensaje**, porque dice `2025-06-18` y la
> revisión de referencia es `2026-07-28`. El código **-32600** no cambia.

### 2.4 · Átomos: un nombre de fuera **nunca** se convierte con `String.to_atom/1`

La regla de [`docs/03-convenciones/`](../../03-convenciones/README.md) §4 es
*«`String.to_existing_atom/1`, nunca `String.to_atom/1`»*, y
`lib/candil/rag.ex:142-151` ya la cumple con un `rescue` que devuelve
`{:error, {:unknown_embedder, nombre}}`.

En MCP esto **pasa a ser una cuestión de disponibilidad**, no de estilo: el `name`
de un `tools/call` lo manda el cliente. La tabla de átomos de Erlang **no tiene
recolección de basura**. Un bucle que mande `nombre_1`, `nombre_2`, … `nombre_n`
y Candil convierta cada uno, **mata la VM en cuanto la tabla crece de más**, y se
mata al host que la hospeda, que es el LLM, que es el programa del usuario.

La respuesta correcta para un `name` desconocido es
`-32602 Invalid params` (**no** `-32601 Method not found`: el método sí existe,
lo que no existe es la herramienta), y **sin crear el átomo**.

### 2.5 · Un tool que LANZA da `-32603` en esa petición, y el servidor sigue escuchando

`lib/candil/mcp.ex:103-113` ya tiene la forma:

```elixir
code: -32_603,
message: "tool #{inspect(tool_name)} failed: #{Exception.message(exception)}",
data: %{tool: tool_name, reason: inspect(exception.__struct__)}
```

`-32603` es *Internal error* de JSON-RPC 2.0. **La parte importante es lo que el
`@moduledoc` de `lib/candil/mcp.ex:97-100` dice y no es opcional**:

> *A failing tool must not take the server down: the host has other tools to call
> and the failure belongs to the call, not to the session.*

Con `2026-07-28` esto es **más fácil**, no más difícil: sin handshake y sin
sesión, **no hay sesión que tirar**. El error pertenece a la petición y la
petición siguiente se sirve igual. La fase 6 tiene un test que lo demuestra
matando el servidor de verdad después de un tool que revienta (§4.3).

### 2.6 · stdio es el transporte por defecto, y http es el otro

`Candil.MCP.transports/0` (`lib/candil/mcp.ex:53`) devuelve `[:stdio, :http]` y el
`@moduledoc` de las líneas 8-13 da la razón, que es buena:

> *a stdio server has no port to collide with, no token to leak and nothing
> listening after the host goes away.*

La especificación nombra los dos transportes **stdio** y **Streamable HTTP**. En
`2026-07-28`, además:

- **stdio**: se puede sondear con `server/discover` para saber si el otro es
  moderno o heredado. La propia especificación dice que si el otro devuelve un
  `DiscoverResult` **o un error moderno reconocido**, es moderno; si devuelve
  cualquier otro error, o no responde, es heredado.
- **http**: **`MCP-Protocol-Version` es obligatorio**. Una petición que lo
  falta **no se asume** en el camino moderno: se rechaza con `400`.

> ⚠️ Y aquí hay que ser preciso, porque `lib/candil/mcp/protocol.ex:51` dice
> `default_http_version() == "2025-03-26"`, y eso **sigue siendo verdad pero solo
> para el cliente heredado**. La regla «sin cabecera se asume `2025-03-26`» es de
> `2025-03-26`, no de `2026-07-28`. **Un servidor moderno rechaza con `400`; un
> cliente que hable con un servidor heredado asume `2025-03-26`.** Son dos
> funciones distintas y hoy están mezcladas en una. Ver el Anexo IV, decisión 3.

### 2.7 · Las herramientas vienen del REGISTRO, no de una lista

Esto es lo que dice el `@moduledoc` de `lib/candil/mcp.ex:15-20`, y es la frase
que hay que conseguir:

> *`serve/1` takes `:registered` and exposes whatever `Candil.Tool` has. A
> consumer that defines its own tools therefore gets them served without Candil
> knowing anything about them.*

`Candil.MCP.resolve_tools/1` (`lib/candil/mcp.ex:67-68`) ya tiene las dos formas:
`:registered` y una lista de módulos. **`serve/1` tiene que llamar a
`Candil.Tool.list/0` en cada `tools/list`, no a una lista de módulos**, porque
`define/1` puede llamarse **después** de que el servidor esté encendido.

Y para poder hacer eso, `Candil.Tool` tiene que estar vivo. Lo está: es un hijo
del árbol de `lib/candil/application.ex` (`Candil.Tool`), un `GenServer` llamado
`Candil.Tool.Registry`.

### 2.8 · ⚠️ `Candil.Tool` es el punto de extensión, y le falta una pieza

El inventario (`docs/01-inventario/README.md` §2) llama a `Candil.Tool` **registro**
con superficie `define/2`, `call/2`, macro `__tool__`, schema JSON. Todo eso
existe. Pero:

```elixir
# lib/candil/tool.ex:64 — dentro de __using__
@behaviour unquote(__MODULE__)

# lib/candil/tool.ex — en todo el fichero:
$ grep -n "@callback" lib/candil/tool.ex
(sin resultado)
```

**El behaviour está declarado y vacío.** `use Candil.Tool` pone
`@behaviour Candil.Tool`, y `Candil.Tool` **no declara ni un `@callback`**. En la
práctica eso significa que:

- el dialyzer **no comprueba** que la `run/1` que el usuario escribe tenga la
  forma que el `function:` del struct promete
- un usuario puede escribir `run/1` que devuelve una cadena suelta, y el
  `@type function: (map() -> {:ok, term()} | {:error, term()})`
  (`lib/candil/tool.ex:53`) **miente sin que nadie se entere**

Y hay una segunda cosa, más pequeña y más fácil que se escape: **`call/2` no
valida los argumentos.** `validate_args/2` existe (`lib/candil/tool.ex:119-131`) y
comprueba los `required`, pero **`handle_call({:call, ...})` no lo llama**:
`lib/candil/tool.ex:158-166` va directo a `function.(args)`. Es decir: **el schema
que se le enseña al modelo no es el schema que se le exige.**

> Las dos cosas se arreglan en la fase M-1, y las dos son la diferencia entre
> «un registro» y «un punto de extensión».

---

## 3 · Qué toca

Lista cerrada.

### Ficheros que ya existen y **se modifican**

| Fichero | Qué se le hace |
|---|---|
| `lib/candil/mcp/protocol.ex` | **reescrito** a `2026-07-28`: sin `initialize`, `server/discover`, `_meta`, `-32022`, `resultType`, comparación por tupla |
| `lib/candil/mcp.ex` | la fachada: `serve/1` y `connect/1` pasan de stub a cuerpo |
| `lib/candil/tool.ex` | **los `@callback` que faltan**, y `call/2` valida antes de invocar |
| `test/candil/mcp_protocol_test.exs` | **reescrito**: hoy afirma `2025-11-25` en `mcp_protocol_test.exs:10-13` y `:93-95`, y después de esta fase esas aserciones son **falsas** |
| `lib/candil/application.ex` | un hijo más para el servidor stdio, si se supervisa (ver el Anexo IV, decisión 5) |

### Ficheros nuevos

| Fichero | Qué vive en él |
|---|---|
| `lib/candil/mcp/revision.ex` | la **tupla** de la revisión: qué rasgos tiene, y la comparación |
| `lib/candil/mcp/dispatch.ex` | `method → función`. **El único sitio** donde se responde algo |
| `lib/candil/mcp/transport.ex` | el `behaviour`: `recv/1`, `send/2`, `close/1` |
| `lib/candil/mcp/transport/stdio.ex` | el transporte por defecto |
| `lib/candil/mcp/transport/http.ex` | Streamable HTTP con Plug (ya es dependencia) |
| `lib/candil/mcp/server.ex` | el bucle: lee, despacha, escribe |
| `lib/candil/mcp/client.ex` | el otro lado: `connect/1`, y reexponer lo ajeno con `Candil.Tool.define/1` |
| `lib/candil/mcp/errors.ex` | los códigos: `-32600`, `-32601`, `-32602`, `-32603`, `-32022` |

### Tests nuevos

`test/candil/mcp/revision_test.exs` · `test/candil/mcp/dispatch_test.exs` ·
`test/candil/mcp/transport/stdio_test.exs` · `test/candil/mcp/transport/http_test.exs` ·
`test/candil/mcp/server_test.exs` · `test/candil/mcp/client_test.exs` ·
`test/candil/mcp/third_party_test.exs` ← **el del §4.4**

---

## 4 · Los tests primero

| Fase | Patrón | Por qué |
|---|---|---|
| M-1 | **contrato** | un `@callback` es un `@callback` |
| M-2 | **contrato** | la revisión es una forma de retorno que no puede cambiar |
| M-3 | **de orden** | un GenServer y un bucle de entrada |
| M-4 | **contrato** | los códigos JSON-RPC no se inventan |
| M-5 | **contrato** | el mapeo herramienta ajena → `Candil.Tool` es fijo |
| M-6 | **de necesidad** | **el test de tercero**. Que la documentación apunte a algo real |

### 4.1 · M-1 · El behaviour que falta, y el schema que no se exigía

```elixir
defmodule Candil.ToolTest do
  use ExUnit.Case, async: false

  alias Candil.Tool

  setup do
    start_supervised(Tool)
    Tool.reset()
    :ok
  end

  describe "el behaviour" do
    test "run/1 es un callback DE VERDAD" do
      # Este test lee el @spec del behaviour. Si un día desaparece, falla aquí
      # y no en el dialyzer de otro, cuatro meses después.
      {:ok, {_, [{:abstract_code, _}]}} = :beam_lib.chunks(:code.which(Candil.Tool), [:abstract_code])
      assert abstract =~ "run"
    end

    test "call/2 EXIGE lo que el schema le enseña al modelo" do
      Tool.define(%Tool{
        name: "t",
        description: "",
        schema: %{"type" => "object", "required" => ["a"]},
        function: fn args -> {:ok, Map.keys(args)} end
      })

      # Antes esto llegaba a la función con %{}. Ahora dice qué falta.
      assert {:error, %Candil.Error{reason: :invalid_request}} = Tool.call("t", %{})
    end
  end
end
```

### 4.2 · M-2 · La revisión, comparada por tupla

```elixir
defmodule Candil.MCP.RevisionTest do
  use ExUnit.Case, async: true

  alias Candil.MCP.{Protocol, Revision}

  doctest Candil.MCP.Protocol

  describe "la revisión es 2026-07-28, y es sin estado" do
    test "no hay initialize en ninguna parte" do
      refute "initialize" in Protocol.server_methods()
      refute function_exported?(Protocol, :initialize_result, 0)
    end

    test "server/discover es OBLIGATORIO" do
      assert "server/discover" in Protocol.server_methods()
      assert Revision.current().requires_discover
    end

    test "no hay sesiones" do
      refute Revision.current().sessions
      refute Protocol.version_header() =~ "Session"
    end

    test "se compara con lo que la revisión ES, no con su cadena" do
      # Una revisión es un conjunto de rasgos. "2026-07-28 " con un espacio
      # detrás es la MISMA revisión con la etiqueta sucia, y el cliente se
      # merece la respuesta igual.
      assert Revision.supports?("2026-07-28 ")
      refute Revision.supports?("1999-01-01")
    end
  end

  describe "cada petición lleva su versión en _meta" do
    test "sin protocolVersion se rechaza, y en HTTP con 400" do
      assert {:error, {:bad_request, msg}} = Protocol.check_request(%{"method" => "tools/list"})
      assert msg =~ "io.modelcontextprotocol/protocolVersion"
    end

    test "con la versión buena, pasa" do
      assert {:ok, "2026-07-28"} =
               Protocol.check_request(%{
                 "method" => "tools/list",
                 "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
               })
    end
  end

  describe "un desajuste se responde con lo que SÍ soportamos" do
    test "el error es -32022 y lista supported" do
      assert %{error: %{code: -32_022, data: %{supported: supported, requested: "1999-01-01"}}} =
               Protocol.unsupported_version_error("1999-01-01")

      assert "2026-07-28" in supported
    end
  end

  describe "los códigos que no se inventan" do
    test "batching sigue muerto, y sigue siendo -32600" do
      assert Protocol.batch?([%{"id" => 1}])
      assert Protocol.batch_error().error.code == -32_600
      assert Protocol.batch_error().error.message =~ "2025-06-18"
    end

    test "un tool que revienta es -32603 y el servidor sigue" do
      assert %{error: %{code: -32_603}} = Candil.MCP.tool_error(%RuntimeError{message: "boom"}, :w)
    end

    test "una herramienta que no existe NO crea el átomo de su nombre" do
      # La tabla de átomos de Erlang no se recoge. Un million de nombres
      # distintos y la VM está muerta.
      antes = :erlang.system_info(:atom_count)
      _ = Candil.MCP.Dispatch.call_tool("herramienta_que_no_existe_#{:erlang.unique_integer([:positive])}", %{})
      assert :erlang.system_info(:atom_count) - antes <= 1
    end
  end

  describe "resultType" do
    test "todo resultado lo lleva" do
      assert %{resultType: "complete"} = Protocol.complete_result(%{content: []})
    end

    test "un cliente que habla con un servidor viejo asume complete" do
      assert Protocol.result_type(%{}) == "complete"
    end
  end
end
```

### 4.3 · M-4 · El servidor que sobrevive a un tool que revienta

```elixir
defmodule Candil.MCP.ServerTest do
  use ExUnit.Case, async: false

  test "un tool que lanza NO se lleva el servidor" do
    Candil.Tool.reset()
    Candil.Tool.define(%Candil.Tool{
      name: "explota",
      description: "",
      schema: %{"type" => "object"},
      function: fn _ -> raise "boom" end
    })

    {:ok, pid} = Candil.MCP.serve(transport: :stdio, in: StringIO.open(""), out: sink())

    send_pid = send_frame(pid, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
      "params" => %{"name" => "explota", "arguments" => %{}}})
    send_pid = send_frame(pid, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    # La 1 falla con -32603. La 2 contesta. El proceso sigue vivo.
    assert Process.alive?(pid)
    assert_receive %{"id" => 1, "error" => %{"code" => -32_603}}
    assert_receive %{"id" => 2, "result" => %{"tools" => _}}
  end
end
```

### 4.4 · ⭐ M-6 · El test de tercero — **el criterio de aceptación del módulo**

Este es el test que decide si la columna «framework» existe. **Está fuera de
`lib/`. No toca un solo fichero de Candil. Y no se puede arreglar tocando Candil
sin que este test cambie.**

```elixir
# test/candil/mcp/third_party_test.exs
defmodule MiEmpresa.Tools.Pedidos do
  # Una empresa que NO es Candil. Su módulo. Sus reglas.
  use Candil.Tool,
    name: "pedidos_de_un_cliente",
    description: "Los pedidos de un cliente",
    schema: %{
      "type" => "object",
      "properties" => %{"cliente" => %{"type" => "string"}},
      "required" => ["cliente"]
    }

  def run(%{"cliente" => cliente}) do
    {:ok, MiEmpresa.Billing.pedidos(cliente)}
  end
end

defmodule Candil.MCP.ThirdPartyTest do
  use ExUnit.Case, async: false

  alias Candil.{MCP, Tool}

  setup do
    start_supervised(Tool)
    Tool.reset()
    # El tercero se registra EN SU MOMENTO, como lo haría su aplicación.
    Tool.define(MiEmpresa.Tools.Pedidos.__tool__())
    :ok
  end

  test "una herramienta de fuera se sirve SIN QUE CANDIL SEPA QUE EXISTE" do
    # No hay ni una línea de Candil que nombre MiEmpresa. Grep, más abajo.
    assert {:ok, pid} = MCP.serve(transport: :stdio, tools: :registered, in: in_stream(), out: sink())
    pid |> send_frame(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert_receive %{"id" => 1, "result" => %{"tools" => [tool | _]}}
    assert tool["name"] == "pedidos_de_un_cliente"
    stop(pid)
  end

  test "y se puede llamar de verdad, sin registering nada en Candil" do
    {:ok, pid} = MCP.serve(transport: :stdio, tools: :registered, in: in_stream(), out: sink())
    pid |> send_frame(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
      "params" => %{"name" => "pedidos_de_un_cliente", "arguments" => %{"cliente" => "acme"}}})
    assert_receive %{"id" => 1, "result" => %{"content" => [%{"type" => "text"}]}}
    stop(pid)
  end

  test "el grep que demuestra que Candil no sabe de qué va" do
    # La prueba de que la extensión no toca Candil: si este grep encontrara algo,
    # el diseño está mal. Se ejecuta a mano, no en el test.
    #
    #   grep -rn "MiEmpresa" lib/
    #   → (nada)
  end
end
```

> **El `grep -rn "MiEmpresa" lib/` que tiene que devolver nada** es la mitad de
> la prueba. El otro test puede pasar por accidente, si el nombre coincide con
> algo. El grep no.

---

## 5 · Cómo se hace

**Los comandos, en orden.** El orden de las fases está en el Anexo I; aquí está
**qué se ejecuta**, literal.

### 5.1 · Preparar

```bash
cd /ruta/al/repo/candil
git checkout docs-v2
git status                     # debe decir: working tree clean
mix deps.get
mix compile                   # debe decir "Compiled N files", 0 errores
mix test                      # debe decir: 27 doctests, 800 tests, 0 failures
```

Esos dos números son los de [`docs/01-inventario/`](../../01-inventario/README.md),
medidos el 2026-10-07. **Si los tuyos no son, para aquí.**

### 5.2 · Escribir el test, y verlo ROJO

```bash
mix test test/candil/mcp/revision_test.exs
```

**Qué se espera ver**: fallos, cada uno con su razón. Un `0 failures` antes de
escribir el módulo significa que el test está leyendo algo que ya existía.

### 5.3 · El código mínimo

Editar el fichero de §3. Y solo ese.

### 5.4 · Verde

```bash
mix test test/candil/mcp/revision_test.exs      # debe decir: 0 failures
```

### 5.5 · Comprobar que el test **falla con el código roto**

```bash
mix test test/candil/mcp/revision_test.exs      # 0 failures
# cambiar @latest en lib/candil/mcp/revision.ex
mix test test/candil/mcp/revision_test.exs      # 1 failure, Y DECIR POR QUÉ
```

**Un test que pasa con el código roto no es un test.**

### 5.6 · Las siete puertas, en orden

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

Si salen muchos fallos de golpe sin razón aparente, el build está corrupto
antes que tu código:

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

### 5.7 · El smoke test de verdad, contra un host de verdad

⚠️ **`./candil mcp serve` NO existe.** Los comandos se declaran en
`lib/candil/cli.ex` con `use Alaja.CLI.Definition` (línea 43), y ahí **no hay
ninguno de RAG ni de MCP** —los que existen son `version`, `help`, `route`,
`models`, `run`, `stop`, `status`, `init` y `doctor`. Y en el módulo RAG pasa lo
mismo: **no hay `candil rag`**.

Por la regla 1 de [`docs/README.md`](../../README.md) —*«una fase no se cierra por
el CLI»*— **el criterio de aceptación de este módulo es el `mix run -e` y el test
de §4.4, no el binario**.

Lo que se ejecuta hoy:

```bash
mix escript.build && ./candil --help
```

**Y el servidor, con la herramienta externa, que es la que de verdad prueba el
módulo:**

```bash
mix run -e '
  Candil.Tool.define(MiEmpresa.Tools.Pedidos.__tool__())
  Candil.MCP.serve(transport: :stdio, tools: :registered)
'
```

> **Y el grep, a mano, en la máquina del dueño:**
> ```bash
> grep -rn "MiEmpresa" lib/      # no debe devolver NADA
> ```

Cuando exista el comando, `./candil mcp serve` será **confirmación secundaria**,
no criterio.

### 5.8 · Y lo que no es un comando

> **Un servidor MCP que solo ha visto su propio test puede tener el protocolo
> mal y las pruebas en verde.** Hace falta **Inspector**, que lanza el servidor
> como subproceso real, y alguien mirándolo.

---

## 6 · Las puertas

Las mismas siete, en el mismo orden
([`docs/03-convenciones/`](../../03-convenciones/README.md) §5), y qué falla si no
pasan **en MCP**:

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

| Puerta | Si falla en MCP, significa |
|---|---|
| `compile --warnings-as-errors` | un `behaviour` sin `@callback`. **Es exactamente el defecto de `lib/candil/tool.ex` que M-1 arregla** |
| `credo --strict` | `dispatch.ex` con un `case` de 30 ramas, o `revision.ex` comparando cadenas |
| **`test`** | el test de tercero no pasa. **Y eso no se arregla tocando el test** |
| `dialyzer` | un `@spec` de `transport` que promete algo que `stdio.ex` no cumple. Con `:no_underspecs`, dialyzer no avisa de eso: **el test de la §8 lo avisa** |
| `escript.build` | el escript ya no arranca. Y Candil sigue siendo una librería con un binario |

Y la puerta de **este** módulo, que no es un comando:

> **`grep -rn "MiEmpresa" lib/` no devuelve nada.**

> **Ninguna fase se cierra con el resultado de un comando.** Un servidor MCP que
> solo ha visto su propio test puede tener el protocolo mal y las pruebas en
> verde. Hace falta **Inspector**, que es la herramienta oficial y es un
> subproceso real: nada de lo que se ve aquí es un simulacro.

---

## 7 · Cómo se sabe que funciona

**Y cómo se sabe que falla.**

### 7.1 · Que funciona

```bash
# 1. Encender el servidor stdio y hablarle a mano
mix run -e '
  {:ok, pid} = Candil.MCP.serve(transport: :stdio, tools: :registered)
  send(pid, :ping)
'
```

Con un fichero de entrada real, que es lo honesto:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
  | mix run -e 'Candil.MCP.serve(transport: :stdio, tools: :registered)'

# Un array de las dos líneas de arriba tiene que dar -32600.
```

**Qué se espera ver**: dos respuestas, cada una con su `id`, la de `server/discover`
con las versiones soportadas, y **la de `tools/list` con `resultType: "complete"`**.

### 7.2 · Que **falla**

```bash
# 1. Versión que no existe: tiene que decir QUÉ SÍ SOPORTA
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01"}}}' \
  | mix run -e 'Candil.MCP.serve(transport: :stdio, tools: :registered)'
```

**Qué se espera ver**: `code: -32022` y `data.supported` **con al menos
`"2026-07-28"`**. Un `-32602` genérico aquí es un fallo: el cliente no puede
recuperarse de un error que no le dice qué hay.

```bash
# 2. Batching
echo '[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]' \
  | mix run -e 'Candil.MCP.serve(transport: :stdio, tools: :registered)'
```

**Qué se espera ver**: `-32600` y un mensaje que mencione `2025-06-18`. Un array
**atendido** es un fallo: es un servidor hablando una revisión que dice no hablar.

```bash
# 3. Y el que de verdad duele: 100.000 nombres de herramienta distintos
mix run -e '
  antes = :erlang.system_info(:atom_count)
  for i <- 1..100_000 do
    Candil.MCP.Dispatch.call_tool("herramienta_#{i}", %{})
  end
  IO.puts("átomos nuevos: #{:erlang.system_info(:atom_count) - antes}")
'
```

**Qué se espera ver**: un número **pequeño** (0 o 1). **Un número de 100.000 es un
fallo, y si el proceso se muere, es la tabla de átomos.** Este es el test que más
daña si no se hace, y por eso está en la §7 y no solo en el test.

---

## 8 · Cuando sale mal

| Síntoma | Qué es | Qué hacer |
|---|---|---|
| `-32602` con `params: nil` en un `tools/list` | falta `_meta["io.modelcontextprotocol/protocolVersion"]` | **No es un bug del cliente si el cliente es moderno.** Es lo que pasa cuando se habla con un `2026-07-28` desde un cliente `2025-11-25`. La respuesta correcta es `-32022` con la lista de versiones |
| El host MCP **no arranca el servidor** | el binario no existe, o escribe en `stderr` | **`stderr` es del proceso, no del protocolo.** Cualquier `IO.puts` sin `IO.inspect` a stderr rompe un host que lo lee línea a línea. Por eso `Candil.CLI.Escript` existe |
| El servidor se queda mudo después de un error | una excepción se salió del bucle y lo mató | Cada `dispatch` va dentro de un `try`. El `-32603` de §2.5 es el contrato, y el test de §4.3 lo mira en el proceso, no en el log |
| `grep -rn "MiEmpresa" lib/` **devuelve algo** | el diseño está mal: Candil sabe de un cliente | Es el punto. El registro es lo que se expone. Si hay que tocar `lib/` para añadir una herramienta, **el behaviour no está haciendo su trabajo** |
| `atom_count` sube en un bucle | alguien convierte un nombre de fuera con `String.to_atom/1` | §2.4. **`String.to_existing_atom/1`, como ya hace `lib/candil/rag.ex:142-151`** |
| Un cliente `2025-11-25` y un servidor `2026-07-28` **no se entienden** | es lo que dice la especificación | No hay arreglo. Se arregla con `server/discover` como sonda (§5, M-5.2), o eligiendo una revisión antigua. **Hay que decirlo al usuario, no swallowed** |
| `tools/list` devuelve una lista distinta en cada llamada | hay estado, o el registro cambia | Con `2026-07-28` **los endpoints de lista ya no varían por conexión**. Si varyan, es tu código, no el protocolo |
| `Plug` no encuentra la ruta | el servidor MCP y el gateway están en la misma app | Ver el Anexo IV, decisión 4. Hoy son dos cosas distintas: **no se mezclan sin decidir** |

---

## Anexo I · Desglose en fases

### 🔶 FASE M-1 · `Candil.Tool` deja de ser un registro a medias

> **Prerrequisito**: **ninguno.**
> **Desbloquea**: M-3, M-5 y M-6. Y es la fase **1** de
> [`docs/02-orden/`](../../02-orden/README.md), la misma que `R-1` del módulo RAG.
> **Una fase, dos módulos.** Ver el Anexo IV, decisión 1.

Es corta y es la que más valor da por línea escrita.

1. `@callback run(map()) :: {:ok, term()} | {:error, term()}` en
   `lib/candil/tool.ex`, al lado del `@type t`. **El `@behaviour` del `use` ya
   está puesto** (`lib/candil/tool.ex:64`); lo que falta es lo que lo hace
   meaningful.
2. Que `handle_call({:call, name, args}, ...)` llame a `validate_args/2` **antes**
   de `function.(args)`. `validate_args/2` ya existe y ya está probado en
   `test/candil/tool_test.exs:43-60`.
3. Test de que un `run/1` mal escrito **falla**. Si el compilador no se queja,
   el test de §4.1 es el que dice que se queja.
4. Correr las siete puertas.

### 🔶 FASE M-2 · El protocolo a `2026-07-28`

> **Prerrequisito**: **ninguno.** Se puede hacer hoy, y **es lo primero que hay
> que hacer**, porque cambia un test que hoy está verde y afirma lo contrario.

⚠️ **Este bloque no es «añadir cosas». Es quitar cosas.** Y eso significa que
`test/candil/mcp_protocol_test.exs` **cambia de verdad**:

| Test actual | Qué pasa |
|---|---|
| `:10-13` — `assert Protocol.version() == "2025-11-25"` | **falla** hasta que `@latest` sea `"2026-07-28"` |
| `:93-95` — `assert "initialize" == List.first(Protocol.server_methods())` | **se borra**: no hay `initialize` |
| `:15-17` — `2024-11-05` como fallback | **se decide** si sigue o se va (Anexo IV, decisión 2) |
| `:32-38` — sin cabecera se asume `2025-03-26` | **se parte en dos**: `400` para moderno, supuesto para heredado |
| `:81-90` — `initialize_result/0` | **se borra**, y con él `lib/candil/mcp/protocol.ex:129-143` |

1. `lib/candil/mcp/revision.ex`: la **tupla**. `id`, `handshake`, `sessions`,
   `requires_discover`, `requires_meta`, `requires_result_type`. Y
   `supports?/1` comparando rasgos, no cadenas.
2. Reescribir `@supported`. **Decidir** si `2025-11-25` se sirve: sin handshake
   se puede, pero es **otro dialecto**, y son dos máquinas distintas. Es la
   decisión 2 del Anexo IV y **no se decide por omisión**.
3. `check_request/1`: lee `params._meta["io.modelcontextprotocol/protocolVersion"]`,
   y en http también la cabecera `MCP-Protocol-Version`.
4. `unsupported_version_error/1`: `-32022` con `data.supported` **y**
   `data.requested`.
5. `server/discover` → `DiscoverResult` con versiones, capacidades e identidad.
6. `resultType` en todo resultado. Y el cliente que recibe un resultado viejo **lo
   trata como `"complete"`**, que es lo que la especificación obliga.
7. `lib/candil/mcp/errors.ex`: los cinco códigos, cada uno con su nombre al lado
   para que nadie los invente.

### 🔶 FASE M-3 · El servidor stdio

> **Prerrequisito**: M-1 **y** M-2.

1. `transport.ex`: `@callback recv(timeout()) :: {:ok, binary()} | :closed | {:error, term()}`,
   `@callback send(binary()) :: :ok | {:error, term()}`, `@callback close() :: :ok`.
   **Un transporte que no cumple el behaviour no sirve.**
2. `dispatch.ex`: **la única tabla `method → función`**. `tools/list` → lo que
   devuelva `Candil.Tool.list/0` **en ese momento**.
3. `server.ex`: bucle. `recv` → Jason.decode → `dispatch` → `send`.
   **`Jason` ya es dependencia** (`mix.exs`).
4. Test de §4.3: el tool que revienta y el servidor que sigue.
5. **El test de §4.4 en este punto.** No al final: si el test de tercero no pasa
   cuando el servidor está en pie, no va a pasar después.

### 🔶 FASE M-4 · El servidor http

> **Prerrequisito**: M-3. **`Plug` y `Bandit` ya son dependencias** (`mix.exs`), y
> hay un módulo `Candil.Gateway.Endpoint` al que mirar.

1. `transport/http.ex`: `POST /mcp`, `MCP-Protocol-Version` **obligatoria**, sin
   ella `400`. **Sin `GET`**: en `2026-07-28` el endpoint GET se eliminó.
2. El mismo `dispatch.ex`. **El transporte no sabe de métodos**, y si algún día
   aparece uno que sabe, es la señal de que se ha roto la frontera.
3. Lo de `server/discover` en http es lo mismo que en stdio. **Sin `Mcp-Session-Id`**
   en ningún sitio: no existe en esta revisión.

### 🔶 FASE M-5 · El cliente

> **Prerrequisito**: M-3, y M-1 para poder reexponer.

1. `client.ex`: `connect/1` habla el **mismo** protocolo por el `transport` que se
   le pase. Un cliente y un servidor son el mismo `dispatch`, mirado al revés.
2. Por **stdio**, sondear con `server/discover` primero: si vuelve un
   `DiscoverResult` o un `-32022` reconocido, el otro es moderno; si vuelve otro
   error o nada, es heredado. **Es lo que dice la especificación** y es lo que
   hace que un cliente `2026-07-28` pueda hablar con un servidor viejo sin
   tener dos implementaciones.
3. **La reexposición**: cada `tool` del otro se convierte con
   `Candil.Tool.define/1` en un `%Candil.Tool{}` cuya `function` llama al cliente.
   **El `Candil.Tool` no cambia una línea.** Eso es el punto entero.
4. El **nombre de la herramienta reexpuesta**: `otro_servidor__mi_herramienta`, y
   el `name` del `_meta` donde va el de origen. Un nombre plano de otro servidor
   en tu registro es una **colisión esperando**.

### 🔶 FASE M-6 · Endurecer

> **Prerrequisito**: M-4 y M-5.

1. `-32603` por tool que lanza, y el servidor sigue (§2.5).
2. `-32600` por batch. El código **no cambia** (`-32600` es *Invalid Request* de
   JSON-RPC); lo que cambia es el mensaje, que hoy nombra `2025-06-18` como
   referencia y en una revisión sin estado tiene que nombrar **`2026-07-28`**
   (§2.3).
3. `-32602` por herramienta desconocida, **sin crear el átomo** (§2.4).
4. `ttlMs` + `cacheScope` en `tools/list` — la `CacheableResult` de `2026-07-28`.
   **Un `tools/list` que cambia en cada llamada es una petición de red por cada
   prompt.**
5. **El grep del §4.4, a mano, en la máquina del dueño.**

---

## Anexo II · Los contratos

### Lo que YA existe y no cambia de forma

```elixir
# lib/candil/mcp.ex
@spec serve(keyword()) :: {:ok, pid()} | {:error, term()}      # el cuerpo cambia, la forma no
@spec connect(keyword()) :: {:ok, map()} | {:error, term()}
@spec transports() :: [:stdio | :http]                          # ya devuelve [:stdio, :http]
@spec resolve_tools(:registered | [module()]) :: :registered | [module()]
@spec tool_wire(map()) :: map()                                 # schema → inputSchema, ya está
@spec call_result(term()) :: map()                              # lista de bloques tipados
@spec tool_error(Exception.t(), String.t()) :: map()            # -32603
@spec version() :: String.t()                                   # defdelegate a Protocol
@spec supported_versions() :: [String.t()]

# lib/candil/tool.ex
@type t :: %Candil.Tool{name: String.t(), description: String.t(),
                        schema: map(), function: (map() -> {:ok, term()} | {:error, term()})}
@spec define(Candil.Tool.t() | {String.t(), String.t(), map(), function()}) :: :ok
@spec list() :: [t()]
@spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
@spec validate_args(t(), map()) :: :ok | {:error, term()}
```

### Lo que las fases añaden

```elixir
# Candil.Tool — el hueco de §2.8
@callback run(map()) :: {:ok, term()} | {:error, term()}

# Candil.MCP.Revision — la tupla, no la cadena
@type t :: %{
        id: String.t(),
        handshake: boolean(),        # 2026-07-28: false
        sessions: boolean(),         # 2026-07-28: false
        requires_discover: boolean(),
        requires_meta: boolean(),
        requires_result_type: boolean()
      }
@spec current() :: t()
@spec supports?(String.t()) :: boolean()
@spec unsupported_version_error(String.t()) :: map()   # -32022 + data.supported

# Candil.MCP.Transport — el behaviour
@callback recv(timeout()) :: {:ok, binary()} | :closed | {:error, term()}
@callback send(binary()) :: :ok | {:error, term()}
@callback close() :: :ok

# Candil.MCP.Client
@spec connect(keyword()) :: {:ok, map()} | {:error, term()}
```

> **Invariante**: **`dispatch` no sabe qué transporte hay.** El mismo
> `tools/call` se sirve por stdio y por http con **el mismo código**. Si algún día
> un método se comporta distinto según el transporte, la frontera está mal puesta
> y `Candil.MCP.Transport` es demasiado pequeño.
>
> **Invariante**: **ningún método de `server_methods/0` se sirve en un dialecto
> distinto del que anuncia la revisión pedida.** Si se sirve `2025-11-25`, es con
> el `initialize` de `2025-11-25`, o no se sirve.

---

## Anexo III · Lo que queda SIN MEDIR

| | Sin medir | Por qué importa |
|---|---|---|
| **Cuánto tarda un `tools/call` de punta a punta** | por subproceso, con un tool real | decide si el bucle necesita `recv` con timeout y reintento |
| **Si un servidor stdio aguanta un cliente que mande 10.000 `tools/call` seguidos** | sin parar | decide el `@spec recv/1` y si hace falta backpressure |
| **El tamaño de `tools/list` con 29 herramientas** | el `_meta` de `cacheScope` y `ttlMs` | decide si hace falta paginar |
| **Qué hace Inspector con un `-32022`** | si el mensaje se entiende | decide si `data.supported` necesita más contexto |
| **El coste de `String.to_existing_atom/1` con 100.000 nombres** | el número real de la §7.2.3 | el riesgo del §2.4 **es de disponibilidad**, y sin medir es una hipótesis |
| **Si `server/discover` como sonda sobre stdio cuelga** | el timeout | un cliente que espera 30 s a un servidor heredado es peor que uno que espera 1 |

---

## Anexo IV · Las decisiones abiertas

| # | Decisión | Bloquea |
|---|---|---|
| **1** | **M-1 es fase 1 compartida con `R-1` del módulo RAG.** ¿Se hacen en la misma semana o en dos? | El orden global. La respuesta de [`docs/02-orden/`](../../02-orden/README.md) es «en la misma fase» |
| **2** | **¿Se sirve `2025-11-25` además de `2026-07-28`?** Sin handshake es otro dialecto, y son dos máquinas | M-2 |
| **3** | **`default_http_version/0`**: ¿se queda `2025-03-26` para el camino heredado y se añade el `400` del moderno, o se borra? | M-2 |
| **4** | **¿El http de MCP vive en su propio `Endpoint` o bajo el gateway de la fase 4?** Hoy `Candil.Gateway.Endpoint` existe y MCP no. **Mezclarlos sin decidir es cómo se rompe el uno al cambiar el otro** | M-4 |
| **5** | **¿El servidor stdio se supervisa desde `Candil.Application` o lo arranca el proceso que lo invoca?** Un servidor **debe** morir con su host | M-3 |
| **6** | **¿Se implementa `resources/*` y `prompts/*`, o solo `tools/*`?** `server_methods/0` los lista los dos y no hay nada detrás | M-3 |
| **7** | **MRTR (`resultType: "input_required"`)**: es la característica estrella de `2026-07-28` y **no está en el alcance de este bloque**. ¿Se dice en voz alta que no se soporta, o se acepta un resultado mal formado? | M-6, y el cliente de M-5 |
| **8** | **¿El prefijo de las herramientas reexpostas?** `otro__mio` es lo seguro; otra cosa es una colisión silenciosa | M-5 |
| **9** | **`ping` y `logging/setLevel` han desaparecido en `2026-07-28`.** ¿Se responden con `-32601` o con un mensaje que diga que el método ya no existe? | M-2 |

---

## Anexo V · Lo que este documento NO decide

| | |
|---|---|
| **Que hace Candil con las herramientas** | Este bloque las **sirve**. Quién las llama es del router y de los agentes |
| **Autorización y tokens** | La revisión endurece la autorización. **Nada de eso está aquí**: Candil sirve por stdio, donde no hay token |
| **MRTR** | Ver el Anexo IV, decisión 7. Es grande, y es otro bloque |
| **Si el MCP va en el router o aparte** | Como en RAG: [`docs/02-orden/` §8](../../02-orden/README.md) lo deja a cada módulo |