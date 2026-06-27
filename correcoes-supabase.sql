-- ============================================================================
-- CIDADE DO XIS · Correções de segurança e limpeza
-- Cole TODO este conteúdo no Supabase → SQL Editor → RUN.
-- É seguro rodar mais de uma vez (idempotente).
-- ============================================================================

-- 1) SEGURANÇA DA VOTAÇÃO -----------------------------------------------------
-- Antes, qualquer visitante podia sobrescrever QUALQUER voto (using(true)).
-- Agora removemos o acesso direto e a votação passa por uma função controlada.
drop policy if exists votos_ins_publico on public.votos;
drop policy if exists votos_upd_publico on public.votos;

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

-- 2) LIMPEZA DA TABELA PARCEIROS ---------------------------------------------
-- Unifica a coluna do logo em "logo" e remove a antiga "logo_url" duplicada.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='parceiros' and column_name='logo_url') then
    update public.parceiros set logo = coalesce(logo, logo_url) where logo is null;
    alter table public.parceiros drop column logo_url;
  end if;
end$$;
alter table public.parceiros alter column nome drop not null;
