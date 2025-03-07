-- =========================================================================
-- QUERIES OTIMIZADAS - SISTEMA E-COMMERCE DE ALTA ESCALA
-- =========================================================================
-- Este arquivo contém as queries e scripts SQL principais mencionados no
-- desafio de modelagem e query performance para um sistema de e-commerce
-- que deve suportar até 1 milhão de pedidos por dia.
-- =========================================================================

-- =========================================================================
-- 1. CRIAÇÃO DA ESTRUTURA DO BANCO DE DADOS
-- =========================================================================

-- -----------------------------------------
-- 1.1 Tabelas Principais
-- -----------------------------------------

-- Tabela: usuarios
CREATE TABLE usuarios (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    senha VARCHAR(100) NOT NULL,
    cpf VARCHAR(14) UNIQUE NOT NULL,
    telefone VARCHAR(20),
    endereco_entrega JSONB,
    data_cadastro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ativo BOOLEAN DEFAULT TRUE
);

-- Tabela: produtos
CREATE TABLE produtos (
    id SERIAL PRIMARY KEY,
    nome VARCHAR(200) NOT NULL,
    descricao TEXT,
    preco DECIMAL(12,2) NOT NULL,
    estoque INT NOT NULL DEFAULT 0,
    sku VARCHAR(50) UNIQUE NOT NULL,
    peso DECIMAL(8,3),
    dimensoes JSONB,
    categoria_id INT,
    data_cadastro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ativo BOOLEAN DEFAULT TRUE,
    version INT DEFAULT 1
);

-- Tabela: pedidos
CREATE TABLE pedidos (
    id SERIAL PRIMARY KEY,
    usuario_id INT NOT NULL REFERENCES usuarios(id),
    data_pedido TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(30) DEFAULT 'pendente',
    valor_total DECIMAL(12,2) NOT NULL,
    forma_pagamento VARCHAR(50),
    endereco_entrega JSONB NOT NULL,
    codigo_rastreio VARCHAR(50),
    data_atualizacao TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_status CHECK (status IN ('pendente', 'aprovado', 'em_processamento', 'enviado', 'entregue', 'cancelado', 'devolvido'))
);

-- Tabela: itens_pedido
CREATE TABLE itens_pedido (
    id SERIAL PRIMARY KEY,
    pedido_id INT NOT NULL REFERENCES pedidos(id),
    produto_id INT NOT NULL REFERENCES produtos(id),
    quantidade INT NOT NULL,
    preco_unitario DECIMAL(12,2) NOT NULL,
    desconto DECIMAL(12,2) DEFAULT 0,
    data_adicionado TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_quantidade CHECK (quantidade > 0)
);

-- Tabela: historico_estoque (para auditoria)
CREATE TABLE historico_estoque (
    id SERIAL PRIMARY KEY,
    produto_id INT NOT NULL REFERENCES produtos(id),
    quantidade_anterior INT NOT NULL,
    quantidade_nova INT NOT NULL,
    tipo_operacao VARCHAR(20) NOT NULL,
    pedido_id INT REFERENCES pedidos(id),
    usuario_id INT REFERENCES usuarios(id),
    data_operacao TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_tipo_operacao CHECK (tipo_operacao IN ('entrada', 'saida', 'ajuste', 'devolucao'))
);

-- -----------------------------------------
-- 1.2 Índices Estratégicos
-- -----------------------------------------

-- Índices para pesquisa de usuários
CREATE INDEX idx_usuarios_email ON usuarios(email);
CREATE INDEX idx_usuarios_cpf ON usuarios(cpf);

-- Índices para pesquisa de produtos
CREATE INDEX idx_produtos_nome ON produtos(nome);
CREATE INDEX idx_produtos_preco ON produtos(preco);
CREATE INDEX idx_produtos_sku ON produtos(sku);
CREATE INDEX idx_produtos_categoria ON produtos(categoria_id);

-- Índices para consulta de pedidos
CREATE INDEX idx_pedidos_usuario ON pedidos(usuario_id);
CREATE INDEX idx_pedidos_data ON pedidos(data_pedido);
CREATE INDEX idx_pedidos_status ON pedidos(status);

