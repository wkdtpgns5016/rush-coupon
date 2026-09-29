# k6 부하 테스트 가이드 — M5

## 요약

| 항목 | 내용 |
|---|---|
| 범위 | Issue #47 — Valkey+RabbitMQ 비동기 아키텍처 대상 `POST /coupons/:id/issue` k6 부하 시나리오 재실행 |
| 목적 | M3(비관적 락)와 같은 부하 패턴(baseline/spike/scaleout)을 그대로 재실행해 API 응답 지연·종단 지연·HPA 확장·큐 배출 여부를 측정하고, M3 vs M5 비교표(#49)의 입력값을 만든다 |
| 전신 문서 | [m3-k6-load-test.md](m3-k6-load-test.md) — `k6/scenarios/*.js`, `k6/lib/report.js`는 별도 파일로 분리하지 않고 같은 파일을 M5 아키텍처에 맞게 직접 갱신했다. 환경변수/`run.sh`/`cleanup.sql` 사용법은 그 문서와 동일하다 |
| 관련 파일 | [k6/lib/](../../k6/lib/), [k6/scenarios/](../../k6/scenarios/), [k6/scripts/latency-report.sql](../../k6/scripts/latency-report.sql)(종단 지연 계산), 측정 결과는 (실행 후) `m5-async-load-test-report.md` |

---

## 1. 구성

```
k6/
  lib/
    helpers.js   # setup() 단계에서 테스트 전용 쿠폰을 생성
    report.js    # handleSummary()용 결과 리포트(RPS/API 응답 지연/발급 요청 결과 분포) 포맷터
  scenarios/
    baseline.js  # 단일 파드/소규모 트래픽 — 정상 상태 기준선
    spike.js     # 수천 명 동시 발급 — 스파이크/스트레스
    scaleout.js  # 목표 요청률을 몇 분간 유지 — API/Worker HPA 스케일아웃 관찰용
  scripts/
    run.sh              # k6 실행 + 종료 후 cleanup.sql 자동 실행 래퍼
    cleanup.sql          # 테스트 전용 쿠폰([k6-* 접두사])과 발급 이력 삭제
    latency-report.sql   # (#47) 종단 지연(큐 적재→Worker 저장 완료) percentile 계산
  results/       # 실행 결과 (.md/.json), gitignore 대상
```

세 시나리오 모두 `setup()`에서 `POST /coupons`로 테스트 전용 쿠폰을 새로 만들어 쓴다. 재고를
수요보다 훨씬 크게 잡는 이유가 M3(락 경합 재현)와는 다르다 — M5에서는 재고 소진(400)이 섞여
결과가 왜곡되지 않도록, 순수하게 "Valkey 판정 처리량 + RabbitMQ 큐 적재/배출"만 관찰하는 데
집중한다.

각 발급 요청의 `userId`는 `exec.scenario.iterationInTest`(시나리오 전체에서 단조 증가하는 카운터)로
만든다. VU/반복 조합과 무관하게 항상 고유해서, 테스트 중 의도치 않은 중복 발급(409)이 섞여
결과가 왜곡되는 것을 막는다.

`baseline.js`/`spike.js`와 `scaleout.js`는 executor가 다르다. baseline/spike는 "실제 사용자가 몇 명
동시에 몰리는가"를 흉내내는 게 목적이라 `ramping-vus`/`per-vu-iterations`를 쓰지만, `scaleout.js`는
"HPA가 여러 단계로 반응할 만큼 충분히 오래(몇 분) 목표 요청률을 유지"하는 게 목적이라
`ramping-arrival-rate`로 초당 요청 수 자체를 고정한다. 자세한 설계 이유는 `scaleout.js` 상단 주석 참고.

## 2. 사전 준비

- [k6](https://k6.io/) 설치 (`brew install k6` 등)
- 테스트 대상 backend/worker가 떠 있고 `BASE_URL`로 접근 가능해야 함
- **(#47) `requested_at` 컬럼 마이그레이션 완료**: `backend/db/schema.sql`의
  `ALTER TABLE coupon_issues ADD COLUMN IF NOT EXISTS requested_at ...`을 대상 DB(로컬
  docker-compose 또는 클러스터 외부 Postgres)에 적용해뒀어야 종단 지연을 계산할 수 있다. 로컬
  docker-compose는 볼륨이 이미 있으면 `docker-entrypoint-initdb.d`가 재실행되지 않으므로 직접
  `ALTER TABLE`을 실행해야 한다.
- **(#47) backend/worker가 `requestedAt` 저장 로직이 포함된 버전으로 재배포되어 있어야 함** —
  머지 전 이미지로 측정하면 `requested_at`이 전부 NULL로 남는다.

## 3. 실행 대상 (`BASE_URL`)

| 대상 | BASE_URL | 비고 |
|---|---|---|
| 로컬 docker-compose | `http://localhost:3000` (기본값) | `cd backend && docker compose up -d` |
| k8s 클러스터 | `http://<INGRESS_HOST>` | [fresh-environment-setup.md](../setup/fresh-environment-setup.md) 5번의 Ingress 호스트. `/coupons`만 허용 목록에 있어 이 스크립트가 쓰는 경로(`POST /coupons`, `POST /coupons/:id/issue`)는 그대로 통과한다 |

로컬 실행은 스크립트 동작 검증(스모크 테스트) 용도다. **M3 vs M5 비교표에 쓸 공식 수치는 반드시
클러스터(`INGRESS_HOST`) 대상으로 측정한다** — ingress-nginx, HPA(2~10 파드), 파드 리소스
제한이 로컬 docker-compose에는 없어서 진짜 확장/병목 양상이 재현되지 않는다.

## 4. 실행

`.env.example`을 복사해 값을 채운 뒤 셸에 불러와서 쓴다. 설치된 k6 버전(v2.2.0)은 `--env-file`을
지원하지 않아서, `k6 run`이 `--include-system-env-vars`(기본 true)로 읽는 실제 셸 환경변수로
넘겨야 한다:

```bash
cd k6
cp .env.example .env   # 값 채우기 (BASE_URL, SPIKE_VUS, DB_* 등)
set -a && source .env && set +a
```

**권장: `scripts/run.sh`로 실행** — k6를 돌리고, (#47) Worker 배출이 끝나길 기다려
`latency-report.sql`로 종단 지연을 계산한 뒤, `cleanup.sql`로 테스트 쿠폰을 자동 정리한다
(자세한 내용은 5-2, 7번). k6에 넘기고 싶은 추가 인자는 시나리오 이름 뒤에 그대로 붙인다:

```bash
./scripts/run.sh baseline
./scripts/run.sh spike
./scripts/run.sh spike -e SPIKE_VUS=3000   # 값 하나만 덮어쓰기
./scripts/run.sh scaleout                  # 몇 분간 지속되는 시나리오라 미리 Grafana 열어둘 것
                                            # (배출/정리 재시도 예산을 늘려야 할 수 있음 — 5-2, 7번 참고)
```

클러스터 대상은 `.env`의 `BASE_URL`/`SPIKE_VUS`/`DB_*`를 클러스터 값으로 바꾼 뒤 동일하게 실행한다.

자동 정리 없이 `k6 run`만 직접 돌리고 싶을 때(예: 정리 전 DB 상태를 눈으로 먼저 보고 싶을 때)는:

```bash
k6 run scenarios/baseline.js
k6 run -e BASE_URL=http://backend.<worker-tailscale-ip>.nip.io -e SPIKE_VUS=3000 scenarios/spike.js
```

이 경우 종단 지연은 5-2의 `latency-report.sql`을 직접 실행해서 계산한다.

### 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BASE_URL` | `http://localhost:3000` | 테스트 대상 |
| `COUPON_QUANTITY` | `100000`(baseline/spike) / `1000000`(scaleout) | setup()에서 생성할 테스트 쿠폰 총 수량 |
| `SPIKE_VUS` | `3000` | spike.js — 동시에 발급을 시도할 가상 사용자 수 (각자 정확히 1회 요청) |
| `SPIKE_MAX_DURATION` | `3m` | spike.js — 시나리오 최대 허용 시간 |
| `SCALEOUT_RATE` | `60` | scaleout.js — 목표 초당 요청 수. M3에서 확인한 커밋 TPS 상한(~30 ops/s)보다 의도적으로 높게 잡아 지속적인 초과 수요를 만듦 — M5에서 이 요청률이 뚫리는지가 관찰 포인트 |
| `SCALEOUT_RAMP_DURATION` | `2m` | scaleout.js — 0 → `SCALEOUT_RATE`로 올리는 램프업 시간 |
| `SCALEOUT_HOLD_DURATION` | `8m` | scaleout.js — `SCALEOUT_RATE`를 유지하는 시간 (HPA가 여러 단계로 반응할 시간을 벌어줌) |
| `SCALEOUT_RAMP_DOWN_DURATION` | `1m` | scaleout.js — 종료 전 램프다운 시간 |
| `SCALEOUT_PRE_VUS` / `SCALEOUT_MAX_VUS` | `300` / `2000` | scaleout.js — k6가 미리 띄워둘 VU 수 / 지연으로 쌓이는 요청까지 감당할 최대 VU 수 |
| `DB_HOST`/`DB_PORT`/`DB_USERNAME`/`DB_PASSWORD`/`DB_DATABASE` | 로컬 docker-compose 기준값 | `scripts/run.sh`의 `cleanup.sql`과 `latency-report.sql` 실행에 쓰는 Postgres 접속 정보 |

`SPIKE_VUS`를 낮은 값(예: 로컬 스모크 테스트는 200~500)으로 먼저 돌려서 스크립트가 정상 동작하는지
확인한 뒤, 클러스터에서 본 수치(수천 단위)로 올리는 것을 권장한다.

## 5. 결과 해석

### 5-1. API 응답 지연 (k6가 직접 측정)

`handleSummary()`가 실행할 때마다 `results/<scenario>-<timestamp>.md`(요약)와 `.json`(원본 전체
지표)을 남긴다. 요약에 포함되는 값:

- **RPS**: `http_reqs` 기준 초당 요청 수
- **API 응답 지연**: `http_req_duration`의 avg/p95/p99/max — **202 접수까지만** 잰 값이다. M4부터
  발급 API가 Valkey 판정 통과 시 즉시 202로 응답하고 RDB 저장은 Worker가 비동기로 처리하므로,
  DB 반영 여부는 이 지연에 포함되지 않는다
- **발급 요청 결과 분포**: 커스텀 카운터로 집계하며, API가 의도적으로 반환하는 정상 응답이라
  `http_req_failed`(네트워크/5xx 레벨 실패율)와는 별도로 본다

| 코드 | 의미 | k6 카운터 |
|---|---|---|
| 202 | 판정 통과, 큐 적재 완료(접수 성공) | `coupon_accepted_total` |
| 400 | 재고 소진 / 발급 기간 아님 | `coupon_sold_out_total` |
| 404 | 쿠폰 없음 (Valkey에 재고 워밍 안 됨) | `coupon_not_found_total` |
| 409 | 중복 발급 | `coupon_duplicate_total` |
| 503 | RabbitMQ publish 실패 — Valkey 예약을 롤백한 뒤 에러 반환("유령 차감" 방지, `coupons.service.ts`) | `coupon_unavailable_total` |

### 5-2. 종단 지연 (큐 적재 → Worker 저장 완료) — `latency-report.sql`

k6는 202 응답만 보고 실제 DB 반영 여부/시각을 알 수 없어서, "큐 적재부터 Worker가 실제로 배치
INSERT를 끝낼 때까지" 걸리는 지연은 k6 지표에 없다. 이 지연은 테스트가 끝난 뒤
`coupon_issues.requested_at`(RabbitMQ 발행 시각)과 `issued_at`(배치 저장 완료 시각)의 차이로
DB에서 직접 계산한다.

**`scripts/run.sh`로 실행했다면 자동으로 계산된다** — k6가 끝나면 `coupon_issues` row count가
두 번 연속 같게 나올 때까지 폴링해 Worker 배출 완료를 기다린 뒤(`DRAIN_POLL_ATTEMPTS`×
`DRAIN_POLL_INTERVAL`, 기본 12회×5초), `latency-report.sql`을 실행하고 결과를
`results/<scenario>-latency-<timestamp>.txt`에 남긴 다음에 `cleanup.sql`을 돌린다.
`scaleout`처럼 백로그가 깊어 배출이 오래 걸리는 시나리오는 기본 대기 예산(60초)이 부족할 수
있다 — 이 경우 row count가 계속 늘어난다는 경고가 뜨니, 다음처럼 예산을 늘려서 재실행한다:

```bash
DRAIN_POLL_ATTEMPTS=60 DRAIN_POLL_INTERVAL=15 ./scripts/run.sh scaleout   # 최대 15분까지 대기
```

`k6 run`을 직접 썼거나 자동 계산을 건너뛰고 싶다면 직접 실행한다 (**반드시 `cleanup.sql`보다
먼저** — cleanup이 `coupon_issues` 행을 지우면 계산할 데이터가 함께 사라진다):

```bash
PGPASSWORD=<DB_PASSWORD> psql -h <DB_HOST> -p <DB_PORT> -U <DB_USERNAME> -d <DB_DATABASE> \
  -f k6/scripts/latency-report.sql
```

`[k6-baseline]`/`[k6-spike]`/`[k6-scaleout]` 쿠폰 제목별로 건수·avg·p50·p95·p99·max(ms)를 보여준다.

API 응답 지연(5-1)과 종단 지연(5-2)을 나란히 보면, "즉시 응답은 빠른데 실제 반영은 얼마나
밀리는가"(큐 적체)가 드러난다 — 이 두 수치가 M3 vs M5 비교표(#49)의 핵심 입력이다.

## 6. Prometheus/Grafana와 함께 보기

클러스터 대상 실행 시, `k8s/monitoring`의 **Rush Coupon API** 대시보드와 함께 다음을 관찰한다:

- **API 파드의 HPA 확장 여부** — `kubectl -n rush-coupon get hpa --watch`, 대시보드 파드 수 패널.
  M3에서 API 파드가 3개에서 멈췄던 것과 비교
- **Worker 파드는 HPA가 없다 (`k8s/backend/base/worker/deployment.yaml`, `replicas: 2` 고정)** —
  큐 길이 기반 오토스케일링은 KEDA + RabbitMQ management API가 필요해 배포 시점에 범위 밖으로
  보류됐다. 그래서 부하를 얼마나 줘도 Worker 파드 수는 2에서 관찰상 변하지 않는다 — 이건
  버그가 아니라 현재 배포 구성의 알려진 제약이니, "Worker가 확장 안 됨"이 아니라 "Worker
  오토스케일링이 아직 없음"으로 M5 리포트에 그대로 기록한다. (KEDA 도입은 별도 백로그로 제안)
- **RabbitMQ 큐 길이 추이** (대시보드 큐 패널) — 순간 유입(spike)이 몰려도 고정 2대 Worker가
  정상적으로 배출해 큐 길이가 다시 0으로 돌아오는지, 아니면 계속 쌓이기만 하는지 확인 —
  Worker가 고정 대수라 이 배출 속도 자체가 M5의 실질적인 처리량 상한을 보여준다
- **DLQ 패널** — 재시도 끝에 DLQ로 격리되는 메시지가 있는지 (있다면 `docs/operations/dlq-recovery.md`
  참고)

Prometheus는 `emptyDir`(retention 3d)이라 결과는 테스트 직후에 캡처해야 한다
([fresh-environment-setup.md](../setup/fresh-environment-setup.md) 11번 참고). Worker 파드에는
`/metrics` 엔드포인트가 없어서 Worker 자체 처리 시간은 Grafana의 RabbitMQ exporter 패널(큐
길이·배출률)로 간접 관찰해야 한다.

## 7. 테스트 데이터 정리

`setup()`이 만드는 테스트 쿠폰은 제목이 `[k6-baseline] ...` / `[k6-spike] ...`로 시작한다. API에
`DELETE` 엔드포인트가 없어서, 반복 실행하면 `coupons`/`coupon_issues`에 테스트 데이터가 계속
쌓인다. [k6/scripts/cleanup.sql](../../k6/scripts/cleanup.sql)이 이 제목 접두사를 기준으로
`coupon_issues` → `coupons` 순서로(FK 제약 순서) 지운다.

**`scripts/run.sh`로 실행했다면 자동으로 정리된다** — k6가 끝나면 (5-2에서 설명한 배출 대기 +
`latency-report.sql` 실행을 먼저 마친 뒤) `.env`의 `DB_*` 값으로 `psql -f cleanup.sql`을
이어서 실행한다.

**높은 부하 시나리오(spike, scaleout)에서는 정리가 한 번에 안 될 수 있다.** M3는 원인이 락
대기열이었지만, M5는 원인이 다르다 — 5-2의 배출 대기(`DRAIN_POLL_ATTEMPTS`)가 끝난 뒤에도
RabbitMQ 큐에 아직 남아있던 메시지를 Worker가 계속 consume해 커밋할 수 있다. 그 커밋이
`coupon_issues` DELETE와 `coupons` DELETE 사이에 끼어들면 FK 제약 위반으로 트랜잭션 전체가
롤백된다. `run.sh`는 정리가 실패하면 기본 5회, 10초 간격으로 재시도한다
(`CLEANUP_ATTEMPTS`/`CLEANUP_RETRY_DELAY` 환경변수로 조정 가능).

`scaleout.js`처럼 몇 분간 초과 수요를 지속시킨 경우 재시도 예산을 넉넉히 늘린다:

```bash
CLEANUP_ATTEMPTS=30 CLEANUP_RETRY_DELAY=15 ./scripts/run.sh scaleout   # 최대 7.5분까지 재시도
```

그래도 실패하면 큐가 아직 안 비었다는 뜻이니, Grafana(큐 길이 패널)로 확인한 뒤 수동 정리를
다시 실행한다. `k6 run`을 직접 썼거나 `run.sh`가 DB에 TCP로 못 붙는 환경이라면 수동으로 정리한다:

```bash
# psql로 직접
PGPASSWORD=<DB_PASSWORD> psql -h <DB_HOST> -p <DB_PORT> -U <DB_USERNAME> -d <DB_DATABASE> -f k6/scripts/cleanup.sql

# 또는 컨테이너 안에서 (docker exec)
docker exec -i rush-coupon-postgres-local psql -U <DB_USERNAME> -d <DB_DATABASE> < k6/scripts/cleanup.sql   # 로컬
docker exec -i rush-coupon-postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB> < k6/scripts/cleanup.sql       # 클러스터 외부 Postgres
```

시드 쿠폰(`선착순 테스트 쿠폰`)은 제목이 `[k6-`로 시작하지 않아 영향받지 않는다.

## 8. 측정 결과

실제 클러스터 측정값(baseline/spike/scaleout 수치, API 응답 지연 vs 종단 지연, HPA/큐 길이
Grafana 캡처, M3 대비 비교)은
[m5-async-load-test-report.md](m5-async-load-test-report.md)에 정리했다 (#49 비교표의 원자료).
