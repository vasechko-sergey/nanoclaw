# Переезд Jarvis на платный Apple Developer + TestFlight

Runbook: от бесплатного Personal Team (7-дневная подпись, установка только через Xcode) →
платная подписка + TestFlight (OTA-раздача Лене, push, Live Activities, виджеты).

Легенда: **[ТЫ]** — делаешь ты (браузер / Xcode / деньги). **[Я]** — код, делаю я.
Порядок важен: фаза зависит от предыдущей.

Grounded-факты на момент написания (2026-07-06):
- bundle id: `dev.vasechko.jarvis`; watch: `dev.vasechko.jarvis.watch` (companion → main)
- team: `24Z6S27D7U` (сейчас Personal Team `vasechkoss@gmail.com`)
- iOS target 18.0; версия `CURRENT_PROJECT_VERSION 91` / `MARKETING_VERSION 1.23.0`
- APNs-кода **нет нигде** (ни iOS, ни host). `.env IOS_APNS_*` — мёртвые заглушки.
- entitlements: только HealthKit. Нет push / App Groups / Associated Domains / Live Activities.
- уведомления сейчас = локальные, будятся self-wake pull (`GET /ios/pending`) — хрупко.

---

## P0 — Подписка (разблокирует всё)  [ТЫ]

**Цель:** оплатить Apple Developer Program.

**Статус 2026-07-16: заявка подана как Individual, ждём ревью (~2 раб. дня по письму Apple).**

### ⚠️ Ловушка региона

