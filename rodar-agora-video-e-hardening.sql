-- ============================================================================
-- CIDADE DO XIS · Vídeo nas Histórias + Hardening (P0-2b / P0-3 do runbook)
-- Cole TUDO no Supabase → SQL Editor → RUN. É idempotente (rodar 2x é seguro).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) VÍDEO NAS HISTÓRIAS DO XIS
--    Nova coluna para o vídeo enviado no formulário público "Conte sua História".
-- ----------------------------------------------------------------------------
alter table public.historias
  add column if not exists video text;

-- ----------------------------------------------------------------------------
-- 2) P0-3 · Limites de tamanho e tipo nos buckets (fonte de verdade, não a UI)
--    'estabelecimentos' recebe upload público: fotos (5 MB), áudio (10 MB)
--    e agora vídeo das histórias (50 MB) → limite do bucket = 50 MB.
-- ----------------------------------------------------------------------------
update storage.buckets
set allowed_mime_types = array[
      'image/jpeg','image/png','image/webp',
      'audio/mpeg','audio/mp4','audio/wav','audio/x-m4a','audio/webm',
      'video/mp4','video/webm','video/quicktime'
    ],
    file_size_limit = 52428800   -- 50 MB
where name = 'estabelecimentos';

update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp'],
    file_size_limit = 5242880    -- 5 MB
where name in ('capa','parceiros');

-- Galeria do Festival (upload só da equipe): fotos e vídeos até 50 MB.
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime'],
    file_size_limit = 52428800
where name = 'midia';

-- ----------------------------------------------------------------------------
-- 3) P0-2a · Votos: garantir que as policies abertas foram removidas.
--    (O script principal já cria a função registrar_voto — segura, com
--    validação. Aqui só garantimos que o acesso direto à tabela está fechado.)
-- ----------------------------------------------------------------------------
drop policy if exists votos_ins_publico on public.votos;
drop policy if exists votos_upd_publico on public.votos;

-- ----------------------------------------------------------------------------
-- 4) P0-2b · estabelecimento_responsavel: insert público só vinculado a um
--    cadastro PENDENTE real (evita spam de linhas soltas com CPF).
-- ----------------------------------------------------------------------------
drop policy if exists resp_ins on public.estabelecimento_responsavel;
create policy resp_ins on public.estabelecimento_responsavel
  for insert to anon, authenticated
  with check (
    exists (
      select 1 from public.estabelecimentos e
      where e.id = estabelecimento_id and e.status = 'pendente'
    )
  );

-- ----------------------------------------------------------------------------
-- 5) Conferência rápida (read-only) — rode e confira o resultado:
-- ----------------------------------------------------------------------------
select name, public, file_size_limit, allowed_mime_types from storage.buckets;
select policyname, cmd, roles from pg_policies
 where schemaname='public' and tablename in ('votos','estabelecimento_responsavel');
