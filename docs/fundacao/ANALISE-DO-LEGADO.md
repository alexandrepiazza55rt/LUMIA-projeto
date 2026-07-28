# O que aproveitar do sistema legado — análise para a Fase de Fundação

> Fonte: `CHANGELOG.md` do sistema anterior (Beauty 360 → Sistema Elaine → LUMIA), 170 entradas
> entre 10/06 e 23/07. Este documento é **julgamento**, não extração: diz o que faz sentido trazer,
> o que não faz, e por quê.

---

## 1. O que esse changelog realmente é

Não é uma lista de funcionalidades. É o registro honesto de um sistema que funcionou **e da conta que
ele pagou** por decisões de base tomadas tarde. Os números estão no próprio changelog:

| Fato registrado | Onde |
|---|---|
| 33.596 linhas, arquivo central de estado com 5.653 linhas | 20/07, diagnóstico |
| **17 ciclos** de reorganização só para tornar o código migrável | 21/07, encerramento do Bloco 4 |
| **7 ciclos** (18–24) para tirar os dados do navegador e pôr no banco | 22/07 |
| ~30 pareceres de auditoria independente, 2 bugs críticos interceptados antes do commit | 21/07 |
| 1 bug real de perda de dados: o autosave não observava **10 listas** (inclusive a numeração de comandas) | 21/07, ciclo 17 |
| 7 "padrões de fiação" inventados só para conseguir sincronizar o que já existia | 22/07, resumo da migração |

Quase tudo isso é **trabalho que não entregou nada ao dono**. Foi o preço de ter construído dois meses
de regra de negócio — agenda, comanda, comissão, caixa, estoque, fidelidade — em cima de um blob no
`localStorage`, com o banco cuidando só do login.

O valor do changelog para nós está em três camadas, nessa ordem de importância:

1. **As cicatrizes.** Cada bug que o changelog confessa é uma *classe* de erro. Uma fundação boa não
   corrige o caso: torna a classe inteira **inexprimível**.
2. **As decisões do dono.** Dezenas delas estão registradas com "decisão do dono", "combinado",
   "não reabrir". São requisitos com custo de descoberta já pago. Algumas são contraintuitivas
   (ver §5) e uma fundação bem-intencionada as quebra sozinha.
3. **As regras de negócio.** Importantes, mas é a camada mais barata de reconstruir — e a maioria
   **não** pertence à fundação.

---

## 2. O filtro que usei

O erro mais provável aqui é o oposto do erro do legado: fazer uma fundação tão grande que ela nunca
termina. Na primeira passada, 105 das 150 regras levantadas foram marcadas como "fundação" — 70%.
Uma fase 0 com 105 itens não é uma fundação, é o sistema inteiro com as telas removidas.

O critério que separa é **uma pergunta só**:

> Quando eu implementar isso na fase 3, **o que já vai estar gravado no banco** que eu vou ter que
> reescrever, migrar ou adivinhar?
>
> Se a resposta é "nada, é só acrescentar" → **não é fundação.**

Isso produz três níveis, e a maior parte da confusão vem de tratar os dois primeiros como um só:

| Nível | Significa | Custo hoje | Custo se descoberto tarde |
|---|---|---|---|
| **FUNDAÇÃO** | Construído no commit 1: DDL, GRANT, política, tipo, teste | dias | reescrita de histórico já gravado |
| **RESTRIÇÃO VINCULANTE** | **Decidido** agora e escrito na lei; **construído** junto com o módulo | uma linha | a tabela nasce errada e o módulo inteiro se acomoda em cima dela |
| **FASE** | Trabalho normal, na vez dele | — | — |

Uma cicatriz grave **num módulo que ainda não existe** é uma *lição*, não um retrofit. "Encaixe exige
autorização registrada" é uma regra excelente — e criar a coluna na fase da agenda não reescreve
linha nenhuma, porque não há nenhuma reserva gravada. Vai para RESTRIÇÃO VINCULANTE, não para a fase 0.

Aplicado o filtro: **34 invariantes de fundação** (em [`INVARIANTES.md`](./INVARIANTES.md)),
~40 restrições vinculantes distribuídas pelas fases (em [`MAPA-DE-FASES.md`](./MAPA-DE-FASES.md)),
e o resto abaixo.

---

## 3. O que a fundação precisa ter que o legado nunca teve

Nove garantias não aparecem em nenhuma linha do changelog — não porque não importam, mas porque o
protótipo nunca chegou a sofrer com elas. Todas são do tipo que não se retrofita:

1. **Fuso horário e dia operacional.** O changelog fala de "caixa do dia", "faturamento de hoje",
   "meta dividida por 26 dias úteis", "reset diário da numeração" — e nunca define o que é um dia.
   Salão que fecha às 21h com comanda aberta precisa de `data_operacional` como coluna derivada no
   servidor, não de `date(created_at)` no fuso do navegador.
2. **Relógio autoritativo.** No protótipo a hora vinha da máquina que gravava. Com três computadores
   no salão, um relógio adiantado joga um recebimento para o caixa de amanhã e um atrasado joga para
   um dia já fechado — e a linha não guarda de onde veio a hora, então é indetectável depois.
