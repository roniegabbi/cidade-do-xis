-- ============================================================================
-- MÓDULO DE GESTÃO DO FESTIVAL DO XIS · Cidade do Xis · Santa Maria
-- SQL idempotente — pode rodar quantas vezes quiser no SQL Editor do Supabase.
-- Cria: papel financeiro, evento, espaços, fornecedores, participações
-- (operações de xis + expositores), atrações, patrocinadores e financeiro.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Papel "financeiro" e funções de permissão
-- ----------------------------------------------------------------------------
alter type public.papel_usuario add value if not exists 'financeiro';

-- Equipe do festival: admin, editor ou financeiro
create or replace function public.pode_festival()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual()::text in ('admin_total','editor','financeiro'), false);
$$;

-- Financeiro: admin ou papel financeiro
create or replace function public.pode_financeiro()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual()::text in ('admin_total','financeiro'), false);
$$;

-- ----------------------------------------------------------------------------
-- 2. Eventos (edições do festival)
-- ----------------------------------------------------------------------------
create table if not exists public.festival_eventos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  edicao      text,
  data_inicio date,
  data_fim    date,
  local       text,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

insert into public.festival_eventos (nome, edicao, data_inicio, data_fim, local)
values ('4º Festival Nacional do Xis', '2026', '2026-11-13', '2026-11-15', 'Largo da Gare')
on conflict (nome) do nothing;

-- ----------------------------------------------------------------------------
-- 3. Espaços (lotes/pontos do evento)
-- ----------------------------------------------------------------------------
create table if not exists public.festival_espacos (
  id         uuid primary key default gen_random_uuid(),
  evento_id  uuid not null references public.festival_eventos(id) on delete cascade,
  codigo     text not null,
  dimensao   text not null default 'xis'
             check (dimensao in ('xis','cultural','criativo','ferromodelismo','outros')),
  metragem   numeric,
  valor      numeric not null default 0,
  energia    text,
  obs        text,
  criado_em  timestamptz not null default now(),
  unique (evento_id, codigo)
);

-- ----------------------------------------------------------------------------
-- 4. Fornecedores (usados no contas a pagar)
-- ----------------------------------------------------------------------------
create table if not exists public.festival_fornecedores (
  id            uuid primary key default gen_random_uuid(),
  razao_social  text not null,
  cnpj_cpf      text,
  contato       text,
  telefone      text,
  email         text,
  categoria     text,
  banco_dados   text,
  pix           text,
  obs           text,
  criado_em     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 5. Participações (operações de xis vinculadas + expositores das demais dimensões)
--    Operação de Xis: aponta para estabelecimentos (sem recadastro).
--    Expositor (criativo/ferromodelismo/outros): dados próprios no registro.
-- ----------------------------------------------------------------------------
create table if not exists public.festival_participacoes (
  id                 uuid primary key default gen_random_uuid(),
  evento_id          uuid not null references public.festival_eventos(id) on delete cascade,
  dimensao           text not null
                     check (dimensao in ('xis','criativo','ferromodelismo','outros')),
  estabelecimento_id uuid references public.estabelecimentos(id) on delete set null,
  nome               text,
  documento          text,
  responsavel        text,
  telefone           text,
  email              text,
  espaco_id          uuid references public.festival_espacos(id) on delete set null,
  taxa               numeric not null default 0,
  isento             boolean not null default false,
  status             text not null default 'interessado'
                     check (status in ('interessado','confirmado','cancelado')),
  obs                text,
  criado_em          timestamptz not null default now(),
  check (estabelecimento_id is not null or nome is not null)
);

-- Uma operação de xis só entra uma vez por evento
create unique index if not exists festpart_estab_unico
  on public.festival_participacoes (evento_id, estabelecimento_id)
  where estabelecimento_id is not null;

-- Um espaço só pode estar ocupado por uma participação ativa
create unique index if not exists festpart_espaco_unico
  on public.festival_participacoes (espaco_id)
  where espaco_id is not null and status <> 'cancelado';

-- ----------------------------------------------------------------------------
-- 6. Atrações culturais
-- ----------------------------------------------------------------------------
create table if not exists public.festival_atracoes (
  id         uuid primary key default gen_random_uuid(),
  evento_id  uuid not null references public.festival_eventos(id) on delete cascade,
  nome       text not null,
  tipo       text,
  dia        date,
  horario    text,
  palco      text,
  espaco_id  uuid references public.festival_espacos(id) on delete set null,
  cache      numeric not null default 0,
  status     text not null default 'prevista'
             check (status in ('prevista','confirmada','realizada','cancelada')),
  obs        text,
  criado_em  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 7. Patrocinadores (captação com status previsto/empenhado/recebido)
-- ----------------------------------------------------------------------------
create table if not exists public.festival_patrocinadores (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references public.festival_eventos(id) on delete cascade,
  nome           text not null,
  documento      text,
  contato        text,
  telefone       text,
  email          text,
  cota           text,
  valor          numeric not null default 0,
  contrapartidas text,
  status         text not null default 'previsto'
                 check (status in ('previsto','empenhado','recebido','cancelado')),
  obs            text,
  criado_em      timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 8. Financeiro (contas a receber e a pagar, por evento)
--    "atrasado" é derivado: previsto (realizado=false) com vencimento < hoje.
-- ----------------------------------------------------------------------------
create table if not exists public.festival_financeiro (
  id               uuid primary key default gen_random_uuid(),
  evento_id        uuid not null references public.festival_eventos(id) on delete cascade,
  tipo             text not null check (tipo in ('receber','pagar')),
  descricao        text not null,
  valor            numeric not null,
  vencimento       date,
  realizado        boolean not null default false,
  data_realizacao  date,
  fornecedor_id    uuid references public.festival_fornecedores(id) on delete set null,
  patrocinador_id  uuid references public.festival_patrocinadores(id) on delete set null,
  participacao_id  uuid references public.festival_participacoes(id) on delete set null,
  atracao_id       uuid references public.festival_atracoes(id) on delete set null,
  espaco_id        uuid references public.festival_espacos(id) on delete set null,
  obs              text,
  criado_em        timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 9. RLS — equipe do festival lê/escreve; financeiro tem exclusividade no caixa;
--    nada é visível ao público (anon).
-- ----------------------------------------------------------------------------
alter table public.festival_eventos         enable row level security;
alter table public.festival_espacos         enable row level security;
alter table public.festival_fornecedores    enable row level security;
alter table public.festival_participacoes   enable row level security;
alter table public.festival_atracoes        enable row level security;
alter table public.festival_patrocinadores  enable row level security;
alter table public.festival_financeiro      enable row level security;

drop policy if exists festev_all  on public.festival_eventos;
create policy festev_all  on public.festival_eventos        for all
  using (public.pode_festival()) with check (public.pode_festival());

drop policy if exists festesp_all on public.festival_espacos;
create policy festesp_all on public.festival_espacos        for all
  using (public.pode_festival()) with check (public.pode_festival());

drop policy if exists festforn_all on public.festival_fornecedores;
create policy festforn_all on public.festival_fornecedores  for all
  using (public.pode_festival()) with check (public.pode_festival());

drop policy if exists festpart_all on public.festival_participacoes;
create policy festpart_all on public.festival_participacoes for all
  using (public.pode_festival()) with check (public.pode_festival());

drop policy if exists festatr_all on public.festival_atracoes;
create policy festatr_all on public.festival_atracoes       for all
  using (public.pode_festival()) with check (public.pode_festival());

drop policy if exists festpat_all on public.festival_patrocinadores;
create policy festpat_all on public.festival_patrocinadores for all
  using (public.pode_festival()) with check (public.pode_festival());

-- Financeiro: leitura para a equipe do festival; escrita só admin/financeiro
drop policy if exists festfin_sel on public.festival_financeiro;
create policy festfin_sel on public.festival_financeiro for select
  using (public.pode_festival());
drop policy if exists festfin_ins on public.festival_financeiro;
create policy festfin_ins on public.festival_financeiro for insert
  with check (public.pode_financeiro());
drop policy if exists festfin_upd on public.festival_financeiro;
create policy festfin_upd on public.festival_financeiro for update
  using (public.pode_financeiro()) with check (public.pode_financeiro());
drop policy if exists festfin_del on public.festival_financeiro;
create policy festfin_del on public.festival_financeiro for delete
  using (public.pode_financeiro());

grant select, insert, update, delete on
  public.festival_eventos, public.festival_espacos, public.festival_fornecedores,
  public.festival_participacoes, public.festival_atracoes,
  public.festival_patrocinadores, public.festival_financeiro
to authenticated;

-- ============================================================================
-- FIM. Após rodar: dê o papel 'financeiro' a quem cuidará do caixa, ex.:
--   update public.perfis set papel='financeiro' where email='fulano@email.com';
-- (admin_total já tem acesso a tudo.)
-- ============================================================================
