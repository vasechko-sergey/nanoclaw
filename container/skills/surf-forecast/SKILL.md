---
name: surf-forecast
description: Use when user asks for a surf forecast for a specific break or region (e.g. «прогноз серфинга», «surf forecast», «как там сёрф», «прогноз на завтра»). Pulls wave/wind/tide data from Open-Meteo + surf-forecast.com, scores the morning window for the named breaks, generates a visual chart image and sends it as a photo. Requires location params (lat, lon, shore-facing degrees, break list). If user did not specify a location, check memory for the user's default spot before asking.
---

# surf-forecast

Generic утренний surf-forecast: график волна/ветер/прилив + рейтинг спотов → одно фото. Локация не зашита — передаётся параметрами.

## 0. Собрать параметры

Перед запуском skill нужны:

| Параметр | Что | Источник |
|---|---|---|
| `lat`, `lon` | координаты ближайшей waypoint моря | пользователь, profile/memories, или geocode |
| `tz` | таймзона (`Asia/Makassar` для Бали, `Europe/Lisbon` для Эрисейры, итд) | по локации |
| `shore_facing_deg` | в какую сторону смотрит берег (для оффшор-калькуляции) | 270° = запад (Кангу), 220° = ЮЗ (Эрисейра), итд |
| `breaks[]` | список спотов `{name, type: "reef" \| "beach" \| "point", min_period_s, min_swell_m, ideal_tide_m: [lo, hi]}` | preset или вопрос |
| `tide_url` | страница приливов на surf-forecast.com (опц.) | `https://www.surf-forecast.com/breaks/<NAME>/tides/latest` |
| `swell_url` | страница свелла на surf-forecast.com (опц.) | `https://www.surf-forecast.com/breaks/<NAME>/forecasts/latest/six_day` |
| `date` | YYYY-MM-DD | сегодня, или «завтра», или явная |
| `window_hours` | часовое окно для анализа | `[5, 9]` по умолчанию (утро) |

**Если параметров нет:** сначала смотри в memory (`memories/self/profile.md` — «default surf location» или подобное). Если и там пусто — спроси у пользователя одним вопросом, не дроби.

## 1. Получить данные (4 вызова параллельно)

**Волна (Open-Meteo Marine):**
`https://marine-api.open-meteo.com/v1/marine?latitude={lat}&longitude={lon}&hourly=wave_height,wave_period&timezone={tz}&start_date={date}&end_date={date}`

**Ветер (Open-Meteo Forecast):**
`https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&hourly=wind_speed_10m,wind_direction_10m&timezone={tz}&start_date={date}&end_date={date}`

**Приливы:** `{tide_url}` — извлечь high/low времена и значения для нужной даты.
Sanity: high обычно >1.5 м, low <1.0 м. Если метки кажутся перепутанными — проверять по значению.

**Кросс-чек свелла:** `{swell_url}` — высота, период, направление dawn/morning для нужной даты.

Если `tide_url` или `swell_url` не задан — пропусти этот источник, используй только Open-Meteo (приливы Open-Meteo тоже отдаёт на marine endpoint — добавь `tide_height` в hourly).

## 2. Анализ утреннего окна

**Часы окна:** `window_hours[0]..window_hours[1]` (по умолчанию 05–09).

**Направление ветра → метка:**
0–22°: N | 23–67°: NE | 68–112°: E | 113–157°: SE | 158–202°: S | 203–247°: SW | 248–292°: W | 293–337°: NW

**Оффшор-зона:** ветер из направления противоположного `shore_facing_deg` ±67.5°. Пример: `shore_facing_deg=270` (запад) → оффшор когда ветер дует с востока (90°), т.е. направление ветра 22°–157° → оффшор/кросс-оффшор → зелёный бар. Иначе онshore → синий.

**Энергия (H²×T):**
<8 → 1 точка | 8–18 → 2 | 18–28 → 3 | 28–40 → 4 | >40 → 5

