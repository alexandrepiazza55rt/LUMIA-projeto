#!/usr/bin/env node
/* =============================================================================
 * LUMIA · Gerador do dossiê estático
 * =============================================================================
 * O blueprint interativo (index.html) monta tudo por JavaScript a partir de
 * JSON embutido. Isso é ótimo para quem abre no navegador e péssimo para quem
 * lê a página por programa: a maioria dos leitores automáticos (agentes de IA,
 * crawlers, conversores HTML→texto) não executa JS e ainda descarta o conteúdo
 * de <script>. Medido na prática: de 218 KB de página, só 5,2 KB de texto
 * sobreviviam — cerca de 2%.
 *
 * Este script gera dois artefatos SEM JavaScript, a partir das mesmas fontes
 * canônicas, de modo que nunca divergem do blueprint:
 *
 *   dossie.html  documento completo, todo o conteúdo no HTML estático
 *   llms.txt     índice curto apontando os recursos legíveis por máquina
 *
 * Uso:  node tools/gerar-dossie.js
 * ========================================================================== */

const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..');
const ler = (f) => JSON.parse(fs.readFileSync(path.join(RAIZ, f), 'utf8'));

const gaps = ler('gaps.json');
const arq = ler('architecture.json');
const deps = ler('dependencias.json');
const inv = ler('schema-inventario.json');

const BASE_URL = 'https://alexandrepiazza55rt.github.io/LUMIA-projeto';
const DATA = '26 de julho de 2026';

/* ---- catálogo de módulos: os 10 originais + os novos de gaps.json --------- */
const BASE_MODULOS = [
  ['meu-negocio', '🏠', 'Meu Negócio', 'Fundação'],
  ['meus-clientes', '👥', 'Meus Clientes', 'Entidades'],
  ['minha-equipe', '💇', 'Minha Equipe', 'Entidades'],
  ['minha-agenda', '📅', 'Minha Agenda', 'Operação'],
  ['meu-financeiro', '💰', 'Meu Financeiro', 'Monetização'],
  ['meus-resultados', '📈', 'Meus Resultados', 'Inteligência'],
  ['ferramentas-mqs', '🧭', 'Ferramentas MQS', 'Método'],
  ['universidade-mqs', '📚', 'Universidade MQS', 'Método'],
  ['consultor-mqs', '🤖', 'Consultor MQS', 'Consultoria'],
  ['configuracoes', '⚙️', 'Configurações', 'Plataforma'],
];

const slug = (s) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

const MOD = {};
BASE_MODULOS.forEach(([id, ico, titulo, camada]) => {
  MOD[id] = { id, icone: ico, titulo, camada, novo: false, grupos: [], reforcos: [] };
});
gaps.modulos_novos.forEach((m) => {
  MOD[slug(m.titulo)] = {
    id: slug(m.titulo), icone: m.icone, titulo: m.titulo, camada: m.camada,
    novo: true, prioridade: m.prioridade, frase: m.frase, pergunta: m.pergunta,
    por_que: m.por_que, grupos: m.grupos, reforcos: [],
  };
});
gaps.reforcos_modulos_existentes.forEach((r) => {
  const id = slug(r.modulo);
  if (MOD[id]) MOD[id].reforcos.push(r);
});

/* Meu Balcão foi dividido em Caixa e Comandas quando o schema foi implementado. */
(function dividirBalcao() {
  const b = MOD['meu-balcao'];
  if (!b) return;
  const gCaixa = ['Sessão de Caixa', 'Recebimento no Balcão', 'Alçadas e Antifraude', 'Operação de Balcão'];
  MOD['meu-caixa'] = { ...b, id: 'meu-caixa', icone: '💵', titulo: 'Meu Caixa', camada: 'Caixa',
    frase: 'Dinheiro com dono, hora e motivo.',
    pergunta: 'Quanto entrou, por onde e sob responsabilidade de quem?',
    por_que: 'Livro append-only, conferência cega imposta por GRANT de coluna e divergência que nunca vira desconto automático.',
    grupos: b.grupos.filter((g) => gCaixa.includes(g.nome)) };
  MOD['minhas-comandas'] = { ...b, id: 'minhas-comandas', icone: '🧾', titulo: 'Minhas Comandas', camada: 'Comanda',
    frase: 'Toda comanda tem dono, sempre.',
    pergunta: 'Quem abriu, quem executou e por quais mãos passou?',
    por_que: 'Cadeia de custódia sem buraco nem sobreposição, transferência com motivo obrigatório e valor congelado no item.',
    grupos: b.grupos.filter((g) => !gCaixa.includes(g.nome)) };
  delete MOD['meu-balcao'];
})();

const ORDEM = [
  'configuracoes', 'plataforma-lumia', 'central-de-privacidade', 'minhas-conversas',
  'meu-negocio', 'meu-catalogo', 'meus-clientes', 'minha-equipe',
  'minha-vitrine', 'meu-prontuario', 'meu-estoque', 'meu-marketing',
  'minha-agenda', 'meu-caixa', 'minhas-comandas',
  'meu-financeiro', 'meu-fiscal', 'meus-resultados',
  'ferramentas-mqs', 'universidade-mqs', 'consultor-mqs',
];

