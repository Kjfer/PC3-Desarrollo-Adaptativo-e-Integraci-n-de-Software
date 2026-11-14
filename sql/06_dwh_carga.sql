-- 06 · Carga de stg a dwh con MERGE
-- Dimensiones y hechos de propuesta: inserta lo nuevo y actualiza solo lo que cambió (SCD tipo 1).
-- Fotos diarias: se cargan por fecha de corte. Para el rating, cada fecha con archivo vigente queda
--   exactamente igual a stg (incluye borrar clientes que ya no vienen si el archivo se recargó).
-- Cada procedimiento devuelve una fila con las filas afectadas (columna filas).

USE ARC_INTEGRADO;
GO

------------------------------------------------------------------------
-- Dimensiones
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dwh.sp_dimensiones
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT = 0;
    BEGIN TRAN;

    -- Calendario: agrega los días que falten en el rango
    DECLARE @ini DATE = '20240101', @fin DATE = '20311231';
    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @ini, @fin) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    )
    INSERT dwh.dim_fecha (fecha, anio, mes, dia, nombre_mes, dia_semana, nombre_dia, es_dia_habil)
    SELECT d.fecha, YEAR(d.fecha), MONTH(d.fecha), DAY(d.fecha),
           CHOOSE(MONTH(d.fecha), N'enero', N'febrero', N'marzo', N'abril', N'mayo', N'junio', N'julio',
                  N'agosto', N'septiembre', N'octubre', N'noviembre', N'diciembre'),
           s.dia_semana,
           CHOOSE(s.dia_semana, N'lunes', N'martes', N'miércoles', N'jueves', N'viernes', N'sábado', N'domingo'),
           CASE WHEN s.dia_semana <= 5 THEN 1 ELSE 0 END
    FROM n
    CROSS APPLY (SELECT DATEADD(DAY, n.i, @ini) AS fecha) d
    CROSS APPLY (SELECT DATEDIFF(DAY, '19000101', d.fecha) % 7 + 1 AS dia_semana) s  -- 01/01/1900 fue lunes
    WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_fecha f WHERE f.fecha = d.fecha);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.dim_banca AS t
    USING stg.banca AS s ON t.cod_banca = s.cod_banca
    WHEN MATCHED AND EXISTS (SELECT s.nombre_banca EXCEPT SELECT t.nombre_banca)
        THEN UPDATE SET nombre_banca = s.nombre_banca, fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_banca, nombre_banca) VALUES (s.cod_banca, s.nombre_banca);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.dim_grupo_economico AS t
    USING stg.grupo_economico AS s ON t.cod_grupo_economico = s.cod_grupo_economico
    WHEN MATCHED AND EXISTS (SELECT s.nombre_grupo, s.sector EXCEPT SELECT t.nombre_grupo, t.sector)
        THEN UPDATE SET nombre_grupo = s.nombre_grupo, sector = s.sector, fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_grupo_economico, nombre_grupo, sector) VALUES (s.cod_grupo_economico, s.nombre_grupo, s.sector);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.dim_cliente AS t
    USING stg.cliente AS s ON t.cod_cliente = s.cod_cliente
    WHEN MATCHED AND EXISTS (SELECT s.razon_social, s.ruc, s.segmento, s.cod_banca, s.cod_grupo_economico, s.fecha_alta
                             EXCEPT
                             SELECT t.razon_social, t.ruc, t.segmento, t.cod_banca, t.cod_grupo_economico, t.fecha_alta)
        THEN UPDATE SET razon_social = s.razon_social, ruc = s.ruc, segmento = s.segmento, cod_banca = s.cod_banca,
                        cod_grupo_economico = s.cod_grupo_economico, fecha_alta = s.fecha_alta,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_cliente, razon_social, ruc, segmento, cod_banca, cod_grupo_economico, fecha_alta)
             VALUES (s.cod_cliente, s.razon_social, s.ruc, s.segmento, s.cod_banca, s.cod_grupo_economico, s.fecha_alta);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.dim_analista AS t
    USING stg.analista AS s ON t.cod_analista = s.cod_analista
    WHEN MATCHED AND EXISTS (SELECT s.nombre, s.equipo, s.activo EXCEPT SELECT t.nombre, t.equipo, t.activo)
        THEN UPDATE SET nombre = s.nombre, equipo = s.equipo, activo = s.activo, fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_analista, nombre, equipo, activo) VALUES (s.cod_analista, s.nombre, s.equipo, s.activo);
    SET @filas += @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO

------------------------------------------------------------------------
-- Propuesta, líneas y garantías
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dwh.sp_fact_propuesta
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT = 0;
    BEGIN TRAN;

    -- DWH (propuesta) + base local (asignación vigente)
    MERGE dwh.fact_propuesta AS t
    USING (
        SELECT p.id_propuesta, p.cod_cliente, p.cod_banca, a.cod_analista, p.tipo_propuesta, p.fecha_ingreso,
               a.fecha_asignacion, p.fecha_resolucion, p.estado, a.prioridad, p.moneda,
               p.monto_solicitado, p.monto_aprobado, p.fecha_actualizacion
        FROM stg.propuesta p
        LEFT JOIN stg.asignacion_propuesta a ON a.id_propuesta = p.id_propuesta
    ) AS s ON t.id_propuesta = s.id_propuesta
    WHEN MATCHED AND EXISTS (
            SELECT s.cod_cliente, s.cod_banca, s.cod_analista, s.tipo_propuesta, s.fecha_ingreso, s.fecha_asignacion,
                   s.fecha_resolucion, s.estado, s.prioridad, s.moneda, s.monto_solicitado, s.monto_aprobado,
                   s.fecha_actualizacion
            EXCEPT
            SELECT t.cod_cliente, t.cod_banca, t.cod_analista, t.tipo_propuesta, t.fecha_ingreso, t.fecha_asignacion,
                   t.fecha_resolucion, t.estado, t.prioridad, t.moneda, t.monto_solicitado, t.monto_aprobado,
                   t.fecha_actualizacion)
        THEN UPDATE SET cod_cliente = s.cod_cliente, cod_banca = s.cod_banca, cod_analista = s.cod_analista,
                        tipo_propuesta = s.tipo_propuesta, fecha_ingreso = s.fecha_ingreso,
                        fecha_asignacion = s.fecha_asignacion, fecha_resolucion = s.fecha_resolucion,
                        estado = s.estado, prioridad = s.prioridad, moneda = s.moneda,
                        monto_solicitado = s.monto_solicitado, monto_aprobado = s.monto_aprobado,
                        fecha_actualizacion = s.fecha_actualizacion, fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_propuesta, cod_cliente, cod_banca, cod_analista, tipo_propuesta, fecha_ingreso, fecha_asignacion,
                     fecha_resolucion, estado, prioridad, moneda, monto_solicitado, monto_aprobado, fecha_actualizacion)
             VALUES (s.id_propuesta, s.cod_cliente, s.cod_banca, s.cod_analista, s.tipo_propuesta, s.fecha_ingreso,
                     s.fecha_asignacion, s.fecha_resolucion, s.estado, s.prioridad, s.moneda, s.monto_solicitado,
                     s.monto_aprobado, s.fecha_actualizacion);
    SET @filas += @@ROWCOUNT;

    -- DWH (línea) + archivo de renovaciones (indicador del archivo más reciente que trae la línea)
    MERGE dwh.fact_propuesta_linea AS t
    USING (
        SELECT l.id_propuesta, l.id_linea, l.tipo_linea, l.moneda, l.monto, l.plazo_meses, l.fecha_vencimiento,
               r.es_renovacion, r.fecha_corte AS fecha_corte_renovacion
        FROM stg.propuesta_linea l
        OUTER APPLY (SELECT TOP 1 rv.es_renovacion, rv.fecha_corte
                     FROM stg.renovacion_lineas rv
                     WHERE rv.id_propuesta = l.id_propuesta AND rv.id_linea = l.id_linea
                     ORDER BY rv.fecha_corte DESC) r
    ) AS s ON t.id_propuesta = s.id_propuesta AND t.id_linea = s.id_linea
    WHEN MATCHED AND EXISTS (
            SELECT s.tipo_linea, s.moneda, s.monto, s.plazo_meses, s.fecha_vencimiento, s.es_renovacion, s.fecha_corte_renovacion
            EXCEPT
            SELECT t.tipo_linea, t.moneda, t.monto, t.plazo_meses, t.fecha_vencimiento, t.es_renovacion, t.fecha_corte_renovacion)
        THEN UPDATE SET tipo_linea = s.tipo_linea, moneda = s.moneda, monto = s.monto, plazo_meses = s.plazo_meses,
                        fecha_vencimiento = s.fecha_vencimiento, es_renovacion = s.es_renovacion,
                        fecha_corte_renovacion = s.fecha_corte_renovacion, fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_propuesta, id_linea, tipo_linea, moneda, monto, plazo_meses, fecha_vencimiento,
                     es_renovacion, fecha_corte_renovacion)
             VALUES (s.id_propuesta, s.id_linea, s.tipo_linea, s.moneda, s.monto, s.plazo_meses, s.fecha_vencimiento,
                     s.es_renovacion, s.fecha_corte_renovacion);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.fact_garantia AS t
    USING stg.garantia AS s ON t.id_propuesta = s.id_propuesta AND t.id_garantia = s.id_garantia
    WHEN MATCHED AND EXISTS (
            SELECT s.tipo_garantia, s.moneda, s.valor_comercial, s.valor_realizacion, s.cobertura_pct
            EXCEPT
            SELECT t.tipo_garantia, t.moneda, t.valor_comercial, t.valor_realizacion, t.cobertura_pct)
        THEN UPDATE SET tipo_garantia = s.tipo_garantia, moneda = s.moneda, valor_comercial = s.valor_comercial,
                        valor_realizacion = s.valor_realizacion, cobertura_pct = s.cobertura_pct,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_propuesta, id_garantia, tipo_garantia, moneda, valor_comercial, valor_realizacion, cobertura_pct)
             VALUES (s.id_propuesta, s.id_garantia, s.tipo_garantia, s.moneda, s.valor_comercial,
                     s.valor_realizacion, s.cobertura_pct);
    SET @filas += @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO

------------------------------------------------------------------------
-- Consultas: estado del archivo más reciente en que aparece cada consulta; se borran las que ya
-- no aparecen en ningún archivo
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dwh.sp_fact_consulta
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT = 0;
    -- stg guarda la historia de todos los archivos: una consulta que ya no está en ninguno se borra de dwh
    -- (p. ej. una fila errónea que se corrigió recargando el archivo). Si stg está vacío no se toca nada.
    IF NOT EXISTS (SELECT 1 FROM stg.consultas_propuesta)
    BEGIN
        SELECT @filas AS filas;
        RETURN;
    END;
    BEGIN TRAN;

    MERGE dwh.fact_consulta AS t
    USING (
        SELECT id_propuesta, nro_consulta, ronda, fecha_pregunta, pregunta, fecha_respuesta, respuesta, estado,
               fecha_corte_primera, fecha_corte AS fecha_corte_ultima
        FROM (
            SELECT c.*,
                   ROW_NUMBER() OVER (PARTITION BY id_propuesta, nro_consulta ORDER BY fecha_corte DESC) AS rn,
                   MIN(fecha_corte) OVER (PARTITION BY id_propuesta, nro_consulta) AS fecha_corte_primera
            FROM stg.consultas_propuesta c) x
        WHERE rn = 1
    ) AS s ON t.id_propuesta = s.id_propuesta AND t.nro_consulta = s.nro_consulta
    WHEN MATCHED AND EXISTS (
            SELECT s.ronda, s.fecha_pregunta, s.pregunta, s.fecha_respuesta, s.respuesta, s.estado,
                   s.fecha_corte_primera, s.fecha_corte_ultima
            EXCEPT
            SELECT t.ronda, t.fecha_pregunta, t.pregunta, t.fecha_respuesta, t.respuesta, t.estado,
                   t.fecha_corte_primera, t.fecha_corte_ultima)
        THEN UPDATE SET ronda = s.ronda, fecha_pregunta = s.fecha_pregunta, pregunta = s.pregunta,
                        fecha_respuesta = s.fecha_respuesta, respuesta = s.respuesta, estado = s.estado,
                        fecha_corte_primera = s.fecha_corte_primera, fecha_corte_ultima = s.fecha_corte_ultima,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_propuesta, nro_consulta, ronda, fecha_pregunta, pregunta, fecha_respuesta, respuesta, estado,
                     fecha_corte_primera, fecha_corte_ultima)
             VALUES (s.id_propuesta, s.nro_consulta, s.ronda, s.fecha_pregunta, s.pregunta, s.fecha_respuesta,
                     s.respuesta, s.estado, s.fecha_corte_primera, s.fecha_corte_ultima)
    WHEN NOT MATCHED BY SOURCE
        THEN DELETE;
    SET @filas = @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO

------------------------------------------------------------------------
-- Rating: foto diaria por fecha de corte
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dwh.sp_fact_rating_cliente
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT;
    BEGIN TRAN;

    -- El destino se limita a las fechas con archivo vigente: así una fecha recargada queda igual a stg
    -- (también si el archivo nuevo viene vacío), y las demás fechas no se tocan.
    WITH destino AS (
        SELECT * FROM dwh.fact_rating_cliente
        WHERE fecha_corte IN (SELECT fecha_corte FROM ctl.archivo_cargado
                              WHERE cod_fuente = 'rating_cliente' AND estado = 'CARGADO')
    )
    MERGE destino AS t
    USING stg.rating_cliente AS s ON t.cod_cliente = s.cod_cliente AND t.fecha_corte = s.fecha_corte
    WHEN MATCHED AND EXISTS (SELECT s.rating, s.modelo_rating, s.fecha_rating
                             EXCEPT SELECT t.rating, t.modelo_rating, t.fecha_rating)
        THEN UPDATE SET rating = s.rating, modelo_rating = s.modelo_rating, fecha_rating = s.fecha_rating,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_cliente, fecha_corte, rating, modelo_rating, fecha_rating)
             VALUES (s.cod_cliente, s.fecha_corte, s.rating, s.modelo_rating, s.fecha_rating)
    WHEN NOT MATCHED BY SOURCE
        THEN DELETE;
    SET @filas = @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO

------------------------------------------------------------------------
-- Riesgo de cliente y de grupo: fotos diarias del DWH
------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dwh.sp_fact_riesgo
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @filas INT = 0;
    BEGIN TRAN;

    MERGE dwh.fact_riesgo_cliente AS t
    USING stg.riesgo_cliente AS s ON t.cod_cliente = s.cod_cliente AND t.fecha_corte = s.fecha_corte
    WHEN MATCHED AND EXISTS (SELECT s.deuda_directa, s.deuda_indirecta, s.clasificacion, s.lineas_utilizadas
                             EXCEPT SELECT t.deuda_directa, t.deuda_indirecta, t.clasificacion, t.lineas_utilizadas)
        THEN UPDATE SET deuda_directa = s.deuda_directa, deuda_indirecta = s.deuda_indirecta,
                        clasificacion = s.clasificacion, lineas_utilizadas = s.lineas_utilizadas,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_cliente, fecha_corte, deuda_directa, deuda_indirecta, clasificacion, lineas_utilizadas)
             VALUES (s.cod_cliente, s.fecha_corte, s.deuda_directa, s.deuda_indirecta, s.clasificacion, s.lineas_utilizadas);
    SET @filas += @@ROWCOUNT;

    MERGE dwh.fact_riesgo_grupo AS t
    USING stg.riesgo_grupo AS s ON t.cod_grupo_economico = s.cod_grupo_economico AND t.fecha_corte = s.fecha_corte
    WHEN MATCHED AND EXISTS (SELECT s.exposicion_total, s.limite_grupo EXCEPT SELECT t.exposicion_total, t.limite_grupo)
        THEN UPDATE SET exposicion_total = s.exposicion_total, limite_grupo = s.limite_grupo,
                        fecha_carga_dwh = SYSDATETIME()
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (cod_grupo_economico, fecha_corte, exposicion_total, limite_grupo)
             VALUES (s.cod_grupo_economico, s.fecha_corte, s.exposicion_total, s.limite_grupo);
    SET @filas += @@ROWCOUNT;

    COMMIT;
    SELECT @filas AS filas;
END;
GO
