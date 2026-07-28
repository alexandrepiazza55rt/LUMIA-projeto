# Mapa de fases — o que não entra na fundação, e o que já fica decidido

O que **não** é fundação não é "para depois pensar". Cada fase abaixo carrega **restrições
vinculantes**: decisões tomadas agora, escritas na lei do repositório, construídas junto com o módulo.
Custam uma linha hoje; custam a tabela inteira se descobertas com dados dentro.

Legenda: **↳** = restrição vinculante (decidida agora) · *regra* = herdada do legado, com a data da
entrada que a originou.

---

## Fase 1 · Acesso

**Entra:** login real, ciclo de senha, tela única de cadastro de gente, concessão de funções.

- *Uma pessoa é cadastrada num lugar só*: a tela decide se ela tem acesso, ficha de negócio, ou ambos (23/07).
  O legado teve duas telas cadastrando pessoas e isso escondeu o bug do profissional que "não existia".
- *Senha provisória com no mínimo 8 caracteres; no primeiro acesso o usuário cria a própria senha
  antes de abrir qualquer tela* (15/06, endurecido na auditoria de 07/07).
- *O último administrador não pode ser removido, revogado nem desativado* (15/06).
  **Não é fundação:** é um trigger de ~20 linhas, aditivo, e enquanto não há clientes o modo de falha
  tem conserto trivial. Mas entra junto com a tela, não depois dela.
- *Ninguém altera as próprias funções nem o próprio status* — verificado no banco (15/06).
- *A lista de ações e os destinatários possíveis são calculados no servidor a partir do ator e do
  estado.* Cicatriz: no legado, **quem enviava** uma transferência via os botões de aceitar/recusar
  (22/07) — a autorização morava no componente que desenhava o botão.

**↳** Nenhuma constante de autorização no repositório do front. Sem banco, a tela de administração
não abre — falha visível, nunca fallback local (o legado criou essa segunda fonte de verdade em 23/07).

---

## Fase 2 · Cadastros e catálogo

**Entra:** cliente, equipe, serviços (grupo → subgrupo → serviço), produtos, parâmetros.

- *Editar cadastro nunca reescreve o passado*: comandas, vendas e recibos já feitos continuam com os
  valores de então; a tela viva mostra o dado atual (23/06).
- *Toda edição gera trilha de/para por campo* (17/06, 23/06).
- *Origens de cliente, categorias, fabricantes e fornecedores são listas cadastráveis pelo dono*, com
  criação na hora — nunca enum no código (17/06).
- *Serviço com preço GRATUITO ocupa a agenda e não fatura* (cortesia e retrabalho) (17/06).
- *Serviço tem tipo de preço: fixo, "a partir de", gratuito* (17/06).
- **Antipadrão a não repetir:** matriz de comissão fixa no código, invisível ao dono — governou o
  pagamento até 23/07, quando teve de ser eliminada.

**↳ Todo número que o dono poderia querer mudar é linha de parâmetro com vigência, autor e trilha
de/para.** Parâmetro ausente é **falha alta**, nunca um default numérico escondido. A proibição do
literal dentro do motor de dinheiro vale desde o dia 1 (lint); o mecanismo de vigência nasce aqui.

**↳** Serviço externo (ViaCEP e o que vier depois) é **auxiliar de preenchimento**: nunca participa do
caminho de gravação, escreve em colunas próprias, falha visível, preenchimento manual sempre
disponível. Nenhuma FK nem cache apontando para dado de terceiro.

---

## Fase 3 · Agenda

**Entra:** agendamento, bloqueio, disponibilidade, recorrência, ciclo de atendimento.

- *Ocupação de recurso é um conceito próprio, acima de Agenda e de Locação* — nenhum dos dois é dono
  da verdade do outro. **Cicatriz:** existiam duas verificações que não se enxergavam (o agendamento só
  olhava agendamentos, a locação só olhava locações) e dava para reservar a mesma sala duas vezes (23/06).
- *A garantia contra sobreposição mora no armazenamento*, não numa função que todo caminho de gravação
  precisa lembrar de chamar.
- *Qualquer mudança de horário, duração, sala ou profissional revalida a ocupação no destino antes de
  gravar*; cancelar/faltar/remarcar libera na hora (11/06 — remarcar nem revalidava a sala).
- *Remarcar nunca move o registro*: o antigo fica no lugar marcado como Remarcado (sem ocupar, fora das
  contas) e um novo aponta para ele, formando cadeia A→B→C (17/06).
