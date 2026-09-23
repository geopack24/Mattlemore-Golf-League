-- =====================================================================
--  Fantasy Golf League — Supabase schema
--  Run this whole file once in Supabase: SQL Editor -> New query -> Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tables ----------------------------------------------------

create table if not exists owners (
  id          serial primary key,
  name        text unique not null,
  pin_hash    text not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists tournaments (
  id          serial primary key,
  season      int  not null,
  sort_order  int  not null,
  name        text not null,
  start_date  date not null,
  lock_at     timestamptz not null,          -- picks hidden & frozen from here
  prize_pool  numeric not null,
  multiplier  numeric not null default 1,
  unique (season, name)
);

create table if not exists picks (
  id            serial primary key,
  owner_id      int  not null references owners(id) on delete cascade,
  tournament_id int  not null references tournaments(id) on delete cascade,
  golfer        text not null,
  golfer_key    text generated always as (lower(trim(regexp_replace(golfer, '\s+', ' ', 'g')))) stored,
  winnings      numeric not null default 0,   -- golfer's actual prize money, entered by commissioner
  submitted_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (owner_id, tournament_id)
);

create table if not exists golfers (            -- autocomplete list only; free text is allowed
  name text primary key
);

create table if not exists settings (
  key   text primary key,
  value text not null
);

create table if not exists card_library (        -- the pool of card designs, kept across seasons
  id          serial primary key,
  name        text not null,
  kind        text not null default 'Enchantment',
  effect      text not null check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom','fellowship','curse','strokes')),
  params      jsonb not null default '{}',
  rules       text,
  flavor      text,
  image       text,
  retired     boolean not null default false,     -- hidden from the deal list, never deleted
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists cards (               -- commissioner's TCG-style enchantments, dealt to owners
  id              serial primary key,
  owner_id        int  not null references owners(id) on delete cascade,
  name            text not null,
  kind            text not null default 'Enchantment',      -- printed type line
  effect          text not null check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom','fellowship','curse','strokes')),
  params          jsonb not null default '{}',              -- multiply {"x":2} · flat {"amount":500000} · steal {"pct":25}
  rules           text,
  flavor          text,
  image           text,                                     -- data URL (resized in the browser) or https URL
  status          text not null default 'held' check (status in ('held','played','revoked')),
  tournament_id   int references tournaments(id) on delete set null,   -- where it was played
  target_owner_id int references owners(id) on delete set null,        -- duel/steal/swap opponent
  dealt_at        timestamptz not null default now(),
  played_at       timestamptz
);
drop index if exists cards_one_in_play_per_week;   -- was one card per owner per week; the limit is now 3 (enforced in play_card, see RULES.md)
alter table cards add column if not exists library_id int references card_library(id) on delete set null;
-- commissioner's manual adjustment for cards/rulings the engine can't compute (applied after cards)
alter table picks add column if not exists adjust numeric not null default 0;
alter table picks add column if not exists adjust_note text;
alter table tournaments add column if not exists announced_at timestamptz;   -- Discord lock announcement sent
-- full_card: the image IS the finished card (title/text baked in) — show it as-is, no frame
alter table cards        add column if not exists full_card boolean not null default false;
alter table card_library add column if not exists full_card boolean not null default false;
-- tier / rarity: common < rare < legendary < mythic (frame look + set-symbol colour + Discord embed colour)
alter table card_library add column if not exists tier text not null default 'common' check (tier in ('common','rare','legendary','mythic'));
alter table cards        add column if not exists tier text not null default 'common' check (tier in ('common','rare','legendary','mythic'));
-- keep the effect lists in step on an existing database
alter table cards        drop constraint if exists cards_effect_check;
alter table cards        add  constraint cards_effect_check check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom','fellowship','curse','strokes'));
alter table card_library drop constraint if exists card_library_effect_check;
alter table card_library add  constraint card_library_effect_check check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom','fellowship','curse','strokes'));

create table if not exists live_scores (          -- ESPN leaderboard snapshot per tournament (written by the scores edge function)
  tournament_id int primary key references tournaments(id) on delete cascade,
  event_id    text,
  event_name  text,
  status      text,                               -- STATUS_SCHEDULED / STATUS_IN_PROGRESS / STATUS_FINAL ...
  round       int,
  fetched_at  timestamptz not null default now(),
  field       jsonb not null default '[]'         -- [{name,key,pos,posn,score,strokes,thru,state,earnings}]
);
alter table picks add column if not exists winnings_source text;    -- 'auto' (from live scores) or 'manual' (commissioner typed it)
alter table card_library add column if not exists exempt_limit boolean not null default false;   -- card text exempts it from the 3-cards-per-tournament cap
alter table cards        add column if not exists exempt_limit boolean not null default false;
-- Tees (Sep 22 2026): every owner has 3 tees per tournament; a card costs 0–3 tees to play (RULES.md)
alter table card_library add column if not exists cost int not null default 0 check (cost between 0 and 3);
alter table card_library add column if not exists max_copies int check (max_copies is null or max_copies >= 1);   -- cap on copies held at once (null = unlimited); RULES.md 18
alter table tournaments add column if not exists is_major boolean not null default false;
alter table card_library add column if not exists review boolean not null default false;   -- drafted by the scorer, not yet reviewed by the commissioner: shown in the library, never dealt   -- the four majors + THE PLAYERS count as majors for all card purposes (RULES.md 19)
alter table cards        add column if not exists cost int not null default 0 check (cost between 0 and 3);
-- Booster packs (Sep 22 2026): one pack of 5 random library cards per owner at the end of every tournament
create table if not exists packs (
  id            serial primary key,
  tournament_id int not null references tournaments(id) on delete cascade,
  owner_id      int not null references owners(id) on delete cascade,
  opened_at     timestamptz not null default now(),
  unique (tournament_id, owner_id)
);
alter table packs enable row level security;
alter table packs add column if not exists revealed_at timestamptz;   -- when the owner opened it on the site (cards stay hidden in My Cards until then)
alter table cards add column if not exists pack_id int references packs(id) on delete set null;   -- set when the card came out of a pack

create table if not exists champions (           -- The White Stag Club: one league champion per season
  season int primary key,
  owner  text not null,                           -- free text: past winners may not be current owners
  note   text,                                    -- e.g. "Rode Scheffler to a Masters payday"
  points numeric
);

-- ---------- Lock everything down ---------------------------------------
-- Browsers only hold the public "anon" key. No table is readable or writable
-- directly; every access goes through the functions below, which enforce
-- PINs, lock times and the no-repeat rule server-side.

alter table owners      enable row level security;
alter table tournaments enable row level security;
alter table picks       enable row level security;
alter table golfers     enable row level security;
alter table settings    enable row level security;
alter table champions   enable row level security;
alter table cards       enable row level security;
alter table card_library enable row level security;
alter table live_scores enable row level security;

revoke all on all tables in schema public from anon, authenticated;
-- the announcer edge function reads with the service role (tables made via the SQL API don't get its default grants)
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- ---------- Helpers ------------------------------------------------------

create or replace function _owner_id(p_owner text, p_pin text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_id int;
begin
  select id into v_id from owners
   where lower(name) = lower(trim(p_owner)) and active
     and pin_hash = crypt(p_pin, pin_hash);
  if v_id is null then
    raise exception 'Wrong name or PIN' using errcode = '28000';
  end if;
  return v_id;
end $$;

create or replace function _check_admin(p_pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  select value into v_hash from settings where key = 'admin_pin_hash';
  if v_hash is null or v_hash <> crypt(p_pin, v_hash) then
    raise exception 'Wrong commissioner PIN' using errcode = '28000';
  end if;
end $$;

create or replace function current_season()
returns int language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select value::int from settings where key = 'current_season'),
                  (select max(season) from tournaments), extract(year from now())::int);
$$;

-- ---------- Scoring engine -------------------------------------------------
-- Points for one tournament = winnings × multiplier, then every card in play
-- that week applied in the order it was played. All views read points from
-- here so cards change the standings automatically.

create or replace function _oname(p_id int) returns text
language sql stable security definer set search_path = public, extensions as $$
  select name from owners where id = p_id;
$$;

create or replace function _note(n jsonb, k text, s text) returns jsonb
language sql immutable as $$
  select n || jsonb_build_object(k, case when n ? k then (n->>k) || ' · ' || s else s end);
$$;

-- "+3 strokes" / "−1 stroke" for stroke-adjustment cards (positive hurts, negative helps).
create or replace function _strokes_txt(x numeric) returns text language sql immutable as $$
  select case when x < 0 then '−' else '+' end || trim(to_char(abs(x), 'FM9999990.##')) || case when abs(x) = 1 then ' stroke' else ' strokes' end;
$$;

create or replace function scored_points(p_tournament_id int)
returns table (o_id int, raw numeric, base_pts numeric, pts numeric, note text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_t  tournaments%rowtype;
  w    jsonb := '{}';    -- owner -> raw winnings
  b    jsonb := '{}';    -- owner -> base points (winnings × multiplier)
  m    jsonb := '{}';    -- owner -> points after cards
  n    jsonb := '{}';    -- owner -> explanation
  sh   int[] := '{}';    -- owners holding a shield this week
  c    record;
  a    text; tg text;
  wa numeric; wb numeric; x numeric; s numeric; tmp numeric;
  k text; v jsonb;
  paired int[] := '{}';  -- fellowship pairs already resolved
  fk text; pk text;
begin
  select * into v_t from tournaments tt where tt.id = p_tournament_id;
  if v_t.id is null then return; end if;

  for c in select p.owner_id as o, p.winnings as wn from picks p where p.tournament_id = p_tournament_id loop
    w := w || jsonb_build_object(c.o::text, c.wn);
    b := b || jsonb_build_object(c.o::text, c.wn * v_t.multiplier);
  end loop;
  m := b;
  -- (commissioner adjustments are applied last, after every card — see the end of this function)

  select coalesce(array_agg(cd.owner_id), '{}') into sh from cards cd
   where cd.tournament_id = p_tournament_id and cd.status = 'played' and cd.effect = 'shield';

  for c in select * from cards cd where cd.tournament_id = p_tournament_id and cd.status = 'played' order by cd.played_at, cd.id loop
    a := c.owner_id::text; tg := c.target_owner_id::text;
    if not (m ? a) then w := w || jsonb_build_object(a, 0); b := b || jsonb_build_object(a, 0); m := m || jsonb_build_object(a, 0); end if;
    if c.target_owner_id is not null and not (m ? tg) then
      w := w || jsonb_build_object(tg, 0); b := b || jsonb_build_object(tg, 0); m := m || jsonb_build_object(tg, 0);
    end if;

    if c.effect in ('duel','steal','swap','curse','strokes') and c.target_owner_id = any(sh) then
      n := _note(n, a, c.name || ': fizzled — ' || _oname(c.target_owner_id) || ' was shielded');
      n := _note(n, tg, 'Shield blocked ' || _oname(c.owner_id) || '''s ' || c.name);
      continue;
    end if;

    case c.effect
      when 'multiply' then
        x := coalesce((c.params->>'x')::numeric, 2);
        m := jsonb_set(m, array[a], to_jsonb((m->>a)::numeric * x));
        n := _note(n, a, c.name || ': ×' || x);
      when 'flat' then
        x := coalesce((c.params->>'amount')::numeric, 0);
        m := jsonb_set(m, array[a], to_jsonb((m->>a)::numeric + x));
        n := _note(n, a, c.name || ': ' || case when x >= 0 then '+' else '−' end || '$' || to_char(abs(x), 'FM999,999,999,990'));
      when 'duel' then
        wa := (w->>a)::numeric; wb := (w->>tg)::numeric;
        if wa > wb then
          m := jsonb_set(m, array[a], to_jsonb((b->>a)::numeric * 2));
          m := jsonb_set(m, array[tg], to_jsonb(0));
          n := _note(n, a,  c.name || ': beat ' || _oname(c.target_owner_id) || ' (×2)');
          n := _note(n, tg, c.name || ': lost to ' || _oname(c.owner_id) || ' (0)');
        elsif wb > wa then
          m := jsonb_set(m, array[tg], to_jsonb((b->>tg)::numeric * 2));
          m := jsonb_set(m, array[a], to_jsonb(0));
          n := _note(n, a,  c.name || ': lost to ' || _oname(c.target_owner_id) || ' (0)');
          n := _note(n, tg, c.name || ': beat ' || _oname(c.owner_id) || ' (×2)');
        else
          n := _note(n, a, c.name || ': tied ' || _oname(c.target_owner_id) || ' — no effect');
        end if;
      when 'steal' then
        x := coalesce((c.params->>'pct')::numeric, 25);
        s := round((m->>tg)::numeric * x / 100);
        m := jsonb_set(m, array[tg], to_jsonb((m->>tg)::numeric - s));
        m := jsonb_set(m, array[a],  to_jsonb((m->>a)::numeric + s));
        n := _note(n, a,  c.name || ': took ' || x || '% from ' || _oname(c.target_owner_id));
        n := _note(n, tg, c.name || ': ' || _oname(c.owner_id) || ' took ' || x || '%');
      when 'swap' then
        tmp := (m->>a)::numeric;
        m := jsonb_set(m, array[a],  to_jsonb((m->>tg)::numeric));
        m := jsonb_set(m, array[tg], to_jsonb(tmp));
        n := _note(n, a,  c.name || ': swapped points with ' || _oname(c.target_owner_id));
        n := _note(n, tg, c.name || ': ' || _oname(c.owner_id) || ' swapped points with you');
      when 'fellowship' then
        -- both partners must play the card on each other; resolved once per pair
        if c.owner_id = any(paired) then
          null;
        elsif not exists (select 1 from cards p2 where p2.tournament_id = p_tournament_id and p2.status = 'played'
                             and p2.effect = 'fellowship' and p2.owner_id = c.target_owner_id and p2.target_owner_id = c.owner_id) then
          n := _note(n, a, c.name || ': fizzled — ' || _oname(c.target_owner_id) || ' did not join');
        else
          paired := paired || c.owner_id || c.target_owner_id;
          x := coalesce((c.params->>'amount')::numeric, 500000);
          if (w->>a)::numeric <= 0 or (w->>tg)::numeric <= 0 then
            m := jsonb_set(m, array[a],  to_jsonb(0));
            m := jsonb_set(m, array[tg], to_jsonb(0));
            n := _note(n, a,  c.name || ': ' || case when (w->>a)::numeric <= 0 then 'you' else _oname(c.target_owner_id) end || ' missed the cut — both get $0');
            n := _note(n, tg, c.name || ': ' || case when (w->>tg)::numeric <= 0 then 'you' else _oname(c.owner_id) end || ' missed the cut — both get $0');
          else
            m := jsonb_set(m, array[a],  to_jsonb((m->>a)::numeric + x));
            m := jsonb_set(m, array[tg], to_jsonb((m->>tg)::numeric + x));
            n := _note(n, a,  c.name || ': +$' || to_char(x, 'FM999,999,999,990') || ' with ' || _oname(c.target_owner_id));
            n := _note(n, tg, c.name || ': +$' || to_char(x, 'FM999,999,999,990') || ' with ' || _oname(c.owner_id));
          end if;
        end if;
      when 'curse' then
        fk := nullif(trim(c.params->>'golfer'), '');
        x  := coalesce((c.params->>'pct')::numeric, 0);
        select p.golfer_key into pk from picks p where p.owner_id = c.target_owner_id and p.tournament_id = p_tournament_id;
        if fk is not null and coalesce(pk, '') <> lower(trim(regexp_replace(fk, '\s+', ' ', 'g'))) then
          m := jsonb_set(m, array[tg], to_jsonb(0));
          n := _note(n, tg, c.name || ': did not pick ' || fk || ' — $0');
          n := _note(n, a,  c.name || ': ' || _oname(c.target_owner_id) || ' defied the stocks ($0)');
        else
          m := jsonb_set(m, array[tg], to_jsonb(round((m->>tg)::numeric * (1 + x / 100))));
          n := _note(n, tg, c.name || ': ' || x || '%' || case when fk is not null then ' (forced ' || fk || ')' else '' end);
          n := _note(n, a,  c.name || ': ' || _oname(c.target_owner_id) || ' took ' || x || '%');
        end if;
      when 'strokes' then
        -- signed: +N adds strokes (hurts), −N removes them (helps). Applied to the live score by live_board().
        x := coalesce((c.params->>'n')::numeric, 1);
        n := _note(n, tg, c.name || ': ' || _strokes_txt(x) || ' on your golfer — applied automatically on the live leaderboard');
        n := _note(n, a,  c.name || ': ' || _strokes_txt(x) || ' on ' || _oname(c.target_owner_id) || '''s golfer');
      when 'shield'   then n := _note(n, a, c.name || ': shielded');
      when 'mulligan' then n := _note(n, a, c.name || ': mulligan');
      else                 n := _note(n, a, c.name || ' (commissioner applies)');
    end case;
  end loop;

  -- commissioner adjustments (In the Stocks rulings, custom cards, corrections) — always last
  for c in select p.owner_id as o, p.adjust as adj, p.adjust_note as an from picks p
            where p.tournament_id = p_tournament_id and p.adjust <> 0 loop
    a := c.o::text;
    if not (m ? a) then m := m || jsonb_build_object(a, 0); w := w || jsonb_build_object(a, 0); b := b || jsonb_build_object(a, 0); end if;
    m := jsonb_set(m, array[a], to_jsonb((m->>a)::numeric + c.adj));
    n := _note(n, a, 'Commissioner: ' || case when c.adj >= 0 then '+' else '−' end || '$' || to_char(abs(c.adj), 'FM999,999,999,990')
                     || case when nullif(trim(c.an), '') is not null then ' (' || trim(c.an) || ')' else '' end);
  end loop;

  for k, v in select * from jsonb_each(m) loop
    o_id := k::int; raw := (w->>k)::numeric; base_pts := (b->>k)::numeric; pts := (m->>k)::numeric; note := n->>k;
    return next;
  end loop;
end $$;

-- ---------- Public read functions ---------------------------------------

create or replace function list_owners()
returns table (name text) language sql stable security definer set search_path = public, extensions as $$
  select name from owners where active order by name;
$$;

drop function if exists list_tournaments(int);   -- return type changed (is_major) — must be dropped before the create below
create or replace function list_tournaments(p_season int default null)
returns table (id int, name text, start_date date, lock_at timestamptz,
               prize_pool numeric, multiplier numeric, locked boolean, season int, is_major boolean)
language sql stable security definer set search_path = public, extensions as $$
  select id, name, start_date, lock_at, prize_pool, multiplier, now() >= lock_at, season, is_major
    from tournaments
   where season = coalesce(p_season, current_season())
   order by sort_order;
$$;

-- Autocomplete: the seeded list plus every golfer from an already-locked
-- tournament. Unlocked picks never appear here, or a new name would give away
-- someone's pick before lock.
create or replace function list_golfers()
returns table (name text) language sql stable security definer set search_path = public, extensions as $$
  select name from golfers
  union
  select p.golfer from picks p join tournaments t on t.id = p.tournament_id where now() >= t.lock_at
  order by 1;
$$;

-- Who has picked for a tournament. Golfer names are NULL until lock time.
-- (drop first: these return types grew a note column in Sep 2026)
drop function if exists tournament_board(int);
drop function if exists admin_upsert_tournament(text, int, int, text, date, timestamptz, numeric, numeric);
drop function if exists season_picks(int);
drop function if exists my_picks(text, text, int);
drop function if exists tournament_cards(int);
drop function if exists my_cards(text, text);
drop function if exists admin_list_library(text);
drop function if exists admin_deal_card(text, text, text, text, text, jsonb, text, text, text);
drop function if exists admin_save_library_card(text, int, text, text, text, jsonb, text, text, text);
drop function if exists admin_save_library_card(text, int, text, text, text, jsonb, text, text, text, boolean);
drop function if exists admin_save_library_card(text, int, text, text, text, jsonb, text, text, text, boolean, text);
drop function if exists admin_save_library_card(text, int, text, text, text, jsonb, text, text, text, boolean, text, boolean);
drop function if exists admin_save_library_card(text, int, text, text, text, jsonb, text, text, text, boolean, text, boolean, int);
drop function if exists admin_list_cards(text);
drop function if exists revealed_card(text);
create or replace function tournament_board(p_tournament_id int)
returns table (owner text, has_picked boolean, golfer text, winnings numeric,
               points numeric, submitted_at timestamptz, note text, adjust numeric, adjust_note text)
language sql stable security definer set search_path = public, extensions as $$
  select o.name,
         p.id is not null,
         case when now() >= t.lock_at then p.golfer end,
         case when now() >= t.lock_at then p.winnings end,
         case when now() >= t.lock_at then coalesce(sp.pts, p.winnings * t.multiplier) end,
         p.submitted_at,
         case when now() >= t.lock_at then sp.note end,
         case when now() >= t.lock_at then p.adjust end,
         case when now() >= t.lock_at then p.adjust_note end
    from owners o
    cross join tournaments t
    left join picks p on p.owner_id = o.id and p.tournament_id = t.id
    left join scored_points(t.id) sp on sp.o_id = o.id
   where t.id = p_tournament_id and o.active
   order by o.name;
$$;

-- Card designs the whole league may see: anything played in a locked week this season.
-- Used for the hover popover on card names in scoring notes.
create or replace function revealed_card_names()
returns table (name text) language sql stable security definer set search_path = public, extensions as $$
  select distinct c.name from cards c join tournaments t on t.id = c.tournament_id
   where c.status = 'played' and now() >= t.lock_at and t.season = current_season() order by 1;
$$;

create or replace function revealed_card(p_name text)
returns table (name text, kind text, effect text, params jsonb, rules text, flavor text, image text, full_card boolean, tier text)
language sql stable security definer set search_path = public, extensions as $$
  select c.name, c.kind, c.effect, c.params, c.rules, c.flavor, c.image, c.full_card, c.tier
    from cards c join tournaments t on t.id = c.tournament_id
   where c.status = 'played' and now() >= t.lock_at and lower(c.name) = lower(trim(p_name))
   order by c.played_at desc limit 1;
$$;

-- Stroke penalties in effect for a tournament. Public and IMMEDIATE (unlike other cards) — the
-- leaderboard shows the victim's −N strokes as soon as the card is played. Shielded victims are skipped.
create or replace function tournament_penalties(p_tournament_id int)
returns table (owner text, strokes numeric, cards text)
language sql stable security definer set search_path = public, extensions as $$
  select o.name, sum(coalesce((c.params->>'n')::numeric, 1)), string_agg(c.name, ', ' order by c.played_at)
    from cards c join owners o on o.id = c.target_owner_id
   where c.tournament_id = p_tournament_id and c.status = 'played' and c.effect = 'strokes'
     and not exists (select 1 from cards s where s.owner_id = c.target_owner_id and s.tournament_id = p_tournament_id
                        and s.status = 'played' and s.effect = 'shield')
   group by o.name order by o.name;
$$;

-- ---------- Live scoring (ESPN feed → live_scores) ---------------------------
-- Names are matched loosely: lower-case, accents folded, punctuation dropped.
create or replace function _norm(t text) returns text language sql immutable as $$
  select regexp_replace(regexp_replace(lower(translate(coalesce(t, ''), 'áàâäãåéèêëíìîïóòôöõøúùûüñçýÿÁÀÂÄÃÅÉÈÊËÍÌÎÏÓÒÔÖÕØÚÙÛÜÑÇ', 'aaaaaaeeeeiiiiooooooouuuuncyyAAAAAAEEEEIIIIOOOOOOOUUUUNC')), '[^a-z ]', '', 'g'), '\s+', ' ', 'g');
$$;

-- Standard PGA Tour purse distribution by finishing position (share of the purse).
create or replace function _payout_pct(p int) returns numeric language sql immutable as $$
  select case when p is null or p < 1 then 0
              when p <= 65 then (array[18,10.9,6.9,4.9,4.1,3.625,3.375,3.125,2.925,2.725,2.525,2.325,2.125,1.925,1.825,1.725,1.625,1.525,1.425,1.325,
                                       1.225,1.125,1.045,0.965,0.885,0.805,0.775,0.745,0.715,0.685,0.655,0.625,0.595,0.57,0.545,0.52,0.495,0.475,0.455,0.435,
                                       0.415,0.395,0.375,0.355,0.335,0.315,0.295,0.279,0.265,0.257,0.251,0.245,0.241,0.237,0.235,0.233,0.231,0.229,0.227,0.225,
                                       0.223,0.221,0.219,0.217,0.215])[p]::numeric / 100
              else greatest(0, 0.215 - 0.002 * (p - 65)) / 100 end;
$$;

-- Each owner's golfer on the live leaderboard, with stroke penalties applied and the finish re-ranked against the
-- whole field. projected = real earnings at that finish once the event is final, else purse × payout table.
-- Only after lock (before that, picks are secret).
create or replace function live_board(p_tournament_id int)
returns table (owner text, golfer text, matched text, pos text, score int, thru text, state text, penalty numeric,
               adj_score int, adj_pos int, adj_ties int, projected numeric, event_status text, event_name text, fetched_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
declare t tournaments%rowtype; ls live_scores%rowtype; r record; f jsonb; sc int; adj int; posn int; ties int; share numeric; ern numeric; k text; lastn text;
begin
  select * into t from tournaments tt where tt.id = p_tournament_id;
  if t.id is null or now() < t.lock_at then return; end if;
  select * into ls from live_scores l where l.tournament_id = p_tournament_id;
  if ls.tournament_id is null then return; end if;

  for r in select o.name as oname, p.golfer as pgolfer,
                  coalesce((select tp.strokes from tournament_penalties(p_tournament_id) tp where tp.owner = o.name), 0) as pen
             from owners o join picks p on p.owner_id = o.id and p.tournament_id = p_tournament_id
            where o.active order by o.name loop
    k := _norm(r.pgolfer); lastn := split_part(k, ' ', array_length(string_to_array(k, ' '), 1));
    select e into f from jsonb_array_elements(ls.field) e where e->>'key' = k limit 1;
    if f is null then   -- fall back to same surname + same first initial ("S. Scheffler")
      select e into f from jsonb_array_elements(ls.field) e
       where split_part(e->>'key', ' ', array_length(string_to_array(e->>'key', ' '), 1)) = lastn and left(e->>'key', 1) = left(k, 1) limit 1;
    end if;
    owner := r.oname; golfer := r.pgolfer; penalty := r.pen; event_status := ls.status; event_name := ls.event_name; fetched_at := ls.fetched_at;
    if f is null then
      matched := null; pos := null; score := null; thru := null; state := 'not in field'; adj_score := null; adj_pos := null; adj_ties := null; projected := 0;
      return next; continue;
    end if;
    matched := f->>'name'; pos := f->>'pos'; thru := f->>'thru'; state := f->>'state';
    sc := nullif(f->>'score', '')::int; score := sc;
    if sc is null or (f->>'state') in ('STATUS_CUT','STATUS_WITHDRAWN','STATUS_DISQUALIFIED','STATUS_DQ','STATUS_WD','STATUS_MDF') then
      adj_score := sc; adj_pos := null; adj_ties := null; projected := 0; return next; continue;
    end if;
    adj := sc + r.pen::int; adj_score := adj;
    select count(*) + 1 into posn from jsonb_array_elements(ls.field) e
     where nullif(e->>'score', '')::int < adj and e->>'key' <> f->>'key'
       and (e->>'state') not in ('STATUS_CUT','STATUS_WITHDRAWN','STATUS_DISQUALIFIED','STATUS_DQ','STATUS_WD','STATUS_MDF');
    select count(*) + 1 into ties from jsonb_array_elements(ls.field) e
     where nullif(e->>'score', '')::int = adj and e->>'key' <> f->>'key'
       and (e->>'state') not in ('STATUS_CUT','STATUS_WITHDRAWN','STATUS_DISQUALIFIED','STATUS_DQ','STATUS_WD','STATUS_MDF');
    adj_pos := posn; adj_ties := ties;
    ern := null;
    if ls.status = 'STATUS_FINAL' then
      if r.pen = 0 then ern := nullif(f->>'earnings', '')::numeric;
      else select avg(nullif(e->>'earnings', '')::numeric) into ern from jsonb_array_elements(ls.field) e
            where (e->>'posn')::int between posn and posn + ties - 1 and nullif(e->>'earnings', '')::numeric > 0; end if;
      if ern is not null and ern <= 0 then ern := null; end if;
    end if;
    if ern is not null then projected := round(ern);
    else select avg(_payout_pct(g)) into share from generate_series(posn, posn + ties - 1) g; projected := round(t.prize_pool * coalesce(share, 0)); end if;
    return next;
  end loop;
end $$;

-- Write live projections into picks.winnings (skipping anything the commissioner typed by hand).
create or replace function _autofill_winnings(p_tournament_id int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0; r record;
begin
  for r in select * from live_board(p_tournament_id) loop
    update picks p set winnings = coalesce(r.projected, 0), winnings_source = 'auto', updated_at = now()
      from owners o where o.id = p.owner_id and o.name = r.owner and p.tournament_id = p_tournament_id
       and coalesce(p.winnings_source, '') <> 'manual';
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function admin_autofill_winnings(p_admin_pin text, p_tournament_id int) returns int
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if not exists (select 1 from live_scores where tournament_id = p_tournament_id) then raise exception 'No live scores for that tournament yet'; end if;
  return _autofill_winnings(p_tournament_id);
end $$;

-- Run by pg_cron every 10 minutes: while a tournament is under way, ask the scores edge function to sync.
create or replace function sync_scores() returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare akey text; url text;
begin
  if not exists (select 1 from tournaments tt where tt.lock_at <= now() and tt.start_date >= current_date - 4) then return null; end if;
  select value into akey from settings where key = 'announce_key';
  select value into url  from settings where key = 'scores_url';
  if coalesce(akey, '') = '' or coalesce(url, '') = '' then return null; end if;
  return net.http_post(url := url, body := '{}'::jsonb,
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-announce-key', akey),
                       timeout_milliseconds := 30000);
end $$;

-- ---------- Booster packs (RULES.md) -------------------------------------------
-- Slot odds: cards 1–3 common 80% / rare 20%; card 4 common 50 / rare 40 / legendary 10; card 5 rare 70 / legendary 25 / mythic 5.
create or replace function _pack_tier(p_slot int) returns text language plpgsql volatile as $$
declare r numeric := random();
begin
  if p_slot <= 3 then return case when r < 0.20 then 'rare' else 'common' end;
  elsif p_slot = 4 then return case when r < 0.10 then 'legendary' when r < 0.50 then 'rare' else 'common' end;
  else return case when r < 0.05 then 'mythic' when r < 0.30 then 'legendary' else 'rare' end;
  end if;
end $$;

-- Copies of a design currently in hands (held). Designs with max_copies stop being dealt once this reaches the cap.
create or replace function _copies_held(p_library_id int) returns int language sql stable as $$
  select count(*)::int from cards c where c.library_id = p_library_id and c.status = 'held';
$$;
create or replace function _at_copy_cap(l card_library) returns boolean language sql stable as $$
  select l.max_copies is not null and _copies_held(l.id) >= l.max_copies;
$$;

-- A random active library design of the given tier (skipping designs at their copy cap); if that pool is empty, step down a tier (then up) so a pack is never short.
create or replace function _pick_library_card(p_tier text) returns card_library language plpgsql volatile as $$
declare l card_library; tiers text[] := array['mythic','legendary','rare','common']; i int; t text;
begin
  i := coalesce(array_position(tiers, p_tier), 4);
  foreach t in array (tiers[i:4] || tiers[1:i-1]) loop
    select * into l from card_library cl where not cl.retired and not cl.review and cl.tier = t and not _at_copy_cap(cl) order by random() limit 1;
    if l.id is not null then return l; end if;
  end loop;
  return null;
end $$;

create or replace function _packs_message(p_tournament_id int) returns text
language sql stable security definer set search_path = public, extensions as $$
  select '📦 **Booster packs** for the **' || t.name || '** are open! Check My Cards.' || E'\n' ||
         coalesce((select string_agg('• **' || o.name || '** pulled ' || pulls, E'\n' order by o.name)
                     from (select pk.owner_id,
                                  string_agg(cnt || ' ' || tier, ' · ' order by array_position(array['common','rare','legendary','mythic'], tier)) as pulls
                             from (select pk2.owner_id, c.tier, count(*) as cnt
                                     from packs pk2 join cards c on c.pack_id = pk2.id
                                    where pk2.tournament_id = t.id group by pk2.owner_id, c.tier) x
                             join packs pk on pk.owner_id = x.owner_id and pk.tournament_id = t.id
                            group by pk.owner_id) p join owners o on o.id = p.owner_id), '')
    from tournaments t where t.id = p_tournament_id;
$$;

-- Give every active owner one 5-card pack for the tournament (once; safe to call again).
create or replace function _award_packs(p_tournament_id int) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare o record; pid int; n int := 0; s int; l card_library; t tournaments%rowtype;
begin
  select * into t from tournaments tt where tt.id = p_tournament_id;
  if t.id is null then return 0; end if;
  for o in select id, name from owners where active order by name loop
    if exists (select 1 from packs pk where pk.tournament_id = p_tournament_id and pk.owner_id = o.id) then continue; end if;
    insert into packs(tournament_id, owner_id) values (p_tournament_id, o.id) returning id into pid;
    for s in 1..5 loop
      l := _pick_library_card(_pack_tier(s));
      if l.id is null then continue; end if;      -- empty library: pack stays empty rather than failing
      insert into cards(owner_id, library_id, name, kind, effect, params, rules, flavor, image, full_card, tier, exempt_limit, cost, pack_id)
      values (o.id, l.id, l.name, l.kind, l.effect, l.params, l.rules, l.flavor, l.image, l.full_card, l.tier, l.exempt_limit, l.cost, pid);
    end loop;
    n := n + 1;
  end loop;
  if n > 0 then perform _discord_text(_packs_message(p_tournament_id)); end if;
  return n;
end $$;

-- pg_cron, hourly: packs for every tournament that has ended (midnight ET after day 4) in the last two weeks and has none yet.
create or replace function award_due_packs() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  for r in select tt.id from tournaments tt
            where _tournament_end(tt.start_date) <= now() and tt.start_date >= current_date - 14
              and not exists (select 1 from packs pk where pk.tournament_id = tt.id)
            order by tt.start_date loop
    n := n + _award_packs(r.id);
  end loop;
  return n;
end $$;

-- The owner has watched the pack-opening on the site; the cards now show in their hand.
create or replace function open_pack(p_owner text, p_pin text, p_pack_id int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_owner int := _owner_id(p_owner, p_pin);
begin
  update packs set revealed_at = now() where id = p_pack_id and owner_id = v_owner and revealed_at is null;
end $$;

create or replace function admin_award_packs(p_admin_pin text, p_tournament_id int) returns int
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  return _award_packs(p_tournament_id);
end $$;

-- Cards in play for a tournament — revealed at lock time, like picks.
create or replace function tournament_cards(p_tournament_id int)
returns table (id int, owner text, name text, kind text, effect text, params jsonb, rules text, flavor text, image text, target text, full_card boolean, tier text, cost int)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, o.name, c.name, c.kind, c.effect, c.params, c.rules, c.flavor, c.image, tg.name, c.full_card, c.tier, c.cost
    from cards c
    join owners o on o.id = c.owner_id
    join tournaments t on t.id = c.tournament_id
    left join owners tg on tg.id = c.target_owner_id
   where c.tournament_id = p_tournament_id and c.status = 'played' and now() >= t.lock_at
   order by c.played_at;
$$;

create or replace function standings(p_season int default null)
returns table (owner text, points numeric, picks_made int, wins int, best_week numeric)
language sql stable security definer set search_path = public, extensions as $$
  with s as (select coalesce(p_season, current_season()) as season)
  select o.name,
         coalesce(sum(case when now() >= t.lock_at then coalesce(sp.pts, p.winnings * t.multiplier) end), 0),
         count(p.id)::int,
         count(*) filter (where now() >= t.lock_at and p.winnings > 0
                          and p.winnings = (select max(p2.winnings) from picks p2 where p2.tournament_id = t.id))::int,
         coalesce(max(case when now() >= t.lock_at then coalesce(sp.pts, p.winnings * t.multiplier) end), 0)
    from owners o
    cross join tournaments t
    left join picks p on p.owner_id = o.id and p.tournament_id = t.id
    left join scored_points(t.id) sp on sp.o_id = o.id
   where o.active and t.season = (select season from s)
   group by o.name
   order by 2 desc, 1;
$$;

-- The White Stag Club: past champions, newest first (image = portrait data URL).
alter table champions add column if not exists image text;
drop function if exists list_champions();
create or replace function list_champions()
returns table (season int, owner text, note text, points numeric, image text)
language sql stable security definer set search_path = public, extensions as $$
  select season, owner, note, points, image from champions order by season desc;
$$;

-- All revealed picks for the season (for the history grid).
create or replace function season_picks(p_season int default null)
returns table (tournament_id int, owner text, golfer text, winnings numeric, points numeric, note text)
language sql stable security definer set search_path = public, extensions as $$
  select t.id, o.name, p.golfer, p.winnings, coalesce(sp.pts, p.winnings * t.multiplier), sp.note
    from picks p
    join tournaments t on t.id = p.tournament_id
    join owners o on o.id = p.owner_id
    left join scored_points(t.id) sp on sp.o_id = o.id
   where t.season = coalesce(p_season, current_season()) and now() >= t.lock_at;
$$;

-- ---------- Owner functions (need name + PIN) ----------------------------

create or replace function my_picks(p_owner text, p_pin text, p_season int default null)
returns table (tournament_id int, tournament text, start_date date, golfer text,
               winnings numeric, points numeric, locked boolean, submitted_at timestamptz, note text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id int := _owner_id(p_owner, p_pin);
begin
  return query
    select t.id, t.name, t.start_date, p.golfer, p.winnings, coalesce(sp.pts, p.winnings * t.multiplier),
           now() >= t.lock_at, p.submitted_at, case when now() >= t.lock_at then sp.note end
      from picks p join tournaments t on t.id = p.tournament_id
      left join scored_points(t.id) sp on sp.o_id = p.owner_id
     where p.owner_id = v_id and t.season = coalesce(p_season, current_season())
     order by t.sort_order;
end $$;

-- ---------- Cards: the owner's hand -------------------------------------

create or replace function my_cards(p_owner text, p_pin text)
returns table (id int, name text, kind text, effect text, params jsonb, rules text, flavor text, image text,
               status text, tournament_id int, tournament text, locked boolean, target text, dealt_at timestamptz, full_card boolean, tier text, exempt_limit boolean,
               cost int, pack_id int, pack_tournament text, pack_revealed boolean, pack_awarded timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id int := _owner_id(p_owner, p_pin);
begin
  return query
    select c.id, c.name, c.kind, c.effect, c.params, c.rules, c.flavor, c.image, c.status,
           c.tournament_id, t.name, (t.id is not null and now() >= t.lock_at), tg.name, c.dealt_at, c.full_card, c.tier, c.exempt_limit,
           c.cost, c.pack_id, pt.name, (pk.revealed_at is not null), pk.opened_at
      from cards c
      left join tournaments t on t.id = c.tournament_id
      left join owners tg on tg.id = c.target_owner_id
      left join packs pk on pk.id = c.pack_id
      left join tournaments pt on pt.id = pk.tournament_id
     where c.owner_id = v_id and c.status <> 'revoked'
     order by (c.status = 'held') desc, c.dealt_at, c.id;
end $$;

-- Cards played ON me that constrain my pick this week (a curse's forced golfer). Only the
-- victim learns this before lock — and only the card, not who played it.
create or replace function my_constraints(p_owner text, p_pin text, p_tournament_id int)
returns table (card text, golfer text, pct numeric)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id int := _owner_id(p_owner, p_pin);
begin
  return query
    select c.name, nullif(trim(c.params->>'golfer'), ''), coalesce((c.params->>'pct')::numeric, 0)
      from cards c
     where c.target_owner_id = v_id and c.tournament_id = p_tournament_id and c.status = 'played' and c.effect = 'curse'
       and not exists (select 1 from cards s where s.owner_id = v_id and s.tournament_id = p_tournament_id and s.status = 'played' and s.effect = 'shield')
     order by c.played_at;
end $$;

-- ---------- Timing rules (see RULES.md) ---------------------------------------
-- A card whose type line says "Instant" may be played after lock, until 8 PM ET on day 3 of the tournament.
-- An owner hit by an Instant may respond with their own Instant until the tournament ends (midnight ET after day 4);
-- on the final day (day 4) that response may only target someone who has already hit them with an Instant.
create or replace function _is_instant(p_kind text) returns boolean language sql immutable as $$
  select lower(coalesce(p_kind, '')) like '%instant%';
$$;
create or replace function _instant_cutoff(p_start date) returns timestamptz language sql immutable as $$
  select ((p_start + 2)::timestamp + interval '20 hours') at time zone 'America/New_York';      -- day 3, 8:00 PM ET
$$;
create or replace function _final_day(p_start date) returns timestamptz language sql immutable as $$
  select (p_start + 3)::timestamp at time zone 'America/New_York';                             -- day 4, 12:00 AM ET
$$;
create or replace function _tournament_end(p_start date) returns timestamptz language sql immutable as $$
  select (p_start + 4)::timestamp at time zone 'America/New_York';                             -- midnight ET after day 4
$$;

-- Text-only Discord post (used for mid-tournament plays). Never fails the caller.
create or replace function _discord_text(p_msg text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hook text;
begin
  select value into hook from settings where key = 'discord_webhook';
  if coalesce(hook, '') = '' then return; end if;
  perform net.http_post(url := hook, body := jsonb_build_object('content', left(p_msg, 1990), 'username', 'The White Stag'),
                        headers := '{"Content-Type":"application/json"}'::jsonb);
exception when others then null;
end $$;

create or replace function play_card(p_owner text, p_pin text, p_card_id int, p_tournament_id int, p_target text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_owner  int := _owner_id(p_owner, p_pin);
  v_c      cards%rowtype;
  v_t      tournaments%rowtype;
  v_target int;
  v_live   boolean;      -- played after lock (Instant)
  v_n      int;
  v_used   int;          -- tees already spent this tournament
begin
  select * into v_c from cards cd where cd.id = p_card_id and cd.owner_id = v_owner;
  if v_c.id is null then raise exception 'That card is not in your hand'; end if;
  if v_c.status <> 'held' then raise exception 'That card is already in play'; end if;
  select * into v_t from tournaments tt where tt.id = p_tournament_id;
  if v_t.id is null then raise exception 'Unknown tournament'; end if;
  if v_c.effect in ('duel','steal','swap','curse','fellowship','strokes') then
    select o.id into v_target from owners o where lower(o.name) = lower(trim(coalesce(p_target, ''))) and o.active;
    if v_target is null then raise exception 'Choose % for this card', case when v_c.effect = 'fellowship' then 'a partner' else 'an opponent' end; end if;
    if v_target = v_owner then raise exception 'You cannot target yourself'; end if;
  end if;

  if coalesce((v_c.params->>'major_only')::boolean, false) and not v_t.is_major then
    raise exception '% can only be played at a major (the Masters, PGA Championship, U.S. Open, The Open — or THE PLAYERS, which counts as one)', v_c.name;
  end if;

  v_live := now() >= v_t.lock_at;
  if v_live then
    if not _is_instant(v_c.kind) then raise exception 'Too late — the % has already started. Only Instants can be played mid-tournament.', v_t.name; end if;
    if now() >= _tournament_end(v_t.start_date) then raise exception 'The % is over', v_t.name; end if;
    if now() >= _instant_cutoff(v_t.start_date) then
      -- past the 8 PM day-3 cutoff: only an owner who has been hit by an Instant may respond
      if not exists (select 1 from cards x where x.tournament_id = p_tournament_id and x.status = 'played'
                       and x.target_owner_id = v_owner and x.owner_id <> v_owner and _is_instant(x.kind)) then
        raise exception 'Instants close at 8 PM ET on day 3. After that only an owner hit by an Instant may respond with one.';
      end if;
      if now() >= _final_day(v_t.start_date) and v_target is not null and not exists (
           select 1 from cards x where x.tournament_id = p_tournament_id and x.status = 'played'
             and x.owner_id = v_target and x.target_owner_id = v_owner and _is_instant(x.kind)) then
        raise exception 'On the final day a response Instant may only target someone who already hit you with an Instant';
      end if;
    end if;
  end if;

  -- 3 cards per owner per tournament unless the card text exempts it
  if not v_c.exempt_limit then
    select count(*) into v_n from cards cd
     where cd.owner_id = v_owner and cd.tournament_id = p_tournament_id and cd.status = 'played' and not cd.exempt_limit;
    if v_n >= 3 then raise exception 'Three cards is the limit for one tournament (the % already has % of yours)', v_t.name, v_n; end if;
  end if;

  -- 3 tees per owner per tournament; each card costs cards.cost tees
  select coalesce(sum(cd.cost), 0) into v_used from cards cd
   where cd.owner_id = v_owner and cd.tournament_id = p_tournament_id and cd.status = 'played';
  if v_used + v_c.cost > 3 then
    raise exception 'Not enough tees: % costs % and you have % of 3 left for the %', v_c.name, v_c.cost, 3 - v_used, v_t.name;
  end if;

  update cards set status = 'played', tournament_id = p_tournament_id, target_owner_id = v_target, played_at = now()
   where id = p_card_id;
  if v_live then
    perform _discord_text('⚡ **' || p_owner || '** plays **' || v_c.name || '**'
      || case when v_target is null then '' when v_c.effect = 'fellowship' then ' with **' || _oname(v_target) || '**' else ' on **' || _oname(v_target) || '**' end
      || ' — ' || v_t.name || case when now() >= _instant_cutoff(v_t.start_date) then ' (response)' else '' end);
  end if;
  return json_build_object('ok', true, 'card', v_c.name, 'tournament', v_t.name, 'target', _oname(v_target), 'live', v_live);
end $$;

create or replace function unplay_card(p_owner text, p_pin text, p_card_id int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_owner int := _owner_id(p_owner, p_pin);
  v_c     cards%rowtype;
  v_t     tournaments%rowtype;
begin
  select * into v_c from cards cd where cd.id = p_card_id and cd.owner_id = v_owner;
  if v_c.id is null or v_c.status <> 'played' then raise exception 'That card is not in play'; end if;
  select * into v_t from tournaments tt where tt.id = v_c.tournament_id;
  if now() >= v_t.lock_at then raise exception 'The % has started — the card stays played', v_t.name; end if;
  if v_c.effect = 'mulligan' and exists (
       select 1 from picks p
         join picks p2 on p2.owner_id = p.owner_id and p2.golfer_key = p.golfer_key and p2.tournament_id <> p.tournament_id
         join tournaments t2 on t2.id = p2.tournament_id and t2.season = v_t.season
        where p.owner_id = v_owner and p.tournament_id = v_c.tournament_id) then
    raise exception 'Your pick for the % reuses a golfer — change it before taking back the mulligan', v_t.name;
  end if;
  update cards set status = 'held', tournament_id = null, target_owner_id = null, played_at = null where id = p_card_id;
end $$;

create or replace function submit_pick(p_owner text, p_pin text, p_tournament_id int, p_golfer text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_owner  int := _owner_id(p_owner, p_pin);
  v_t      tournaments%rowtype;
  v_golfer text := trim(regexp_replace(p_golfer, '\s+', ' ', 'g'));
  v_key    text := lower(v_golfer);
  v_used   text;
  v_golfer_prev text;
  v_prev   text;
  v_curse  text;
  v_forced text;
begin
  if v_golfer is null or length(v_golfer) < 3 then
    raise exception 'Please enter a golfer''s full name';
  end if;

  select * into v_t from tournaments where id = p_tournament_id;
  if v_t.id is null then raise exception 'Unknown tournament'; end if;
  if now() >= v_t.lock_at then
    raise exception 'Picks for % are locked (tournament has started)', v_t.name;
  end if;

  -- A curse with a forced golfer (In the Stocks) dictates this owner's pick.
  select cd.name, nullif(trim(cd.params->>'golfer'), '') into v_curse, v_forced
    from cards cd
   where cd.target_owner_id = v_owner and cd.tournament_id = p_tournament_id and cd.status = 'played' and cd.effect = 'curse'
     and nullif(trim(cd.params->>'golfer'), '') is not null
     and not exists (select 1 from cards s where s.owner_id = v_owner and s.tournament_id = p_tournament_id and s.status = 'played' and s.effect = 'shield')
   order by cd.played_at limit 1;
  if v_forced is not null and lower(trim(regexp_replace(v_forced, '\s+', ' ', 'g'))) <> v_key then
    raise exception '%: you must pick % this week', v_curse, v_forced;
  end if;

  -- No mulligans: a golfer may be used once per season (changing your pick
  -- for THIS tournament before lock is fine) — unless a Mulligan card is in
  -- play for this tournament, or the pick is being forced by a curse.
  if v_forced is null and not exists (select 1 from cards cd where cd.owner_id = v_owner and cd.tournament_id = p_tournament_id
                    and cd.status = 'played' and cd.effect = 'mulligan') then
    select t.name, p.golfer into v_used, v_golfer_prev
      from picks p join tournaments t on t.id = p.tournament_id
     where p.owner_id = v_owner and p.golfer_key = v_key
       and t.season = v_t.season and p.tournament_id <> p_tournament_id;
    if v_used is not null then
      raise exception 'No mulligans: you already used % at the %', v_golfer_prev, v_used;
    end if;
  end if;

  select golfer into v_prev from picks where owner_id = v_owner and tournament_id = p_tournament_id;

  insert into picks (owner_id, tournament_id, golfer)
  values (v_owner, p_tournament_id, v_golfer)
  on conflict (owner_id, tournament_id)
  do update set golfer = excluded.golfer, updated_at = now(), submitted_at = now();

  return json_build_object('ok', true, 'tournament', v_t.name, 'golfer', v_golfer,
                           'replaced', v_prev, 'lock_at', v_t.lock_at);
end $$;

create or replace function change_pin(p_owner text, p_pin text, p_new_pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_id int := _owner_id(p_owner, p_pin);
begin
  if p_new_pin !~ '^\d{4,8}$' then raise exception 'PIN must be 4–8 digits'; end if;
  update owners set pin_hash = crypt(p_new_pin, gen_salt('bf')) where id = v_id;
end $$;

-- ---------- Commissioner functions (need admin PIN) ----------------------

create or replace function admin_set_owner(p_admin_pin text, p_owner text, p_pin text, p_active boolean default true)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if p_pin !~ '^\d{4,8}$' then raise exception 'PIN must be 4–8 digits'; end if;
  insert into owners (name, pin_hash, active)
  values (trim(p_owner), crypt(p_pin, gen_salt('bf')), p_active)
  on conflict (name) do update set pin_hash = excluded.pin_hash, active = excluded.active;
end $$;

drop function if exists admin_set_winnings(text, int, text, numeric);
-- p_adjust / p_adjust_note: null leaves the stored value alone; an empty note clears it.
create or replace function admin_set_winnings(p_admin_pin text, p_tournament_id int, p_owner text, p_winnings numeric,
                                              p_adjust numeric default null, p_adjust_note text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  update picks p set winnings = coalesce(p_winnings, 0),
                     winnings_source = 'manual',
                     adjust = coalesce(p_adjust, p.adjust),
                     adjust_note = case when p_adjust_note is null then p.adjust_note else nullif(trim(p_adjust_note), '') end,
                     updated_at = now()
    from owners o
   where o.id = p.owner_id and lower(o.name) = lower(trim(p_owner)) and p.tournament_id = p_tournament_id;
  if not found then raise exception 'No pick found for % in that tournament', p_owner; end if;
end $$;

create or replace function admin_upsert_tournament(p_admin_pin text, p_season int, p_sort_order int, p_name text,
                                                   p_start_date date, p_lock_at timestamptz,
                                                   p_prize_pool numeric, p_multiplier numeric, p_is_major boolean default false)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  insert into tournaments (season, sort_order, name, start_date, lock_at, prize_pool, multiplier, is_major)
  values (p_season, p_sort_order, trim(p_name), p_start_date, p_lock_at, p_prize_pool, p_multiplier, coalesce(p_is_major, false))
  on conflict (season, name) do update
     set sort_order = excluded.sort_order, start_date = excluded.start_date, lock_at = excluded.lock_at,
         prize_pool = excluded.prize_pool, multiplier = excluded.multiplier, is_major = excluded.is_major;
end $$;

create or replace function admin_delete_tournament(p_admin_pin text, p_tournament_id int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  -- cards played on the deleted week go back to their owners' hands
  update cards set status = 'held', tournament_id = null, target_owner_id = null, played_at = null
   where tournament_id = p_tournament_id and status = 'played';
  delete from tournaments where id = p_tournament_id;
end $$;

drop function if exists admin_set_champion(text, int, text, text, numeric);
-- p_image null keeps the existing portrait; pass '' to clear it.
create or replace function admin_set_champion(p_admin_pin text, p_season int, p_owner text,
                                              p_note text default null, p_points numeric default null, p_image text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if trim(coalesce(p_owner, '')) = '' then raise exception 'Who won?'; end if;
  insert into champions (season, owner, note, points, image)
  values (p_season, trim(p_owner), nullif(trim(p_note), ''), p_points, nullif(p_image, ''))
  on conflict (season) do update set owner = excluded.owner, note = excluded.note, points = excluded.points,
    image = case when p_image is null then champions.image else nullif(p_image, '') end;
end $$;

create or replace function admin_delete_champion(p_admin_pin text, p_season int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  delete from champions where season = p_season;
end $$;

create or replace function admin_deal_card(p_admin_pin text, p_owner text, p_name text, p_kind text, p_effect text,
                                           p_params jsonb default '{}', p_rules text default null,
                                           p_flavor text default null, p_image text default null, p_full_card boolean default false)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_owner int; v_id int;
begin
  perform _check_admin(p_admin_pin);
  select o.id into v_owner from owners o where lower(o.name) = lower(trim(p_owner));
  if v_owner is null then raise exception 'Unknown owner %', p_owner; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'The card needs a name'; end if;
  insert into cards (owner_id, name, kind, effect, params, rules, flavor, image, full_card)
  values (v_owner, trim(p_name), coalesce(nullif(trim(p_kind), ''), 'Enchantment'), p_effect,
          coalesce(p_params, '{}'), nullif(trim(p_rules), ''), nullif(trim(p_flavor), ''), nullif(p_image, ''), coalesce(p_full_card, false))
  returning id into v_id;
  return v_id;
end $$;

-- ---------- Card library (the pool) ----------------------------------------

create or replace function admin_list_library(p_admin_pin text)
returns table (id int, name text, kind text, effect text, params jsonb, rules text, flavor text, image text,
               retired boolean, times_dealt int, in_play int, created_at timestamptz, full_card boolean, tier text, exempt_limit boolean, cost int, max_copies int, review boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  return query
    select l.id, l.name, l.kind, l.effect, l.params, l.rules, l.flavor, l.image, l.retired,
           (select count(*) from cards c where c.library_id = l.id and c.status <> 'revoked')::int,
           (select count(*) from cards c where c.library_id = l.id and c.status = 'held')::int,
           l.created_at, l.full_card, l.tier, l.exempt_limit, l.cost, l.max_copies, l.review
      from card_library l
     order by l.retired, lower(l.name);
end $$;

-- Create (p_id null) or update a library card. A null p_image on update keeps the existing artwork.
create or replace function admin_save_library_card(p_admin_pin text, p_id int, p_name text, p_kind text, p_effect text,
                                                   p_params jsonb default '{}', p_rules text default null,
                                                   p_flavor text default null, p_image text default null,
                                                   p_full_card boolean default null, p_tier text default null,
                                                   p_exempt_limit boolean default null, p_cost int default null,
                                                   p_max_copies int default null, p_clear_max boolean default false)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_id int;
begin
  perform _check_admin(p_admin_pin);
  if trim(coalesce(p_name, '')) = '' then raise exception 'The card needs a name'; end if;
  if p_cost is not null and p_cost not between 0 and 3 then raise exception 'A card costs 0 to 3 tees'; end if;
  if p_max_copies is not null and p_max_copies < 1 then raise exception 'Max copies must be 1 or more (leave it blank for unlimited)'; end if;
  if p_id is null then
    insert into card_library (name, kind, effect, params, rules, flavor, image, full_card, tier, exempt_limit, cost, max_copies)
    values (trim(p_name), coalesce(nullif(trim(p_kind), ''), 'Enchantment'), p_effect, coalesce(p_params, '{}'),
            nullif(trim(p_rules), ''), nullif(trim(p_flavor), ''), nullif(p_image, ''), coalesce(p_full_card, false), coalesce(p_tier, 'common'),
            coalesce(p_exempt_limit, false), coalesce(p_cost, 0), p_max_copies)
    returning id into v_id;
  else
    update card_library
       set name = trim(p_name), kind = coalesce(nullif(trim(p_kind), ''), 'Enchantment'), effect = p_effect,
           params = coalesce(p_params, '{}'), rules = nullif(trim(p_rules), ''), flavor = nullif(trim(p_flavor), ''),
           image = coalesce(nullif(p_image, ''), image), full_card = coalesce(p_full_card, full_card), tier = coalesce(p_tier, tier),
           exempt_limit = coalesce(p_exempt_limit, exempt_limit), cost = coalesce(p_cost, cost),
           max_copies = case when p_clear_max then null else coalesce(p_max_copies, max_copies) end, review = false, updated_at = now()
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'No such library card'; end if;
  end if;
  return v_id;
end $$;

create or replace function admin_retire_library_card(p_admin_pin text, p_id int, p_retired boolean default true)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  update card_library set retired = p_retired, updated_at = now() where id = p_id;
  if not found then raise exception 'No such library card'; end if;
end $$;

create or replace function admin_review_library_card(p_admin_pin text, p_id int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  update card_library set review = false, updated_at = now() where id = p_id;
  if not found then raise exception 'No such library card'; end if;
end $$;

-- Deal a copy of a library card to an owner.
create or replace function admin_deal_from_library(p_admin_pin text, p_library_id int, p_owner text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_owner int; v_id int; l card_library%rowtype;
begin
  perform _check_admin(p_admin_pin);
  select * into l from card_library cl where cl.id = p_library_id;
  if l.id is null then raise exception 'No such library card'; end if;
  if l.review then raise exception '% is still marked "needs review" — approve it (or edit and save it) in the library first', l.name; end if;
  if _at_copy_cap(l) then raise exception '% is capped at % cop% in circulation and % already out', l.name, l.max_copies, case when l.max_copies = 1 then 'y' else 'ies' end, case when l.max_copies = 1 then 'it is' else 'they are' end; end if;
  select o.id into v_owner from owners o where lower(o.name) = lower(trim(p_owner));
  if v_owner is null then raise exception 'Unknown owner %', p_owner; end if;
  insert into cards (owner_id, library_id, name, kind, effect, params, rules, flavor, image, full_card, tier, exempt_limit, cost)
  values (v_owner, l.id, l.name, l.kind, l.effect, l.params, l.rules, l.flavor, l.image, l.full_card, l.tier, l.exempt_limit, l.cost)
  returning id into v_id;
  return v_id;
end $$;

create or replace function admin_list_cards(p_admin_pin text)
returns table (id int, owner text, name text, kind text, effect text, params jsonb, status text,
               tournament text, target text, dealt_at timestamptz, has_image boolean, tier text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  return query
    select c.id, o.name, c.name, c.kind, c.effect, c.params, c.status, t.name, tg.name, c.dealt_at, c.image is not null, c.tier
      from cards c
      join owners o on o.id = c.owner_id
      left join tournaments t on t.id = c.tournament_id
      left join owners tg on tg.id = c.target_owner_id
     order by c.dealt_at desc, c.id desc;
end $$;

create or replace function admin_revoke_card(p_admin_pin text, p_card_id int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  update cards set status = 'revoked' where id = p_card_id;
  if not found then raise exception 'No such card'; end if;
end $$;

create or replace function admin_set_admin_pin(p_admin_pin text, p_new_pin text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if p_new_pin !~ '^\d{4,8}$' then raise exception 'PIN must be 4–8 digits'; end if;
  update settings set value = crypt(p_new_pin, gen_salt('bf')) where key = 'admin_pin_hash';
end $$;

create or replace function admin_set_season(p_admin_pin text, p_season int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  insert into settings (key, value) values ('current_season', p_season::text)
  on conflict (key) do update set value = excluded.value;
end $$;

-- ---------- Discord: announce picks + cards when a week locks ----------------
-- The webhook URL lives in settings ('discord_webhook'); pg_cron runs announce_locked()
-- every 5 minutes and pg_net posts the message. Nothing here is reachable by owners.

create or replace function _discord_message(p_tournament_id int) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare t tournaments%rowtype; picks_txt text; cards_txt text; n int; msg text;
begin
  select * into t from tournaments tt where tt.id = p_tournament_id;
  if t.id is null then return null; end if;
  if now() >= t.lock_at then
    select string_agg('• **' || o.name || '** — ' || coalesce(p.golfer, '_no pick_')
                      || coalesce(' ' || case when tp.strokes < 0 then '✨ ' else '⚠️ ' end || _strokes_txt(tp.strokes) || ' (' || tp.cards || ')', ''), E'\n' order by o.name), count(p.id)
      into picks_txt, n
      from owners o left join picks p on p.owner_id = o.id and p.tournament_id = t.id
           left join tournament_penalties(t.id) tp on tp.owner = o.name
     where o.active;
    select string_agg('• **' || o.name || '** plays **' || c.name || '**'
                      || case when tg.name is null then '' when c.effect = 'fellowship' then ' with **' || tg.name || '**' else ' on **' || tg.name || '**' end,
                      E'\n' order by c.played_at)
      into cards_txt
      from cards c join owners o on o.id = c.owner_id left join owners tg on tg.id = c.target_owner_id
     where c.tournament_id = t.id and c.status = 'played';
    msg := '⛳ **' || t.name || '** is locked! ' || n || ' picks in · purse $' || to_char(t.prize_pool, 'FM999,999,999,990') || ' · ' || t.multiplier || '×'
        || E'\n\n**Picks**\n' || coalesce(picks_txt, '—')
        || E'\n\n**Cards in play**\n' || coalesce(cards_txt, '_None this week._');
  else
    select string_agg(o.name, ', ' order by o.name) into picks_txt
      from owners o join picks p on p.owner_id = o.id and p.tournament_id = t.id where o.active;
    msg := '🔒 **' || t.name || '** locks ' || to_char(t.lock_at at time zone 'America/New_York', 'Dy Mon FMDD, FMHH12:MI AM') || ' ET. In so far: '
        || coalesce(picks_txt, 'nobody yet') || '.';
  end if;
  return msg;
end $$;

-- Cards in play with their art, for the announcer's image embeds (locked weeks only).
drop function if exists _discord_cards(int);
create or replace function _discord_cards(p_tournament_id int)
returns table (owner text, target text, name text, kind text, effect text, rules text, flavor text, image text, summary text, tier text)
language sql stable security definer set search_path = public, extensions as $$
  select o.name, tg.name, c.name, c.kind, c.effect, c.rules, c.flavor, c.image,
         case c.effect
           when 'multiply'   then 'Points ×' || coalesce(c.params->>'x', '2')
           when 'flat'       then 'Bonus $' || coalesce(c.params->>'amount', '0')
           when 'duel'       then 'Head to head: more prize money wins ×2, loser gets 0'
           when 'steal'      then 'Takes ' || coalesce(c.params->>'pct', '25') || '% of the victim''s points'
           when 'swap'       then 'Swaps points with the target'
           when 'shield'     then 'Rivals'' cards cannot touch the holder this week'
           when 'mulligan'   then 'May reuse a golfer this week'
           when 'fellowship' then 'Partners get +$' || coalesce(c.params->>'amount', '500000') || ' each; $0 for both if either misses the cut'
           when 'curse'      then coalesce('Victim must pick ' || nullif(c.params->>'golfer', ''), 'Curse') || coalesce(' · ' || nullif(c.params->>'pct', '') || '% to their points', '')
           when 'strokes'    then _strokes_txt(coalesce((c.params->>'n')::numeric, 1)) || ' on the target''s golfer'
           else 'Commissioner rules on it at results time' end,
         c.tier
    from cards c join owners o on o.id = c.owner_id join tournaments t on t.id = c.tournament_id
    left join owners tg on tg.id = c.target_owner_id
   where c.tournament_id = p_tournament_id and c.status = 'played' and now() >= t.lock_at
   order by c.played_at;
$$;

-- Posts the announcement. With the announcer edge function configured (settings.announce_key) the
-- database calls it and it attaches card images; otherwise fall back to a text-only webhook post.
create or replace function _discord_post(p_tournament_id int) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare hook text; akey text; fn_url text;
begin
  select value into hook from settings where key = 'discord_webhook';
  if coalesce(hook, '') = '' then raise exception 'Discord is not connected — paste the webhook URL under Commissioner → Settings'; end if;
  select value into akey from settings where key = 'announce_key';
  select value into fn_url from settings where key = 'announce_url';
  if coalesce(akey, '') <> '' and coalesce(fn_url, '') <> '' then
    return net.http_post(url := fn_url,
                         body := jsonb_build_object('tournament_id', p_tournament_id),
                         headers := jsonb_build_object('Content-Type', 'application/json', 'x-announce-key', akey),
                         timeout_milliseconds := 30000);
  end if;
  return net.http_post(url := hook,
                       body := jsonb_build_object('content', left(_discord_message(p_tournament_id), 1990), 'username', 'The White Stag'),
                       headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;

-- Run by pg_cron. Announces every week that locked in the last 2 days and hasn't been announced.
create or replace function announce_locked() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  if coalesce((select value from settings where key = 'discord_webhook'), '') = '' then return 0; end if;
  for r in select tt.id from tournaments tt
            where tt.lock_at <= now() and tt.lock_at > now() - interval '2 days' and tt.announced_at is null
            order by tt.lock_at loop
    perform _discord_post(r.id);
    update tournaments set announced_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function admin_announce(p_admin_pin text, p_tournament_id int) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m text;
begin
  perform _check_admin(p_admin_pin);
  m := _discord_message(p_tournament_id);
  if m is null then raise exception 'Unknown tournament'; end if;
  perform _discord_post(p_tournament_id);
  update tournaments set announced_at = coalesce(announced_at, now()) where id = p_tournament_id and now() >= lock_at;
  return m;
end $$;

create or replace function admin_set_discord(p_admin_pin text, p_url text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if coalesce(trim(p_url), '') = '' then
    delete from settings where key = 'discord_webhook';
  elsif trim(p_url) !~ '^https://(discord\.com|discordapp\.com)/api/webhooks/' then
    raise exception 'That does not look like a Discord webhook URL (it should start with https://discord.com/api/webhooks/)';
  else
    insert into settings (key, value) values ('discord_webhook', trim(p_url))
    on conflict (key) do update set value = excluded.value;
  end if;
end $$;

create or replace function admin_discord_status(p_admin_pin text)
returns table (configured boolean, hint text, scheduled boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare hook text;
begin
  perform _check_admin(p_admin_pin);
  select value into hook from settings where key = 'discord_webhook';
  return query select coalesce(hook, '') <> '',
                      case when coalesce(hook, '') <> '' then '…/webhooks/' || left(split_part(hook, '/webhooks/', 2), 8) || '…' end,
                      exists (select 1 from pg_extension where extname = 'pg_cron')
                        and exists (select 1 from cron.job where jobname = 'announce-locks');
end $$;

-- Extensions + the 5-minute schedule. Wrapped so a project without pg_cron still loads the rest.
do $$
begin
  create extension if not exists pg_net with schema extensions;
exception when others then raise notice 'pg_net not available: %', sqlerrm;
end $$;
do $$
begin
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname = 'announce-locks') then perform cron.unschedule('announce-locks'); end if;
  perform cron.schedule('announce-locks', '*/5 * * * *', 'select public.announce_locked()');
  if exists (select 1 from cron.job where jobname = 'sync-scores') then perform cron.unschedule('sync-scores'); end if;
  perform cron.schedule('sync-scores', '*/10 * * * *', 'select public.sync_scores()');
  if exists (select 1 from cron.job where jobname = 'award-packs') then perform cron.unschedule('award-packs'); end if;
  perform cron.schedule('award-packs', '17 * * * *', 'select public.award_due_packs()');
exception when others then raise notice 'pg_cron not available: %', sqlerrm;
end $$;

-- Only the functions are callable from the browser.
revoke all on all functions in schema public from public, anon, authenticated;
revoke execute on function _owner_id(text, text) from public, anon, authenticated;
revoke execute on function _check_admin(text) from public, anon, authenticated;
revoke execute on function _oname(int), _note(jsonb, text, text), scored_points(int) from public, anon, authenticated;
drop function if exists _discord_post(text);
revoke execute on function _discord_message(int), _discord_cards(int), _discord_post(int), announce_locked() from public, anon, authenticated;
revoke execute on function _autofill_winnings(int), sync_scores(), _discord_text(text), _award_packs(int), award_due_packs(), _packs_message(int),
                           _pack_tier(int), _pick_library_card(text), _copies_held(int), _at_copy_cap(card_library) from public, anon, authenticated;
grant execute on function _discord_message(int), _discord_cards(int), _autofill_winnings(int), _award_packs(int) to service_role;   -- the edge functions
grant all on live_scores, packs to service_role;
grant execute on function
  current_season(), list_owners(), list_tournaments(int), list_golfers(), tournament_board(int), tournament_cards(int),
  revealed_card_names(), revealed_card(text), tournament_penalties(int), live_board(int), admin_autofill_winnings(text, int), open_pack(text, text, int),
  my_cards(text, text), my_constraints(text, text, int), play_card(text, text, int, int, text), unplay_card(text, text, int),
  admin_deal_card(text, text, text, text, text, jsonb, text, text, text, boolean), admin_list_cards(text), admin_revoke_card(text, int),
  admin_list_library(text), admin_save_library_card(text, int, text, text, text, jsonb, text, text, text, boolean, text, boolean, int, int, boolean), admin_award_packs(text, int), admin_review_library_card(text, int),
  admin_retire_library_card(text, int, boolean), admin_deal_from_library(text, int, text),
  admin_announce(text, int), admin_set_discord(text, text), admin_discord_status(text),
  standings(int), season_picks(int), my_picks(text, text, int), submit_pick(text, text, int, text),
  change_pin(text, text, text), admin_set_owner(text, text, text, boolean),
  admin_set_winnings(text, int, text, numeric, numeric, text),
  admin_upsert_tournament(text, int, int, text, date, timestamptz, numeric, numeric, boolean),
  admin_delete_tournament(text, int), admin_set_admin_pin(text, text), admin_set_season(text, int),
  list_champions(), admin_set_champion(text, int, text, text, numeric, text), admin_delete_champion(text, int)
to anon, authenticated;

-- =====================================================================
--  Seed data
-- =====================================================================

-- Commissioner PIN. CHANGE THIS before running (or change it later from the
-- Commissioner tab on the site).
insert into settings (key, value) values ('admin_pin_hash', crypt('1234', gen_salt('bf')))
on conflict (key) do nothing;
insert into settings (key, value) values ('current_season', '2027') on conflict (key) do nothing;

-- 2027 schedule (PGA Tour announcement, Aug 26 2026), using the same event
-- selection and multipliers as the 2026 league sheet plus Pebble Beach: February
-- through the TOUR Championship, no opposite-field events, no Hawaii/AmEx/Sentry.
-- Changes from 2026: Cadillac Championship moved to March, Valspar to May,
-- the Rocket Classic is gone (Sompo Championship takes that week), and the
-- Wyndham is now the GO by Raymond James. Purses are 2026 placeholders until
-- the Tour publishes 2027 figures — they only show on the board, scoring uses
-- the actual winnings the commissioner enters. Picks lock Thursday 7:00 AM ET.
insert into tournaments (season, sort_order, name, start_date, lock_at, prize_pool, multiplier) values
 (2027, 1, 'AT&T Pebble Beach Pro-Am',      '2027-02-04', '2027-02-04 07:00 America/New_York', 20000000, 1),
 (2027, 2, 'WM Phoenix Open',               '2027-02-11', '2027-02-11 07:00 America/New_York',  9600000, 1),
 (2027, 3, 'The Genesis Invitational',      '2027-02-18', '2027-02-18 07:00 America/New_York', 20000000, 1),
 (2027, 4, 'Cognizant Classic',             '2027-02-25', '2027-02-25 07:00 America/New_York',  9600000, 1),
 (2027, 5, 'Cadillac Championship',         '2027-03-04', '2027-03-04 07:00 America/New_York', 20000000, 1),
 (2027, 6, 'THE PLAYERS Championship',      '2027-03-11', '2027-03-11 07:00 America/New_York', 25000000, 1.5),
 (2027, 7, 'Arnold Palmer Invitational',    '2027-03-18', '2027-03-18 07:00 America/New_York', 20000000, 1),
 (2027, 8, 'Houston Open',                  '2027-03-25', '2027-03-25 07:00 America/New_York',  9900000, 1),
 (2027, 9, 'Valero Texas Open',             '2027-04-01', '2027-04-01 07:00 America/New_York',  9800000, 1),
 (2027,10, 'Masters',                       '2027-04-08', '2027-04-08 07:00 America/New_York', 21000000, 3),
 (2027,11, 'RBC Heritage',                  '2027-04-15', '2027-04-15 07:00 America/New_York', 20000000, 1),
 (2027,12, 'Zurich Classic of New Orleans', '2027-04-22', '2027-04-22 07:00 America/New_York',  9500000, 2),
 (2027,13, 'CJ Cup Byron Nelson',           '2027-04-29', '2027-04-29 07:00 America/New_York', 10300000, 1),
 (2027,14, 'Valspar Championship',          '2027-05-06', '2027-05-06 07:00 America/New_York',  9100000, 1),
 (2027,15, 'Truist Championship',           '2027-05-13', '2027-05-13 07:00 America/New_York', 20000000, 1),
 (2027,16, 'PGA Championship',              '2027-05-20', '2027-05-20 07:00 America/New_York', 19000000, 3),
 (2027,17, 'Charles Schwab Challenge',      '2027-05-27', '2027-05-27 07:00 America/New_York',  9900000, 1),
 (2027,18, 'The Memorial Tournament',       '2027-06-03', '2027-06-03 07:00 America/New_York', 20000000, 1),
 (2027,19, 'RBC Canadian Open',             '2027-06-10', '2027-06-10 07:00 America/New_York',  9800000, 1),
 (2027,20, 'US Open',                       '2027-06-17', '2027-06-17 07:00 America/New_York', 21500000, 3),
 (2027,21, 'Travelers Championship',        '2027-06-24', '2027-06-24 07:00 America/New_York', 20000000, 1),
 (2027,22, 'John Deere Classic',            '2027-07-01', '2027-07-01 07:00 America/New_York',  8800000, 1),
 (2027,23, 'Genesis Scottish Open',         '2027-07-08', '2027-07-08 07:00 America/New_York',  9000000, 1),
 (2027,24, 'British Open',                  '2027-07-15', '2027-07-15 07:00 America/New_York', 17000000, 3),
 (2027,25, '3M Open',                       '2027-07-22', '2027-07-22 07:00 America/New_York',  8800000, 1),
 (2027,26, 'Sompo Championship',            '2027-07-29', '2027-07-29 07:00 America/New_York',  8800000, 1),
 (2027,27, 'GO by Raymond James',           '2027-08-05', '2027-08-05 07:00 America/New_York',  8500000, 1),
 (2027,28, 'FedEx St. Jude Championship',   '2027-08-12', '2027-08-12 07:00 America/New_York', 20000000, 1.5),
 (2027,29, 'BMW Championship',              '2027-08-19', '2027-08-19 07:00 America/New_York', 20000000, 2),
 (2027,30, 'TOUR Championship',             '2027-08-26', '2027-08-26 07:00 America/New_York', 40000000, 1.35)
on conflict (season, name) do nothing;

-- Autocomplete seed (owners can still type any name; names from revealed picks
-- join the list automatically via list_golfers()).
insert into golfers (name) values
 ('Scottie Scheffler'),('Rory McIlroy'),('Xander Schauffele'),('Collin Morikawa'),('Ludvig Åberg'),
 ('Bryson DeChambeau'),('Jon Rahm'),('Justin Thomas'),('Viktor Hovland'),('Hideki Matsuyama'),
 ('Patrick Cantlay'),('Tommy Fleetwood'),('Shane Lowry'),('Wyndham Clark'),('Sam Burns'),
 ('Russell Henley'),('Sepp Straka'),('Keegan Bradley'),('Robert MacIntyre'),('Corey Conners'),
 ('Tony Finau'),('Jordan Spieth'),('Max Homa'),('Brooks Koepka'),('Cameron Young'),
 ('Sungjae Im'),('Tom Kim'),('Matt Fitzpatrick'),('Tyrrell Hatton'),('Justin Rose'),
 ('Akshay Bhatia'),('Ben Griffin'),('Maverick McNealy'),('Harris English'),('Andrew Novak'),
 ('J.J. Spaun'),('Ryan Fox'),('Nick Taylor'),('Daniel Berger'),('Jason Day'),
 ('Adam Scott'),('Min Woo Lee'),('Aaron Rai'),('Si Woo Kim'),('Taylor Pendrith'),
 ('Brian Harman'),('Chris Gotterup'),('Jacob Bridgeman'),('Denny McCarthy'),('Lucas Glover'),
 ('Rickie Fowler'),('Cameron Smith'),('Dustin Johnson'),('Patrick Reed'),('Joaquin Niemann'),
 ('Sahith Theegala'),('Nick Dunlap'),('Billy Horschel'),('Kurt Kitayama'),('Michael Kim'),
 ('Davis Thompson'),('Thomas Detry'),('Rasmus Højgaard'),('Nicolai Højgaard'),('Sam Stevens'),
 ('Alex Noren'),('Gary Woodland'),('Will Zalatoris'),('Cam Davis'),('Brian Campbell')
on conflict do nothing;

-- Owners: add each league member (name, 4–8 digit PIN). Example:
-- select admin_set_owner('1234', 'GP', '4821');
-- select admin_set_owner('1234', 'Mike', '7710');
-- Majors for card purposes (RULES.md 19): the four majors plus THE PLAYERS. Re-applied on every run so new seasons pick it up;
-- the commissioner can also tick/untick it per tournament under Schedule.
update tournaments set is_major = true
 where not is_major and name ~* '^(the )?masters|pga championship|u\.?s\.? open|(british|the) open|open championship|players championship';
