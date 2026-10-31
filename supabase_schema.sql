-- GALAXY FRONTIER: Supabase schema
-- Run this entire file in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pilot_name text not null default 'Rookie Pilot' check (char_length(pilot_name) between 2 and 20),
  friend_code text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  created_at timestamptz not null default now()
);

create table if not exists public.player_data (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  credits bigint not null default 0 check (credits >= 0),
  crystals integer not null default 0 check (crystals >= 0),
  weapon_level integer not null default 1 check (weapon_level between 1 and 10),
  hull_level integer not null default 1 check (hull_level between 1 and 10),
  engine_level integer not null default 1 check (engine_level between 1 and 10),
  shield_level integer not null default 1 check (shield_level between 1 and 10),
  equipped_ship text not null default 'scout' check (equipped_ship in ('scout','interceptor','guardian')),
  unlocked_ships text[] not null default array['scout']::text[],
  updated_at timestamptz not null default now()
);

create table if not exists public.friendships (
  user_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id, friend_id),
  check(user_id <> friend_id)
);

create table if not exists public.game_scores (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  score bigint not null check(score >= 0),
  sector integer not null check(sector between 1 and 10000),
  bosses_defeated integer not null default 0 check(bosses_defeated between 0 and 10000),
  duration_seconds integer not null default 0 check(duration_seconds between 0 and 86400),
  created_at timestamptz not null default now()
);
create index if not exists game_scores_user_score_idx on public.game_scores(user_id, score desc);
create index if not exists game_scores_created_idx on public.game_scores(created_at desc);

-- One row per pilot, aggregating their personal best values.
create or replace view public.leaderboard_best as
select p.id as user_id, p.pilot_name,
       coalesce(max(s.score),0)::bigint as best_score,
       coalesce(max(s.sector),1)::integer as best_sector,
       coalesce(max(s.bosses_defeated),0)::integer as bosses_defeated
from public.profiles p left join public.game_scores s on s.user_id=p.id
group by p.id,p.pilot_name;

alter table public.profiles enable row level security;
alter table public.player_data enable row level security;
alter table public.friendships enable row level security;
alter table public.game_scores enable row level security;

drop policy if exists "profiles are visible to authenticated pilots" on public.profiles;
create policy "profiles are visible to authenticated pilots" on public.profiles for select to authenticated using (true);
drop policy if exists "pilot updates own profile" on public.profiles;
create policy "pilot updates own profile" on public.profiles for update to authenticated using (auth.uid()=id) with check (auth.uid()=id);
drop policy if exists "pilot reads own data" on public.player_data;
create policy "pilot reads own data" on public.player_data for select to authenticated using (auth.uid()=user_id);
drop policy if exists "pilot reads own friendships" on public.friendships;
create policy "pilot reads own friendships" on public.friendships for select to authenticated using (auth.uid()=user_id);
drop policy if exists "pilot reads own scores" on public.game_scores;
create policy "pilot reads own scores" on public.game_scores for select to authenticated using (auth.uid()=user_id);
-- No client INSERT/UPDATE/DELETE policies on balances, upgrades, friendships or scores.
-- All mutations below happen in SECURITY DEFINER RPCs.

grant select on public.profiles, public.player_data, public.friendships, public.game_scores to authenticated;
grant select on public.leaderboard_best to authenticated;

create or replace function public.gf_new_pilot()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id) values(new.id) on conflict do nothing;
  insert into public.player_data(user_id) values(new.id) on conflict do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created_gf on auth.users;
create trigger on_auth_user_created_gf after insert on auth.users for each row execute procedure public.gf_new_pilot();

-- Ensure existing auth users also receive game rows.
insert into public.profiles(id) select id from auth.users on conflict do nothing;
insert into public.player_data(user_id) select id from auth.users on conflict do nothing;

