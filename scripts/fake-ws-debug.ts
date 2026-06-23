/**
 * Throwaway debug harness: a local v2 WS server the iOS app connects to so we
 * can watch what the REAL app does with a workout_plan, end to end.
 *
 *   pnpm exec tsx scripts/fake-ws-debug.ts
 *   SIMCTL_CHILD_JARVIS_WS_URL=ws://127.0.0.1:8765 xcrun simctl launch <udid> com.vasechko.jarvis
 *
 * On auth it sends auth_ok, then (≈400ms later) pushes Payne's exact seq-405
 * workout_plan followed by a chat text — mirroring production. Every frame the
 * app sends back (auth, ack, delivered, message) is logged, so we see whether
 * the app receives + delivers-acks the plan.
 */
import { WebSocketServer } from 'ws';
import { randomUUID } from 'node:crypto';

const PORT = 8765;

// Payne's real seq-405 payload (8 exercises, 8-entry image_manifest).
const PLAN_PAYLOAD = {
  workout_id: '2026-06-23',
  plan_json: {
    day_name: 'Верх А',
    week: 2,
    week_label: 'Средняя',
    exercises: [
      { slug: 'hodba-na-begovoy-dorozhke', name_ru: 'Ходьба на беговой дорожке', target_sets: null, target_reps: '', reps_in_reserve: null, rest_seconds: 0, duration_seconds: 300, notes: 'разминка' },
      { slug: 'zhim-shtangi-lezha-shirokim-hvatom', name_ru: 'Жим штанги лежа широким хватом', target_sets: 4, target_reps: '5-6', reps_in_reserve: 2, rest_seconds: 180, weight_kg_target: 66.25 },
      { slug: 'tyaga-bloka-k-poyasu', name_ru: 'Тяга блока к поясу', target_sets: 4, target_reps: '5-6', reps_in_reserve: 2, rest_seconds: 180, weight_kg_target: 66.25 },
      { slug: 'zhim-ganteley-na-naklonnoy-skame', name_ru: 'Жим гантелей на наклонной скамье', target_sets: 3, target_reps: '8-10', reps_in_reserve: 2, rest_seconds: 120, weight_kg_target: 25 },
      { slug: 'sgibanie-ruk-v-bloke', name_ru: 'Сгибание рук в блоке', target_sets: 3, target_reps: '10-12', reps_in_reserve: 2, rest_seconds: 90, weight_kg_target: 36.25 },
      { slug: 'razgibanie-v-bloke', name_ru: 'Разгибание в блоке', target_sets: 3, target_reps: '10-12', reps_in_reserve: 2, rest_seconds: 90, weight_kg_target: 32.5 },
      { slug: 'obratnaya-babochka', name_ru: 'Обратная бабочка', target_sets: 3, target_reps: '12-15', reps_in_reserve: 2, rest_seconds: 90, weight_kg_target: 41.25 },
      { slug: 'zhim-lezha-v-trenazhere-hammer', name_ru: 'Жим лежа в тренажере Хаммер', target_sets: 2, target_reps: '10-12', reps_in_reserve: 2, rest_seconds: 90, weight_kg_target: 46.25, notes: 'финиш на грудь' },
    ],
  },
  image_manifest: [
    { slug: 'hodba-na-begovoy-dorozhke', sha256: 'ae672aad02d165e94103e1dccba746b786ff33a72e0e2ca92e8b7964e3144e87', url: '' },
    { slug: 'zhim-shtangi-lezha-shirokim-hvatom', sha256: 'f61e6adbe6501eca6b82d02734430260ed348d6e55030eab1371f4e7958b22c5', url: '' },
  ],
};

// Valid 1x1 PNG — UIImage(contentsOfFile:) detects the format regardless of the
// .jpg extension the cache writes, so this renders as a real (tiny) image.
const PNG_1x1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

/** The sha256 the manifest declares for a slug (so the blob lands where the app's resolver looks). */
function manifestSha(slug: string): string {
  const e = (PLAN_PAYLOAD.image_manifest as Array<{ slug: string; sha256: string }>).find((m) => m.slug === slug);
  return e?.sha256 ?? 'swapsha';
}