-- Índices para relação itens_pedido
CREATE INDEX idx_itens_pedido_pedido ON itens_pedido(pedido_id);
CREATE INDEX idx_itens_pedido_produto ON itens_pedido(produto_id);
CREATE INDEX idx_itens_pedido_combo ON itens_pedido(pedido_id, produto_id);

-- -----------------------------------------
-- 1.3 Particionamento da Tabela de Pedidos
-- -----------------------------------------

-- Tabela base com configuração de particionamento
CREATE TABLE pedidos_particionada (
    LIKE pedidos INCLUDING ALL
) PARTITION BY RANGE (data_pedido);

-- Criação de partições por mês (exemplo para 2024)
CREATE TABLE pedidos_y2024m01 PARTITION OF pedidos_particionada
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
    
CREATE TABLE pedidos_y2024m02 PARTITION OF pedidos_particionada
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

CREATE TABLE pedidos_y2024m03 PARTITION OF pedidos_particionada
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- Função para criar partições automaticamente
CREATE OR REPLACE FUNCTION criar_particao_mes()
RETURNS TRIGGER AS $$
DECLARE
    particao_data TEXT;
    particao_nome TEXT;
    particao_inicio DATE;
    particao_fim DATE;
BEGIN
    particao_inicio := DATE_TRUNC('month', NEW.data_pedido);
    particao_fim := particao_inicio + INTERVAL '1 month';
    particao_data := TO_CHAR(NEW.data_pedido, 'YYYYmm');
    particao_nome := 'pedidos_y' || TO_CHAR(NEW.data_pedido, 'YYYY') || 'm' || TO_CHAR(NEW.data_pedido, 'MM');
    
    -- Verificar se a partição já existe
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = particao_nome) THEN
        EXECUTE 'CREATE TABLE ' || particao_nome || ' PARTITION OF pedidos_particionada
                 FOR VALUES FROM (''' || particao_inicio || ''') TO (''' || particao_fim || ''')';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para criar partições automaticamente
CREATE TRIGGER trig_criar_particao_pedidos
    BEFORE INSERT ON pedidos_particionada
    FOR EACH ROW
    EXECUTE FUNCTION criar_particao_mes();

-- =========================================================================
-- 2. QUERIES OTIMIZADAS
-- =========================================================================

-- -----------------------------------------
-- 2.1 Últimos 10 pedidos de um usuário específico
-- -----------------------------------------

/*
Esta query recupera os últimos 10 pedidos de um usuário com todos 
os produtos de cada pedido em formato JSON agregado.

Parâmetros:
- $1: ID do usuário

Otimizações aplicadas:
- Usa json_agg para evitar múltiplas linhas por pedido
- Inclui somente colunas necessárias
- Aproveita o índice em pedidos(usuario_id)
- Limita resultados a 10 registros
*/

SELECT 
    p.id AS pedido_id,
    p.data_pedido,
    p.valor_total,
    p.status,
    json_agg(
        json_build_object(
            'produto_id', pr.id,
            'nome', pr.nome,
            'quantidade', ip.quantidade,
            'preco_unitario', ip.preco_unitario,
            'subtotal', (ip.quantidade * ip.preco_unitario) - ip.desconto
        )
    ) AS produtos
FROM 
    pedidos p
JOIN 
    itens_pedido ip ON p.id = ip.pedido_id
JOIN 
    produtos pr ON ip.produto_id = pr.id
WHERE 
    p.usuario_id = $1
GROUP BY 
    p.id, p.data_pedido, p.valor_total, p.status
ORDER BY 
    p.data_pedido DESC
LIMIT 10;

-- -----------------------------------------
-- 2.2 Produtos mais vendidos nos últimos 30 dias
-- -----------------------------------------

/*
Esta query identifica os produtos mais vendidos no período recente.

Otimizações aplicadas:
- Usa CTE para melhor legibilidade e desempenho
- Filtra pedidos cancelados/devolvidos para dados precisos
- Aproveita índice composto em itens_pedido(pedido_id, produto_id)
- Utiliza LEFT JOIN para incluir produtos sem vendas
*/