const esc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const nome = (id) => (MOD[id] ? MOD[id].titulo + (MOD[id].novo ? ' *' : '') : id);

/* ========================================================================== */
/* dossie.html                                                                 */
/* ========================================================================== */
const P = [];
const w = (s) => P.push(s);

w(`<title>LUMIA · Dossiê completo da fundação</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Documento completo e estático da fundação do sistema LUMIA: 21 módulos, dependências verificadas por chave estrangeira, decisões irreversíveis e modelo de dados em PostgreSQL.">
<style>
  :root{--ink:#241b30;--soft:#5b5068;--faint:#8a7f97;--line:#e8dff2;--bg:#fdfcff;
        --accent:#7c3aed;--gold:#b8862f;--p0:#c2410c;--p1:#0369a1;--p2:#57534e;
        --serif:Georgia,'Times New Roman',serif;--sans:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
        --mono:ui-monospace,'SF Mono',Menlo,monospace}
  @media (prefers-color-scheme:dark){:root{--ink:#f2ecf8;--soft:#b9adca;--faint:#877a9a;
        --line:#2c2140;--bg:#120c1a;--accent:#b78cf5;--gold:#e2b662;--p0:#fb923c;--p1:#5cb8e8;--p2:#a8a29e}}
  *{box-sizing:border-box}
  body{margin:0 auto;max-width:52rem;padding:2.5rem 1.25rem 6rem;background:var(--bg);color:var(--ink);
       font-family:var(--sans);line-height:1.65;font-size:16px}
  h1{font-family:var(--serif);font-size:2.1rem;line-height:1.15;margin:.4rem 0 .6rem;letter-spacing:-.02em}
  h2{font-family:var(--serif);font-size:1.5rem;margin:3rem 0 .8rem;padding-top:1.2rem;
     border-top:1px solid var(--line);letter-spacing:-.01em}
  h3{font-size:1.12rem;margin:2rem 0 .5rem;letter-spacing:-.01em}
  h4{font-size:.95rem;margin:1.2rem 0 .35rem;color:var(--soft)}
  p,li{color:var(--ink)}
  .lead{font-size:1.05rem;color:var(--soft)}
  .meta{font-size:.85rem;color:var(--faint);margin:0}
  code{font-family:var(--mono);font-size:.85em;background:color-mix(in srgb,var(--accent) 9%,transparent);
       border-radius:4px;padding:.1em .35em}
  pre{font-family:var(--mono);font-size:.8rem;background:color-mix(in srgb,var(--accent) 7%,transparent);
      border:1px solid var(--line);border-radius:8px;padding:.9rem 1rem;overflow-x:auto;line-height:1.5}
  table{border-collapse:collapse;width:100%;font-size:.86rem;margin:.6rem 0}
  th{text-align:left;font-size:.72rem;text-transform:uppercase;letter-spacing:.06em;color:var(--faint);
     border-bottom:2px solid var(--line);padding:.45rem .5rem}
  td{border-bottom:1px solid var(--line);padding:.45rem .5rem;vertical-align:top}
  .wrap{overflow-x:auto}
  .novo{color:var(--gold);font-weight:700}
  .pri{font-size:.68rem;font-weight:800;padding:.1rem .35rem;border-radius:4px;letter-spacing:.04em}
  .P0{background:color-mix(in srgb,var(--p0) 15%,transparent);color:var(--p0)}
  .P1{background:color-mix(in srgb,var(--p1) 15%,transparent);color:var(--p1)}
  .P2{background:color-mix(in srgb,var(--p2) 15%,transparent);color:var(--p2)}
  .fk{font-family:var(--mono);font-size:.72rem;font-weight:700;color:var(--gold)}
  .aviso{border-left:3px solid var(--gold);padding:.7rem 1rem;margin:1.2rem 0;
         background:color-mix(in srgb,var(--gold) 7%,transparent);border-radius:0 8px 8px 0;font-size:.92rem}
  ul{padding-left:1.2rem} li{margin:.15rem 0}
  .itens{font-size:.88rem;color:var(--soft)}
  a{color:var(--accent)}
  nav ol{font-size:.95rem}
</style>`);

w(`<p class="meta">Documento estático · gerado em ${DATA} · <a href="${BASE_URL}/">versão interativa</a></p>`);
w(`<h1>LUMIA — Dossiê completo da fundação</h1>`);
w(`<p class="lead">Sistema de gestão para o setor de beleza e estética no Brasil, com metodologia MQS embutida, projetado para escala nacional. Este documento contém <strong>todo</strong> o conteúdo do blueprint em HTML estático, para leitura por pessoas e por programas.</p>`);

/* Bloco de fatos logo no topo: leitores automáticos frequentemente truncam
   documentos longos, então os números que mais importam não podem depender de
   o leitor chegar à seção 8. */
