# 🔐 Runbook de Hardening — Cidade do Xis

> Diagnóstico de segurança em formato de checklist, priorizado e executável.
> Stack alvo: **SPA estática (Vercel: cidadedoxis.com) + Supabase (Auth, Postgres/RLS, Storage)** + Google Maps.
> Projeto Supabase: `hlstcndhxzhdzbecfrhp` · Repositório: `roniegabbi/cidade-do-xis`

---

## Como usar este runbook (rodando com o Claude)

**Pré-requisitos de acesso (o operador precisa fornecer):**

- [ ] Acesso ao **repositório** (`cidade-do-xis.html`, `admin-cidade-do-xis.html`, `vercel.json`).
- [ ] **Supabase MCP** conectado (já disponível neste projeto).
- [ ] Confirmação de **autorização** para alterar o projeto (protótipo público da SMDEI — tratar como produção).

**Regras de execução:**

1. Resolva na ordem: **P0 → P1 → P2 → P3**. Não pule P0.
2. Cada item tem `🔍 Verificar` (read-only, seguro) e `🛠 Corrigir` (faz alteração).
3. **Antes de qualquer alteração**: rode todas as verificações primeiro e registre o estado atual (snapshot).
4. Toda alteração de RLS/policy deve ser testada com a `anon key` **antes e depois**.
5. Os nomes abaixo são os **reais do schema** (`supabase-cidade-do-xis.sql` + `rodar-agora-supabase.sql`). O P0-0 confirma se o banco em produção bate com os scripts.
6. Marque `[x]` ao concluir e anote o resultado na linha `Resultado:`.

**Contexto do schema real:**

| Item | Valor no projeto |
|---|---|
| Tabelas | `categorias`, `bairros`, `perfis`, `estabelecimentos`, `estabelecimento_itens`, `estabelecimento_responsavel`, `midia`, `imagens_capa`, `parceiros`, `config`, `destaques_festival`, `votos`, `festival_midia`, `historias` |
| View pública | `estabelecimento_ranking` |
| Papéis (enum `papel_usuario`) | `admin_total`, `editor`, `curador`, `visualizador` (default no signup) |
| Funções de papel (já existem) | `papel_atual()`, `is_admin()`, `pode_editar()`, `is_equipe()` |
| Buckets (todos `public=true`) | `estabelecimentos`, `midia`, `capa`, `parceiros` |
| Uploads anônimos | bucket `estabelecimentos`, pastas `cadastros/` (fotos do Cadastre seu Xis) e `historias/` (foto+áudio do Conte sua História) |
| Tabela com PII crítica | `estabelecimento_responsavel` (**CPF, CNPJ, nome do responsável**) |

---

## 🧭 P0-0 — Descoberta do schema (pré-flight, read-only)

- [ ] **Confirmar que o banco em produção bate com os scripts SQL do repositório.**

```sql
-- Tabelas e se a RLS está ligada (esperado: TODAS com rowsecurity = true)
select schemaname, tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by rowsecurity, tablename;

-- Policies existentes (comparar com os scripts do repo)
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public';

-- Buckets de Storage (esperado: 4 buckets públicos, SEM limite de tamanho/mime hoje)
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets;

-- Policies de storage.objects (verificar o alcance do INSERT anon)
select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects';

-- Colunas das tabelas sensíveis
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name in ('estabelecimento_responsavel','perfis','estabelecimentos','historias','votos')
order by table_name, ordinal_position;
```

> Resultado: _(tabelas com RLS off, policies divergentes dos scripts, buckets sem limites)_

---

# 🔴 P0 — Crítico (resolver antes de tudo)

### P0-1 · RLS habilitada em TODAS as tabelas

A `anon key` está no HTML público. Sem RLS, ela lê/escreve/apaga tudo.

- [ ] 🔍 **Verificar:** rode a 1ª query do P0-0. Os scripts do repo habilitam RLS em todas as 14 tabelas — confirmar que nenhuma ficou de fora no banco real (atenção a tabelas criadas manualmente pelo painel).
- [ ] 🛠 **Corrigir:** para qualquer linha com `rowsecurity = false`:

```sql
alter table public.<tabela> enable row level security;
alter table public.<tabela> force row level security;
```

> Resultado: _(tabelas que estavam sem RLS)_

---

### P0-2 · Furos nas policies existentes

O projeto **já tem** papéis e policies (`papel_atual()`, `is_equipe()`, `pode_editar()`), mas a revisão do código encontrou furos concretos:

**(a) `votos_upd_publico` — qualquer pessoa altera o voto de qualquer outra.**

```sql
-- HOJE (rodar-agora-supabase.sql):
-- create policy votos_upd_publico on public.votos
--   for update to anon, authenticated
--   using (true) with check (nota between 1 and 5);   -- ← using(true) = fraude de ranking
```

