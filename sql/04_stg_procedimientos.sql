-- 04 · Zona stg: tipifica, limpia, estandariza llaves y fechas, elimina duplicados (T-SQL)
--
-- Archivos (stg.consultas_propuesta, stg.rating_cliente, stg.renovacion_lineas):
--   se procesan por fecha de corte. Una fecha está pendiente cuando su carga vigente en
--   ctl.archivo_cargado (estado CARGADO) todavía no está en stg. Así, un archivo nuevo o
--   recargado se reprocesa solo, y una falla anterior se corrige en la corrida siguiente.
--   @reprocesar_todo = 1 rehace todas las fechas.
-- Bases (stg.banca ... stg.asignacion_propuesta): se reconstruyen completas desde raw, tomando
--   la última versión de cada llave.
--
-- Cada procedimiento devuelve una fila con la cantidad de filas escritas (columna filas).
-- Idempotente: funciones y procedimientos con CREATE OR ALTER, tablas solo si no existen.

USE ARC_INTEGRADO;
GO

------------------------------------------------------------------------
-- Funciones de limpieza
------------------------------------------------------------------------
-- Texto recortado; vacío -> NULL
CREATE OR ALTER FUNCTION stg.fn_texto (@x NVARCHAR(4000)) RETURNS NVARCHAR(4000)
AS
BEGIN
    RETURN NULLIF(LTRIM(RTRIM(@x)), N'');
END;
GO

-- Fecha en aaaa-mm-dd (también la que deja el lector de Excel) o dd/mm/aaaa; otro formato -> NULL
CREATE OR ALTER FUNCTION stg.fn_fecha (@x NVARCHAR(200)) RETURNS DATE
AS
BEGIN
    DECLARE @t NVARCHAR(200) = LTRIM(RTRIM(@x));
    RETURN CASE
        WHEN @t LIKE N'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]%' THEN TRY_CONVERT(DATE, LEFT(@t, 10), 23)
        WHEN @t LIKE N'%/%/[0-9][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, @t, 103)
    END;
END;
GO

-- Monto: si trae coma, la coma es el decimal y el punto es separador de miles (1.234,56 / 1234,56)
CREATE OR ALTER FUNCTION stg.fn_decimal (@x NVARCHAR(200)) RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @t NVARCHAR(200) = REPLACE(LTRIM(RTRIM(@x)), N' ', N'');
    IF @t LIKE N'%,%'
        SET @t = REPLACE(REPLACE(@t, N'.', N''), N',', N'.');
    RETURN TRY_CAST(@t AS DECIMAL(18,2));
END;
GO

-- Código de cliente: solo dígitos, texto de 8 posiciones con ceros a la izquierda (12345 -> 00012345)
CREATE OR ALTER FUNCTION stg.fn_cod_cliente (@x NVARCHAR(200)) RETURNS CHAR(8)
AS
BEGIN
    DECLARE @t NVARCHAR(200) = LTRIM(RTRIM(@x));
    IF @t LIKE N'%.0'
        SET @t = LEFT(@t, LEN(@t) - 2);   -- 12345.0 si el Excel lo guardó como decimal
    RETURN CASE WHEN @t <> N'' AND @t NOT LIKE N'%[^0-9]%' AND LEN(@t) <= 8
                THEN RIGHT(REPLICATE('0', 8) + @t, 8) END;
END;
GO

-- Indicador S/N -> 1/0; otro valor -> NULL
CREATE OR ALTER FUNCTION stg.fn_si_no (@x NVARCHAR(200)) RETURNS BIT
AS
BEGIN
    DECLARE @t NVARCHAR(200) = UPPER(LTRIM(RTRIM(@x)));
    RETURN CASE WHEN @t IN (N'S', N'SI', N'SÍ', N'1', N'TRUE', N'Y') THEN 1
                WHEN @t IN (N'N', N'NO', N'0', N'FALSE') THEN 0 END;
END;
GO

