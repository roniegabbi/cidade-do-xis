-- ============================================================================
-- RODAR AGORA · Cidade do Xis
-- Cole TUDO no SQL Editor do Supabase e clique em "Run".
-- Cria o que está faltando: §18 (destaques) e §19 (votação + ranking).
-- A tabela 'parceiros' (§20) já existe — não está aqui.
-- Pode rodar de novo sem medo: tudo é idempotente.
-- ============================================================================


-- ============================================================================
-- §18 · DESTAQUES DO ÚLTIMO FESTIVAL DO XIS
-- Até 4 cards manuais na capa do site. Fotos no bucket 'capa', pasta 'destaques/'.
-- Leitura pública; só a equipe insere/edita/remove.
-- ============================================================================
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
alter table public.destaques_festival drop column if exists nota;

alter table public.destaques_festival enable row level security;

drop policy if exists destaque_pub_read on public.destaques_festival;
create policy destaque_pub_read on public.destaques_festival
  for select using (true);

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
-- §19 · VOTAÇÃO PÚBLICA (transeunte avalia o Xis de 1 a 5 estrelas)
-- Qualquer pessoa vota (estilo Google). O ranking da capa usa a MÉDIA pública.
-- Votos individuais NÃO são lidos pelo público — só a média, via a view.
-- ============================================================================
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

drop policy if exists votos_ins_publico on public.votos;
create policy votos_ins_publico on public.votos
  for insert to anon, authenticated
  with check (nota between 1 and 5);

drop policy if exists votos_upd_publico on public.votos;
create policy votos_upd_publico on public.votos
  for update to anon, authenticated
  using (true) with check (nota between 1 and 5);

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
-- §21 · ESCOLHA DA FOTO DE FUNDO DA CAPA
-- Marca qual imagem de capa é o fundo imersivo do hero (independe da ordem).
-- A política capa_wr (for all) já permite o UPDATE feito pelo admin.
-- ============================================================================
alter table public.imagens_capa
  add column if not exists fundo boolean not null default false;


-- ============================================================================
-- §22 · GALERIA DO FESTIVAL DO XIS (fotos + vídeos do YouTube)
-- Alimentada pela equipe no Painel Admin. Leitura pública.
-- tipo = 'foto'  (url = imagem no bucket 'capa', pasta 'festival/')
--        'video' (url = link do YouTube).
-- ============================================================================
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
-- §23 · HISTÓRIAS DO XIS (o visitante conta a sua história)
-- O público envia (foto obrigatória + texto OU áudio) e fica 'pendente'.
-- A curadoria (equipe) aprova no Painel Admin; só as aprovadas aparecem no
-- mural público. Foto e áudio vão para o bucket 'estabelecimentos', pasta
-- 'historias/' (mesmo bucket que já aceita upload público do "Cadastre seu Xis").
-- ============================================================================
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

-- Leitura pública: só as histórias aprovadas aparecem no mural.
drop policy if exists historia_pub_read on public.historias;
create policy historia_pub_read on public.historias
  for select using (status = 'aprovada');

-- A equipe (curadoria) enxerga tudo, inclusive pendentes.
drop policy if exists historia_equipe_read on public.historias;
create policy historia_equipe_read on public.historias
  for select to authenticated using (public.pode_editar());

-- Qualquer visitante envia a própria história; entra sempre como 'pendente'.
drop policy if exists historia_ins_publico on public.historias;
create policy historia_ins_publico on public.historias
  for insert to anon, authenticated
  with check (status = 'pendente');

-- Aprovar/rejeitar/remover: somente a equipe.
drop policy if exists historia_equipe_upd on public.historias;
create policy historia_equipe_upd on public.historias
  for update to authenticated using (public.pode_editar()) with check (public.pode_editar());
drop policy if exists historia_equipe_del on public.historias;
create policy historia_equipe_del on public.historias
  for delete to authenticated using (public.pode_editar());
-- ============================================================================
-- FIM. Depois de rodar, recarregue o site público.
-- ============================================================================
