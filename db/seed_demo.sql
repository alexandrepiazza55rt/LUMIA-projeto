-- =============================================================================
-- LUMIA · Seed de demonstração
-- =============================================================================
-- Um caso real e pequeno, suficiente para exercitar as regras difíceis:
--   • Rede "Studio Aurora" com 2 estabelecimentos em fusos DIFERENTES
--     (São Paulo e Manaus) — prova que fuso é por estabelecimento.
--   • Coloração com pausa química — prova o modelo de tempo por etapa.
--   • Variantes curto/médio/longo com fator de consumo.
--   • Ficha técnica com conversão litro → mililitro.
--   • Custo do produto com DUAS versões de vigência (antes e depois do reajuste)
--     — prova que a margem histórica não muda.
--   • Tabela geral + tabela de convênio com prioridade.
-- =============================================================================

BEGIN;

SET LOCAL lumia.tenant_id = '00000000-0000-7000-8000-00000000a001';

-- ---------------------------------------------------------------- plataforma --
INSERT INTO lumia.celula (id, codigo) VALUES
  ('00000000-0000-7000-8000-0000000000c1', 'br-sudeste-1');

INSERT INTO lumia.tenant (id, celula_id, slug, nome_exibicao, status, finalidade) VALUES
  ('00000000-0000-7000-8000-00000000a001',
   '00000000-0000-7000-8000-0000000000c1',
   'studio-aurora', 'Studio Aurora', 'ATIVO', 'DEMONSTRACAO');

-- ------------------------------------------------------------------ hierarquia --
-- GRUPO > PESSOA_JURIDICA > ESTABELECIMENTO > UNIDADE
INSERT INTO lumia.no_org (tenant_id, id, tipo, pai_id, nome, codigo, caminho, profundidade) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b001','GRUPO',NULL,'Grupo Aurora','grupo-aurora','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b002','PESSOA_JURIDICA','00000000-0000-7000-8000-00000000b001','Aurora Beleza Ltda','aurora-ltda','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b003','ESTABELECIMENTO','00000000-0000-7000-8000-00000000b002','Aurora Pinheiros','aurora-pinheiros','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b004','ESTABELECIMENTO','00000000-0000-7000-8000-00000000b002','Aurora Manaus','aurora-manaus','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b005','UNIDADE','00000000-0000-7000-8000-00000000b003','Sala Colorimetria','sala-color','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b006','UNIDADE','00000000-0000-7000-8000-00000000b005','Cadeira 1','cadeira-1','x',0),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b007','UNIDADE','00000000-0000-7000-8000-00000000b003','Cabine Laser','cabine-laser','x',0);
-- (caminho e profundidade são sobrescritos pelo trigger; 'x' é apenas placeholder
--  para satisfazer o NOT NULL antes do BEFORE INSERT)

INSERT INTO lumia.pessoa_juridica (tenant_id, no_org_id, cnpj, razao_social, nome_fantasia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b002',
   '11222333000181','Aurora Beleza Ltda','Studio Aurora');

INSERT INTO lumia.estabelecimento
  (tenant_id, no_org_id, pessoa_juridica_id, numero, codigo_municipio_ibge, uf, fuso, matriz, inscricao_municipal) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b003','00000000-0000-7000-8000-00000000b002',
   1,'3550308','SP','America/Sao_Paulo',true,'1234567'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b004','00000000-0000-7000-8000-00000000b002',
   2,'1302603','AM','America/Manaus',false,'7654321');

INSERT INTO lumia.unidade_operacional (tenant_id, no_org_id, estabelecimento_id, tipo, capacidade) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b005','00000000-0000-7000-8000-00000000b003','SALA',2),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b006','00000000-0000-7000-8000-00000000b003','CADEIRA',1),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000b007','00000000-0000-7000-8000-00000000b003','CABINE',1);

-- --------------------------------------------------------------------- catálogo --
INSERT INTO lumia.categoria_catalogo (tenant_id, id, pai_id, nome, caminho, aplica_servico, aplica_produto) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000d001',NULL,'Cabelo','x',true,false),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000d002','00000000-0000-7000-8000-00000000d001','Coloração','x',true,false),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000d003',NULL,'Revenda','x',false,true);

