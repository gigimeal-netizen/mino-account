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

-- One recipe (formula/ratio) can back multiple sellable products (different portion sizes/
-- prices) — see account.html's computeRecipeCostPerGram()/renderProductsList(). Owner-only:
-- unlike recipes, there's no reason a share-link visitor should see cost/selling-price data.
create table products (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  recipe_id uuid not null references recipes(id) on delete cascade,
  name text not null default '새 제품',
  portion_weight numeric not null default 0, -- 1개당 중량(g, 성형 완료 기준)
  selling_price numeric not null default 0,
  loss_rate_pct numeric not null default 0, -- 재단/성형 손실률(%) — (총 반죽 - 성형완료 총중량)/총 반죽 × 100
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- A product doesn't always come from a single recipe (e.g. 소보로빵 = 소보로 반죽 + 빵 반죽,
-- two entirely separate recipes combined). composite_products is the deliberately-separate
-- entity for that case — components each reference their own recipe + finished weight + their
-- own loss rate (different shapes from the same or different batches can trim differently).
-- The plain `products` table above stays as the simple "one recipe, several sizes" case.
create table composite_products (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null default '새 조합 제품',
  selling_price numeric not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- A component is either a whole recipe (recipe_id) OR a single priced ingredient
-- (ingredient_id) — e.g. 프레첼 위에 뿌리는 소금 is just "N그램의 소금", not a recipe with its
-- own flour/ratio. Exactly one of the two is expected to be set at a time; the app clears
-- the other when the user picks one. recipe_id cascades (the component has no identity of
-- its own once its recipe is gone), but ingredient_id sets null instead of cascading — an
-- ingredient can be hard-deleted independently (see ingredients.is_active soft-delete flow),
-- and the component row should survive as "재료를 다시 선택해주세요", not vanish silently.
create table composite_product_components (
  id uuid primary key default gen_random_uuid(),
  composite_product_id uuid not null references composite_products(id) on delete cascade,
  recipe_id uuid references recipes(id) on delete cascade,       -- nullable: unassigned until picked
  ingredient_id uuid references ingredients(id) on delete set null,
  weight_g numeric not null default 0,      -- 이 구성요소가 완제품에 들어가는 무게(성형 완료 기준)
  loss_rate_pct numeric not null default 0, -- 이 구성요소만의 재단/성형 손실률(%)
  created_at timestamptz not null default now()
);

alter table recipes enable row level security;
alter table recipe_shares enable row level security;
alter table ingredients enable row level security;
alter table products enable row level security;
alter table composite_products enable row level security;
alter table composite_product_components enable row level security;

create policy "owner full access" on ingredients for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "owner full access" on products for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "owner full access" on composite_products for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
-- composite_product_components has no owner_id of its own, so it checks ownership via its
-- parent — safe as a plain subquery (unlike recipes/recipe_shares) since composite_products'
-- own policy only checks a column directly and never queries this table back, so there's no
-- cycle for Postgres to recurse on.
create policy "owner full access via parent" on composite_product_components for all
  using (exists (select 1 from composite_products cp where cp.id = composite_product_id and cp.owner_id = auth.uid()))
  with check (exists (select 1 from composite_products cp where cp.id = composite_product_id and cp.owner_id = auth.uid()));

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

-- 회원 탈퇴: the client (anon/authenticated key) can never delete a row from auth.users
-- directly — that requires the service_role key, which must never reach the browser. This
-- SECURITY DEFINER function is the standard Supabase-recommended workaround: it runs as its
-- owner (the role that created it in the SQL editor, which does have rights on auth.users),
-- and only ever deletes auth.uid() itself, so a logged-in user can only ever delete their own
-- account, never anyone else's. Every one of this app's tables already references
-- auth.users(id) on delete cascade, so this single delete is enough to also remove all of
-- that user's recipes/ingredients/products/composite products — no separate cleanup needed.
create or replace function delete_own_account()
returns void language plpgsql security definer as $$
begin
  delete from auth.users where id = auth.uid();
end; $$;
grant execute on function delete_own_account() to authenticated;
