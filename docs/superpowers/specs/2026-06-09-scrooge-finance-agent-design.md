# Скрудж — финансовый агент NanoClaw

**Дата:** 2026-06-09
**Статус:** дизайн утверждён, готов к плану
**Семья агентов:** Jarvis (дворецкий) · Greg (health) · Payne (фитнес) · **Scrooge (финансы)**

## 1. Цель

Узкий финансовый агент Сергея. Ведёт аналитику доходов/расходов из нескольких банков в разных валютах, приводит всё к USD, детектит постоянные подписки, проактивно пингует о перерасходе и срезаемых тратах. Личность — гибрид Дядюшки Скруджа (азарт накопления) и диккенсовского Эбенизера (беспощадность к утечкам).

## 2. Идентичность и вайринг

- **id:** `scrooge` (letter-leading — обходит баг OneCLI/createAgent 400 на id с цифры; см. [[reference-create-agent]] грабля 1).
- **Папка:** `groups/scrooge/`.
- **Создание:** через DB-слой — `createAgentGroup({ id: "scrooge", name: "Scrooge", folder: "scrooge", ... })` + `ensureContainerConfig("scrooge")`. `ncl groups create` игнорит переданный `--id` (генерит свой) и НЕ создаёт строку `container_configs` (грабли 1, 2).
- **Канал:** directly-addressable — свой messaging_group (iOS agent picker + Telegram при желании), как Payne/Greg. Сергей пишет Скруджу напрямую.
- **a2a:** destinations `scrooge↔jarvis` в обе стороны (`ncl destinations add` обе строки). Джарвис может спросить «сколько на еду за месяц», Скрудж проактивно пингует через Джарвиса в основной чат.
- **container_config:** `cli_scope=group` (дефолт), provider `claude`, рантайм Bun, без `additional_mounts` (данные внутри папки группы, авто-mount в `/workspace/agent`).

## 3. Архитектура — поток данных

```
Источники → Ingestion-коннекторы → ledger.db (нормализованный реестр, USD)
                                         │
                  ┌──────────────────────┼───────────────────────┐
            detect-subscriptions.js  analyze.js (Greg-паттерн)  query-скрипты
                  │                      │ findings.json           │ (on-demand)
                  └──────────┬───────────┘                         │
                       проактивный пинг                     ответ + чарт
                    (свой канал / a2a Jarvis)              (canvas → iOS-вложение)
```

Ключевой инвариант (урок Грега): **реестр и сырые выписки НИКОГДА не читаются в LLM-контекст.** Только скрипты их трогают → отдают маленький JSON. CLAUDE.md прямо запрещает `cat`/Read на `ledger.db` и сырые файлы выписок. Нарушение раздувает контекст в разы.

## 4. Данные — нормализованный реестр (SQLite)

`groups/scrooge/finance/ledger.db`. Внутри авто-mount папки группы, **единственный писатель/читатель — контейнер** (хост не трогает), поэтому cross-mount правило `journal_mode=DELETE` (для session-DB) здесь не применяется — обычный режим ок. SQLite, не JSONL: финансы реляционны (group-by, дедуп, recurring-серии, multi-source).

```sql
CREATE TABLE transactions (
  id            TEXT PRIMARY KEY,   -- hash(source,account,ts,amount,raw_desc) → дедуп при пере-загрузке
  ts            TEXT NOT NULL,      -- ISO дата/время транзакции
  source        TEXT NOT NULL,      -- 'bybit' | 'kaspi' | 'tinkoff' | 'bog' | 'homecredit' | 'tgwallet' | 'manual'
  account       TEXT,               -- метка счёта внутри источника
  direction     TEXT NOT NULL,      -- 'in' | 'out'
  amount        REAL NOT NULL,      -- оригинальная сумма
  currency      TEXT NOT NULL,      -- оригинальная валюта
  amount_usd    REAL,               -- нормализовано в USD
  fx_rate       REAL,               -- курс использованный
  fx_date       TEXT,               -- дата курса (= дата транзакции)
  category      TEXT,               -- food/transport/subscription/...
  merchant      TEXT,               -- нормализованное имя мерчанта
  raw_desc      TEXT,               -- оригинальное описание из выписки
  is_recurring  INTEGER DEFAULT 0,  -- флаг от detect-subscriptions
  recurring_group TEXT,             -- id связывающий серию
  created_at    TEXT NOT NULL
);
CREATE TABLE fx_rates (currency TEXT, date TEXT, rate REAL, PRIMARY KEY(currency, date));
CREATE TABLE subscriptions (group_id TEXT PRIMARY KEY, merchant TEXT, amount_usd REAL, period TEXT, last_seen TEXT, status TEXT);
CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT);   -- watermark'и синка, suppress-правила пингов
CREATE INDEX idx_tx_ts ON transactions(ts);
CREATE INDEX idx_tx_cat ON transactions(category);
CREATE INDEX idx_tx_merchant ON transactions(merchant);
```

