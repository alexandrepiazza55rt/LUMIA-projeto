# Kit de prompts — mapear a estrutura de um sistema

Para levantar a estrutura completa de um sistema (menus, abas, subseções, campos,
ações) e sair com um relatório e um JSON aproveitáveis.

São **três prompts**, usados em sequência. Mapear um sistema inteiro não cabe em
uma mensagem: você vai enviar as telas em lotes, e o risco real não é a IA
deixar de ver algo — é ela **preencher lacunas com suposição plausível**. Os
prompts abaixo são escritos para tornar isso difícil.

---

## Antes de começar: o que capturar

A qualidade do relatório é limitada pelo material. Para cada tela, capture:

- **O menu aberto/expandido** — é a única fonte confiável da árvore de navegação
- **A tela com dados** e **a tela vazia** — o estado vazio revela texto de ajuda
- **O formulário em modo de edição** — campos só aparecem quando editáveis
- **Cada modal, drawer e aba interna** — costumam esconder metade dos campos
- **Dropdowns abertos** — as opções de um `select` não aparecem fechado
- **Mensagens de erro de validação** — revelam obrigatoriedade, formato e limite
- **Rodapé de listagens** — filtros, colunas, ações em massa, paginação

Se o sistema for acessível por URL pública, informe o endereço: eu consigo
navegar. Área logada eu **não** acesso — nesse caso, capturas de tela.

---

## Prompt 1 — Abertura

> Copie, preencha os campos entre colchetes e envie junto com o primeiro lote de
> capturas.

