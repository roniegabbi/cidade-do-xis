-- ============================================================================
-- CIDADE DO XIS — Schema Supabase (PostgreSQL)
-- Plataforma da cadeia produtiva do Xis · Santa Maria/RS
--
-- Como usar:
--   1. No painel do Supabase, abra "SQL Editor" → "New query".
--   2. Cole TODO este arquivo e clique em "Run".
--   3. Rode uma vez só. É idempotente o suficiente para recriar do zero,
--      mas NÃO rode em produção com dados — ele recria objetos.
--
-- Cobre: categorias, bairros, estabelecimentos (+ itens de cardápio),
-- perfis/usuários (ligados ao Auth), mídia, imagens da capa, parceiros,
-- índices, trigger de updated_at, RLS por papel e buckets de Storage.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Extensões
-- ----------------------------------------------------------------------------
create extension if not exists "pgcrypto";      -- gen_random_uuid()
create extension if not exists "unaccent";       -- busca sem acento (opcional)

-- ----------------------------------------------------------------------------
-- 1. Tipos (enums)
-- ----------------------------------------------------------------------------
do $$ begin
  create type public.papel_usuario as enum
    ('admin_total','editor','curador','visualizador');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.status_estab as enum ('pendente','publicado','rejeitado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.tipo_midia as enum ('img','video','yt');
exception when duplicate_object then null; end $$;

-- ----------------------------------------------------------------------------
-- 2. Função utilitária: updated_at automático
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ----------------------------------------------------------------------------
-- 3. Lookups: categorias e bairros (alimentam os selects do admin)
-- ----------------------------------------------------------------------------
create table if not exists public.categorias (
  nome text primary key,
  ordem int not null default 0
);

create table if not exists public.bairros (
  nome text primary key
);

-- ----------------------------------------------------------------------------
-- 4. Perfis (1:1 com auth.users) — controla o papel/nível de acesso
-- ----------------------------------------------------------------------------
create table if not exists public.perfis (
  id          uuid primary key references auth.users(id) on delete cascade,
  nome        text,
  email       text,
  papel       public.papel_usuario not null default 'visualizador',
  criado_em   timestamptz not null default now()
);

-- Cria o perfil automaticamente quando um usuário se registra no Auth.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, nome, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'full_name'),
          new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Função SECURITY DEFINER para ler o papel do usuário atual SEM recursão de RLS.
create or replace function public.papel_atual()
returns public.papel_usuario
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() = 'admin_total', false);
$$;

-- Pode editar conteúdo (admin ou editor).
create or replace function public.pode_editar()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() in ('admin_total','editor'), false);
$$;

-- Equipe (admin, editor ou curador) — vê itens não publicados.
create or replace function public.is_equipe()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() in ('admin_total','editor','curador'), false);
$$;

