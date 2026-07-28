# LUMIA-projeto

## Documentação

Fonte de verdade — o fluxograma e os dados que o alimentam:

- [`index.html`](index.html) — blueprint interativo da fundação (abas: diagnóstico e decisões,
  lente do legado, fluxo de dependências, módulos, arquitetura, modelo de dados).
- [`dossie.html`](dossie.html) — o mesmo conteúdo sem JavaScript.
- [`gaps.json`](gaps.json) · [`architecture.json`](architecture.json) ·
  [`dependencias.json`](dependencias.json) · [`schema-inventario.json`](schema-inventario.json).

Derivação da análise do sistema anterior (raciocínio e mecanismo, não especificação):

- [`docs/fundacao/ANALISE-DO-LEGADO.md`](docs/fundacao/ANALISE-DO-LEGADO.md) — o critério de decisão
  e o que não se repete.
- [`docs/fundacao/INVARIANTES.md`](docs/fundacao/INVARIANTES.md) — o mecanismo concreto de cada
  invariante (DDL, GRANT, política, lint, teste).
- [`docs/fundacao/MAPA-DE-FASES.md`](docs/fundacao/MAPA-DE-FASES.md) — as regras do legado ancoradas
  nas fases canônicas F1–F10.