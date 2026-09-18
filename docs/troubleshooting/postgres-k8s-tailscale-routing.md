# [트러블슈팅] k8s 파드에서 Tailscale 너머 외부 Postgres 접속 실패

## 요약

| 항목 | 내용 |
|---|---|
| 증상 | k8s 클러스터 내부 파드에서 Mac(Tailscale) 위 Postgres로 접속 시 타임아웃 |
| 원인 | Tailscale의 전용 라우팅 테이블이 **포워딩되는 트래픽에는 적용되지 않음** |
| 해결 | 워커 노드 메인 라우팅 테이블에 `100.64.0.0/10 dev tailscale0` 라우트 명시적 추가 (systemd로 영구화) |
| 소요 시간 | 약 2시간 (원인 파악에 대부분 소요) |

---

## 1. 환경

```
Mac (macOS, Tailscale: 100.113.87.50)
  └─ Docker Compose로 Postgres 구동 (0.0.0.0:5432 매핑, listen_addresses='*')

VirtualBox VM 2대 (Host-Only 네트워크 192.168.56.0/24)
  ├─ k8s-master (192.168.56.10, control-plane, NoSchedule taint)
  │    └─ Tailscale 설치, subnet router로 192.168.56.0/24 advertise
  └─ k8s-worker (192.168.56.20, 실제 워크로드가 뜨는 노드)
       └─ Tailscale 설치 (같은 tailnet에 peer로 join, advertise-routes 없음)

k8s: kubeadm + Calico CNI, Pod CIDR 10.244.0.0/16
```

목표: k8s 파드 → `postgres-service` (Service/Endpoints, 셀렉터 없이 `100.113.87.50:5432`를 직접 가리킴) → Mac의 Postgres

---

## 2. 증상

```bash
kubectl run pgtest --rm -i --restart=Never -n rush-coupon \
  --image=postgres:16-alpine --command -- pg_isready -h 100.113.87.50 -p 5432
# => 100.113.87.50:5432 - no response
```

- Mac에서 자기 자신의 Tailscale IP로 접속: **성공**
- macOS 방화벽: 비활성화 상태 (원인 아님)
- Postgres 컨테이너: healthy, `listen_addresses='*'` (원인 아님)

---

## 3. 진단 과정

### 3-1. 노드 자체는 되는데 파드는 안 됨

`hostNetwork: true`로 워커 노드 네트워크를 그대로 쓰는 테스트 파드를 띄워보니 **성공**.

```bash
kubectl run hostnet-test --rm -i --restart=Never -n rush-coupon \
  --overrides='{"spec":{"hostNetwork":true,"nodeName":"k8s-worker"}}' \
  --image=postgres:16-alpine --command -- pg_isready -h 100.113.87.50 -p 5432
# => 100.113.87.50:5432 - accepting connections
```

→ 워커 노드 자체는 Tailscale로 Mac까지 도달 가능. 문제는 **일반 파드(Calico 오버레이) 트래픽**에 한정됨.

### 3-2. Calico NAT 설정 확인

```bash
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E "name:|natOutgoing|cidr"
# natOutgoing: true  → 정상
```

### 3-3. 라우팅 정책 확인

```bash
ip rule show
# 5270: from all lookup 52   ← tailscale 전용 테이블, 소스 제한 없어 보임

ip route show table 52
# 100.113.87.50 dev tailscale0   ← 목적지 라우트는 존재

ip route show table main
# default via 10.0.2.2 dev enp0s3   ← 메인 테이블엔 tailscale 관련 라우트가 전혀 없음
```

`ip rule`만 보면 모든 트래픽이 table 52를 타야 할 것처럼 보였지만, 실제로는 그렇지 않았음 (아래 3-4에서 실측으로 확인).

### 3-4. tcpdump로 실측 (결정적 증거)

privileged 디버그 파드(`hostNetwork`, `hostPID`, `privileged: true`)를 워커 노드에 띄워서, 파드가 연결을 시도하는 동안 `any` 인터페이스를 캡처:

```
calie88c2818eeb In  IP 10.244.254.131.39180 > 100.113.87.50.5432: Flags [S]   # 파드에서 나온 SYN
enp0s3          Out IP 10.0.2.15.56007 > 100.113.87.50.5432: Flags [S]        # tailscale0가 아니라 NAT 어댑터로 나감!
enp0s3          In  IP 100.113.87.50.5432 > 10.0.2.15.48135: Flags [R.]       # 엉뚱한 곳에서 RST 응답
```

**파드에서 나온 패킷이 `tailscale0`가 아니라 메인 라우팅 테이블의 기본 라우트(`enp0s3`, VirtualBox NAT 어댑터)를 타고 인터넷으로 새고 있었음.**

---

## 4. 근본 원인

Tailscale의 정책 라우팅(`ip rule` + 전용 테이블 52)은 **이 노드에서 직접 생성된(로컬 프로세스가 만든) 패킷에만 적용**된다. k8s 파드에서 온 트래픽은 이 노드 입장에서 "포워딩되는" 트래픽이라, 커널이 라우팅 결정을 할 때 tailscale 전용 테이블을 타지 않고 **메인 라우팅 테이블의 기본 라우트**로 빠져버린다. 메인 테이블에는 애초에 Tailscale 대역(`100.64.0.0/10`)으로 가는 라우트가 등록되어 있지 않았기 때문에, 결국 일반 인터넷 게이트웨이(VirtualBox NAT)로 나가서 실패했다.

즉, `hostNetwork` 파드(=노드가 직접 만든 패킷)는 되고, 일반 파드(=Calico를 거쳐 포워딩되는 패킷)는 안 되는 차이가 정확히 이 지점에서 발생함.