-- Coloração: 40 min ativos, 30 min de pausa química, 20 min de finalização.
-- Durante a pausa o profissional atende outra pessoa; a cadeira segue ocupada.
INSERT INTO lumia.servico
  (tenant_id, id, categoria_id, numero, nome,
   duracao_ativa_min, duracao_processamento_min, duracao_finalizacao_min, duracao_higienizacao_min,
   libera_profissional_no_processamento, libera_recurso_no_processamento,
   publicavel_online, exige_anamnese) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e001',
   '00000000-0000-7000-8000-00000000d002', 1, 'Coloração raiz',
   40, 30, 20, 10, true, false, true, false),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e002',
   '00000000-0000-7000-8000-00000000d002', 2, 'Depilação a laser axila',
   20, 0, 0, 10, false, false, true, true);

INSERT INTO lumia.servico_variante (tenant_id, id, servico_id, nome, delta_duracao_ativa_min, fator_consumo, padrao) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e101','00000000-0000-7000-8000-00000000e001','Curto',  0, 1.000, true),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e102','00000000-0000-7000-8000-00000000e001','Médio', 10, 1.400, false),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e103','00000000-0000-7000-8000-00000000e001','Longo', 20, 1.800, false);

INSERT INTO lumia.servico_recurso_exigido (tenant_id, id, servico_id, tipo_unidade, etapa_ocupacao) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e201','00000000-0000-7000-8000-00000000e001','CADEIRA','TODA'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e202','00000000-0000-7000-8000-00000000e002','CABINE','TODA');

INSERT INTO lumia.habilidade (tenant_id, id, nome) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e301','Colorimetria'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e302','Laser');

INSERT INTO lumia.servico_habilidade_exigida (tenant_id, id, servico_id, habilidade_id, nivel_minimo) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e401','00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e301',3),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000e402','00000000-0000-7000-8000-00000000e002','00000000-0000-7000-8000-00000000e302',4);

-- --------------------------------------------------------------------- produtos --
-- Tinta comprada em frasco de 1 L, consumida em ml (fator 1000).
INSERT INTO lumia.produto
  (tenant_id, id, categoria_id, numero, natureza, sku, nome, marca,
   unidade_compra_codigo, unidade_consumo_codigo, fator_conversao, controla_lote, controla_validade) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f001',
   NULL, 1, 'INSUMO', 'TINT-7-0', 'Coloração 7.0 Louro Médio', 'Aurora Pro',
   'l','ml',1000, true, true),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f002',
   NULL, 2, 'INSUMO', 'OX-20V', 'Oxidante 20 volumes', 'Aurora Pro',
   'l','ml',1000, true, true),
  -- Cosmético de revenda: lote E validade. Rastrear validade sem lote é
  -- impossível na prática (é o lote que distingue os frascos em estoque) — a
  -- constraint produto_validade_exige_lote impede a combinação incoerente.
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f003',
   '00000000-0000-7000-8000-00000000d003', 3, 'REVENDA', 'SHP-500', 'Shampoo pós-coloração 500ml', 'Aurora Pro',
   'un','un',1, true, true);

-- Custo com DUAS vigências: R$ 80/L até 30/jun, R$ 100/L a partir de 01/jul.
-- É este par de linhas que prova a decisão nº 5.
INSERT INTO lumia.produto_custo_versao
  (tenant_id, id, produto_id, custo_unitario_compra, vigencia, motivo) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f101','00000000-0000-7000-8000-00000000f001',
   80.0000, daterange('2026-01-01','2026-07-01','[)'), 'Custo inicial'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f102','00000000-0000-7000-8000-00000000f001',
   100.0000, daterange('2026-07-01', NULL, '[)'), 'Reajuste do fornecedor'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f103','00000000-0000-7000-8000-00000000f002',
   40.0000, daterange('2026-01-01', NULL, '[)'), 'Custo inicial');