- *Duração resolve em cascata* (agendamento → profissional×serviço → padrão do serviço) e fica gravada
  no agendamento; ajustar ali nunca altera o cadastro (17/06).
- *Encaixe sobre horário ocupado exige autorização explícita*, com quem autorizou e quando (17/06).
- *Bloqueio não grava por cima de cliente*: lista cada conflito e só libera quando todos forem
  resolvidos (17/06).
- *Check-in só na data do próprio agendamento* (11/06).
- *Sala tem capacidade declarada* — conflito é por lotação, não pela existência de outra reserva (23/06).
- *Buffers opcionais de preparo e limpeza entram no cálculo do conflito* (23/06).
- *Estados previstos:* Pendente → Confirmado → Chegou → Em atendimento → Finalizado → Concluído, com
  saídas Faltou, Cancelado, Remarcado. **Cada transição é evento datado, não sobrescrita de campo.**
- *Recorrência materializa ocorrências individuais*; cancelar pergunta "só esta" ou "esta e as
  próximas" (11/06).

**↳ A tabela de reserva nasce com `EXCLUDE USING gist` por (empresa, recurso, intervalo)** — a
sobreposição é impossível no armazenamento, não validada por código. Origem da reserva (atendimento,
locação, bloqueio) é coluna desde o DDL.

**↳** Agendamento aponta para `equipe`, nunca para `usuario` (regra de FK da fundação, F-A2).

---

## Fase 4 · Comanda / PDV e fechamento

**Entra:** o motor de dinheiro. É a fase mais sensível — a fundação inteira existe para sustentá-la.

- *Uma visita, uma comanda*, compartilhada por todos os profissionais que atenderem o cliente (11/06).
- *O ciclo de vida corre por ITEM*: encerrar o atendimento de um profissional afeta só os itens dele e
  nunca derruba o serviço do colega na mesma comanda (11/06).
- *Cancelar atendimento em andamento remove o item na hora* — nada de item fantasma cobrando serviço
  não realizado (11/06).
- *A comanda cobra o preço acordado no agendamento*, não o do catálogo no dia (11/06).
- *Comanda não exige agendamento nem cliente*: venda de balcão abre, lança e fecha (02/07).
- *Item sem profissional atribuído gera ZERO comissão.* **Cicatriz:** venda de balcão ("casa") gerava
  "comissão fantasma de 40%" (11/06).
- *Comissão do assistente sai da fatia do principal*, com piso zero; N assistentes por item, cada um
  com papel (17/06, 02/07). Adicionar assistente nunca aumenta o custo total do salão.
- *Percentual resolve em cascata*: % do serviço → % principal da pessoa → padrão do salão. A cascata é
  legítima; o que é proibido é o **default numérico escondido no código** (23/07).
- *Desconto exige motivo* e nunca é maior que o subtotal; total nunca negativo (11/06, 07/07).
- *Desconto rateado entre os itens antes da comissão*; taxa por forma de pagamento é despesa do salão;
  base da comissão (bruto/líquido/rateio) é parâmetro (10/06).
- *Comanda fechada não reabre.* A única reversão é estorno/contestação, com categoria e motivo
  obrigatórios: Administrador estorna na hora (auditado), os demais geram pedido para fila de
  aprovação (11/06, 07/07).
- *Estorno de item retira da apuração o principal e os assistentes daquele item* (02/07).
- *A comanda nunca fica órfã*: guarda para sempre quem abriu, tem sempre um responsável atual, a
  transferência é **de usuário para usuário** e só vale por aceite; recusa, cancelamento ou fim de
  expediente devolvem ao anterior (02/07, 22/07).
- *Mover item entre comandas abertas* não cria nem some dinheiro; depois do fechamento o vínculo é
  imutável (22/07).

**↳ Comissão é SEMPRE por participante do item**, nunca por coluna da comanda. Transferir a comanda
move a responsabilidade e o destino do dinheiro no caixa; **não move comissão**. Teste adversarial
obrigatório: abrir com A, transferir para B, fechar, e provar que a apuração de A não mudou um centavo
e a de B continua zero.

**↳ Item de comanda tem id próprio e `comanda_id` alterável enquanto ambas estão abertas** — não é
posição em array. Sem isso, "mover item" vira apagar aqui e recriar lá, ou seja, apagar dinheiro.

**↳ Pagamento é coleção de linhas (forma, valor, taxa)** — nunca forma e valor no cabeçalho da comanda.
**Cicatriz:** cancelar venda paga em duas formas devolvia só a primeira (11/06). Pagamento e comanda
não nascem 1:1 (a junção da fase 5 depende disso).