WITH vendas_recentes AS (
    SELECT 
        ip.produto_id,
        SUM(ip.quantidade) AS quantidade_vendida
    FROM 
        itens_pedido ip
    JOIN 
        pedidos p ON ip.pedido_id = p.id
    WHERE 
        p.data_pedido >= CURRENT_DATE - INTERVAL '30 days'
        AND p.status NOT IN ('cancelado', 'devolvido')
    GROUP BY 
        ip.produto_id
)
SELECT 
    p.id,
    p.nome,
    p.preco,
    COALESCE(vr.quantidade_vendida, 0) AS quantidade_vendida
FROM 
    produtos p
LEFT JOIN 
    vendas_recentes vr ON p.id = vr.produto_id
WHERE 
    COALESCE(vr.quantidade_vendida, 0) > 0
ORDER BY 
    quantidade_vendida DESC;

-- -----------------------------------------
-- 2.3 Dashboard de vendas com métricas por categoria
-- -----------------------------------------

/*
Esta query gera um dashboard com métricas de vendas agrupadas
por categoria de produto nos últimos 90 dias.
*/

WITH vendas_periodo AS (
    SELECT 
        pr.categoria_id,
        SUM(ip.quantidade * ip.preco_unitario) AS valor_total_vendas,
        SUM(ip.quantidade) AS quantidade_total_itens,
        COUNT(DISTINCT p.id) AS total_pedidos,
        COUNT(DISTINCT p.usuario_id) AS total_clientes
    FROM 
        pedidos p
    JOIN 
        itens_pedido ip ON p.id = ip.pedido_id
    JOIN 
        produtos pr ON ip.produto_id = pr.id
    WHERE 
        p.data_pedido >= CURRENT_DATE - INTERVAL '90 days'
        AND p.status NOT IN ('cancelado', 'devolvido')
    GROUP BY 
        pr.categoria_id
)
SELECT 
    c.id AS categoria_id,
    c.nome AS categoria,
    COALESCE(vp.valor_total_vendas, 0) AS valor_total_vendas,
    COALESCE(vp.quantidade_total_itens, 0) AS quantidade_total_itens,
    COALESCE(vp.total_pedidos, 0) AS total_pedidos,
    COALESCE(vp.total_clientes, 0) AS total_clientes,
    CASE 
        WHEN vp.total_pedidos > 0 THEN 
            ROUND(vp.valor_total_vendas / vp.total_pedidos, 2)
        ELSE 0
    END AS ticket_medio
FROM 
    categorias c
LEFT JOIN 
    vendas_periodo vp ON c.id = vp.categoria_id
ORDER BY 
    valor_total_vendas DESC;

-- -----------------------------------------
-- 2.4 Análise de disponibilidade de estoque
-- -----------------------------------------

/*
Esta query identifica produtos com estoque baixo baseado 
no padrão de vendas dos últimos 30 dias.
*/

WITH taxa_vendas_diarias AS (
    SELECT 
        ip.produto_id,
        SUM(ip.quantidade) / 30.0 AS media_diaria_vendas
    FROM 
        itens_pedido ip
    JOIN 
        pedidos p ON ip.pedido_id = p.id
    WHERE 
        p.data_pedido >= CURRENT_DATE - INTERVAL '30 days'
        AND p.status NOT IN ('cancelado', 'devolvido')
    GROUP BY 
        ip.produto_id
)
SELECT 
    p.id,
    p.nome,
    p.sku,
    p.estoque AS estoque_atual,
    COALESCE(tv.media_diaria_vendas, 0) AS media_diaria_vendas,
    CASE 
        WHEN tv.media_diaria_vendas > 0 THEN 
            ROUND(p.estoque / tv.media_diaria_vendas)
        ELSE NULL
    END AS dias_estimados_ate_esgotar,
    CASE
        WHEN p.estoque <= 0 THEN 'Sem estoque'
        WHEN p.estoque < COALESCE(tv.media_diaria_vendas * 7, 10) THEN 'Crítico'
        WHEN p.estoque < COALESCE(tv.media_diaria_vendas * 15, 20) THEN 'Baixo'
        ELSE 'Adequado'
    END AS status_estoque
FROM 
    produtos p
LEFT JOIN 
    taxa_vendas_diarias tv ON p.id = tv.produto_id
WHERE 
    p.ativo = TRUE
    AND (
        p.estoque <= COALESCE(tv.media_diaria_vendas * 15, 20)
        OR p.estoque <= 5
    )
