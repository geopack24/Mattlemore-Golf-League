// Live scores sync. Called by the database (pg_cron → sync_scores) every 10 minutes while a tournament is
// under way. Pulls ESPN's public PGA leaderboard, matches the event to our schedule by date, and stores the
// whole field in live_scores.field. When the event is final it asks the database to auto-fill winnings.
// Auth: x-announce-key header must equal the ANNOUNCE_KEY secret (same key as the announcer).
import { createClient } from "npm:@supabase/supabase-js@2";

const ESPN = "https://site.web.api.espn.com/apis/site/v2/sports/golf/leaderboard?league=pga";
const norm = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z ]/g, "").replace(/\s+/g, " ").trim();
const toPar = (v: unknown): number | null => {
  if (v == null || v === "" || v === "-") return null;
  if (v === "E") return 0;
  const n = Number(v); return Number.isFinite(n) ? n : null;
};
const day = (d: Date, off: number) => new Date(d.getTime() + off * 864e5).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  if (req.headers.get("x-announce-key") !== Deno.env.get("ANNOUNCE_KEY")) return new Response("unauthorized", { status: 401 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // ESPN's edge rejects some default agents; curl's gets through.
  const r = await fetch(ESPN, { headers: { "User-Agent": "curl/8.4.0", "Accept": "application/json" } });
  if (!r.ok) return new Response("espn " + r.status, { status: 502 });
  const data = await r.json();

  const out: unknown[] = [];
  for (const ev of data.events ?? []) {
    const comp = ev.competitions?.[0]; if (!comp) continue;
    const d = new Date(ev.date);
    const { data: ts, error } = await sb.from("tournaments").select("id,name,start_date").gte("start_date", day(d, -3)).lte("start_date", day(d, 3)).order("start_date");
    if (error) return new Response("tournaments: " + error.message, { status: 500 });
    const t = ts?.[0];
    if (!t) { out.push({ event: ev.name, date: ev.date, matched: null }); continue; }

    // Mid-round, ESPN's `score.displayValue` lags ("E" until the round is posted); the live to-par number
    // lives in statistics[scoreToPar]. `score.value` is total strokes.
    // deno-lint-ignore no-explicit-any
    const stat = (c: any, n: string) => (c.statistics ?? []).find((s: any) => s.name === n);
    // deno-lint-ignore no-explicit-any
    const field = (comp.competitors ?? []).map((c: any) => ({
      name: c.athlete?.displayName ?? "",
      key: norm(c.athlete?.displayName ?? ""),
      pos: c.status?.position?.displayName ?? "",
      posn: Number(c.status?.position?.id) || null,
      score: toPar(stat(c, "scoreToPar")?.value ?? stat(c, "scoreToPar")?.displayValue ?? c.score?.displayValue),
      strokes: Number(c.score?.value) || 0,
      thru: c.status?.displayThru ?? String(c.status?.thru ?? ""),
      state: c.status?.type?.name ?? "",
      earnings: Number(c.earnings) || Number(stat(c, "officialAmount")?.value) || 0,
    }));
    const status = ev.status?.type?.name ?? comp.status?.type?.name ?? "";
    const { error: e2 } = await sb.from("live_scores").upsert({
      tournament_id: t.id, event_id: String(ev.id), event_name: ev.name, status,
      round: comp.status?.period ?? ev.status?.period ?? null, fetched_at: new Date().toISOString(), field,
    });
    if (e2) return new Response("live_scores: " + e2.message, { status: 500 });

    let filled: unknown = null;
    if (status === "STATUS_FINAL") {
      const { data: n } = await sb.rpc("_autofill_winnings", { p_tournament_id: t.id }); filled = n;
      await sb.rpc("_award_packs", { p_tournament_id: t.id });     // booster packs for everyone (no-op if already awarded)
    }
    out.push({ event: ev.name, matched: t.name, tournament_id: t.id, players: field.length, status, filled });
  }
  return Response.json(out);
});
