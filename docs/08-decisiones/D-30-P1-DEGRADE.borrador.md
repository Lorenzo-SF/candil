# D-30 · P-1 `:degrade` — borrador, pendiente de firma del dueño

**Estado**: borrador. No es una decisión hasta que el dueño firme una de las
cuatro opciones de `CHECKPOINT-2026-10-22.md` §6 fila 11.

**Contexto**:
- `Candil.Refusal` declara `:degrade` en `@type strategy` (`lib/candil/refusal.ex:99`).
- `Candil.Refusal.apply/5` lo trata con `raise ArgumentError` (`:191-195`).
- `:fail` y `:wait` ya llegan al cliente HTTP como 503 + `Retry-After`.

**Opciones** (copiadas del CHECKPOINT §6):
1. Implementar `:degrade` de verdad — solo si el enrutado sabe qué pide la pregunta.
2. Mantenerlo declarado pero sin crash — `apply/5` devuelve `{:error, %Candil.Error{reason: :degrade_unavailable}}` o se rechaza al cargar la config.
3. Retirarlo del tipo y de la config — cierra P-1 por escrito; D-09 queda en `:fail`/`:wait`.
4. Dejarlo como está y documentarlo.

**Recomendación del consejero**: opción 2 ahora; opción 1 solo si se cierra la cobertura.
Si al llegar ahí nadie echa de menos `:degrade`, la relectura honesta es revisar D-09, no ampliarlo.

**Cuando se firme**: la decisión entra en `README.md` de este mismo bloque,
como D-27 ✓, D-28 ✓ y D-29 ✓ —que es donde están **todas** las decisiones ✓—,
con la opción elegida ✓, sus consecuencias ✓ y el impacto en
`Candil.Refusal` ✓ y en el tipo ✓. Y **este fichero desaparece** ✓: un
borrador que sobrevive a su propia firma es un borrador que nadie mira ✓.
