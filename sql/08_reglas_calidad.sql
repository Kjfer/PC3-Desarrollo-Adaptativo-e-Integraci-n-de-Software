-- 08 · Reglas de calidad sobre los datos (raw, stg y dwh) -> ctl.resultado_calidad
--
-- ctl.sp_reglas_calidad evalúa todas las reglas y guarda una fila por regla y tabla, también cuando
-- no falla nada (filas_fallan = 0), para que el reporte muestre que la regla se evaluó.
-- @fecha_corte acota las reglas de los archivos a esa fecha; las reglas del modelo integrado son globales.
-- Las reglas de archivos (faltantes, vacíos, con error, no reconocidos) están en src/calidad/validaciones.py.
-- Devuelve una fila: cantidad de reglas con hallazgos (columna filas).
--
-- Severidad: ERROR = se pierden datos (la fila no llega a stg); ALERTA = el dato llega, pero hay que revisarlo.

USE ARC_INTEGRADO;
GO

CREATE OR ALTER PROCEDURE ctl.sp_reglas_calidad @id_ejecucion INT, @fecha_corte DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (regla VARCHAR(80), tabla NVARCHAR(200), filas_fallan INT, severidad VARCHAR(10), detalle NVARCHAR(2000));

    ------------------------------------------------------------------------
    -- 1. Filas repetidas dentro del mismo archivo (stg conserva la primera)
    ------------------------------------------------------------------------
    WITH f AS (
        SELECT archivo_origen + N': ' + id_propuesta + N'/' + nro_consulta AS ej,
               ROW_NUMBER() OVER (PARTITION BY id_archivo, LTRIM(RTRIM(id_propuesta)), LTRIM(RTRIM(nro_consulta))
                                  ORDER BY nro_fila) AS rn
        FROM raw.arch_consultas_propuesta
        WHERE @fecha_corte IS NULL OR fecha_corte = @fecha_corte)
    INSERT @r SELECT 'DUPLICADO_EN_ARCHIVO', 'raw.arch_consultas_propuesta', COUNT(*), 'ALERTA',
                     N'Filas repetidas por id_propuesta/nro_consulta; en stg se conserva la primera.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f WHERE rn > 1 ORDER BY ej) t), N'')
              FROM f WHERE rn > 1;

    WITH f AS (
        SELECT archivo_origen + N': ' + cod_cliente AS ej,
               ROW_NUMBER() OVER (PARTITION BY id_archivo, stg.fn_cod_cliente(cod_cliente) ORDER BY nro_fila) AS rn
        FROM raw.arch_rating_cliente
        WHERE @fecha_corte IS NULL OR fecha_corte = @fecha_corte)
    INSERT @r SELECT 'DUPLICADO_EN_ARCHIVO', 'raw.arch_rating_cliente', COUNT(*), 'ALERTA',
                     N'Clientes repetidos en el mismo archivo; en stg se conserva el primero.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f WHERE rn > 1 ORDER BY ej) t), N'')
              FROM f WHERE rn > 1;

    WITH f AS (
        SELECT archivo_origen + N': ' + id_propuesta + N'/' + id_linea AS ej,
               ROW_NUMBER() OVER (PARTITION BY id_archivo, LTRIM(RTRIM(id_propuesta)), LTRIM(RTRIM(id_linea))
                                  ORDER BY nro_fila) AS rn
        FROM raw.arch_renovacion_lineas
        WHERE @fecha_corte IS NULL OR fecha_corte = @fecha_corte)
    INSERT @r SELECT 'DUPLICADO_EN_ARCHIVO', 'raw.arch_renovacion_lineas', COUNT(*), 'ALERTA',
                     N'Líneas repetidas en el mismo archivo; en stg se conserva la primera.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f WHERE rn > 1 ORDER BY ej) t), N'')
              FROM f WHERE rn > 1;

    ------------------------------------------------------------------------
    -- 2. Llaves que no se pueden interpretar: la fila no pasa a stg
    ------------------------------------------------------------------------
    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': "' + id_propuesta + N'/' + nro_consulta + N'"' AS ej
        FROM raw.arch_consultas_propuesta
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte)
          AND (TRY_CAST(stg.fn_texto(id_propuesta) AS INT) IS NULL OR TRY_CAST(stg.fn_texto(nro_consulta) AS INT) IS NULL))
    INSERT @r SELECT 'LLAVE_INVALIDA', 'raw.arch_consultas_propuesta', COUNT(*), 'ERROR',
                     N'id_propuesta o nro_consulta vacío o no numérico; la fila no pasa a stg.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': "' + cod_cliente + N'"' AS ej
        FROM raw.arch_rating_cliente
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte) AND stg.fn_cod_cliente(cod_cliente) IS NULL)
    INSERT @r SELECT 'LLAVE_INVALIDA', 'raw.arch_rating_cliente', COUNT(*), 'ERROR',
                     N'cod_cliente vacío, con letras o de más de 8 dígitos; la fila no pasa a stg.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': "' + id_propuesta + N'/' + id_linea + N'"' AS ej
        FROM raw.arch_renovacion_lineas
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte)
          AND (TRY_CAST(stg.fn_texto(id_propuesta) AS INT) IS NULL OR TRY_CAST(stg.fn_texto(id_linea) AS INT) IS NULL))
    INSERT @r SELECT 'LLAVE_INVALIDA', 'raw.arch_renovacion_lineas', COUNT(*), 'ERROR',
                     N'id_propuesta o id_linea vacío o no numérico; la fila no pasa a stg.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    ------------------------------------------------------------------------
    -- 3. Valores con contenido que stg no puede interpretar (quedan en NULL)
    ------------------------------------------------------------------------
    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': "'
               + CASE WHEN stg.fn_texto(fecha_pregunta) IS NOT NULL AND stg.fn_fecha(fecha_pregunta) IS NULL
                      THEN fecha_pregunta ELSE fecha_respuesta END + N'"' AS ej
        FROM raw.arch_consultas_propuesta
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte)
          AND ((stg.fn_texto(fecha_pregunta) IS NOT NULL AND stg.fn_fecha(fecha_pregunta) IS NULL)
            OR (stg.fn_texto(fecha_respuesta) IS NOT NULL AND stg.fn_fecha(fecha_respuesta) IS NULL)))
    INSERT @r SELECT 'VALOR_NO_INTERPRETABLE', 'raw.arch_consultas_propuesta', COUNT(*), 'ALERTA',
                     N'Fecha de pregunta o respuesta en un formato no reconocido; queda en NULL.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': "' + fecha_rating + N'"' AS ej
        FROM raw.arch_rating_cliente
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte)
          AND stg.fn_texto(fecha_rating) IS NOT NULL AND stg.fn_fecha(fecha_rating) IS NULL)
    INSERT @r SELECT 'VALOR_NO_INTERPRETABLE', 'raw.arch_rating_cliente', COUNT(*), 'ALERTA',
                     N'fecha_rating en un formato no reconocido; queda en NULL.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT archivo_origen + N' fila ' + CAST(nro_fila AS NVARCHAR(10)) + N': monto "' + monto
               + N'", vencimiento "' + fecha_vencimiento + N'", renovación "' + es_renovacion + N'"' AS ej
        FROM raw.arch_renovacion_lineas
        WHERE (@fecha_corte IS NULL OR fecha_corte = @fecha_corte)
          AND ((stg.fn_texto(monto) IS NOT NULL AND stg.fn_decimal(monto) IS NULL)
            OR (stg.fn_texto(fecha_vencimiento) IS NOT NULL AND stg.fn_fecha(fecha_vencimiento) IS NULL)
            OR (stg.fn_texto(es_renovacion) IS NOT NULL AND stg.fn_si_no(es_renovacion) IS NULL)))
    INSERT @r SELECT 'VALOR_NO_INTERPRETABLE', 'raw.arch_renovacion_lineas', COUNT(*), 'ALERTA',
                     N'Monto, fecha de vencimiento o indicador de renovación no interpretable; queda en NULL.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    ------------------------------------------------------------------------
    -- 4. Huérfanos: llaves que no cruzan entre fuentes
    ------------------------------------------------------------------------
    WITH f AS (
        SELECT CAST(p.id_propuesta AS NVARCHAR(20)) + N' -> cliente ' + p.cod_cliente AS ej
        FROM dwh.fact_propuesta p
        WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_cliente c WHERE c.cod_cliente = p.cod_cliente))
    INSERT @r SELECT 'HUERFANO', 'dwh.fact_propuesta', COUNT(*), 'ALERTA',
                     N'Propuestas cuyo cliente no existe en dim_cliente.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT CAST(q.id_propuesta AS NVARCHAR(20)) + N'/' + CAST(q.nro_consulta AS NVARCHAR(10)) AS ej
        FROM dwh.fact_consulta q
        WHERE NOT EXISTS (SELECT 1 FROM dwh.fact_propuesta p WHERE p.id_propuesta = q.id_propuesta))
    INSERT @r SELECT 'HUERFANO', 'dwh.fact_consulta', COUNT(*), 'ALERTA',
                     N'Consultas (archivo) de propuestas que no existen en el DWH.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT DISTINCT CAST(r.cod_cliente AS NVARCHAR(20)) AS ej   -- STRING_AGG no mezcla char con separador N''
        FROM dwh.fact_rating_cliente r
        WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_cliente c WHERE c.cod_cliente = r.cod_cliente))
    INSERT @r SELECT 'HUERFANO', 'dwh.fact_rating_cliente', COUNT(*), 'ALERTA',
                     N'Clientes del archivo de rating que no existen en dim_cliente (revisar normalización del código).'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT DISTINCT CAST(r.id_propuesta AS NVARCHAR(20)) + N'/' + CAST(r.id_linea AS NVARCHAR(20)) AS ej
        FROM stg.renovacion_lineas r
        WHERE (@fecha_corte IS NULL OR r.fecha_corte = @fecha_corte)
          AND NOT EXISTS (SELECT 1 FROM dwh.fact_propuesta_linea l
                          WHERE l.id_propuesta = r.id_propuesta AND l.id_linea = r.id_linea))
    INSERT @r SELECT 'HUERFANO', 'stg.renovacion_lineas', COUNT(*), 'ALERTA',
                     N'Líneas del archivo de renovaciones que no existen en el DWH.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT c.cod_cliente + N' -> grupo ' + c.cod_grupo_economico AS ej
        FROM dwh.dim_cliente c
        WHERE c.cod_grupo_economico IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dwh.dim_grupo_economico g WHERE g.cod_grupo_economico = c.cod_grupo_economico))
    INSERT @r SELECT 'HUERFANO', 'dwh.dim_cliente', COUNT(*), 'ALERTA',
                     N'Clientes con un grupo económico que no existe en dim_grupo_economico.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    ------------------------------------------------------------------------
    -- 5. Consistencia entre fuentes y del flujo de evaluación
    ------------------------------------------------------------------------
    WITH f AS (
        SELECT DISTINCT CAST(r.id_propuesta AS NVARCHAR(20)) + N'/' + CAST(r.id_linea AS NVARCHAR(20))
               + N': archivo ' + CAST(r.monto AS NVARCHAR(30)) + N' vs DWH ' + CAST(l.monto AS NVARCHAR(30)) AS ej
        FROM stg.renovacion_lineas r
        JOIN dwh.fact_propuesta_linea l ON l.id_propuesta = r.id_propuesta AND l.id_linea = r.id_linea
        WHERE (@fecha_corte IS NULL OR r.fecha_corte = @fecha_corte) AND r.monto <> l.monto)
    INSERT @r SELECT 'MONTO_DISTINTO_DWH', 'stg.renovacion_lineas', COUNT(*), 'ALERTA',
                     N'El monto de la línea en el archivo de renovaciones no coincide con el DWH.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT CAST(q.id_propuesta AS NVARCHAR(20)) + N'/' + CAST(q.nro_consulta AS NVARCHAR(10)) + N' ' + ISNULL(q.estado, N'?') AS ej
        FROM dwh.fact_consulta q
        WHERE (q.estado = 'RESPONDIDA' AND q.fecha_respuesta IS NULL)
           OR (q.estado = 'PENDIENTE' AND q.fecha_respuesta IS NOT NULL)
           OR q.fecha_respuesta < q.fecha_pregunta
           OR q.estado IS NULL OR q.estado NOT IN ('RESPONDIDA', 'PENDIENTE'))
    INSERT @r SELECT 'CONSULTA_INCONSISTENTE', 'dwh.fact_consulta', COUNT(*), 'ALERTA',
                     N'Estado de la consulta que no cuadra con sus fechas (respondida sin fecha, respuesta antes de la pregunta...).'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH f AS (
        SELECT CAST(p.id_propuesta AS NVARCHAR(20)) + N' (ingreso ' + CONVERT(NVARCHAR(10), p.fecha_ingreso, 103) + N')' AS ej
        FROM dwh.fact_propuesta p
        WHERE p.estado = 'EN EVALUACION' AND p.cod_analista IS NULL)
    INSERT @r SELECT 'PROPUESTA_SIN_ANALISTA', 'dwh.fact_propuesta', COUNT(*), 'ALERTA',
                     N'Propuestas en evaluación sin asignación en la base local.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    WITH ultimo AS (SELECT MAX(fecha_corte) AS fecha FROM dwh.fact_rating_cliente),
    f AS (
        SELECT CAST(p.id_propuesta AS NVARCHAR(20)) + N' cliente ' + p.cod_cliente AS ej
        FROM dwh.fact_propuesta p CROSS JOIN ultimo u
        WHERE p.estado = 'EN EVALUACION' AND u.fecha IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dwh.fact_rating_cliente r
                          WHERE r.cod_cliente = p.cod_cliente AND r.fecha_corte = u.fecha))
    INSERT @r SELECT 'PROPUESTA_SIN_RATING', 'dwh.fact_propuesta', COUNT(*), 'ALERTA',
                     N'Propuestas en evaluación cuyo cliente no aparece en el último archivo de rating.'
                     + ISNULL(N' Ej.: ' + (SELECT STRING_AGG(ej, N'; ') FROM (SELECT TOP 5 ej FROM f ORDER BY ej) t), N'')
              FROM f;

    INSERT ctl.resultado_calidad (id_ejecucion, regla, tabla, fecha_corte, filas_fallan, severidad, detalle)
    SELECT @id_ejecucion, regla, tabla,
           CASE WHEN tabla LIKE 'raw.arch%' OR tabla = 'stg.renovacion_lineas' THEN @fecha_corte END,
           filas_fallan, severidad, LEFT(detalle, 2000)
    FROM @r;

    SELECT COUNT(*) AS filas FROM @r WHERE filas_fallan > 0;
END;
GO

-- Reporte de calidad de la última corrida que evaluó reglas
CREATE OR ALTER VIEW ctl.vw_calidad_ultima_ejecucion
AS
SELECT r.id_ejecucion, e.inicio, e.modo, r.regla, r.tabla, r.fecha_corte, r.filas_fallan, r.severidad,
       CASE WHEN r.filas_fallan = 0 THEN 'OK' ELSE r.severidad END AS resultado, r.detalle
FROM ctl.resultado_calidad r
JOIN ctl.log_ejecucion e ON e.id_ejecucion = r.id_ejecucion
WHERE r.id_ejecucion = (SELECT MAX(id_ejecucion) FROM ctl.resultado_calidad);
GO
