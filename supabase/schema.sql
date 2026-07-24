-- Mino account.html — recipe storage + sharing schema.
-- Run this once in the Supabase project's SQL editor (Database → SQL Editor).
-- Requires: Authentication → Providers → Google enabled (needs a Google Cloud OAuth client).
--
-- Design note: link-sharing does NOT rely on a table-level RLS policy like
-- "share_token is not null", because that would let any anon client list every
-- publicly shared recipe by scanning ids. Instead, anonymous token lookup goes
-- through get_recipe_by_share_token(), a SECURITY DEFINER function that only
-- returns a row when the caller supplies the exact matching token.

create table recipes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  recipe_name text not null default '이름 없는 레시피',
  recipe_type text not null default 'bread', -- 'bread' (baker's %) | 'confection' | 'other' (both: absolute weight)
  mode text not null default 'A',
  base_flour numeric not null default 0,
  multiplier numeric not null default 1,
  target_total numeric not null default 0,
  portions jsonb not null default '[]',
  flours jsonb not null default '[]',
  ingredients jsonb not null default '[]',
  notes text not null default '',
  share_token uuid,               -- null = link sharing off
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table recipe_shares (
  recipe_id uuid not null references recipes(id) on delete cascade,
  shared_with_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (recipe_id, shared_with_user_id)
);

-- Personal ingredient master list, referenced from a recipe's flour/ingredient rows via
-- ingredient_id (see account.html's serializeCurrentRecipe/resolveIngredientName). Kept
-- separate from recipes: purchase_unit/purchase_price exist for a future cost/production-
-- planning step and aren't used in any calculation yet.
create table ingredients (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  category text not null default '',             -- free-text grouping (e.g. 밀가루류/유제품), user-defined
  purchase_amount numeric not null default 0,
  purchase_unit_type text not null default 'g', -- 'g' | 'kg' | 'ml' | 'l' | 'ea'
  purchase_price numeric not null default 0,
  price_per_gram numeric not null default 0,     -- computed client-side on save; 0/unused for 'ea'
  is_active boolean not null default true,       -- soft-delete: deactivated ingredients keep
                                                  -- resolving in recipes that already link them,
                                                  -- they just stop appearing as pick candidates
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table recipes enable row level security;
alter table recipe_shares enable row level security;
alter table ingredients enable row level security;

create policy "owner full access" on ingredients for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- recipes' "shared read access" policy needs to check recipe_shares, and recipe_shares'
-- "owner manages shares" policy needs to check recipes — a direct subquery in either
-- USING clause makes Postgres re-evaluate the other table's RLS while evaluating this
-- one, which re-triggers this one, forever ("infinite recursion detected in policy for
-- relation ..."). Routing each cross-table check through a SECURITY DEFINER function
-- breaks the cycle: the function runs as its (table-owning) creator, which isn't subject
-- to RLS, so the lookup inside it doesn't re-trigger policy evaluation on the other table.
create or replace function is_owner_of_recipe(p_recipe_id uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from recipes where id = p_recipe_id and owner_id = auth.uid());
$$;

create or replace function is_recipe_shared_with_me(p_recipe_id uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from recipe_shares where recipe_id = p_recipe_id and shared_with_user_id = auth.uid());
$$;

-- Owner: full CRUD. Recipient of an account-share: read only.
create policy "owner full access" on recipes for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "shared read access" on recipes for select
  using (is_recipe_shared_with_me(id));

create policy "owner manages shares" on recipe_shares for all
  using (is_owner_of_recipe(recipe_id));
create policy "recipient sees own share row" on recipe_shares for select
  using (shared_with_user_id = auth.uid());

-- Share with a specific account by email. auth.users is never exposed to
-- clients directly, so the lookup happens inside this SECURITY DEFINER function.
create or replace function share_recipe_with_email(p_recipe_id uuid, p_email text)
returns void language plpgsql security definer as $$
declare target_id uuid;
begin
  select id into target_id from auth.users where email = p_email;
  if target_id is null then
    raise exception '해당 이메일의 계정을 찾을 수 없어요';
  end if;
  if not exists (select 1 from recipes where id = p_recipe_id and owner_id = auth.uid()) then
    raise exception '본인 소유 레시피만 공유할 수 있어요';
  end if;
  insert into recipe_shares (recipe_id, shared_with_user_id) values (p_recipe_id, target_id)
    on conflict do nothing;
end; $$;

-- Issue or revoke a share link's token. Owner only.
create or replace function set_recipe_share_token(p_recipe_id uuid, p_enable boolean)
returns uuid language plpgsql security definer as $$
declare new_token uuid;
begin
  if not exists (select 1 from recipes where id = p_recipe_id and owner_id = auth.uid()) then
    raise exception '본인 소유 레시피만 공유 링크를 만들 수 있어요';
  end if;
  new_token := case when p_enable then gen_random_uuid() else null end;
  update recipes set share_token = new_token where id = p_recipe_id;
  return new_token;
end; $$;

-- Anonymous read-only lookup by exact token match. Granted to anon.
create or replace function get_recipe_by_share_token(p_token uuid)
returns setof recipes language sql security definer as $$
  select * from recipes where share_token = p_token;
$$;
grant execute on function get_recipe_by_share_token(uuid) to anon;