Дедуп: `id` = детерминированный хэш `(source, account, ts, amount, raw_desc)`. Пере-загрузка той же выписки → `INSERT OR IGNORE`, дублей нет.

Гоча bun:sqlite: именованные параметры требуют префикс `$` И в SQL, И в JS-ключах (`.run({ $id: ... })`) — не авто-стрипается как в better-sqlite3 на хосте (см. CLAUDE.md).

## 5. Ingestion — pluggable коннекторы

Каждый коннектор: источник → массив нормализованных транзакций → upsert в `ledger.db` (дедуп по `id`). **Phase 1 — ручной NL (§5.1) + Bybit (§5.3); этого хватает прогнать всё ядро.** Парсеры выписок (§5.2) — **Phase 2**, когда Сергей выгрузит реальные образцы и сделает парсер под каждый формат.

### 5.1. Ручной NL-ввод (всегда доступен)
Сообщение «потратил 3000 тенге на еду» → Скрудж парсит LLM'ом → одна транзакция (`source=manual`, валюта из текста, категория инференсом, `direction=out`) → upsert. Краткое подтверждение в стиле персоны. Неясная валюта/сумма → один уточняющий вопрос, не выдумывает.

### 5.2. Парсер выписок (на банк) — Phase 2 (deferred)
Откладывается: парсер нельзя написать без реального образца формата, а форматы у банков разные. Сергей сначала выгрузит выписку, потом под неё пишется парсер. Дизайн фиксируем здесь, имплементация — Phase 2.

Сергей грузит выписку **через iOS-приложение** (вложение). Поток:
- Inbound-вложения уже поддержаны каналом: `ios-app/v2/index.ts:252` кладёт `attachments: envelope.payload.attachments` в content сообщения.
- Хост сохраняет байты вложения на диск; агент видит **ссылку на файл**, не base64: `formatter.ts:302-305` рендерит `[pdf: statement.pdf — saved to /workspace/<localPath>]`. Контекст не раздувается.
- Парсер — Bun-скрипт на формат банка (`scripts/parse-<bank>.js`): мапит колонки→поля, формат даты, валюту. Читает файл по пути, не через контекст. Переиспользуемо: парсер `kaspi` написан раз — все будущие выписки Kaspi работают.
- Выход: нормализованные транзакции → upsert.

Форматы (PDF / CSV / Excel) различаются по банку — каждый парсер свой. PDF в Bun: либо текстовый слой через lib, либо требует образец для определения подхода.

### 5.3. Bybit API-коннектор
- Read-only API key+secret. **Хранение креда — паттерн почты:** `groups/scrooge/scripts/.env` (gitignored, монтируется в `/workspace/agent/scripts/.env`) с `BYBIT_API_KEY` / `BYBIT_API_SECRET`. Коннектор копирует `_env.js` (из `groups/jarvis/scripts/_env.js`) и импортит его ПЕРВЫМ, потом читает `process.env.BYBIT_*`. Нативный credential-proxy (`src/credential-proxy.ts`) — **только Anthropic** (один upstream `api.anthropic.com`), третий-party не инжектит; OneCLI-вольта больше нет.
- Bun-скрипт `scripts/sync-bybit.js` → Bybit v5 REST: wallet balance, transaction log, deposit/withdrawal. Подписывает запросы HMAC по ключу.
- Синк по расписанию (`schedule_task`) + on-demand. Маппинг крипто-сумм → USD (значение транзакции в USD или текущий тикер).
- **Безопасность:** ключ строго read-only (без права вывода средств) — ограниченный blast radius при компрометации файла.

