#!/bin/bash
#
# DHIS2 Manual Install Script for Ubuntu 22.04 / 24.04
# Based on: https://docs.dhis2.org/en/manage/getting-started/manual-install-on-ubuntu.html
#
# Usage:
#   sudo ./install-dhis2.sh
#
# Run this script as a user with sudo privileges (NOT as root directly,
# i.e. don't `su root` first — just `sudo ./install-dhis2.sh`).
#
# ---------------------------------------------------------------------
# CONFIGURATION — edit these variables before running
# ---------------------------------------------------------------------
DHIS_SYSTEM_USER="dhis"                     # OS user that will run Tomcat/DHIS2
DHIS_HOME="/home/${DHIS_SYSTEM_USER}"
DHIS2_CONFIG_DIR="${DHIS_HOME}/config"       # DHIS2_HOME
TOMCAT_DIR="${DHIS_HOME}/tomcat-dhis"

DB_NAME="dhis"
DB_USER="dhis"
DB_PASSWORD="dhis"

DHIS_OS_PASSWORD="dhis"

JRE_VERSION="17"                             # 17 for DHIS2 2.40+, 11 for 2.38/2.35, 8 for pre-2.35
PG_VERSION="16"                              # PostgreSQL version to install

DHIS2_VERSION_MAJOR="43"                     # e.g. 42
DHIS2_VERSION_FULL="43.0.1"                  # e.g. 42.0.0 -- set the exact version you want
DHIS2_WAR_URL="https://releases.dhis2.org/${DHIS2_VERSION_MAJOR}/dhis2-stable-${DHIS2_VERSION_FULL}.war"

JAVA_HEAP_MIN="-Xms3g"
JAVA_HEAP_MAX="-Xmx6g"
TOMCAT_HTTP_PORT="8080"

LOCALE="en_US.UTF-8"
# ---------------------------------------------------------------------

set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run with sudo/root privileges (e.g. sudo ./install-dhis2.sh)" 1>&2
  exit 1
fi

echo "=================================================================="
echo " DHIS2 Manual Install"
echo " User: ${DHIS_SYSTEM_USER}  | DHIS2_HOME: ${DHIS2_CONFIG_DIR}"
echo " DB:   ${DB_NAME} / ${DB_USER} (PostgreSQL ${PG_VERSION})"
echo " Java: OpenJDK ${JRE_VERSION}"
echo " WAR:  ${DHIS2_WAR_URL}"
echo "=================================================================="
sleep 3

# ---------------------------------------------------------------------
# 1. Create the dhis system user
# ---------------------------------------------------------------------
echo ">>> [1/10] Creating system user '${DHIS_SYSTEM_USER}'..."
if id "${DHIS_SYSTEM_USER}" &>/dev/null; then
  echo "    User '${DHIS_SYSTEM_USER}' already exists, skipping creation."
else
  useradd -d "${DHIS_HOME}" -m "${DHIS_SYSTEM_USER}" -s /bin/false
  echo "${DHIS_SYSTEM_USER}:${DHIS_OS_PASSWORD}" | chpasswd
fi

# ---------------------------------------------------------------------
# 2. Create the DHIS2 configuration directory
# ---------------------------------------------------------------------
echo ">>> [2/10] Creating configuration directory ${DHIS2_CONFIG_DIR}..."
sudo -u "${DHIS_SYSTEM_USER}" mkdir -p "${DHIS2_CONFIG_DIR}"

# ---------------------------------------------------------------------
# 3. Set server timezone and locale
# ---------------------------------------------------------------------
echo ">>> [3/10] Configuring locale (${LOCALE})..."
locale-gen "${LOCALE}" || true
# Timezone reconfiguration is interactive (dpkg-reconfigure tzdata).
# Uncomment the next line to run it interactively:
# dpkg-reconfigure tzdata

# ---------------------------------------------------------------------
# 4. Install PostgreSQL
# ---------------------------------------------------------------------
echo ">>> [4/10] Installing PostgreSQL ${PG_VERSION} + PostGIS..."
sh -c "echo \"deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list"
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg

apt update -y
apt upgrade -y
apt-get install -y "postgresql-${PG_VERSION}" "postgresql-${PG_VERSION}-postgis-3"

systemctl start postgresql
systemctl enable postgresql

echo ">>> Creating database user and database..."
# Create DB role non-interactively (avoids the interactive createuser prompt)
sudo -u postgres psql -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} WITH LOGIN ENCRYPTED PASSWORD '${DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END \$\$;"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"

echo ">>> Creating required extensions (postgis, btree_gin, pg_trgm)..."
sudo -u postgres psql -c "create extension if not exists postgis;" "${DB_NAME}"
sudo -u postgres psql -c "create extension if not exists btree_gin;" "${DB_NAME}"
sudo -u postgres psql -c "create extension if not exists pg_trgm;" "${DB_NAME}"

# ---------------------------------------------------------------------
# 5. Install Java
# ---------------------------------------------------------------------
echo ">>> [5/10] Installing OpenJDK ${JRE_VERSION} (headless)..."
apt-get install -y "openjdk-${JRE_VERSION}-jre-headless"
java -version

# ---------------------------------------------------------------------
# 6. Create dhis.conf
# ---------------------------------------------------------------------
echo ">>> [6/10] Writing dhis.conf..."
sudo -u "${DHIS_SYSTEM_USER}" bash -c "cat > ${DHIS2_CONFIG_DIR}/dhis.conf" <<EOF
# ----------------------------------------------------------------------
# Database connection
# ----------------------------------------------------------------------

# JDBC driver class
connection.driver_class = org.postgresql.Driver

# Database connection URL
connection.url = jdbc:postgresql:${DB_NAME}