-- ----------------------------------------------------------------------------
-- 5. Estabelecimentos (unifica "publicados" e "pendentes")
-- ----------------------------------------------------------------------------
create table if not exists public.estabelecimentos (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  categoria     text references public.categorias(nome) on update cascade,
  bairro        text references public.bairros(nome) on update cascade,
  especialidade text,
  descricao     text,
  nota          numeric(2,1) check (nota >= 0 and nota <= 5),
  emoji         text,
  cor           text,                 -- hex da identidade (#662382 ...)
  horario       text,                 -- "18h–01h"
  telefone      text,
  endereco      text,
  contato       text,                 -- contato de quem submeteu (pendentes)
  map_x         int,                  -- coordenada no mapa SVG (ilustração de reserva)
  map_y         int,
  latitude      double precision,     -- coordenada real (Google Maps)
  longitude     double precision,     -- coordenada real (Google Maps)
  status        public.status_estab not null default 'pendente',
  dono_id       uuid references auth.users(id) on delete set null,
  criado_em     timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

drop trigger if exists trg_estab_updated on public.estabelecimentos;
create trigger trg_estab_updated before update on public.estabelecimentos
  for each row execute function public.set_updated_at();

create index if not exists idx_estab_status   on public.estabelecimentos(status);
create index if not exists idx_estab_categoria on public.estabelecimentos(categoria);
create index if not exists idx_estab_bairro    on public.estabelecimentos(bairro);
create index if not exists idx_estab_dono       on public.estabelecimentos(dono_id);

-- Itens de cardápio (era o array "itens[]")
create table if not exists public.estabelecimento_itens (
  id               uuid primary key default gen_random_uuid(),
  estabelecimento_id uuid not null references public.estabelecimentos(id) on delete cascade,
  nome             text not null,
  ordem            int not null default 0
);
create index if not exists idx_itens_estab on public.estabelecimento_itens(estabelecimento_id);

-- ----------------------------------------------------------------------------
-- 6. Mídia (galeria: imagens, vídeos e thumbs do YouTube)
-- ----------------------------------------------------------------------------
create table if not exists public.midia (
  id               uuid primary key default gen_random_uuid(),
  tipo             public.tipo_midia not null,
  url              text not null,     -- URL pública (Storage) ou thumb do YT
  legenda          text,
  estabelecimento_id uuid references public.estabelecimentos(id) on delete set null,
  criado_em        timestamptz not null default now()
);
create index if not exists idx_midia_estab on public.midia(estabelecimento_id);

-- ----------------------------------------------------------------------------
-- 7. Imagens da capa (laterais do hero) — substitui o localStorage
-- ----------------------------------------------------------------------------
create table if not exists public.imagens_capa (
  id        uuid primary key default gen_random_uuid(),
  url       text not null,
  legenda   text,
  ordem     int not null default 0,   -- define a alternância E/D
  ativo     boolean not null default true,
  fundo     boolean not null default false,  -- foto escolhida como fundo imersivo da capa
  criado_em timestamptz not null default now()
);
-- idempotente: garante a coluna em bancos já criados
alter table public.imagens_capa add column if not exists fundo boolean not null default false;
create index if not exists idx_capa_ordem on public.imagens_capa(ordem) where ativo;

-- ----------------------------------------------------------------------------
-- 8. Parceiros (logos)
-- ----------------------------------------------------------------------------
-- Coluna oficial do logo é "logo" (ver §20). Mantida única e consistente aqui.
create table if not exists public.parceiros (
  id        uuid primary key default gen_random_uuid(),
  nome      text,
  logo      text,
  link      text,
  ordem     int not null default 0,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

-- ============================================================================
-- 9. RLS — Row Level Security
-- ============================================================================
alter table public.categorias            enable row level security;
alter table public.bairros               enable row level security;
alter table public.perfis                enable row level security;
alter table public.estabelecimentos      enable row level security;
alter table public.estabelecimento_itens enable row level security;
alter table public.midia                 enable row level security;
alter table public.imagens_capa          enable row level security;
alter table public.parceiros             enable row level security;

-- ---- Categorias / Bairros: leitura pública, escrita só equipe ----
drop policy if exists cat_sel on public.categorias;
create policy cat_sel on public.categorias for select using (true);
drop policy if exists cat_wr on public.categorias;
create policy cat_wr on public.categorias for all
  using (public.pode_editar()) with check (public.pode_editar());

drop policy if exists bai_sel on public.bairros;
create policy bai_sel on public.bairros for select using (true);
drop policy if exists bai_wr on public.bairros;
create policy bai_wr on public.bairros for all
  using (public.pode_editar()) with check (public.pode_editar());

-- ---- Perfis: cada um vê o seu; admin vê/edita todos ----
drop policy if exists perfil_sel on public.perfis;
create policy perfil_sel on public.perfis for select
  using (id = auth.uid() or public.is_admin());
drop policy if exists perfil_upd on public.perfis;
create policy perfil_upd on public.perfis for update
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());
drop policy if exists perfil_admin_all on public.perfis;
create policy perfil_admin_all on public.perfis for all
  using (public.is_admin()) with check (public.is_admin());

-- ---- Estabelecimentos ----
-- Público vê os publicados; equipe vê todos (inclui pendentes).
drop policy if exists estab_sel_pub on public.estabelecimentos;
create policy estab_sel_pub on public.estabelecimentos for select
  using (status = 'publicado' or public.is_equipe() or dono_id = auth.uid());

-- Dono pode cadastrar o próprio (entra como 'pendente'); equipe também.
drop policy if exists estab_ins on public.estabelecimentos;
create policy estab_ins on public.estabelecimentos for insert
  with check (public.is_equipe() or dono_id = auth.uid());

-- Editor/admin editam tudo; curador atualiza (ex.: aprovar status);
-- dono edita o próprio.
drop policy if exists estab_upd on public.estabelecimentos;
create policy estab_upd on public.estabelecimentos for update
  using (public.is_equipe() or dono_id = auth.uid())
  with check (public.is_equipe() or dono_id = auth.uid());

drop policy if exists estab_del on public.estabelecimentos;
create policy estab_del on public.estabelecimentos for delete
  using (public.pode_editar());

-- ---- Itens de cardápio: leitura pública (do que está publicado), escrita equipe ----
drop policy if exists itens_sel on public.estabelecimento_itens;
create policy itens_sel on public.estabelecimento_itens for select using (
  public.is_equipe() or exists (
    select 1 from public.estabelecimentos e
    where e.id = estabelecimento_id and (e.status='publicado' or e.dono_id=auth.uid())
  )
);
drop policy if exists itens_wr on public.estabelecimento_itens;
create policy itens_wr on public.estabelecimento_itens for all using (
  public.pode_editar() or exists (
    select 1 from public.estabelecimentos e
    where e.id = estabelecimento_id and e.dono_id = auth.uid()
  )
) with check (
  public.pode_editar() or exists (
    select 1 from public.estabelecimentos e
    where e.id = estabelecimento_id and e.dono_id = auth.uid()
  )
);

-- ---- Mídia: leitura pública, escrita equipe ----
drop policy if exists midia_sel on public.midia;
create policy midia_sel on public.midia for select using (true);
drop policy if exists midia_wr on public.midia;
create policy midia_wr on public.midia for all
  using (public.pode_editar()) with check (public.pode_editar());

-- ---- Imagens da capa: leitura pública (ativas), escrita equipe ----
drop policy if exists capa_sel on public.imagens_capa;
create policy capa_sel on public.imagens_capa for select
  using (ativo or public.is_equipe());
drop policy if exists capa_wr on public.imagens_capa;
create policy capa_wr on public.imagens_capa for all
  using (public.pode_editar()) with check (public.pode_editar());

-- ---- Parceiros: leitura pública, escrita equipe ----
drop policy if exists parc_sel on public.parceiros;
create policy parc_sel on public.parceiros for select using (true);
drop policy if exists parc_wr on public.parceiros;
create policy parc_wr on public.parceiros for all
  using (public.pode_editar()) with check (public.pode_editar());

-- ============================================================================
-- 10. Storage — buckets públicos para upload de fotos/logos/vídeos
-- ============================================================================
insert into storage.buckets (id, name, public) values
  ('estabelecimentos','estabelecimentos', true),
  ('midia','midia', true),
  ('capa','capa', true),
  ('parceiros','parceiros', true)
on conflict (id) do nothing;

-- Leitura pública dos buckets acima.
drop policy if exists storage_pub_read on storage.objects;
create policy storage_pub_read on storage.objects for select
  using (bucket_id in ('estabelecimentos','midia','capa','parceiros'));

-- Upload/edição/remoção apenas para a equipe (admin/editor) autenticada.
drop policy if exists storage_equipe_ins on storage.objects;
create policy storage_equipe_ins on storage.objects for insert to authenticated
  with check (bucket_id in ('estabelecimentos','midia','capa','parceiros') and public.pode_editar());

drop policy if exists storage_equipe_upd on storage.objects;
create policy storage_equipe_upd on storage.objects for update to authenticated
  using (bucket_id in ('estabelecimentos','midia','capa','parceiros') and public.pode_editar());

drop policy if exists storage_equipe_del on storage.objects;
create policy storage_equipe_del on storage.objects for delete to authenticated
  using (bucket_id in ('estabelecimentos','midia','capa','parceiros') and public.pode_editar());

-- ============================================================================
-- 11. SEED — dados iniciais (categorias, bairros e os 8 estabelecimentos)
-- ============================================================================
insert into public.categorias (nome, ordem) values
  ('Trailer',1),('Lanchonete',2),('Restaurante',3)
on conflict (nome) do nothing;

insert into public.bairros (nome) values
  ('Centro'),('Camobi'),('Patronato'),('N. Sra. de Fátima'),('Itararé'),
  ('N. Sra. do Rosário'),('Medianeira'),('Passo d''Areia'),('Tancredo Neves')
on conflict (nome) do nothing;

-- Estabelecimentos publicados (catálogo da vitrine)
insert into public.estabelecimentos
  (nome, categoria, bairro, especialidade, descricao, nota, emoji, cor, horario, telefone, endereco, map_x, map_y, latitude, longitude, status)
values
  ('Xis do Gaúcho','Trailer','Centro','Xis Cavalo lendário','Tradição há mais de 20 anos no coração de Santa Maria. O xis cavalo daqui é parada obrigatória.',4.9,'🌯','#662382','18h–01h','(55) 99999-0001','Praça Saldanha Marinho',380,230,-29.6868,-53.8149,'publicado'),
  ('Xis da Praça','Trailer','Centro','Xis Salada caprichado','Clássico da praça, fila garantida nas noites de sexta.',4.7,'🥪','#E5006D','19h–00h','(55) 99999-0002','Rua do Acampamento',420,210,-29.6856,-53.8108,'publicado'),
  ('Camobi Lanches','Lanchonete','Camobi','Xis universitário','Point da galera da UFSM. Porção generosa e preço de estudante.',4.6,'🍔','#51AE32','18h–02h','(55) 99999-0003','Av. Roraima',640,250,-29.7163,-53.7158,'publicado'),
  ('Xis do Patronato','Trailer','Patronato','Xis Coração','O famoso xis coração, receita da casa que virou tradição do bairro.',4.8,'🌭','#302683','18h30–00h','(55) 99999-0004','Rua Appel',300,160,-29.6757,-53.8262,'publicado'),
  ('Fátima Xis','Restaurante','N. Sra. de Fátima','Xis gourmet','Versão gourmet com pão brioche e blend especial de carnes.',4.5,'🚚','#F9B000','19h–23h','(55) 99999-0005','Av. Pres. Vargas',250,300,-29.6739,-53.8048,'publicado'),
  ('Itararé do Xis','Lanchonete','Itararé','Xis da subida','Tradicional lá na subida do Itararé, atende desde cedo até tarde.',4.4,'🍟','#2581C4','17h–00h','(55) 99999-0006','Rua Visconde',520,120,-29.6800,-53.7950,'publicado'),
  ('Rosário Lanches','Lanchonete','N. Sra. do Rosário','Xis Tudo','O xis tudo aqui leva tudo mesmo — vem com fome.',4.6,'🥙','#92C020','18h–01h','(55) 99999-0007','Rua Silva Jardim',470,340,-29.6920,-53.8230,'publicado'),
  ('Medianeira Burguer','Trailer','Medianeira','Xis artesanal','Truck itinerante de xis artesanal, acompanha a agenda da cidade.',4.7,'🚐','#662382','19h–23h30','(55) 99999-0008','Av. Borges de Medeiros',200,200,-29.7000,-53.8100,'publicado')
on conflict do nothing;

-- Submissões pendentes (fila de curadoria)
insert into public.estabelecimentos
  (nome, categoria, bairro, especialidade, emoji, cor, contato, status)
values
  ('Xis do Viaduto','Trailer','Passo d''Areia','Xis Calabresa','🌯','#F9B000','(55) 99888-1010','pendente'),
  ('Tancredo Lanches','Lanchonete','Tancredo Neves','Xis Duplo','🍔','#92C020','(55) 99888-2020','pendente')
on conflict do nothing;

-- Itens de cardápio dos estabelecimentos publicados
insert into public.estabelecimento_itens (estabelecimento_id, nome, ordem)
select e.id, x.nome, x.ordem
from (values
  ('Xis do Gaúcho','Xis Cavalo',1),('Xis do Gaúcho','Xis Salada',2),('Xis do Gaúcho','Xis Bacon',3),
  ('Xis da Praça','Xis Salada',1),('Xis da Praça','Xis Frango',2),('Xis da Praça','Xis Tudo',3),
  ('Camobi Lanches','Xis Duplo',1),('Camobi Lanches','Xis Calabresa',2),('Camobi Lanches','Bauru',3),
  ('Xis do Patronato','Xis Coração',1),('Xis do Patronato','Xis Salada',2),('Xis do Patronato','Xis Egg',3),
  ('Fátima Xis','Xis Gourmet',1),('Fátima Xis','Xis Costela',2),('Fátima Xis','Smash',3),
  ('Itararé do Xis','Xis Salada',1),('Itararé do Xis','Xis Bacon',2),('Itararé do Xis','Cachorrão',3),
  ('Rosário Lanches','Xis Tudo',1),('Rosário Lanches','Xis Frango',2),('Rosário Lanches','Misto',3),
  ('Medianeira Burguer','Xis Artesanal',1),('Medianeira Burguer','Xis Vegetariano',2),('Medianeira Burguer','Onion',3)
) as x(estab, nome, ordem)
join public.estabelecimentos e on e.nome = x.estab
on conflict do nothing;

-- ============================================================================
-- 12. PÓS-INSTALAÇÃO (faça manualmente)
-- ----------------------------------------------------------------------------
-- a) Crie seu login em Authentication → Users (ou pela tela de cadastro).
-- b) Promova-se a administrador rodando (troque pelo seu e-mail):
--      update public.perfis set papel='admin_total'
--      where email = 'ronie.gabbi74@gmail.com';
-- c) Pegue em Project Settings → API a "Project URL" e a chave "anon public".
--    São esses dois valores que entram no HTML para conectar o front-end.
-- ============================================================================