### Открытый вопрос (для плана)
Подтвердить, что inbound-пайплайн **реально пишет байты вложения на диск и ставит `localPath`**. `formatter.ts` умеет рендерить путь, но персист байтов — часть активной iOS-работы (git status: `ChatView.swift`, `OrbHomeView.swift` модифицированы). Если персиста нет — это конкретная точка интеграции, которую надо добить до парсеров.

## 6. Нормализация валют

- **Источник курсов:** exchangerate.host (free, покрывает KZT/RUB/GEL/USD; frankfurter/ECB не даёт RUB после 2022 и не имеет KZT/GEL). Крипта ≈ USD напрямую.
- **Исторический курс на дату транзакции**, не сегодняшний → отчёты воспроизводимы. Кэш в `fx_rates` по `(currency, date)`.
- На каждой транзакции хранятся `fx_rate` + `fx_date` рядом с `amount_usd`.
- ⚠️ Проверить при имплементации: exchangerate.host всё ещё free / покрывает эти валюты / лимиты. Фоллбэк-источник держать в уме.

## 7. Детект подписок (ядро)

Bun `scripts/detect-subscriptions.js`: группирует транзакции по `(merchant, ~amount)`, ищет регулярные интервалы (мес/нед/год ± допуск), флагует серии ≥N повторов как recurring. Выход — маленький JSON: активные подписки, сумма $/мес, last-charged, «забытые» кандидаты (давно списывается, паттерн неиспользования). Пишет `is_recurring` + `recurring_group` в реестр, обновляет таблицу `subscriptions`.

## 8. Движок анализа (Greg-паттерн)

Bun `scripts/analyze.js` — по расписанию + на новых данных. Считает:
- Траты по категориям/периодам + тренд vs прошлый период.
- Аномалии: всплеск категории, новый recurring, необычно крупная трата, дубль-списание.
- Срезаемые кандидаты: неиспользуемые подписки, дублирующие сервисы, FX-потери на конвертациях.

Выход — `/tmp/findings.json` (capped top-K, маленький). Агент читает **только** его. Нечего пинговать → молчит (как Greg: тихий прогон без находок).

## 9. Проактивные пинги (единственный coaching-механизм)

Выбор пользователя: **только проактивные пинги** — без целей накопления, бюджетов-конвертов, расписанных отчётов. Act-first: не строим бюджетные леса, Скрудж следит и кусает при утечке.

- **Триггер:** (a) расписанный скан (cron via `schedule_task`, заводится на первом прогоне — guardrail по стоимости, не чаще раза в день/неделю); (b) событие — новая выписка/Bybit-синк проглочены.
- Если `findings.json` содержит срезаемое/аномалию И не под suppress в `state` → пинг: свой канал (primary) + опц. a2a Jarvis.
- **Anti-spam:** suppress-правила в таблице `state` (как `memories/state.md` у Грега). Не повторяет тот же finding; уважает 👎 «не повторяй».
- **Голос:** гибрид-Скрудж — «Bah! Подписка X — $12/мес, не трогал 3 месяца. Это $144/год в трубу. Режь.»

## 10. On-demand запросы (ядро, всегда)

«отчёт за месяц» · «сколько на еду» · «найди подписки» · «где срезать?» · «сколько всего в USD по всем счетам» → query-скрипт (`scripts/report.js` с режимами) → форматированный ответ. Где уместно — приложить чарт (§11).

## 11. Графики (canvas, как Jarvis/surf-forecast)

JS canvas → jpg → outbound iOS-вложение. Паттерн доказан: `container/skills/surf-forecast/render.cjs` использует `@napi-rs/canvas` (`node render.cjs input.json output.jpg`), уже в образе.

- `scripts/render-chart.cjs` (node + @napi-rs/canvas): траты по категориям (donut/bar), тренд по месяцам (line), burn подписок.
- Анализ-скрипты (bun) пишут data-JSON → render-скрипт (node) рисует → отдаётся вложением через канал.
- **Кастомный iOS finance-bridge НЕ нужен** (в отличие от workout-bridge у Payne) — переиспользуем общий attachment-путь.
- ⚠️ Подтвердить `@napi-rs/canvas` доступен (surf-forecast его юзает → должен быть в образе).