w(`<h2 style="border:0;padding:0;margin:1.8rem 0 .6rem">Resumo em números</h2>
<div class="wrap"><table><tbody>
<tr><td>Módulos no total</td><td><strong>21</strong> — 10 originais e ${gaps.modulos_novos.length + 1} novos (marcados com <span class="novo">*</span>)</td></tr>
<tr><td>Ligações de dependência</td><td><strong>${deps.total}</strong>, das quais <strong>${deps.verificadas}</strong> comprovadas por chave estrangeira real</td></tr>
<tr><td>Decisões irreversíveis de fundação</td><td><strong>${gaps.decisoes_irreversiveis.length}</strong></td></tr>
<tr><td>Reforços em módulos existentes</td><td><strong>${gaps.reforcos_modulos_existentes.length}</strong></td></tr>
<tr><td>Achados da análise de lacunas</td><td><strong>${gaps.meta.contagem.consolidados}</strong> verificados, sob <strong>7</strong> lentes independentes</td></tr>
<tr><td>Custo já pago pelo sistema anterior</td><td><strong>${gaps.lente_legado.custo_ja_pago.ciclos_de_reorganizacao}</strong> ciclos de reorganização + <strong>${gaps.lente_legado.custo_ja_pago.ciclos_de_migracao_para_banco}</strong> de migração, sem funcionalidade nova ao dono</td></tr>
<tr><td><strong>Tabelas no banco</strong></td><td><strong>${inv.resumo.tabelas}</strong> tabelas · ${inv.resumo.colunas} colunas · ${inv.resumo.com_rls} com RLS forçada</td></tr>
<tr><td>Constraints</td><td>${inv.resumo.checks} CHECK · ${inv.resumo.excludes} EXCLUDE · ${inv.resumo.fks} chaves estrangeiras</td></tr>
<tr><td>Migrations PostgreSQL</td><td><strong>${inv.resumo.migrations}</strong></td></tr>
<tr><td>Asserções de teste passando</td><td><strong>${inv.resumo.asercoes}</strong>, incluindo prova de concorrência com 30 sessões simultâneas</td></tr>
</tbody></table></div>
<p class="meta">Módulos, na ordem de dependência: Configurações · Plataforma LUMIA* · Central de Privacidade* · Minhas Conversas* · Meu Negócio · Meu Catálogo* · Meus Clientes · Minha Equipe · Minha Vitrine* · Meu Prontuário* · Meu Estoque* · Meu Marketing* · Minha Agenda · Meu Caixa* · Minhas Comandas* · Meu Financeiro · Meu Fiscal* · Meus Resultados · Ferramentas MQS · Universidade MQS · Consultor MQS</p>`);

w(`<div class="aviso"><strong>Por que este documento existe.</strong> A versão interativa monta o conteúdo por JavaScript. Leitores automáticos que não executam scripts enxergam apenas cerca de 2% do texto. Aqui está tudo, sem depender de JavaScript.</div>`);

w(`<nav><h2 style="border:0;padding:0;margin-top:1.5rem">Índice</h2><ol>
<li><a href="#diagnostico">Diagnóstico da estrutura</a></li>
<li><a href="#modulos">Os 21 módulos</a></li>
<li><a href="#dependencias">Mapa de dependências</a></li>
<li><a href="#decisoes">Decisões irreversíveis de fundação</a></li>
<li><a href="#legado">Lente do sistema legado</a></li>
<li><a href="#arquitetura">Arquitetura técnica</a></li>
<li><a href="#rotas">Mapa de rotas da API</a></li>
<li><a href="#fases">Fases de construção</a></li>
<li><a href="#modelo">Modelo de dados implementado</a></li>
<li><a href="#provas">Provas executadas</a></li>
<li><a href="#fontes">Fontes legíveis por máquina</a></li>
</ol></nav>`);

/* --- diagnóstico --- */
w(`<h2 id="diagnostico">1. Diagnóstico da estrutura</h2>`);
w(`<p>${esc(gaps.diagnostico)}</p>`);
w(`<p class="meta">Método: ${esc(gaps.meta.metodo)}</p>`);
w(`<table><tbody>
<tr><td>Módulos originais</td><td><strong>10</strong></td></tr>
<tr><td>Módulos novos identificados</td><td><strong>${gaps.modulos_novos.length}</strong> (marcados com <span class="novo">*</span>)</td></tr>
<tr><td>Reforços em módulos existentes</td><td><strong>${gaps.reforcos_modulos_existentes.length}</strong></td></tr>
<tr><td>Achados consolidados</td><td><strong>${gaps.meta.contagem.consolidados}</strong> (P0: ${gaps.meta.contagem.P0} · P1: ${gaps.meta.contagem.P1} · P2: ${gaps.meta.contagem.P2})</td></tr>
<tr><td>Decisões irreversíveis</td><td><strong>${gaps.decisoes_irreversiveis.length}</strong></td></tr>
</tbody></table>`);
w(`<p class="meta"><strong>Prioridades.</strong> P0 = sem isso o modelo de dados nasce errado, e corrigir depois exige migração, reescrita ou perda de histórico. P1 = necessário antes do lançamento comercial, encaixa sem migração destrutiva. P2 = maturidade e escala.</p>`);

/* --- módulos --- */
w(`<h2 id="modulos">2. Os 21 módulos</h2>`);
w(`<p>Onze módulos aparecem marcados com <span class="novo">*</span>: foram identificados na análise de lacunas e não constavam da estrutura original. Meu Balcão foi dividido em <strong>Meu Caixa</strong> e <strong>Minhas Comandas</strong> quando o schema foi implementado, porque as dependências de cada um são distintas.</p>`);

ORDEM.forEach((id) => {
  const m = MOD[id];
  if (!m) return;
  w(`<h3>${m.icone} ${esc(m.titulo)}${m.novo ? ' <span class="novo">*</span>' : ''}` +
    (m.prioridade ? ` <span class="pri ${m.prioridade}">${m.prioridade}</span>` : '') + `</h3>`);
  w(`<p class="meta">Camada: ${esc(m.camada)}${m.novo ? ' · módulo novo' : ' · módulo base'}` +
    (m.frase ? ` · “${esc(m.frase)}”` : '') + `</p>`);
  if (m.pergunta) w(`<p><em>Pergunta que responde:</em> ${esc(m.pergunta)}</p>`);
  if (m.por_que) w(`<p><strong>Por que é indispensável:</strong> ${esc(m.por_que)}</p>`);

  const ups = deps.arestas.filter((a) => a.para === id);
  const downs = deps.arestas.filter((a) => a.de === id && a.tipo !== 'retroalimentacao');
  if (ups.length) {
    w(`<h4>Depende de</h4><ul class="itens">` + ups.map((a) =>
      `<li><strong>${esc(nome(a.de))}</strong>${a.fks_verificadas ? ` <span class="fk">${a.fks_verificadas} FK verificadas</span>` : ' <span class="meta">(planejado)</span>'} — ${esc(a.motivo)}</li>`
    ).join('') + `</ul>`);
  }
  if (downs.length) {
    w(`<h4>Alimenta</h4><ul class="itens">` + downs.map((a) =>
      `<li><strong>${esc(nome(a.para))}</strong>${a.fks_verificadas ? ` <span class="fk">${a.fks_verificadas} FK</span>` : ''} — ${esc(a.motivo)}</li>`
    ).join('') + `</ul>`);
  }
  (m.grupos || []).forEach((g) => {
    w(`<h4>${esc(g.nome)}${m.novo ? ' <span class="novo">*</span>' : ''}</h4>`);
    w(`<p class="itens">${g.itens.map(esc).join(' · ')}</p>`);
  });
  (m.reforcos || []).forEach((r) => {
    w(`<h4>${esc(r.grupo)} <span class="novo">*</span> <span class="pri ${r.prioridade}">${r.prioridade}</span> — reforço novo</h4>`);
    w(`<p class="itens">${r.itens.map(esc).join(' · ')}</p>`);
    w(`<p class="meta">${esc(r.por_que)}</p>`);
  });
});

/* --- dependências --- */
w(`<h2 id="dependencias">3. Mapa de dependências</h2>`);
w(`<p>${deps.total} ligações entre módulos. <strong>${deps.verificadas}</strong> delas não são opinião: foram derivadas das chaves estrangeiras reais do schema implementado, e a contagem indica quantas FKs sustentam cada ligação. As demais são dependências planejadas, ainda não implementadas.</p>`);
w(`<h3>Ordem de construção</h3><pre>Plataforma      Configurações · Plataforma LUMIA* · Central de Privacidade* · Minhas Conversas*
  ↓
Fundação        Meu Negócio
  ↓
Catálogo        Meu Catálogo*                    ← o nó raiz do sistema
  ↓
Entidades       Meus Clientes · Minha Equipe
  ↓
Recursos        Minha Vitrine* · Meu Prontuário* · Meu Estoque* · Meu Marketing*
  ↓
Operação        Minha Agenda
  ↓
Caixa           Meu Caixa*
  ↓
Comanda         Minhas Comandas*
  ↓
Monetização     Meu Financeiro · Meu Fiscal*
  ↓
Inteligência    Meus Resultados
  ↓
Método          Ferramentas MQS · Universidade MQS
  ↓
Consultoria     Consultor MQS</pre>`);

w(`<h3>Dependências verificadas no schema</h3><div class="wrap"><table>
<thead><tr><th>Módulo que depende</th><th>Depende de</th><th>FKs</th><th>Por quê</th></tr></thead><tbody>` +
  deps.arestas.filter((a) => a.fks_verificadas)
    .sort((a, b) => b.fks_verificadas - a.fks_verificadas)
    .map((a) => `<tr><td><strong>${esc(nome(a.para))}</strong></td><td>${esc(nome(a.de))}</td><td class="fk">${a.fks_verificadas}</td><td>${esc(a.motivo)}</td></tr>`).join('') +
  `</tbody></table></div>`);

w(`<h3>Dependências planejadas</h3><div class="wrap"><table>
<thead><tr><th>Módulo que depende</th><th>Depende de</th><th>Por quê</th></tr></thead><tbody>` +
  deps.arestas.filter((a) => !a.fks_verificadas && a.tipo !== 'retroalimentacao')
    .map((a) => `<tr><td><strong>${esc(nome(a.para))}</strong></td><td>${esc(nome(a.de))}</td><td>${esc(a.motivo)}</td></tr>`).join('') +
  `</tbody></table></div>`);

