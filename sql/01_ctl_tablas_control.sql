-- 01 · Tablas de control (esquema ctl): configuración, auditoría y calidad
-- Idempotente: crea cada objeto solo si no existe.

USE ARC_INTEGRADO;
GO

-- Configuración por metadatos: una fila por tipo de archivo o tabla de base de datos.
-- Se sincroniza desde config/fuentes.yaml al inicio de cada corrida.
IF OBJECT_ID('ctl.fuente_config') IS NULL
CREATE TABLE ctl.fuente_config (
    cod_fuente          VARCHAR(60)    NOT NULL PRIMARY KEY,  -- consultas_propuesta, dwh.propuesta, ...
    tipo_fuente         VARCHAR(10)    NOT NULL CHECK (tipo_fuente IN ('ARCHIVO', 'BD')),
    descripcion         NVARCHAR(200)  NULL,
    tabla_destino       NVARCHAR(200)  NOT NULL,              -- raw.<tabla>
    -- Solo archivos
    patron              NVARCHAR(200)  NULL,                  -- regex del nombre, con grupo (?P<fecha>ddmmaaaa)
    formato             VARCHAR(10)    NULL,                  -- csv, txt, xlsx
    separador           NVARCHAR(5)    NULL,
    encoding            VARCHAR(20)    NULL,
    hoja                NVARCHAR(100)  NULL,
    texto_encabezado    NVARCHAR(100)  NULL,                  -- Excel: texto de la 1.a celda del encabezado
    columnas_esperadas  NVARCHAR(1000) NULL,                  -- lista separada por comas
    frecuencia          VARCHAR(10)    NULL,                  -- DIARIA
    -- Solo bases de datos
    base_origen         SYSNAME        NULL,
    tabla_origen        NVARCHAR(200)  NULL,
    modo_carga          VARCHAR(12)    NULL CHECK (modo_carga IN ('COMPLETA', 'INCREMENTAL')),
    columna_marca_agua  SYSNAME        NULL,
    activo              BIT            NOT NULL DEFAULT 1,
    fecha_actualizacion DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

-- Una fila por corrida del pipeline
IF OBJECT_ID('ctl.log_ejecucion') IS NULL
CREATE TABLE ctl.log_ejecucion (
    id_ejecucion INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    modo         VARCHAR(20)    NOT NULL,                     -- DIARIO, FECHA
    parametros   NVARCHAR(400)  NULL,
    inicio       DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    fin          DATETIME2(0)   NULL,
    estado       VARCHAR(20)    NOT NULL,                     -- EN CURSO, OK, CON ERRORES, FALLIDA
    mensaje      NVARCHAR(2000) NULL
);
GO

-- Detalle de cada paso de una corrida (una tabla extraída, la ingesta de archivos, ...)
IF OBJECT_ID('ctl.log_paso') IS NULL
CREATE TABLE ctl.log_paso (
    id_paso      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_ejecucion INT            NOT NULL REFERENCES ctl.log_ejecucion (id_ejecucion),
    paso         VARCHAR(40)    NOT NULL,                     -- INGESTA_ARCHIVOS, EXTRACCION_BD
    objeto       NVARCHAR(260)  NULL,
    inicio       DATETIME2(0)   NOT NULL,
    fin          DATETIME2(0)   NULL,
    filas        INT            NULL,
    estado       VARCHAR(20)    NOT NULL,                     -- OK, ERROR
    mensaje      NVARCHAR(2000) NULL
);
GO

-- Una fila por archivo detectado y procesado (o rechazado)
IF OBJECT_ID('ctl.archivo_cargado') IS NULL
CREATE TABLE ctl.archivo_cargado (
    id_archivo     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_ejecucion   INT            NOT NULL REFERENCES ctl.log_ejecucion (id_ejecucion),
    nombre_archivo NVARCHAR(260)  NOT NULL,
    cod_fuente     VARCHAR(60)    NULL,                       -- NULL si el tipo no se reconoce
    fecha_corte    DATE           NULL,
    hash_sha256    CHAR(64)       NOT NULL,
    tamano_bytes   BIGINT         NOT NULL,
    filas          INT            NULL,
    estado         VARCHAR(20)    NOT NULL,                   -- CARGADO, REEMPLAZADO, ERROR, NO_RECONOCIDO
    mensaje        NVARCHAR(2000) NULL,
    fecha_registro DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

-- Garantiza una sola carga vigente por tipo de archivo y fecha de corte
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_archivo_cargado_vigente')
CREATE UNIQUE INDEX UX_archivo_cargado_vigente
    ON ctl.archivo_cargado (cod_fuente, fecha_corte) WHERE estado = 'CARGADO';
GO

-- Resultados de las reglas de calidad (se llena en la fase 4)
IF OBJECT_ID('ctl.resultado_calidad') IS NULL
CREATE TABLE ctl.resultado_calidad (
    id_resultado   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    id_ejecucion   INT            NULL REFERENCES ctl.log_ejecucion (id_ejecucion),
    regla          VARCHAR(80)    NOT NULL,
    tabla          NVARCHAR(200)  NOT NULL,
    fecha_corte    DATE           NULL,
    filas_fallan   INT            NOT NULL,
    severidad      VARCHAR(10)    NOT NULL,                   -- ALERTA, ERROR
    detalle        NVARCHAR(2000) NULL,
    fecha_registro DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO
