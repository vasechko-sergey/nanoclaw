# iPad: Orb Hub Canvas + расширение данных устройства

**Дата:** 2026-06-14
**Статус:** утверждён к реализации
**Область:** `ios/JarvisApp/` (раскладка) + `shared/ios-app-protocol/`, `container/agent-runner/src/mcp-tools/`, `ios/.../Services/` (данные)

## Контекст

`JarvisApp` сейчас iPhone-only, single-column. Корень `ContentView` — фаза-машина `splash → home (OrbHomeView) → chat (ChatView)`, всё через ZStack + opacity/transition. Переключение между 5 агентами (jarvis/payne/greg/scrooge/gordon) — `AgentPickerInline` в шапке. iPad-раскладки нет; на большом экране центрированный орб даёт море пустоты, а `UIScreen.main.bounds.width`, зашитый в `Theme.scale` и `Theme.drawerWidth`, ломается в Stage Manager / Split View / повороте.

Данные с устройства тянутся pull-моделью: агент вызывает MCP-инструмент `request_context` с набором `fields`, девайс отвечает `context_response`, агент получает сырой JSON. Сегодня доступны поля: `health`, `calendar`, `device`, `next_event`, `recent_locations`, `screen_state`. Несколько уже-авторизованных health-метрик и полное окно календаря не отдаются (см. «Вне области» и Фазу 2).

## Цели

1. Удобное приложение для iPad, сохраняющее уникальный визуал (тёмный Jarvis-HUD, teal `#54BEC4`, живой орб из концентрических колец, per-agent акценты).
2. В landscape — левое пространство как переключатель агентов, реализованный **не** клишированным сайдбаром-списком, а орбитой агент-орбов вокруг фирменного орба.
3. Portrait и узкие раскладки — полная аналогия текущего телефонного флоу.
4. Расширить данные, вытягиваемые с устройства (календарь+reminders, focus/motion/weather, Pencil/drag-drop).

## Не-цели (вне области этой итерации)

- Расширение health-полей (HRV, SpO2, resp rate, wrist temp, vo2max, walking HR, body-fat %, lean mass уже авторизованы в `HealthManager`, но не отдаются в `AppContextCoordinator.health()`) — отложено, отдельная итерация.
- watchOS-приложение (`JarvisWatch`) — не трогаем.
- Полный редизайн цветовой схемы/орба — сохраняем как есть.

## Принцип переключения раскладки

Драйвер — **ширина доступной области и size-class, не device и не ориентация устройства напрямую, и никогда не `UIScreen.main.bounds`.**

```
LayoutMode:
  .split    если horizontalSizeClass == .regular
                 И geo.size.width > geo.size.height  (ландшафтное окно)
                 И geo.size.width >= 900
  .stacked  иначе
```

Следствия (желаемые):
- iPad landscape, полный экран → `.split`.
- iPad portrait (regular, ~834/1024pt) → `.stacked` (полная телефонная аналогия — подтверждено: чат в портретном сплите слишком сжат).
- iPhone (compact) → `.stacked`.
- Stage Manager / Slide Over узкое окно → `.stacked` (ширина < 900 или compact).

Детект ландшафта через `width > height` доступной области (не `UIDevice.orientation`) — корректно работает в Stage Manager, где «окно» может быть любым.

---

# Фаза 1 — адаптивная раскладка Orb Hub Canvas

## 1.1 `RootAdaptiveView` (новый корень)

Вставляется над текущим `ContentView`. Владеет splash/коннект-гейтом (как сейчас в `ContentView`/`SplashView`), после `ready` ветвится по `LayoutMode`, вычисленному из `GeometryReader` + `@Environment(\.horizontalSizeClass)`:

```
RootAdaptiveView
├─ .stacked → ContentView   (нынешняя фаза-машина home/chat — поведение без изменений)
└─ .split   → HStack(spacing: 0) {
       OrbHubPane   .frame(width: paneWidth)   // ≈ 38–40% ширины, clamp [360, 460]
       Divider-hairline (Theme.accent @ 0.08)
       ChatCanvas   .frame(maxWidth: .infinity)
   }
```

- Splash остаётся общим; ветвление только после `connectionPhase == .connected` (или autonomous).
- `onChange` ширины из `GeometryReader` → `Theme.refreshScale(width:)` и `Theme.refreshDrawerWidth(width:)` (см. 1.6). Один источник правды о ширине.

## 1.2 Извлечение `OrbHub` (переиспользуемое ядро)

Из `OrbHomeView` выделяется `OrbHub` — ядро орб-кластера, рендерится в двух контейнерах. Содержит:
- центральный `OrbView` (mood `.welcoming`, цвет ядра = акцент активного агента),
- орбита спутников — **контент инъецируется** (см. ниже),
- кольцо action-спутников по long-press (mic/камера/фото/файл) — как сейчас,
- приветствие (`GreetingBank`) под орбом,
- мини health-strip (`HealthStripView`).

Орбита-спутники конфигурируема:
- **narrow home** (`OrbHomeView`): спутники = контекстные подсказки (`SuggestionEngine`) — поведение как сейчас; свитч агента остаётся в шапке (`AgentPickerInline`).
- **wide pane** (`OrbHubPane`): спутники = **агенты** (4 не-активных). Тап → `active.active = agent`, орб лерпит в новый акцент (`lerpToMood` + смена цвета), хаптик `hapticMedium`. Активный агент отражён центральным орбом.

Общая орбит-математика (углы/радиусы из текущего `orbCluster`) выносится в helper, переиспользуется обоими.

## 1.3 `OrbHubPane` (левая панель, wide)

Контейнер вокруг `OrbHub` c агент-орбитой:
- вверху статус-точка коннекта + вход в профиль/настройки,
- центр — `OrbHub` (агент-спутники),
- приветствие + health-strip снизу; тап по strip → StateBoard как **popover** (не sheet, не slide-over) на wide.
- long-press орба → action-спутники (общий код).
- Контекстные подсказки (`SuggestionEngine`) — опциональная компактная строка под приветствием; можно отложить (чат-холст рядом, ценность ниже). Помечено как опциональное, не блокирует фазу.

## 1.4 `ChatCanvas` (правая панель, wide)

Переиспользует `ChatView` (он уже фильтрует таймлайн по `ActiveAgentState`). Встраиваемый режим:
- `ChatView` получает флаг `embedded` (или конфиг шапки): в wide шапка ужата — имя активного агента + статус-точка + «новый чат»; affordance «домой» скрыт (отдельной home-фазы в split нет — орб всегда слева).
- свитч агента слева (орбита) → `ChatView` ре-байндится на таймлайн нового агента (механика мульти-агента уже есть; `active.active` — единый источник).
- инпут-бар снизу панели (текущий `UnifiedInputBar`).

`onGoHome` в wide — no-op/скрыт; в narrow — без изменений.

## 1.5 Профиль/настройки на wide

Текущий `RightDrawerContent` со slide-over и зашитой `Theme.drawerWidth` — **только narrow**. На wide вход в профиль (из `OrbHubPane`) открывает `RightDrawerContent` как **sheet или popover**, без ручной offset-математики и без `UIScreen`.

## 1.6 Фикс зашитой ширины (обязательно, независимо от раскладки)

`Theme.computeScale()` и `Theme.computeDrawerWidth()` читают `UIApplication.connectedScenes…screen.bounds.width` — это ширина **экрана**, не окна; в Stage Manager неверно.

- `Theme.refreshScale(width:)` и `Theme.refreshDrawerWidth(width:)` принимают **явную ширину** доступной области (от `RootAdaptiveView` `GeometryReader`).
- `RootAdaptiveView` вызывает их в `onAppear` и `onChange(of: geoWidth)`.
- Fallback-чтение сцены остаётся только если явная ширина ещё не пришла.

## 1.7 Клавиатура / Pencil / указатель