-- ============================================================================
-- 13. MIGRAÇÃO: coordenadas reais do Google Maps
-- ----------------------------------------------------------------------------
-- Rode este bloco SE o banco já foi criado antes de adicionarmos latitude/longitude.
-- Adiciona as colunas e preenche os 8 estabelecimentos de exemplo.
-- (Pode rodar mais de uma vez sem problema.)
-- ----------------------------------------------------------------------------
alter table public.estabelecimentos
  add column if not exists latitude  double precision,
  add column if not exists longitude double precision;

update public.estabelecimentos e
set latitude = v.lat, longitude = v.lng
from (values
  ('Xis do Gaúcho',      -29.6868, -53.8149),
  ('Xis da Praça',       -29.6856, -53.8108),
  ('Camobi Lanches',     -29.7163, -53.7158),
  ('Xis do Patronato',   -29.6757, -53.8262),
  ('Fátima Xis',  -29.6739, -53.8048),
  ('Itararé do Xis',     -29.6800, -53.7950),
  ('Rosário Lanches',    -29.6920, -53.8230),
  ('Medianeira Burguer', -29.7000, -53.8100)
) as v(nome, lat, lng)
where e.nome = v.nome and e.latitude is null;
-- ============================================================================

-- ============================================================================
-- 14. MARCA / IDENTIDADE: tabela config (chave/valor)
-- ----------------------------------------------------------------------------
-- Guarda URLs de imagens de identidade visual, como:
--   'logo_site'        -> logo da Cidade do Xis (emblema da capa)
--   'logo_prefeitura'  -> logomarca da Prefeitura (cabeçalho)
-- Leitura pública (todos veem os logos); escrita só para a equipe (pode_editar()).
-- Os arquivos ficam no bucket público 'capa', na pasta 'branding/'.
-- (Pode rodar mais de uma vez sem problema.)
-- ----------------------------------------------------------------------------
create table if not exists public.config (
  chave         text primary key,
  valor         text,
  atualizado_em timestamptz not null default now()
);