3. **Saldo derivado, nunca coluna mutável.** Fidelidade é o ponto cego total do legado: pontos e
   cashback eram *um número por cliente*. Nada diz de onde vieram os 2.100 pontos daquele cliente, e
   estornar a venda que os gerou não tem como devolvê-los. Cashback é pior — é obrigação em reais.
4. **Numeração humana de documento.** O legado tratou o nº da comanda como checagem de tela sobre uma
   sequência que vivia no navegador — e foi exatamente uma das 10 listas que o autosave não observava.
   Dois documentos com o mesmo número é um dano que nenhuma correção posterior desfaz.
5. **Dado pessoal separado do fato financeiro.** Há uma colisão frontal entre a espinha da fundação
   ("nada de dinheiro se apaga") e o direito de exclusão do titular. Se nome e CPF forem congelados
   dentro de snapshots e documentos, ou a LGPD é descumprida ou o livro-razão é violado.
6. **`FORCE ROW LEVEL SECURITY` e papel de aplicação sem posse das tabelas.** Em Postgres o **dono da
   tabela ignora as policies por padrão**. Se a aplicação rodar com o papel proprietário, todo o
   isolamento por empresa e todo o append-only são decorativos — e o teste que "prova" o isolamento
   passa mesmo assim.
7. **Separação de ambientes.** O legado semeou 48 comandas e 70 lançamentos financeiros de exemplo no
   banco real (22/07). Com append-only, esse dinheiro fictício **não sai mais**.
8. **Ponto de retorno (PITR) e restauração provada** antes do primeiro dado real. Append-only não
   protege dos dois caminhos destrutivos que continuam existindo: migração ruim e erro de operação no
   painel do provedor.
9. **Ator-sistema explícito.** Migração, seed, rotina e trigger escrevem sem sessão. Se o autor da
   trilha for `NULL` ou um "usuário padrão", a auditoria mente na primeira linha.

---

## 4. O que **não** se traz do legado

Onze regras do legado são artefato de protótipo ou antipadrão. O que interessa não é descartá-las —
é o **guarda-corpo** que impede cada uma de voltar.

| O que o legado fez | O que custou | Guarda-corpo na fundação |
|---|---|---|
| Dois meses de regra de negócio sobre blob no `localStorage` | 17 ciclos de reorganização + 7 de migração + 7 padrões de fiação inventados | A primeira funcionalidade já é escrita contra o banco real. Sem store de negócio no cliente, nem "temporariamente" — garantido por o cliente **não ter GRANT de escrita**, não por disciplina |
| "Modo demonstração" como segundo caminho de execução e gravação | Toda entrega provada duas vezes ("no modo demonstração nada muda" em quase toda entrada de 22/07); a porta ficou **exposta em produção** até 07/07 | Um caminho só. Ambiente é ambiente (projeto separado), não modo de login. Nenhum `if (demo)` em caminho de escrita |
| Subir o estado local para o banco quando ele estava vazio | 48 comandas e 70 lançamentos fictícios no livro-razão real | Seed **nunca contém dinheiro** (só catálogo), carrega `origem='seed'`, é idempotente e bloqueado em produção |
| Números de negócio escritos no código | Matriz de comissão invisível ao dono governou pagamento até 23/07; o fallback de 40% causou a "comissão fantasma" em 11/06 — e **voltou** em 23/07 como "rede de segurança" | Literal numérico de negócio proibido dentro do motor de dinheiro, verificado por lint. Parâmetro ausente = **falha alta**, nunca número escondido |
| Catálogo local de permissões como fallback offline (23/07) | Nasceu uma segunda fonte de verdade para **autorização**, no último dia, depois de toda a migração | O cliente nunca embarca catálogo de funções nem políticas. Sem banco, a tela de administração não abre — falha visível, não degradação silenciosa |
| Descobrir configuração de ambiente só em produção | 15/06 "testado ponta a ponta"; 17/06 erro 500 em produção (variáveis faltando + import sem `.js`, que só quebra no runtime do servidor) | Validação de configuração no boot que **aborta nomeando a variável faltante**; paridade de runtime dev/prod; smoke test pós-deploy como portão |
| HTML montado por concatenação nas telas de impressão | Injeção de código pelo texto do "Documento para assinar", publicada por ~3 semanas até a auditoria C2 | Lint proíbe `innerHTML`/`dangerouslySetInnerHTML`/marcação montada à mão. Texto do dono é **dado**, nunca template |
| Backup por arquivo como plano de continuidade | O JSON continha a base inteira de clientes; qualquer um com acesso a Configurações baixava; sem registro de quem exportou | Continuidade é do banco (PITR, com restauração testada). Exportar dado pessoal é operação privilegiada com registro append-only |
| Criar caminho de escrita novo fora do banco **depois** da migração concluída | 23/07, na entrada seguinte a "MIGRAÇÃO CONCLUÍDA": o cadastro de profissional sem login "continua funcionando 100% no navegador" — a assistente que recebe comissão só existia numa máquina | Consequência do cliente não ter GRANT de escrita + teste de arquitetura que reprova qualquer escrita fora de RPC |

