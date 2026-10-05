defmodule Candil.Context.Builder do
  @moduledoc """
  Turns a session into the message list actually sent to a model.

  Order is: system prompt, summary, then as much recent history as fits.

  ## Failing loudly instead of truncating

  When the request does not fit, this returns `{:error, reason}` and **does not
  quietly drop the oldest turns**. A truncated conversation is a conversation
  where the model answers a question it was not asked, with no way for the
  caller to tell. An error is recoverable; a plausible wrong answer is not.

  ## The reason says WHICH part did not fit

  `:context_exceeded` alone is a symptom. Three different things make the same
  request too big, and they need different fixes:

  | `:budget_exhausted` | the new messages alone do not fit the window |
  | `:no_room_for_system` | the system prompt and the summary alone do not fit |
  | `:no_room_to_truncate` | the new messages fit, but only after dropping every single history turn |

  The consumer that has to act on this should not have to parse a sentence to
  find out whether to raise the window, shorten the prompt, or let the history
  go. So the reason duplicates the cause instead of only naming the symptom.

  ## `:compact` is the exception, and it says so

  Under `:compact` the history IS truncated, because sometimes that is the
  right thing. **La forma del exito no cambia**: sigue siendo `{:ok, messages}`.
  Se podia haber anadido un tercer elemento con cuantos se perdieron, y no se
  hace a proposito: `:strict` no recorta nunca, y en `:compact` el recorte es lo
  que se ha pedido. Un contrato que cambia de forma cada vez que se anade una
  idea rompe a todos los que ya lo usan, que es la mitad del trabajo de una
  fase.

  ## `:summarize` never degrades to `:strict`

  If summarising is the policy and the summariser fails, this returns the
  summariser's failure. It does **not** fall back to `:strict` and does **not**
  silently truncate. A policy that quietly becomes another policy when things
  get hard is worse than no policy: the caller believes it asked for a summary
  and got something else.
  """

  alias Candil.Context.{Session, Summarizer}
  alias Candil.Inference

  @default_margin 512
  @default_context_size 4096

  @type reason ::
          :context_exceeded
          | {:context_exceeded, :no_room_to_truncate | :budget_exhausted | :no_room_for_system}

  @type policy :: :strict | :compact | :summarize

  @doc """
  Builds the message list for a request.

  ## Options

    * `:context_size` — the model's window. Not a property of the session: a
      session can be routed to a 4k model and then to a 131k one, and the
      window travels with the model, not with the conversation.
    * `:system_prompt` — prepended as a `system` message.
    * `:margin_tokens` — room left for the response. Default 512.
    * `:policy` — `:strict` (default), `:compact` or `:summarize`.

  ## Examples

      iex> session = Candil.Context.Session.new(:c, "s1")
      iex> Candil.Context.Builder.build(session, [%{role: "user", content: "hola"}])
      {:ok, [%{role: "user", content: "hola"}]}

      iex> session = Candil.Context.Session.new(:c, "s1")
      iex> Candil.Context.Builder.build(session, [%{role: "user", content: "hola"}], context_size: 4)
      {:error, {:context_exceeded, :budget_exhausted}}
  """
  @spec build(Session.t(), [Inference.message()], keyword()) ::
          {:ok, [Inference.message()]} | {:error, reason() | term()}
  def build(session, messages, opts \\ []) do
    margin = Keyword.get(opts, :margin_tokens, @default_margin)
    size = Keyword.get(opts, :context_size, @default_context_size)
    # El margen se le resta de verdad, y con `context_size: 4` y el margen de
    # 512 por defecto la ventana sale NEGATIVA. Con margen >= ventana el
    # diagnostico no puede ser "no hay sitio para el prompt del sistema" —no
    # hay prompt— sino "el presupuesto se ha comido la ventana entera", que es
    # otra cosa y se arregla con otra cosa.
    window = max(size - margin, 0)
    policy = Keyword.get(opts, :policy, :strict)

    prefix = prefix(opts)
    summary = summary(session)
    new_tokens = estimate(messages)

    cond do
      window == 0 ->
        {:error, {:context_exceeded, :budget_exhausted}}

      estimate(prefix ++ summary) > window ->
        {:error, {:context_exceeded, :no_room_for_system}}

      new_tokens > window ->
        # Ni un resumen ni un recorte de historial caben aqui: lo que no cabe
        # es lo que el usuario acaba de escribir. Solo una ventana mayor lo
        # arregla, y eso vale para LAS TRES politicas — mandarlo igualmente
        # produce un 400 del servidor o, peor, un recorte que no hemos pedido.
        {:error, {:context_exceeded, :budget_exhausted}}

      true ->
        {history, dropped} = take_history(session, window - new_tokens)

        decide(policy, dropped, session, messages, opts, prefix, summary, history)
    end
  end

  # Lo unico que queda por decidir cuando la ventana ya esta. Separado para
  # que `build/3` no crezca en ramas: aqui la pregunta es solo que hacer con la
  # historia que no cabe.
  #
  # El problema es el HISTORIAL, que es lo que un resumen puede arreglar, y si
  # hay que tirarlo es pregunta de politica.
  defp decide(:summarize, dropped, session, messages, opts, _prefix, _summary, _history)
       when dropped > 0,
       do: summarize_or_report(session, messages, opts)

  # `:strict` es ESTRICTO: si hay que tirar historia para que quepa, no se tira.
  # Antes se tiraba en silencio y el resultado no decia nada, de modo que un
  # consumidor recibia un contexto mas corto del que creia y no tenia forma de
  # saberlo. Un error de contexto es recuperable; una respuesta plausible a una
  # pregunta que no se ha hecho, no.
  defp decide(:strict, dropped, _session, _messages, _opts, _prefix, _summary, _history)
       when dropped > 0,
       do: {:error, {:context_exceeded, :no_room_to_truncate}}

  defp decide(_policy, _dropped, _session, messages, _opts, prefix, summary, history),
    do: {:ok, prefix ++ summary ++ history ++ messages}

  # `:summarize` con el modelo caido NO degrada a `:strict` ni a `:compact`.
  # Devuelve el fallo del resumidor tal cual, para que quien lo pidio sepa que
  # no hubo resumen. Una politica que en cuanto las cosas se ponenYK difieren
  # se convierte en otra es peor que no tener politica: el llamador cree que
  # pidio un resumen y recibio otra cosa.
  #
  # Y si el resumidor SI funciona, se reconstruye con la sesion ya resumida y
  # sin politica, porque a partir de ahi ya no deberia volver aFallar:
  # si aun asi no cupiera, es que el problema no era la historia.
  #
  # `Summarizer.maybe_summarize/2` no falla: con el modelo caido devuelve la
  # sesion INTACTA (§3.5), y por eso aqui no hay rama de error que escribir. Lo
  # que pasa entonces es que la reconstruccion vuelve a no caber y devuelve
  # `{:error, {:context_exceeded, :no_room_to_truncate}}` — un error, no un
  # recorte. Eso es exactamente lo que "no degrada a :strict" quiere decir: la
  # politica pide un resumen, no lo hubo, y en vez de recortar por debajo se
  # dice que no cupo.
  defp summarize_or_report(session, messages, opts) do
    {:ok, summarized} = Summarizer.maybe_summarize(session, summarize_opts(opts))
    build(summarized, messages, summarize_opts(opts))
  end

  defp summarize_opts(opts), do: Keyword.delete(opts, :policy)

  defp prefix(opts) do
    case Keyword.get(opts, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> [%{role: "system", content: prompt}]
      _ -> []
    end
  end

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "" do
    [%{role: "system", content: "Summary of the earlier conversation:\n\n" <> summary}]
  end

  defp summary(_session), do: []

  # Newest first, put back in order, and SAY how many went. Dropping from the
  # front is what a context window actually does; dropping from the end throws
  # away the question that was just asked.
  #
  # La version anterior devolvia solo la lista, y quien la llamaba no tenia
  # forma de saber que se habia perdido historia. Bajo `:strict` eso es un
  # error; bajo `:compact` es un numero que viaja con el resultado.
  defp take_history(%Session{messages: messages, summarised_upto: upto}, budget) do
    available = Enum.drop(messages, upto)

    {kept, _reversed, dropped} = take_while_within(Enum.reverse(available), budget, 0)
    {Enum.reverse(kept), dropped + (length(available) - length(kept))}
  end

  defp take_while_within([message | rest], budget, dropped) do
    cost = div(String.length(message.content), 4)

    if cost <= budget do
      {kept, rest_kept, dropped} = take_while_within(rest, budget - cost, dropped)
      {[message | kept], rest_kept, dropped}
    else
      {[], rest, dropped + 1}
    end
  end

  defp take_while_within([], _budget, dropped), do: {[], [], dropped}

  defp estimate(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      acc + div(String.length(to_string(message[:content] || "")), 4)
    end)
  end
end
