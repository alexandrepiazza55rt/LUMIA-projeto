# LUMIA-projeto

## Documentação

Fonte de verdade — o fluxograma e os dados que o alimentam:

- [`index.html`](index.html) — blueprint interativo da fundação (abas: diagnóstico e decisões,
  lente do legado, fluxo de dependências, módulos, arquitetura, modelo de dados).
- [`dossie.html`](dossie.html) — o mesmo conteúdo sem JavaScript.
- [`gaps.json`](gaps.json) · [`architecture.json`](architecture.json) ·
  [`dependencias.json`](dependencias.json) · [`schema-inventario.json`](schema-inventario.json).

### Publicar

O site monta **todo** o conteúdo por JavaScript, então um erro de sintaxe no script inline não degrada
nada — apaga a página inteira: sem texto, sem abas, sem nada clicável. Antes de publicar:

```sh
node tools/gerar-dossie.js     # regenera dossie.html e llms.txt a partir dos JSON
node tools/verificar-pagina.js # o script compila? JSON válido? alvos e abas ligados?
```

`verificar-pagina.js` roda em Node puro, sem navegador. Ele existe porque essa falha já aconteceu:
um `const G` novo colidiu com o `const G` do grafo de dependências e derrubou a página publicada.

O GitHub Pages serve do branch `claude/business-structure-flowchart-yjybyj`, a partir de `index.html`
na raiz — que precisa ser idêntico a `blueprint.html` (o verificador confere).

Derivação da análise do sistema anterior (raciocínio e mecanismo, não especificação):

- [`docs/fundacao/ANALISE-DO-LEGADO.md`](docs/fundacao/ANALISE-DO-LEGADO.md) — o critério de decisão
  e o que não se repete.
- [`docs/fundacao/INVARIANTES.md`](docs/fundacao/INVARIANTES.md) — o mecanismo concreto de cada
  invariante (DDL, GRANT, política, lint, teste).
- [`docs/fundacao/MAPA-DE-FASES.md`](docs/fundacao/MAPA-DE-FASES.md) — as regras do legado ancoradas
  nas fases canônicas F1–F10.