alter table public.config enable row level security;

drop policy if exists config_leitura_publica on public.config;
create policy config_leitura_publica on public.config
  for select using (true);

drop policy if exists config_escrita_equipe on public.config;
create policy config_escrita_equipe on public.config
  for all to authenticated
  using (public.pode_editar())
  with check (public.pode_editar());
-- ============================================================================


-- ============================================================================
-- 15) CADASTRE SEU XIS: cadastro público + dados do responsável
-- ----------------------------------------------------------------------------
-- O botão "Cadastre seu Xis" (site público, sem login) insere o estabelecimento
-- como 'pendente'. O endereço vira latitude/longitude (mapa) e, após a aprovação
-- do admin, o estabelecimento aparece na vitrine.
--
-- Dados sensíveis (responsável, CPF, CNPJ) ficam numa TABELA SEPARADA, legível
-- apenas pela equipe — para que o CPF nunca vaze pela leitura pública da vitrine.
-- (Rodar mais de uma vez é seguro.)
-- ----------------------------------------------------------------------------

-- 15.1) Permite o cadastro anônimo (formulário público), sempre como 'pendente'.
drop policy if exists estab_ins_publico on public.estabelecimentos;
create policy estab_ins_publico on public.estabelecimentos for insert
  to anon
  with check (status = 'pendente' and dono_id is null);

