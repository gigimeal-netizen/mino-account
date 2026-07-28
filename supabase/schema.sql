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
  -- 2026-07-25: 레시피 아카이브(공개 게시판) — 지금까지의 공유(링크/계정 지정)와 달리, 이건
  -- 로그인 없이 누구나 볼 수 있는 진짜 공개 게시. author_display_name은 별도 프로필 테이블 없이
  -- 레시피 행에 바로 저장하는 선택적 닉네임(비우면 화면에 "익명") — recipe_shares.shared_with_email과
  -- 같은 "행에 표시용 텍스트를 바로 저장" 패턴.
  is_public boolean not null default false,
  author_display_name text not null default '',
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

-- 2026-07-28: 공유 스팸 방지 — 지금까지 recipe_shares/tag_account_shares는 owner만 행을 지울 수
-- 있어서, 받는 쪽이 원치 않는 공유를 스스로 정리할 방법이 전혀 없었다. 아무나 자기 소유 레시피를
-- 계속 만들어 이미 가입된 걸 아는 특정 이메일(예: 이 앱의 운영자 계정)에 계속 공유를 걸어 그
-- 사람의 "내 레시피" 목록을 스팸으로 도배할 수 있는 실제 취약점이었다. 받는 쪽(blocker)이 특정
-- 소유자(blocked_owner)를 차단하면, 이후 그 소유자가 걸려는 모든 신규 공유(개별/태그/초대 클레임
-- 전부, 아래 각 함수에서 검사)가 막히고, 이미 걸려있던 공유도 아래 "shared read access" 정책이
-- 즉시 걸러서 안 보이게 된다.
create table share_blocks (
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_owner_id uuid not null references auth.users(id) on delete cascade,
  note text not null default '', -- 차단 당시 정황(예: 공유돼있던 레시피 이름) — 소유자 쪽 프로필이 따로 없어 참고용
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_owner_id)
);
alter table share_blocks enable row level security;
create policy "blocker manages own blocks" on share_blocks for all
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create or replace function is_blocked_by_recipient(p_owner_id uuid)
returns boolean language sql security definer stable as $$
  select exists (select 1 from share_blocks where blocker_id = auth.uid() and blocked_owner_id = p_owner_id);
$$;

