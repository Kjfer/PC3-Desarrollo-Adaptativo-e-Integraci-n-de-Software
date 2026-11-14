-- 03 · Zona raw: copia fiel de cada fuente + columnas de control
-- Archivos (raw.arch_*): todas las columnas de datos como texto, tal como vienen; la tipificación
--   se hace en stg. Control: id_archivo (ctl.archivo_cargado), archivo_origen, fecha_corte
--   (del nombre del archivo), nro_fila (orden de la fila de datos en el archivo) y fecha_carga.
-- Bases (raw.dwh_*, raw.loc_*): mismas columnas y tipos que el origen. Control: id_ejecucion
--   (ctl.log_ejecucion) y fecha_carga. Las tablas incrementales acumulan versiones.
-- Idempotente: crea cada tabla solo si no existe.

USE ARC_INTEGRADO;
GO

------------------------------------------------------------------------
-- Archivos de la ruta compartida
------------------------------------------------------------------------
IF OBJECT_ID('raw.arch_consultas_propuesta') IS NULL
CREATE TABLE raw.arch_consultas_propuesta (
    id_archivo      INT            NOT NULL,
    archivo_origen  NVARCHAR(260)  NOT NULL,
    fecha_corte     DATE           NOT NULL,
    nro_fila        INT            NOT NULL,
    fecha_carga     DATETIME2(0)   NOT NULL,
    id_propuesta    NVARCHAR(200)  NULL,
    nro_consulta    NVARCHAR(200)  NULL,
    ronda           NVARCHAR(200)  NULL,
    fecha_pregunta  NVARCHAR(200)  NULL,
    pregunta        NVARCHAR(2000) NULL,
    fecha_respuesta NVARCHAR(200)  NULL,
    respuesta       NVARCHAR(2000) NULL,
    estado          NVARCHAR(200)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_arch_consultas_propuesta_fecha')
CREATE INDEX IX_arch_consultas_propuesta_fecha ON raw.arch_consultas_propuesta (fecha_corte);
GO

IF OBJECT_ID('raw.arch_rating_cliente') IS NULL
CREATE TABLE raw.arch_rating_cliente (
    id_archivo     INT           NOT NULL,
    archivo_origen NVARCHAR(260) NOT NULL,
    fecha_corte    DATE          NOT NULL,
    nro_fila       INT           NOT NULL,
    fecha_carga    DATETIME2(0)  NOT NULL,
    cod_cliente    NVARCHAR(200) NULL,
    rating         NVARCHAR(200) NULL,
    modelo_rating  NVARCHAR(200) NULL,
    fecha_rating   NVARCHAR(200) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_arch_rating_cliente_fecha')
CREATE INDEX IX_arch_rating_cliente_fecha ON raw.arch_rating_cliente (fecha_corte);
GO

IF OBJECT_ID('raw.arch_renovacion_lineas') IS NULL
CREATE TABLE raw.arch_renovacion_lineas (
    id_archivo        INT           NOT NULL,
    archivo_origen    NVARCHAR(260) NOT NULL,
    fecha_corte       DATE          NOT NULL,
    nro_fila          INT           NOT NULL,
    fecha_carga       DATETIME2(0)  NOT NULL,
    id_propuesta      NVARCHAR(200) NULL,
    id_linea          NVARCHAR(200) NULL,
    tipo_linea        NVARCHAR(200) NULL,
    monto             NVARCHAR(200) NULL,
    plazo_meses       NVARCHAR(200) NULL,
    fecha_vencimiento NVARCHAR(200) NULL,
    es_renovacion     NVARCHAR(200) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_arch_renovacion_lineas_fecha')
CREATE INDEX IX_arch_renovacion_lineas_fecha ON raw.arch_renovacion_lineas (fecha_corte);
GO

------------------------------------------------------------------------
-- DWH corporativo
------------------------------------------------------------------------
IF OBJECT_ID('raw.dwh_banca') IS NULL
CREATE TABLE raw.dwh_banca (
    id_ejecucion INT          NOT NULL,
    fecha_carga  DATETIME2(0) NOT NULL,
    cod_banca    CHAR(3)      NULL,
    nombre_banca NVARCHAR(50) NULL
);
GO

IF OBJECT_ID('raw.dwh_grupo_economico') IS NULL
CREATE TABLE raw.dwh_grupo_economico (
    id_ejecucion        INT           NOT NULL,
    fecha_carga         DATETIME2(0)  NOT NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    nombre_grupo        NVARCHAR(150) NULL,
    sector              NVARCHAR(80)  NULL
);
GO

IF OBJECT_ID('raw.dwh_cliente') IS NULL
CREATE TABLE raw.dwh_cliente (
    id_ejecucion        INT           NOT NULL,
    fecha_carga         DATETIME2(0)  NOT NULL,
    cod_cliente         CHAR(8)       NULL,
    razon_social        NVARCHAR(200) NULL,
    ruc                 CHAR(11)      NULL,
    segmento            NVARCHAR(50)  NULL,
    cod_banca           CHAR(3)       NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    fecha_alta          DATE          NULL
);
GO

IF OBJECT_ID('raw.dwh_propuesta') IS NULL
CREATE TABLE raw.dwh_propuesta (
    id_ejecucion        INT           NOT NULL,
    fecha_carga         DATETIME2(0)  NOT NULL,
    id_propuesta        INT           NULL,
    cod_cliente         CHAR(8)       NULL,
    cod_banca           CHAR(3)       NULL,
    tipo_propuesta      VARCHAR(20)   NULL,
    fecha_ingreso       DATE          NULL,
    fecha_resolucion    DATE          NULL,
    estado              VARCHAR(20)   NULL,
    moneda              CHAR(3)       NULL,
    monto_solicitado    DECIMAL(18,2) NULL,
    monto_aprobado      DECIMAL(18,2) NULL,
    fecha_actualizacion DATE          NULL
);
GO

IF OBJECT_ID('raw.dwh_propuesta_linea') IS NULL
CREATE TABLE raw.dwh_propuesta_linea (
    id_ejecucion      INT           NOT NULL,
    fecha_carga       DATETIME2(0)  NOT NULL,
    id_propuesta      INT           NULL,
    id_linea          INT           NULL,
    tipo_linea        NVARCHAR(60)  NULL,
    moneda            CHAR(3)       NULL,
    monto             DECIMAL(18,2) NULL,
    plazo_meses       INT           NULL,
    fecha_vencimiento DATE          NULL
);
GO

IF OBJECT_ID('raw.dwh_garantia') IS NULL
CREATE TABLE raw.dwh_garantia (
    id_ejecucion      INT           NOT NULL,
    fecha_carga       DATETIME2(0)  NOT NULL,
    id_propuesta      INT           NULL,
    id_garantia       INT           NULL,
    tipo_garantia     NVARCHAR(60)  NULL,
    moneda            CHAR(3)       NULL,
    valor_comercial   DECIMAL(18,2) NULL,
    valor_realizacion DECIMAL(18,2) NULL,
    cobertura_pct     DECIMAL(7,2)  NULL
);
GO

IF OBJECT_ID('raw.dwh_riesgo_cliente') IS NULL
CREATE TABLE raw.dwh_riesgo_cliente (
    id_ejecucion      INT           NOT NULL,
    fecha_carga       DATETIME2(0)  NOT NULL,
    fecha_corte       DATE          NULL,
    cod_cliente       CHAR(8)       NULL,
    deuda_directa     DECIMAL(18,2) NULL,
    deuda_indirecta   DECIMAL(18,2) NULL,
    clasificacion     VARCHAR(3)    NULL,
    lineas_utilizadas DECIMAL(18,2) NULL
);
GO

IF OBJECT_ID('raw.dwh_riesgo_grupo') IS NULL
CREATE TABLE raw.dwh_riesgo_grupo (
    id_ejecucion        INT           NOT NULL,
    fecha_carga         DATETIME2(0)  NOT NULL,
    fecha_corte         DATE          NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    exposicion_total    DECIMAL(18,2) NULL,
    limite_grupo        DECIMAL(18,2) NULL
);
GO

------------------------------------------------------------------------
-- Base local del área
------------------------------------------------------------------------
IF OBJECT_ID('raw.loc_analista') IS NULL
CREATE TABLE raw.loc_analista (
    id_ejecucion INT           NOT NULL,
    fecha_carga  DATETIME2(0)  NOT NULL,
    cod_analista VARCHAR(6)    NULL,
    nombre       NVARCHAR(100) NULL,
    equipo       NVARCHAR(50)  NULL,
    activo       BIT           NULL
);
GO

IF OBJECT_ID('raw.loc_asignacion_propuesta') IS NULL
CREATE TABLE raw.loc_asignacion_propuesta (
    id_ejecucion     INT          NOT NULL,
    fecha_carga      DATETIME2(0) NOT NULL,
    id_asignacion    INT          NULL,
    id_propuesta     INT          NULL,
    cod_analista     VARCHAR(6)   NULL,
    fecha_asignacion DATE         NULL,
    prioridad        VARCHAR(10)  NULL
);
GO

IF OBJECT_ID('raw.loc_seguimiento_propuesta') IS NULL
CREATE TABLE raw.loc_seguimiento_propuesta (
    id_ejecucion   INT           NOT NULL,
    fecha_carga    DATETIME2(0)  NOT NULL,
    id_seguimiento INT           NULL,
    id_propuesta   INT           NULL,
    fecha_evento   DATETIME2(0)  NULL,
    evento         VARCHAR(30)   NULL,
    cod_analista   VARCHAR(6)    NULL,
    comentario     NVARCHAR(400) NULL
);
GO
