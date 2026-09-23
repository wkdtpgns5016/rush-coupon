# k6 부하 테스트 가이드

## 요약

| 항목 | 내용 |
|---|---|
| 범위 | Issue #31 — `POST /coupons/:id/issue`(비관적 락 기반 발급 API) k6 부하 시나리오 작성 및 성능 측정 |
| 목적 | "정상 상태" 성능(baseline)과 "선착순 몰림" 상황의 한계(spike)를 측정해 병목(#32) 분석의 입력값을 만든다 |
| 관련 파일 | [k6/lib/](../../k6/lib/), [k6/scenarios/](../../k6/scenarios/), 측정 결과는 [m3-mvp-load-test-report.md](m3-mvp-load-test-report.md) |

---

## 1. 구성

```
k6/
  lib/
    helpers.js   # setup() 단계에서 테스트 전용 쿠폰을 생성
    report.js    # handleSummary()용 결과 리포트(RPS/지연시간/발급 결과 분포) 포맷터
  scenarios/
    baseline.js  # 단일 파드/소규모 트래픽 — 정상 상태 기준선
    spike.js     # 수천 명 동시 발급 — 스파이크/스트레스
  scripts/
    run.sh        # k6 실행 + 종료 후 cleanup.sql 자동 실행 래퍼
    cleanup.sql    # 테스트 전용 쿠폰([k6-* 접두사])과 발급 이력 삭제
  results/       # 실행 결과 (.md/.json), gitignore 대상
```

두 시나리오 모두 `setup()`에서 `POST /coupons`로 테스트 전용 쿠폰을 새로 만들어 쓴다. 시드 쿠폰(수량
10)을 재사용하지 않는 이유: 비관적 락은 **재고가 남아있든 소진됐든 행 락(row lock)부터 잡으므로**,
재고를 수요보다 훨씬 크게 잡아도(`COUPON_QUANTITY` 기본 100,000) 락 경합 자체는 그대로 재현된다.
따라서 재고 소진(400)이 아니라 락 대기로 인한 지연 증가를 관찰하는 데 집중할 수 있다.

각 발급 요청의 `userId`는 `exec.scenario.iterationInTest`(시나리오 전체에서 단조 증가하는 카운터)로
만든다. VU/반복 조합과 무관하게 항상 고유해서, 테스트 중 의도치 않은 중복 발급(409)이 섞여
결과가 왜곡되는 것을 막는다.

## 2. 사전 준비

- [k6](https://k6.io/) 설치 (`brew install k6` 등)
- 테스트 대상 backend가 떠 있고 `BASE_URL`로 접근 가능해야 함

## 3. 실행 대상 (`BASE_URL`)

| 대상 | BASE_URL | 비고 |
|---|---|---|
| 로컬 docker-compose | `http://localhost:3000` (기본값) | `cd backend && docker compose up -d` |
| k8s 클러스터 | `http://<INGRESS_HOST>` | [fresh-environment-setup.md](../setup/fresh-environment-setup.md) 5번의 Ingress 호스트. `/coupons`만 허용 목록에 있어 이 스크립트가 쓰는 경로(`POST /coupons`, `POST /coupons/:id/issue`)는 그대로 통과한다 |

로컬 실행은 스크립트 동작 검증(스모크 테스트) 용도다. **M3 vs M5 비교표에 쓸 공식 수치는 반드시
클러스터(`INGRESS_HOST`) 대상으로 측정한다** — ingress-nginx, HPA(2~10 파드), 파드 리소스
제한(CPU 100m/메모리 128Mi)이 로컬 docker-compose에는 없어서 진짜 병목이 재현되지 않는다.

## 4. 실행

`.env.example`을 복사해 값을 채운 뒤 셸에 불러와서 쓴다. 설치된 k6 버전(v2.2.0)은 `--env-file`을
지원하지 않아서, `k6 run`이 `--include-system-env-vars`(기본 true)로 읽는 실제 셸 환경변수로
넘겨야 한다:

```bash
cd k6
cp .env.example .env   # 값 채우기 (BASE_URL, SPIKE_VUS, DB_* 등)
set -a && source .env && set +a
```

**권장: `scripts/run.sh`로 실행** — k6를 돌리고, 끝나면 `cleanup.sql`로 테스트 쿠폰을 자동 정리한다
(자세한 내용은 7번). k6에 넘기고 싶은 추가 인자는 시나리오 이름 뒤에 그대로 붙인다:

```bash
./scripts/run.sh baseline
./scripts/run.sh spike
./scripts/run.sh spike -e SPIKE_VUS=3000   # 값 하나만 덮어쓰기
```

클러스터 대상은 `.env`의 `BASE_URL`/`SPIKE_VUS`/`DB_*`를 클러스터 값으로 바꾼 뒤 동일하게 실행한다.

자동 정리 없이 `k6 run`만 직접 돌리고 싶을 때(예: 정리 전 DB 상태를 눈으로 먼저 보고 싶을 때)는:

```bash
k6 run scenarios/baseline.js
k6 run -e BASE_URL=http://backend.<worker-tailscale-ip>.nip.io -e SPIKE_VUS=3000 scenarios/spike.js
```

### 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BASE_URL` | `http://localhost:3000` | 테스트 대상 |
| `COUPON_QUANTITY` | `100000` | setup()에서 생성할 테스트 쿠폰 총 수량 |
| `SPIKE_VUS` | `3000` | spike.js — 동시에 발급을 시도할 가상 사용자 수 (각자 정확히 1회 요청) |
| `SPIKE_MAX_DURATION` | `3m` | spike.js — 시나리오 최대 허용 시간 |
| `DB_HOST`/`DB_PORT`/`DB_USERNAME`/`DB_PASSWORD`/`DB_DATABASE` | 로컬 docker-compose 기준값 | `scripts/run.sh`가 종료 후 자동 정리(`cleanup.sql`)할 때 쓰는 Postgres 접속 정보. `k6 run`을 직접 쓸 땐 필요 없음 |

`SPIKE_VUS`를 낮은 값(예: 로컬 스모크 테스트는 200~500)으로 먼저 돌려서 스크립트가 정상 동작하는지
확인한 뒤, 클러스터에서 본 수치(수천 단위)로 올리는 것을 권장한다. 로컬 머신에서 수천 VU를 그대로
띄우면 k6 자체가 CPU/메모리 병목이 되어 결과가 왜곡될 수 있다.

## 5. 결과 해석

`handleSummary()`가 실행할 때마다 `results/<scenario>-<timestamp>.md`(요약)와 `.json`(원본 전체
지표)을 남긴다. 요약에 포함되는 값:

- **RPS**: `http_reqs` 기준 초당 요청 수
- **지연 시간**: `http_req_duration`의 avg/p95/p99/max
- **발급 결과 분포**: 발급 성공(201) / 재고 소진·기간 아님(400) / 중복 발급(409) / 예상치 못한 응답
  건수와 비율 — 커스텀 카운터(`coupon_issued_total` 등)로 집계하며, 이 세 가지는 API가 의도적으로
  반환하는 정상 응답이라 `http_req_failed`(네트워크/5xx 레벨 실패율)와는 별도로 본다

baseline과 spike의 p95/p99, 실패율을 나란히 비교하면 락 경합으로 인한 지연 증가 폭이 드러난다 —
이 수치가 #32(병목 분석) 및 최종 M3 vs M5 비교표의 입력이 된다.

## 6. Prometheus/Grafana와 함께 보기

클러스터 대상 실행 시, `k8s/monitoring`의 **Rush Coupon API** 대시보드(HTTP 패널: RPS, P95/P99,
발급 결과 분포)와 HPA(`kubectl -n rush-coupon get hpa backend --watch`)를 함께 열어두면 k6 결과와
클러스터 지표를 실시간으로 대조할 수 있다. Prometheus는 `emptyDir`(retention 3d)이라 결과는 테스트
직후에 캡처해야 한다 ([fresh-environment-setup.md](../setup/fresh-environment-setup.md) 11번 참고).

## 7. 테스트 데이터 정리

`setup()`이 만드는 테스트 쿠폰은 제목이 `[k6-baseline] ...` / `[k6-spike] ...`로 시작한다. API에
`DELETE` 엔드포인트가 없어서, 반복 실행하면 `coupons`/`coupon_issues`에 테스트 데이터가 계속
쌓인다. [k6/scripts/cleanup.sql](../../k6/scripts/cleanup.sql)이 이 제목 접두사를 기준으로
`coupon_issues` → `coupons` 순서로(FK 제약 순서) 지운다.

**`scripts/run.sh`로 실행했다면 자동으로 정리된다** — k6가 끝나자마자 `.env`의 `DB_*` 값으로
`psql -f cleanup.sql`을 이어서 실행한다 (k6가 실패해도 정리는 실행됨). 로컬 검증 결과:

```
$ ./scripts/run.sh spike
...
테스트 데이터 정리 중 (title LIKE '[k6-%')...
BEGIN
DELETE 100
DELETE 1
COMMIT
```

`k6 run`을 직접 썼거나, `run.sh`가 DB에 TCP로 못 붙는 환경(포트가 안 열려 있는 등)이라면 수동으로
정리한다:

```bash
# psql로 직접 (DB 포트가 호스트에 열려 있을 때 — 로컬은 backend/docker-compose.yml의 DB_LOCAL_PORT, 클러스터는 deploy/external-db의 POSTGRES_PORT)
PGPASSWORD=<DB_PASSWORD> psql -h <DB_HOST> -p <DB_PORT> -U <DB_USERNAME> -d <DB_DATABASE> -f k6/scripts/cleanup.sql

# 또는 컨테이너 안에서 (docker exec)
docker exec -i rush-coupon-postgres-local psql -U <DB_USERNAME> -d <DB_DATABASE> < k6/scripts/cleanup.sql   # 로컬
docker exec -i rush-coupon-postgres psql -U <POSTGRES_USER> -d <POSTGRES_DB> < k6/scripts/cleanup.sql       # 클러스터 외부 Postgres
```

시드 쿠폰(`선착순 테스트 쿠폰`)은 제목이 `[k6-`로 시작하지 않아 영향받지 않는다.

## 8. 측정 결과

실제 클러스터 측정값(baseline/spike 수치, Grafana 캡처, 원인 분석)은
[m3-mvp-load-test-report.md](m3-mvp-load-test-report.md)에 별도로 정리했다.
