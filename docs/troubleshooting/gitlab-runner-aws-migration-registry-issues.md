# [트러블슈팅] GitLab+Runner를 AWS EC2로 옮길 때 겪은 레지스트리/인증 이슈 3가지

## 요약

| 항목 | 내용 |
|---|---|
| 배경 | M6 #54 — GitLab CE+Runner를 AWS EC2(private subnet)로 이전, 기존 온프레미스 클러스터 대상 CI/CD 검증 |
| 이슈 1 | GitLab 레지스트리(평문 HTTP)를 쓰는 daemon마다 insecure-registry 설정을 따로 갱신해야 함 — EC2 자체의 dockerd, k8s-worker의 containerd 둘 다 |
| 이슈 2 | Alpine `aws-cli` 패키지가 musl libc와 안 맞아 `pyexpat` relocation 에러로 깨짐 |
| 이슈 3 | 컨테이너에서 EC2 IAM 인스턴스 프로파일 자격증명을 가져오려면 IMDS hop-limit을 2로 올려야 함 |
| 관련 이슈 | #54 |

---

## 이슈 1. GitLab 레지스트리 IP가 바뀌면, 그 레지스트리를 쓰는 daemon마다 insecure-registry 설정을 따로 갱신해야 한다

### 증상

GitLab+Runner를 새 EC2로 옮기고 나서:
- `backend-build` job의 `docker login`이 `Get "https://<새IP>:5050/v2/": http: server gave HTTP response to HTTPS client`로 실패
- deploy 브랜치에 새 이미지 태그가 반영된 뒤에도, 온프레미스 클러스터의 새 파드가 `ImagePullBackOff` — 이벤트 메시지도 완전히 동일한 `http: server gave HTTP response to HTTPS client`

### 원인

GitLab Container Registry는 TLS 없이 평문 HTTP로 띄워져 있다(Tailscale 자체가 WireGuard로 암호화해주므로 TLS는 의도적으로 생략, [[cicd_gitlab_mirror_setup]] 참고). Docker/containerd는 기본적으로 레지스트리에 HTTPS로 접속을 시도하므로, "이 호스트는 HTTP로 접속해도 된다"는 예외를 **레지스트리에 접속하는 daemon마다 개별적으로** 등록해줘야 한다.

문제는 이 레지스트리에 접속하는 daemon이 두 곳이라는 점이다:
1. **`backend-build` job을 실행하는 docker daemon** — GitLab+Runner가 어떤 머신에 있든, 그 머신의 dockerd
2. **`backend-deploy`가 배포한 이미지를 실제로 받아오는 k8s-worker의 containerd**

기존 온프레미스 구성(Mac 위에서 GitLab+Runner 구동)에서는 1번이 Mac의 Docker Desktop이라 `~/.docker/daemon.json`에 등록했었다. 이번에 GitLab+Runner를 EC2로 옮기면서 1번이 EC2의 dockerd로 바뀌었는데, **2번(k8s-worker의 containerd)은 레지스트리 호스트가 그대로 유지될 거라 생각해서 갱신을 빼먹었다** — 그런데 애초에 GitLab 자체가 새 IP로 옮겨졌으니 2번도 당연히 갱신 대상이었다.

### 해결

**EC2(dockerd)**: `/etc/docker/daemon.json`에 등록 후 재시작.
```bash
echo '{"insecure-registries": ["<새 GitLab IP>:5050"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```
(재생성 대비, `terraform/gitlab-runner/user_data.sh.tpl`에 자동화해둠 — 인스턴스가 자기 자신의 Tailscale IP를 `tailscale ip -4`로 알아내서 스스로 등록)

**k8s-worker(containerd)**: 기존 `docs/setup/fresh-environment-setup.md` 9번 절차를 새 IP로 반복.
```bash
sudo mkdir -p "/etc/containerd/certs.d/<새IP>_5050_"   # 콜론 대신 언더스코어, 끝에도 언더스코어
sudo tee "/etc/containerd/certs.d/<새IP>_5050_/hosts.toml" <<'EOF'
server = "http://<새IP>:5050"

[host."http://<새IP>:5050"]
  capabilities = ["pull", "resolve"]
EOF
sudo systemctl restart containerd
```
재시작 직후 kubelet이 backoff 타이머 때문에 바로 재시도 안 할 수 있으니, 실패 중인 파드를 지워서 강제로 재시도시키면 빠르다.

### 교훈

레지스트리 자체의 주소가 바뀌면, "그 레지스트리를 신뢰해야 하는 모든 daemon" 목록을 먼저 나열하고 하나씩 확인해야 한다. 이번처럼 "GitLab을 옮기는 작업"과 "온프레미스 클러스터 설정을 건드리는 작업"이 서로 다른 인프라(AWS vs 온프레미스)에 속해 있으면, 후자를 깜빡하기 쉽다 — insecure-registry 설정은 레지스트리가 아니라 **그걸 쓰는 쪽**에 있다는 게 놓치기 쉬운 지점이다.

