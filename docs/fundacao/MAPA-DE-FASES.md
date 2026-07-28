# Regras do legado, ancoradas nas fases canônicas

> **Este documento não define fases.** As fases do LUMIA são as **F1–F10** de
> [`architecture.json`](../../architecture.json) (`fases_de_construcao`), renderizadas na aba
> *Fases de construção* do [dossiê](../../dossie.html). Aqui está apenas o **inventário de regras de
> negócio extraídas do sistema legado**, cada uma pendurada na fase canônica onde entra e na
> restrição de desenho que já fica travada desde agora.
>
> Onde a regra já virou achado, decisão ou tabela, o texto diz onde — para não existir uma terceira
> fonte de verdade. A versão canônica de tudo que veio desta análise é a **lente 7** em
> [`gaps.json`](../../gaps.json) (`lente_legado`).

Legenda: **↳** = restrição de desenho vinculante · **✓** = já resolvido no schema atual ·
**◆** = virou achado ou decisão em `gaps.json`.

---

## F1 · Fundação técnica e tenancy

- ✓ *Toda tabela nasce com coluna de empresa e isolamento no banco*, mesmo operando com um salão só —
  o legado adotou isso em 22/07 e acertou, mas deixou a tabela de perfis e permissões de fora "por ser
  inofensivo com um salão só". `RLS habilitada e forçada` já é asserção de teste no schema atual.
- ◆ *O cliente não tem GRANT de escrita: toda gravação é EXECUTE de função de servidor* —
  **decisão irreversível 19**. É o que torna inexprimível a segunda implementação de uma regra de
  dinheiro, em vez de proibida por disciplina.
- ◆ *Catálogo de autorização nunca embarcado no cliente*, nem como reserva offline —
  achado `catalogo-de-autorizacao-nunca-embarcado-no-cliente`.
- ◆ *Configuração validada no arranque, abortando com o nome do que falta; paridade de runtime* —
  achado `validacao-de-configuracao-no-boot-e-paridade-de-runtime`.
- ◆ *Semente sem dinheiro; nenhuma rotina promove dado local a real* —
  achado `semente-e-demonstracao-nunca-contem-dinheiro`.
- *Identidade de acesso e ficha de negócio são entidades separadas, com vínculo opcional*: existe
  profissional sem login e login sem ficha. Regra de FK: negócio aponta para a ficha, ato do sistema
  aponta para o usuário. Já coberto pela decisão 10 (três sujeitos de identidade); a evidência do
  legado é que criar quem tinha a função Profissional na tabela de LOGIN fez a pessoa ganhar acesso e
  **não existir** para a agenda, o PDV e a comissão (23/07).
- *O último administrador não pode ser removido, revogado nem desativado.* Não é fundação — é um
  trigger aditivo de ~20 linhas — mas entra junto com a tela de gestão, não depois dela.
- *Ninguém altera as próprias funções nem o próprio status*, verificado no banco.
- *Senha provisória com mínimo de 8 caracteres; no primeiro acesso o usuário cria a própria senha
  antes de abrir qualquer tela.*
- *A lista de ações e os destinatários possíveis são calculados no servidor.* Cicatriz: no legado,
  **quem enviava** uma transferência via os botões de aceitar e recusar (22/07) — a autorização morava
  no componente que desenhava o botão.

---

## F2 · Catálogo

- *Editar cadastro nunca reescreve o passado*: comandas e recibos já feitos mantêm os valores de
  então; a tela viva mostra o dado atual.
- *Grupo → subgrupo → serviço, e produto classificado por natureza* (revenda × uso interno) — a perda
  só existe para uso interno, nunca para revenda.
- *Serviço com preço gratuito ocupa a agenda e não fatura* (cortesia e retrabalho).
- *Duração por profissional além da duração padrão do serviço*, resolvida em cascata.
- ↳ **Todo número que o dono poderia querer mudar é linha de parâmetro com vigência, autor e trilha
  de/para.** Parâmetro ausente é falha alta, nunca um valor padrão silencioso. Já é a decisão 5
  (vigência em preço, comissão, custo e alíquota); o legado acrescenta a evidência: uma matriz de
  comissão escrita no código governou o pagamento dos profissionais até ser eliminada por invisível ao
  dono, e o percentual de segurança escondido causou comissão indevida em venda de balcão.
- ↳ Serviço externo (ViaCEP e o que vier) é auxiliar de preenchimento: nunca participa do caminho de
  gravação, escreve em colunas próprias, falha visível, preenchimento manual sempre disponível.