-- --------------------------------------------------------------- ficha técnica --
-- Coloração raiz: 60 ml de tinta + 90 ml de oxidante (dose base, variante curto)
INSERT INTO lumia.ficha_tecnica (tenant_id, id, servico_id, variante_id, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f201',
   '00000000-0000-7000-8000-00000000e001', NULL, daterange('2026-01-01', NULL, '[)'));

INSERT INTO lumia.ficha_tecnica_item (tenant_id, id, ficha_tecnica_id, produto_id, quantidade, unidade_codigo) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f301','00000000-0000-7000-8000-00000000f201','00000000-0000-7000-8000-00000000f001',60,'ml'),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f302','00000000-0000-7000-8000-00000000f201','00000000-0000-7000-8000-00000000f002',90,'ml');

-- Custo por disparo do laser
INSERT INTO lumia.custo_uso_recurso (tenant_id, id, unidade_id, base_medida, custo_por_unidade, vida_util_total, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000f401','00000000-0000-7000-8000-00000000b007',
   'DISPARO', 0.1200, 1000000, daterange('2026-01-01', NULL, '[)'));

-- ----------------------------------------------------------------- preços --
INSERT INTO lumia.tabela_preco (tenant_id, id, nome, estabelecimento_id, canal, prioridade, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009001','Tabela geral 2026', NULL, 'TODOS', 0, daterange('2026-01-01', NULL,'[)')),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009002','Convênio Empresa X', NULL, 'TODOS', 10, daterange('2026-01-01', NULL,'[)'));

INSERT INTO lumia.tabela_preco_item
  (tenant_id, id, tabela_preco_id, servico_id, variante_id, nivel_profissional, preco, base_comissao, vigencia) VALUES
  -- geral, variante curto
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009101','00000000-0000-7000-8000-000000009001',
   '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e101',NULL,180.0000,'LIQUIDO_INSUMO',daterange('2026-01-01',NULL,'[)')),
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009102','00000000-0000-7000-8000-000000009001',
   '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e103',NULL,260.0000,'LIQUIDO_INSUMO',daterange('2026-01-01',NULL,'[)')),
  -- convênio: mesma variante curto, mais barato, prioridade maior
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009103','00000000-0000-7000-8000-000000009002',
   '00000000-0000-7000-8000-00000000e001','00000000-0000-7000-8000-00000000e101',NULL,150.0000,'LIQUIDO_INSUMO',daterange('2026-01-01',NULL,'[)'));

-- Produto de revenda: linha separada porque a coluna preenchida é produto_id
-- (a constraint tpi_servico_xor_produto exige exatamente um dos dois).
INSERT INTO lumia.tabela_preco_item
  (tenant_id, id, tabela_preco_id, produto_id, preco, base_comissao, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-000000009104','00000000-0000-7000-8000-000000009001',
   '00000000-0000-7000-8000-00000000f003', 89.9000,'BRUTO',daterange('2026-01-01',NULL,'[)'));

-- ---------------------------------------------------------- atributos fiscais --
INSERT INTO lumia.servico_atributo_fiscal
  (tenant_id, id, servico_id, estabelecimento_id, item_lc116, codigo_tributacao_municipal, aliquota_iss, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000fa01','00000000-0000-7000-8000-00000000e001',
   '00000000-0000-7000-8000-00000000b003','6.01','610100000', 2.0000, daterange('2026-01-01',NULL,'[)')),
  -- Mesmo serviço, OUTRO município: alíquota diferente. Por isso o atributo
  -- fiscal é por estabelecimento, não por serviço.
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000fa02','00000000-0000-7000-8000-00000000e001',
   '00000000-0000-7000-8000-00000000b004','6.01','601000',      5.0000, daterange('2026-01-01',NULL,'[)'));

INSERT INTO lumia.produto_atributo_fiscal
  (tenant_id, id, produto_id, ncm, origem_mercadoria, csosn, unidade_comercial, unidade_tributavel, vigencia) VALUES
  ('00000000-0000-7000-8000-00000000a001','00000000-0000-7000-8000-00000000fb01','00000000-0000-7000-8000-00000000f003',
   '33051000', 0, '102', 'un','un', daterange('2026-01-01',NULL,'[)'));

COMMIT;