**↳ A primitiva de rateio recebe política de resíduo e ordenação como parâmetros obrigatórios, sem
default** — o legado manda o resíduo da junção para a **última** comanda e o da gorjeta para o
**primeiro** profissional. Ordenação estável obrigatória.

**↳ O arredondamento acontece uma vez só, num ponto declarado do motor.** **Cicatriz:** um
arredondamento extra na baixa de estoque mudava R$ 0,01 em embalagens fracionadas — pego pela auditoria
do ciclo 15, não pelos 428 testes.

---

## Fase 5 · Caixa por operador

**Entra:** sessão de caixa, movimentações, conciliação, fechamento do dia.

- *Cada operador abre a SUA sessão com fundo de troco*; sangria, suprimento e despesa são da sessão,
  com motivo obrigatório (07/07).
- *O esperado é fundo + dinheiro físico recebido + suprimentos − sangrias − despesas* (07/07).
- *A conferência conta SÓ dinheiro físico*; cartão, Pix e crédito são conferidos pelo registro (07/07).
- *Contagem cega*: o operador digita o contado **sem ver o esperado**; a sobra/falta só aparece depois
  de registrada a contagem; diferença exige justificativa (22/07). É o que impede a "contagem ajustada
  para bater".
- *Ao fechar, o Administrador é notificado e precisa carimbar "Conferi — está OK"* (imutável); enquanto
  não conferir, o caixa fica na fila, inclusive de dias anteriores (22/07).
- *Reabrir é privilégio exclusivo do Administrador, com motivo*; o registro original nunca é apagado (23/06).
- *O troco não altera a gaveta*: a sessão registra o líquido; o troco fica só como auditoria (07/07).
- *Pagamento parcial FECHA a comanda e gera devedor*; comanda com saldo em aberto exige cliente
  vinculado antes de fechar (07/07).
- *Junção de comandas*: cada uma fecha individualmente (snapshots e comissões preservados, nada
  recalculado nem duplicado); o valor de cada forma é rateado proporcionalmente; a sobra ou dívida fica
  com o **pagador do grupo**, não com o cliente da comanda (07/07).
- *O fechamento do DIA consolida as sessões, não as substitui*, e trava com sessão aberta, comanda
  aberta ou atendimento em andamento/finalizado sem comanda — cancelado, faltou e remarcado **não**
  travam. Só o Administrador fecha com pendência, sob justificativa registrada (07/07).
- *Comanda aberta NÃO é dinheiro*: aparece como aviso, não entra no caixa nem na previsão (07/07).

**↳** O dinheiro cai no caixa de **quem recebeu**, nunca de quem abriu a comanda — a coluna
`recebido_por` + `sessao_caixa_id` já nasce na linha do ledger na fase 4 (fundação F-A3 impõe o valor).

**↳** O que fecha o dia é aqui; a **trava de período fechado** já é da fundação (F-C10).

---

## Fase 6 · Financeiro consolidado

**Entra:** créditos e devedores, gorjeta a pagar, contas a pagar, DRE, fluxo de caixa.

- *Crédito de cliente é PASSIVO do salão e **não** é forma de pagamento* — é saldo abatível como o
  fiado, só do titular, nunca acima do saldo (07/07). Decisão explícita: virar forma de pagamento
  confundiria com cartão de crédito.
- *Fiado de venda estornada não pode ser recebido* (11/06).
- *Gorjeta nunca gera comissão*, é rateada igualmente entre os participantes (principais + assistentes,
  sem repetir, sem a casa) e é cancelada junto se a comanda for estornada. Natureza por forma: em
  **dinheiro** entra na gaveta sem ser receita; em **cartão/Pix** não entra na gaveta nem na receita
  (vira a pagar ao profissional); **"para a casa"** é receita (07/07).
- *Conta a pagar é FIXA ou POR MÉDIA*; a de média projeta pelos pagamentos já realizados do grupo,
  avisa "estimativa fraca" com pouco histórico, e é substituída pelo valor real quando paga (07/07).
- *Projeção nunca vira lançamento nem entra na DRE.*
- *Regime de CAIXA*: conta a pagar entra no mês em que foi **paga**, pela data de pagamento, não pelo
  vencimento — o vencimento é etiqueta de organização (07/07).
- *Previsto e Realizado nunca se misturam*: o realizado deriva das transações e nunca é digitado; a
  previsão **não** conta comanda em aberto (11/06, 07/07).