- [ ] 🔍 **Verificar:** com a `anon key`, faça `update votos set nota=5` sem filtro → hoje **funciona** (não deveria).
- [ ] 🛠 **Corrigir:** amarrar o update ao `device_id` do votante (coluna usada pelo front) e nunca permitir update em massa:

```sql
drop policy if exists votos_upd_publico on public.votos;
create policy votos_upd_publico on public.votos
  for update to anon, authenticated
  using (device_id = current_setting('request.headers', true)::json ->> 'x-device-id' or public.is_equipe())
  with check (nota between 1 and 5);
-- Alternativa mais simples e robusta: remover o UPDATE público e tratar revoto
-- com upsert por (estabelecimento_id, device_id) via unique constraint,
-- ou mover o voto para uma Edge Function com rate limit.
```

**(b) `resp_ins` com `with check (true)` — spam ilimitado de linhas com CPF falso.**

- [ ] 🔍 **Verificar:** policy `resp_ins` em `estabelecimento_responsavel` aceita insert anon sem vínculo com um cadastro pendente real.
- [ ] 🛠 **Corrigir:** exigir que o insert referencie um estabelecimento `pendente` recém-criado:

```sql
drop policy if exists resp_ins on public.estabelecimento_responsavel;
create policy resp_ins on public.estabelecimento_responsavel
  for insert to anon, authenticated
  with check (
    exists (
      select 1 from public.estabelecimentos e
      where e.id = estabelecimento_id and e.status = 'pendente'
    )
  );
```

**(c) Teste de regressão obrigatório com a `anon key`:**

- [ ] `select * from estabelecimento_responsavel` → **vazio/negado** (CPF nunca vaza)
- [ ] `select * from perfis` → só o próprio perfil ou negado
- [ ] `insert` em `estabelecimentos` com `status='publicado'` ou `dono_id` de terceiro → **negado** (só `pendente` + `dono_id null`)
- [ ] `insert` em `historias` com `status='publicado'` → **negado** (só `pendente`)
- [ ] `update`/`delete` em `estabelecimentos`, `historias`, `parceiros`, `config`, `destaques_festival`, `festival_midia`, `imagens_capa` → **negado**
- [ ] `update votos` de outro device → **negado** (após o fix (a))

> Resultado: _(o que a anon key ainda consegue após os fixes)_

---

### P0-3 · Policies e limites de Storage

Os 4 buckets são públicos e **sem `file_size_limit` nem `allowed_mime_types`**. O `INSERT` anon no bucket `estabelecimentos` (pastas `cadastros/` e `historias/`) permite hospedagem gratuita de qualquer arquivo — o front valida 5 MB/JPG-PNG (e 10 MB de áudio), mas só na UI.

- [ ] 🔍 **Verificar:** 3ª e 4ª queries do P0-0. Confirmar que o INSERT anon está restrito às pastas certas e que não há limite de tamanho/tipo no bucket.
- [ ] 🛠 **Corrigir:**

```sql
-- Limites no próprio bucket (fonte de verdade, não a UI):
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp',
                               'audio/mpeg','audio/mp4','audio/wav','audio/x-m4a'],
    file_size_limit = 10485760   -- 10 MB (áudio das histórias; fotos ficam bem abaixo)
where name = 'estabelecimentos';

update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp'],
    file_size_limit = 5242880    -- 5 MB
where name in ('capa','parceiros');

-- 'midia' (galeria do festival, upload só da equipe): vídeo até 50 MB
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm'],
    file_size_limit = 52428800
where name = 'midia';

-- Conferir que o INSERT anon segue restrito às pastas públicas:
-- policy storage_cadastro_publico deve exigir
--   bucket_id='estabelecimentos' and foldername in ('cadastros','historias')
-- e NUNCA cobrir os buckets 'capa', 'midia' e 'parceiros' (equipe apenas).
```

> ⚠️ Fotos/áudios enviados pelo público ficam **legíveis publicamente antes da curadoria** (bucket público). Ideal: bucket de *quarentena* privado + mover na aprovação pelo painel.

> Resultado: _(limites aplicados; INSERT anon restrito a quais pastas?)_

---

### P0-4 · Chave do Google Maps exposta e sem restrição

Não há chamadas de IA no projeto. O equivalente aqui é a **chave do Google Maps hardcoded** nos dois HTMLs (`GOOGLE_MAPS_KEY = 'AIzaSy...'`, linhas ~889 e ~580). Chave de Maps é pública por natureza, mas **sem restrição de referrer** ela pode ser usada por terceiros e gerar cobrança na conta do projeto.

- [ ] 🔍 **Verificar:** no Google Cloud Console → APIs & Services → Credentials: a chave tem restrição de **HTTP referrer**? Quais APIs estão habilitadas para ela?
- [ ] 🛠 **Corrigir:** restringir a chave aos referrers:
  - `https://cidadedoxis.com/*`
  - `https://www.cidadedoxis.com/*`
  - `https://cidade-do-xis.vercel.app/*`
  E limitar às APIs realmente usadas (Maps JavaScript API). Ativar alerta de billing.

> Resultado: _(restrições aplicadas na chave)_

---

# 🟠 P1 — Alto

### P1-1 · XSS via conteúdo enviado pelo público

**41 usos de `innerHTML`** (23 no site público, 18 no admin). O vetor mais grave: nome/história/endereço/Instagram enviados no formulário público e renderizados no **painel do curador** — sequestro da sessão da equipe.

- [ ] 🔍 **Verificar:**

```bash
grep -niE "innerHTML|insertAdjacentHTML|outerHTML|document\.write" \
  cidade-do-xis.html admin-cidade-do-xis.html
# Identificar quais interpolam dados vindos de estabelecimentos/historias/votos.
```

- [ ] 🛠 **Corrigir:** nos pontos que renderizam dado do público, trocar por `textContent`/criação de nós, ou escapar com uma função `esc()` aplicada a **todo** campo vindo do banco. Validar que `site`/`instagram`/`facebook`/`whatsapp` começam com `http(s)` (bloquear `javascript:`) antes de virar `href`.

> Resultado: _(pontos inseguros encontrados e corrigidos)_

---

### P1-2 · Fluxo de signup ("Criar conta" público)

O site tem "Criar conta" para empreendedores e o trigger `handle_new_user()` cria um registro em `perfis` com papel default `visualizador`. Riscos: signup aberto sem confirmação de e-mail; e qualquer conta nova enxergar mais do que deveria.

- [ ] 🔍 **Verificar:** Supabase → Authentication → Sign In/Up: signups públicos habilitados? **Confirm email** exigido? O papel default `visualizador` concede algo além de leitura? (conferir todas as policies que usam `authenticated` sem checar papel — ex.: `estab_ins` permite `dono_id = auth.uid()`, ok por design).
- [ ] 🛠 **Corrigir:** exigir confirmação de e-mail; conferir que `visualizador` não passa em `is_equipe()`/`pode_editar()` (correto no script); promoção a `curador`/`editor`/`admin_total` só via painel do admin, nunca por auto-registro. Contas da equipe: convite pelo Supabase (invite), não senha combinada por WhatsApp.

> Resultado: _(config de signup e papéis conferidos)_

---

### P1-3 · Validação real de arquivos no upload

O front valida JPG/PNG ≤ 5 MB e áudio ≤ 10 MB só com `accept` e checagem JS — burlável com uma chamada direta à API de Storage.

- [ ] 🔍 **Verificar:** após o P0-3, tentar via `anon key` subir um `.html` de 20 MB na pasta `cadastros/` → deve falhar **pelo bucket**, não pela UI.
- [ ] 🛠 **Corrigir:** os limites do P0-3 são a fonte de verdade. Opcional: Edge Function com checagem de *magic bytes* para os áudios das histórias.

> Resultado: _(validação server-side confirmada?)_

---

# 🟡 P2 — Médio

### P2-1 · Headers de segurança (Vercel)

O `vercel.json` atual só tem o rewrite da home — nenhum header de segurança.