## 12. Персона (гибрид)

- **База — Дядюшка Скрудж (McDuck):** азартный шотландец, обожает растущую гору монет, экономия = охота за сокровищами, радуется каждому сэкономленному доллару. Гейміфикация роста «хранилища».
- **Прикус — диккенсовский Эбенизер:** на утечках «Bah! Humbug!», презрение к бессмысленным тратам, режет беспощадно.
- Яд — в трату, не в личность (параллель House у Грега: «без хамства в личность — только в проблему»).
- Числа первыми, всегда конкретный USD + оригинал.
- **Plain language** ([[feedback-plain-language]]): разворачивает фин-термины в простые русские; JSON-ключи остаются короткими.
- Язык: русский/английский (зеркалит Сергея), как Jarvis.

## 13. Guardrails / безопасность

- **Не двигает деньги, не торгует, не выводит средства, не инициирует переводы.** Только читает/анализирует/советует. (Параллель доктрине computer-use: budgeting OK, transactions — нет.)
- **Не гарантирует инвестиции** как доход — флагует/предлагает, решает человек.
- Деструктив в реестре (массовая правка, удаление) — один confirm.
- Bybit-ключ строго read-only.

## 14. Обработка ошибок

- Парс выписки упал → репортит какие строки/страницы не разобрал, не глотает молча, просит образец/уточнение.
- FX-fetch упал → последний кэшированный курс + флаг staleness в ответе.
- Bybit auth (401) → «креды Bybit не подгрузились». Проверка как у почты: `ls -la /workspace/agent/scripts/.env`, смотри stderr скрипта, сообщи конкретику. **Не** приписывай OneCLI (его нет). Не предлагай «авторизоваться через вольт».
- Дубль-загрузка выписки → дедуп по `id`-хэшу, не двоит.
- Неясная валюта/сумма в NL → один уточняющий вопрос.

## 15. Тестирование

