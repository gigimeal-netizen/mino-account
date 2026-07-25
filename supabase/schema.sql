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
  category text not null default '',         -- 2026-07-25: superseded by `tags` below (a recipe now carries several free-text
                                              -- labels like a board's tags, not just one) — column kept for existing data, unused going forward
  tags text[] not null default '{}',         -- free-text, multiple per recipe (제빵/OO제과/... — a recipe can have both a "type" tag
                                              -- and a "vendor" tag at once), same free-text philosophy as ingredients.category
  mode text not null default 'A',
  base_flour numeric not null default 0,
  multiplier numeric not null default 1,
  target_total numeric not null default 0,
  portions jsonb not null default '[]',
  flours jsonb not null default '[]',
  ingredients jsonb not null default '[]',
  notes text not null default '',
  share_token uuid,               -- null = link sharing off
  -- 원가 계산 전용 독립 사본. 원가 계산 화면은 이 세 컬럼만 읽고 쓴다 — flours/ingredients
  -- (메인 계산기가 편집하는 실데이터)와는 별개라서, 메인 계산기에서 배합을 조정해도
  -- 원가 계산 쪽 재료 연결은 말없이 안 바뀐다. cost_snapshot_taken_at이 null이면 아직 원가
  -- 계산에서 한 번도 안 열어본 레시피. account.html의 openCostCalcRecipe()가 이 값이
  -- updated_at보다 오래됐으면 "원본이 수정됨"으로 판단해 안내한다.
  cost_snapshot_flours jsonb,
  cost_snapshot_ingredients jsonb,
  cost_snapshot_taken_at timestamptz,
  created_at timestamptz not null default now(),
  -- account.html의 serializeCurrentRecipe()가 저장할 때마다 명시적으로 now()를 채워 넣는다 —
  -- Postgres에 이 컬럼을 자동으로 갱신하는 트리거가 없어서, 클라이언트가 안 채우면 생성 시각
  -- 그대로 영원히 안 바뀐다(원가 계산 스냅샷과의 신선도 비교가 성립하려면 반드시 필요).
  updated_at timestamptz not null default now()
);