const retro = deps.arestas.filter((a) => a.tipo === 'retroalimentacao');
if (retro.length) {
  w(`<h3>Retroalimentação</h3><ul>` + retro.map((a) =>
    `<li><strong>${esc(nome(a.de))}</strong> devolve para <strong>${esc(nome(a.para))}</strong> — ${esc(a.motivo)}</li>`).join('') + `</ul>`);
}

/* --- decisões --- */
w(`<h2 id="decisoes">4. Decisões irreversíveis de fundação</h2>`);
w(`<p>Ordenadas por custo de erro. São as escolhas cuja correção tardia exige migração de dados, reescrita de módulo ou perda de histórico.</p>`);
gaps.decisoes_irreversiveis.forEach((d, i) => {
  w(`<h3>${i + 1}. ${esc(d.titulo)}</h3>`);
  w(`<p class="meta">Área: ${esc(d.area)}</p>`);
  w(`<p><strong>Decisão:</strong> ${esc(d.decisao)}</p>`);
  w(`<p><strong>Se errar:</strong> ${esc(d.se_errar)}</p>`);
});

/* --- lente do legado --- */
const LG = gaps.lente_legado;
w(`<h2 id="legado">5. Lente do sistema legado</h2>`);
w(`<p class="meta">${esc(LG.origem)}</p>`);
w(`<p>${esc(LG.natureza)}</p>`);
w(`<p class="meta">Método: ${esc(LG.metodo)}</p>`);
w(`<h3>O custo já pago</h3>`);
w(`<p>${esc(LG.custo_ja_pago.resumo)}</p>`);
w(`<table><tbody>` + Object.entries(LG.custo_ja_pago).filter(([k]) => k !== 'resumo').map(([k, v]) =>
  `<tr><td>${esc(k.replace(/_/g, ' '))}</td><td><strong>${v.toLocaleString('pt-BR')}</strong></td></tr>`).join('') + `</tbody></table>`);
const achLeg = gaps.achados_detalhados.filter((a) => a.lente === 'legado');
w(`<h3>Os ${achLeg.length} achados que nenhuma outra lente viu</h3>`);
achLeg.forEach((a, i) => {
  w(`<h4>${i + 1}. ${esc(a.titulo)} <span class="meta">[${esc(a.prioridade)}]</span></h4>`);
  w(`<p>${esc(a.descricao)}</p>`);
  w(`<p><strong>Por que é fundação:</strong> ${esc(a.por_que_fundacao)}</p>`);
  w(`<p><strong>Evidência:</strong> ${esc(a.evidencia)}</p>`);
});
w(`<h3>Antipadrões e guarda-corpos</h3>`);
w(`<table><thead><tr><th>O erro</th><th>O que custou</th><th>Guarda-corpo</th></tr></thead><tbody>` +
  LG.antipadroes.map((a) => `<tr><td>${esc(a.erro)}</td><td>${esc(a.consequencia_real)}</td><td>${esc(a.guarda_corpo)}</td></tr>`).join('') +
  `</tbody></table>`);
w(`<h3>Confirmações empíricas de achados já levantados</h3>`);
w(`<table><thead><tr><th>Achado</th><th>O que de fato aconteceu</th><th>Data</th></tr></thead><tbody>` +
  LG.confirmacoes.map((c) => `<tr><td>${esc(c.achado_id)}</td><td>${esc(c.evidencia)}</td><td>${esc(c.data_no_changelog)}</td></tr>`).join('') +
  `</tbody></table>`);
w(`<h3>Já resolvido no schema atual</h3>`);
w(`<table><thead><tr><th>Item</th><th>Onde</th><th>Nota</th></tr></thead><tbody>` +
  LG.ja_implementado_no_schema.map((d) => `<tr><td>${esc(d.item)}</td><td><code>${esc(d.onde)}</code></td><td>${esc(d.nota)}</td></tr>`).join('') +
  `</tbody></table>`);