```
Você vai me ajudar a levantar a ESTRUTURA COMPLETA de um sistema, a partir do
material que eu enviar. O objetivo final é um relatório de engenharia reversa da
interface: todo menu, submenu, aba, seção, campo, ação e coluna de listagem.

SISTEMA: [nome do sistema]
SETOR / FINALIDADE: [ex.: gestão para salões de beleza]
MEU OBJETIVO COM ESSE LEVANTAMENTO: [ex.: comparar com o sistema que estou
construindo / documentar antes de migrar / mapear concorrente]
MATERIAL QUE VOU ENVIAR: [capturas de tela / URL pública / HTML exportado]

═══════════════════════════════════════════════════════════════════
REGRA CENTRAL — separe o que você VIU do que você SUPÔS
═══════════════════════════════════════════════════════════════════

Este levantamento só tem valor se eu puder confiar em cada linha. Por isso:

1. Registre APENAS o que está visível no material. Não complete campos que
   "todo sistema desse tipo tem".
2. Marque cada item com um destes selos:
   [V] VISTO      — está literalmente na captura, li o rótulo
   [P] PARCIAL    — vi o elemento mas não consegui ler tudo (cortado, ilegível,
                    dropdown fechado)
   [S] SUPOSIÇÃO  — não vi, estou inferindo por contexto. Diga em que se baseou.
3. Nunca converta [S] em [V] depois. Suposição só vira observação com captura
   nova.
4. Se um menu tem submenus que eu não enviei, registre o menu e liste o submenu
   como NÃO CAPTURADO — não tente adivinhar o conteúdo.
5. Transcreva rótulos EXATAMENTE como aparecem, inclusive maiúsculas,
   abreviações e erros de digitação do próprio sistema. Não "corrija" nem
   traduza.
6. Se duas capturas se contradizem, aponte a contradição em vez de escolher uma.

═══════════════════════════════════════════════════════════════════
O QUE EXTRAIR DE CADA TELA
═══════════════════════════════════════════════════════════════════

NAVEGAÇÃO
- Caminho completo até a tela (ex.: Cadastros › Clientes › Editar › aba Fiscal)
- Tipo de navegação (menu lateral, superior, abas, modal, drawer, wizard)

CAMPOS — para cada um:
- Rótulo exato
- Tipo aparente (texto, número, moeda, data, hora, seleção, múltipla seleção,
  checkbox, alternância, upload, área de texto, busca com autocomplete, editor)
- Obrigatório? (indicado por asterisco, cor, mensagem de erro — diga como soube)
- Opções, quando for seleção — liste todas as visíveis
- Máscara ou formato (CPF, CNPJ, telefone, moeda, percentual)
- Valor padrão, se visível
- Texto de ajuda, placeholder ou tooltip
- Limite de caracteres ou validação observada
- Campo dependente? (ex.: "só aparece quando Tipo = Pessoa Jurídica")

AÇÕES
- Todo botão, ícone clicável e item de menu de contexto
- O que cada um aparenta fazer
- Ações destrutivas e se pedem confirmação
- Ações que aparentam exigir permissão especial

LISTAGENS E TABELAS
- Colunas exibidas, na ordem
- Filtros disponíveis e seus tipos
- Ordenação, paginação, busca
- Ações em massa
- Exportações oferecidas

REGRAS E ESTADOS
- Estados do registro (rascunho, ativo, cancelado…) e transições visíveis
- Mensagens de validação capturadas
- Indícios de perfil/permissão (itens desabilitados, avisos de acesso)
- Integrações visíveis (WhatsApp, gateway de pagamento, nota fiscal, etc.)

═══════════════════════════════════════════════════════════════════
FORMATO DA RESPOSTA A CADA LOTE
═══════════════════════════════════════════════════════════════════

Para cada lote que eu enviar, responda com:

1. INVENTÁRIO DO LOTE — as telas deste lote, no formato hierárquico:

   ## [Módulo] › [Submenu] › [Tela]  [V]
   **Navegação:** menu lateral › ...
   **Finalidade aparente:** ...

   ### Seção: [nome da seção do formulário]  [V]
   | Campo | Tipo | Obrig. | Opções / formato | Observações | Selo |
   |---|---|---|---|---|---|

   ### Ações
   | Rótulo | Efeito aparente | Destrutiva? | Selo |

   ### Listagem (se houver)
   Colunas: ... · Filtros: ... · Ações em massa: ...

2. ÁRVORE ATUALIZADA — a árvore de navegação acumulada até agora, com
   `[NÃO CAPTURADO]` em cada ramo que ainda não vi.

3. O QUE FALTA — lista objetiva do que preciso capturar em seguida para fechar
   as lacunas, em ordem de importância. Seja específico: "abrir o dropdown
   Situação em Clientes › Editar", não "mais telas de clientes".

4. OBSERVAÇÕES — contradições, campos ilegíveis, decisões de interface que
   chamaram atenção.

Não escreva conclusões nem comparações ainda. Por enquanto é só inventário.
Confirme que entendeu e analise o primeiro lote em anexo.
```

---

## Prompt 2 — Continuação

> Use a cada novo lote de capturas. Curto de propósito.

```
Próximo lote em anexo: [descreva o que está enviando, ex.: "Financeiro ›
Contas a pagar, com o modal de nova conta e o dropdown de categoria aberto"].

Mantenha as mesmas regras e selos. Responda com:
1. Inventário deste lote
2. Árvore de navegação atualizada (acumulada, com [NÃO CAPTURADO] onde falta)
3. O que ainda falta capturar, em ordem de importância
4. Qualquer item anterior que este lote CORRIJA — diga explicitamente o que
   muda e por quê
```

---

## Prompt 3 — Consolidação final

> Use quando terminar de enviar as capturas.