- **Shortcuts** (`.keyboardShortcut` / `Commands`): ⌘1–5 — свитч агента (по порядку `AgentIdentity.allCases`), ⌘N — новый чат, ⌘↩ — отправка, Esc — расфокус инпута.
- **Scribble**: на iPadOS работает автоматически на `TextField`; задача — убедиться, что инпут/жесты не перехватывают рукописный ввод.
- **Drag&drop**: `.dropDestination(for:)` на `ChatCanvas` принимает `Image`/PDF/файлы → `DraftAttachment` (как существующий attachment-флоу). Расширяет фото-флоу Гордона и выписки Скруджа.
- **Pointer**: `.hoverEffect` на спутниках и кнопках.

## 1.8 Точки касания (файлы)

| Файл | Изменение |
|---|---|
| `Views/RootAdaptiveView.swift` | **новый** — корень, splash-гейт, ветвление split/stacked, прокидка ширины в Theme |
| `Views/ContentView.swift` | splash-гейт переезжает в `RootAdaptiveView`; `ContentView` остаётся чисто stacked-веткой (home/chat фазы) |
| `Views/OrbHub.swift` | **новый** — извлечённое ядро орб-кластера + orbit-math helper |
| `Views/OrbHomeView.swift` | оборачивает `OrbHub` (narrow), спутники = подсказки |
| `Views/OrbHubPane.swift` | **новый** — левая панель wide, спутники = агенты, popover-StateBoard |
| `Views/ChatCanvas.swift` или флаг в `ChatView.swift` | встраиваемый чат |
| `Views/RightDrawerContent.swift` | sheet/popover на wide; slide-over только narrow |
| `Utility/Theme.swift` | `refreshScale(width:)` / `refreshDrawerWidth(width:)` принимают явную ширину |
| `JarvisApp.swift` / точка входа | корень → `RootAdaptiveView` |
| `project.yml` → `xcodegen generate` | после новых `.swift` |

## 1.9 Тесты (Фаза 1)

- Юнит: `LayoutMode` от (width, height, sizeClass) — split только при regular+landscape+≥900.
- UITests: split-раскладка показывает обе панели; stacked = текущий флоу; поворот landscape↔portrait меняет режим.
- Свитч агента тапом по спутнику свопает таймлайн в `ChatCanvas`.
- Keyboard shortcuts (⌘1–5, ⌘N, ⌘↩).
- Регресс: на iPhone поведение не изменилось (stacked-ветка идентична).

---

# Фаза 2 — расширение данных устройства

## 2.0 Рецепт добавления поля (lockstep)

Каждое новое `ContextField` правится синхронно, иначе compile-check падает:

1. `shared/ios-app-protocol/v2.ts` → `ContextFieldEnum` (+ при нужде `params` в `context_request` payload).
2. `container/agent-runner/src/mcp-tools/request_context.ts` → `CONTEXT_FIELDS` зеркало (compile-time `_exhaustive` форсит синк) + `params` в `InputSchema`.
3. `ios/.../Protocol/V2.swift` → типы/декод ответа.
4. `ios/.../Services/AppContextCoordinator.swift` → продьюс значения поля.
5. Менеджер-источник (`CalendarManager` и новые `FocusManager`/`MotionManager`/`WeatherManager`).
6. Fixture-контракт `shared/ios-app-protocol/v2.test.ts` + Swift-зеркало — держит синк Swift↔TS.

Хост-форматтер **не нужен**: `request_context` отдаёт агенту сырой `{data, errors}` JSON; персоны агентов интерпретируют поля сами.

Проверить при старте Фазы 2: `AppCoordinator` инстанцирует `LocationManager`/`HealthManager`/`CalendarManager` (строки ~55–57), но убедиться, что они реально доходят до `AppContextCoordinator`, используемого `TransportV2` (а не остаются nil) — иначе pull этих полей мёртв.

## 2.1 Календарь — полное окно (низкая стоимость)

