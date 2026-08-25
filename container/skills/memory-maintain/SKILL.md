---
name: memory-maintain
description: Use on the scheduled weekly memory wake to health-check and tidy your OWN private memories/. Dispatches the wiki Lint sub-agent, applies its findings, prunes memories/index.md. Private wiki only — never public.md, /workspace/shared, or /workspace/global. Terminal, silent — no message to the owner.
---

# memory-maintain — недельная гигиена приватной памяти

Раз в неделю (плановый таск). Проверяешь и приводишь в порядок **свою приватную** `memories/`, чтобы индекс не расходился с файлами, а факты не тухли и не двоились. Терминально, молча — владельцу ничего не пишешь, a2a не шлёшь.

Это операция **Lint** из `INSTRUCTIONS.md §Wiki memory` — здесь только её недельная обёртка. Механику памяти не переписывай, следуй INSTRUCTIONS.

## Что трогаешь и что НЕ трогаешь

- **Трогаешь:** свою приватную `memories/` и её `memories/index.md`.
- **НЕ трогаешь:**
  - `memories/public.md` — её владелец скилл `publish`, не лезь.
  - `/workspace/shared/**` — туда только через осознанный Publish (см. INSTRUCTIONS §Wiki memory), не в этой рутине.
  - `/workspace/global/**` (`about.md`, `profiles/`) — read-only, пишет хост/Джарвис.

## Шаги

1. **Lint в саб-агенте.** Длинные страницы не тащи в свой контекст — гоняй проверку в `Task` (как в INSTRUCTIONS §Wiki memory):

   ```
   Task({
     description: "wiki lint",
     prompt: "Read /workspace/agent/INSTRUCTIONS.md §Wiki memory (Lint) and health-check ONLY my private memories/: orphan pages (not in index), contradictions between pages/sources, stale or superseded claims, missing pages the index promises. Do NOT touch the shared zone, public.md, or /workspace/global. Return a concise list of concrete fixes (file → action).",
   })
   ```

2. **Применяешь правки** из отчёта сабагента, по дисциплине «реестр, не журнал» (та же, что у общего профиля):
   - Дубли — **сливаешь** в одну страницу, лишние удаляешь.
   - Устаревшее / отменённое новым фактом — **выкидываешь**, не складываешь рядом («переехал» — старого города не остаётся).
   - Противоречия — разрешаешь в пользу свежего/достоверного, помечаешь дату.
   - Раздутую страницу — сжимаешь, не растишь.

3. **Индекс.** Перечитай `memories/index.md` и приведи в соответствие с файлами: удали строки на несуществующие файлы, добавь на новые, поправь однострочные описания. Индекс — это карта, по ней ты находишь память на старте.

4. **Границы.** Если по ходу видишь готовый к шерингу вывод — это отдельный осознанный Publish (INSTRUCTIONS §Wiki memory), НЕ делай его в этой недельной рутине. Здесь только приватная уборка.

## Терминально

Молчишь: ни сообщения владельцу, ни a2a. Отчёт сабагента остаётся у тебя. Закончил уборку — заверши ход.
