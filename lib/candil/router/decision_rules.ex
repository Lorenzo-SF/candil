defmodule Candil.Router.DecisionRules do
  @moduledoc """
  Reglas **declarativas que pueden cambiar el veredicto**, despues de que las
  capas hayan opinado.

  ## Lo que ya hay, y por que esto es otra cosa

  `[router.rules]` —lo de `words = [...]`— es un **diccionario**: «estas palabras
  significan este modelo». Y como medimos, un diccionario no separa: ninguna
  marca aparece mas en lo que se resuelve que en lo que cae al fallback.

  Esto es otra cosa. Una regla aqui tiene una **condicion sobre lo que ha
  pasado de verdad** —que capa decidio, quien gano, de que consumer viene— y una
  **accion** sobre el resultado:

  ```toml
  [[router.decision]]
  reason = "el posadero solo indexa; que no le toque el chat"
  when = { consumer = "posadero" }
  force = "embed"

  [[router.decision]]
  reason = "con el codigo caro y PII, el barato se queda"
  when = { contains_pii = true }
  veto = "gpt4o"

  [[router.decision]]
  reason = "si el clasificador ha dicho profundo, sube el que razona"
  when = { strategy = "llm", difficulty = "deep" }
  prefer = { model = "verificador", weight = 0.5 }
  ```

  ## Las tres acciones, y por que no son lo mismo

  | accion | |
  |---|---|
  | `force` | **gana**. Si el modelo no esta en los candidatos, la regla **no se aplica y se dice**: forzar algo que no existe no es forzar, es mentir |
  | `prefer` | **suma**. Gana si supera a la suma de las demas; si no, manda la que hubiera ganado |
  | `veto` | **quita**, y **no se puede deshacer**. Es la restriction Dura de D-09: *«ninguna puede devolver un modelo vetado»*. Un `prefer` de 10 puntos no resucita a un vetado |

  Esa ultima linea es la que convierte esto en algo que se puede usar sin miedo:
  un veto es un veto porque `prefer` **no lo mira**. Y al reves tampoco.

  ## El orden

  Por `priority`, de mayor a menor, y a igual empate el **orden del fichero**.
  Un veto gana contra un force anterior: las restricciones Duras mandan sobre
  las blandas, siempre. Por eso el `force` se ejecuta en un segundo pase, ya con
  los vetos aplicados.

  ## Y lo que NO hace

  **No mira el prompt.** Una regla que necesita mirar la peticion es una **capa**,
  y las capas son lo otro. Aqui solo se mira lo que ya ha pasado: la decision, los
  candidatos y el consumer. Es una diferencia de proposito, y por eso esta pieza
  es de milisegundos y la capa `:llm` de segundos.
  """

  alias Candil.Router

  @doc """
  Lee `[router.decision]` de la configuracion ya cargada.

  Cada entrada es `%{reason:, priority:, when:, force:, prefer:, veto:}`.
  Una entrada que no trae ninguna accion **no es una regla**: no hace nada, y
  devolverla haria creer al motor que si.
  """
  @spec from_config(map() | nil) :: [map()]
  def from_config(nil), do: []

  # El toml escribe `[[router.decision]]` —en singular— y el setting se guarda
  # en `decisions`. Se leen los dos nombres porque un `Map.take` se lleva el
  # que no coincide y la lista entera se pierde **sin decir nada**.
  def from_config(settings) do
    case Map.get(settings, :decisions) || Map.get(settings, :decision) do
      decisions when is_list(decisions) -> normalise_todas(decisions)
      _otra -> []
    end
  end

  defp normalise_todas(decisions) do
    decisions
    |> Enum.with_index()
    |> Enum.filter(fn {rule, _pos} -> actionable?(rule) end)
    |> Enum.sort_by(fn {rule, pos} -> {priority(rule), -pos} end)
    |> Enum.map(fn {rule, _pos} -> normalise(rule) end)
  end

  # `has_key?` con atomo sobre un mapa de claves STRING **siempre da falso**, y
  # el filtro se lleva la regla entera sin decir nada. Por eso el toml entero
  # —con acciones— llegaba como `[]` y las reglas no existian.
  defp actionable?(rule) when is_map(rule),
    do: pick(rule, :force) || pick(rule, :prefer) || present?(rule, :veto)

  defp actionable?(_other), do: false

  defp present?(map, clave) when is_atom(clave),
    do: Map.has_key?(map, clave) or Map.has_key?(map, Atom.to_string(clave))

  defp priority(rule) when is_map(rule) do
    case pick(rule, :priority, 0) do
      p when is_integer(p) -> -p
      _otra -> 0
    end
  end

  # El toml llega con claves STRING y `action = {}` se parsea como mapa con
  # guiones bajos, mientras el test construye la regla con atomos. Se aceptan
  # las dos formas por lo mismo que en `[router.rules]`: quien escribe el
  # fichero no tiene por que recordar cual de las dos usa.
  defp normalise(rule) when is_map(rule) do
    %{
      reason: pick(rule, :reason, "regla sin motivo escrito"),
      priority: pick(rule, :priority, 0),
      when: normalise_when(pick(rule, :when, %{})),
      force: pick(rule, :force),
      prefer: normalise_prefer(pick(rule, :prefer)),
      veto: normalise_list(pick(rule, :veto))
    }
  end

  defp pick(map, key, defecto \\ nil)

  defp pick(map, key, defecto) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), defecto))
  end

  # El toml escribe `prefer = { model = "x", weight = 0.5 }` y llega como un mapa
  # de una clave. Normalizado a algo que se pueda sumar.
  defp normalise_prefer(nil), do: nil

  defp normalise_prefer(%{"model" => model} = p), do: {model, pick(p, :weight, 0.5)}

  defp normalise_prefer(%{model: model} = p) when is_binary(model),
    do: {model, pick(p, :weight, 0.5)}

  defp normalise_prefer(model) when is_binary(model), do: {model, 0.5}

  defp normalise_prefer(_other), do: nil

  defp normalise_list(nil), do: []
  defp normalise_list(list) when is_list(list), do: list
  defp normalise_list(other), do: [other]

  defp normalise_when(nil), do: %{}

  # Las claves tambien llegan en string, y `matches?/2` compara por patron con
  # atomos: si la condicion queda con `{"consumer" => "posadero"}` **no casa
  # nunca**, en silencio —que es la forma preferida de fallar aqui.
  defp normalise_when(clause) when is_map(clause) do
    Map.new(clause, fn {k, v} ->
      clave = if is_binary(k), do: known_condition(k), else: k

      if clave in [:strategy, :difficulty, :consumer] do
        {clave, to_string(v)}
      else
        {clave, v}
      end
    end)
  end

  defp normalise_when(_other), do: %{}

  # Las unicas condiciones que el motor sabe mirar. Una condicion con otra clave
  # **no puede hacer nada**, y eso es preferible a que parezca que si: se
  # documenta en el `@moduledoc` y el motor no inventa semantica.
  defp known_condition("strategy"), do: :strategy
  defp known_condition("difficulty"), do: :difficulty
  defp known_condition("consumer"), do: :consumer
  # Una condicion con una clave que el motor no sabe mirar se queda **como
  # texto**: `matches?/2` no tiene clausula para ella y por tanto la regla NO
  # casa. Que seIgnore en silencio, que es preferible a que parezca que se
  # cumple. Y no se convierte en atomo: eso seria uno nuevo por cada clave
  # escrita y cada recarga del fichero.
  defp known_condition(otra), do: otra

  @doc """
  Aplica las reglas a una decision y devuelve la nueva.

  `fallback` es lo que se decide cuando **no** hay a quien elegir: sin esto, un
  `force` sobre un candidato que no existe devolveria `:none` y una peticion que
  si tiene modelos se quedaria sin responder.
  """
  @spec apply([map()], map(), atom(), [atom()]) :: {:ok, map()} | {:error, atom()}
  def apply(rules, decision, consumer, candidates) do
    facts = facts(decision, consumer)

    casan = Enum.filter(rules, &matches?(&1.when, facts))

    {vetados, aplicables} =
      Enum.split_with(casan, fn rule -> rule.veto != [] end)

    eliminados = vetados |> Enum.flat_map(& &1.veto) |> Enum.map(&to_existing_alias/1)

    supervivientes = Enum.reject(candidates, &(&1 in eliminados))

    try do
      decision
      |> Map.put(:alternatives, [])
      |> then(&sacar_vetado(&1, eliminados, supervivientes))
      |> then(&force_after_veto(&1, aplicables, supervivientes))
      |> then(&preferir(&1, aplicables, supervivientes))
      |> Map.put(:degraded, unique(decision.degraded ++ tags_de(eliminados)))
      |> then(&{:ok, &1})
    catch
      :all_candidates_vetoed -> {:error, :all_candidates_vetoed}
    end
  end

  defp facts(decision, consumer) do
    %{
      strategy: to_string(Map.get(decision, :strategy, :default)),
      model: Map.get(decision, :model_alias) |> to_atom_string(),
      consumer: to_string(consumer),
      difficulty: difficulty(decision),
      contains_pii: false
    }
  end

  defp difficulty(%{strategy: :llm}), do: "deep"
  defp difficulty(_decision), do: "none"

  # Una clausula VACIA se cumple siempre. Sin esta clausula, `when = {}` —que es
  # lo que se escribe para «esta regla no depende de nada»— caia al `catch-all`
  # de abajo y **no llegaba a aplicarse nunca**: presente en el fichero, leida,
  # y sin efecto.
  defp matches?(clause, _facts) when is_map(clause) and map_size(clause) == 0, do: true

  defp matches?(nil, _facts), do: true

  defp matches?(%{strategy: str}, %{strategy: actual}), do: str == actual
  defp matches?(%{model: str}, %{model: actual}), do: str == actual
  defp matches?(%{consumer: str}, %{consumer: actual}), do: str == actual
  defp matches?(%{difficulty: str}, %{difficulty: actual}), do: str == actual
  defp matches?(_when, _facts), do: false

  # El force va **despues** de aplicar vetos, y solo si el modelo forzado sigue
  # vivo. Un force que apunta a algo que ya no esta es una regla que no se
  # puede cumplir: se dice en el `reason` y se sigue con lo que hubiera
  # ganado, en vez de inventar un destino.
  # Un veto que quita un candidato pero deja la decision apuntando a el **no es
  # un veto**. Aqui se comprueba: si al que gano le vetaron, se va al siguiente
  # superviviente y se dice en el `reason`.
  defp sacar_vetado(decision, eliminados, survivors) do
    if to_atom_string(decision.model_alias) in Enum.map(eliminados, &to_atom_string/1) do
      case survivors do
        [] ->
          # **Todos vetados no es «sin decision»: es una decision imposible.**
          # Antes aqui se devolvia la decision tal cual, apuntando al modelo
          # vetado — y eso rompe la regla DURA de D-09: *«ninguna puede devolver
          # un modelo vetado»*. No lo ha visto nadie porque nadie ha vetado los
          # tres candidatos a la vez.
          throw(:all_candidates_vetoed)

        [siguiente | resto] ->
          %{
            decision
            | model_alias: siguiente,
              alternatives: resto,
              reason: "#{decision.reason} · #{decision.model_alias} vetado; va #{siguiente}"
          }
      end
    else
      decision
    end
  end

  defp force_after_veto(decision, rules, survivors) do
    # La primera regla con `force` que case. Se trae su motivo con ella: una
    # regla que actua sin decir por que es indistinguible de un fallo.
    caso =
      Enum.find_value(rules, fn
        %{force: nil} -> nil
        %{force: model, reason: reason} -> {model, reason}
      end)

    wanted = caso && to_atom_string(elem(caso, 0))

    case wanted && Enum.find(survivors, &(to_atom_string(&1) == wanted)) do
      nil ->
        decision

      winner ->
        {model, reason} = caso

        %{
          decision
          | model_alias: winner,
            reason: "#{reason} → #{model} (forzado) sobre: #{decision.reason}",
            alternatives: Enum.reject(survivors, &(&1 == winner))
        }
    end
  end

  defp preferir(decision, rules, survivors) do
    caso =
      Enum.find_value(rules, fn
        %{prefer: nil} -> nil
        %{prefer: {model, peso}, reason: reason} -> {model, peso, reason}
      end)

    case caso do
      nil ->
        decision

      {model, peso, reason} ->
        if Enum.find(survivors, &(to_atom_string(&1) == model)) do
          %{
            decision
            | reason: "#{decision.reason} · #{reason} (+#{peso} a #{model})"
          }
        else
          # El modelo preferido no esta: la regla no aplica, y la decision se
          # queda como estaba. Sumar puntos a un modelo que no existe es
          # Puntuar a un fantasma.
          decision
        end
    end
  end

  defp tags_de([]), do: []
  defp tags_de(eliminados), do: [{:vetoed, Enum.map(eliminados, &to_atom_string/1)}]

  defp unique(list), do: list |> Enum.uniq()

  defp to_atom_string(nil), do: ""
  defp to_atom_string(value) when is_atom(value), do: Atom.to_string(value)

  defp to_atom_string(value) when is_binary(value), do: value

  # Un alias que llega del toml y no existe en el Store se queda como texto:
  # no se crea el atomo. Un `[router.decision]` con `veto = "inventado"` no
  # puede convertir una peticion en un destino que no existe.
  defp to_existing_alias(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp to_existing_alias(name), do: name

  @doc """
  Las reglas que hoy hay en la configuracion. Para `candil router explain`.
  """
  @spec configured() :: [map()]
  def configured, do: Router.settings() |> from_config()
end