function ts(): string {
  return new Date().toISOString();
}
function log(...a: unknown[]): void {
  console.log(`[${ts()}]`, ...a);
}

const wss = new WebSocketServer({ port: PORT });
log(`fake ws listening on ws://127.0.0.1:${PORT}`);

wss.on('connection', (ws) => {
  log('🔌 app connected');

  ws.on('message', (raw) => {
    let env: any;
    try {
      env = JSON.parse(raw.toString());
    } catch {
      log('⚠️ non-JSON frame', raw.toString().slice(0, 80));
      return;
    }

    // Log every frame the app sends.
    if (env.type === 'delivered' || env.type === 'read') {
      log(`⬅️  ${env.type}  ids=${JSON.stringify(env.payload?.ids)}`);
      return;
    }
    if (env.type === 'ack') {
      log(`⬅️  ack id=${env.payload?.id}`);
      return;
    }
    log(`⬅️  ${env.type}` + (env.type === 'message' ? `  text=${JSON.stringify(env.payload?.text)} agent=${env.payload?.agent_id}` : ''));

    if (env.type === 'auth') {
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'auth_ok', id: randomUUID(), seq: null, ts: ts(),
        payload: { last_seen_outbound_seq: 0, server_time: ts() },
      }));
      log('➡️  auth_ok');

      // Simulate Payne: push the workout_plan, then a chat text right after
      // (the exact production sequence that stranded the card on prod).
      setTimeout(() => {
        const planId = randomUUID();
        ws.send(JSON.stringify({
          v: 2, kind: 'control', type: 'workout_plan', id: planId, seq: 1, ts: ts(),
          payload: PLAN_PAYLOAD,
        }));
        log(`➡️  workout_plan  id=${planId} seq=1`);

        ws.send(JSON.stringify({
          v: 2, kind: 'data', type: 'message', id: randomUUID(), seq: 2, ts: ts(),
          payload: { thread_id: 'ios:default', text: 'Отправил план тренировки.', agent_id: 'payne' },
        }));
        log('➡️  message "Отправил план тренировки." seq=2');
      }, 400);
    }

    if (env.type === 'image_request') {
      const slug = env.payload?.slug;
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'image_blob', id: randomUUID(), seq: null, ts: ts(),
        payload: { slug, sha256: manifestSha(slug), base64: PNG_1x1 },
      }));
      log(`➡️  image_blob slug=${slug}`);
    }

    if (env.type === 'exercise_swap_request') {
      const wid = env.payload?.workout_id;
      const slug = env.payload?.exercise_slug;
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'exercise_swap_options', id: randomUUID(), seq: null, ts: ts(),
        payload: {
          workout_id: wid, original_slug: slug, alternatives: [
            { slug: 'otzhimaniya-na-brusyah', why: 'свой вес, щадит плечо' },
            { slug: 'zhim-v-trenazhere', why: 'фиксированная траектория' },
          ],
        },
      }));
      log(`➡️  exercise_swap_options for ${slug}`);
    }

    if (env.type === 'exercise_swap_confirm') {
      const wid = env.payload?.workout_id;
      const orig = env.payload?.original_slug;
      const neu = env.payload?.new_slug;
      const updated = JSON.parse(JSON.stringify(PLAN_PAYLOAD));
      updated.workout_id = wid;
      const i = updated.plan_json.exercises.findIndex((e: { slug: string }) => e.slug === orig);
      if (i >= 0) {
        updated.plan_json.exercises[i] = {
          slug: neu, name_ru: 'Заменённое упражнение', target_sets: 3, target_reps: '8-10',
          reps_in_reserve: 2, rest_seconds: 120, weight_kg_target: 25,
        };
      }
      updated.image_manifest = [...updated.image_manifest, { slug: neu, sha256: 'swapsha', url: '' }];
      ws.send(JSON.stringify({
        v: 2, kind: 'control', type: 'workout_plan', id: randomUUID(), seq: 3, ts: ts(), payload: updated,
      }));
      log(`➡️  workout_plan (updated after swap) wid=${wid} new=${neu}`);
    }
  });

  ws.on('close', () => log('🔌 app disconnected'));
  ws.on('error', (e) => log('⚠️ ws error', String(e)));
});
