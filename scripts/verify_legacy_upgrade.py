#!/usr/bin/env python3
"""Replay current schema migration over the real 1.0.7/1.0.8 schemas.

The historical sources are read from immutable Git commits. Each legacy table
is populated across every historical column, the current idempotent DDL is
applied twice, and both row preservation and full current-column writability
are verified with SQLite's integrity checker.
"""

from __future__ import annotations

import json
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


def verify_device_local_personalization_upgrade(
    connection: sqlite3.Connection, label: str
) -> None:
    """Exercise the lossless old-row -> local override -> mixed-writer path."""
    host_id = f"compat-host-{label}"
    legacy_display = json.dumps(
        {
            "width": 1280,
            "height": 720,
            "multiMonitor": False,
            "monitorCount": 1,
            "dynamicResolution": True,
            "colorDepth": 32,
        },
        separators=(",", ":"),
    )
    connection.execute(
        """
        INSERT INTO remotehosts
          (id, userid, label, protocol, host, port, displayconfig,
           lastconnected, lasthealth, lastlatency)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            host_id,
            "legacy-owner",
            "Legacy host",
            "rdp",
            "192.0.2.10",
            3389,
            legacy_display,
            1700000000101,
            3,
            72,
        ),
    )
    # Reads need no migration row. The first current-version local save creates
    # an additive envelope without mutating any legacy cloud column.
    seeded = {
        "localpersonalizationversion": "1",
        "localdisplayconfig": legacy_display,
        "locallastconnected": "1700000000101",
        "locallasthealth": "3",
        "locallastlatency": "72",
        "localrustdeskadaptiveorientation": "0",
        "localrustdeskprolastseenat": "0",
        "localrustdeskprosyncerror": "",
    }
    connection.execute(
        """
        INSERT INTO localextensions (id, tablename, recordid, payload, updatedat)
        VALUES (?, 'remotehosts', ?, ?, 1)
        """,
        (f"remotehosts:{host_id}", host_id, json.dumps(seeded, sort_keys=True)),
    )
    # A Phone changes only its local display/health. A simultaneous cloud-base
    # rename must retain the old wire snapshot for 1.0.7/1.0.8 readers.
    phone = dict(seeded)
    phone["localdisplayconfig"] = json.dumps(
        {"width": 2340, "height": 1080}, separators=(",", ":")
    )
    phone["locallastlatency"] = "18"
    connection.execute(
        "UPDATE localextensions SET payload=?, updatedat=2 WHERE id=?",
        (json.dumps(phone, sort_keys=True), f"remotehosts:{host_id}"),
    )
    connection.execute(
        "UPDATE remotehosts SET label='Renamed host' WHERE id=?", (host_id,)
    )
    cloud_row = connection.execute(
        """
        SELECT label, displayconfig, lastconnected, lasthealth, lastlatency
        FROM remotehosts WHERE id=?
        """,
        (host_id,),
    ).fetchone()
    if cloud_row != (
        "Renamed host",
        legacy_display,
        1700000000101,
        3,
        72,
    ):
        raise AssertionError(f"{label}: new client rewrote legacy cloud personalization")

    # A still-installed old client may later update its legacy columns. The
    # established local envelope on this device must survive unchanged.
    old_writer_display = json.dumps(
        {"width": 1920, "height": 1080}, separators=(",", ":")
    )
    connection.execute(
        """
        UPDATE remotehosts
        SET displayconfig=?, lastconnected=?, lasthealth=?, lastlatency=?
        WHERE id=?
        """,
        (old_writer_display, 1700000000202, 2, 41, host_id),
    )
    persisted_phone = connection.execute(
        "SELECT payload FROM localextensions WHERE id=?",
        (f"remotehosts:{host_id}",),
    ).fetchone()[0]
    if json.loads(persisted_phone) != phone:
        raise AssertionError(f"{label}: old writer overwrote device-local personalization")

    # A second current client with no envelope starts from the latest compatible
    # wire value; no local row is required for login or table initialization.
    second_device_seed = connection.execute(
        "SELECT displayconfig, lastconnected, lasthealth, lastlatency "
        "FROM remotehosts WHERE id=?",
        (host_id,),
    ).fetchone()
    if second_device_seed != (old_writer_display, 1700000000202, 2, 41):
        raise AssertionError(f"{label}: second-device legacy fallback is not lossless")

    # VNC keeps its old host payload complete while a localmetadata envelope
    # owns device presentation. No cloud schema or extra distributed table is
    # needed for the override.
    vnc_id = f"compat-vnc-{label}"
    vnc_legacy = {
        "label": "Legacy VNC",
        "host": "192.0.2.20",
        "port": 5900,
        "username": "",
        "gatewayId": "",
        "transport": "direct_tcp",
        "repeaterMode": "mode12",
        "rememberPassword": False,
        "viewOnly": False,
        "displayOverrideEnabled": True,
        "scalingMode": "fit",
        "clipboardEnabled": True,
        "securityPolicy": "secure_only",
        "tls": True,
        "locked": False,
        "lockType": 0,
    }
    vnc_wire = json.dumps(vnc_legacy, separators=(",", ":"), sort_keys=True)
    connection.execute(
        """
        INSERT INTO vncrecordv2
          (id, userid, recordtype, ownerid, ownertype, payload,
           syncversion, schemaversion, createdat, updatedat, deletedat)
        VALUES (?, 'legacy-owner', 'host', 'legacy-owner', 'account', ?, 1, 1, 1, 1, 0)
        """,
        (vnc_id, vnc_wire),
    )
    vnc_local = json.dumps(
        {
            "version": 1,
            "rememberPassword": False,
            "viewOnly": True,
            "displayOverrideEnabled": True,
            "scalingMode": "pan",
            "clipboardEnabled": False,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    connection.execute(
        "INSERT INTO localmetadata (key, value, updatedat) VALUES (?, ?, 1)",
        (f"vnc_host_local_personalization_v1:{vnc_id}", vnc_local),
    )
    if connection.execute(
        "SELECT payload FROM vncrecordv2 WHERE id=?", (vnc_id,)
    ).fetchone()[0] != vnc_wire:
        raise AssertionError(f"{label}: VNC local override changed the legacy wire payload")


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

        verify_device_local_personalization_upgrade(connection, label)

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
            f"personalizationUpgrade=pass schemaVersion={version}"
        )
    finally:
        connection.close()


def main() -> None:
    current_source = CURRENT_STORE.read_text(encoding="utf-8")
    for label, commit in HISTORICAL_RELEASES.items():
        verify_release(label, commit, current_source)


if __name__ == "__main__":
    main()
