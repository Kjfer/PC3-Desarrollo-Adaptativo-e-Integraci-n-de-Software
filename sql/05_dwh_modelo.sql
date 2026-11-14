-- 05 · Zona dwh: modelo dimensional centrado en la propuesta
-- Llaves de negocio como llaves primarias (id_propuesta, cod_cliente, cod_grupo_economico...).
-- Sin claves foráneas físicas: un huérfano (p. ej. un cliente del archivo de rating que no está en
-- el DWH) no debe detener la carga; lo detectan las reglas de calidad (fase 4).
-- Idempotente: crea cada tabla solo si no existe.

USE ARC_INTEGRADO;
GO

------------------------------------------------------------------------
-- Dimensiones
------------------------------------------------------------------------
IF OBJECT_ID('dwh.dim_banca') IS NULL
CREATE TABLE dwh.dim_banca (
    cod_banca       CHAR(3)      NOT NULL PRIMARY KEY,
    nombre_banca    NVARCHAR(50) NULL,
    fecha_carga_dwh DATETIME2(0) NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dwh.dim_grupo_economico') IS NULL
CREATE TABLE dwh.dim_grupo_economico (
    cod_grupo_economico VARCHAR(6)    NOT NULL PRIMARY KEY,
    nombre_grupo        NVARCHAR(150) NULL,
    sector              NVARCHAR(80)  NULL,
    fecha_carga_dwh     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dwh.dim_cliente') IS NULL
CREATE TABLE dwh.dim_cliente (
    cod_cliente         CHAR(8)       NOT NULL PRIMARY KEY,
    razon_social        NVARCHAR(200) NULL,
    ruc                 CHAR(11)      NULL,
    segmento            NVARCHAR(50)  NULL,
    cod_banca           CHAR(3)       NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    fecha_alta          DATE          NULL,
    fecha_carga_dwh     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dwh.dim_analista') IS NULL
CREATE TABLE dwh.dim_analista (
    cod_analista    VARCHAR(6)    NOT NULL PRIMARY KEY,
    nombre          NVARCHAR(100) NULL,
    equipo          NVARCHAR(50)  NULL,
    activo          BIT           NULL,
    fecha_carga_dwh DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('dwh.dim_fecha') IS NULL
CREATE TABLE dwh.dim_fecha (
    fecha        DATE         NOT NULL PRIMARY KEY,
    anio         SMALLINT     NOT NULL,
    mes          TINYINT      NOT NULL,
    dia          TINYINT      NOT NULL,
    nombre_mes   NVARCHAR(12) NOT NULL,
    dia_semana   TINYINT      NOT NULL,   -- 1 = lunes ... 7 = domingo
    nombre_dia   NVARCHAR(12) NOT NULL,
    es_dia_habil BIT          NOT NULL    -- lunes a viernes (sin feriados en el demo)
);
GO

------------------------------------------------------------------------
-- Hechos
------------------------------------------------------------------------
IF OBJECT_ID('dwh.fact_propuesta') IS NULL
CREATE TABLE dwh.fact_propuesta (
    id_propuesta        INT           NOT NULL PRIMARY KEY,
    cod_cliente         CHAR(8)       NULL,
    cod_banca           CHAR(3)       NULL,
    cod_analista        VARCHAR(6)    NULL,     -- base local: asignación vigente
    tipo_propuesta      VARCHAR(20)   NULL,
    fecha_ingreso       DATE          NULL,
    fecha_asignacion    DATE          NULL,     -- base local
    fecha_resolucion    DATE          NULL,
    estado              VARCHAR(20)   NULL,
    prioridad           VARCHAR(10)   NULL,     -- base local
    moneda              CHAR(3)       NULL,
    monto_solicitado    DECIMAL(18,2) NULL,
    monto_aprobado      DECIMAL(18,2) NULL,
    dias_evaluacion     AS DATEDIFF(DAY, fecha_ingreso, fecha_resolucion),
    fecha_actualizacion DATE          NULL,
    fecha_carga_dwh     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_propuesta_cliente')
CREATE INDEX IX_fact_propuesta_cliente ON dwh.fact_propuesta (cod_cliente);
GO

IF OBJECT_ID('dwh.fact_propuesta_linea') IS NULL
CREATE TABLE dwh.fact_propuesta_linea (
    id_propuesta           INT           NOT NULL,
    id_linea               INT           NOT NULL,
    tipo_linea             NVARCHAR(60)  NULL,
    moneda                 CHAR(3)       NULL,
    monto                  DECIMAL(18,2) NULL,
    plazo_meses            INT           NULL,
    fecha_vencimiento      DATE          NULL,
    es_renovacion          BIT           NULL,  -- archivo de renovaciones; NULL = la línea no apareció en ningún archivo
    fecha_corte_renovacion DATE          NULL,  -- archivo del que se tomó es_renovacion
    fecha_carga_dwh        DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_propuesta_linea PRIMARY KEY (id_propuesta, id_linea)
);
GO

IF OBJECT_ID('dwh.fact_garantia') IS NULL
CREATE TABLE dwh.fact_garantia (
    id_propuesta      INT           NOT NULL,
    id_garantia       INT           NOT NULL,
    tipo_garantia     NVARCHAR(60)  NULL,
    moneda            CHAR(3)       NULL,
    valor_comercial   DECIMAL(18,2) NULL,
    valor_realizacion DECIMAL(18,2) NULL,
    cobertura_pct     DECIMAL(7,2)  NULL,
    fecha_carga_dwh   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_garantia PRIMARY KEY (id_propuesta, id_garantia)
);
GO

-- Estado más reciente de cada consulta (la historia diaria queda en stg.consultas_propuesta)
IF OBJECT_ID('dwh.fact_consulta') IS NULL
CREATE TABLE dwh.fact_consulta (
    id_propuesta        INT            NOT NULL,
    nro_consulta        INT            NOT NULL,
    ronda               INT            NULL,
    fecha_pregunta      DATE           NULL,
    pregunta            NVARCHAR(2000) NULL,
    fecha_respuesta     DATE           NULL,
    respuesta           NVARCHAR(2000) NULL,
    estado              VARCHAR(20)    NULL,
    dias_respuesta      AS DATEDIFF(DAY, fecha_pregunta, fecha_respuesta),
    fecha_corte_primera DATE           NULL,   -- primer archivo en que apareció
    fecha_corte_ultima  DATE           NULL,   -- archivo del que se tomó el estado
    fecha_carga_dwh     DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_consulta PRIMARY KEY (id_propuesta, nro_consulta)
);
GO

-- Fotos diarias: la llave empieza por el cliente/grupo para buscar "la última foto <= fecha"
IF OBJECT_ID('dwh.fact_rating_cliente') IS NULL
CREATE TABLE dwh.fact_rating_cliente (
    cod_cliente     CHAR(8)      NOT NULL,
    fecha_corte     DATE         NOT NULL,
    rating          VARCHAR(10)  NULL,
    modelo_rating   VARCHAR(40)  NULL,
    fecha_rating    DATE         NULL,
    fecha_carga_dwh DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_rating_cliente PRIMARY KEY (cod_cliente, fecha_corte)
);
GO

IF OBJECT_ID('dwh.fact_riesgo_cliente') IS NULL
CREATE TABLE dwh.fact_riesgo_cliente (
    cod_cliente       CHAR(8)       NOT NULL,
    fecha_corte       DATE          NOT NULL,
    deuda_directa     DECIMAL(18,2) NULL,
    deuda_indirecta   DECIMAL(18,2) NULL,
    clasificacion     VARCHAR(3)    NULL,
    lineas_utilizadas DECIMAL(18,2) NULL,
    fecha_carga_dwh   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_riesgo_cliente PRIMARY KEY (cod_cliente, fecha_corte)
);
GO

IF OBJECT_ID('dwh.fact_riesgo_grupo') IS NULL
CREATE TABLE dwh.fact_riesgo_grupo (
    cod_grupo_economico VARCHAR(6)    NOT NULL,
    fecha_corte         DATE          NOT NULL,
    exposicion_total    DECIMAL(18,2) NULL,
    limite_grupo        DECIMAL(18,2) NULL,
    pct_uso_limite      AS CAST(exposicion_total * 100.0 / NULLIF(limite_grupo, 0) AS DECIMAL(9,2)),
    fecha_carga_dwh     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_fact_riesgo_grupo PRIMARY KEY (cod_grupo_economico, fecha_corte)
);
GO