create table recipe_shares (
  recipe_id uuid not null references recipes(id) on delete cascade,
  shared_with_user_id uuid not null references auth.users(id) on delete cascade,
  shared_with_email text not null default '', -- denormalized copy of what the owner typed, so the
                                               -- 공유 관리 screen can list recipients without needing
                                               -- a separate auth.users lookup (client can't query it directly)
  can_save boolean not null default false,    -- 2026-07-25: 공개(저장 가능)/비공개(저장 전용) — one flag per
                                               -- recipe's account-share, applied uniformly to every recipient
                                               -- (not per-person), toggled from 공유 관리
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

-- 2026-07-25: 태그 단위 계정 공유 — 레시피 하나하나가 아니라 (소유자, 태그) 쌍으로 계정을 지정해
-- 공유한다. 기존 tag_shares(익명 링크, 태그 공유)와는 별개 — 이건 "누구인지"로 검사하는 계정 기반이라
-- 회수(행 삭제)가 즉시, 확실하게 먹힌다는 점이 다르다. recipe_shares와 동일한 구조(can_save,
-- shared_with_email)를 그대로 따른다.
create table tag_account_shares (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  tag text not null,
  shared_with_user_id uuid not null references auth.users(id) on delete cascade,
  shared_with_email text not null default '',
  can_save boolean not null default false,
  created_at timestamptz not null default now(),
  unique (owner_id, tag, shared_with_user_id)
);
alter table tag_account_shares enable row level security;
create policy "owner full access" on tag_account_shares for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "recipient sees own share row" on tag_account_shares for select
  using (shared_with_user_id = auth.uid());

-- "이 레시피의 소유자가 나에게 이 레시피가 가진 태그 중 하나를 공유했는가"를 검사.
create or replace function is_recipe_tag_shared_with_me(p_owner_id uuid, p_tags text[])
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from tag_account_shares
    where owner_id = p_owner_id and shared_with_user_id = auth.uid() and tag = any(p_tags)
  );
$$;

-- Owner: full CRUD. Recipient of an account-share (레시피 개별 공유 또는 태그 공유): read only.
create policy "owner full access" on recipes for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "shared read access" on recipes for select
  using (is_recipe_shared_with_me(id) or is_recipe_tag_shared_with_me(owner_id, tags));

create policy "owner manages shares" on recipe_shares for all
  using (is_owner_of_recipe(recipe_id));
create policy "recipient sees own share row" on recipe_shares for select
  using (shared_with_user_id = auth.uid());

-- Share with a specific account by email. auth.users is never exposed to
-- clients directly, so the lookup happens inside this SECURITY DEFINER function.
-- 2026-07-25: p_can_save 추가(공개/비공개), 이미 공유된 이메일을 다시 추가하면 에러 대신
-- can_save/shared_with_email을 갱신(공유 관리 화면에서 "다시 추가 = 설정 변경"으로 쓸 수 있게).
create or replace function share_recipe_with_email(p_recipe_id uuid, p_email text, p_can_save boolean default false)
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
  insert into recipe_shares (recipe_id, shared_with_user_id, shared_with_email, can_save)
    values (p_recipe_id, target_id, p_email, p_can_save)
    on conflict (recipe_id, shared_with_user_id) do update
      set can_save = excluded.can_save, shared_with_email = excluded.shared_with_email;
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

-- 태그 전체 공유: 레시피 한 개가 아니라 (소유자, 태그) 쌍에 링크를 건다. 실시간이라
-- 스냅샷이 아님 — 링크를 만든 뒤 그 태그를 단 레시피를 더 추가해도 같은 링크로 바로 보인다.
-- 2026-07-25: 레시피당 하나였던 category를 "게시판 태그처럼" 여러 개(recipes.tags text[])로
-- 쓸 수 있게 바꾸면서, 공유도 category_shares(레시피당 카테고리 하나 전제)에서 이 tag_shares로
-- 완전히 교체됐다 — 옛 category_shares/set_category_share_token/get_recipes_by_category_share_token은
-- 더 이상 쓰지 않는다.
create table tag_shares (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  tag text not null,
  share_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  unique (owner_id, tag)
);
alter table tag_shares enable row level security;
create policy "owner full access" on tag_shares for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Issue or revoke a tag share link. Owner only. Re-enabling an already-shared tag reuses the
-- row (upsert) rather than erroring, so toggling on/off/on doesn't need a delete first — same
-- "링크 켜기/끄기" ergonomics as set_recipe_share_token().
create or replace function set_tag_share_token(p_tag text, p_enable boolean)
returns uuid language plpgsql security definer as $$
declare new_token uuid;
begin
  if p_enable then
    insert into tag_shares (owner_id, tag, share_token)
      values (auth.uid(), p_tag, gen_random_uuid())
      on conflict (owner_id, tag) do update set share_token = excluded.share_token
      returning share_token into new_token;
  else
    delete from tag_shares where owner_id = auth.uid() and tag = p_tag;
    new_token := null;
  end if;
  return new_token;
end; $$;

-- Anonymous, real-time lookup: every recipe whose tags array currently contains that tag, not
-- a frozen list taken when the link was created.
create or replace function get_recipes_by_tag_share_token(p_token uuid)
returns setof recipes language sql security definer as $$
  select r.* from recipes r
  join tag_shares ts on ts.owner_id = r.owner_id and ts.tag = any(r.tags)
  where ts.share_token = p_token;
$$;
grant execute on function get_recipes_by_tag_share_token(uuid) to anon;

-- 태그 단위 "계정" 공유 추가 (tag_account_shares 테이블/정책은 위 is_recipe_tag_shared_with_me
-- 근처에 정의됨) — share_recipe_with_email과 완전히 같은 모양, 대상 테이블/이메일만 다르다.
create or replace function share_tag_with_email(p_tag text, p_email text, p_can_save boolean default false)
returns void language plpgsql security definer as $$
declare target_id uuid;
begin
  select id into target_id from auth.users where email = p_email;
  if target_id is null then
    raise exception '해당 이메일의 계정을 찾을 수 없어요';
  end if;
  insert into tag_account_shares (owner_id, tag, shared_with_user_id, shared_with_email, can_save)
    values (auth.uid(), p_tag, target_id, p_email, p_can_save)
    on conflict (owner_id, tag, shared_with_user_id) do update
      set can_save = excluded.can_save, shared_with_email = excluded.shared_with_email;
end; $$;

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