ORDER BY 
    dias_estimados_ate_esgotar ASC NULLS LAST,
    estoque_atual ASC;

-- =========================================================================
-- 3. FUNÇÕES E PROCEDIMENTOS ARMAZENADOS
-- =========================================================================

-- -----------------------------------------
-- 3.1 Atualização de estoque com controle de concorrência
-- -----------------------------------------

/*
Esta função implementa controle de concorrência otimista para evitar race conditions.

Parâmetros:
- p_produto_id: ID do produto a ser atualizado
- p_quantidade: Quantidade a ser reduzida do estoque
- p_pedido_id: ID do pedido associado
- p_usuario_id: ID do usuário que está realizando a operação
- p_version: Versão atual do produto (controle otimista)

Retorno:
- BOOLEAN: TRUE se a operação foi bem-sucedida, FALSE caso contrário

Uso:
BEGIN;
-- Verificar versão atual
SELECT id, nome, estoque, version FROM produtos WHERE id = 123;

-- Tentar atualizar o estoque
SELECT atualizar_estoque_produto(
    123,         -- ID do produto
    2,           -- Quantidade sendo comprada
    456,         -- ID do pedido
    789,         -- ID do usuário
    5            -- Versão atual do produto obtida antes da transação
);
COMMIT;
*/

CREATE OR REPLACE FUNCTION atualizar_estoque_produto(
    p_produto_id INT, 
    p_quantidade INT, 
    p_pedido_id INT, 
    p_usuario_id INT,
    p_version INT
) 
RETURNS BOOLEAN AS $$
DECLARE
    v_estoque_atual INT;
    v_version_atual INT;
    v_resultado BOOLEAN := FALSE;
BEGIN
    -- Obter o estoque atual usando FOR UPDATE para lock da linha
    SELECT estoque, version INTO v_estoque_atual, v_version_atual 
    FROM produtos 
    WHERE id = p_produto_id
    FOR UPDATE;
    
    -- Verificar controle de versão
    IF v_version_atual <> p_version THEN
        RETURN FALSE; -- Conflito de versão detectado
    END IF;
    
    -- Verificar se tem estoque suficiente
    IF v_estoque_atual >= p_quantidade THEN
        -- Atualizar estoque
        UPDATE produtos 
        SET 
            estoque = estoque - p_quantidade,
            version = version + 1
        WHERE 
            id = p_produto_id
            AND version = p_version;
            
        -- Registrar histórico para auditoria
        INSERT INTO historico_estoque (
            produto_id, 
            quantidade_anterior, 
            quantidade_nova, 
            tipo_operacao, 
            pedido_id, 
            usuario_id
        ) VALUES (
            p_produto_id, 
            v_estoque_atual, 
            v_estoque_atual - p_quantidade, 
            'saida', 
            p_pedido_id, 
            p_usuario_id
        );
        
        v_resultado := TRUE;
    END IF;
    
    RETURN v_resultado;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------
-- 3.2 Criação de Pedido com Transação Atômica
-- -----------------------------------------

/*
Este procedimento cria um pedido completo em uma única transação atômica,
verificando disponibilidade de estoque e atualizando todos os registros necessários.

Parâmetros:
- p_usuario_id: ID do usuário que está fazendo o pedido
- p_itens: Array JSON com os itens do pedido (formato: [{produto_id, quantidade, preco_unitario, desconto}])
- p_endereco_entrega: JSON com endereço de entrega
- p_forma_pagamento: Método de pagamento
- p_pedido_id: Parâmetro de saída com o ID do pedido criado

Retorno:
- INT: ID do pedido criado ou 0 em caso de erro
*/

CREATE OR REPLACE FUNCTION criar_pedido(
    p_usuario_id INT,
    p_itens JSONB,
    p_endereco_entrega JSONB,
    p_forma_pagamento VARCHAR(50),
    OUT p_pedido_id INT
) RETURNS INT AS $$
DECLARE
    v_item JSONB;
    v_produto_id INT;
    v_quantidade INT;
    v_preco_unitario DECIMAL(12,2);
    v_desconto DECIMAL(12,2);
    v_version INT;
    v_valor_total DECIMAL(12,2) := 0;
    v_estoque_atualizado BOOLEAN;