---

## 5. Decisões do dono que a fundação **não** pode quebrar sozinha

Estas são contraintuitivas e uma modelagem "higiênica" as violaria por reflexo. Estão no changelog
como decisão explícita e devem entrar na lei do repositório:

- **CPF, CNPJ e telefone não são chave única.** Duplicidade **avisa**, nunca bloqueia (23/06). Mãe e
  filha com o mesmo telefone, cliente sem documento, CPF do responsável. `UNIQUE(cpf)` parece higiene
  e é a coisa errada: trava a recepção no balcão com o cliente na frente.
- **Crédito de cliente não é forma de pagamento** — é saldo abatível, como o fiado (07/07). Modelar
  como forma de pagamento confunde com cartão de crédito e polui a conciliação.
- **Comissão do assistente sai da fatia do principal**, nunca do salão (17/06, 02/07). Adicionar
  assistente jamais aumenta o custo total de comissão.
- **Gorjeta não é receita** (exceto a "para a casa") e **nunca gera comissão** (07/07). Em dinheiro
  entra na gaveta sem ser receita; em cartão/Pix não entra nem na gaveta nem na receita.
- **Regime de caixa:** conta a pagar entra na DRE no mês em que foi **paga**, não no vencimento (07/07).
- **Comanda fechada não reabre.** A única reversão é o estorno auditável (07/07).
- **Editar cadastro não reescreve o passado** (23/06). Valor, comissão e documentos já emitidos não mudam.
- **A comanda cobra o preço acordado na agenda**, não o preço vigente do catálogo (11/06).
- **Contagem cega no fechamento de caixa** (22/07): o operador digita o contado sem ver o esperado.
  Não é detalhe de tela — é o que impede a "contagem ajustada para bater".

---

## 6. Contradições a resolver **antes do primeiro DDL**

Cinco pontos em que as regras do legado, lidas juntas, se contradizem. Nenhum se resolve depois sem
migração:

1. **Append-only: só INSERT ou INSERT+UPDATE?** O legado diz as duas coisas. Resolução proposta:
   política **por classe de tabela** — fato financeiro e auditoria sem GRANT de `UPDATE` nem `DELETE`
   (correção só por linha nova); cadastro com `UPDATE` permitido e trilha de/para obrigatória.
2. **Álgebra da permissão.** "Permissão é conjunto de funções marcáveis" (união de concessões) versus
   "quem é Profissional só mexe na própria agenda mesmo tendo Agenda Geral" (restrição que
   *prevalece*). União pura não expressa isso. Precisa de **dois eixos** — função × escopo — com
   precedência do escopo mais restritivo, decidido antes da primeira policy.
3. **Resíduo de centavos.** O legado manda o resíduo da junção de comandas para a **última** comanda e
   o da gorjeta para o **primeiro** profissional. Então a primitiva de rateio não pode ter política
   fixa: recebe **política e ordenação como parâmetros obrigatórios**, sem default.
4. **Cache offline versus fonte da verdade.** "Banco é a fonte, navegador é cache para leitura/offline"
   convive mal com "cache nunca é autoridade". Regra única: o cache é **só apresentação**, carimbado
   com o instante da leitura, nunca entra numa decisão de escrita, e **nenhuma operação de dinheiro
   lê dele**.
5. **Ambiente de prova.** "Prova executada em ambiente real" + "o teste desfaz seus próprios rastros"
   + append-only sem `DELETE` é impossível por construção. Resolução: banco **efêmero** de CI,
   destruído ao fim. Limpeza por destruição do ambiente, nunca por `DELETE`.

---

## 7. O que o changelog não responde — perguntas para o dono

Nenhuma bloqueia o começo da fundação, mas as três primeiras mudam DDL e é melhor decidi-las antes:

1. **Qual o fuso e onde vira o dia operacional?** (o salão fecha às 21h — comanda aberta às 23h é de
   qual dia?)
2. **Retenção de dado pessoal:** por quanto tempo depois do último atendimento, e o que exatamente
   pode ser anonimizado sem quebrar a defesa financeira do salão?
3. **Numeração de documento:** reinicia por dia/mês/ano/nunca, e o prefixo é por empresa ou por
   operador? (o legado tinha as quatro opções — precisamos saber se todas continuam valendo)
4. Multi-tenant oculto continua sendo a decisão? (o legado cancelou o SaaS multiempresa mas manteve a
   coluna de empresa em tudo — a fundação assume que **sim**, e isso está certo)
5. A migração de dados do sistema legado para o LUMIA novo faz parte do escopo, ou o novo começa vazio?

---

## Onde continuar

- [`INVARIANTES.md`](./INVARIANTES.md) — os 34 invariantes da fundação, cada um com a cicatriz que o
  originou, como implementar e o teste que o prova.
- [`MAPA-DE-FASES.md`](./MAPA-DE-FASES.md) — o que **não** entra na fundação, em que fase entra, e a
  restrição de desenho que cada fase carrega desde já.