**Рейтинг спотов** (по середине окна, прилив + период):

Для каждого `break` в `breaks[]`:
- зелёный если `period >= min_period_s` И `tide` внутри `ideal_tide_m`
- жёлтый если одно условие нарушено в граничном диапазоне (период чуть ниже, прилив в ±0.3 м от границы)
- серый/красный если оба нарушены или прилив <0.5 м (риф) / волна <0.5 м

`type=beach` → больше толерантности к приливу. `type=reef` → жёстче по min_period_s и tide. `type=point` → длинная волна, фокус на period.

**Лучшее окно:** часы с оффшор ветром + средний/растущий прилив.

## 3. Сгенерировать canvas-скрипт

Файл: `/workspace/agent/surf_<slug>_<DDmon>.js` (slug — короткое имя локации, `DDmon` — `01jun`).

Шаблон: скопировать последний `surf_*.js` из `/workspace/agent/` и обновить:

- Заголовок: `'<ЛОКАЦИЯ ВЕРХНЕМ РЕГИСТРЕ> · D МЕСЯЦ · УТРО'`
- `tidePoints[]`: данные приливов + 2 экстраполированные точки по краям для гладкого сплайна
- `waveH[]`: Open-Meteo wave_height часы окна
- `windSpeed[]`: Open-Meteo wind_speed_10m часы окна
- `windDir[]`: метки направления из wind_direction_10m
- `spots[]`: `{name, hm, t, color, note}` для каждого break
- Строка периода в footer секции волны
- Строка лучшего окна в footer картинки
- Выход: `/workspace/agent/surf_<slug>_<DDmon>.jpg`

Если в `/workspace/agent/` ещё нет surf-скрипта — собрать с нуля (canvas + node-canvas, 1200×1800 px, секции: header, tide curve, wind bars, wave bars, spot rating cards).

Масштаб `ty()`: подобрать margin/range под амплитуду прилива, кривая ~80% высоты графика.

## 4. Сгенерировать и отправить

```bash
node /workspace/agent/surf_<slug>_<DDmon>.js
```

Затем: `mcp__nanoclaw__send_photo({ path: "/workspace/agent/surf_<slug>_<DDmon>.jpg" })`

**Только фото. Никакого текста до или после.**

## Примеры пресетов

**Кангу (Бали):**
```js
{
  lat: -8.65, lon: 115.13,
  tz: "Asia/Makassar",
  shore_facing_deg: 270,
  tide_url: "https://www.surf-forecast.com/breaks/Canggu/tides/latest",
  swell_url: "https://www.surf-forecast.com/breaks/Canggu/forecasts/latest/six_day",
  breaks: [
    { name: "Batu Bolong",  type: "reef",  min_period_s: 10, min_swell_m: 0.8, ideal_tide_m: [1.0, 2.0] },
    { name: "Echo Beach",   type: "reef",  min_period_s: 9,  min_swell_m: 1.2, ideal_tide_m: [1.0, 2.0] },
    { name: "Pererenan",    type: "reef",  min_period_s: 10, min_swell_m: 0.8, ideal_tide_m: [1.0, 2.0] }
  ]
}
```

**Эрисейра (Португалия):**
```js
{
  lat: 38.96, lon: -9.42,
  tz: "Europe/Lisbon",
  shore_facing_deg: 250,
  tide_url: "https://www.surf-forecast.com/breaks/Ericeira/tides/latest",
  swell_url: "https://www.surf-forecast.com/breaks/Ericeira/forecasts/latest/six_day",
  breaks: [
    { name: "Ribeira d'Ilhas", type: "reef", min_period_s: 11, min_swell_m: 1.0, ideal_tide_m: [1.0, 3.0] },
    { name: "Coxos",           type: "reef", min_period_s: 12, min_swell_m: 1.5, ideal_tide_m: [1.5, 3.0] }
  ]
}
```
