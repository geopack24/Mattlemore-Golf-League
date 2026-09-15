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
  effect      text not null check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom')),
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
  effect          text not null check (effect in ('multiply','flat','duel','steal','swap','shield','mulligan','custom')),
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
create unique index if not exists cards_one_in_play_per_week on cards (owner_id, tournament_id) where status = 'played';
alter table cards add column if not exists library_id int references card_library(id) on delete set null;

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

revoke all on all tables in schema public from anon, authenticated;

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
begin
  select * into v_t from tournaments tt where tt.id = p_tournament_id;
  if v_t.id is null then return; end if;

  for c in select p.owner_id as o, p.winnings as wn from picks p where p.tournament_id = p_tournament_id loop
    w := w || jsonb_build_object(c.o::text, c.wn);
    b := b || jsonb_build_object(c.o::text, c.wn * v_t.multiplier);
  end loop;
  m := b;

  select coalesce(array_agg(cd.owner_id), '{}') into sh from cards cd
   where cd.tournament_id = p_tournament_id and cd.status = 'played' and cd.effect = 'shield';

  for c in select * from cards cd where cd.tournament_id = p_tournament_id and cd.status = 'played' order by cd.played_at, cd.id loop
    a := c.owner_id::text; tg := c.target_owner_id::text;
    if not (m ? a) then w := w || jsonb_build_object(a, 0); b := b || jsonb_build_object(a, 0); m := m || jsonb_build_object(a, 0); end if;
    if c.target_owner_id is not null and not (m ? tg) then
      w := w || jsonb_build_object(tg, 0); b := b || jsonb_build_object(tg, 0); m := m || jsonb_build_object(tg, 0);
    end if;

    if c.effect in ('duel','steal','swap') and c.target_owner_id = any(sh) then
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
      when 'shield'   then n := _note(n, a, c.name || ': shielded');
      when 'mulligan' then n := _note(n, a, c.name || ': mulligan');
      else                 n := _note(n, a, c.name || ' (commissioner applies)');
    end case;
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

create or replace function list_tournaments(p_season int default null)
returns table (id int, name text, start_date date, lock_at timestamptz,
               prize_pool numeric, multiplier numeric, locked boolean, season int)
language sql stable security definer set search_path = public, extensions as $$
  select id, name, start_date, lock_at, prize_pool, multiplier, now() >= lock_at, season
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
drop function if exists season_picks(int);
drop function if exists my_picks(text, text, int);
create or replace function tournament_board(p_tournament_id int)
returns table (owner text, has_picked boolean, golfer text, winnings numeric,
               points numeric, submitted_at timestamptz, note text)
language sql stable security definer set search_path = public, extensions as $$
  select o.name,
         p.id is not null,
         case when now() >= t.lock_at then p.golfer end,
         case when now() >= t.lock_at then p.winnings end,
         case when now() >= t.lock_at then coalesce(sp.pts, p.winnings * t.multiplier) end,
         p.submitted_at,
         case when now() >= t.lock_at then sp.note end
    from owners o
    cross join tournaments t
    left join picks p on p.owner_id = o.id and p.tournament_id = t.id
    left join scored_points(t.id) sp on sp.o_id = o.id
   where t.id = p_tournament_id and o.active
   order by o.name;
$$;

-- Cards in play for a tournament — revealed at lock time, like picks.
create or replace function tournament_cards(p_tournament_id int)
returns table (id int, owner text, name text, kind text, effect text, params jsonb, rules text, flavor text, image text, target text)
language sql stable security definer set search_path = public, extensions as $$
  select c.id, o.name, c.name, c.kind, c.effect, c.params, c.rules, c.flavor, c.image, tg.name
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

-- The White Stag Club: past champions, newest first.
create or replace function list_champions()
returns table (season int, owner text, note text, points numeric)
language sql stable security definer set search_path = public, extensions as $$
  select season, owner, note, points from champions order by season desc;
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
               status text, tournament_id int, tournament text, locked boolean, target text, dealt_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_id int := _owner_id(p_owner, p_pin);
begin
  return query
    select c.id, c.name, c.kind, c.effect, c.params, c.rules, c.flavor, c.image, c.status,
           c.tournament_id, t.name, (t.id is not null and now() >= t.lock_at), tg.name, c.dealt_at
      from cards c
      left join tournaments t on t.id = c.tournament_id
      left join owners tg on tg.id = c.target_owner_id
     where c.owner_id = v_id and c.status <> 'revoked'
     order by (c.status = 'held') desc, c.dealt_at, c.id;
end $$;