------------------------------------------------------------------------
-- Tablas stg de archivos (historia por fecha de corte)
------------------------------------------------------------------------
IF OBJECT_ID('stg.consultas_propuesta') IS NULL
CREATE TABLE stg.consultas_propuesta (
    id_archivo      INT            NOT NULL,
    fecha_corte     DATE           NOT NULL,
    id_propuesta    INT            NOT NULL,
    nro_consulta    INT            NOT NULL,
    ronda           INT            NULL,
    fecha_pregunta  DATE           NULL,
    pregunta        NVARCHAR(2000) NULL,
    fecha_respuesta DATE           NULL,
    respuesta       NVARCHAR(2000) NULL,
    estado          VARCHAR(20)    NULL,
    fecha_proceso   DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_stg_consultas_propuesta PRIMARY KEY (fecha_corte, id_propuesta, nro_consulta)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_stg_consultas_propuesta_archivo')
CREATE INDEX IX_stg_consultas_propuesta_archivo ON stg.consultas_propuesta (id_archivo);
GO

IF OBJECT_ID('stg.rating_cliente') IS NULL
CREATE TABLE stg.rating_cliente (
    id_archivo    INT          NOT NULL,
    fecha_corte   DATE         NOT NULL,
    cod_cliente   CHAR(8)      NOT NULL,
    rating        VARCHAR(10)  NULL,
    modelo_rating VARCHAR(40)  NULL,
    fecha_rating  DATE         NULL,
    fecha_proceso DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_stg_rating_cliente PRIMARY KEY (fecha_corte, cod_cliente)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_stg_rating_cliente_archivo')
CREATE INDEX IX_stg_rating_cliente_archivo ON stg.rating_cliente (id_archivo);
GO

IF OBJECT_ID('stg.renovacion_lineas') IS NULL
CREATE TABLE stg.renovacion_lineas (
    id_archivo        INT           NOT NULL,
    fecha_corte       DATE          NOT NULL,
    id_propuesta      INT           NOT NULL,
    id_linea          INT           NOT NULL,
    tipo_linea        NVARCHAR(60)  NULL,
    monto             DECIMAL(18,2) NULL,
    plazo_meses       INT           NULL,
    fecha_vencimiento DATE          NULL,
    es_renovacion     BIT           NULL,
    fecha_proceso     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_stg_renovacion_lineas PRIMARY KEY (fecha_corte, id_propuesta, id_linea)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_stg_renovacion_lineas_archivo')
CREATE INDEX IX_stg_renovacion_lineas_archivo ON stg.renovacion_lineas (id_archivo);
GO

------------------------------------------------------------------------
-- Tablas stg de bases (última versión de cada llave)
------------------------------------------------------------------------
IF OBJECT_ID('stg.banca') IS NULL
CREATE TABLE stg.banca (
    cod_banca    CHAR(3)      NOT NULL PRIMARY KEY,
    nombre_banca NVARCHAR(50) NULL
);
GO

IF OBJECT_ID('stg.grupo_economico') IS NULL
CREATE TABLE stg.grupo_economico (
    cod_grupo_economico VARCHAR(6)    NOT NULL PRIMARY KEY,
    nombre_grupo        NVARCHAR(150) NULL,
    sector              NVARCHAR(80)  NULL
);
GO

IF OBJECT_ID('stg.cliente') IS NULL
CREATE TABLE stg.cliente (
    cod_cliente         CHAR(8)       NOT NULL PRIMARY KEY,
    razon_social        NVARCHAR(200) NULL,
    ruc                 CHAR(11)      NULL,
    segmento            NVARCHAR(50)  NULL,
    cod_banca           CHAR(3)       NULL,
    cod_grupo_economico VARCHAR(6)    NULL,
    fecha_alta          DATE          NULL
);
GO

IF OBJECT_ID('stg.propuesta') IS NULL
CREATE TABLE stg.propuesta (
    id_propuesta        INT           NOT NULL PRIMARY KEY,
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

IF OBJECT_ID('stg.propuesta_linea') IS NULL
CREATE TABLE stg.propuesta_linea (
    id_propuesta      INT           NOT NULL,
    id_linea          INT           NOT NULL,
    tipo_linea        NVARCHAR(60)  NULL,
    moneda            CHAR(3)       NULL,
    monto             DECIMAL(18,2) NULL,
    plazo_meses       INT           NULL,
    fecha_vencimiento DATE          NULL,
    CONSTRAINT PK_stg_propuesta_linea PRIMARY KEY (id_propuesta, id_linea)
);
GO

IF OBJECT_ID('stg.garantia') IS NULL
CREATE TABLE stg.garantia (
    id_propuesta      INT           NOT NULL,
    id_garantia       INT           NOT NULL,
    tipo_garantia     NVARCHAR(60)  NULL,
    moneda            CHAR(3)       NULL,
    valor_comercial   DECIMAL(18,2) NULL,
    valor_realizacion DECIMAL(18,2) NULL,
    cobertura_pct     DECIMAL(7,2)  NULL,
    CONSTRAINT PK_stg_garantia PRIMARY KEY (id_propuesta, id_garantia)
);
GO

IF OBJECT_ID('stg.riesgo_cliente') IS NULL
CREATE TABLE stg.riesgo_cliente (
    fecha_corte       DATE          NOT NULL,
    cod_cliente       CHAR(8)       NOT NULL,
    deuda_directa     DECIMAL(18,2) NULL,
    deuda_indirecta   DECIMAL(18,2) NULL,
    clasificacion     VARCHAR(3)    NULL,
    lineas_utilizadas DECIMAL(18,2) NULL,
    CONSTRAINT PK_stg_riesgo_cliente PRIMARY KEY (fecha_corte, cod_cliente)
);
GO

IF OBJECT_ID('stg.riesgo_grupo') IS NULL
CREATE TABLE stg.riesgo_grupo (
    fecha_corte         DATE          NOT NULL,
    cod_grupo_economico VARCHAR(6)    NOT NULL,
    exposicion_total    DECIMAL(18,2) NULL,
    limite_grupo        DECIMAL(18,2) NULL,
    CONSTRAINT PK_stg_riesgo_grupo PRIMARY KEY (fecha_corte, cod_grupo_economico)
);
GO

IF OBJECT_ID('stg.analista') IS NULL
CREATE TABLE stg.analista (
    cod_analista VARCHAR(6)    NOT NULL PRIMARY KEY,
    nombre       NVARCHAR(100) NULL,
    equipo       NVARCHAR(50)  NULL,
    activo       BIT           NULL
);
GO

-- Asignación vigente: la más reciente de cada propuesta
IF OBJECT_ID('stg.asignacion_propuesta') IS NULL
CREATE TABLE stg.asignacion_propuesta (
    id_propuesta     INT         NOT NULL PRIMARY KEY,
    cod_analista     VARCHAR(6)  NULL,
    fecha_asignacion DATE        NULL,
    prioridad        VARCHAR(10) NULL
);
GO

------------------------------------------------------------------------
-- Procedimientos: archivos
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE stg.sp_consultas_propuesta @reprocesar_todo BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT;
    DECLARE @pendientes TABLE (fecha_corte DATE PRIMARY KEY, id_archivo INT NOT NULL);

    INSERT @pendientes (fecha_corte, id_archivo)
    SELECT a.fecha_corte, a.id_archivo
    FROM ctl.archivo_cargado a
    WHERE a.cod_fuente = 'consultas_propuesta' AND a.estado = 'CARGADO'
      AND (@reprocesar_todo = 1
           OR NOT EXISTS (SELECT 1 FROM stg.consultas_propuesta s WHERE s.id_archivo = a.id_archivo));

    BEGIN TRAN;
    DELETE s FROM stg.consultas_propuesta s JOIN @pendientes p ON p.fecha_corte = s.fecha_corte;

    WITH tipado AS (
        SELECT r.id_archivo, r.fecha_corte, r.nro_fila,
               TRY_CAST(stg.fn_texto(r.id_propuesta) AS INT)  AS id_propuesta,
               TRY_CAST(stg.fn_texto(r.nro_consulta) AS INT)  AS nro_consulta,
               TRY_CAST(stg.fn_texto(r.ronda) AS INT)         AS ronda,
               stg.fn_fecha(r.fecha_pregunta)                  AS fecha_pregunta,
               stg.fn_texto(r.pregunta)                        AS pregunta,
               stg.fn_fecha(r.fecha_respuesta)                 AS fecha_respuesta,
               stg.fn_texto(r.respuesta)                       AS respuesta,
               UPPER(stg.fn_texto(r.estado))                   AS estado
        FROM raw.arch_consultas_propuesta r
        JOIN @pendientes p ON p.id_archivo = r.id_archivo
    ), unico AS (
        -- Filas repetidas en el mismo archivo: se conserva la primera
        SELECT *, ROW_NUMBER() OVER (PARTITION BY fecha_corte, id_propuesta, nro_consulta ORDER BY nro_fila) AS rn
        FROM tipado
        WHERE id_propuesta IS NOT NULL AND nro_consulta IS NOT NULL
    )
    INSERT stg.consultas_propuesta (id_archivo, fecha_corte, id_propuesta, nro_consulta, ronda, fecha_pregunta,
                                    pregunta, fecha_respuesta, respuesta, estado)
    SELECT id_archivo, fecha_corte, id_propuesta, nro_consulta, ronda, fecha_pregunta,
           pregunta, fecha_respuesta, respuesta, estado
    FROM unico WHERE rn = 1;
    SET @filas = @@ROWCOUNT;
    COMMIT;

    SELECT @filas AS filas;
END;
GO

CREATE OR ALTER PROCEDURE stg.sp_rating_cliente @reprocesar_todo BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT;
    DECLARE @pendientes TABLE (fecha_corte DATE PRIMARY KEY, id_archivo INT NOT NULL);

    INSERT @pendientes (fecha_corte, id_archivo)
    SELECT a.fecha_corte, a.id_archivo
    FROM ctl.archivo_cargado a
    WHERE a.cod_fuente = 'rating_cliente' AND a.estado = 'CARGADO'
      AND (@reprocesar_todo = 1
           OR NOT EXISTS (SELECT 1 FROM stg.rating_cliente s WHERE s.id_archivo = a.id_archivo));

    BEGIN TRAN;
    DELETE s FROM stg.rating_cliente s JOIN @pendientes p ON p.fecha_corte = s.fecha_corte;

    WITH tipado AS (
        SELECT r.id_archivo, r.fecha_corte, r.nro_fila,
               stg.fn_cod_cliente(r.cod_cliente)  AS cod_cliente,   -- recupera los ceros a la izquierda
               UPPER(stg.fn_texto(r.rating))      AS rating,
               UPPER(stg.fn_texto(r.modelo_rating)) AS modelo_rating,
               stg.fn_fecha(r.fecha_rating)       AS fecha_rating
        FROM raw.arch_rating_cliente r
        JOIN @pendientes p ON p.id_archivo = r.id_archivo
    ), unico AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY fecha_corte, cod_cliente ORDER BY nro_fila) AS rn
        FROM tipado
        WHERE cod_cliente IS NOT NULL
    )
    INSERT stg.rating_cliente (id_archivo, fecha_corte, cod_cliente, rating, modelo_rating, fecha_rating)
    SELECT id_archivo, fecha_corte, cod_cliente, rating, modelo_rating, fecha_rating
    FROM unico WHERE rn = 1;
    SET @filas = @@ROWCOUNT;
    COMMIT;

    SELECT @filas AS filas;
END;
GO

CREATE OR ALTER PROCEDURE stg.sp_renovacion_lineas @reprocesar_todo BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT;
    DECLARE @pendientes TABLE (fecha_corte DATE PRIMARY KEY, id_archivo INT NOT NULL);

    INSERT @pendientes (fecha_corte, id_archivo)
    SELECT a.fecha_corte, a.id_archivo
    FROM ctl.archivo_cargado a
    WHERE a.cod_fuente = 'renovacion_lineas' AND a.estado = 'CARGADO'
      AND (@reprocesar_todo = 1
           OR NOT EXISTS (SELECT 1 FROM stg.renovacion_lineas s WHERE s.id_archivo = a.id_archivo));

    BEGIN TRAN;
    DELETE s FROM stg.renovacion_lineas s JOIN @pendientes p ON p.fecha_corte = s.fecha_corte;

    WITH tipado AS (
        SELECT r.id_archivo, r.fecha_corte, r.nro_fila,
               TRY_CAST(stg.fn_texto(r.id_propuesta) AS INT) AS id_propuesta,
               TRY_CAST(stg.fn_texto(r.id_linea) AS INT)     AS id_linea,
               stg.fn_texto(r.tipo_linea)                     AS tipo_linea,
               stg.fn_decimal(r.monto)                        AS monto,          -- coma decimal
               TRY_CAST(stg.fn_texto(r.plazo_meses) AS INT)  AS plazo_meses,
               stg.fn_fecha(r.fecha_vencimiento)              AS fecha_vencimiento,
               stg.fn_si_no(r.es_renovacion)                  AS es_renovacion
        FROM raw.arch_renovacion_lineas r
        JOIN @pendientes p ON p.id_archivo = r.id_archivo
    ), unico AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY fecha_corte, id_propuesta, id_linea ORDER BY nro_fila) AS rn
        FROM tipado
        WHERE id_propuesta IS NOT NULL AND id_linea IS NOT NULL
    )
    INSERT stg.renovacion_lineas (id_archivo, fecha_corte, id_propuesta, id_linea, tipo_linea, monto,
                                  plazo_meses, fecha_vencimiento, es_renovacion)
    SELECT id_archivo, fecha_corte, id_propuesta, id_linea, tipo_linea, monto,
           plazo_meses, fecha_vencimiento, es_renovacion
    FROM unico WHERE rn = 1;
    SET @filas = @@ROWCOUNT;
    COMMIT;

    SELECT @filas AS filas;
END;
GO

------------------------------------------------------------------------
-- Procedimiento: bases (reconstrucción completa, última versión por llave)
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE stg.sp_bases
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT = 0;
    BEGIN TRAN;

    TRUNCATE TABLE stg.banca;
    INSERT stg.banca (cod_banca, nombre_banca)
    SELECT cod_banca, nombre_banca FROM (
        SELECT UPPER(stg.fn_texto(cod_banca)) AS cod_banca, stg.fn_texto(nombre_banca) AS nombre_banca,
               ROW_NUMBER() OVER (PARTITION BY UPPER(stg.fn_texto(cod_banca)) ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_banca) x
    WHERE rn = 1 AND cod_banca IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.grupo_economico;
    INSERT stg.grupo_economico (cod_grupo_economico, nombre_grupo, sector)
    SELECT cod_grupo_economico, nombre_grupo, sector FROM (
        SELECT UPPER(stg.fn_texto(cod_grupo_economico)) AS cod_grupo_economico,
               stg.fn_texto(nombre_grupo) AS nombre_grupo, stg.fn_texto(sector) AS sector,
               ROW_NUMBER() OVER (PARTITION BY UPPER(stg.fn_texto(cod_grupo_economico)) ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_grupo_economico) x
    WHERE rn = 1 AND cod_grupo_economico IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.cliente;
    INSERT stg.cliente (cod_cliente, razon_social, ruc, segmento, cod_banca, cod_grupo_economico, fecha_alta)
    SELECT cod_cliente, razon_social, ruc, segmento, cod_banca, cod_grupo_economico, fecha_alta FROM (
        SELECT stg.fn_cod_cliente(cod_cliente) AS cod_cliente, stg.fn_texto(razon_social) AS razon_social,
               stg.fn_texto(ruc) AS ruc, stg.fn_texto(segmento) AS segmento,
               UPPER(stg.fn_texto(cod_banca)) AS cod_banca,
               UPPER(stg.fn_texto(cod_grupo_economico)) AS cod_grupo_economico, fecha_alta,
               ROW_NUMBER() OVER (PARTITION BY stg.fn_cod_cliente(cod_cliente) ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_cliente) x
    WHERE rn = 1 AND cod_cliente IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    -- raw.dwh_propuesta es incremental: guarda versiones; se toma la última actualización
    TRUNCATE TABLE stg.propuesta;
    INSERT stg.propuesta (id_propuesta, cod_cliente, cod_banca, tipo_propuesta, fecha_ingreso, fecha_resolucion,
                          estado, moneda, monto_solicitado, monto_aprobado, fecha_actualizacion)
    SELECT id_propuesta, cod_cliente, cod_banca, tipo_propuesta, fecha_ingreso, fecha_resolucion,
           estado, moneda, monto_solicitado, monto_aprobado, fecha_actualizacion FROM (
        SELECT id_propuesta, stg.fn_cod_cliente(cod_cliente) AS cod_cliente, UPPER(stg.fn_texto(cod_banca)) AS cod_banca,
               UPPER(stg.fn_texto(tipo_propuesta)) AS tipo_propuesta, fecha_ingreso, fecha_resolucion,
               UPPER(stg.fn_texto(estado)) AS estado, UPPER(stg.fn_texto(moneda)) AS moneda,
               monto_solicitado, monto_aprobado, fecha_actualizacion,
               ROW_NUMBER() OVER (PARTITION BY id_propuesta ORDER BY fecha_actualizacion DESC, id_ejecucion DESC) AS rn
        FROM raw.dwh_propuesta) x
    WHERE rn = 1 AND id_propuesta IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.propuesta_linea;
    INSERT stg.propuesta_linea (id_propuesta, id_linea, tipo_linea, moneda, monto, plazo_meses, fecha_vencimiento)
    SELECT id_propuesta, id_linea, tipo_linea, moneda, monto, plazo_meses, fecha_vencimiento FROM (
        SELECT id_propuesta, id_linea, stg.fn_texto(tipo_linea) AS tipo_linea, UPPER(stg.fn_texto(moneda)) AS moneda,
               monto, plazo_meses, fecha_vencimiento,
               ROW_NUMBER() OVER (PARTITION BY id_propuesta, id_linea ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_propuesta_linea) x
    WHERE rn = 1 AND id_propuesta IS NOT NULL AND id_linea IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.garantia;
    INSERT stg.garantia (id_propuesta, id_garantia, tipo_garantia, moneda, valor_comercial, valor_realizacion, cobertura_pct)
    SELECT id_propuesta, id_garantia, tipo_garantia, moneda, valor_comercial, valor_realizacion, cobertura_pct FROM (
        SELECT id_propuesta, id_garantia, stg.fn_texto(tipo_garantia) AS tipo_garantia,
               UPPER(stg.fn_texto(moneda)) AS moneda, valor_comercial, valor_realizacion, cobertura_pct,
               ROW_NUMBER() OVER (PARTITION BY id_propuesta, id_garantia ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_garantia) x
    WHERE rn = 1 AND id_propuesta IS NOT NULL AND id_garantia IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.riesgo_cliente;
    INSERT stg.riesgo_cliente (fecha_corte, cod_cliente, deuda_directa, deuda_indirecta, clasificacion, lineas_utilizadas)
    SELECT fecha_corte, cod_cliente, deuda_directa, deuda_indirecta, clasificacion, lineas_utilizadas FROM (
        SELECT fecha_corte, stg.fn_cod_cliente(cod_cliente) AS cod_cliente, deuda_directa, deuda_indirecta,
               UPPER(stg.fn_texto(clasificacion)) AS clasificacion, lineas_utilizadas,
               ROW_NUMBER() OVER (PARTITION BY fecha_corte, stg.fn_cod_cliente(cod_cliente) ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_riesgo_cliente) x
    WHERE rn = 1 AND fecha_corte IS NOT NULL AND cod_cliente IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.riesgo_grupo;
    INSERT stg.riesgo_grupo (fecha_corte, cod_grupo_economico, exposicion_total, limite_grupo)
    SELECT fecha_corte, cod_grupo_economico, exposicion_total, limite_grupo FROM (
        SELECT fecha_corte, UPPER(stg.fn_texto(cod_grupo_economico)) AS cod_grupo_economico,
               exposicion_total, limite_grupo,
               ROW_NUMBER() OVER (PARTITION BY fecha_corte, UPPER(stg.fn_texto(cod_grupo_economico))
                                  ORDER BY id_ejecucion DESC) AS rn
        FROM raw.dwh_riesgo_grupo) x
    WHERE rn = 1 AND fecha_corte IS NOT NULL AND cod_grupo_economico IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.analista;
    INSERT stg.analista (cod_analista, nombre, equipo, activo)
    SELECT cod_analista, nombre, equipo, activo FROM (
        SELECT UPPER(stg.fn_texto(cod_analista)) AS cod_analista, stg.fn_texto(nombre) AS nombre,
               stg.fn_texto(equipo) AS equipo, activo,
               ROW_NUMBER() OVER (PARTITION BY UPPER(stg.fn_texto(cod_analista)) ORDER BY id_ejecucion DESC) AS rn
        FROM raw.loc_analista) x
    WHERE rn = 1 AND cod_analista IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    TRUNCATE TABLE stg.asignacion_propuesta;
    INSERT stg.asignacion_propuesta (id_propuesta, cod_analista, fecha_asignacion, prioridad)
    SELECT id_propuesta, cod_analista, fecha_asignacion, prioridad FROM (
        SELECT id_propuesta, UPPER(stg.fn_texto(cod_analista)) AS cod_analista, fecha_asignacion,
               UPPER(stg.fn_texto(prioridad)) AS prioridad,
               ROW_NUMBER() OVER (PARTITION BY id_propuesta ORDER BY fecha_asignacion DESC, id_asignacion DESC) AS rn
        FROM raw.loc_asignacion_propuesta) x
    WHERE rn = 1 AND id_propuesta IS NOT NULL;
    SET @filas += @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO
