#!/bin/bash
set -euo pipefail

# -----------------------------
# 1: Konfiguration
# -----------------------------
PGDATA=${PGDATA:-/app/pgdata_test}
PGPORT=${PGPORT:-5433}
PGHOST=${PGHOST:-localhost}
PGUSER=${PGUSER:-postgres}
BACKUPDIR=${BACKUPDIR:-/app/pgbackup}
ARCHIVEDIR=${ARCHIVEDIR:-/app/pgwal}
DB=${DB:-testdb}
TABLE=${TABLE:-testtable}
PG_BIN=/usr/lib/postgresql/15/bin
RECOVERY_TIMEOUT=${RECOVERY_TIMEOUT:-60}
GPG_PASSWORD=${GPG_PASSWORD:-"MeinSicheresPasswort"}

# PostgreSQL Bin-Verzeichnis setzen
export PATH=$PG_BIN:$PATH

# -----------------------------
# 2: Cleanup vorheriger Test
# -----------------------------
echo "==> Starte Cleanup..."
{
    rm -rf "$PGDATA" "$BACKUPDIR" "$ARCHIVEDIR"
} 2>/dev/null || true
mkdir -p "$BACKUPDIR" "$ARCHIVEDIR"

# -----------------------------
# 3: PostgreSQL initialisieren
# -----------------------------
echo "==> Initialisiere PostgreSQL..."
initdb -D "$PGDATA" -U "$PGUSER" --locale=C
chmod 700 "$PGDATA"

# -----------------------------
# 4: TCP + Replikation erlauben
# -----------------------------
echo "==> Konfiguriere PostgreSQL..."
cat >>"$PGDATA/pg_hba.conf" <<EOF
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
EOF

cat >>"$PGDATA/postgresql.conf" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'test ! -f ${ARCHIVEDIR}/%f && cp %p ${ARCHIVEDIR}/%f'
listen_addresses = '*'
port = ${PGPORT}
max_connections = 100
EOF

# -----------------------------
# 5: PostgreSQL starten
# -----------------------------
echo "==> Starte PostgreSQL..."
pg_ctl -D "$PGDATA" -o "-p $PGPORT" -l "$PGDATA/postgres.log" -w start

# Warte auf PostgreSQL
sleep 3
echo "==> PostgreSQL läuft auf Port $PGPORT"

# -----------------------------
# 6: Testdatenbank + Tabelle erstellen
# -----------------------------
echo "==> Erstelle Datenbank und Tabelle..."
createdb -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" "$DB"

psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
CREATE TABLE $TABLE (id INT PRIMARY KEY, name TEXT);
EOF

# -----------------------------
# 7: 5 Datensätze vor Base Backup
# -----------------------------
echo "==> Füge Testdaten ein..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
INSERT INTO $TABLE VALUES
(1,'Alice'),(2,'Bob'),(3,'Carol'),(4,'Dave'),(5,'Eve');
EOF

echo "==> Tabelle vor Base Backup:"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE ORDER BY id;"

echo "==> Schalte WAL um..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 1

# -----------------------------
# 8: Base Backup erstellen + GPG verschlüsseln
# -----------------------------
echo "==> Erstelle Base Backup (Plain-Modus)..."
pg_basebackup -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -D "$BACKUPDIR/base" -Fp -Xs -P -c fast

echo "==> Packe Backup..."
tar -czf "$BACKUPDIR/base_backup.tar.gz" -C "$BACKUPDIR/base" .

echo "==> Verschlüssele Backup mit GPG..."
echo "$GPG_PASSWORD" | gpg --batch --yes --passphrase-fd 0 -c "$BACKUPDIR/base_backup.tar.gz"
BACKUP_FILE="$BACKUPDIR/base_backup.tar.gz.gpg"
echo "==> Base Backup fertig und verschlüsselt: $BACKUP_FILE"
ls -lh "$BACKUP_FILE"

