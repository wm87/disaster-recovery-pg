FROM postgres:18-alpine

# Installiere benötigte Pakete als root
USER root
RUN apk add --no-cache \
    gnupg \
    postgresql-client \
    bash \
    coreutils

# Verzeichnis erstellen und Berechtigungen setzen
RUN mkdir -p /app && chown -R postgres:postgres /app

# Zum postgres User wechseln
USER postgres

# Setze Arbeitsverzeichnis
WORKDIR /app

# Kopiere das Skript
COPY --chown=postgres:postgres pitr-test.sh /app/pitr-test.sh

# Mache Skript ausführbar
RUN chmod +x /app/pitr-test.sh

# Healthcheck deaktivieren
HEALTHCHECK NONE

# Setze Entrypoint
ENTRYPOINT ["/app/pitr-test.sh"]