---

## F3 · Entidades e privacidade

- ◆ *Documento e contato validados e normalizados, com índice **não** único; duplicidade avisa e nunca
  bloqueia* — achado `chave-de-negocio-duplicada-avisa-nunca-bloqueia`. Decisão explícita do dono
  (23/06), contraintuitiva o bastante para uma modelagem instintiva quebrá-la sozinha.
- ◆ *Documento emitido ou assinado é conteúdo renderizado imutável* — **decisão irreversível 20**.
  Estende ao termo de parceria, ao comprovante de caixa e ao recibo o mecanismo que o motor de
  consentimento já prevê para o termo LGPD.
- *Toda edição de cadastro gera trilha de/para por campo.*
- *Profissional promovido e despromovido sem recadastrar*: despromover desativa a ficha, repromover
  reativa a mesma ficha preservando o histórico.
- ↳ Dado pessoal isolado do fato financeiro: o ledger guarda `cliente_id`, nunca CPF e telefone
  congelados dentro de payload. Já é a decisão 6 (duas classes de dado); o ponto que o legado
  acrescenta é que **nenhum snapshot congela pessoa** — senão o esquecimento colide com o livro
  imutável.

---

## F4 · Operação (agenda, conversas, estoque)

**Agenda** — quase tudo aqui já está implementado; a lista serve de conferência.

- ✓ *Ocupação de recurso é conceito próprio, acima de agenda e de locação*: `reserva` com `EXCLUDE`,
  provado por teste de concorrência com 30 sessões. Cicatriz do legado: existiam duas verificações que
  não se enxergavam e dava para reservar a mesma sala duas vezes (23/06).
- ✓ *A garantia contra sobreposição mora no armazenamento*, não numa função que todo caminho de
  gravação precisa lembrar de chamar.
- ✓ *Fuso por estabelecimento, não por servidor.*
- *Qualquer mudança de horário, duração, sala ou profissional revalida a ocupação no destino antes de
  gravar*; cancelar, faltar e remarcar liberam na hora. No legado, remarcar nem revalidava a sala.
- *Remarcar nunca move o registro*: o antigo fica no lugar marcado como Remarcado, sem ocupar e fora
  das contas, e um novo aponta para ele, formando cadeia A→B→C.
- *Duração fica gravada no agendamento*; ajustar ali nunca altera o cadastro.
- *Encaixe sobre horário ocupado exige autorização explícita*, com quem autorizou e quando.
- *Bloqueio não grava por cima de cliente*: lista cada conflito e só libera quando todos forem
  resolvidos.
- *Check-in só na data do próprio agendamento.*
- *Sala tem capacidade declarada* — conflito é por lotação, não pela existência de outra reserva.
- *Buffers opcionais de preparo e limpeza entram no cálculo do conflito.*
- *Cada transição de estado é evento datado, não sobrescrita de campo.*
- *Recorrência materializa ocorrências individuais*; cancelar pergunta "só esta" ou "esta e as
  próximas".

**Estoque**

- *Livro de movimentação append-only com motivo; custo médio ponderado recalculado a cada compra;
  compra do fornecedor gera a conta a pagar; custo do insumo = custo médio ÷ embalagem, descontada a
  perda; fechar comanda baixa produtos e insumos pela ficha técnica, e estornar devolve.*
- ↳ A baixa de estoque é um **efeito tipado com inverso declarado** (achado
  `efeito-tipado-com-inverso-declarado`) — é exatamente o caminho em que a auditoria do legado
  encontrou um arredondamento extra mudando R$ 0,01 em embalagens fracionadas.

---

## F5 · Balcão e dinheiro

A fase mais sensível, e onde a lente do legado concentra o que tem de mais concreto.

**Já resolvido no schema atual**

- ✓ Contagem cega imposta pelo banco (`conferencia_caixa`: declarado às cegas, esperado escrito pelo
  sistema, recontagens).
- ✓ Item nunca é texto livre; preço de tabela e preço praticado congelados no item.
- ✓ Desconto exige motivo tipado e autorizador.
- ✓ Custódia com `EXCLUDE` contra dois responsáveis e trigger contra buraco na cadeia.
- ✓ Pagamento com chave de idempotência única por tenant.
- ✓ **Custódia não move comissão** — decisão 18, provada em `db/tests/test_balcao.sql` com controle
  negativo executado.

**A decidir antes do primeiro DDL do ledger** (a tabela `lancamento` ainda não existe)