-- 15.1b) Bairro como texto livre (o cadastro público aceita qualquer bairro,
-- mesmo que ainda não exista na tabela de bairros). Remove a chave estrangeira.
alter table public.estabelecimentos
  drop constraint if exists estabelecimentos_bairro_fkey;

-- 15.2) Tabela protegida com os dados do responsável (1 por estabelecimento).
create table if not exists public.estabelecimento_responsavel (
  estabelecimento_id uuid primary key
    references public.estabelecimentos(id) on delete cascade,
  responsavel  text,
  cpf          text,
  cnpj         text,
  criado_em    timestamptz not null default now()
);

alter table public.estabelecimento_responsavel enable row level security;

-- Leitura: SOMENTE a equipe (dado pessoal/CPF nunca é público).
drop policy if exists resp_sel on public.estabelecimento_responsavel;
create policy resp_sel on public.estabelecimento_responsavel
  for select using (public.is_equipe());

-- Inserção: liberada para o formulário público (anon e autenticado).
drop policy if exists resp_ins on public.estabelecimento_responsavel;
create policy resp_ins on public.estabelecimento_responsavel
  for insert with check (true);

-- Atualizar/excluir: somente a equipe.
drop policy if exists resp_upd on public.estabelecimento_responsavel;
create policy resp_upd on public.estabelecimento_responsavel
  for update using (public.is_equipe()) with check (public.is_equipe());
