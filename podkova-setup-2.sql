-- Подкова, шаг 2: чат, аукцион и случка.
-- Вставь весь этот текст в Supabase → SQL Editor → New query и нажми Run.
-- Старые таблицы (рейтинг, сохранения, рынок) не меняются.

-- ===== чат и лента событий =====
create table if not exists public.chat (
  id bigserial primary key,
  uid uuid not null references auth.users(id) on delete cascade,
  nick text default 'Игрок',
  text text not null check (char_length(text) between 1 and 300),
  kind text not null default 'msg' check (kind in ('msg','feed')),
  team text default '' check (char_length(team) <= 20),
  created_at timestamptz not null default now()
);
alter table public.chat enable row level security;
drop policy if exists "chat read" on public.chat;
drop policy if exists "chat insert own" on public.chat;
create policy "chat read" on public.chat for select using (true);
create policy "chat insert own" on public.chat for insert with check (auth.uid() = uid);

-- ===== аукцион =====
create table if not exists public.auctions (
  id uuid primary key default gen_random_uuid(),
  seller uuid not null references auth.users(id) on delete cascade,
  seller_nick text default 'Игрок',
  horse jsonb not null,
  name text,
  start_price int not null check (start_price between 10 and 99999),
  bid int,
  bidder uuid references auth.users(id),
  bidder_nick text,
  ends_at timestamptz not null,
  status text not null default 'open' check (status in ('open','won','paid')),
  created_at timestamptz not null default now()
);
alter table public.auctions enable row level security;
drop policy if exists "auctions read" on public.auctions;
drop policy if exists "auctions insert own" on public.auctions;
create policy "auctions read" on public.auctions for select using (true);
create policy "auctions insert own" on public.auctions for insert
  with check (auth.uid() = seller and status = 'open' and bid is null and bidder is null
              and ends_at > now() and ends_at <= now() + interval '25 hours');

-- ставка: только выше текущей, только пока идут торги, не на свой лот
create or replace function public.place_bid(aid uuid, amount int, nick text)
returns setof public.auctions language sql security definer set search_path = public as $$
  update public.auctions set bid = amount, bidder = auth.uid(), bidder_nick = left(coalesce(nick,'Игрок'), 24)
  where id = aid and status = 'open' and now() < ends_at and seller <> auth.uid() and auth.uid() is not null
    and amount <= 99999 and amount >= coalesce(bid + 10, start_price)
  returning *;
$$;
-- победитель забирает лошадь после окончания торгов
create or replace function public.claim_auction(aid uuid)
returns setof public.auctions language sql security definer set search_path = public as $$
  update public.auctions set status = 'won'
  where id = aid and status = 'open' and bidder = auth.uid() and now() >= ends_at
  returning *;
$$;
-- продавец получает деньги за выигранные лоты
create or replace function public.claim_auction_pay()
returns setof public.auctions language sql security definer set search_path = public as $$
  update public.auctions set status = 'paid'
  where seller = auth.uid() and status = 'won'
  returning *;
$$;
-- если ставок не было, продавец забирает лошадь обратно
create or replace function public.close_auction(aid uuid)
returns setof public.auctions language sql security definer set search_path = public as $$
  delete from public.auctions
  where id = aid and seller = auth.uid() and status = 'open' and bidder is null and now() >= ends_at
  returning *;
$$;

-- ===== случка с жеребцами других игроков =====
create table if not exists public.studs (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  owner_nick text default 'Игрок',
  horse jsonb not null,
  name text,
  fee int not null check (fee between 10 and 9999),
  created_at timestamptz not null default now()
);
alter table public.studs enable row level security;
drop policy if exists "studs read" on public.studs;
drop policy if exists "studs insert own" on public.studs;
drop policy if exists "studs delete own" on public.studs;
create policy "studs read" on public.studs for select using (true);
create policy "studs insert own" on public.studs for insert with check (auth.uid() = owner);
create policy "studs delete own" on public.studs for delete using (auth.uid() = owner);

create table if not exists public.stud_uses (
  id bigserial primary key,
  stud uuid references public.studs(id) on delete set null,
  owner uuid not null references auth.users(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fee int not null check (fee between 10 and 9999),
  paid boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.stud_uses enable row level security;
drop policy if exists "uses insert own" on public.stud_uses;
drop policy if exists "uses read own" on public.stud_uses;
create policy "uses insert own" on public.stud_uses for insert
  with check (auth.uid() = user_id and paid = false and owner <> auth.uid()
              and exists (select 1 from public.studs s where s.id = stud_uses.stud and s.owner = stud_uses.owner and s.fee = stud_uses.fee));
create policy "uses read own" on public.stud_uses for select using (auth.uid() = user_id or auth.uid() = owner);

create or replace function public.claim_stud()
returns setof public.stud_uses language sql security definer set search_path = public as $$
  update public.stud_uses set paid = true
  where owner = auth.uid() and paid = false
  returning *;
$$;

revoke execute on function public.place_bid(uuid,int,text) from public, anon;
revoke execute on function public.claim_auction(uuid) from public, anon;
revoke execute on function public.claim_auction_pay() from public, anon;
revoke execute on function public.close_auction(uuid) from public, anon;
revoke execute on function public.claim_stud() from public, anon;
grant execute on function public.place_bid(uuid,int,text) to authenticated;
grant execute on function public.claim_auction(uuid) to authenticated;
grant execute on function public.claim_auction_pay() to authenticated;
grant execute on function public.close_auction(uuid) to authenticated;
grant execute on function public.claim_stud() to authenticated;
