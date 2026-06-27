# Cidade do Xis · Santa Maria · RS

Plataforma da cadeia produtiva do xis de Santa Maria — vitrine pública, mapa,
Festival do Xis, mural de histórias e painel administrativo. Iniciativa da
Secretaria Municipal de Desenvolvimento Econômico e Inovação (SMDEI).

## Páginas

- `cidade-do-xis.html` — site público (vitrine, mapa, festival, histórias). **É a home** (`/`).
- `admin-cidade-do-xis.html` — painel administrativo (`/admin-cidade-do-xis.html`).
- `calculadora-preco-xis.html`, `planejador-compras-xis.html`, `planejador-midias-xis.html` — ferramentas do empreendedor.

## Backend

Supabase (Postgres + Auth + Storage). Os scripts SQL ficam em `supabase-cidade-do-xis.sql`
e `correcoes-supabase.sql` (cole no Supabase → SQL Editor → RUN).

A chave Supabase usada no front é a **publishable** (pública por natureza). A chave do
Google Maps também é pública, mas recomenda-se restringir por *HTTP referrer* no Google
Cloud Console para os domínios do projeto (ex.: `*.vercel.app` e o domínio final).

## Deploy (Vercel)

Site estático. O `vercel.json` redireciona `/` para a vitrine. Basta importar este
repositório no Vercel (Framework: **Other**) e publicar.
