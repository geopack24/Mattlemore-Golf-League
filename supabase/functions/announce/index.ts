// Discord announcer. Called by the database (pg_cron → announce_locked → _discord_post) with
// { tournament_id }. Posts one message: picks as text, every card in play as an image embed
// (card art is decoded from the data URLs stored in the cards table and attached to the message).
// Deploy: supabase Management API, slug "announce", verify_jwt off — auth is the x-announce-key
// header, which must equal the ANNOUNCE_KEY secret (and settings.announce_key in the database).
import { createClient } from "npm:@supabase/supabase-js@2";

type Card = {
  owner: string; target: string | null; name: string; kind: string; effect: string;
  rules: string | null; flavor: string | null; image: string | null; summary: string | null; tier: string | null;
};
const TIER_COLOR: Record<string, number> = { common: 0x8f8f8f, rare: 0x2e5a99, legendary: 0x8b5cf6, mythic: 0xe0691c };   // grey, blue, purple, orange

Deno.serve(async (req) => {
  if (req.headers.get("x-announce-key") !== Deno.env.get("ANNOUNCE_KEY")) {
    return new Response("unauthorized", { status: 401 });
  }
  const { tournament_id } = await req.json().catch(() => ({}));
  if (!tournament_id) return new Response("tournament_id required", { status: 400 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: hook, error: e0 } = await sb.from("settings").select("value").eq("key", "discord_webhook").maybeSingle();
  if (e0) return new Response("settings: " + e0.message, { status: 500 });
  if (!hook?.value) return new Response("no webhook configured", { status: 400 });

  const { data: content, error: e1 } = await sb.rpc("_discord_message", { p_tournament_id: tournament_id });
  if (e1) return new Response("message: " + e1.message, { status: 500 });
  const { data: cards, error: e2 } = await sb.rpc("_discord_cards", { p_tournament_id: tournament_id });
  if (e2) return new Response("cards: " + e2.message, { status: 500 });

  const form = new FormData();
  const embeds = ((cards ?? []) as Card[]).slice(0, 10).map((c, i) => {
    const who = `${c.owner} plays ${c.name}` +
      (c.target ? (c.effect === "fellowship" ? ` with ${c.target}` : ` on ${c.target}`) : "");
    const embed: Record<string, unknown> = { title: who, color: TIER_COLOR[c.tier ?? "common"] ?? 0xc29d52 };
    if (c.image?.startsWith("data:")) {
      const [meta, b64] = c.image.split(",", 2);
      const mime = /data:([^;]+)/.exec(meta)?.[1] ?? "image/jpeg";
      const bytes = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
      const video = mime.startsWith("video/");
      const fname = `card${i}.${video ? (mime.includes("webm") ? "webm" : "mp4") : mime.includes("png") ? "png" : "jpg"}`;
      form.append(`files[${i}]`, new Blob([bytes], { type: mime }), fname);
      if (video) {
        // Discord embeds can't hold a video; the attachment itself plays inline under the message
        embed.description = [c.kind, c.rules, c.flavor ? `*${c.flavor}*` : null, c.summary ? `⚙ ${c.summary}` : null, `🎞 animated art attached below`]
          .filter(Boolean).join("\n");
      } else {
        embed.image = { url: `attachment://${fname}` };
        if (c.summary) embed.footer = { text: c.summary };
      }
    } else {
      embed.description = [c.kind, c.rules, c.flavor ? `*${c.flavor}*` : null, c.summary ? `⚙ ${c.summary}` : null]
        .filter(Boolean).join("\n");
    }
    return embed;
  });

  form.append("payload_json", JSON.stringify({ content: String(content ?? "").slice(0, 1990), username: "The White Stag", embeds }));
  const r = await fetch(hook.value, { method: "POST", body: form });
  const text = await r.text();
  return new Response(r.ok ? "posted" : `discord ${r.status}: ${text}`, { status: r.ok ? 200 : 502 });
});