-- 2026-07-28 공유 스팸 방지 2단계 — 받는 쪽 차단(위)이 "이미 걸린 공유를 정리하는 사후 대응"
-- 이라면, 이건 "애초에 짧은 시간에 공유/초대 링크를 너무 많이 만드는 것 자체"를 막는 사전
-- 방어다. share_recipe_with_email/share_tag_with_email/create_recipe_share_invite/
-- create_tag_share_invite 네 함수 전부 본문 맨 앞에서 이 함수를 호출한다 — 이메일이 존재하는지
-- 등 다른 검증보다 먼저 실행해서, 존재하지 않는 이메일을 대상으로 한 실패한 시도까지도 횟수에
-- 포함시킨다(이메일 존재 여부를 무제한으로 훑어보는 것 자체도 막고 싶어서).
-- 클라이언트는 이 테이블에 전혀 접근하지 않는다(정책을 아예 안 둠 — RLS 활성화 + 정책 0개는
-- 기본적으로 모든 비-슈퍼유저 접근을 막는다) — 오직 이 파일의 SECURITY DEFINER 함수들만
-- 건드리며, 그 함수들은 테이블을 만든 역할(이 스키마를 실행한 역할)로 실행되므로 RLS 대상이
-- 아니다(이 파일의 다른 SECURITY DEFINER 함수들과 같은 원리 — 맨 위 is_owner_of_recipe() 참고).
create table share_rate_log (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table share_rate_log enable row level security;

create or replace function check_share_rate_limit()
returns void language plpgsql security definer as $$
declare recent_count int;
begin
  -- 오래된 기록은 그때그때 지워서 별도 정리 작업(cron) 없이도 테이블이 계속 작게 유지된다 —
  -- 이 앱 규모에서 매 호출마다 지우는 비용은 무시할 만하다.
  delete from share_rate_log where created_at < now() - interval '1 day';
  select count(*) into recent_count from share_rate_log
    where owner_id = auth.uid() and created_at > now() - interval '10 minutes';
  if recent_count >= 20 then
    raise exception '공유/초대 링크 요청이 너무 많아요 — 잠시 후 다시 시도해주세요';
  end if;
  insert into share_rate_log (owner_id) values (auth.uid());
end; $$;

-- Owner: full CRUD. Recipient of an account-share (레시피 개별 공유 또는 태그 공유): read only.
create policy "owner full access" on recipes for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "shared read access" on recipes for select
  using ((is_recipe_shared_with_me(id) or is_recipe_tag_shared_with_me(owner_id, tags)) and not is_blocked_by_recipient(owner_id));
-- 레시피 아카이브: 이건 의도적으로 "누구나"(anon 포함) 읽을 수 있는 단순 컬럼 조건 정책이다 —
-- 파일 맨 위의 "share_token is not null 정책 안 씀" 원칙은 링크 공유(원치 않는 사람에게 발견되면
-- 안 되는 것)에 관한 거고, 공개 게시판은 정반대로 발견/브라우징이 목적이라 이 방식이 맞다.
create policy "public recipes are readable by anyone" on recipes for select
  using (is_public = true);

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
  perform check_share_rate_limit();
  select id into target_id from auth.users where email = p_email;
  if target_id is null then
    raise exception '해당 이메일의 계정을 찾을 수 없어요';
  end if;
  if not exists (select 1 from recipes where id = p_recipe_id and owner_id = auth.uid()) then
    raise exception '본인 소유 레시피만 공유할 수 있어요';
  end if;
  if exists (select 1 from share_blocks where blocker_id = target_id and blocked_owner_id = auth.uid()) then
    raise exception '상대방이 회원님의 공유를 차단했어요';
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
  perform check_share_rate_limit();
  select id into target_id from auth.users where email = p_email;
  if target_id is null then
    raise exception '해당 이메일의 계정을 찾을 수 없어요';
  end if;
  if exists (select 1 from share_blocks where blocker_id = target_id and blocked_owner_id = auth.uid()) then
    raise exception '상대방이 회원님의 공유를 차단했어요';
  end if;
  insert into tag_account_shares (owner_id, tag, shared_with_user_id, shared_with_email, can_save)
    values (auth.uid(), p_tag, target_id, p_email, p_can_save)
    on conflict (owner_id, tag, shared_with_user_id) do update
      set can_save = excluded.can_save, shared_with_email = excluded.shared_with_email;
end; $$;

-- 2026-07-25: 1회용 초대 링크 — share_*_with_email은 상대가 이미 가입까지 끝난 계정이어야만
-- 동작해서, 아직 가입 전인 사람에게는 미리 공유해둘 방법이 없었다. 소유자가 링크를 만들어
-- 카톡/메일 등으로 직접 전달하면, 상대가 그 링크를 열고 로그인(또는 가입)하는 순간 그 계정
-- 앞으로 공유가 자동 적용되고 링크는 소멸한다(claimed_by가 한 번 채워지면 끝) — 먼저 여는
-- 사람이 그 자리를 가져가는 구조라 1회용이 안전상 필수. 이 테이블 자체는 owner만
-- select/update/delete 가능(익명/타인 열람 정책은 일부러 안 둠 — 클레임은 아래 RPC 하나를
-- 통해서만, 이 파일 맨 위 "share_token is not null 정책 안 씀" 설계 원칙과 같은 이유).
create table recipe_share_invites (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references recipes(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  can_save boolean not null default false,
  token uuid not null default gen_random_uuid(),
  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table recipe_share_invites enable row level security;
create policy "owner full access" on recipe_share_invites for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function create_recipe_share_invite(p_recipe_id uuid, p_can_save boolean default false)
returns uuid language plpgsql security definer as $$
declare new_token uuid;
begin
  perform check_share_rate_limit();
  if not exists (select 1 from recipes where id = p_recipe_id and owner_id = auth.uid()) then
    raise exception '본인 소유 레시피만 초대 링크를 만들 수 있어요';
  end if;
  insert into recipe_share_invites (recipe_id, owner_id, can_save)
    values (p_recipe_id, auth.uid(), p_can_save)
    returning token into new_token;
  return new_token;
end; $$;

-- 반환값: 'ok'(방금 적용됨) | 'already_yours'(같은 계정으로 재방문, 무해) |
-- 'already_claimed'(다른 계정이 먼저 가져감) | 'is_owner'(본인 링크, 조용히 무시) | 'not_found' |
-- 'blocked'(2026-07-28: 클레임하는 사람이 이 링크의 소유자를 차단해둔 상태 — 초대 링크로 차단을
-- 우회해 공유를 강제로 걸 수 없도록, 이메일 공유와 같은 차단 검사를 여기도 적용).
create or replace function claim_recipe_share_invite(p_token uuid)
returns text language plpgsql security definer as $$
declare inv recipe_share_invites%rowtype;
declare my_email text;
begin
  select * into inv from recipe_share_invites where token = p_token for update;
  if inv.id is null then return 'not_found'; end if;
  if inv.owner_id = auth.uid() then return 'is_owner'; end if;
  if inv.claimed_by is not null then
    return case when inv.claimed_by = auth.uid() then 'already_yours' else 'already_claimed' end;
  end if;
  if exists (select 1 from share_blocks where blocker_id = auth.uid() and blocked_owner_id = inv.owner_id) then
    return 'blocked';
  end if;
  select email into my_email from auth.users where id = auth.uid();
  insert into recipe_shares (recipe_id, shared_with_user_id, shared_with_email, can_save)
    values (inv.recipe_id, auth.uid(), coalesce(my_email, ''), inv.can_save)
    on conflict (recipe_id, shared_with_user_id) do update
      set can_save = excluded.can_save, shared_with_email = excluded.shared_with_email;
  update recipe_share_invites set claimed_by = auth.uid(), claimed_at = now() where id = inv.id;
  return 'ok';
end; $$;
grant execute on function claim_recipe_share_invite(uuid) to authenticated;

-- 태그용 — 위와 완전히 대칭 (tag_account_shares 대상).
create table tag_share_invites (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  tag text not null,
  can_save boolean not null default false,
  token uuid not null default gen_random_uuid(),
  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table tag_share_invites enable row level security;
create policy "owner full access" on tag_share_invites for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function create_tag_share_invite(p_tag text, p_can_save boolean default false)
returns uuid language plpgsql security definer as $$
declare new_token uuid;
begin
  perform check_share_rate_limit();
  insert into tag_share_invites (owner_id, tag, can_save) values (auth.uid(), p_tag, p_can_save)
    returning token into new_token;
  return new_token;
end; $$;

-- 반환값 목록은 claim_recipe_share_invite()와 동일('blocked' 포함, 2026-07-28).
create or replace function claim_tag_share_invite(p_token uuid)
returns text language plpgsql security definer as $$
declare inv tag_share_invites%rowtype;
declare my_email text;
begin
  select * into inv from tag_share_invites where token = p_token for update;
  if inv.id is null then return 'not_found'; end if;
  if inv.owner_id = auth.uid() then return 'is_owner'; end if;
  if inv.claimed_by is not null then
    return case when inv.claimed_by = auth.uid() then 'already_yours' else 'already_claimed' end;
  end if;
  if exists (select 1 from share_blocks where blocker_id = auth.uid() and blocked_owner_id = inv.owner_id) then
    return 'blocked';
  end if;
  select email into my_email from auth.users where id = auth.uid();
  insert into tag_account_shares (owner_id, tag, shared_with_user_id, shared_with_email, can_save)
    values (inv.owner_id, inv.tag, auth.uid(), coalesce(my_email, ''), inv.can_save)
    on conflict (owner_id, tag, shared_with_user_id) do update
      set can_save = excluded.can_save, shared_with_email = excluded.shared_with_email;
  update tag_share_invites set claimed_by = auth.uid(), claimed_at = now() where id = inv.id;
  return 'ok';
end; $$;
grant execute on function claim_tag_share_invite(uuid) to authenticated;

-- 레시피 아카이브 신고 — 로그인 여부와 무관하게 누구나 사유만 남길 수 있는 쓰기 전용 테이블.
-- 별도 관리자 역할(RBAC) 테이블을 새로 만드는 대신, 이 개인 프로젝트의 유일한 운영자 계정
-- 이메일을 정책에 직접 박아둔다 — 여러 사업자가 쓰는 SaaS가 아니라 한 사람이 운영하는 개인
-- 도구라, 이 규모에서는 새 권한 체계보다 이게 훨씬 간단하고 충분하다.
create table recipe_reports (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references recipes(id) on delete cascade,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table recipe_reports enable row level security;
create policy "anyone can report" on recipe_reports for insert with check (true);
-- auth.users is never exposed to clients directly (같은 원칙, 파일 맨 위 참고) — 일반 RLS 정책은
-- 클라이언트 권한으로 평가되기 때문에 auth.users를 직접 조회하면 "permission denied for table
-- users"가 난다. share_recipe_with_email()처럼 SECURITY DEFINER 함수로 감싸서 우회한다.
create or replace function is_report_admin()
returns boolean language sql security definer stable as $$
  select auth.uid() = (select id from auth.users where email = 'gigimeal@gmail.com');
$$;
create policy "owner manages reports" on recipe_reports for all
  using (is_report_admin());

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

-- 내 레시피 목록/태그 필터의 사용자별 커스텀 순서 (2026-07-27) — "레시피 위치 이동, 태그
-- 위치 이동" 요청. recipes 테이블 자체에 순서 컬럼을 두지 않은 이유: 공유받은 레시피는 RLS상
-- 소유자만 그 행을 update할 수 있어서, 공유받은 사람이 자기 화면에서만 순서를 바꾸고 싶어도
-- recipes 행을 못 건드린다. 대신 "이 사용자가 이 레시피/태그를 몇 번째로 보고 싶어하는지"를
-- 뷰어(user_id) 기준으로 따로 저장 — 소유자든 공유받은 사람이든 자기 화면 순서를 독립적으로
-- 가질 수 있다. 명시적 순서가 없는 항목(아직 한 번도 옮긴 적 없는 레시피/태그)은 account.html의
-- renderMyRecipesList()가 기존 폴백 순서(레시피는 updated_at 내림차순, 태그는 첫 등장 순)를 그대로 쓴다.
create table recipe_list_order (
  user_id uuid not null references auth.users(id) on delete cascade,
  recipe_id uuid not null references recipes(id) on delete cascade,
  sort_order integer not null,
  primary key (user_id, recipe_id)
);
alter table recipe_list_order enable row level security;
create policy "user manages own recipe order" on recipe_list_order for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table tag_list_order (
  user_id uuid not null references auth.users(id) on delete cascade,
  tag text not null,
  sort_order integer not null,
  primary key (user_id, tag)
);
alter table tag_list_order enable row level security;
create policy "user manages own tag order" on tag_list_order for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