**↳** Tudo isso é **leitura** sobre o ledger da fase 4/5. Nenhuma dessas telas cria ou edita fato
financeiro — o legado acertou nisso ("é SÓ LEITURA: a aba não cria nem edita nada", 07/07) e vale
manter como restrição escrita.

---

## Fase 7 · Estoque valorizado

- *Livro-razão de movimentação*: toda entrada/saída registrada com motivo, append-only (17/06).
- *Custo médio ponderado recalculado a cada compra* (comprou a R$100 e depois a R$50 → R$75) (17/06).
- *Compra do fornecedor gera automaticamente a conta a pagar* (17/06).
- *Custo do insumo = custo médio ÷ quantidade da embalagem, descontada a perda* — e **perda só existe
  para produto de uso interno, nunca para revenda** (17/06).
- *Fechar comanda baixa produtos vendidos **e** os insumos dos serviços pela ficha técnica; estornar
  devolve ao estoque* (17/06).
- *"Valor em estoque" é calculado pelo custo médio* (17/06).

**↳** A baixa de estoque é um **efeito tipado com inverso declarado** (fundação F-C9) — é exatamente o
caminho em que o legado introduziu um arredondamento extra sem ninguém ver.

---

## Fase 8 · Salas e locação

- *Preço por m² com índice e ajustes; pagamento cai no caixa; estorno atualiza a tela* (11/06, 23/06).
- *Locação e atendimento-com-sala leem e gravam a **mesma** reserva* — a fonte única já é da fase 3.
- *Procedimento aparece na agenda de salas com cor distinta da locação* (23/06).

**↳** A locação é apenas mais um `tipo_origem` do ledger (fundação F-C4). Se o lançamento nascer preso
à comanda, esta fase exige comanda fantasma ou afrouxar a coluna com histórico dentro.

---

## Fase 9 · Fidelidade

- *Pontos, cashback, avaliações, prontuário, lista de espera, resgates* (10/06 em diante).
- *Fidelidade pontuar ou não produtos é parâmetro* (10/06).
- *Cashback editável por regra* (17/06).

**↳ Nenhuma coluna de saldo em `cliente`** (fundação F-C5). No legado, pontos e cashback eram um número
por cliente: nada diz de onde vieram os 2.100 pontos daquele cliente, e estornar a venda que os gerou
não tem como devolvê-los. **Cashback é dinheiro** — obrigação em reais — e entra no ledger com natureza
própria, não numa contagem à parte.

**↳** Regra de pontuação (quantos pontos por real, o que pontua, expiração) é parâmetro **com
vigência**: mudar a regra não pode reprecificar pontos já concedidos.

---

## Transversal · Governança

Não é fase, é como se trabalha. O legado desenvolveu isso sozinho e vale herdar — mas na forma barata,
que é máquina, não disciplina.

**Desde a fundação:**
- A lei escrita (`CLAUDE.md`) e o `CHANGELOG.md` em linguagem de dono, no primeiro commit (F-F6).
- Os três portões no CI, com números (F-F5).
- Controle negativo: teste só é prova depois de demonstrado que falharia se o defeito existisse.

**A partir da fase 1:**
- *Toda entrega declara por escrito o que ela **não** faz e as limitações aceitas*, cada uma com
  destino (backlog, próximo ciclo, decisão do dono).
- *Diagnóstico e implementação são entregas separadas*: auditoria/plano primeiro, numerado, sem tocar
  no sistema; aprovação item a item antes do código.
- *Diante de técnica não prescrita ou acoplamento não previsto, para sem tocar em arquivo, devolve
  opções analisadas e só implementa depois da decisão* — regra criada no legado **depois** de um bug
  crítico (ciclo 09) e que evitou o seguinte (ciclo 10).
- *Nenhum ciclo fecha sem parecer de revisor independente que refaz a verificação por conta própria e
  tem poder de REPROVAR.* No legado isso interceptou 2 bugs críticos antes do commit e reprovou os
  ciclos 02, 09 e 15.

**A partir da fase 2 (ou de ~40 arquivos):**
- *Cada domínio tem sua suíte nomeada; a rede de testes é construída ANTES de reorganizar o que ela
  protege.*
- *Documentação viva atualizada no mesmo commit* — moveu arquivo, atualiza o mapa.
- *Mover código é diff vazio*: reorganização e mudança de comportamento nunca no mesmo ciclo.
- *Defeito pré-existente descoberto no meio de uma mudança é preservado, anotado e vira ciclo próprio*
  — nunca correção de carona.