create or replace function public.purchase_upgrade(p_item_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); lv integer; cost bigint; balance bigint; col text; max_lv integer:=10;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  col:=case p_item_id when 'weapon' then 'weapon_level' when 'hull' then 'hull_level' when 'engine' then 'engine_level' when 'shield' then 'shield_level' else null end;
  if col is null then raise exception 'Unknown upgrade'; end if;
  select case col when 'weapon_level' then weapon_level when 'hull_level' then hull_level when 'engine_level' then engine_level else shield_level end, credits
    into lv,balance from public.player_data where user_id=uid for update;
  if lv is null then raise exception 'Pilot data not found'; end if;
  if lv>=max_lv then raise exception 'Upgrade already at maximum level'; end if;
  cost:=case p_item_id when 'weapon' then 150 when 'hull' then 120 when 'engine' then 130 else 160 end * (1.65::numeric ^ (lv-1));
  cost:=floor(cost);
  if balance<cost then raise exception 'Not enough credits'; end if;
  execute format('update public.player_data set %I=%I+1, credits=credits-$1, updated_at=now() where user_id=$2',col,col) using cost,uid;
  return jsonb_build_object('success',true,'item',p_item_id,'new_level',lv+1,'cost',cost);
end; $$;

create or replace function public.submit_run(p_score bigint,p_sector integer,p_bosses integer,p_duration_seconds integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); reward bigint;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if p_score<0 or p_score>100000000 then raise exception 'Invalid score'; end if;
  if p_sector<1 or p_sector>10000 or p_bosses<0 or p_bosses>10000 or p_duration_seconds<0 or p_duration_seconds>86400 then raise exception 'Invalid run data'; end if;
  insert into public.game_scores(user_id,score,sector,bosses_defeated,duration_seconds)
  values(uid,p_score,p_sector,p_bosses,p_duration_seconds);
  -- Basic gameplay reward. This is not a cheat-proof anti-tamper system; see README.
  reward:=least(1000,floor(p_score/100.0))::bigint;
  update public.player_data set credits=credits+reward,updated_at=now() where user_id=uid;
  return jsonb_build_object('success',true,'credits_earned',reward);
end; $$;


create or replace function public.purchase_ship(p_ship_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cost bigint;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  cost:=case p_ship_id when 'interceptor' then 800 when 'guardian' then 1200 else null end;
  if cost is null then raise exception 'Unknown ship'; end if;
  update public.player_data set credits=credits-cost,
    unlocked_ships=array(select distinct ship from unnest(unlocked_ships || array[p_ship_id]) as t(ship)),
    updated_at=now()
  where user_id=uid and credits>=cost and not (p_ship_id=any(unlocked_ships));
  if not found then
    if exists(select 1 from public.player_data where user_id=uid and p_ship_id=any(unlocked_ships)) then raise exception 'Ship already owned'; end if;
    raise exception 'Not enough credits';
  end if;
  return jsonb_build_object('success',true,'ship',p_ship_id,'cost',cost);
end; $$;

create or replace function public.equip_ship(p_ship_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Sign in required'; end if;
  if p_ship_id not in ('scout','interceptor','guardian') then raise exception 'Unknown ship'; end if;
  update public.player_data set equipped_ship=p_ship_id,updated_at=now()
  where user_id=uid and p_ship_id=any(unlocked_ships);
  if not found then raise exception 'Ship not owned'; end if;
  return jsonb_build_object('success',true,'equipped_ship',p_ship_id);
end; $$;

create or replace function public.add_friend_by_code(p_friend_code text)
returns text language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); fid uuid;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  select id into fid from public.profiles where upper(friend_code)=upper(trim(p_friend_code));
  if fid is null then raise exception 'Friend code not found'; end if;
  if fid=uid then raise exception 'You cannot add yourself'; end if;
  insert into public.friendships(user_id,friend_id) values(uid,fid) on conflict do nothing;
  insert into public.friendships(user_id,friend_id) values(fid,uid) on conflict do nothing;
  return 'Friend added successfully';
end; $$;

revoke all on function public.purchase_upgrade(text) from public, anon;
revoke all on function public.purchase_ship(text) from public, anon;
revoke all on function public.equip_ship(text) from public, anon;
revoke all on function public.submit_run(bigint,integer,integer,integer) from public, anon;
revoke all on function public.add_friend_by_code(text) from public, anon;
grant execute on function public.purchase_upgrade(text) to authenticated;
grant execute on function public.purchase_ship(text) to authenticated;
grant execute on function public.equip_ship(text) to authenticated;
grant execute on function public.submit_run(bigint,integer,integer,integer) to authenticated;
grant execute on function public.add_friend_by_code(text) to authenticated;
