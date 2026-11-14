-- 02 · Tablas de origen simuladas (las llena src/generar_datos.py)
-- Idempotente: crea cada tabla solo si no existe; no borra datos.

------------------------------------------------------------------------
-- DWH corporativo simulado: tablas "listas para consumir", carga diaria
------------------------------------------------------------------------
USE DWH_CORP_SIM;
GO

IF OBJECT_ID('dbo.banca') IS NULL
CREATE TABLE dbo.banca (
    cod_banca       CHAR(3)       NOT NULL PRIMARY KEY,   -- COR, INS, EMP, INM
    nombre_banca    NVARCHAR(50)  NOT NULL
);
GO

IF OBJECT_ID('dbo.grupo_economico') IS NULL
CREATE TABLE dbo.grupo_economico (
    cod_grupo_economico VARCHAR(6)    NOT NULL PRIMARY KEY, -- GE0001
    nombre_grupo        NVARCHAR(150) NOT NULL,
    sector              NVARCHAR(80)  NOT NULL
);
GO

IF OBJECT_ID('dbo.cliente') IS NULL
CREATE TABLE dbo.cliente (
    cod_cliente         CHAR(8)       NOT NULL PRIMARY KEY, -- texto con ceros a la izquierda: 00012345
    razon_social        NVARCHAR(200) NOT NULL,
    ruc                 CHAR(11)      NOT NULL,
    segmento            NVARCHAR(50)  NOT NULL,
    cod_banca           CHAR(3)       NOT NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    fecha_alta          DATE          NOT NULL
);
GO

IF OBJECT_ID('dbo.propuesta') IS NULL
CREATE TABLE dbo.propuesta (
    id_propuesta        INT           NOT NULL PRIMARY KEY,
    cod_cliente         CHAR(8)       NOT NULL,
    cod_banca           CHAR(3)       NOT NULL,
    tipo_propuesta      VARCHAR(20)   NOT NULL,   -- NUEVA, RENOVACION, AMPLIACION
    fecha_ingreso       DATE          NOT NULL,
    fecha_resolucion    DATE          NULL,
    estado              VARCHAR(20)   NOT NULL,   -- EN EVALUACION, APROBADA, OBSERVADA, DENEGADA
    moneda              CHAR(3)       NOT NULL,
    monto_solicitado    DECIMAL(18,2) NOT NULL,
    monto_aprobado      DECIMAL(18,2) NULL,
    fecha_actualizacion DATE          NOT NULL    -- marca de agua para la carga incremental
);
GO

IF OBJECT_ID('dbo.propuesta_linea') IS NULL
CREATE TABLE dbo.propuesta_linea (
    id_propuesta      INT           NOT NULL,
    id_linea          INT           NOT NULL,
    tipo_linea        NVARCHAR(60)  NOT NULL,
    moneda            CHAR(3)       NOT NULL,
    monto             DECIMAL(18,2) NOT NULL,
    plazo_meses       INT           NOT NULL,
    fecha_vencimiento DATE          NOT NULL,
    CONSTRAINT PK_propuesta_linea PRIMARY KEY (id_propuesta, id_linea)
);
GO

IF OBJECT_ID('dbo.garantia') IS NULL
CREATE TABLE dbo.garantia (
    id_propuesta      INT           NOT NULL,
    id_garantia       INT           NOT NULL,
    tipo_garantia     NVARCHAR(60)  NOT NULL,
    moneda            CHAR(3)       NOT NULL,
    valor_comercial   DECIMAL(18,2) NOT NULL,
    valor_realizacion DECIMAL(18,2) NOT NULL,
    cobertura_pct     DECIMAL(7,2)  NOT NULL,
    CONSTRAINT PK_garantia PRIMARY KEY (id_propuesta, id_garantia)
);
GO

-- Foto diaria del riesgo del cliente en el sistema financiero (montos en PEN)
IF OBJECT_ID('dbo.riesgo_cliente') IS NULL
CREATE TABLE dbo.riesgo_cliente (
    fecha_corte       DATE          NOT NULL,
    cod_cliente       CHAR(8)       NOT NULL,
    deuda_directa     DECIMAL(18,2) NOT NULL,
    deuda_indirecta   DECIMAL(18,2) NOT NULL,
    clasificacion     VARCHAR(3)    NOT NULL,   -- NOR, CPP, DEF, DUD, PER
    lineas_utilizadas DECIMAL(18,2) NOT NULL,
    CONSTRAINT PK_riesgo_cliente PRIMARY KEY (fecha_corte, cod_cliente)
);
GO

-- Foto diaria de la exposición del grupo económico (montos en PEN)
IF OBJECT_ID('dbo.riesgo_grupo') IS NULL
CREATE TABLE dbo.riesgo_grupo (
    fecha_corte         DATE          NOT NULL,
    cod_grupo_economico VARCHAR(6)    NOT NULL,
    exposicion_total    DECIMAL(18,2) NOT NULL,
    limite_grupo        DECIMAL(18,2) NOT NULL,
    CONSTRAINT PK_riesgo_grupo PRIMARY KEY (fecha_corte, cod_grupo_economico)
);
GO

------------------------------------------------------------------------
-- Base local del área: seguimiento y asignación de propuestas
------------------------------------------------------------------------
USE BD_ARC_LOCAL;
GO

IF OBJECT_ID('dbo.analista') IS NULL
CREATE TABLE dbo.analista (
    cod_analista VARCHAR(6)    NOT NULL PRIMARY KEY,   -- AN001
    nombre       NVARCHAR(100) NOT NULL,
    equipo       NVARCHAR(50)  NOT NULL,
    activo       BIT           NOT NULL
);
GO

IF OBJECT_ID('dbo.asignacion_propuesta') IS NULL
CREATE TABLE dbo.asignacion_propuesta (
    id_asignacion    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_propuesta     INT          NOT NULL,
    cod_analista     VARCHAR(6)   NOT NULL,
    fecha_asignacion DATE         NOT NULL,
    prioridad        VARCHAR(10)  NOT NULL      -- ALTA, MEDIA, BAJA
);
GO

IF OBJECT_ID('dbo.seguimiento_propuesta') IS NULL
CREATE TABLE dbo.seguimiento_propuesta (
    id_seguimiento INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_propuesta   INT           NOT NULL,
    fecha_evento   DATETIME2(0)  NOT NULL,
    evento         VARCHAR(30)   NOT NULL,      -- ASIGNADA, EN REVISION, CONSULTA ENVIADA, RESPUESTA RECIBIDA, OPINION EMITIDA
    cod_analista   VARCHAR(6)    NOT NULL,
    comentario     NVARCHAR(400) NULL
);
GO