create or replace function play_card(p_owner text, p_pin text, p_card_id int, p_tournament_id int, p_target text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_owner  int := _owner_id(p_owner, p_pin);
  v_c      cards%rowtype;
  v_t      tournaments%rowtype;
  v_target int;
begin
  select * into v_c from cards cd where cd.id = p_card_id and cd.owner_id = v_owner;
  if v_c.id is null then raise exception 'That card is not in your hand'; end if;
  if v_c.status <> 'held' then raise exception 'That card is already in play'; end if;
  select * into v_t from tournaments tt where tt.id = p_tournament_id;
  if v_t.id is null then raise exception 'Unknown tournament'; end if;
  if now() >= v_t.lock_at then raise exception 'Too late — the % has already started', v_t.name; end if;
  if v_c.effect in ('duel','steal','swap') then
    select o.id into v_target from owners o where lower(o.name) = lower(trim(coalesce(p_target, ''))) and o.active;
    if v_target is null then raise exception 'Choose an opponent for this card'; end if;
    if v_target = v_owner then raise exception 'You cannot target yourself'; end if;
  end if;
  if exists (select 1 from cards cd where cd.owner_id = v_owner and cd.tournament_id = p_tournament_id and cd.status = 'played') then
    raise exception 'You already have a card in play for the %', v_t.name;
  end if;
  update cards set status = 'played', tournament_id = p_tournament_id, target_owner_id = v_target, played_at = now()
   where id = p_card_id;
  return json_build_object('ok', true, 'card', v_c.name, 'tournament', v_t.name, 'target', _oname(v_target));
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
begin
  if v_golfer is null or length(v_golfer) < 3 then
    raise exception 'Please enter a golfer''s full name';
  end if;

  select * into v_t from tournaments where id = p_tournament_id;
  if v_t.id is null then raise exception 'Unknown tournament'; end if;
  if now() >= v_t.lock_at then
    raise exception 'Picks for % are locked (tournament has started)', v_t.name;
  end if;

  -- No mulligans: a golfer may be used once per season (changing your pick
  -- for THIS tournament before lock is fine) — unless a Mulligan card is in
  -- play for this tournament.
  if not exists (select 1 from cards cd where cd.owner_id = v_owner and cd.tournament_id = p_tournament_id
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

create or replace function admin_set_winnings(p_admin_pin text, p_tournament_id int, p_owner text, p_winnings numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  update picks p set winnings = coalesce(p_winnings, 0), updated_at = now()
    from owners o
   where o.id = p.owner_id and lower(o.name) = lower(trim(p_owner)) and p.tournament_id = p_tournament_id;
  if not found then raise exception 'No pick found for % in that tournament', p_owner; end if;
end $$;

create or replace function admin_upsert_tournament(p_admin_pin text, p_season int, p_sort_order int, p_name text,
                                                   p_start_date date, p_lock_at timestamptz,
                                                   p_prize_pool numeric, p_multiplier numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  insert into tournaments (season, sort_order, name, start_date, lock_at, prize_pool, multiplier)
  values (p_season, p_sort_order, trim(p_name), p_start_date, p_lock_at, p_prize_pool, p_multiplier)
  on conflict (season, name) do update
     set sort_order = excluded.sort_order, start_date = excluded.start_date, lock_at = excluded.lock_at,
         prize_pool = excluded.prize_pool, multiplier = excluded.multiplier;
end $$;

create or replace function admin_delete_tournament(p_admin_pin text, p_tournament_id int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  delete from tournaments where id = p_tournament_id;
end $$;

create or replace function admin_set_champion(p_admin_pin text, p_season int, p_owner text,
                                              p_note text default null, p_points numeric default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  if trim(coalesce(p_owner, '')) = '' then raise exception 'Who won?'; end if;
  insert into champions (season, owner, note, points)
  values (p_season, trim(p_owner), nullif(trim(p_note), ''), p_points)
  on conflict (season) do update set owner = excluded.owner, note = excluded.note, points = excluded.points;
end $$;

create or replace function admin_delete_champion(p_admin_pin text, p_season int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  delete from champions where season = p_season;
end $$;

create or replace function admin_deal_card(p_admin_pin text, p_owner text, p_name text, p_kind text, p_effect text,
                                           p_params jsonb default '{}', p_rules text default null,
                                           p_flavor text default null, p_image text default null)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_owner int; v_id int;
begin
  perform _check_admin(p_admin_pin);
  select o.id into v_owner from owners o where lower(o.name) = lower(trim(p_owner));
  if v_owner is null then raise exception 'Unknown owner %', p_owner; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'The card needs a name'; end if;
  insert into cards (owner_id, name, kind, effect, params, rules, flavor, image)
  values (v_owner, trim(p_name), coalesce(nullif(trim(p_kind), ''), 'Enchantment'), p_effect,
          coalesce(p_params, '{}'), nullif(trim(p_rules), ''), nullif(trim(p_flavor), ''), nullif(p_image, ''))
  returning id into v_id;
  return v_id;
end $$;

-- ---------- Card library (the pool) ----------------------------------------

create or replace function admin_list_library(p_admin_pin text)
returns table (id int, name text, kind text, effect text, params jsonb, rules text, flavor text, image text,
               retired boolean, times_dealt int, in_play int, created_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  return query
    select l.id, l.name, l.kind, l.effect, l.params, l.rules, l.flavor, l.image, l.retired,
           (select count(*) from cards c where c.library_id = l.id and c.status <> 'revoked')::int,
           (select count(*) from cards c where c.library_id = l.id and c.status = 'held')::int,
           l.created_at
      from card_library l
     order by l.retired, lower(l.name);
end $$;

-- Create (p_id null) or update a library card. A null p_image on update keeps the existing artwork.
create or replace function admin_save_library_card(p_admin_pin text, p_id int, p_name text, p_kind text, p_effect text,
                                                   p_params jsonb default '{}', p_rules text default null,
                                                   p_flavor text default null, p_image text default null)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_id int;
begin
  perform _check_admin(p_admin_pin);
  if trim(coalesce(p_name, '')) = '' then raise exception 'The card needs a name'; end if;
  if p_id is null then
    insert into card_library (name, kind, effect, params, rules, flavor, image)
    values (trim(p_name), coalesce(nullif(trim(p_kind), ''), 'Enchantment'), p_effect, coalesce(p_params, '{}'),
            nullif(trim(p_rules), ''), nullif(trim(p_flavor), ''), nullif(p_image, ''))
    returning id into v_id;
  else
    update card_library
       set name = trim(p_name), kind = coalesce(nullif(trim(p_kind), ''), 'Enchantment'), effect = p_effect,
           params = coalesce(p_params, '{}'), rules = nullif(trim(p_rules), ''), flavor = nullif(trim(p_flavor), ''),
           image = coalesce(nullif(p_image, ''), image), updated_at = now()
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

-- Deal a copy of a library card to an owner.
create or replace function admin_deal_from_library(p_admin_pin text, p_library_id int, p_owner text)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_owner int; v_id int; l card_library%rowtype;
begin
  perform _check_admin(p_admin_pin);
  select * into l from card_library cl where cl.id = p_library_id;
  if l.id is null then raise exception 'No such library card'; end if;
  select o.id into v_owner from owners o where lower(o.name) = lower(trim(p_owner));
  if v_owner is null then raise exception 'Unknown owner %', p_owner; end if;
  insert into cards (owner_id, library_id, name, kind, effect, params, rules, flavor, image)
  values (v_owner, l.id, l.name, l.kind, l.effect, l.params, l.rules, l.flavor, l.image)
  returning id into v_id;
  return v_id;
end $$;

create or replace function admin_list_cards(p_admin_pin text)
returns table (id int, owner text, name text, kind text, effect text, params jsonb, status text,
               tournament text, target text, dealt_at timestamptz, has_image boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _check_admin(p_admin_pin);
  return query
    select c.id, o.name, c.name, c.kind, c.effect, c.params, c.status, t.name, tg.name, c.dealt_at, c.image is not null
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

-- Only the functions are callable from the browser.
revoke all on all functions in schema public from public, anon, authenticated;
revoke execute on function _owner_id(text, text) from public, anon, authenticated;
revoke execute on function _check_admin(text) from public, anon, authenticated;
revoke execute on function _oname(int), _note(jsonb, text, text), scored_points(int) from public, anon, authenticated;
grant execute on function
  current_season(), list_owners(), list_tournaments(int), list_golfers(), tournament_board(int), tournament_cards(int),
  my_cards(text, text), play_card(text, text, int, int, text), unplay_card(text, text, int),
  admin_deal_card(text, text, text, text, text, jsonb, text, text, text), admin_list_cards(text), admin_revoke_card(text, int),
  admin_list_library(text), admin_save_library_card(text, int, text, text, text, jsonb, text, text, text),
  admin_retire_library_card(text, int, boolean), admin_deal_from_library(text, int, text),
  standings(int), season_picks(int), my_picks(text, text, int), submit_pick(text, text, int, text),
  change_pin(text, text, text), admin_set_owner(text, text, text, boolean),
  admin_set_winnings(text, int, text, numeric),
  admin_upsert_tournament(text, int, int, text, date, timestamptz, numeric, numeric),
  admin_delete_tournament(text, int), admin_set_admin_pin(text, text), admin_set_season(text, int),
  list_champions(), admin_set_champion(text, int, text, text, numeric), admin_delete_champion(text, int)
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
