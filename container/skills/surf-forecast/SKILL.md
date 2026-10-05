---
name: surf-forecast
description: Use when user asks for a surf forecast for a specific break or region (e.g. «прогноз серфинга», «surf forecast», «как там сёрф», «прогноз на завтра»). Pulls wave/wind/tide data from Open-Meteo + surf-forecast.com, scores the morning window for the named breaks, generates a visual chart image and sends it as a photo. Requires location params (lat, lon, shore-facing degrees, break list). If user did not specify a location, check memory for the user's default spot before asking.
---

# surf-forecast

Generic утренний surf-forecast: график волна/ветер/прилив + рейтинг спотов → одно фото.

## Локация с пресетом — один вызов

Пресеты локаций (споты, их приливы, берег, страница приливов) лежат в `presets.json`: `canggu`, `ericeira`. Для них весь скилл — это скрипт:

```bash
node /app/skills/surf-forecast/forecast.cjs [--spot canggu] [--date YYYY-MM-DD]
```

- Без `--spot` скрипт берёт пресет по поясу владельца (`$OWNER_TZ`).
- Без `--date` берёт сегодня, если местное время до 08:00, иначе завтра.
- Скрипт печатает JSON `{ photo, params, summary }`: отправь `photo` через `mcp__nanoclaw__send_photo` — и всё, без текста. Правила рейтинга записаны в шапке `forecast.cjs`, это §2 ниже в точном виде.
- Упал — скажи человеку причину из его ошибки одной строкой, вручную не пересчитывай.

Голую команду `/surf` раннер отвечает этим же скриптом без тебя. В следующем ходе у тебя будет `<served command="/surf">` со сводкой. Последний прогноз со всеми цифрами лежит в `/workspace/agent/scratch/surf_last.json`: на вопросы по картинке («почему Echo жёлтый?») отвечай по нему.

## Локация без пресета — шаги 0–4

Проходи шаги по порядку и не заменяй источник или шаг своим вариантом. Если шаг не получается, скажи об этом, а не обходи его. Новую локацию, куда человек будет ездить регулярно, предложи добавить в пресеты.

## 0. Собрать параметры

Перед запуском skill нужны:

| Параметр | Что | Источник |
|---|---|---|
| `lat`, `lon` | координаты ближайшей waypoint моря | пользователь, profile/memories, или geocode |
| `tz` | таймзона (`Asia/Makassar` для Бали, `Europe/Lisbon` для Эрисейры, итд) | по локации |
| `shore_facing_deg` | в какую сторону смотрит берег (для оффшор-калькуляции) | 270° = запад (Кангу), 220° = ЮЗ (Эрисейра), итд |
| `breaks[]` | список спотов `{name, type: "reef" \| "beach" \| "point", min_period_s, min_swell_m, ideal_tide_m: [lo, hi]}` | preset или вопрос |
| `tide_url` | страница приливов на surf-forecast.com | `https://www.surf-forecast.com/breaks/<NAME>/tides/latest` |
| `swell_url` | страница свелла на surf-forecast.com (опц.) | `https://www.surf-forecast.com/breaks/<NAME>/forecasts/latest/six_day` |
| `date` | YYYY-MM-DD | сегодня, или «завтра», или явная |
| `window_hours` | часовое окно для анализа | `[5, 9]` по умолчанию (утро) |

**Если параметров нет:** сначала смотри в memory (`memories/self/profile.md` — «default surf location» или подобное). Если и там пусто — спроси у пользователя одним вопросом, не дроби.

## 1. Получить данные (4 вызова параллельно)

**Волна (Open-Meteo Marine):**
`https://marine-api.open-meteo.com/v1/marine?latitude={lat}&longitude={lon}&hourly=wave_height,wave_period&timezone={tz}&start_date={date}&end_date={date}`

**Ветер (Open-Meteo Forecast):**
`https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&hourly=wind_speed_10m,wind_direction_10m&timezone={tz}&start_date={date}&end_date={date}`

**Приливы — только скриптом, руками страницу не разбирать:**
```bash
node /app/skills/surf-forecast/tides.cjs "{tide_url}" {date}
```
Отдаёт JSON: `hourly` (`[{h, v}]` на каждый час, метры над нулём глубин — та же шкала, что `ideal_tide_m`), `extremes` (полная/малая вода с временем), а также готовые для рендера `tidePoints`, `tideMarkers` и `tideRange`.

Open-Meteo `sea_level_height_msl` для рейтинга **не годится**: это уровень относительно среднего моря, он уходит в минус, а пороги спотов абсолютные (2026-10-04 так получились неверные рейтинги). Только если `tides.cjs` упал, бери его с поправкой `msl_offset_m` из пресета. Совпадение с таблицей обычно ±0.2 м, бывает до 0.4, поэтому:
- в `sources` пиши «прилив ≈ Open-Meteo»;
- на границе диапазона зелёный не ставь.

**Кросс-чек свелла (необязательно):** `{swell_url}` — высота, период, направление dawn/morning для нужной даты.

## 2. Анализ утреннего окна

**Часы окна:** `window_hours[0]..window_hours[1]` (по умолчанию 05–09).

**Направление ветра → метка:**
0–22°: N | 23–67°: NE | 68–112°: E | 113–157°: SE | 158–202°: S | 203–247°: SW | 248–292°: W | 293–337°: NW

**Оффшор-зона:** ветер из направления противоположного `shore_facing_deg` ±67.5°. Пример: `shore_facing_deg=270` (запад) → оффшор когда ветер дует с востока (90°), т.е. направление ветра 22°–157° → оффшор/кросс-оффшор → зелёный бар. Иначе онshore → синий.