- Регион Apple ID был = **Казахстан**. Единственный документ — **российский паспорт**. ВНЖ нигде нет.
- Individual-enroll делает ID-верификацию, привязанную к региону аккаунта: KZ-регион ждёт казахстанский документ → роспаспорт не подходит («passport doesn't match region»).
- Сменить регион на **Россию** нельзя: Developer Program для РФ заблокирован санкциями (оплата не проходит).

### Решение: новый Apple ID с регионом Грузия, enroll как Individual

Проблема была в **регионе аккаунта**, а не в типе энролла. Лечится сменой региона, а не юрлицом.

> **Organization-путь через ИП не существует — проверено на живой форме.** Apple дословно: *«If you are a sole proprietor/single-person business, you must join as an individual and your legal name will appear as the seller»*; Organization требует «recognized as a legal entity». Грузинское ИП — sole proprietor, не отдельное юрлицо → Org-ветка отлупает его by design. D-U-N-S её не открывает (наш `933915244` был отвергнут именно так) и для Individual вообще **не нужен**. Источник: developer.apple.com/support/enrollment/
>
> Следствия: **имя продавца будет `SERGEI VASECHKO`** личное — не `SERGEI VASECHKO, IE` (Apple прямо отказывает ИП-шнику в бизнес-имени как seller). Сайт на домене и рабочая почта требуются только для Organization → для этого энролла не были нужны.

Шаги:
1. Apple ID: **новый**, регион **Грузия**, на `sergei@vasechko.dev`. Заводить **on-device** (Настройки iPhone) и **без VPN** — так капча не циклит. **2FA обязательна**, без неё enroll не пустит. Отдельный аккаунт (а не смена региона основного) — чтобы не тащить KZ-покупки/подписки и не наследовать завалившийся Individual-энролл.
2. https://developer.apple.com/programs/enroll → Start your enrollment → логин **грузинским** Apple ID.
3. Порядок экранов: личные данные (`SERGEI` / `VASECHKO` — как в паспорте, **не** имя ИП: Apple *«Do not enter an alias, nickname, or company name as your legal name»*) → *возможно* скан гос. ID → выбор Entity Type → **Individual**.
4. Оплата **$99/год** BoG-картой.

**Открытый риск:** пройдёт ли ID-верификация по российскому паспорту на GE-аккаунте. На сабмите паспорт не спросили — проверка либо внутри ревью, либо не понадобилась. Узнаем из ответа.

**Фолбэк при отказе на ID** (Org через ИП вычеркнут — невозможен):
- грузинское **LLC** — настоящее юрлицо, Org-ветка открывается, но это регистрация компании + бухгалтерия (большой заход ради TestFlight);
- либо enroll под аккаунтом доверенного лица с грузинским документом, Сергея — в команду. ⚠️ Individual-аккаунт **не умеет добавлять team members** — этот фолбэк требует, чтобы у доверенного лица был Org-аккаунт.

**В окне ревью:** следить за `sergei@vasechko.dev` (CF-форвард → gmail — вся переписка Developer Support туда), отвечать быстро; **не пересабмичивать** — дубли путают ревью.

**После активации проверь:** team id. Сейчас `24Z6S27D7U` — это Personal Team. У платного членства **будет НОВЫЙ team id**. Скажи мне новый — обновлю `DEVELOPMENT_TEAM` в 5 таргетах `project.yml` + пересобрать.

Пока ждёшь одобрения — параллельно делаю код-подготовку P1 (см. «[Я] заранее»).

---

## P1 — Первый билд в TestFlight, приложение КАК ЕСТЬ

**Цель:** доказать канал раздачи. Лена ставит текущий Jarvis по воздуху. Push ещё НЕ добавляем —
сначала убеждаемся, что pipeline «архив → App Store Connect → TestFlight → телефон Лены» работает.

### [Я] заранее (можно во время ожидания P0)
- Добавить в `Info.plist`: `ITSAppUsesNonExemptEncryption = NO`
  (приложение шифрует только стандартным HTTPS/TLS = exempt → это убирает вопрос про экспорт-комплаенс при КАЖДОЙ загрузке).
- Бамп `CURRENT_PROJECT_VERSION` (92) + `xcodegen generate` + коммит pbxproj.
- (Опц., де-риск) временно исключить watch-таргет из схемы архива, чтобы первый аплоуд не спотыкался
  о подпись watch-app. Вернём watch отдельным шагом.

### [ТЫ] в App Store Connect (браузер)
1. https://appstoreconnect.apple.com → **My Apps** → **+** → **New App**.
   - Platform: iOS. Name: `Jarvis` (имя глобально уникально в App Store — если занято, придумаем суффикс).
   - Bundle ID: выбрать `dev.vasechko.jarvis` (появится в списке после того как Xcode/портал его зарегистрирует — см. ниже).
   - SKU: любой (напр. `jarvis-ios`). Primary language: Russian.
2. Если bundle id НЕ виден в списке — сначала зарегистрируй App ID:
   https://developer.apple.com/account/resources/identifiers → **+** → App IDs → App →
   Bundle ID `dev.vasechko.jarvis` (Explicit) → включить capability **HealthKit** (пока только её) → Register.
   (Xcode при архиве обычно сам это делает, но вручную надёжнее для первого раза.)

### [ТЫ] в Xcode (архив + загрузка) — Mac обязателен
1. Из `ios/JarvisApp/` (если я менял `project.yml`): `xcodegen generate`.
2. Открой `JarvisApp.xcodeproj`. Вверху выбери устройство **Any iOS Device (arm64)** (НЕ симулятор).
3. Меню **Product → Archive**. Дождись Organizer.
4. В Organizer: выбери архив → **Distribute App** → **TestFlight & App Store** (или «App Store Connect») → Upload.
   - Signing: **Automatically manage signing** (paid team сам выпустит distribution-профиль).
   - Если спросит про encryption и ты добавил `ITSAppUsesNonExemptEncryption=NO` — вопроса не будет.
5. Аплоуд идёт ~5–15 мин на обработку в App Store Connect (статус «Processing» → готово).

### [ТЫ] пригласить Лену (TestFlight)
Два пути:
- **External (проще для одного человека):** App Store Connect → твоё приложение → **TestFlight** →
  вкладка **External Testing** → создать группу → добавить билд → добавить email Лены (или включить public link) →
  Submit for **Beta App Review**. Первый external-билд проходит бета-ревью Apple (~24 ч, потом обновления быстрее).
- **Internal (без ревью, мгновенно):** добавить Лену как **User** в App Store Connect (роль, напр. App Manager/Developer)
  под её Apple ID → она попадает в Internal Testers → билд доступен сразу, без ревью. Минус: она видит консоль ASC.

Рекомендация: для Лены — **External + email-инвайт**. Один раз подождать бета-ревью, дальше OTA моментально.

### [Лена] установка
1. Ставит из App Store приложение **TestFlight**.
2. Открывает пригласительный email / ссылку → **Accept** → **Install**.
3. Дальше все твои новые билды — просто **Update** в TestFlight. Никаких Mac/кабелей.

✅ Выход P1: Лена пользуется текущим Jarvis по воздуху. Билд живёт 90 дней (потом перезалить).

---

## P2 — APNs push (Phase 1 из плана улучшений). Главный технический выигрыш.

**Цель:** убить хрупкий pull-костыль. Сервер сам будит телефон → проактивные сообщения надёжно звенят.

### [ТЫ] портал — capability + ключ
1. App ID `dev.vasechko.jarvis` → Edit → включить **Push Notifications** → Save.
2. Создать **APNs Auth Key** (один на все приложения аккаунта):
   https://developer.apple.com/account/resources/authkeys → **+** → имя `Jarvis APNs` → галка **Apple Push Notifications service (APNs)** → Continue → Register.
   - **Скачать `.p8` ФАЙЛ — он даётся ОДИН раз, повторно не скачать.** Потеряешь → отзывать и делать новый.
   - Запиши **Key ID** (10 симв.) и **Team ID** (`24Z6S27D7U`). Bundle id = `dev.vasechko.jarvis`.
   - Храни `.p8` безопасно (менеджер паролей / OneCLI vault, НЕ в git).
3. Дай мне: Key ID + содержимое `.p8` (или залей на VDS в `.env`). Team ID и bundle id я знаю.

### [ТЫ] VDS `.env` (или дам команду)
```
IOS_APNS_KEY_ID=<key id>
IOS_APNS_TEAM_ID=24Z6S27D7U
IOS_APNS_BUNDLE_ID=dev.vasechko.jarvis
IOS_APNS_KEY=<содержимое .p8, одной строкой или путь>
```

### [Я] код
- iOS: добавить `aps-environment` в entitlements; `registerForRemoteNotifications` в AppDelegate;
  device token → отправлять хосту в auth-envelope (рядом с версией). Bump версии.
- Host: APNs-sender модуль (JWT из `.p8`, HTTP/2 на `api.push.apple.com`), потребляющий `IOS_APNS_*`.
  Слать **silent push** (`content-available:1`) на проактивные сообщения → телефон просыпается → drain очереди.
  `PendingNotifications` / BGTask `pending-pull` остаются **fallback**, не primary.

⚠️ **Ключевой гоча — окружения APNs:**
TestFlight/App Store-билды используют **production** APNs (`api.push.apple.com`), а прямой запуск из Xcode — **development** (`api.sandbox.push.apple.com`).
Один и тот же `.p8` работает для обоих, но host-sender должен слать в ПРАВИЛЬНЫЙ шлюз. У Лены билд из TestFlight = production.
Отправка не в тот шлюз = тишина без ошибки. Заложу переключатель в host-sender.

✅ Выход P2: проактивные сообщения долетают надёжно, без зависимости от непредсказуемого iOS bg-wake. Закрывает сагу билдов 70–78.

---

## P3+ — фичи поверх push (по плану улучшений)

Каждая = capability на портале + entitlement + код. Делаем по одной, каждая = свой бамп версии + TestFlight-билд.

| Фаза | Портал-capability (ТЫ) | Entitlement / Info.plist (Я) | Что даёт |
|------|------------------------|------------------------------|----------|
| Live Activities / Dynamic Island | — (только push token) | `NSSupportsLiveActivities=YES` + Widget-extension таргет | Тренировка-раннер на локскрине/острове |
| Rich notifications | App Groups | App Group + Notification Service Extension таргет | Картинки в push (позинг-референсы, workout-gif, Сводка) |
| Time Sensitive | — | `interruptionLevel=.timeSensitive` | Тревоги Greg пробивают Focus/DND |
| Critical Alerts | **заявка в Apple** (спец-разрешение) | critical-alerts entitlement | Truly-critical здоровье звенит всегда |
| Widgets (home/lock/Control Center) | App Groups (тот же) | Widget-extension (общий с Live Activity) | Кольца здоровья / Сводка / след. тренировка |
| Universal links | Associated Domains | `applinks:vasechko.dev` + `apple-app-site-association` на домене | https-диплинки вместо custom-scheme |
| watchOS | Watch App ID + push | complications / watch Live Activity | Кольца и быстрый ответ с запястья |

---

## Чеклист «ничего не забыть»

- [ ] Apple ID: 2FA включена
- [ ] Enroll Individual, $99 оплачено, карта прошла
- [ ] Team id после активации = `24Z6S27D7U` (иначе обновить `project.yml` × 5 таргетов)
- [ ] App ID `dev.vasechko.jarvis` зарегистрирован (Explicit)
- [ ] Watch App ID `dev.vasechko.jarvis.watch` — либо зарегистрён, либо watch временно исключён из первого архива
- [ ] `ITSAppUsesNonExemptEncryption=NO` в Info.plist (убирает вопрос при каждом аплоуде)
- [ ] `CURRENT_PROJECT_VERSION` строго растёт на КАЖДЫЙ аплоуд (нельзя переиспользовать номер; сейчас 91)
- [ ] App Store Connect: запись приложения создана
- [ ] Первый external-билд прошёл Beta App Review (~24 ч)
- [ ] Лена: TestFlight установлен, инвайт принят
- [ ] APNs `.p8` скачан (даётся 1 раз!), Key ID записан, файл в безопасном месте
- [ ] `.env` на VDS заполнен `IOS_APNS_*` реальными значениями
- [ ] Host-sender шлёт в ПРАВИЛЬНЫЙ APNs-шлюз (TestFlight = production)
- [ ] Билды TestFlight перезаливать до истечения 90 дней

---

## Что я НЕ могу сделать за тебя
- Оплатить подписку, пройти enroll (деньги + твой Apple ID).
- Нажать Archive/Distribute в Xcode Organizer первого раза (GUI + интерактивные диалоги подписи/комплаенса).
  → После того как появится App Store Connect API key, следующие аплоуды можно скриптовать (`xcodebuild archive` + upload), уже без GUI.
- Скачать `.p8` и добавить Лену в тестеры (твой аккаунт).

Всё остальное (entitlements, регистрация APNs, host-sender, версии, xcodegen) — на мне.
