# Fase 6 — Context compartido


> **Para probar esta fase**: [`../PRUEBAS-MANUALES.md`](../PRUEBAS-MANUALES.md) — comandos, comportamiento esperado y el script `scripts/manual-check.sh`.

> Estado: **pendiente**. Depende de la 4. Carril C.
> Original: `../original/candil-4.0-final.md` §18 y la Fase 6 (~línea 2253).

## Qué es y por qué

Hoy `Candil.Conversation` guarda el historial **en el proceso que llama**. Si
posadero y opencode están en la misma VM, cada uno tiene el suyo, y no se puede
compartir, resumir ni mover entre modelos. `ElPaso` lo resolvió con Postgres y
schemas Ecto; aquí es **ETS**.

Una sesión se identifica por `{consumer, session_id}`. El consumer particiona:
el contexto de `opencode` nunca se mezcla con el de `posadero`, **aunque usen
el mismo `session_id`**. Esa es toda la fase, y es más pequeña de lo que
parece.

## Por qué aquí y no después

Está en la ruta crítica (después de la 4) porque el router de la 7 y la RAG de
la 10 leen contexto, y las dos llegan tarde sin él. La 7 se retiene un día a
propósito: un router que reparte sin contexto reparte bien, y uno que reparte
con el contexto equivocado reparte peor.

## Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/context.ex` y `lib/candil/context/**` |
| Tests | `test/candil/context/**` |
| Lo que ya existe | `Context`, `Context.Builder`, `Context.Session`, `Context.Summarizer`, `Context.PrefixManager` — **congelados en la fase −1, con cuerpo** |

**Carril C.** No toques `router.ex`, `gateway.ex`, `mcp.ex` ni `rag.ex`: son las
fases 7, 8, 9 y 10, y pueden estar en marcha a la vez.

## Qué hay que hacer

1. **Particionar por consumer.** `create(:posadero, "s1")` y
   `create(:opencode, "s1")` son dos sesiones distintas.
2. **TTL.** `gc/0` recoge la sesión vieja. El reloj es **monotónico**; comparar
   reloj de pared contra reloj monotónico es un bug que ya se cometió una vez y
   no recogía nunca.
3. **LRU.** Con `max_sessions: 2`, la tercera desaloja la más antigua. El
   desalojo tiene que funcionar: un `max(0, len - max)` mal colocado nunca
   desaloja nada.
4. **Builder.** Con `context_size` pequeño: `{:error, :context_exceeded}`, **no
   una lista truncada en silencio**. Una lista truncada parece un contexto
   corto; el error dice que no cupo.
5. **Summarizer.** Con el modelo caído, **la sesión queda intacta**. Un resumen
   fallido que deja la sesión vacía destruye trabajo del usuario.

## Cómo se comprueba

```bash
mix test test/candil/context/
#   - aislamiento: create(:posadero,"s1") y create(:opencode,"s1") no se ven
#   - TTL: gc/0 recoge la sesión vieja
#   - LRU: con max_sessions: 2, la tercera desaloja la más antigua
#   - Builder: con context_size pequeño → {:error, :context_exceeded}
#   - Summarizer: con el modelo caído, la sesión queda intacta
```

Más los ocho gates, y **la integración de verdad**, que es la que importa:

```bash
$ ./candil run verifier --detach
$ mix run -e '
  Candil.chat_with_context(:verifier, "s1",
    [%{role: "user", content: "recuerda: mi API key está en $CANDIL_KEY"}],
    consumer: :posadero)
  Candil.chat_with_context(:coder, "s1",
    [%{role: "user", content: "¿qué sabes de mí?"}],
    consumer: :opencode)
  # el segundo NO debe saber nada del primero'
```

Ese último bloque es el criterio. Si el segundo responde sabiendo la API key,
el particionado no funciona aunque todos los tests unitarios pasen.

## Por qué NO

- **No Postgres.** Regla 4 del Apéndice D: ETS siempre. La 6 es sesiones en
  memoria, y `Q9` dice que en v4 no se persisten.
- **No un GenServer de dos Subsequently.** `Context` ya existe; la fase le pone
  cuerpo, no le añade una responsabilidad.

## Definición de done

- [ ] Los cinco casos de `mix test test/candil/context/` en verde
- [ ] El bloque de integración de arriba ejecutado: el segundo consumer **no**
      recuerda nada del primero
- [ ] Los ocho gates verdes
- [ ] El número de tests **no ha bajado** de 702
- [ ] `CHANGELOG.md` con los nombres de función reales
- [ ] `HANDOFF.md` §2 actualizado con números medidos
- [ ] PR contra `4.0`, CI verde
- [ ] **cerrado a `main`**: sync `main` → `4.0` y PR `4.0` → `main`
- [ ] Tag `candil-4.0.0-alpha.4`

## La rama

```
git fetch origin
# antes: sincroniza, para que 4.0 no se vaya atrasando de main
# git checkout 4.0 && git merge origin/main && git push origin 4.0
git checkout -b 4.0-f6-context origin/4.0
```

⚠ Con guion. `4.0/f6-context` es imposible: `refs/heads/4.0` y
`refs/heads/4.0/f6-context` no pueden coexistir, porque Git no admite un ref y
un directorio en el mismo sitio.