```
Terminei de enviar o material. Consolide tudo em um relatório final.

PARTE 1 — RELATÓRIO
1. Resumo executivo: o que é o sistema, para quem, como se organiza (10 linhas)
2. Árvore de navegação completa, com marcação de cobertura por ramo
3. Inventário detalhado por módulo, no formato dos lotes
4. Tabela consolidada de TODOS os campos do sistema:
   módulo | tela | seção | campo | tipo | obrigatório | selo
5. Entidades de negócio que a interface deixa transparecer, e como se
   relacionam (ex.: "Comanda referencia Cliente e Profissional; item de comanda
   referencia Serviço"). Baseie-se em campos e listagens observados, e marque
   claramente o que é inferência.
6. Padrões de interface recorrentes (como faz busca, como confirma exclusão,
   como trata obrigatoriedade, onde ficam as ações)
7. Pontos fortes da estrutura — o que está bem resolvido
8. Fragilidades e lacunas aparentes — o que parece faltar ou estar mal
   resolvido, com o cuidado de distinguir "não existe" de "não capturei"

PARTE 2 — COBERTURA (seja rigoroso aqui)
- Percentual estimado da interface efetivamente coberto, e como chegou nele
- Lista do que ficou NÃO CAPTURADO
- Lista de tudo que está marcado [S] SUPOSIÇÃO, reunido em um lugar só, para eu
  decidir o que vale confirmar
- As 10 capturas que mais aumentariam a confiabilidade do relatório

PARTE 3 — JSON
Um bloco JSON com a estrutura completa, neste formato:

{
  "sistema": "", "capturado_em": "", "cobertura_estimada": "",
  "modulos": [{
    "nome": "", "selo": "V|P|S", "icone_ou_rotulo": "",
    "submenus": [{
      "nome": "", "selo": "",
      "telas": [{
        "nome": "", "caminho": "", "tipo": "listagem|formulario|painel|modal|wizard",
        "selo": "",
        "secoes": [{
          "nome": "", "selo": "",
          "campos": [{
            "rotulo": "", "tipo": "", "obrigatorio": true,
            "como_soube_obrigatorio": "", "opcoes": [], "formato": "",
            "padrao": "", "ajuda": "", "condicional": "", "selo": ""
          }]
        }],
        "acoes": [{"rotulo":"","efeito":"","destrutiva":false,"selo":""}],
        "listagem": {"colunas":[],"filtros":[],"acoes_massa":[],"exportacoes":[]}
      }]
    }]
  }],
  "entidades_inferidas": [{"nome":"","campos_observados":[],"relacionamentos":[],"confianca":""}],
  "nao_capturado": [],
  "suposicoes": [{"item":"","base_da_suposicao":""}]
}

Não invente nada para preencher o JSON. Campo não observado fica ausente ou
null, nunca preenchido por plausibilidade.
```

---

## Variações úteis

**Se o objetivo é comparar com outro sistema**, acrescente ao Prompt 3:

```
PARTE 4 — COMPARAÇÃO
Compare a estrutura levantada com [descreva ou anexe a estrutura do outro
sistema]. Produza:
- O que o sistema analisado tem e o outro não
- O que o outro tem e o analisado não
- Onde os dois resolvem a mesma coisa de formas diferentes, e qual abordagem
  parece mais sólida — justificando
Marque cada linha com a confiança do levantamento que a sustenta.
```

**Se o objetivo é migrar dados**, acrescente:

```
PARTE 4 — MIGRAÇÃO
Para cada entidade inferida, liste os campos que precisariam ser mapeados,
identifique quais parecem ser identificadores naturais, e aponte onde a
estrutura de origem perderia informação ao ser migrada.
```

**Se o sistema tem área pública** (agendamento online, catálogo), acrescente ao
Prompt 1: `A URL pública é [endereço] — navegue e inclua no levantamento.`

---

## O que esperar

- **Uma sessão longa.** Um sistema de porte médio leva de 40 a 80 capturas.
  Envie em lotes de 5 a 10, por módulo, não misturando áreas.
- **Cobertura honesta em torno de 70–85%** para um sistema que você não
  administra. Telas de configuração e casos de exceção quase sempre escapam.
- **O JSON é o entregável durável.** O relatório em prosa envelhece; o JSON
  alimenta comparação, planilha e o próximo levantamento.
- **Peça o JSON antes de a conversa ficar muito longa.** Se perceber que o
  histórico está grande, peça a consolidação parcial, comece uma conversa nova
  e cole o JSON como ponto de partida.