**Энергия (H²×T):**
<8 → 1 точка | 8–18 → 2 | 18–28 → 3 | 28–40 → 4 | >40 → 5

**Рейтинг спотов** (по середине окна, прилив из `hourly` + период):

Для каждого `break` в `breaks[]`:
- зелёный если `period >= min_period_s` И `tide` внутри `ideal_tide_m`
- жёлтый если одно условие нарушено в граничном диапазоне (период чуть ниже, прилив в ±0.3 м от границы)
- серый/красный если оба нарушены или прилив <0.5 м (риф) / волна <0.5 м

`type=beach` → больше толерантности к приливу. `type=reef` → жёстче по min_period_s и tide. `type=point` → длинная волна, фокус на period.

**Лучшее окно:** часы с оффшор ветром + средний/растущий прилив.

## 3. Собрать JSON-параметры для рендера

Renderer уже ship-аится со skill: `/app/skills/surf-forecast/render.cjs`. Скрипт **не** редактируется — все данные передаются через JSON. Никаких per-call `surf_DDmon.js` копий больше не нужно. Расширение `.cjs` обязательно — host-репо имеет `"type": "module"` в `package.json`, и `.js` будет трактоваться как ESM.

Сформируй JSON со следующей структурой и сохрани его во временный файл (например `/workspace/agent/surf_params.json` — перезаписывается каждый раз, не плодим артефакты):

```json
{
  "title":        "<ЛОКАЦИЯ ВЕРХНЕМ РЕГИСТРЕ> · D МЕСЯЦ · УТРО",
  "byline":       "by Jarvis",
  "tidePoints":   [{ "h": -7.5, "v": 0.2 }, { "h": 4.05, "v": 0.82 }, ...],
  "tideRange":    [-0.1, 2.7],
  "tideMarkers":  [{ "h": 4.05, "v": 0.82, "t": "04:03", "val": "0.8 м", "above": false }, ...],
  "bestWindow":   { "startH": 6.0, "endH": 7.5, "label": "лучшее окно" },
  "waveHours":    [5, 6, 7, 8, 9],
  "waveH":        [0.98, 0.98, 0.98, 0.98, 0.96],
  "windSpeed":    [10.6, 10.7, 11.3, 10.3, 10.0],
  "windDir":      ["NE", "NE", "NE", "NE", "NE"],
  "windOffshore": [true, true, true, true, true],
  "waveFooter":   "период: 11 с  ·  NE кросс-оффшор всё утро",
  "spots": [
    { "name": "Batu Bolong", "rating": "green",  "h": "1.0 м", "p": "11 с", "hm": 0.98, "t": 11, "note": "..." }
  ],
  "footer":  "лучшее окно  06:00 – 07:30  ·  BB/Per до 08:30",
  "sources": "Open-Meteo · surf-forecast.com"
}
```

**Поля:**
- `tidePoints[]`, `tideMarkers[]`, `tideRange` — дословно из вывода `tides.cjs` (подписи полной и малой воды уже размещены так, что не обрезаются)
- `windOffshore[]` — рассчитан **тобой** по `shore_facing_deg` из параметров локации (см. §2). Renderer не пересчитывает направление, он только красит.
- `rating` спота: `green` | `yellow` | `red`
- `hm`, `t` в spot — для расчёта энергии (H²×T → 1–5 точек)

**Что помещается на холст:**
- `spots` — ровно споты пресета, не больше трёх. Четвёртая карточка ещё влезает впритык, а пятая уходит за низ и уносит с собой итоговую строку. Рабочие приливы по спотам из памяти уточняют рейтинг этих трёх. Другие споты из памяти карточек не добавляют.
- `footer` — до 45 символов. Он делит строку с `sources`, более длинный наезжает на них.
- `note` — до 60 символов.

## 4. Отрендерить и отправить

Renderer требует `@napi-rs/canvas`. Он встроен в образ агента (установлен в `/node_modules`), поэтому `require('@napi-rs/canvas')` разрешается из любого скрипта без установки в workspace. (Старым контейнерам, поднятым до пересборки образа, ещё нужна workspace-копия — она резолвится через `NODE_PATH` ниже; новый спавн её не требует.)

Запуск:
```bash
NODE_PATH=/workspace/agent/node_modules \
  node /app/skills/surf-forecast/render.cjs \
  /workspace/agent/surf_params.json \
  /workspace/agent/surf_<slug>_<DDmon>.jpg
```

`NODE_PATH` нужен потому что `render.cjs` живёт в RO-mount `/app/skills/` где нет своих `node_modules` — без него `require('@napi-rs/canvas')` не разрешится.

Затем: `mcp__nanoclaw__send_photo({ path: "/workspace/agent/surf_<slug>_<DDmon>.jpg" })`. Картинка встаёт прямо в чат и в iOS-приложении, и в Telegram. Пересобранную после правки шли так же.

**Только фото. Никакого текста до или после.**

## Пресеты

Пресеты и их формат — в `presets.json`, рядом со скиллом:
- `breaks[].ideal_tide_m: [низ, верх]` — рабочий прилив спота в метрах над нулём глубин; `верх` может быть `null`, тогда высокий прилив спот не портит;
- `min_period_s`, `min_swell_m` — порог периода и высоты;
- `msl_offset_m` — поправка для запасного Open-Meteo.

Для локации без пресета собери те же поля (шаг 0).