BEGIN
    -- Iniciar com valor padrão
    p_pedido_id := 0;
    
    -- Verificar se o usuário existe
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE id = p_usuario_id AND ativo = TRUE) THEN
        RAISE EXCEPTION 'Usuário inexistente ou inativo';
        RETURN;
    END IF;
    
    -- Validar formato dos itens
    IF p_itens IS NULL OR jsonb_array_length(p_itens) = 0 THEN
        RAISE EXCEPTION 'O pedido deve conter pelo menos um item';
        RETURN;
    END IF;
    
    -- Iniciar transação
    BEGIN
        -- Primeiro, verificar disponibilidade de estoque para todos os itens
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_itens)
        LOOP
            v_produto_id := (v_item->>'produto_id')::INT;
            v_quantidade := (v_item->>'quantidade')::INT;
            
            IF NOT EXISTS (
                SELECT 1 FROM produtos 
                WHERE id = v_produto_id AND ativo = TRUE AND estoque >= v_quantidade
            ) THEN
                RAISE EXCEPTION 'Produto % não possui estoque suficiente', v_produto_id;
                RETURN;
            END IF;
        END LOOP;
        
        -- Calcular valor total
        SELECT 
            SUM((i->>'quantidade')::INT * (i->>'preco_unitario')::DECIMAL(12,2) - COALESCE((i->>'desconto')::DECIMAL(12,2), 0))
        INTO v_valor_total
        FROM jsonb_array_elements(p_itens) AS i;
        
        -- Criar o pedido
        INSERT INTO pedidos (
            usuario_id,
            valor_total,
            forma_pagamento,
            endereco_entrega,
            status
        ) VALUES (
            p_usuario_id,
            v_valor_total,
            p_forma_pagamento,
            p_endereco_entrega,
            'pendente'
        ) RETURNING id INTO p_pedido_id;
        
        -- Inserir os itens do pedido e atualizar estoque
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_itens)
        LOOP
            v_produto_id := (v_item->>'produto_id')::INT;
            v_quantidade := (v_item->>'quantidade')::INT;
            v_preco_unitario := (v_item->>'preco_unitario')::DECIMAL(12,2);
            v_desconto := COALESCE((v_item->>'desconto')::DECIMAL(12,2), 0);
            
            -- Obter versão atual do produto
            SELECT version INTO v_version FROM produtos WHERE id = v_produto_id FOR UPDATE;
            
            -- Inserir item do pedido
            INSERT INTO itens_pedido (
                pedido_id,
                produto_id,
                quantidade,
                preco_unitario,
                desconto
            ) VALUES (
                p_pedido_id,
                v_produto_id,
                v_quantidade,
                v_preco_unitario,
                v_desconto
            );
            
            -- Atualizar estoque
            SELECT atualizar_estoque_produto(
                v_produto_id,
                v_quantidade,
                p_pedido_id,
                p_usuario_id,
                v_version
            ) INTO v_estoque_atualizado;
            
            IF NOT v_estoque_atualizado THEN
                RAISE EXCEPTION 'Falha ao atualizar estoque do produto %', v_produto_id;
                RETURN;
            END IF;
        END LOOP;
        
        -- Commit implícito por causa do RETURNS
    EXCEPTION WHEN OTHERS THEN
        -- Em caso de erro, será feito rollback implícito
        RAISE NOTICE 'Erro ao criar pedido: %', SQLERRM;
        p_pedido_id := 0;
    END;
    
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------
-- 3.3 View Materializada: Dashboard de Vendas
-- -----------------------------------------

/*
Esta view materializada permite consultas rápidas ao dashboard de vendas,
sendo atualizada periodicamente (recomendado: a cada hora).
*/

