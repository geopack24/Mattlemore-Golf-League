# Fantasy Golf League site

Static one-page site (GitHub Pages) + Supabase (Postgres) backend for GP's fantasy golf league.

## Files
- `index.html` — the entire site: HTML, CSS and vanilla JS in one file. Loads `@supabase/supabase-js@2` UMD from jsDelivr and `config.js`.
- `config.js` — `window.LEAGUE_CONFIG = { SUPABASE_URL, SUPABASE_ANON_KEY, LEAGUE_NAME }`. Anon key is public by design.
- `supabase/schema.sql` — idempotent; run in the Supabase SQL editor. Tables, RLS, all RPC functions, 2027 schedule seed (29 events, 2026 purses as placeholders), golfer autocomplete seed, commissioner PIN seed (`1234` placeholder — GP must change).
- `README.md` — setup walkthrough for GP (non-developer).

## League rules the code enforces (server-side, in schema.sql)
- One golfer per owner per tournament. Owners may change their pick until `tournaments.lock_at`.
- **No mulligans**: a golfer can be used once per season per owner. Matching is on `golfer_key` (lower-cased, whitespace-collapsed).
- Before lock: everyone can see *who* has picked, never *which* golfer. After lock: picks revealed and frozen. `tournament_board()` does the masking.
- Scoring: `picks.winnings` (golfer's actual prize money, entered by commissioner) × `tournaments.multiplier`. Season total = standings.
- Default lock: Thursday 07:00 America/New_York. Event selection/multipliers follow GP's "Fantasy Golf 2026" Google Sheet, applied to the 2027 PGA Tour schedule (announced Aug 26 2026). The 2026 season was over before launch, so the site ships on season 2027.
- Zurich Classic (two-man team event) is deliberately a normal single pick at 2× — GP's call, Sep 2026.
- Autocomplete (`list_golfers()`) = seed table ∪ golfers from locked tournaments. `submit_pick` must NOT write to `golfers` — that leaked pre-lock picks.

## Security model — keep it this way
- The browser holds only the anon key. **All tables have RLS on and zero grants to anon/authenticated.** Nothing is readable or writable directly.
- Every read/write goes through `security definer` functions; only those are granted to `anon`. Owner functions take `(p_owner, p_pin)` and call `_owner_id()`; commissioner functions take `p_admin_pin` and call `_check_admin()`. PINs are hashed with pgcrypto `crypt()`.
- When adding a function: `security definer set search_path = public`, add it to the `grant execute ... to anon, authenticated` list at the end of the schema, and never expose an unlocked golfer name from it.
- Frontend calls functions with `sb.rpc(name, {p_...})` via the `rpc()` helper in index.html; errors thrown there surface as user-facing messages.

## Frontend structure (index.html)
Views toggled by `show(view)`: `board` (This Week: pick form + who's-in), `standings`, `mine` (My Picks + change PIN), `season` (grid), `admin` (Commissioner: enter winnings, owners, schedule, settings). Shared data (tournaments, owners, `season` via `current_season()`) loaded once in `loadShared()`; an empty schedule shows a pointer to Commissioner → Schedule instead of a blank board. Owner name/PIN are kept in `sessionStorage` for convenience only.

## Testing
No test framework checked in. Previous verification: schema loaded into local Postgres 16 with roles `anon`/`authenticated` created first, functions exercised as `set role anon`, and a Playwright script driving the page against a small mock of PostgREST (`POST /rest/v1/rpc/<fn>`). Reproduce that approach for changes to rules or RPCs; a real Supabase project also works if GP shares the URL/anon key (test data only).

## Open questions for GP
- Owner names live in sheet tabs not yet shared (add via Commissioner tab or `admin_set_owner`).
- 2027 purses: seeded with 2026 values; update when the Tour publishes them (cosmetic only).
- Whether to add AT&T Pebble Beach (Feb 4 2027, Signature) — excluded to match the 2026 sheet.