`calendar_window` (`today|next_7d|next_30d`) **уже** в схеме `request_context.params`. `AppContextCoordinator.calendar()` его игнорирует и возвращает только кэшированный `nextEvent`.
- `CalendarManager` → range-query `EKEventStore` по окну.
- `AppContextCoordinator.calendar(window:)` honors param, возвращает массив событий (title, start, end, attendees-опц.).
- Разрешение календаря уже запрашивается; для iOS 17 — `requestFullAccessToEvents`, `NSCalendarsFullAccessUsageDescription`.

## 2.2 Reminders (средняя — разрешение)

- Новое поле `reminders`.
- `EKEventStore` reminders, `requestFullAccessToReminders`, `NSRemindersFullAccessUsageDescription`.
- Возврат: незакрытые задачи с due-датой в окне.

## 2.3 Focus (низкая)

- Новое поле `focus`.
- `INFocusStatusCenter.default.focusStatus.isFocused` (+ `requestAuthorization`).
- **Ограничение API:** доступен только bool «в фокусе/нет», не конкретный режим (Work/Sleep). Конкретный режим требует Focus-filter App Intent — вне области. Закладываем bool.

## 2.4 Motion (средняя — разрешение)

- Новое поле `motion`.
- `CMMotionActivityManager` (walking/running/automotive/cycling/stationary + confidence) + `CMPedometer` (этажи, каденс).
- `NSMotionUsageDescription`.

## 2.5 Weather (средняя+ — entitlement, делается ПОСЛЕДНИМ/опционально)

- Новое поле `weather`.
- WeatherKit `WeatherService` @ текущая локация → temp/условия.
- **Стоимость:** WeatherKit-capability в Apple Dev portal + entitlement + provisioning (Personal Team — проверить доступность). Поэтому в конце Фазы 2 и опционально — не блокирует остальные поля.

## 2.6 Pencil / drag-drop

Реализованы в Фазе 1 (§1.7). Здесь только как напоминание, что они закрывают «iPad-ввод».

## 2.7 Таблица разрешений/entitlements (Фаза 2)

| Поле | Permission / entitlement | Стоимость |
|---|---|---|
| calendar (окно) | `NSCalendarsFullAccessUsageDescription` (уже) | низкая |
| reminders | `NSRemindersFullAccessUsageDescription` | средняя |
| focus | `INFocusStatusCenter` authorization | низкая |
| motion | `NSMotionUsageDescription` | средняя |
| weather | WeatherKit capability + entitlement + provisioning | средняя+ |

## 2.8 Тесты (Фаза 2)

- Per-field: `AppContextCoordinator` отдаёт новое поле при наличии данных, пустой объект при denied (паттерн «field present, value empty = выключено» — как сейчас).
- Protocol fixture-контракт Swift↔TS зелёный после каждого нового поля.
- `request_context` `_exhaustive` compile-check проходит.

---

## Риски / открытые вопросы

- **WeatherKit provisioning на Personal Team** — может потребовать платный аккаунт/доп. шаги. Если блок — поле `weather` выпадает из итерации без ущерба остальным.
- **Менеджеры до coordinator** — подтвердить, что `CalendarManager` и пр. реально прокинуты в `AppContextCoordinator` (см. 2.0), иначе и текущий календарь не работает.
- **Извлечение `OrbHub`** — central-orb + orbit + long-press actions завязаны на состояние `OrbHomeView`; рефактор требует аккуратной передачи state/callbacks, чтобы narrow-поведение не регрессировало.
- **`ChatView` встраиваемость** — сейчас завязан на fullscreen-фазу (`onGoHome`, autoStartVoice binding); встраивание не должно сломать narrow-флоу.

## Порядок реализации

Фаза 1 (раскладка) → Фаза 2 (данные). Внутри Фазы 1 первым — фикс ширины (§1.6) и `RootAdaptiveView`+`LayoutMode` (каркас), затем извлечение `OrbHub`, панели, ввод. Внутри Фазы 2 — поля по возрастанию стоимости, `weather` последним. Детальный план — через writing-plans.