# Database username
connection.username = ${DB_USER}

# Database password
connection.password = ${DB_PASSWORD}

# Database schema behavior, can be validate, update, create, create-drop
connection.schema = update

# Encryption password (sensitive) -- CHANGE THIS
encryption.password = CHANGE_ME_ENCRYPTION_PASSWORD
EOF
chmod 600 "${DHIS2_CONFIG_DIR}/dhis.conf"

# ---------------------------------------------------------------------
# 7. Install Tomcat and create the DHIS2 instance
# ---------------------------------------------------------------------
echo ">>> [7/10] Installing tomcat9-user and creating Tomcat instance..."
apt-get install -y tomcat9-user

if [ ! -d "${TOMCAT_DIR}" ]; then
  tomcat9-instance-create "${TOMCAT_DIR}"
fi
chown -R "${DHIS_SYSTEM_USER}:${DHIS_SYSTEM_USER}" "${TOMCAT_DIR}"

echo ">>> Configuring setenv.sh..."
JAVA_HOME_PATH=$(readlink -f /usr/lib/jvm/java-${JRE_VERSION}-openjdk-amd64/ 2>/dev/null || echo "/usr/lib/jvm/java-${JRE_VERSION}-openjdk-amd64/")

sudo -u "${DHIS_SYSTEM_USER}" bash -c "cat >> ${TOMCAT_DIR}/bin/setenv.sh" <<EOF

export JAVA_HOME='${JAVA_HOME_PATH}'
export JAVA_OPTS='${JAVA_HEAP_MIN} ${JAVA_HEAP_MAX}'
export DHIS2_HOME='${DHIS2_CONFIG_DIR}'
EOF

echo ">>> Hardening startup.sh (refuse to run as root)..."
sudo -u "${DHIS_SYSTEM_USER}" bash -c "cat > ${TOMCAT_DIR}/bin/startup.sh" <<EOF
#!/bin/sh
set -e

if [ "\$(id -u)" -eq "0" ]; then
  echo "This script must NOT be run as root" 1>&2
  exit 1
fi

export CATALINA_BASE="${TOMCAT_DIR}"
/usr/share/tomcat9/bin/startup.sh
echo "Tomcat started"
EOF
chmod +x "${TOMCAT_DIR}/bin/startup.sh"

echo ">>> Setting relaxedQueryChars on Connector (port ${TOMCAT_HTTP_PORT})..."
SERVER_XML="${TOMCAT_DIR}/conf/server.xml"
if ! grep -q "relaxedQueryChars" "${SERVER_XML}"; then
  sed -i "s#<Connector port=\"${TOMCAT_HTTP_PORT}\" protocol=\"HTTP/1.1\"#<Connector port=\"${TOMCAT_HTTP_PORT}\" protocol=\"HTTP/1.1\" relaxedQueryChars=\"[]\"#" "${SERVER_XML}"
fi

# ---------------------------------------------------------------------
# 8. Download and deploy the DHIS2 WAR file
# ---------------------------------------------------------------------
echo ">>> [8/10] Downloading DHIS2 WAR (${DHIS2_VERSION_FULL})..."
TMP_WAR="/tmp/dhis.war"
wget -O "${TMP_WAR}" "${DHIS2_WAR_URL}"
mv "${TMP_WAR}" "${TOMCAT_DIR}/webapps/ROOT.war"
chown "${DHIS_SYSTEM_USER}:${DHIS_SYSTEM_USER}" "${TOMCAT_DIR}/webapps/ROOT.war"

# ---------------------------------------------------------------------
# 9. Create a systemd service to manage DHIS2
# ---------------------------------------------------------------------
echo ">>> [9/10] Creating systemd service 'dhis2'..."
cat > /etc/systemd/system/dhis2.service <<EOF
[Unit]
Description=DHIS2 Tomcat Instance
After=network.target postgresql.service

[Service]
Type=forking
User=${DHIS_SYSTEM_USER}
Group=${DHIS_SYSTEM_USER}
Environment="CATALINA_BASE=${TOMCAT_DIR}"
Environment="CATALINA_HOME=/usr/share/tomcat9"
Environment="JAVA_HOME=${JAVA_HOME_PATH}"
ExecStart=${TOMCAT_DIR}/bin/startup.sh
ExecStop=${TOMCAT_DIR}/bin/shutdown.sh
Restart=on-failure
RestartSec=10
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dhis2

# ---------------------------------------------------------------------
# 10. Start DHIS2
# ---------------------------------------------------------------------
echo ">>> [10/10] Starting DHIS2 via systemd..."
systemctl start dhis2

echo "=================================================================="
echo " DHIS2 installation complete!"
echo ""
echo " - Follow logs:    sudo tail -f ${TOMCAT_DIR}/logs/catalina.out"
echo " - Stop service:    sudo systemctl stop dhis2"
echo " - Start service:   sudo systemctl start dhis2"
echo " - Status:          sudo systemctl status dhis2"
echo " - Access DHIS2 at: http://<server-ip>:${TOMCAT_HTTP_PORT}"
echo "   (default login: admin / district — change immediately)"
echo ""
echo " IMPORTANT — before/after running in production:"
echo "   1. Change DB_PASSWORD and DHIS_OS_PASSWORD at the top of this script"
echo "      BEFORE running it (they are placeholders right now)."
echo "   2. Change 'encryption.password' in ${DHIS2_CONFIG_DIR}/dhis.conf"
echo "   3. Put a reverse proxy (nginx/Apache) with TLS in front of Tomcat."
echo "   4. Consider the automated install (Ansible) for production:"
echo "      https://github.com/dhis2/dhis2-server-tools"
echo "=================================================================="