CREATE MATERIALIZED VIEW mv_dashboard_vendas AS
WITH vendas_diarias AS (
    SELECT 
        DATE_TRUNC('day', p.data_pedido)::DATE AS data,
        SUM(p.valor_total) AS valor_total,
        COUNT(DISTINCT p.id) AS total_pedidos,
        COUNT(DISTINCT p.usuario_id) AS total_clientes
    FROM 
        pedidos p
    WHERE 
        p.data_pedido >= CURRENT_DATE - INTERVAL '90 days'
        AND p.status NOT IN ('cancelado', 'devolvido')
    GROUP BY 
        DATE_TRUNC('day', p.data_pedido)::DATE
),
vendas_por_categoria AS (
    SELECT 
        DATE_TRUNC('day', p.data_pedido)::DATE AS data,
        pr.categoria_id,
        SUM(ip.quantidade * ip.preco_unitario) AS valor_total,
        SUM(ip.quantidade) AS quantidade_total
    FROM 
        pedidos p
    JOIN 
        itens_pedido ip ON p.id = ip.pedido_id
    JOIN 
        produtos pr ON ip.produto_id = pr.id
    WHERE 
        p.data_pedido >= CURRENT_DATE - INTERVAL '90 days'
        AND p.status NOT IN ('cancelado', 'devolvido')
    GROUP BY 
        DATE_TRUNC('day', p.data_pedido)::DATE,
        pr.categoria_id
)
SELECT 
    vd.data,
    vd.valor_total,
    vd.total_pedidos,
    vd.total_clientes,
    CASE 
        WHEN vd.total_pedidos > 0 THEN 
            ROUND(vd.valor_total / vd.total_pedidos, 2)
        ELSE 0
    END AS ticket_medio,
    json_object_agg(
        COALESCE(c.nome, 'Sem categoria'), 
        json_build_object(
            'valor_total', COALESCE(vpc.valor_total, 0),
            'quantidade', COALESCE(vpc.quantidade_total, 0)
        )
    ) AS vendas_categorias
FROM 
    vendas_diarias vd
LEFT JOIN 
    vendas_por_categoria vpc ON vd.data = vpc.data
LEFT JOIN 
    categorias c ON vpc.categoria_id = c.id
GROUP BY 
    vd.data, vd.valor_total, vd.total_pedidos, vd.total_clientes
ORDER BY 
    vd.data DESC;

-- Criar índice para melhorar performance
CREATE UNIQUE INDEX idx_mv_dashboard_vendas_data ON mv_dashboard_vendas(data);

-- Comando para atualizar a view materializada:
-- REFRESH MATERIALIZED VIEW mv_dashboard_vendas;

-- -----------------------------------------
-- 3.4 Procedimento para Cancelamento de Pedido
-- -----------------------------------------

/*
Este procedimento realiza o cancelamento de um pedido e devolve
os itens ao estoque, registrando as operações no histórico.

Parâmetros:
- p_pedido_id: ID do pedido a ser cancelado
- p_motivo_cancelamento: Motivo do cancelamento (opcional)
- p_usuario_id: ID do usuário que está realizando o cancelamento

Retorno:
- BOOLEAN: TRUE se a operação foi bem-sucedida, FALSE caso contrário
*/

CREATE OR REPLACE FUNCTION cancelar_pedido(
    p_pedido_id INT,
    p_motivo_cancelamento TEXT DEFAULT NULL,
    p_usuario_id INT
) 
RETURNS BOOLEAN AS $$
DECLARE
    v_status_atual VARCHAR(30);
    v_item RECORD;
BEGIN
    -- Verificar se o pedido existe e seu status atual
    SELECT status INTO v_status_atual 
    FROM pedidos 
    WHERE id = p_pedido_id
    FOR UPDATE;
    
    -- Validar se o pedido pode ser cancelado
    IF v_status_atual IS NULL THEN
        RAISE EXCEPTION 'Pedido não encontrado';
        RETURN FALSE;
    ELSIF v_status_atual = 'cancelado' THEN
        RAISE EXCEPTION 'Pedido já está cancelado';
        RETURN FALSE;
    ELSIF v_status_atual IN ('enviado', 'entregue') THEN
        RAISE EXCEPTION 'Pedido já foi enviado ou entregue e não pode ser cancelado';
        RETURN FALSE;
    END IF;
    
    -- Atualizar status do pedido
    UPDATE pedidos 
    SET 
        status = 'cancelado',
        data_atualizacao = CURRENT_TIMESTAMP
    WHERE 
        id = p_pedido_id;
        
    -- Para cada item do pedido
    FOR v_item IN 
        SELECT ip.produto_id, ip.quantidade
        FROM itens_pedido ip
        WHERE ip.pedido_id = p_pedido_id
    LOOP
        -- Restaurar estoque
        UPDATE produtos
        SET 
            estoque = estoque + v_item.quantidade,
            version = version + 1
        WHERE 
            id = v_item.produto_id;
            
        -- Registrar no histórico
        INSERT INTO historico_estoque (
            produto_id,
            quantidade_anterior,
            quantidade_nova,
            tipo_operacao,
            pedido_id,
            usuario_id
        )
        SELECT
            v_item.produto_id,
            p.estoque - v_item.quantidade,
            p.estoque,
            'devolucao',
            p_pedido_id,
            p_usuario_id
        FROM produtos p
        WHERE p.id = v_item.produto_id;
    END LOOP;
    
    -- Registrar motivo do cancelamento, se fornecido
    IF p_motivo_cancelamento IS NOT NULL THEN
        UPDATE pedidos
        SET 
            observacoes = COALESCE(observacoes, '{}'::JSONB) || 
                          jsonb_build_object('cancelamento', 
                                           jsonb_build_object(
                                               'motivo', p_motivo_cancelamento,
                                               'data', CURRENT_TIMESTAMP,
                                               'usuario_id', p_usuario_id
                                           ))
        WHERE 
            id = p_pedido_id;
    END IF;
    
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Erro ao cancelar pedido: %', SQLERRM;
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- =========================================================================
-- 4. EXEMPLOS DE USO
-- =========================================================================