---

## 이슈 2. Alpine `aws-cli` 패키지가 musl libc와 호환되지 않아 실행 자체가 깨진다

### 증상

`backend-build`에서 ECR push를 위해 `apk add --no-cache aws-cli` 후 `aws ecr get-login-password` 실행 시:
```
Error relocating /usr/lib/python3.12/lib-dynload/pyexpat.cpython-312-x86_64-linux-musl.so: XML_SetAllocTrackerActivationThreshold: symbol not found
Error: Cannot perform an interactive login from a non TTY device
```
(두 번째 에러는 첫 번째 에러 때문에 `aws ecr get-login-password`가 빈 값을 출력해서, `docker login --password-stdin`이 빈 비밀번호로 인터랙티브 로그인을 시도하다 난 것 — 실제 원인은 첫 줄이다)

### 원인

Alpine의 `aws-cli`(v2, Python 기반) apk 패키지가 musl libc 환경에서 `pyexpat` 네이티브 확장 모듈과 심볼 호환성 문제를 일으키는, 알려진 이슈다. `docker:24-cli` 이미지가 Alpine 기반이라 이 문제를 그대로 물려받는다.

### 해결

Python 기반 aws-cli 대신, 정적 컴파일된 Go 바이너리인 `amazon-ecr-credential-helper`(`docker-credential-ecr-login`)를 사용한다. musl 의존성이 없어서 Alpine에서도 문제없이 동작한다.

```yaml
- apk add --no-cache curl jq
- curl -fsSL -o /usr/local/bin/docker-credential-ecr-login
  https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/0.12.0/linux-amd64/docker-credential-ecr-login
- chmod +x /usr/local/bin/docker-credential-ecr-login
- jq --arg host "${ECR_REPOSITORY_URL%%/*}" '.credHelpers[$host] = "ecr-login"'
  "$HOME/.docker/config.json" > /tmp/docker-config.json && mv /tmp/docker-config.json "$HOME/.docker/config.json"
```
기존 GitLab 레지스트리용 `docker login`이 이미 써놓은 `auths` 항목은 그대로 두고, `credHelpers`만 jq로 병합해서 추가해야 두 레지스트리 인증이 공존한다(하나를 통째로 덮어쓰면 다른 쪽 인증이 날아간다).

### 교훈

Alpine 기반 이미지에서 Python 기반 CLI 도구를 apk로 설치할 때는 musl 호환성을 의심해봐야 한다. 가능하면 정적 컴파일된 바이너리(Go, Rust 등)로 대체하는 게 이런 부류의 문제를 원천 차단한다.

---

## 이슈 3. 컨테이너 안에서는 기본 설정으로 EC2 IAM 자격증명을 못 가져온다 (IMDS hop-limit)

### 증상

이슈 2를 해결한 뒤에도, docker executor 컨테이너 안에서 실행되는 `docker-credential-ecr-login`(또는 aws-cli)이 EC2 인스턴스 프로파일의 자격증명을 못 가져와서 인증에 실패할 수 있다.

### 원인

EC2 인스턴스 메타데이터 서비스(IMDSv2)는 기본적으로 `http-put-response-hop-limit=1`로 설정되어 있다. 호스트에서 직접 요청하면 1홉이라 문제없지만, **컨테이너 안에서의 요청은 호스트를 거쳐 한 홉 더** 추가되기 때문에, 기본값(1)에서는 컨테이너가 IMDS에 도달하지 못한다. 컨테이너화된 워크로드에서 흔히 보고되는 문제다.

### 해결

인스턴스의 hop-limit을 2로 올린다.
```bash
aws ec2 modify-instance-metadata-options --instance-id <id> --http-put-response-hop-limit 2
```
`terraform/gitlab-runner/ec2.tf`의 `aws_instance` 리소스에도 반영해서, 인스턴스를 재생성해도 자동으로 적용되게 해뒀다:
```hcl
metadata_options {
  http_put_response_hop_limit = 2
}
```
이 옵션은 EC2 인스턴스의 update-in-place 속성이라, 재생성 없이 바로 적용된다.

### 교훈

GitLab Runner처럼 **컨테이너 안에서 AWS API를 호출하는 CI/CD 워크로드**를 EC2 인스턴스 역할 기반으로 인증시키려면, IMDS hop-limit을 처음부터 2로 잡아두는 게 안전하다 — 기본값(1)은 "호스트에서 직접 호출"만 가정한 값이다.

## 관련 파일
- [terraform/gitlab-runner/](../../terraform/gitlab-runner/) — 이슈 1(EC2 쪽)·3의 자동화가 반영된 Terraform 스택
- [.gitlab-ci.yml](../../.gitlab-ci.yml) — 이슈 1(GitLab 레지스트리 로그인)·2의 해결이 반영된 `backend-build` job
- [docs/setup/fresh-environment-setup.md](../setup/fresh-environment-setup.md) — 이슈 1의 k8s-worker 쪽 절차(9번)가 원래 문서화되어 있던 곳