/* --- arquitetura --- */
w(`<h2 id="arquitetura">6. Arquitetura técnica</h2>`);
w(`<p>${esc(arq.meta.ambicao)}</p>`);
w(`<h3>Princípios</h3><ul>` + arq.meta.principios.map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
const kv = (o) => `<table><tbody>` + Object.entries(o).map(([k, v]) =>
  `<tr><td><strong>${esc(k.replace(/_/g, ' '))}</strong></td><td>${esc(typeof v === 'string' ? v : Object.values(v).join(' — '))}</td></tr>`).join('') + `</tbody></table>`;
w(`<h3>Stack</h3>`);
w(`<h4>Frontend</h4>${kv(arq.stack.frontend)}`);
w(`<h4>Backend</h4>${kv(arq.stack.backend)}`);
w(`<h4>Infraestrutura</h4>${kv(arq.stack.infra)}`);
w(`<h3>Banco de dados</h3>${kv({
  principal: arq.banco_de_dados.principal,
  estrategia_multi_tenant: arq.banco_de_dados.multi_tenancy.estrategia,
  racional: arq.banco_de_dados.multi_tenancy.racional,
  cache: arq.banco_de_dados.cache, arquivos: arq.banco_de_dados.arquivos,
  vetorial: arq.banco_de_dados.vetorial, analitico: arq.banco_de_dados.analitico })}`);
w(`<h4>Backups e recuperação</h4>${kv(arq.banco_de_dados.backups)}`);
w(`<h3>Segurança</h3>`);
[['Autenticação', 'autenticacao'], ['Autorização', 'autorizacao'], ['Criptografia', 'criptografia'],
 ['Aplicação', 'aplicacao'], ['Verificação contínua', 'verificacao']].forEach(([t, k]) => {
  w(`<h4>${t}</h4><ul>` + arq.seguranca[k].map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
});
w(`<h4>Segredos e auditoria</h4>${kv({ segredos: arq.seguranca.segredos, auditoria: arq.seguranca.auditoria })}`);
w(`<h3>LGPD e conformidade</h3><ul>` + arq.seguranca.lgpd.map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
w(`<h3>Escalabilidade</h3><ul>` + arq.escalabilidade.estrategia.map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
w(`<h4>Metas de serviço (SLO)</h4>${kv(arq.escalabilidade.slos)}`);
w(`<h3>Observabilidade e DevOps</h3>`);
[['CI/CD', 'ci_cd'], ['Monitoramento', 'monitoramento'], ['Testes', 'testes']].forEach(([t, k]) => {
  w(`<h4>${t}</h4><ul>` + arq.observabilidade_devops[k].map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
});
w(`<h3>Integrações externas</h3>${kv(arq.integracoes)}`);
w(`<h3>Convenções de API</h3><ul>` + arq.api.convencoes.map((x) => `<li>${esc(x)}</li>`).join('') + `</ul>`);
w(`<h3>Eventos assíncronos</h3><ul>` + arq.api.eventos_assincronos.map((x) => `<li><code>${esc(x)}</code></li>`).join('') + `</ul>`);

/* --- rotas --- */
w(`<h2 id="rotas">7. Mapa de rotas da API</h2>`);
w(`<div class="wrap"><table><thead><tr><th>Domínio</th><th>Base</th><th>Endpoints</th></tr></thead><tbody>` +
  Object.entries(arq.api.rotas).map(([k, r]) =>
    `<tr><td><strong>${esc(k.replace(/_/g, ' '))}</strong></td><td><code>${esc(r.base)}</code></td><td>${r.endpoints.map((e) => `<code>${esc(e)}</code>`).join('<br>')}</td></tr>`
  ).join('') + `</tbody></table></div>`);

/* --- fases --- */
w(`<h2 id="fases">8. Fases de construção</h2>`);
w(`<p>Reordenadas para respeitar a dependência do catálogo. Cada fase tem critério objetivo de conclusão.</p><ol>`);
arq.fases_de_construcao.forEach((f) => {
  w(`<li><strong>${esc(f.nome)}</strong> — ${esc(f.entrega)}<br><span class="meta">Pronto quando: ${esc(f.pronto_quando)}</span></li>`);
});
w(`</ol>`);

/* --- modelo de dados --- */
w(`<h2 id="modelo">9. Modelo de dados implementado</h2>`);
const R = inv.resumo;
w(`<p>Hierarquia de estabelecimentos, catálogo, agenda e balcão estão modelados em PostgreSQL ${inv.postgres} e validados contra um banco real.</p>`);
w(`<table><tbody>
<tr><td>Tabelas</td><td><strong>${R.tabelas}</strong></td></tr>
<tr><td>Colunas</td><td><strong>${R.colunas}</strong></td></tr>
<tr><td>Tabelas com RLS habilitada e forçada</td><td><strong>${R.com_rls}</strong> (as ${R.tabelas - R.com_rls} restantes não têm <code>tenant_id</code>)</td></tr>
<tr><td>Constraints CHECK</td><td><strong>${R.checks}</strong></td></tr>
<tr><td>Constraints EXCLUDE</td><td><strong>${R.excludes}</strong></td></tr>
<tr><td>Chaves estrangeiras</td><td><strong>${R.fks}</strong></td></tr>
<tr><td>Migrations</td><td><strong>${R.migrations}</strong></td></tr>
<tr><td>Asserções de teste passando</td><td><strong>${R.asercoes}</strong></td></tr>
</tbody></table>`);
w(`<p>Executar tudo: <code>./db/run.sh</code> — aplica migrations, carrega o seed de demonstração e roda as quatro suítes de teste mais a prova de concorrência.</p>`);

w(`<h3>Convenções verificadas por teste</h3><ul>
<li><strong>PK composta <code>(tenant_id, id)</code></strong> em toda tabela de tenant; as FKs também carregam <code>tenant_id</code>, então o banco impede referência cruzada entre tenants.</li>
<li><strong><code>tenant_id</code> é a primeira coluna de todo índice.</strong></li>
<li><strong>UUIDv7 gerado pela aplicação</strong>, ordenável por tempo, compatível com geração offline.</li>
<li><strong>Numeração humana sequencial por tenant</strong> ao lado da chave técnica.</li>
<li><strong>RLS habilitada e forçada</strong>, política única por <code>tenant_id</code>. Sem contexto de tenant, zero linhas: falha fechada.</li>
<li><strong>Soft delete com tombstone</strong> e <code>atualizado_em</code> indexado, para sincronização incremental do aplicativo móvel.</li>
<li><strong>Vigência SCD-2</strong> em preço, custo e parâmetro fiscal, com <code>EXCLUDE</code> impedindo sobreposição.</li>
<li><strong><code>sistema_origem</code> + <code>id_externo</code></strong> único por tenant: reimportar base de concorrente não duplica.</li>
<li><strong>Fuso IANA por estabelecimento</strong>, validado contra o catálogo do servidor.</li>
</ul>`);

w(`<h3>Hierarquia organizacional</h3>
<pre>GRUPO → PESSOA_JURIDICA (CNPJ) → ESTABELECIMENTO → UNIDADE</pre>
<p>Regra de fronteira gravada no modelo: <strong>franqueado é tenant próprio</strong> (controlador LGPD distinto, CNPJ próprio, numeração fiscal própria); <strong>filial é estabelecimento do mesmo tenant</strong>. A árvore usa <code>parent_id</code> com caminho materializado em <code>ltree</code>, mantido por trigger, e rejeita aninhamento inválido.</p>`);

w(`<h3>Tabelas</h3><div class="wrap"><table>
<thead><tr><th>Grupo</th><th>Tabela</th><th>Col.</th><th>RLS</th><th>CHECK</th><th>EXCL</th><th>FK</th><th>Papel</th></tr></thead><tbody>` +
  inv.tabelas.map((t) => `<tr><td>${esc(t.grupo)}</td><td><code>${esc(t.nome)}</code></td><td>${t.cols}</td>` +
    `<td>${t.rls ? 'sim' : '—'}</td><td>${t.checks || '—'}</td><td>${t.excl || '—'}</td><td>${t.fks || '—'}</td>` +
    `<td>${esc((t.doc || '').split('.')[0])}</td></tr>`).join('') + `</tbody></table></div>`);

/* --- provas --- */
w(`<h2 id="provas">10. Provas executadas</h2>`);
w(`<h3>Concorrência: o double-booking é impossível</h3>
<p>Trinta sessões PostgreSQL independentes disputaram o mesmo profissional no mesmo horário. Nenhum lock distribuído participou — a garantia é uma exclusion constraint.</p>
<pre>sessões que gravaram ......... 1
recusadas pela constraint .... 29
reservas no banco ............ 1</pre>
<p>A constraint: <code>EXCLUDE USING gist (tenant_id WITH =, recurso_id WITH =, slot WITH =, periodo WITH &amp;&amp;) WHERE (ativa)</code></p>`);

w(`<h3>Pausa química: a regra de domínio cai fora do mesmo mecanismo</h3>
<p>Coloração ocupa a profissional 40 min, depois 30 min de pausa química, depois 20 min de finalização. Durante a pausa ela atende outra cliente, mas a cadeira segue ocupada. Isso não é código especial: é a contagem de linhas de reserva.</p>
<pre>profissional →  2 reservas (antes e depois da pausa)  =  70 min
cadeira      →  1 reserva contígua                    = 100 min</pre>
<p>É essa distinção que devolve ao salão cerca de 30% da capacidade que uma agenda ingênua desperdiça.</p>`);

w(`<h3>Vigência de custo: o reajuste de julho não reescreve março</h3>
<pre>custo direto em março  = R$ 8,40   (tinta a R$ 80/L)
custo direto em agosto = R$ 9,60   (tinta a R$ 100/L, reajuste em 01/jul)
consultar março DEPOIS do reajuste = R$ 8,40</pre>
<p>Com <code>UPDATE</code> de valor em vez de nova versão, a comissão de março seria recalculada retroativamente — gerando passivo trabalhista — e não haveria backfill possível, porque a informação da vigência teria sido destruída.</p>`);

w(`<h3>Conferência cega: imposta pelo banco, não pela tela</h3>
<p>O operador declara o que contou sem ver o esperado, porque o papel dele não tem <code>GRANT</code> nessas colunas. Saída real do teste:</p>
<pre>operador tenta ler valor_esperado  → permission denied
operador tenta ler divergencia     → permission denied
operador lê o que ele mesmo declarou → ok</pre>
<p>Uma constraint separa quem conta de quem apura: <code>apurada_por &lt;&gt; conferida_por</code>.</p>`);

w(`<h3>Divergência de caixa não vira desconto automático</h3>
<p>O artigo 462 da CLT protege a integridade salarial e a jurisprudência sobre desconto de quebra de caixa é dividida. O sistema registra valor, justificativa e decisão nomeada — e para por aí. Um teste verifica que nenhum lançamento de ajuste é criado contra o operador. A consequência financeira é ato humano documentado, nunca efeito colateral de software.</p>`);

w(`<h3>A comanda nunca fica sem dono</h3>
<p>A custódia usa períodos com <code>EXCLUDE</code> contra sobreposição, mais um trigger que impede buraco entre um elo e o seguinte. Cadeia testada: recepção → cabeleireira → manicure → caixa, quatro elos, sempre exatamente um responsável, zero buracos. Transferir exige motivo tipado; motivo “outro” exige justificativa escrita. São recusados: transferir sem motivo, transferir sem deter a comanda, e transferir para si mesmo.</p>`);

/* --- fontes --- */
w(`<h2 id="fontes">11. Fontes legíveis por máquina</h2>`);
w(`<p>Todos os arquivos abaixo são servidos diretamente e podem ser buscados por programa.</p>`);
w(`<div class="wrap"><table><thead><tr><th>Arquivo</th><th>Conteúdo</th></tr></thead><tbody>
<tr><td><a href="${BASE_URL}/gaps.json"><code>gaps.json</code></a></td><td>Análise de lacunas completa: diagnóstico, módulos novos, reforços, decisões irreversíveis e os ${gaps.meta.contagem.consolidados} achados detalhados</td></tr>
<tr><td><a href="${BASE_URL}/architecture.json"><code>architecture.json</code></a></td><td>Especificação técnica: stack, banco, segurança, LGPD, rotas, eventos, SLOs e fases</td></tr>
<tr><td><a href="${BASE_URL}/dependencias.json"><code>dependencias.json</code></a></td><td>As ${deps.total} ligações entre módulos, com a contagem de FKs que sustenta cada uma</td></tr>
<tr><td><a href="${BASE_URL}/schema-inventario.json"><code>schema-inventario.json</code></a></td><td>Inventário das ${R.tabelas} tabelas extraído do banco</td></tr>
<tr><td><a href="${BASE_URL}/db/README.md"><code>db/README.md</code></a></td><td>Documentação do modelo de dados</td></tr>
<tr><td><a href="${BASE_URL}/llms.txt"><code>llms.txt</code></a></td><td>Índice para agentes automáticos</td></tr>
</tbody></table></div>`);
w(`<p class="meta">As migrations SQL ficam em <code>db/migrations/</code> e os testes em <code>db/tests/</code>, também acessíveis pela mesma URL base.</p>`);

fs.writeFileSync(path.join(RAIZ, 'dossie.html'), P.join('\n') + '\n');

/* ========================================================================== */
/* llms.txt                                                                    */
/* ========================================================================== */
const llms = `# LUMIA

> Sistema de gestão para o setor de beleza e estética no Brasil, com metodologia
> MQS embutida, projetado para escala nacional. Fundação em PostgreSQL:
> ${R.tabelas} tabelas, ${R.fks} chaves estrangeiras, ${R.asercoes} asserções de teste passando.

A página inicial (${BASE_URL}/) é interativa e monta o conteúdo por JavaScript.
Se você não executa scripts, use o dossiê estático abaixo — ele contém tudo.

## Documentos principais

- [Dossiê completo](${BASE_URL}/dossie.html): todo o conteúdo em HTML estático, sem JavaScript — 21 módulos, dependências, decisões, arquitetura e modelo de dados
- [Blueprint interativo](${BASE_URL}/): fluxograma de dependências navegável, requer JavaScript

## Dados estruturados

- [gaps.json](${BASE_URL}/gaps.json): análise de lacunas — diagnóstico, ${gaps.modulos_novos.length} módulos novos, ${gaps.reforcos_modulos_existentes.length} reforços, ${gaps.decisoes_irreversiveis.length} decisões irreversíveis, ${gaps.meta.contagem.consolidados} achados
- [architecture.json](${BASE_URL}/architecture.json): stack, banco de dados, segurança, LGPD, ${Object.keys(arq.api.rotas).length} domínios de API, SLOs, ${arq.fases_de_construcao.length} fases de construção
- [dependencias.json](${BASE_URL}/dependencias.json): ${deps.total} ligações entre módulos, ${deps.verificadas} verificadas por chave estrangeira real
- [schema-inventario.json](${BASE_URL}/schema-inventario.json): as ${R.tabelas} tabelas do schema com contagem de constraints

## Código

- [db/README.md](${BASE_URL}/db/README.md): documentação do modelo de dados
- [db/migrations/](${BASE_URL}/db/migrations/): ${R.migrations} migrations PostgreSQL
- [db/tests/](${BASE_URL}/db/tests/): suítes de teste, incluindo prova de concorrência com 30 sessões

## Contexto

Os módulos marcados com asterisco foram identificados em uma análise de lacunas
conduzida sob sete lentes independentes (operação de beleza, fiscal brasileiro,
LGPD, arquitetura, escala SaaS, benchmark competitivo e o sistema legado), cada
achado passando por revisão adversarial. A sétima lente é empírica: extraída do
CHANGELOG do sistema anterior, registra defeito que ocorreu em produção, decisão
já tomada pelo dono e custo já pago — ${gaps.lente_legado.custo_ja_pago.ciclos_de_reorganizacao} ciclos de reorganização e
${gaps.lente_legado.custo_ja_pago.ciclos_de_migracao_para_banco} de migração por ter construído a regra de negócio antes da fundação. A ordem de construção segue a dependência: catálogo
antes de agenda, agenda antes de caixa, caixa antes de comanda.
`;
fs.writeFileSync(path.join(RAIZ, 'llms.txt'), llms);

const kb = (f) => (fs.statSync(path.join(RAIZ, f)).size / 1024).toFixed(0);
console.log(`dossie.html  ${kb('dossie.html')} KB`);
console.log(`llms.txt     ${kb('llms.txt')} KB`);