drop policy if exists resp_del on public.estabelecimento_responsavel;
create policy resp_del on public.estabelecimento_responsavel
  for delete using (public.is_equipe());
-- ============================================================================


-- ============================================================================
-- 16) FOTO + REDES SOCIAIS DO ESTABELECIMENTO
-- ----------------------------------------------------------------------------
-- A foto enviada no cadastro público aparece na vitrine. Os links de redes
-- sociais aparecem na página do estabelecimento. (Rodar mais de uma vez é seguro.)
-- ----------------------------------------------------------------------------
alter table public.estabelecimentos
  add column if not exists foto      text,
  add column if not exists instagram text,
  add column if not exists facebook  text,
  add column if not exists site      text,
  add column if not exists whatsapp  text;

-- 16.1) Upload público de fotos no bucket 'estabelecimentos' (pasta 'cadastros/').
--       O bucket é público para leitura; aqui liberamos o INSERT para o anon.
drop policy if exists storage_cadastro_publico on storage.objects;
create policy storage_cadastro_publico on storage.objects
  for insert to anon
  with check (bucket_id = 'estabelecimentos' and (storage.foldername(name))[1] = 'cadastros');
-- ============================================================================


-- ============================================================================
-- 17) CATEGORIAS: Trailer, Lanchonete, Restaurante (remove 'Food Truck')
-- ----------------------------------------------------------------------------
-- A plataforma passa a ter três categorias. 'Food Truck' deixa de existir e
-- seus estabelecimentos viram 'Trailer'. (Rodar mais de uma vez é seguro.)
-- ----------------------------------------------------------------------------
insert into public.categorias (nome, ordem) values ('Restaurante',3)
  on conflict (nome) do nothing;

-- Migra os estabelecimentos de 'Food Truck' para 'Trailer'.
update public.estabelecimentos set categoria = 'Trailer' where categoria = 'Food Truck';

-- Remove a categoria antiga e reordena as três oficiais.
delete from public.categorias where nome = 'Food Truck';
update public.categorias set ordem = 1 where nome = 'Trailer';
update public.categorias set ordem = 2 where nome = 'Lanchonete';
update public.categorias set ordem = 3 where nome = 'Restaurante';
-- ============================================================================


-- ============================================================================
-- 18) DESTAQUES DO ÚLTIMO FESTIVAL DO XIS
-- ----------------------------------------------------------------------------
-- Até 4 cards manuais na capa do site. Cada destaque tem foto + textos próprios
-- (independentes da vitrine). As fotos ficam no bucket 'capa', pasta 'destaques/'.
-- A leitura é pública; só a equipe insere/edita/remove. (Rodar de novo é seguro.)
-- ----------------------------------------------------------------------------
create table if not exists public.destaques_festival (
  id            uuid primary key default gen_random_uuid(),
  foto          text,
  nome          text not null,
  especialidade text,
  bairro        text,
  horario       text,
  categoria     text,
  ordem         int not null default 0,
  criado_em     timestamptz not null default now()
);
-- Se a tabela já existir com a coluna 'nota' (versão antiga), remove — a nota é pública (votos).
alter table public.destaques_festival drop column if exists nota;

alter table public.destaques_festival enable row level security;

-- Leitura pública (aparece na capa do site).
drop policy if exists destaque_pub_read on public.destaques_festival;
create policy destaque_pub_read on public.destaques_festival
  for select using (true);

-- Inserir/editar/remover: somente a equipe.
drop policy if exists destaque_equipe_ins on public.destaques_festival;
create policy destaque_equipe_ins on public.destaques_festival
  for insert to authenticated with check (public.pode_editar());
drop policy if exists destaque_equipe_upd on public.destaques_festival;
create policy destaque_equipe_upd on public.destaques_festival
  for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
