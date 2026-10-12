#!/usr/bin/env bash
#
# Bài 4 - Custom Network & Named Volume bằng Docker CLI
# ------------------------------------------------------
# Kết nối cụm 2 container (Backend Web API + PostgreSQL) bằng Docker CLI thủ công:
#   * Custom Bridge Network : app-net   -> DNS resolution nội bộ qua tên container
#   * Named Volume          : db-data   -> dữ liệu PostgreSQL bền vững
#
# Cách dùng:
#   ./commands.sh          # chạy toàn bộ kịch bản + kiểm tra
#   ./commands.sh clean    # dọn dẹp (containers, network, volume)
#
set -euo pipefail

# ============================================================================
# CẤU HÌNH
# ============================================================================
NETWORK_NAME="app-net"
VOLUME_NAME="db-data"

DB_CONTAINER="db-server"
APP_CONTAINER="app-container"

DB_IMAGE="postgres:15-alpine"
APP_IMAGE="nginx:alpine"          # Backend Web API (đóng vai web server)

DB_NAME="appdb"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_PORT="5432"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ============================================================================
# DỌN DẸP (tùy chọn)
# ============================================================================
cleanup() {
  log "Dọn dẹp containers, network và volume..."
  docker rm -f "$DB_CONTAINER" "$APP_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
  log "Đã dọn dẹp xong."
}

if [[ "${1:-}" == "clean" ]]; then
  cleanup
  exit 0
fi

# ============================================================================
# 1. TẠO CUSTOM BRIDGE NETWORK
# ============================================================================
create_network() {
  log "1. Tạo Custom Bridge Network: ${NETWORK_NAME}"
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    warn "Network '${NETWORK_NAME}' đã tồn tại, bỏ qua."
  else
    docker network create --driver bridge "$NETWORK_NAME"
  fi
  docker network ls | grep "$NETWORK_NAME"
}

# ============================================================================
# 2. TẠO NAMED VOLUME
# ============================================================================
create_volume() {
  log "2. Tạo Named Volume: ${VOLUME_NAME}"
  docker volume create "$VOLUME_NAME"
  docker volume ls | grep "$VOLUME_NAME"
}

# ============================================================================
# 3. KHỞI CHẠY DATABASE CONTAINER (postgres) trên app-net + mount db-data
# ============================================================================
run_db() {
  log "3. Khởi chạy Database Container: ${DB_CONTAINER} (${DB_IMAGE})"
  docker rm -f "$DB_CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$DB_CONTAINER" \
    --network "$NETWORK_NAME" \
    --network-alias "$DB_CONTAINER" \
    -v "${VOLUME_NAME}:/var/lib/postgresql/data" \
    -e POSTGRES_USER="$DB_USER" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -e POSTGRES_DB="$DB_NAME" \
    "$DB_IMAGE"
}

# Chờ PostgreSQL sẵn sàng nhận kết nối
wait_for_db() {
  info "Chờ PostgreSQL khởi động..."
  local retries=60
  until docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
    retries=$((retries - 1))
    [[ $retries -le 0 ]] && die "PostgreSQL không sẵn sàng sau thời gian chờ."
    sleep 1
  done
  log "PostgreSQL đã sẵn sàng."
}

# ============================================================================
# 4. KHỞI CHẠY BACKEND CONTAINER trên app-net, trỏ tới hostname db-server
# ============================================================================
run_app() {
  log "4. Khởi chạy Backend Container: ${APP_CONTAINER} (${APP_IMAGE})"
  docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$APP_CONTAINER" \
    --network "$NETWORK_NAME" \
    -e DB_HOST="$DB_CONTAINER" \
    -e DB_PORT="$DB_PORT" \
    -e DB_NAME="$DB_NAME" \
    -e DB_USER="$DB_USER" \
    -e DB_PASSWORD="$DB_PASSWORD" \
    "$APP_IMAGE"
}

# ============================================================================
# 5. THÊM DỮ LIỆU MẪU VÀO DATABASE
# ============================================================================
seed_data() {
  log "5. Thêm dữ liệu mẫu vào database..."
  docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS students (
    id    SERIAL PRIMARY KEY,
    name  TEXT    NOT NULL,
    score INTEGER NOT NULL
);
TRUNCATE students RESTART IDENTITY;
INSERT INTO students (name, score) VALUES ('Alice', 95), ('Bob', 88), ('Charlie', 76);
SELECT * FROM students ORDER BY id;
SQL
}

# ============================================================================
# 6. TEST DATA PERSISTENCE
#    Xóa cứng container DB -> tạo lại container mới -> gắn cùng volume db-data
# ============================================================================
test_persistence() {
  local before after
  before=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM students;")
  info "Số bản ghi TRƯỚC khi xóa container: ${before}"

  echo
  warn ">> Xóa cứng Database Container: docker rm -f ${DB_CONTAINER}"
  docker rm -f "$DB_CONTAINER" >/dev/null
  docker ps -a | grep "$DB_CONTAINER" && die "Container DB vẫn còn!" || info "Container '${DB_CONTAINER}' đã bị xóa."

  warn ">> Tạo lại container DB mới với cùng volume '${VOLUME_NAME}'"
  run_db
  wait_for_db

  after=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM students;")
  info "Số bản ghi SAU khi tạo lại container: ${after}"

  echo
  docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM students ORDER BY id;"

  if [[ "$before" == "$after" && "$after" -gt 0 ]]; then
    log "KẾT QUẢ: DỮ LIỆU NGUYÊN VẸN sau khi tái tạo container DB (${after} bản ghi). ✔"
  else
    die "KẾT QUẢ: Dữ liệu KHÔNG được bảo toàn (before=${before}, after=${after})."
  fi
}

# ============================================================================
# 7. KIỂM TRA DNS NỘI BỘ (backend -> db-server)
# ============================================================================
verify_dns() {
  log "7. Kiểm tra DNS resolution nội bộ từ '${APP_CONTAINER}' -> '${DB_CONTAINER}'"
  info "Biến môi trường kết nối DB trong Backend Container:"
  docker exec "$APP_CONTAINER" env | grep '^DB_' | sort

  echo
  info "Phân giải tên miền (getent hosts):"
  docker exec "$APP_CONTAINER" getent hosts "$DB_CONTAINER"

  echo
  info "Ping tới hostname DB (tên container):"
  docker exec "$APP_CONTAINER" ping -c 2 "$DB_CONTAINER"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  echo "=================================================================="
  echo " Bài 4 - Custom Network & Named Volume (Docker CLI)"
  echo "=================================================================="
  create_network
  create_volume
  run_db
  wait_for_db
  run_app
  seed_data
  test_persistence
  verify_dns

  echo
  echo "=================================================================="
  log "HOÀN TẤT. Các lệnh kiểm tra nhanh:"
  echo "  docker network ls | grep ${NETWORK_NAME}"
  echo "  docker volume ls  | grep ${VOLUME_NAME}"
  echo "  docker network inspect ${NETWORK_NAME}"
  echo "  docker exec -it ${APP_CONTAINER} ping -c 2 ${DB_CONTAINER}"
  echo "=================================================================="
}

main