-- -----------------------------------------
-- 4.1 Teste de Concorrência
-- -----------------------------------------

-- Terminal 1
BEGIN;
SELECT version FROM produtos WHERE id = 1;  -- Retorna 1
-- Aguardar terminal 2

-- Terminal 2
BEGIN;
SELECT version FROM produtos WHERE id = 1;  -- Retorna 1
SELECT atualizar_estoque_produto(1, 5, 100, 200, 1);  -- Atualiza estoque
COMMIT;

-- Terminal 1 (continuação)
SELECT atualizar_estoque_produto(1, 3, 101, 201, 1);  -- Retorna FALSE (versão desatualizada)
-- Para sucesso, obter versão atual e tentar novamente
SELECT version FROM produtos WHERE id = 1;  -- Retorna 2
SELECT atualizar_estoque_produto(1, 3, 101, 201, 2);  -- Agora retorna TRUE
COMMIT;

-- -----------------------------------------
-- 4.2 Criação de Pedido Completo
-- -----------------------------------------

DO $$
DECLARE
    v_pedido_id INT;
    v_itens JSONB := '[
        {
            "produto_id": 1,
            "quantidade": 2,
            "preco_unitario": 29.90,
            "desconto": 0
        },
        {
            "produto_id": 3, 
            "quantidade": 1,
            "preco_unitario": 149.90,
            "desconto": 15.00
        }
    ]';
    v_endereco JSONB := '{
        "cep": "12345-678",
        "logradouro": "Rua Exemplo",
        "numero": "123",
        "complemento": "Apto 45",
        "bairro": "Centro",
        "cidade": "São Paulo",
        "estado": "SP"
    }';
BEGIN
    SELECT criar_pedido(
        1,              -- ID do usuário
        v_itens,        -- Itens do pedido
        v_endereco,     -- Endereço de entrega
        'cartao_credito',   -- Forma de pagamento
        v_pedido_id     -- Variável para receber o ID do pedido
    ) INTO v_pedido_id;
    
    RAISE NOTICE 'Pedido criado com ID: %', v_pedido_id;
END $$;

-- -----------------------------------------
-- 4.3 Cancelamento de Pedido
-- -----------------------------------------

SELECT cancelar_pedido(
    123,                -- ID do pedido
    'Cliente desistiu da compra',  -- Motivo do cancelamento
    1                   -- ID do usuário que está cancelando
);

-- -----------------------------------------
-- 4.4 Consulta ao Dashboard de Vendas
-- -----------------------------------------

-- Atualizar a view materializada
REFRESH MATERIALIZED VIEW mv_dashboard_vendas;

-- Consulta para os últimos 7 dias
SELECT 
    data,
    valor_total,
    total_pedidos,
    ticket_medio,
    vendas_categorias->>'Eletrônicos' AS vendas_eletronicos,
    vendas_categorias->>'Livros' AS vendas_livros
FROM 
    mv_dashboard_vendas
WHERE 
    data >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY 
    data DESC;
