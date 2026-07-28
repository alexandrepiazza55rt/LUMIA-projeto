#!/usr/bin/env node
/**
 * LUMIA · Verificador do blueprint (index.html / blueprint.html)
 * =============================================================================
 * A página monta TODO o conteúdo por JavaScript. Isso tem uma consequência
 * brutal: um único erro de sintaxe no script inline não degrada nada — ele
 * apaga a página inteira. Sem texto, sem abas, sem nada clicável, e sem
 * nenhuma pista visual do que houve.
 *
 * Foi exatamente o que aconteceu: um `const G` novo colidiu com o `const G` do
 * grafo de dependências, e o SyntaxError derrubou a página publicada.
 *
 * Este verificador roda em Node puro, sem navegador e sem dependência, e checa:
 *   1. cada bloco <script> inline COMPILA (pega colisão de identificador,
 *      parêntese solto, template literal não fechado);
 *   2. cada <script type="application/json"> é JSON válido e não contém a
 *      sequência que fecharia a tag antes da hora;
 *   3. todo getElementById('x') do script tem um id="x" no HTML;
 *   4. index.html e blueprint.html continuam idênticos.
 *
 * Uso:  node tools/verificar-pagina.js
 * Sai com código 1 na primeira falha.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const RAIZ = path.join(__dirname, '..');
const falhas = [];
const ok = (m) => console.log('  OK   ' + m);
const falhar = (m) => { falhas.push(m); console.log('  FALHOU: ' + m); };

const ARQ = 'blueprint.html';
const html = fs.readFileSync(path.join(RAIZ, ARQ), 'utf8');

/* -- 1. os scripts inline compilam ---------------------------------------- */
const scripts = [...html.matchAll(/<script(?![^>]*\btype="application\/json")[^>]*>([\s\S]*?)<\/script>/g)]
  .map((m) => m[1])
  .filter((s) => s.trim());

if (!scripts.length) falhar('nenhum script inline encontrado — o seletor quebrou?');
scripts.forEach((src, i) => {
  try {
    // Compila sem executar. Duas declarações do mesmo const no mesmo escopo
    // são SyntaxError aqui, igual ao navegador.
    new Function(src);
    ok(`script inline ${i + 1}/${scripts.length} compila (${src.length} chars)`);
  } catch (e) {
    falhar(`script inline ${i + 1} NÃO compila — ${e.name}: ${e.message}`);
  }
});

/* -- 2. os blocos JSON são válidos ---------------------------------------- */
const jsons = [...html.matchAll(/<script type="application\/json" id="([^"]+)">([\s\S]*?)<\/script>/g)];
if (!jsons.length) falhar('nenhum bloco JSON embutido encontrado');
jsons.forEach(([, id, txt]) => {
  try {
    JSON.parse(txt);
  } catch (e) {
    return falhar(`bloco JSON #${id} inválido — ${e.message}`);
  }
  // Uma barra-script dentro de string fecharia a tag no parser do navegador.
  if (/<\/script/i.test(txt)) return falhar(`bloco JSON #${id} contém "</script" e fecharia a tag antes da hora`);
  ok(`bloco JSON #${id} é válido (${(txt.length / 1024).toFixed(0)} KB)`);
});

/* -- 3. todo alvo de render existe no HTML -------------------------------- */
const alvos = [...html.matchAll(/getElementById\((['"])([^'"]+)\1\)/g)].map((m) => m[2]);
const ausentes = [...new Set(alvos)].filter((id) => !new RegExp(`id="${id}"`).test(html));
if (ausentes.length) falhar(`getElementById sem elemento correspondente: ${ausentes.join(', ')}`);
else ok(`os ${new Set(alvos).size} alvos de getElementById existem no HTML`);

/* -- 4. as abas estão ligadas -------------------------------------------- */
const wiring = html.match(/const T=\[[\s\S]*?\]\];/);
const abas = [...html.matchAll(/<button class="tab" id="(t-[a-z]+)"/g)].map((m) => m[1]);
if (!wiring) falhar('não encontrei a tabela de ligação das abas (const T)');
else {
  const naoLigadas = abas.filter((t) => !wiring[0].includes(`'${t}'`));
  if (naoLigadas.length) falhar(`aba sem handler registrado em const T: ${naoLigadas.join(', ')}`);
  else ok(`as ${abas.length} abas estão ligadas ao handler`);
}

/* -- 5. index.html espelha blueprint.html --------------------------------- */
const idx = fs.readFileSync(path.join(RAIZ, 'index.html'), 'utf8');
if (idx !== html) falhar('index.html divergiu de blueprint.html — o Pages serve o index');
else ok('index.html idêntico a blueprint.html');

console.log('');
if (falhas.length) {
  console.log(`✗ ${falhas.length} falha(s) — não publique. Script que não compila deixa a página em branco;`);
  console.log('  alvo ou aba faltando quebra só aquele pedaço, mas em silêncio.');
  process.exit(1);
}
console.log('✓ blueprint verificado — a página monta.');