- [ ] 🔍 **Verificar:** `curl -sI https://cidadedoxis.com` → tem CSP, `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options`?
- [ ] 🛠 **Corrigir:** adicionar ao `vercel.json` (CSP já ajustada ao que o site realmente carrega — Supabase, Google Maps, Google Fonts, jsDelivr, e `unsafe-inline` porque o JS/CSS é inline nos HTMLs):

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "rewrites": [
    { "source": "/", "destination": "/cidade-do-xis.html" }
  ],
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains; preload" },
        { "key": "Content-Security-Policy", "value": "default-src 'self'; img-src 'self' data: blob: https:; media-src 'self' blob: https://hlstcndhxzhdzbecfrhp.supabase.co; connect-src 'self' https://hlstcndhxzhdzbecfrhp.supabase.co https://maps.googleapis.com; script-src 'self' 'unsafe-inline' https://maps.googleapis.com https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; frame-ancestors 'none'" }
      ]
    }
  ]
}
```

> Nota: `script-src 'unsafe-inline'` é exigido pela arquitetura atual (JS inline no HTML). Meta de longo prazo: extrair o JS para arquivo próprio e remover o `unsafe-inline`.

> Resultado: _(headers antes/depois)_

---

### P2-2 · Rate limiting / anti-spam

Três formulários públicos sem captcha: **Cadastre seu Xis** (com upload), **Conte sua História** (foto+áudio) e **Voto Popular**.

- [ ] 🔍 **Verificar:** há qualquer proteção anti-abuso hoje? (não há)
- [ ] 🛠 **Corrigir:** Cloudflare Turnstile nos dois formulários de envio; para o voto, unique constraint `(estabelecimento_id, device_id)` + validação em Edge Function se a fraude do ranking do Festival for preocupação real.

> Resultado: _(proteções aplicadas)_

---

### P2-3 · Segredos no repositório

- [ ] 🔍 **Verificar:**

```bash
grep -rniE "service_role|SUPABASE_SERVICE|secret|password\s*=|sk-" . --exclude-dir=node_modules
git log -p | grep -iE "service_role|sk-|secret" | head
```

- [ ] 🛠 **Corrigir:** o repo hoje só expõe a `publishable/anon key` (ok por design) e a chave do Maps (tratada no P0-4). **Nunca** commitar a `service_role`. Se aparecer no histórico → rotacionar no painel do Supabase.

> Resultado: _(segredos encontrados / rotacionados?)_

---

### P2-4 · Exposição de PII em respostas da API

PII do projeto: CPF/CNPJ/nome do responsável (`estabelecimento_responsavel`), telefone/WhatsApp do estabelecimento, nome do autor das histórias.

- [ ] 🔍 **Verificar:** o `select` público de `estabelecimentos` retorna `telefone`/`whatsapp` — é intencional (contato comercial na vitrine)? A view `estabelecimento_ranking` expõe algo além do agregado de votos? `historias` públicas retornam só o necessário?
- [ ] 🛠 **Corrigir:** se algum campo de contato não deve ser público, criar view pública só com colunas seguras e apontar o front para ela; manter a tabela base restrita. Confirmar (P0-2) que `estabelecimento_responsavel` é invisível ao público.

> Resultado: _(colunas sensíveis revisadas)_

---

# 🟢 P3 — Baixo / boa prática

- [ ] **P3-1 · Dependências:** o site usa CDN (jsDelivr, Maps). Fixar versões com hash SRI (`integrity=`) nos `<script src>` de CDN.
- [ ] **P3-2 · Logs/observabilidade:** habilitar logs de Auth e Storage no Supabase; rodar `get_advisors` (security + performance) no MCP e tratar os apontamentos.
- [ ] **P3-3 · Backup/restore:** confirmar backups automáticos do Postgres (plano free = 7 dias) e testar restore antes do Festival.
- [ ] **P3-4 · CORS:** se criar Edge Functions (voto, quarentena de upload), restringir origem a `https://cidadedoxis.com` e `https://www.cidadedoxis.com`.
- [ ] **P3-5 · Erros silenciosos:** o front exibe mensagens cruas do Supabase em alguns `alert()`/`console` — trocar por mensagem genérica (erro cru revela schema).
- [ ] **P3-6 · Senhas:** Supabase Auth → política mínima de senha + leaked-password protection.

> Resultado: _(itens fechados)_

---

## ✅ Passo final — Verificação de regressão

Com a **`anon key`** (perspectiva do atacante), confirmar que **todas** falham:

- [ ] `select` em `estabelecimento_responsavel` → vazio/negado
- [ ] `select` em `perfis` → só o próprio / negado
- [ ] `insert` em `estabelecimentos` com `status='publicado'` ou `dono_id` de terceiro → negado
- [ ] `insert` em `historias` com `status='publicado'` → negado
- [ ] `update`/`delete` em qualquer tabela de conteúdo → negado
- [ ] `update votos` sem ser o device autor → negado
- [ ] upload de arquivo > limite ou mime não permitido → negado pelo bucket
- [ ] upload anon em `capa`, `midia`, `parceiros` ou fora de `cadastros/`·`historias/` → negado
- [ ] chave do Maps usada de um domínio de terceiro → bloqueada por referrer
- [ ] `curl -sI https://cidadedoxis.com` → headers do P2-1 presentes

**Critério de aceite:** todos os itens acima negados/presentes + checkboxes P0/P1 marcados.

---

### Resumo de prioridade

| Prioridade | Itens | Foco |
|---|---|---|
| 🔴 P0 | RLS, furo do `votos_upd_publico`, spam em `estabelecimento_responsavel`, limites de Storage, chave do Maps | Protege CPF/CNPJ, ranking do Festival e a conta de billing |
| 🟠 P1 | XSS (41 `innerHTML`), signup público, validação de upload | Fecha sequestro de sessão da equipe e abuso dos formulários |
| 🟡 P2 | Headers/CSP, captcha/rate limit, segredos, PII | Reduz superfície e abuso |
| 🟢 P3 | SRI, logs/advisors, backup, CORS, erros, senhas | Maturidade operacional |
