#!/usr/bin/env python3
"""Replay current schema migration over the real 1.0.7/1.0.8 schemas.

The historical sources are read from immutable Git commits. Each legacy table
is populated across every historical column, the current idempotent DDL is
applied twice, and both row preservation and full current-column writability
are verified with SQLite's integrity checker.
"""

from __future__ import annotations

import re
import sqlite3
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CURRENT_STORE = ROOT / "entry/src/main/ets/services/CloudStore.ets"
HISTORICAL_RELEASES = {
    "1.0.7": "d2bc6c99826045aa544eb9f0cd9cc61a966ff106",
    "1.0.8-initial": "a3d47c464aefa3533d10a070f66de83e9b44ed20",
}
STORE_PATH = "entry/src/main/ets/services/CloudStore.ets"
CURRENT_SCHEMA_VERSION = 4


def git_source(commit: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"{commit}:{STORE_PATH}"],
        cwd=ROOT,
        text=True,
    )


def migration_body(source: str) -> str:
    start = source.index("private async createTables()")
    end_markers = (
        "private async migrateLegacyVncRecords()",
        "getRdbStore(): relationalStore.RdbStore | null",
    )
    ends = [source.find(marker, start) for marker in end_markers]
    valid_ends = [end for end in ends if end >= 0]
    if not valid_ends:
        raise AssertionError("createTables boundary not found")
    return source[start : min(valid_ends)]


def normalized_body(source: str) -> str:
    return migration_body(source).replace("${VNC_CLOUD_TABLE}", "vncrecordv2")


def create_statements(source: str) -> list[tuple[str, str]]:
    body = normalized_body(source)
    pattern = re.compile(
        r"CREATE TABLE IF NOT EXISTS\s+([A-Za-z0-9_]+)\s*\((.*?)\)\s*`",
        re.DOTALL,
    )
    return [
        (match.group(1).lower(), f"CREATE TABLE IF NOT EXISTS {match.group(1)} ({match.group(2)})")
        for match in pattern.finditer(body)
    ]


def table_columns_from_source(source: str) -> dict[str, list[tuple[str, str]]]:
    result: dict[str, list[tuple[str, str]]] = {}
    for table, statement in create_statements(source):
        body = statement[statement.index("(") + 1 : statement.rindex(")")]
        columns: list[tuple[str, str]] = []
        for item in body.split(","):
            match = re.match(
                r"\s*([A-Za-z0-9_]+)\s+(TEXT|INTEGER|REAL|BLOB)",
                item,
                re.IGNORECASE,
            )
            if match:
                columns.append((match.group(1).lower(), match.group(2).upper()))
        result[table] = columns
    return result


def ensure_columns(source: str) -> dict[str, list[tuple[str, str]]]:
    body = normalized_body(source)
    result: dict[str, list[tuple[str, str]]] = {}

    def add(table: str, definition: str) -> None:
        match = re.match(r"([A-Za-z0-9_]+)\s+(TEXT|INTEGER|REAL|BLOB)", definition)
        if not match:
            raise AssertionError(f"unsupported ensureColumn definition: {definition}")
        result.setdefault(table.lower(), []).append(
            (match.group(1).lower(), match.group(2).upper())
        )

    for table, definition in re.findall(
        r"ensureColumn\('([^']+)',\s*'([^']+)'\)", body
    ):
        add(table, definition)

    array_targets = {
        "hostKeyCols": "remotehosts",
        "rustDeskDirectCols": "remotehosts",
        "rustDeskProCols": "remotehosts",
    }
    for array_name, table in array_targets.items():
        match = re.search(
            rf"const {array_name}: string\[\] = \[(.*?)\];", body, re.DOTALL
        )
        if match is None:
            raise AssertionError(f"missing current migration array: {array_name}")
        for definition in re.findall(r"'([^']+)'", match.group(1)):
            add(table, definition)
    return result


def quote(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def apply_current_schema(connection: sqlite3.Connection, source: str) -> None:
    for _table, statement in create_statements(source):
        connection.execute(statement)
    for table, columns in ensure_columns(source).items():
        current = {
            row[1].lower() for row in connection.execute(f"PRAGMA table_info({quote(table)})")
        }
        for column, affinity in columns:
            if column not in current:
                connection.execute(
                    f"ALTER TABLE {quote(table)} ADD COLUMN {quote(column)} {affinity}"
                )
                current.add(column)
    connection.execute(f"PRAGMA user_version={CURRENT_SCHEMA_VERSION}")


def legacy_value(table: str, column: str, affinity: str) -> object:
    if affinity == "INTEGER":
        return 1700000000000 + len(table) * 100 + len(column)
    if affinity == "REAL":
        return 1.25
    if affinity == "BLOB":
        return sqlite3.Binary((table + ":" + column).encode())
    return f"legacy:{table}:{column}"


def row_values(table: str, columns: list[tuple[str, str]]) -> list[object]:
    values = [legacy_value(table, name, affinity) for name, affinity in columns]
    primary = next((index for index, item in enumerate(columns) if item[0] in ("id", "key")), 0)
    values[primary] = f"legacy-{table}-primary"
    return values


def insert_full_row(
    connection: sqlite3.Connection,
    table: str,
    columns: list[tuple[str, str]],
    values: list[object],
) -> None:
    names = ",".join(quote(name) for name, _affinity in columns)
    placeholders = ",".join("?" for _ in columns)
    connection.execute(
        f"INSERT INTO {quote(table)} ({names}) VALUES ({placeholders})", values
    )


def verify_release(label: str, commit: str, current_source: str) -> None:
    old_source = git_source(commit)
    old_schema = table_columns_from_source(old_source)
    current_schema = table_columns_from_source(current_source)
    ensured = ensure_columns(current_source)
    connection = sqlite3.connect(":memory:")
    snapshots: dict[str, tuple[list[tuple[str, str]], list[object]]] = {}
    try:
        for _table, statement in create_statements(old_source):
            connection.execute(statement)
        for table, columns in old_schema.items():
            values = row_values(table, columns)
            insert_full_row(connection, table, columns, values)
            snapshots[table] = (columns, values)

        for _attempt in range(2):
            apply_current_schema(connection, current_source)

        for table, (columns, expected) in snapshots.items():
            names = ",".join(quote(name) for name, _affinity in columns)
            actual = list(
                connection.execute(f"SELECT {names} FROM {quote(table)}")
            )
            if actual != [tuple(expected)]:
                raise AssertionError(f"{label}: legacy row changed in {table}")

        for table, columns in current_schema.items():
            if table in old_schema:
                old_names = {name for name, _affinity in old_schema[table]}
                missing = [name for name, _affinity in columns if name not in old_names]
                covered = {name for name, _affinity in ensured.get(table, [])}
                uncovered = [name for name in missing if name not in covered]
                if uncovered:
                    raise AssertionError(
                        f"{label}: current columns lack migration in {table}: {uncovered}"
                    )
            values = row_values("current-" + table, columns)
            insert_full_row(connection, table, columns, values)

        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if integrity != "ok" or version != CURRENT_SCHEMA_VERSION:
            raise AssertionError(
                f"{label}: integrity={integrity} schemaVersion={version}"
            )
        print(
            f"PASS {label} commit={commit[:10]} legacyTables={len(old_schema)} "
            f"currentTables={len(current_schema)} preservedRows={len(snapshots)} "
            f"schemaVersion={version}"
        )
    finally:
        connection.close()


def main() -> None:
    current_source = CURRENT_STORE.read_text(encoding="utf-8")
    for label, commit in HISTORICAL_RELEASES.items():
        verify_release(label, commit, current_source)


if __name__ == "__main__":
    main()