# -----------------------------
# 9: 5 Datensätze nach Base Backup
# -----------------------------
echo "==> Füge weitere Datensätze hinzu..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
INSERT INTO $TABLE VALUES
(6,'Frank'),(7,'Grace'),(8,'Heidi'),(9,'Ivan'),(10,'Judy');
EOF

echo "==> Tabelle nach Base Backup, vor Desaster:"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE ORDER BY id;"

echo "==> Schalte WAL um..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 1

# -----------------------------
# 10: Recovery-Zeitpunkt festlegen + Desaster simulieren
# -----------------------------
TARGET_TIME=$(date +"%Y-%m-%d %H:%M:%S")
echo "Recovery-Zeitpunkt festgelegt: $TARGET_TIME"

echo "==> Simuliere Desaster (lösche Datensätze 1-8)..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" <<EOF
DELETE FROM $TABLE WHERE id <= 8;
EOF

echo "==> Tabelle nach Desaster:"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT * FROM $TABLE ORDER BY id;"

echo "==> Schalte finales WAL um..."
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -c "SELECT pg_switch_wal();"
sleep 1

# -----------------------------
# 11: Stoppen für Restore
# -----------------------------
echo "==> Stoppe PostgreSQL für Restore..."
pg_ctl -D "$PGDATA" -m fast -w stop

# -----------------------------
# 12: Restore: GPG entschlüsseln + tar entpacken
# -----------------------------
echo "==> Starte Restore..."
echo "$GPG_PASSWORD" | gpg --batch --yes --passphrase-fd 0 -d "$BACKUP_FILE" >"$BACKUPDIR/base_backup.tar.gz"

echo "==> Lösche alte PGDATA..."
rm -rf "${PGDATA:?}/"*

echo "==> Extrahiere Backup..."
tar -xzf "$BACKUPDIR/base_backup.tar.gz" -C "$PGDATA"
chmod -R 700 "$PGDATA"

# -----------------------------
# 13: Recovery konfigurieren (PostgreSQL 12+ Style)
# -----------------------------
echo "==> Konfiguriere Recovery..."
touch "$PGDATA/recovery.signal"

# Für PostgreSQL 12+ wird recovery.conf nicht mehr verwendet
# Stattdessen in postgresql.conf schreiben
cat >> "$PGDATA/postgresql.conf" <<EOF

# Recovery Einstellungen
restore_command = 'cp ${ARCHIVEDIR}/%f %p'
recovery_target_time = '${TARGET_TIME}'
recovery_target_action = 'promote'
EOF

# -----------------------------
# 14: PostgreSQL starten + PITR überwachen
# -----------------------------
echo "==> Starte PostgreSQL mit Recovery..."
pg_ctl -D "$PGDATA" -o "-p $PGPORT" -l "$PGDATA/recovery.log" start

echo "==> Überwache Recovery..."
echo "   (Prüfe Logdatei: $PGDATA/recovery.log)"

START=$(date +%s)
MAX_WAIT=60
RECOVERY_COMPLETE=false

# Warte auf Server-Start
echo "   Warte auf PostgreSQL Start..."
while [ $(( $(date +%s) - START )) -lt $MAX_WAIT ]; do
    if pg_isready -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
        echo "   PostgreSQL ist erreichbar"
        break
    fi
    sleep 2
    echo "   ... warte ($(( $(date +%s) - START ))s)"
done

# Prüfe Recovery-Status
echo "   Prüfe Recovery-Status..."
for i in $(seq 1 30); do
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
           -At -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "f"; then
        echo "✅ PostgreSQL ist aus Recovery hervorgegangen"
        RECOVERY_COMPLETE=true
        break
    elif psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
           -At -c "SELECT pg_is_in_recovery();" 2>/dev/null | grep -q "t"; then
        echo "   Noch in Recovery... ($i/30)"
    else
        echo "   Verbindungsaufbau... ($i/30)"
    fi
    sleep 2
done

if [ "$RECOVERY_COMPLETE" = false ]; then
    echo "❌ Recovery Timeout oder Fehler!"
    echo "Letzte Logs:"
    tail -30 "$PGDATA/recovery.log" 2>/dev/null || tail -30 "$PGDATA/postgres.log" 2>/dev/null
    echo "Prüfe ob Server läuft:"
    pg_ctl -D "$PGDATA" status || true
    exit 1
