# Bài 4 — Custom Network & Named Volume bằng Docker CLI

Kết nối cụm 2 container (Backend Web API + PostgreSQL Database) bằng Docker CLI thủ công,
sử dụng **Custom Bridge Network** để giao tiếp nội bộ qua tên service và
**Named Volume** để lưu trữ dữ liệu bền vững.

---

## 1. Mục tiêu

- Tạo **Custom Bridge Network** `app-net` → các container phân giải tên nhau qua **DNS nội bộ** (không cần `--link` hay IP tĩnh).
- Tạo **Named Volume** `db-data` → dữ liệu PostgreSQL tồn tại độc lập với vòng đời container.
- Chứng minh **Data Persistence**: xóa cứng container DB, tạo lại container mới gắn cùng volume, dữ liệu vẫn nguyên vẹn.

---

## 2. Kiến trúc

```
                        Docker host
   ┌─────────────────────────────────────────────────────────┐
   │  Custom Bridge Network: app-net  (172.18.0.0/16)        │
   │                                                         │
   │   ┌───────────────────┐        ┌─────────────────────┐   │
   │   │  app-container    │  DNS   │   db-server         │   │
   │   │  (nginx:alpine)   │───────▶│  postgres:15-alpine │   │
   │   │  Backend Web API  │ ping   │  :5432              │   │
   │   │  DB_HOST=db-server│        │         │           │   │
   │   └───────────────────┘        │         ▼           │   │
   │                                │   /var/lib/postgresql│  │
   └────────────────────────────────┼───────────┬─────────┘   │
                                    │           ▼             │
                        Named Volume│      db-data  (persistent)
                                    └─────────────────────────┘
```

| Thành phần   | Tên             | Chi tiết                                                        |
|--------------|-----------------|-----------------------------------------------------------------|
| Network      | `app-net`       | driver `bridge` (custom, có DNS resolution nội bộ)              |
| Volume       | `db-data`       | named volume, mount vào `/var/lib/postgresql/data`              |
| DB Container | `db-server`     | image `postgres:15-alpine`, port `5432`, tham gia `app-net`     |
| App Container| `app-container` | image `nginx:alpine` (vai trò backend), tham gia `app-net`      |

---

## 3. Cấu trúc thư mục

```
homework/session_10/ex4/
├── commands.sh   # Script thực thi toàn bộ thao tác Docker CLI
└── README.md     # Tài liệu này
```

---

## 4. Yêu cầu

- Docker Engine đã cài đặt và đang chạy (`docker info`).
- Có kết nối Internet ở lần chạy đầu để tải image `postgres:15-alpine` và `nginx:alpine`.

---

## 5. Cách chạy

```bash
# Cấp quyền thực thi (chỉ cần 1 lần)
chmod +x commands.sh

# Chạy toàn bộ kịch bản + tự kiểm tra
./commands.sh

# Dọn dẹp (xóa container, network, volume)
./commands.sh clean
```

---

## 6. Chi tiết các bước trong `commands.sh`

### Bước 1 — Tạo Custom Bridge Network
```bash
docker network create --driver bridge app-net
```
→ Tạo mạng riêng, mặc định bật **embedded DNS server** cho phép các container gọi nhau bằng **tên**.

### Bước 2 — Tạo Named Volume
```bash
docker volume create db-data
```
→ Volume do Docker quản lý tại `/var/lib/docker/volumes/db-data/_data`.

### Bước 3 — Khởi chạy Database Container
```bash
docker run -d \
  --name db-server \
  --network app-net \
  --network-alias db-server \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=appdb \
  postgres:15-alpine
```
→ Tham gia `app-net`, gắn volume `db-data` vào đúng thư mục data của PostgreSQL.

### Bước 4 — Khởi chạy Backend Container
```bash
docker run -d \
  --name app-container \
  --network app-net \
  -e DB_HOST=db-server \
  -e DB_PORT=5432 \
  -e DB_NAME=appdb \
  -e DB_USER=postgres \
  -e DB_PASSWORD=postgres \
  nginx:alpine
```
→ Cùng tham gia `app-net`; biến kết nối DB trỏ tới **hostname `db-server`** (không dùng IP).

### Bước 5 — Thêm dữ liệu mẫu
Tạo bảng và chèn dữ liệu để phục vụ kiểm thử persistence:
```bash
docker exec -i db-server psql -U postgres -d appdb <<'SQL'
CREATE TABLE IF NOT EXISTS students (
    id SERIAL PRIMARY KEY, name TEXT NOT NULL, score INTEGER NOT NULL
);
TRUNCATE students RESTART IDENTITY;
INSERT INTO students (name, score) VALUES ('Alice', 95), ('Bob', 88), ('Charlie', 76);
SQL
```

### Bước 6 — Test Data Persistence
```bash
docker rm -f db-server          # xóa cứng container DB
docker run -d --name db-server --network app-net \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=appdb \
  postgres:15-alpine            # tạo lại container mới, gắn CÙNG volume
```
→ So sánh số bản ghi trước/sau khi tái tạo container.