Bun-тесты (`bun:test`, не vitest — см. CLAUDE.md; vitest не грузит `bun:sqlite`):
- Парсеры: фикстуры (анонимизированные образцы выписок) → ожидаемые нормализованные строки.
- FX-нормализация: сумма+валюта+дата → ожидаемый `amount_usd` (мок курсов).
- Детект подписок: синтетические recurring-серии → ожидаемые флаги.
- Дедуп: одна выписка дважды → нет дублей.
- analyze: синтетический реестр → ожидаемые findings.
Typecheck контейнера: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` если трогаются `.ts` в agent-runner (здесь скрипты — `.js`, но если добавим MCP-тул — проверить).

## 16. Фазирование

### Phase 1 — ядро + обвязка + приложение
Цель: рабочий Скрудж с данными из ручного ввода + Bybit, личностью, проактивными пингами, отчётами и чартами; виден и адресуем в iOS-приложении.

1. **Агент + вайринг.** `createAgentGroup({id:"scrooge",...})` + `ensureContainerConfig("scrooge")` через tsx-heredoc (рецепт [[reference-create-agent]]). `ncl groups create` игнорит `--id` и не создаёт `container_configs`.
2. **Файлы группы.** `groups/scrooge/{CLAUDE.md, INDEX.md, finance/, scripts/, memories/}`. Скопировать `_env.js` в `scripts/`.
3. **Канал + a2a.** messaging_group → scrooge + destinations `scrooge↔jarvis` обе стороны. Jarvis живой → перепроецировать его destinations (`writeDestinations`, грабля 6).
4. **iOS-интеграция (не забыть).** Три файла + сборка:
   - **`Models/AgentIdentity.swift`** — enum `CaseIterable` (драйвит picker). Добавить `case scrooge`, ветку в `init?(rawValue:)` (`"scrooge"` — алиас НЕ нужен: folder = слаг = `scrooge`), `displayName` («Scrooge»), `accentColor` (приглушённый золотой/янтарный в палитре teal-семейства, как copper у Payne / sage у Greg). `rawValue` обязан совпадать с `agent_id` в outbound-конвертах хоста.
   - **`Utility/GreetingBank.swift`** — per-agent приветствия по слотам времени (morning/day/evening/night), random pick. Добавить `case .scrooge` с 4 слотами × 3-4 фразы в голосе гибрида (азарт монет + прикус Эбенизера). Образец голоса: утро «Деньги не спят — и мы не спим» / день «Так, показывай, куда утекло» / вечер «Сколько спустил сегодня? Признавайся» / ночь «Подписки тоже не спят — каждую ночь списывают». Финальный текст — на импле.
   - **`Views/OrbHomeView.swift` (layout-фикс, польза всем агентам).** Сейчас `Text(greeting)` сидит внутри `orbCluster` ZStack под центральным орбом (~стр. 318) → нижний спутник (radius 130-150) перекрывает. Вынести приветствие из кластера, прибить к низу экрана (`.safeAreaInset(edge: .bottom)` или bottom-overlay на корневом ZStack), с padding над home-indicator. Сохранить стиль (font 11, tracking 2, `accentMedium.opacity(0.7)`) и dimming `opacity(showSatellites ? 0.3 : 1)`.
   - **Сборка:** `xcodegen generate` (только если добавляются новые файлы; правка существующих — не нужно) → build/run в симуляторе через XcodeBuildMCP, визуально проверить picker + приветствие внизу.

   **Отдельный cleanup (не блокер, не бандлить):** алиас `"health-analyzer"` в `init?(rawValue:)` Грега. Папка локально уже `groups/greg/`, но хост стампит `agent_id` = значение `agent_groups.folder` из БД на VDS. Удалять алиас ТОЛЬКО после проверки что на VDS `folder='greg'` (DB, не только переименование папки) — иначе ответы Грега отфильтруются из ChatView. Держать алиас безвредно.
5. **Bybit-кред.** `groups/scrooge/scripts/.env` (gitignore) с `BYBIT_API_KEY`/`BYBIT_API_SECRET` (read-only ключ).
6. **Ядро.** Реестр (`ledger.db` + схема), нормализация USD/FX, скрипты: `sync-bybit.js`, `detect-subscriptions.js`, `analyze.js`, `report.js`, `render-chart.cjs`. Ручной NL-ввод. Персона/CLAUDE.md. Bun-тесты.
7. **Расписание.** Первый прогон заводит recurring `schedule_task` (скан-каденс).

### Phase 2 — парсеры выписок (когда есть реальные образцы)
1. **Подтвердить персист inbound-вложений** на диск + `localPath` (открытый вопрос §5.3) — блокирует парсеры. Добить если не сделано.
2. **Парсер на банк** (`scripts/parse-<bank>.js`) против реального образца: Kaspi → Tinkoff → BoG → Home Credit (по мере выгрузки). Каждый — фикстура + Bun-тест.

### Phase 3+ — см. §18 (out-of-scope сейчас)

## 17. Открытые вопросы / риски (резолвить в плане)

**Phase 1:**
- **exchangerate.host** — актуальность/покрытие KZT/RUB/GEL/лимиты (§6). Фоллбэк-источник держать в уме.
- **@napi-rs/canvas** в образе (§11) — surf-forecast его юзает, должен быть; подтвердить.
- **Bybit v5 подпись/эндпоинты** — HMAC, какие эндпоинты дают полную историю физлица.

**Phase 2:**
- **Персист inbound-вложений** — пишет ли хост байты на диск + ставит `localPath`? (§5.3). Блокирует парсеры выписок.
- **Форматы выписок** Kaspi / Tinkoff / Bank of Georgia / Home Credit — нужны реальные (анонимизированные) образцы. Без них парсер не написать.

**Позже:**
- **Telegram Wallet** — нет чистого API истории физлица; экспорт/скриншоты.

## 18. Вне scope (будущие итерации)

- Telegram Wallet коннектор; Bank of Georgia / другие банковские API если появятся.
- Цели накопления + трекинг, бюджеты-конверты + лимиты, расписанные авто-отчёты (пользователь не выбрал; добавить если потребуется).
- Агрегаторы (Plaid/SaltEdge) — KZ/RU/GE ритейл покрывают слабо, платно, OAuth-возня.
- Кастомный iOS finance-UI bridge (интерактивные дашборды как workout у Payne).

## Связанные

[[reference-create-agent]] · [[project-jarvis-vds]] · [[feedback-plain-language]] · [[feedback-jarvis-act-first]]