---

## 5. 해결

메인 라우팅 테이블에 Tailscale CGNAT 대역(`100.64.0.0/10`)을 `tailscale0`로 보내는 라우트를 명시적으로 추가한다.

```bash
# 즉시 적용 (재부팅하면 사라짐)
sudo ip route add 100.64.0.0/10 dev tailscale0
```

**영구 적용** — `tailscale0`는 tailscaled가 매번 새로 만드는 인터페이스라 netplan으로 직접 관리하기 애매하므로, tailscaled 시작 이후 라우트를 등록하는 systemd 서비스를 사용:

```ini
# /etc/systemd/system/tailscale-pod-route.service
[Unit]
Description=Route pod-forwarded traffic through tailscale0
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 30); do [ "$(cat /sys/class/net/tailscale0/operstate 2>/dev/null)" = "up" ] && break; sleep 1; done; ip route replace 100.64.0.0/10 dev tailscale0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-pod-route.service
```

> `ip route replace`를 사용해 이미 라우트가 있어도 에러 없이 재실행 가능하도록 했다.
>
> **`After=`/`Requires=tailscaled.service`만으로는 부족했다** — 실제로 재부팅해서 겪은 문제: systemd가 "tailscaled.service 시작됨"으로 판단하는 시점과, tailscaled가 실제로 `tailscale0` 인터페이스를 UP 상태로 올리는 시점이 다르다. 그 사이에 이 유닛이 실행되면 `ip route replace`가 `Error: Device for nexthop is not up.`로 실패하고, 재시도 로직이 없어 그대로 끝나버린다 (`enabled` 상태인데도 라우트가 안 들어가 있는 것처럼 보임). 그래서 `ExecStart`에 인터페이스가 UP 될 때까지 최대 30초 재시도하는 루프를 추가했다.
>
> **재시도 체크 방식도 처음엔 잘못 짚었다** — 처음엔 `ip link show tailscale0 up`으로 체크했는데, 이 명령은 인터페이스가 아직 안 올라와 있어도 "필터에 안 걸려서 빈 결과"일 뿐 exit code는 0(성공)으로 나온다. 그래서 반복문이 첫 시도에 바로 "성공"으로 오판하고 break해버리고, 뒤이은 `ip route replace`는 여전히 실패했다 (재부팅해서 실제로 재현/확인함). `/sys/class/net/tailscale0/operstate` 파일로 실제 링크 상태(`up`/`down`)를 직접 읽는 걸로 바꿔서 해결.

---

## 6. 검증

```bash
# 1) 워커 노드 라우트 확인
ip route show table main | grep 100.64
# 100.64.0.0/10 dev tailscale0 scope link

# 2) 파드에서 직접 IP로 접속
kubectl run pgtest --rm -i --restart=Never -n rush-coupon \
  --image=postgres:16-alpine --command -- pg_isready -h 100.113.87.50 -p 5432
# => accepting connections

# 3) k8s Service(postgres-service) 경유 + 실제 쿼리까지 확인
kubectl run pgtest-final --rm -i --restart=Never -n rush-coupon \
  --image=postgres:16-alpine --command -- sh -c \
  "pg_isready -h postgres-service -p 5432 && \
   PGPASSWORD=*** psql -h postgres-service -U coupon_user -d rush_coupon -c 'select 1;'"
# => 1 row 정상 반환
```

---

## 7. 관련 k8s 리소스

`postgres-service`는 `kustomize`로 관리하며, Mac의 Tailscale IP를 셀렉터 없는 `Endpoints`로 직접 지정한다.

```
k8s/database/
  base/
    namespace.yaml       # rush-coupon 네임스페이스
    service.yaml          # postgres-service (port 5432)
    endpoints.yaml         # placeholder IP → overlay에서 치환
    kustomization.yaml
  overlays/local/
    db-connection.env          # 실제 Tailscale IP (gitignore)
    db-connection.env.example  # 템플릿
    kustomization.yaml         # configMapGenerator + replacements로 IP 주입
```

```bash
kubectl apply -k k8s/database/overlays/local
```

> `v1 Endpoints`는 k8s 1.33+부터 deprecated (동작은 함, `discovery.k8s.io/v1 EndpointSlice`로 전환 권장). mirroring controller가 자동으로 대응 EndpointSlice를 생성해줌.

---

## 8. 체크리스트 (같은 문제 재발 시)

- [ ] `hostNetwork` 테스트 파드로 "노드는 되는데 파드는 안 되는지" 먼저 구분
- [ ] `ip route show table main`에 목적지 대역으로 가는 라우트가 있는지 확인 (Tailscale/WireGuard류는 보통 전용 테이블만 쓰고 메인 테이블엔 안 넣어줌)
- [ ] 애매하면 추측하지 말고 **tcpdump로 실제 나가는 인터페이스를 확인**해서 근거를 확보
- [ ] 새 워커 노드를 추가하거나 VM을 재생성할 경우, `tailscale-pod-route.service`도 같이 세팅해야 함 (Tailscale 설치만으로는 파드 트래픽까지 자동으로 라우팅되지 않음)
- [ ] `tailscale-pod-route.service`가 `enabled`인데도 라우트가 없다면, `systemctl status tailscale-pod-route.service`로 재부팅 시 실제로 성공했는지부터 확인 (`enabled` ≠ 마지막 실행이 성공했다는 뜻이 아님 — `After=tailscaled.service`만으로는 인터페이스가 실제 UP 되기 전에 실행돼서 실패할 수 있음)