### Bước 7 — Kiểm tra DNS nội bộ
```bash
docker exec app-container getent hosts db-server
docker exec app-container ping -c 2 db-server
```

---

## 7. Kết quả chạy thực tế

```
[+] 1. Tạo Custom Bridge Network: app-net
6d1c55961ded   app-net   bridge    local
[+] 2. Tạo Named Volume: db-data
local     db-data
[+] 3. Khởi chạy Database Container: db-server (postgres:15-alpine)
[+] PostgreSQL đã sẵn sàng.
[+] 4. Khởi chạy Backend Container: app-container (nginx:alpine)
[+] 5. Thêm dữ liệu mẫu vào database...
 id |  name   | score
----+---------+-------
  1 | Alice   |    95
  2 | Bob     |    88
  3 | Charlie |    76
(3 rows)

[i] Số bản ghi TRƯỚC khi xóa container: 3
[!] >> Xóa cứng Database Container: docker rm -f db-server
[i] Container 'db-server' đã bị xóa.
[!] >> Tạo lại container DB mới với cùng volume 'db-data'
[i] Số bản ghi SAU khi tạo lại container: 3

 id |  name   | score
----+---------+-------
  1 | Alice   |    95
  2 | Bob     |    88
  3 | Charlie |    76
(3 rows)

[+] KẾT QUẢ: DỮ LIỆU NGUYÊN VẸN sau khi tái tạo container DB (3 bản ghi).

[+] 7. Kiểm tra DNS resolution nội bộ từ 'app-container' -> 'db-server'
DB_HOST=db-server
DB_NAME=appdb
DB_PASSWORD=postgres
DB_PORT=5432
DB_USER=postgres

[i] Phân giải tên miền (getent hosts):
172.18.0.2        db-server  db-server

[i] Ping tới hostname DB (tên container):
PING db-server (172.18.0.2): 56 data bytes
64 bytes from 172.18.0.2: seq=0 ttl=64 time=0.081 ms
64 bytes from 172.18.0.2: seq=1 ttl=64 time=0.070 ms

--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

---

## 8. Kiểm tra theo yêu cầu đề bài

```bash
# 1. Network đã tạo
docker network ls | grep app-net
# >> 6d1c55961ded   app-net   bridge   local

# 2. Volume đã tạo
docker volume ls | grep db-data
# >> local     db-data

# 3. Chi tiết network (2 container cùng tham gia)
docker network inspect app-net
# >> "Containers": { ... "app-container" (172.18.0.3), "db-server" (172.18.0.2) }

# 4. DNS resolution từ backend tới db-server
docker exec -it app-container ping -c 2 db-server
# >> PING db-server (172.18.0.2): 56 data bytes ... 0% packet loss
```

**Kết quả mong đợi — đạt được:**

- ✅ `ping db-server` từ Backend container **phân giải thành công** IP nội bộ `172.18.0.2` của DB container.
- ✅ Dữ liệu DB **nguyên vẹn** (3/3 bản ghi) sau khi xóa và tái tạo container DB.

---

## 9. Giải thích cơ chế

**DNS resolution trong Custom Network**
Trên mạng `bridge` mặc định, container chỉ gọi nhau được qua IP. Với **custom bridge network**,
Docker chạy một DNS server nội bộ (127.0.0.11) cho phép phân giải **tên container** (và `--network-alias`)
thành IP — nên backend chỉ cần cấu hình `DB_HOST=db-server`, không phụ thuộc IP cứng.

**Data Persistence với Named Volume**
Container là *tạm thời*: khi `docker rm`, lớp ghi (writable layer) của nó bị xóa.
Named Volume `db-data` nằm **ngoài** vòng đời container, Docker chỉ xóa volume khi có lệnh `docker volume rm` tường minh.
Vì vậy khi tạo lại `db-server` và gắn lại `db-data:/var/lib/postgresql/data`, toàn bộ dữ liệu được giữ nguyên.
(Đây là lý do **không** dùng bind mount trỏ vào thư mục tạm, và **không** truyền `--rm` cho container DB.)

---

## 10. Dọn dẹp

```bash
./commands.sh clean
# hoặc thủ công:
docker rm -f db-server app-container
docker network rm app-net
docker volume rm db-data
```

---

## 11. Ghi chú

- Mật khẩu DB (`postgres/postgres`) chỉ dùng cho môi trường học tập. Trong thực tế nên dùng Docker secret hoặc biến môi trường từ file `.env` không commit.
- `nginx:alpine` đóng vai trò "Backend Web API" đại diện — điểm cốt lõi của bài là **DNS nội bộ** và **persistence**, không phụ thuộc ngôn ngữ/framework backend.
- Script có tính **idempotent**: chạy lại nhiều lần vẫn cho kết quả đúng (tự xóa container cũ trước khi tạo mới).