drop policy if exists destaque_equipe_del on public.destaques_festival;
create policy destaque_equipe_del on public.destaques_festival
  for delete to authenticated using (public.pode_editar());
-- ============================================================================


-- ============================================================================
-- 19) VOTAÇÃO PÚBLICA (transeunte avalia o Xis de 1 a 5 estrelas)
-- ----------------------------------------------------------------------------
-- Qualquer pessoa vota (estilo Google). O ranking da capa usa a MÉDIA pública
-- dos votos. Cada navegador tem um voter_id (gerado no front) e pode mudar o
-- próprio voto. Os votos individuais NÃO são lidos pelo público — só a média,
-- via a view de ranking. (Rodar de novo é seguro.)
-- ----------------------------------------------------------------------------
create table if not exists public.votos (
  id                 uuid primary key default gen_random_uuid(),
  estabelecimento_id uuid not null references public.estabelecimentos(id) on delete cascade,
  voter_id           text not null,
  nota               smallint not null check (nota between 1 and 5),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  unique (estabelecimento_id, voter_id)
);
create index if not exists idx_votos_estab on public.votos(estabelecimento_id);

alter table public.votos enable row level security;

-- SEGURANÇA DA VOTAÇÃO
-- Antes, o público tinha INSERT/UPDATE direto na tabela votos, e o UPDATE
-- usava using(true) — ou seja, qualquer cliente conseguia sobrescrever QUALQUER
-- voto. Agora o acesso direto de anon/authenticated à tabela é REMOVIDO e a
-- votação passa por uma função controlada (registrar_voto), que valida a nota,
-- confirma que o estabelecimento está publicado e faz upsert só do par
-- (estabelecimento_id, voter_id). Assim ninguém edita o voto de outro registro
-- diretamente, e a nota fica sempre entre 1 e 5.
drop policy if exists votos_ins_publico on public.votos;
drop policy if exists votos_upd_publico on public.votos;
-- (RLS continua ativo; sem políticas para anon/authenticated, o acesso direto
--  à tabela votos fica bloqueado — só a função abaixo grava.)

create or replace function public.registrar_voto(p_estab uuid, p_voter text, p_nota smallint)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  if p_nota is null or p_nota < 1 or p_nota > 5 then
    raise exception 'nota inválida (use 1 a 5)';
  end if;
  if p_voter is null or length(p_voter) < 8 then
    raise exception 'identificador de votante inválido';
  end if;
  if not exists (select 1 from public.estabelecimentos
                 where id = p_estab and status = 'publicado') then
    raise exception 'estabelecimento não está publicado';
  end if;
  insert into public.votos (estabelecimento_id, voter_id, nota, atualizado_em)
  values (p_estab, p_voter, p_nota, now())
  on conflict (estabelecimento_id, voter_id)
  do update set nota = excluded.nota, atualizado_em = now();
end;
$$;
revoke all on function public.registrar_voto(uuid, text, smallint) from public;
grant execute on function public.registrar_voto(uuid, text, smallint) to anon, authenticated;

-- View de ranking: média e total de votos por estabelecimento publicado.
-- Roda como dono (security_invoker=false) → o público lê só o agregado,
-- nunca os votos individuais.
drop view if exists public.estabelecimento_ranking;
create view public.estabelecimento_ranking
  with (security_invoker = false) as
  select e.id,
         coalesce(round(avg(v.nota)::numeric, 2), 0) as media,
         count(v.id)                                  as votos
  from public.estabelecimentos e
  left join public.votos v on v.estabelecimento_id = e.id
  where e.status = 'publicado'
  group by e.id;

grant select on public.estabelecimento_ranking to anon, authenticated;
-- ============================================================================

-- ============================================================================
-- §20 · PARCEIROS (logos institucionais exibidos sobre a capa do site público)
-- ----------------------------------------------------------------------------
create table if not exists public.parceiros (
  id         uuid primary key default gen_random_uuid(),
  logo       text not null,
  nome       text,
  link       text,
  ordem      int  not null default 0,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);
-- Se a tabela já existir de uma versão anterior, garante as colunas (idempotente).
alter table public.parceiros add column if not exists logo      text;
alter table public.parceiros add column if not exists nome      text;
alter table public.parceiros add column if not exists link      text;
alter table public.parceiros add column if not exists ordem     int  not null default 0;
alter table public.parceiros add column if not exists ativo     boolean not null default true;
alter table public.parceiros add column if not exists criado_em timestamptz not null default now();

-- Reconciliação com a versão antiga que usava "logo_url": copia o dado para
-- "logo" e remove a coluna duplicada, evitando confusão (o código usa "logo").
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='parceiros' and column_name='logo_url') then
    update public.parceiros set logo = coalesce(logo, logo_url) where logo is null;
    alter table public.parceiros drop column logo_url;
  end if;
end$$;
-- Um parceiro pode ter só o logo (nome opcional).
alter table public.parceiros alter column nome drop not null;

alter table public.parceiros enable row level security;

-- Leitura pública (aparece sobre a capa do site).
drop policy if exists parceiro_pub_read on public.parceiros;
create policy parceiro_pub_read on public.parceiros
  for select using (ativo = true);

-- Inserir/editar/remover: somente a equipe.
drop policy if exists parceiro_equipe_ins on public.parceiros;
create policy parceiro_equipe_ins on public.parceiros
  for insert to authenticated with check (public.pode_editar());
drop policy if exists parceiro_equipe_upd on public.parceiros;
create policy parceiro_equipe_upd on public.parceiros
  for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
drop policy if exists parceiro_equipe_del on public.parceiros;
create policy parceiro_equipe_del on public.parceiros
  for delete to authenticated using (public.pode_editar());
-- ============================================================================


-- ============================================================================
-- §22 · GALERIA DO FESTIVAL DO XIS (fotos + vídeos do YouTube)
-- ----------------------------------------------------------------------------
-- Alimentada pela equipe no Painel Admin. Leitura pública. (Rodar de novo é seguro.)
-- tipo = 'foto'  → url = imagem no bucket 'capa', pasta 'festival/'
--        'video' → url = link do YouTube.
-- ----------------------------------------------------------------------------
create table if not exists public.festival_midia (
  id        uuid primary key default gen_random_uuid(),
  tipo      text not null default 'foto' check (tipo in ('foto','video')),
  url       text not null,
  legenda   text,
  ordem     int not null default 0,
  criado_em timestamptz not null default now()
);
create index if not exists idx_festival_midia_ordem on public.festival_midia(ordem);

alter table public.festival_midia enable row level security;

drop policy if exists festmidia_pub_read on public.festival_midia;
create policy festmidia_pub_read on public.festival_midia
  for select using (true);

drop policy if exists festmidia_equipe_ins on public.festival_midia;
create policy festmidia_equipe_ins on public.festival_midia
  for insert to authenticated with check (public.pode_editar());
drop policy if exists festmidia_equipe_upd on public.festival_midia;
create policy festmidia_equipe_upd on public.festival_midia
  for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
drop policy if exists festmidia_equipe_del on public.festival_midia;
create policy festmidia_equipe_del on public.festival_midia
  for delete to authenticated using (public.pode_editar());
-- ============================================================================


-- ============================================================================
-- §23 · HISTÓRIAS DO XIS (o visitante conta a sua história)
-- ----------------------------------------------------------------------------
-- Público envia (foto obrigatória + texto OU áudio) → entra como 'pendente'.
-- A curadoria aprova no admin; só aprovadas aparecem no mural público.
-- Foto/áudio no bucket 'estabelecimentos', pasta 'historias/'. (Idempotente.)
-- ----------------------------------------------------------------------------
create table if not exists public.historias (
  id        uuid primary key default gen_random_uuid(),
  nome      text,
  foto      text not null,
  texto     text,
  audio     text,
  status    text not null default 'pendente' check (status in ('pendente','aprovada','rejeitada')),
  criado_em timestamptz not null default now()
);
create index if not exists idx_historias_status on public.historias(status, criado_em desc);

alter table public.historias enable row level security;

drop policy if exists historia_pub_read on public.historias;
create policy historia_pub_read on public.historias
  for select using (status = 'aprovada');

drop policy if exists historia_equipe_read on public.historias;
create policy historia_equipe_read on public.historias
  for select to authenticated using (public.pode_editar());

drop policy if exists historia_ins_publico on public.historias;
create policy historia_ins_publico on public.historias
  for insert to anon, authenticated
  with check (status = 'pendente');

drop policy if exists historia_equipe_upd on public.historias;
create policy historia_equipe_upd on public.historias
  for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
drop policy if exists historia_equipe_del on public.historias;
create policy historia_equipe_del on public.historias
  for delete to authenticated using (public.pode_editar());
-- ============================================================================
