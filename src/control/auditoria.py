"""Auditoría: escribe en ctl.log_ejecucion, ctl.log_paso y ctl.archivo_cargado."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime
from typing import Iterator

from sqlalchemy import text
from sqlalchemy.engine import Connection, Engine


def _corto(msg: str | None, n: int = 2000) -> str | None:
    return None if msg is None else msg[:n]


@dataclass
class Paso:
    """Lo que un paso informa al terminar. estado: OK, CON ERRORES (errores ya contados) o ERROR."""
    filas: int | None = None
    mensaje: str | None = None
    estado: str = "OK"


class Auditoria:
    def __init__(self, eng: Engine):
        self.eng = eng
        self.id_ejecucion: int | None = None
        self.errores = 0

    # -- corrida ---------------------------------------------------------------
    def iniciar(self, modo: str, parametros: str = "") -> int:
        with self.eng.begin() as cn:
            self.id_ejecucion = cn.execute(text(
                "INSERT INTO ctl.log_ejecucion (modo, parametros, estado) "
                "OUTPUT INSERTED.id_ejecucion VALUES (:modo, :param, 'EN CURSO')"),
                {"modo": modo, "param": parametros}).scalar_one()
        return self.id_ejecucion

    def finalizar(self, estado: str | None = None, mensaje: str | None = None) -> str:
        estado = estado or ("OK" if self.errores == 0 else "CON ERRORES")
        with self.eng.begin() as cn:
            cn.execute(text(
                "UPDATE ctl.log_ejecucion SET fin = SYSDATETIME(), estado = :e, mensaje = :m "
                "WHERE id_ejecucion = :id"), {"e": estado, "m": _corto(mensaje), "id": self.id_ejecucion})
        return estado

    @contextmanager
    def paso(self, paso: str, objeto: str | None = None) -> Iterator[Paso]:
        """Registra un paso en ctl.log_paso. Una excepción se registra como ERROR y NO detiene la
        corrida: el pipeline sigue con el siguiente paso."""
        p, inicio = Paso(), datetime.now()
        try:
            yield p
        except Exception as e:  # noqa: BLE001 - se audita y se continúa
            p.estado, p.mensaje = "ERROR", f"{type(e).__name__}: {e}"
            self.errores += 1
        with self.eng.begin() as cn:
            cn.execute(text(
                "INSERT INTO ctl.log_paso (id_ejecucion, paso, objeto, inicio, fin, filas, estado, mensaje) "
                "VALUES (:id, :paso, :obj, :ini, SYSDATETIME(), :filas, :estado, :msg)"),
                {"id": self.id_ejecucion, "paso": paso, "obj": objeto, "ini": inicio.replace(microsecond=0),
                 "filas": p.filas, "estado": p.estado, "msg": _corto(p.mensaje)})

    # -- archivos ----------------------------------------------------------------
    @staticmethod
    def hash_vigente(cn: Connection, cod_fuente: str, fecha_corte: date) -> str | None:
        """Hash de la carga vigente (estado CARGADO) de ese tipo de archivo y fecha, si existe."""
        return cn.execute(text(
            "SELECT hash_sha256 FROM ctl.archivo_cargado "
            "WHERE cod_fuente = :f AND fecha_corte = :d AND estado = 'CARGADO'"),
            {"f": cod_fuente, "d": fecha_corte}).scalar()

    @staticmethod
    def ya_registrado(cn: Connection, nombre: str, hash_sha256: str) -> bool:
        return cn.execute(text(
            "SELECT COUNT(*) FROM ctl.archivo_cargado WHERE nombre_archivo = :n AND hash_sha256 = :h"),
            {"n": nombre, "h": hash_sha256}).scalar_one() > 0

    @staticmethod
    def reemplazar_vigente(cn: Connection, cod_fuente: str, fecha_corte: date) -> int:
        return cn.execute(text(
            "UPDATE ctl.archivo_cargado SET estado = 'REEMPLAZADO' "
            "WHERE cod_fuente = :f AND fecha_corte = :d AND estado = 'CARGADO'"),
            {"f": cod_fuente, "d": fecha_corte}).rowcount

    def registrar_archivo(self, cn: Connection, archivo, estado: str, filas: int | None = None,
                          mensaje: str | None = None) -> int:
        """archivo: ingesta.descubrir_archivos.ArchivoDetectado. Devuelve id_archivo."""
        return cn.execute(text(
            "INSERT INTO ctl.archivo_cargado (id_ejecucion, nombre_archivo, cod_fuente, fecha_corte, "
            "hash_sha256, tamano_bytes, filas, estado, mensaje) OUTPUT INSERTED.id_archivo "
            "VALUES (:id, :nombre, :fuente, :fecha, :hash, :tam, :filas, :estado, :msg)"),
            {"id": self.id_ejecucion, "nombre": archivo.nombre_archivo, "fuente": archivo.cod_fuente,
             "fecha": archivo.fecha_corte, "hash": archivo.hash_sha256, "tam": archivo.tamano_bytes,
             "filas": filas, "estado": estado, "msg": _corto(mensaje)}).scalar_one()
