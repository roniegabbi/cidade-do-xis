-- ============================================================================
-- FESTIVAL DO XIS · SQL CONSOLIDADO (fonte da verdade)
-- Idempotente: pode rodar quantas vezes quiser — cria o que falta, corrige o
-- que estiver defasado e não mexe em dados existentes.
-- Última revisão: auditoria + melhorias (contratos, convênios, ativação digital)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PAPÉIS E PERMISSÕES
-- ---------------------------------------------------------------------------
alter type public.papel_usuario add value if not exists 'financeiro';

create or replace function public.pode_festival()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual()::text in ('admin_total','editor','financeiro'), false);
$$;

create or replace function public.pode_financeiro()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual()::text in ('admin_total','financeiro'), false);
$$;

-- ---------------------------------------------------------------------------
-- 2. EVENTOS (edições)
-- ---------------------------------------------------------------------------
create table if not exists public.festival_eventos (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique, edicao text,
  data_inicio date, data_fim date, local text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
insert into public.festival_eventos (nome, edicao, data_inicio, data_fim, local, ativo) values
  ('4º Festival Nacional do Xis', '2026', '2026-11-13', '2026-11-15', 'Largo da Gare', true),
  ('3º Festival do Xis', '2025', '2025-11-14', '2025-11-16', 'Largo da Gare', false)
on conflict (nome) do nothing;

-- ---------------------------------------------------------------------------
-- 3. CATEGORIAS DE ESPAÇO (áreas) — estrutura fiel ao mapa
-- ---------------------------------------------------------------------------
create table if not exists public.festival_areas (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  nome text not null, ordem int not null default 0,
  criado_em timestamptz not null default now(),
  unique (evento_id, nome)
);
update public.festival_areas set nome='Cervejarias' where nome='Cervejarias Artesanais';
insert into public.festival_areas (evento_id, nome, ordem)
select ev.id, v.nome, v.ordem from public.festival_eventos ev
cross join (values
  ('Operações de Xis',1),('Cervejarias',2),('Mercado Criativo',3),
  ('Expositores Comerciais',4),('Café & Tortas',5),('Ativação Digital de Marcas',6),
  ('Sala GARE 1',7),('Sala GARE 2',8),('Sala GARE 3',9),('Sala GARE 4',10),('Sala GARE 5',11),
  ('Plataforma / Feira Criativa',12),('Espaço Infantil',13),
  ('Estação Marvin / Espaço dos Trens',14),('Auditório PodXis',15),('Palco',16),
  ('Espaços Ativação (patrocínio)',17),('Loja Cidade do Xis',18)
) v(nome,ordem)
where ev.nome = '4º Festival Nacional do Xis'
on conflict (evento_id, nome) do nothing;

-- ---------------------------------------------------------------------------
-- 4. ESPAÇOS (lotes 01–82) — tipos, dimensões e classificação por faixa
-- ---------------------------------------------------------------------------
create table if not exists public.festival_espacos (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  codigo text not null, dimensao text not null default 'xis',
  metragem numeric, valor numeric not null default 0,
  energia text, obs text,
  criado_em timestamptz not null default now(),
  unique (evento_id, codigo)
);
alter table public.festival_espacos add column if not exists tipo_xis text;
alter table public.festival_espacos add column if not exists area_id uuid references public.festival_areas(id) on delete set null;

alter table public.festival_espacos drop constraint if exists festival_espacos_tipo_xis_check;
alter table public.festival_espacos add constraint festival_espacos_tipo_xis_check
  check (tipo_xis is null or tipo_xis in ('trailer','estacao_fixa','cervejaria'));
alter table public.festival_espacos drop constraint if exists festival_espacos_dimensao_check;
alter table public.festival_espacos add constraint festival_espacos_dimensao_check
  check (dimensao in ('xis','cultural','criativo','ferromodelismo','outros','comercial','ativacao'));

-- cria os 82 lotes que faltarem (não altera valores dos existentes)
insert into public.festival_espacos (evento_id, codigo, dimensao, valor)
select ev.id, lpad(g::text,2,'0'), 'xis', 0
from public.festival_eventos ev cross join generate_series(1,82) g
where ev.nome = '4º Festival Nacional do Xis'
on conflict (evento_id, codigo) do nothing;

-- classificação por faixa (área + dimensão + tipo)
update public.festival_espacos e set
  area_id = case
    when s.num between 1 and 30 then (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Operações de Xis')
    when s.num between 31 and 38 then (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Cervejarias')
    when s.num between 39 and 59 then (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Mercado Criativo')
    when s.num between 60 and 70 then (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Café & Tortas')
    when s.num between 71 and 80 then (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Expositores Comerciais')
    else (select id from public.festival_areas a where a.evento_id=e.evento_id and a.nome='Ativação Digital de Marcas') end,
  dimensao = case when s.num <= 38 then 'xis' when s.num <= 59 then 'criativo'
    when s.num <= 70 then 'outros' when s.num <= 80 then 'comercial' else 'ativacao' end,
  tipo_xis = case when s.num between 1 and 5 then 'trailer'
    when s.num between 6 and 30 then 'estacao_fixa'
    when s.num between 31 and 38 then 'cervejaria' else null end
from (select id, nullif(regexp_replace(codigo,'\D','','g'),'')::int as num
      from public.festival_espacos where codigo ~ '^[0-9]+$') s
where s.id = e.id and s.num between 1 and 82;

-- ---------------------------------------------------------------------------
-- 5. CONVÊNIOS (Receitas de Convênios — ex.: SEBRAE)
-- ---------------------------------------------------------------------------
create table if not exists public.festival_convenios (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  nome text not null, valor_previsto numeric not null default 0, obs text,
  criado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 6. PARTICIPAÇÕES (operações + expositores de todas as dimensões)
-- ---------------------------------------------------------------------------
create table if not exists public.festival_participacoes (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  dimensao text not null,
  estabelecimento_id uuid references public.estabelecimentos(id) on delete set null,
  nome text, documento text, responsavel text, telefone text, email text,
  espaco_id uuid references public.festival_espacos(id) on delete set null,
  taxa numeric not null default 0, isento boolean not null default false,
  status text not null default 'interessado' check (status in ('interessado','confirmado','cancelado')),
  obs text, criado_em timestamptz not null default now(),
  check (estabelecimento_id is not null or nome is not null)
);
alter table public.festival_participacoes add column if not exists tipo_xis text;
alter table public.festival_participacoes add column if not exists convenio_id uuid references public.festival_convenios(id) on delete set null;
alter table public.festival_participacoes add column if not exists valor_subsidio numeric not null default 0;
alter table public.festival_participacoes add column if not exists contrato_url text;

alter table public.festival_participacoes drop constraint if exists festival_participacoes_tipo_xis_check;
alter table public.festival_participacoes add constraint festival_participacoes_tipo_xis_check
  check (tipo_xis is null or tipo_xis in ('trailer','estacao_fixa','cervejaria'));
alter table public.festival_participacoes drop constraint if exists festival_participacoes_dimensao_check;
alter table public.festival_participacoes add constraint festival_participacoes_dimensao_check
  check (dimensao in ('xis','criativo','ferromodelismo','outros','comercial','ativacao'));

create unique index if not exists festpart_estab_unico
  on public.festival_participacoes (evento_id, estabelecimento_id)
  where estabelecimento_id is not null;
create unique index if not exists festpart_espaco_unico
  on public.festival_participacoes (espaco_id)
  where espaco_id is not null and status <> 'cancelado';

-- ---------------------------------------------------------------------------
-- 7. ATRAÇÕES, PATROCINADORES, FORNECEDORES
-- ---------------------------------------------------------------------------
create table if not exists public.festival_atracoes (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  nome text not null, tipo text, dia date, horario text, palco text,
  espaco_id uuid references public.festival_espacos(id) on delete set null,
  cache numeric not null default 0,
  status text not null default 'prevista' check (status in ('prevista','confirmada','realizada','cancelada')),
  obs text, criado_em timestamptz not null default now()
);

create table if not exists public.festival_patrocinadores (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  nome text not null, documento text, contato text, telefone text, email text,
  cota text, valor numeric not null default 0, contrapartidas text,
  status text not null default 'previsto' check (status in ('previsto','empenhado','recebido','cancelado')),
  obs text, criado_em timestamptz not null default now()
);
alter table public.festival_patrocinadores add column if not exists origem text not null default 'privado';
alter table public.festival_patrocinadores drop constraint if exists festival_patrocinadores_origem_check;
alter table public.festival_patrocinadores add constraint festival_patrocinadores_origem_check
  check (origem in ('privado','publico'));
alter table public.festival_patrocinadores add column if not exists espaco_id uuid references public.festival_espacos(id) on delete set null;

create table if not exists public.festival_fornecedores (
  id uuid primary key default gen_random_uuid(),
  razao_social text not null, cnpj_cpf text, contato text, telefone text, email text,
  categoria text, banco_dados text, pix text, obs text,
  criado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 8. FINANCEIRO E ORÇAMENTO
-- ---------------------------------------------------------------------------
create table if not exists public.festival_financeiro (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  tipo text not null check (tipo in ('receber','pagar')),
  descricao text not null, valor numeric not null, vencimento date,
  realizado boolean not null default false, data_realizacao date,
  fornecedor_id uuid references public.festival_fornecedores(id) on delete set null,
  patrocinador_id uuid references public.festival_patrocinadores(id) on delete set null,
  participacao_id uuid references public.festival_participacoes(id) on delete set null,
  atracao_id uuid references public.festival_atracoes(id) on delete set null,
  espaco_id uuid references public.festival_espacos(id) on delete set null,
  obs text, criado_em timestamptz not null default now()
);
alter table public.festival_financeiro add column if not exists convenio_id uuid references public.festival_convenios(id) on delete set null;

create table if not exists public.festival_orcamento (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  tipo text not null check (tipo in ('receita','despesa')),
  categoria text not null, valor_previsto numeric not null default 0, obs text,
  criado_em timestamptz not null default now(),
  unique (evento_id, tipo, categoria)
);

-- ---------------------------------------------------------------------------
-- 9. INTERESSADOS 2026 (captação com curadoria separada)
-- ---------------------------------------------------------------------------
create table if not exists public.festival_interessados (
  id uuid primary key default gen_random_uuid(),
  evento_id uuid not null references public.festival_eventos(id) on delete cascade,
  categoria text not null, nome text not null,
  documento text, responsavel text, telefone text, email text,
  descricao text, boas_praticas boolean, tempo_xis text, historia text,
  status text not null default 'novo' check (status in ('novo','contatado','convertido','descartado')),
  criado_em timestamptz not null default now()
);
alter table public.festival_interessados add column if not exists tipo_operacao text;
alter table public.festival_interessados add column if not exists endereco_licenca text;
alter table public.festival_interessados add column if not exists foto_trailer text;
alter table public.festival_interessados add column if not exists qtd_equipe text;
alter table public.festival_interessados drop constraint if exists festival_interessados_categoria_check;
alter table public.festival_interessados add constraint festival_interessados_categoria_check
  check (categoria in ('xis','cervejaria','criativo','comercial','ferromodelismo','outros'));
alter table public.festival_interessados drop constraint if exists festival_interessados_tipo_operacao_check;
alter table public.festival_interessados add constraint festival_interessados_tipo_operacao_check
  check (tipo_operacao is null or tipo_operacao in ('trailer','estacao_fixa'));

-- ---------------------------------------------------------------------------
-- 10. RLS — equipe lê/escreve; financeiro exclusivo no caixa, metas e convênios
-- ---------------------------------------------------------------------------
alter table public.festival_eventos enable row level security;
alter table public.festival_areas enable row level security;
alter table public.festival_espacos enable row level security;
alter table public.festival_convenios enable row level security;
alter table public.festival_participacoes enable row level security;
alter table public.festival_atracoes enable row level security;
alter table public.festival_patrocinadores enable row level security;
alter table public.festival_fornecedores enable row level security;
alter table public.festival_financeiro enable row level security;
alter table public.festival_orcamento enable row level security;
alter table public.festival_interessados enable row level security;

drop policy if exists festev_all on public.festival_eventos;
create policy festev_all on public.festival_eventos for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festarea_all on public.festival_areas;
create policy festarea_all on public.festival_areas for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festesp_all on public.festival_espacos;
create policy festesp_all on public.festival_espacos for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festpart_all on public.festival_participacoes;
create policy festpart_all on public.festival_participacoes for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festatr_all on public.festival_atracoes;
create policy festatr_all on public.festival_atracoes for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festpat_all on public.festival_patrocinadores;
create policy festpat_all on public.festival_patrocinadores for all using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festforn_all on public.festival_fornecedores;
create policy festforn_all on public.festival_fornecedores for all using (public.pode_festival()) with check (public.pode_festival());

-- Financeiro, orçamento e convênios: leitura equipe; escrita só admin/financeiro
drop policy if exists festfin_sel on public.festival_financeiro;
create policy festfin_sel on public.festival_financeiro for select using (public.pode_festival());
drop policy if exists festfin_ins on public.festival_financeiro;
create policy festfin_ins on public.festival_financeiro for insert with check (public.pode_financeiro());
drop policy if exists festfin_upd on public.festival_financeiro;
create policy festfin_upd on public.festival_financeiro for update using (public.pode_financeiro()) with check (public.pode_financeiro());
drop policy if exists festfin_del on public.festival_financeiro;
create policy festfin_del on public.festival_financeiro for delete using (public.pode_financeiro());

drop policy if exists festorc_sel on public.festival_orcamento;
create policy festorc_sel on public.festival_orcamento for select using (public.pode_festival());
drop policy if exists festorc_wr on public.festival_orcamento;
create policy festorc_wr on public.festival_orcamento for all using (public.pode_financeiro()) with check (public.pode_financeiro());

drop policy if exists festcnv_all on public.festival_convenios;
drop policy if exists festcnv_sel on public.festival_convenios;
create policy festcnv_sel on public.festival_convenios for select using (public.pode_festival());
drop policy if exists festcnv_wr on public.festival_convenios;
create policy festcnv_wr on public.festival_convenios for all using (public.pode_financeiro()) with check (public.pode_financeiro());

drop policy if exists festint_sel on public.festival_interessados;
create policy festint_sel on public.festival_interessados for select using (public.pode_festival());
drop policy if exists festint_upd on public.festival_interessados;
create policy festint_upd on public.festival_interessados for update using (public.pode_festival()) with check (public.pode_festival());
drop policy if exists festint_del on public.festival_interessados;
create policy festint_del on public.festival_interessados for delete using (public.pode_festival());

grant select, insert, update, delete on
  public.festival_eventos, public.festival_areas, public.festival_espacos,
  public.festival_convenios, public.festival_participacoes, public.festival_atracoes,
  public.festival_patrocinadores, public.festival_fornecedores,
  public.festival_financeiro, public.festival_orcamento
to authenticated;
grant select, update, delete on public.festival_interessados to authenticated;

-- ---------------------------------------------------------------------------
-- 11. FUNÇÕES PÚBLICAS (formulários por link)
-- ---------------------------------------------------------------------------
create or replace function public.manifestar_interesse_2026(p_categoria text, p_dados jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_ev uuid; v_nome text;
begin
  select id into v_ev from festival_eventos where ativo order by data_inicio desc limit 1;
  if v_ev is null then raise exception 'Captação encerrada'; end if;
  if p_categoria not in ('xis','cervejaria','criativo','comercial','ferromodelismo','outros') then
    raise exception 'Categoria inválida'; end if;
  v_nome := left(trim(coalesce(p_dados->>'nome','')), 200);
  if v_nome = '' then raise exception 'Informe o nome'; end if;
  insert into festival_interessados
    (evento_id, categoria, nome, documento, responsavel, telefone, email,
     descricao, boas_praticas, tempo_xis, qtd_equipe, historia,
     tipo_operacao, endereco_licenca, foto_trailer)
  values (v_ev, p_categoria, v_nome,
    left(p_dados->>'documento',40), left(p_dados->>'responsavel',200),
    left(p_dados->>'telefone',40), left(p_dados->>'email',200),
    left(p_dados->>'descricao',600), (p_dados->>'boas_praticas')::boolean,
    left(p_dados->>'tempo_xis',60), left(p_dados->>'qtd_equipe',20),
    left(p_dados->>'historia',1000),
    nullif(p_dados->>'tipo_operacao',''), left(p_dados->>'endereco_licenca',300),
    left(p_dados->>'foto_trailer',500));
end $$;
revoke all on function public.manifestar_interesse_2026(text, jsonb) from public;
grant execute on function public.manifestar_interesse_2026(text, jsonb) to anon, authenticated;

create or replace function public.inscrever_festival(p_categoria text, p_dados jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_ev uuid; v_nome text;
begin
  select id into v_ev from festival_eventos where ativo order by data_inicio desc limit 1;
  if v_ev is null then raise exception 'Inscrições encerradas'; end if;
  v_nome := left(trim(coalesce(p_dados->>'nome','')), 200);
  if v_nome = '' then raise exception 'Informe o nome'; end if;
  if p_categoria = 'patrocinador' then
    insert into festival_patrocinadores (evento_id, nome, documento, contato, telefone, email, obs, status, origem)
    values (v_ev, v_nome, left(p_dados->>'documento',40), left(p_dados->>'responsavel',200),
            left(p_dados->>'telefone',40), left(p_dados->>'email',200),
            left(p_dados->>'obs',600), 'previsto', 'privado');
    return;
  end if;
  raise exception 'Use o formulário de manifestação de interesse';
end $$;
revoke all on function public.inscrever_festival(text, jsonb) from public;
grant execute on function public.inscrever_festival(text, jsonb) to anon, authenticated;

-- ============================================================================
-- FIM · Papéis: update public.perfis set papel='financeiro' where email='...';
-- ============================================================================