fi

echo "✅ Recovery abgeschlossen"

# Warte kurz für Stabilisierung
sleep 3

# -----------------------------
# 15: Tabelle nach Recovery anzeigen
# -----------------------------
echo "==> Tabelle nach Recovery:"
if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
       -c "SELECT * FROM $TABLE ORDER BY id;" 2>/dev/null; then
    echo "✅ Abfrage erfolgreich"
else
    echo "⚠️  Erster Abfrageversuch fehlgeschlagen, warte und versuche erneut..."
    sleep 5
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
         -c "SELECT * FROM $TABLE ORDER BY id;"
fi

# -----------------------------
# 16: Datenintegrität prüfen
# -----------------------------
echo "==> Prüfe Datenintegrität..."

# Warte auf Datenbank-Verfügbarkeit
for i in $(seq 1 10); do
    if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
           -At -c "SELECT 1;" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

ROW_COUNT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
                 -At -c "SELECT count(*) FROM $TABLE;" 2>/dev/null || echo "0")

echo "Gefundene Zeilen: $ROW_COUNT"

if [ "$ROW_COUNT" -ne 10 ]; then
    echo "❌ Fehler: Erwartet 10 Zeilen, gefunden $ROW_COUNT"
    echo "Aktueller Tabelleninhalt:"
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
         -c "SELECT * FROM $TABLE ORDER BY id;" 2>/dev/null || true
    exit 1
fi

# Prüfe ob alle IDs 1-10 vorhanden sind
MISSING_IDS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
                     -At 2>/dev/null <<EOF
SELECT string_agg(s.id::text, ', ') 
FROM generate_series(1,10) s
WHERE NOT EXISTS (SELECT 1 FROM $TABLE t WHERE t.id = s.id);
EOF
) || MISSING_IDS="unknown"

if [ -n "$MISSING_IDS" ] && [ "$MISSING_IDS" != "unknown" ]; then
    echo "❌ Fehler: Fehlende IDs nach Recovery: $MISSING_IDS"
    exit 1
fi

echo "✅ Alle 10 Datensätze erfolgreich wiederhergestellt!"

# -----------------------------
# 17: Finale Prüfung und Abschluss
# -----------------------------
echo ""
echo "==> Finale Prüfung:"
FINAL_RESULT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" \
                    -t 2>/dev/null <<EOF
SELECT 'Row ' || id || ': ' || name FROM $TABLE ORDER BY id;
EOF
) || FINAL_RESULT="Abfrage fehlgeschlagen"

echo "$FINAL_RESULT"

echo ""
echo "================================================"
echo "🎉 PITR Test ERFOLGREICH abgeschlossen!"
echo "================================================"
echo "Zusammenfassung:"
echo "  ✓ PostgreSQL initialisiert und gestartet"
echo "  ✓ Datenbank '$DB' und Tabelle '$TABLE' erstellt"
echo "  ✓ 5 initiale Datensätze eingefügt (1-5)"
echo "  ✓ Base Backup mit GPG verschlüsselt"
echo "  ✓ Weitere 5 Datensätze hinzugefügt (6-10)"
echo "  ✓ Recovery-Zeitpunkt festgelegt: $TARGET_TIME"
echo "  ✓ Desaster simuliert (DELETE WHERE id <= 8)"
echo "  ✓ PITR Recovery durchgeführt"
echo "  ✓ Alle 10 Datensätze erfolgreich wiederhergestellt!"
echo "================================================"

# -----------------------------
# 18: Cleanup (optional)
# -----------------------------
echo ""
echo "==> Test beendet. Container wird gestoppt."
echo "Die Datenverzeichnisse bleiben im Container erhalten:"
echo "  - PGDATA: $PGDATA"
echo "  - Archive: $ARCHIVEDIR"
echo "  - Backup: $BACKUPDIR"