- ◆ **Natureza em eixos independentes** (`afeta_receita`, `afeta_gaveta`, `gera_comissao`) e estorno
  que herda a natureza da origem — **decisão irreversível 17**. Um único enum receita/despesa não
  expressa gorjeta em dinheiro (gaveta sim, receita não) nem gorjeta em cartão (nenhuma das duas).
- ◆ **Origem polimórfica**: `tipo_origem` + `id_origem`, nunca `comanda_id` no ledger — locação,
  compra e conta a pagar também produzem lançamento.
- ◆ **Efeito tipado com inverso declarado**; o estorno enumera os efeitos gravados em vez de repetir
  uma lista escrita à mão.
- ◆ **Ponto único de arredondamento** declarado no motor.
- ◆ **Política de resíduo de centavos como parâmetro obrigatório do rateio** — no legado, a mesma
  "primitiva única" mandava o resíduo da junção para a última comanda e o da gorjeta para o primeiro
  profissional.
- ◆ **Período fechado como trava genérica**, servindo caixa, comissão e competência fiscal com um
  mecanismo só.
- ↳ **Leitura viva × congelada declarada**: consulta que produz dinheiro não faz JOIN com catálogo.
  Teste: fechar uma comanda, alterar preço, nome e percentual, e provar byte a byte que nada mudou.

**Regras de negócio que o motor precisa respeitar**

- *Comissão do assistente sai da fatia do principal*, com piso zero — adicionar assistente nunca
  aumenta o custo total do estabelecimento.
- *Item sem profissional atribuído gera zero comissão* (a "comissão fantasma de 40%" em venda de
  balcão, 11/06).
- *Comanda fechada não reabre*: a única reversão é estorno com categoria e motivo; administrador
  estorna na hora, auditado, os demais geram pedido para fila de aprovação.
- *Pagamento parcial fecha a comanda e gera devedor*; comanda com saldo em aberto exige cliente.
- *Crédito de cliente é passivo abatível, não forma de pagamento* (já é a decisão 7).
- *Gorjeta nunca gera comissão*, é rateada igualmente entre os participantes e cancelada junto no
  estorno.
- *Junção de comandas*: cada uma fecha individualmente, com snapshots preservados; a sobra fica com o
  **pagador do grupo**, não com o cliente da comanda.
- *O fechamento do dia consolida as sessões, não as substitui*, e trava com sessão aberta, comanda
  aberta ou atendimento sem comanda — cancelado, faltou e remarcado não travam.
- *Comanda aberta não é dinheiro*: aparece como aviso, não entra no caixa nem na previsão.
- *Regime de caixa*: conta a pagar entra no resultado no mês em que foi paga.
- *Previsto e realizado nunca se misturam*; a previsão não conta comanda em aberto.
- *Item com identidade própria e vínculo alterável entre comandas abertas*, imutável após o
  fechamento — mover item é UPDATE auditado, nunca apagar aqui e recriar lá.

---

## F6 a F10

O legado não chegou nessas camadas: não teve vitrine pública, marketing, camada analítica, método nem
IA. A única contribuição da lente aqui é negativa e vale registrar: **nada do que essas fases
construírem pode criar um segundo caminho de escrita.** Foi assim que o legado se perdeu — em 23/07,
na entrada seguinte à que declarou a migração concluída, nasceu um cadastro que gravava só no
navegador.

---

## Transversal · Como se trabalha

Herdado do legado na forma barata, que é máquina e não disciplina:

- **Desde já:** os três portões com números (tipos, build, suítes N/N); controle negativo obrigatório —
  teste só é prova depois de demonstrado que falharia se o defeito existisse; toda entrega vira linha
  de changelog em linguagem de dono, incluindo reprovações e bugs interceptados, e entrada publicada
  nunca é reescrita.
- **A partir da primeira entrega de funcionalidade:** toda entrega declara por escrito o que **não**
  faz e as limitações aceitas, cada uma com destino; diagnóstico e implementação são entregas
  separadas, com aprovação item a item antes do código.
- **Regra que o legado criou depois de um incidente e que evitou o seguinte:** diante de técnica não
  prescrita ou de acoplamento não previsto, para sem tocar em arquivo, devolve opções analisadas e só
  implementa depois da decisão.
- **Revisor independente com poder de reprovar**, que refaz a verificação por conta própria. No
  legado, interceptou dois bugs críticos antes do commit e reprovou três ciclos.
- **Documentação viva atualizada no mesmo commit** — moveu arquivo, atualiza o mapa.
- **Mover código é diff vazio**: reorganização e mudança de comportamento nunca no mesmo ciclo.
