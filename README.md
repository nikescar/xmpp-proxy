
<h1 align="center">
  <br>
  <img src="https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/master/contrib/logo/xmpp_proxy_color.png" alt="logo" width="200">
  <br>
  xmpp-proxy
  <br>
  <br>
</h1>

[![Build Status](https://ci.moparisthe.best/job/moparisthebest/job/xmpp-proxy/job/master/badge/icon%3Fstyle=plastic)](https://ci.moparisthe.best/job/moparisthebest/job/xmpp-proxy/job/master/)

xmpp-proxy는 XMPP 서버와 클라이언트를 위한 리버스 프록시 및 아웃고잉 프록시로, XML 파서 없이 [STARTTLS], [Direct TLS], [QUIC],
[WebSocket C2S], [WebSocket S2S], [WebTransport] 연결을 일반 텍스트 XMPP 서버 및 클라이언트에 제공하고 stanza 크기를 제한합니다.

리버스 프록시(수신) 모드의 xmpp-proxy는:
  1. 임의의 개수의 인터페이스/포트에서 수신 대기
  2. 인터넷에서 STARTTLS, Direct TLS, QUIC, WebSocket 또는 WebTransport c2s 또는 s2s 연결 수락
  3. TLS 종료
  4. s2s의 경우 클라이언트 인증서를 요구하고 SASL EXTERNAL 인증을 위해 올바르게 검증 (CA, host-meta, host-meta2, POSH 사용)
  5. 일반 텍스트 TCP를 통해 로컬 실제 XMPP 서버에 연결
  6. 구성된 경우 [PROXY protocol] v1 헤더를 전송하여 XMPP 서버가 실제 클라이언트 IP를 알 수 있도록 함
  7. 구성된 대로 수신 stanza 크기 제한

아웃고잉 모드의 xmpp-proxy는:
  1. 임의의 개수의 인터페이스/포트에서 수신 대기
  2. 로컬 XMPP 서버 또는 클라이언트로부터 일반 텍스트 TCP 또는 WebSocket 연결 수락
  3. 필요한 SRV, [host-meta], [host-meta2], [POSH] 레코드 조회
  4. 인터넷을 통해 STARTTLS, Direct TLS, QUIC, WebSocket 또는 WebTransport로 실제 XMPP 서버에 연결
  5. 완전히 연결하기 위해 필요한 경우 다음 SRV 대상 또는 기본값으로 폴백
  6. 모든 필수 인증서 검증 로직 수행
  7. 구성된 대로 수신 stanza 크기 제한

#### 설치
  * `cargo install xmpp-proxy`
  * [xmpp-proxy](https://code.moparisthebest.com/moparisthebest/xmpp-proxy/releases) 또는
    [xmpp-proxy (github mirror)](https://github.com/moparisthebest/xmpp-proxy/releases)에서 정적 바이너리 다운로드
  * 선호하는 패키지 매니저 사용

#### 구성
  * `mkdir /etc/xmpp-proxy/ && cp xmpp-proxy.toml /etc/xmpp-proxy/`
  * `/etc/xmpp-proxy/xmpp-proxy.toml` 파일을 필요에 따라 편집, 파일에 주석으로 명확히 설명되어 있음
  * TLS 키/인증서를 `/etc/xmpp-proxy/`에 배치
  * 예제 systemd 유닛이 xmpp-proxy.service에 제공되며 최소 권한으로 잠김. 권한을 올바르게 설정해야 함:
    `chown -Rv 'systemd-network:' /etc/xmpp-proxy/`
  * xmpp-proxy 시작: `Usage: xmpp-proxy [/path/to/xmpp-proxy.toml (기본값 /etc/xmpp-proxy/xmpp-proxy.toml]`

#### 실행 중인 Prosody 구성을 이것을 사용하도록 어떻게 조정하나요?

여기에는 2가지 옵션이 있습니다. xmpp-proxy를 리버스 프록시로만 사용하거나, 리버스 및 아웃고잉 프록시 모두로 사용할 수 있습니다. 둘 다 설명하겠습니다:

###### 리버스 프록시 및 아웃고잉 프록시

이 모드에서 Prosody는 TLS를 전혀 수행할 필요가 없으므로 인증서가 필요하지 않습니다. xmpp-proxy는 적절한 TLS 인증서가 필요합니다.
Prosody의 TLS 키를 `/etc/xmpp-proxy/le.key`로, TLS 인증서를 `/etc/xmpp-proxy/fullchain.cer`로 이동하고,
제공된 `xmpp-proxy.toml` 구성을 그대로 사용하세요.

`/etc/prosody/prosody.cfg.lua`를 편집하고 modules_enabled에 다음을 추가하세요:
```
"net_proxy";
```
prosody-modules가 업데이트될 때까지 제 포크 [mod_net_proxy.lua](https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua)를 사용하세요.

다음 구성을 추가하세요:
```
-- localhost에서만 수신 대기
interfaces = { "127.0.0.1" }

-- prosody가 암호화를 수행할 필요가 없음, 이제 xmpp-proxy가 수행
-- 이것들은 파일 어딘가에 true로 설정되어 있을 수 있으므로 찾아서 false로 변경
-- 구성에서 모든 인증서도 제거할 수 있음
s2s_require_encryption = false
s2s_secure_auth = false
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

-- xmpp-proxy 아웃고잉이 이 포트에서 수신 대기 중, 모든 아웃고잉 s2s 연결을 여기로 직접 연결
proxy_out = { "127.0.0.1", 15270 }
-- 프록시와의 연결을 안전하다고 표시, xmpp-proxy가 이를 보장
proxy_secure = true

-- 이 포트에서 PROXY 프로토콜 처리
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- 일반 c2s/s2s 포트에서 수신 대기 안 함 (이제 xmpp-proxy가 이 포트에서 수신 대기)
-- 구성 파일 아래쪽에 설정된 경우 주석 처리해야 할 수 있음
c2s_ports = {}
legacy_ssl_ports = {}
-- 아웃고잉 S2S가 작동하려면 최소 하나의 s2s_ports가 정의되어야 함, 묻지 마세요..
s2s_ports = {15268}
```

###### 리버스 프록시만, Prosody가 직접 아웃고잉 연결 수행

이 모드에서 Prosody와 xmpp-proxy 모두 적절한 TLS 인증서가 필요합니다. Prosody의 TLS 키를 `/etc/xmpp-proxy/le.key`로,
TLS 인증서를 `/etc/xmpp-proxy/fullchain.cer`로 복사하고, 제공된 `xmpp-proxy.toml` 구성을 그대로 사용하세요.

`/etc/prosody/prosody.cfg.lua`를 편집하고 modules_enabled에 다음을 추가하세요:
```
"net_proxy";
```
prosody-modules가 업데이트될 때까지 제 포크 [mod_net_proxy.lua](https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua)를 사용하세요.

다음 구성을 추가하세요:
```
-- 프록시로부터의 연결을 안전하다고 표시, xmpp-proxy가 이를 보장
proxy_secure_in = true

-- 이 포트에서 PROXY 프로토콜 처리
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- 일반 c2s/s2s 포트에서 수신 대기 안 함 (이제 xmpp-proxy가 이 포트에서 수신 대기)
-- 구성 파일 아래쪽에 설정된 경우 주석 처리해야 할 수 있음
c2s_ports = {}
legacy_ssl_ports = {}
-- 아웃고잉 S2S가 작동하려면 최소 하나의 s2s_ports가 정의되어야 함, 묻지 마세요..
s2s_ports = {15268}
```

#### 빌드 커스터마이징

정확히 원하는 기능만으로 xmpp-proxy를 빌드하고 싶은 까다로운 파워 유저라면, 이 섹션이 당신을 위한 것입니다!

xmpp-proxy는 여러 컴파일 타임 기능을 가지고 있으며, 일부는 필수입니다. 다음과 같이 그룹화됩니다:

1-4개의 방향 중 선택:
  1. `c2s-incoming` - 서버가 수신 c2s 연결을 수락할 수 있게 함
  2. `c2s-outgoing` - 클라이언트가 아웃고잉 c2s 연결을 만들 수 있게 함
  3. `s2s-incoming` - 서버가 수신 s2s 연결을 수락할 수 있게 함
  4. `s2s-outgoing` - 서버가 아웃고잉 s2s 연결을 만들 수 있게 함

1-4개의 전송 프로토콜 중 선택:
  1. `tls` - STARTTLS/TLS 지원 활성화
  2. `quic` - QUIC 지원 활성화
  3. `websocket` - WebSocket 지원 활성화, 적절한 방향이 활성화된 경우 TLS 수신 지원도 활성화
  4. `webtransport` - WebTransport 지원 활성화, QUIC도 활성화

신뢰할 수 있는 CA 루트를 가져오는 다음 방법 중 정확히 1개 선택, `c2s-incoming`만 활성화된 경우 필요 없음:
  1. `tls-ca-roots-native` - 운영 체제에서 CA 루트 읽기
  2. `tls-ca-roots-bundled` - `webpki-roots` 프로젝트에서 CA 루트를 바이너리에 번들

다음 선택적 기능 중 아무거나 선택:
  1. `logging` - 구성 가능한 로깅 활성화

따라서 리버스 프록시 STARTTLS/TLS만 지원하고 QUIC는 지원하지 않도록 빌드하려면: `cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls`
리버스 프록시만 지원하지만 STARTTLS/TLS/QUIC 모두 지원하도록 빌드하려면: `cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls,quic`

#### 개발

1. `check-all-features.sh`는 지원되는 모든 기능 순열로 컴파일을 확인하는 데 사용됩니다
2. `integration/test.sh`는 [Rootless podman](https://wiki.archlinux.org/title/Podman#Rootless_Podman)을 사용하여 실제 네트워크에서
   실제 dns, web, xmpp 서버와 함께 xmpp-proxy를 통해 많은 테스트를 실행합니다. 커밋을 푸시하기 전에 이 모든 테스트가 통과해야 하며,
   새 기능을 다루는 새 테스트를 작성하세요.
3. 코드 변경 사항을 제출하려면 [github](https://github.com/moparisthebest/xmpp-proxy) 또는
   [code.moparisthebest.com](https://code.moparisthebest.com/moparisthebest/xmpp-proxy)에 PR을 제출하거나
   이메일, XMPP, fediverse 또는 carrier pigeon을 통해 패치를 보내주세요.

#### Docker Compose 배포

다음을 제공하는 완전한 Docker Compose 스택이 포함되어 있습니다:
  * **Prosody XMPP 서버** (prosodyim/prosody:13.0) MAM, carbons, 웹 관리자 활성화
  * **xmpp-proxy** (STARTTLS/TLS/QUIC/WebSocket 지원을 위한 리버스 프록시 및 아웃고잉 프록시)
  * **nginx** (Let's Encrypt를 위한 ACME HTTP-01 챌린지 처리 및 동적 리버스 프록시)
  * **fail2ban-rs** (속도 제한 및 남용 방지)
  * **Horust** (강화된 distroless 컨테이너에서 nginx, xmpp-proxy, fail2ban-rs, 인증서 갱신을 위한 프로세스 감독) - 자세한 내용은 아래 [Distroless 배포](#distroless-배포-권장) 참조
  * acme.sh를 사용한 자동 TLS 인증서 관리
  * 클라이언트 IP 보존을 위한 PROXY 프로토콜 지원
  * 포트 5280에서 WebSocket 지원
  * 전체 백업 및 복원 스크립트

###### 빠른 시작

1. 예제 환경 파일을 복사하고 편집:
   ```
   cp .env.example .env
   nano .env
   ```
   최소한 설정: `XMPP_DOMAIN`, `ACME_EMAIL`

2. 스택 시작 (게시된 `ghcr.io/nikescar/xmpp-proxy-stack` 이미지를 가져옴,
   빌드 불필요):
   ```
   docker compose up -d
   ```
   저장소 업데이트를 가져온 후 `docker compose pull`을 다시 실행하여 최신 이미지를 받으세요.
   대신 소스에서 xmpp-proxy-stack을 빌드하려면 - 예: Dockerfile 또는 `nginx-proxy-ctl` 작업 시 -
   `docker-compose.dev.yaml` 사용:
   ```
   docker compose -f docker-compose.dev.yaml build
   docker compose -f docker-compose.dev.yaml up -d
   ```

3. 스택이 노출하는 포트:
   * `5222/tcp` - XMPP C2S (STARTTLS)
   * `5223/tcp` - XMPP C2S (Direct TLS)
   * `5269/tcp` - XMPP S2S (Server-to-Server)
   * `443/udp` - XMPP over QUIC
   * `5280/tcp` - HTTP/WebSocket (BOSH 및 WebSocket 클라이언트용)
   * `80/tcp` - HTTP (ACME 챌린지만)

4. 데이터는 `/srv/xmpp/`에 유지됩니다:
   * `prosody/` - Prosody 데이터 (계정, 메시지 등)
   * `certs/` - TLS 인증서
   * `logs/` - 모든 서비스 로그
   * `fail2ban/` - fail2ban-rs 데이터베이스
   * `acme/` - acme.sh 계정 및 인증서 상태

5. 백업 및 복원:
   ```
   ./scripts/backup.sh      # /srv/xmpp/backups/에 타임스탬프가 찍힌 백업 생성
   ./scripts/restore.sh /path/to/backup.tar.gz
   ```

###### 아키텍처

Docker 배포는 두 개의 컨테이너를 사용합니다:
  * **prosody** - localhost 전용 포트에서 PROXY 프로토콜 지원이 활성화된 Prosody XMPP 서버 실행
  * **xmpp-proxy-stack** - distroless 이미지에 xmpp-proxy, nginx, fail2ban-rs를 번들로 포함하고, Horust가 감독하며, PROXY 프로토콜 지원을 위해 호스트 네트워킹 사용

Prosody는 localhost:15222 (C2S) 및 localhost:15269 (S2S)에서 수신 대기합니다. xmpp-proxy는 공개 포트에서 TLS를 종료하고,
PROXY 프로토콜 헤더를 전송한 다음 Prosody로 전달합니다. 이렇게 하면 로깅 및 속도 제한을 위해 실제 클라이언트 IP가 보존됩니다.

###### 커스터마이징

`docker-compose.override.yaml`에 로컬 오버라이드를 넣으세요 (`docker-compose.override.yaml.example` 참조). 일반적인 커스터마이징:
  * Prosody 모듈 변경: `.env`에서 `PROSODY_ENABLE_MODULES` 설정
  * 로그 레벨 조정: `PROSODY_LOGLEVEL`, `XMPP_PROXY_LOG_LEVEL`
  * 데이터 경로 변경: 오버라이드 파일에서 볼륨 마운트 수정
  * 사용자 정의 Prosody 모듈 추가: `./prosody-modules/` 디렉토리에 넣기

####  라이선스
GNU/AGPLv3 - 자세한 내용은 LICENSE.md 확인

afl-fuzz 시드를 제공한 [rxml](https://github.com/horazont/rxml)에 감사드립니다

#### 할 일
  1. .onion 도메인과의 연결을 위한 완벽한 Tor 통합
  2. WebTransport XEP 작성
  3. systemd 활성화 지원 문서화
  4. 라이브러리로 사용하기 지원 문서화

[STARTTLS]: https://datatracker.ietf.org/doc/html/rfc6120#section-5
[Direct TLS]: https://xmpp.org/extensions/xep-0368.html
[QUIC]: https://xmpp.org/extensions/xep-0467.html
[WebSocket C2S]: https://datatracker.ietf.org/doc/html/rfc7395
[WebSocket S2S]: https://xmpp.org/extensions/xep-0468.html
[WebTransport]: https://www.w3.org/TR/webtransport/
[POSH]: https://datatracker.ietf.org/doc/html/rfc7711
[host-meta]: https://xmpp.org/extensions/xep-0156.html
[host-meta2]: https://xmpp.org/extensions/inbox/host-meta-2.html
[PROXY protocol]: https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt

## Distroless 배포 (권장)

xmpp-proxy-stack은 이제 보안 향상을 위해 강화된 distroless 베이스 이미지를 사용합니다.

### 기능

- **최소 공격 표면**: 셸이나 패키지 매니저가 없는 `gcr.io/distroless/base-debian13` 기반
- **프로세스 감독**: Horust가 nginx, xmpp-proxy, fail2ban-rs, acme.sh 관리
- **자동 인증서**: acme.sh가 SSL/TLS 인증서 획득 및 갱신 처리
- **동적 프록시**: 런타임에 리버스 프록시 구성을 추가/제거하기 위한 nginx-proxy-ctl CLI

### 빠른 시작

1. 환경 변수 구성:
```bash
cp .env.example .env
nano .env  # XMPP_DOMAIN 및 ACME_EMAIL 설정
```

2. 업스트림 `prosodyim/prosody` 이미지가 예상하는 UID/GID(`100:102`)로 Prosody 데이터/로그
   디렉토리를 생성합니다. 그렇지 않으면 Docker가 첫 마운트 시 `root`로 자동 생성하여 prosody
   컨테이너가 `usermod: UID '0' already exists`로 크래시 루프에 빠집니다 (문제 해결 참조):
```bash
mkdir -p /srv/xmpp/prosody /srv/xmpp/logs/prosody
chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
```

3. 시작 (`ghcr.io/nikescar/xmpp-proxy-stack:${XMPP_PROXY_STACK_TAG:-latest}` 가져오기):
```bash
docker compose up -d
```
대신 소스에서 빌드하려면 `docker-compose.dev.yaml` 사용:
```bash
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
docker compose -f docker-compose.dev.yaml up -d
```
빌드 인자 `XMPP_PROXY_VERSION`, `FAIL2BAN_RS_VERSION`, `HORUST_VERSION`
(모두 `.env`에 설정됨)은 소스에서 빌드할 때 각 바이너리의 어느 업스트림 릴리스를 이미지에 다운로드할지 제어합니다.

4. 서비스 확인:
```bash
docker logs xmpp-proxy-stack
docker exec xmpp-proxy-stack /bin/busybox ps aux
```

### 동적 Nginx 프록시 구성

HTTP/HTTPS 리버스 프록시 위치를 동적으로 추가:

```bash
# 프록시 추가
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://backend:8000/

# WebSocket 지원과 함께 추가
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# 모든 프록시 나열
docker exec xmpp-proxy-stack nginx-proxy-ctl list

# 프록시 제거
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/

# nginx 구성 검증
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

### 인증서 관리

인증서는 Let's Encrypt를 통해 자동으로 획득됩니다:

- **초기 획득**: 첫 실행 시 nginx를 통한 HTTP-01 챌린지
- **갱신**: 매일 확인, 30일 이내 만료 시 자동 갱신
- **폴백**: ACME 실패 시 자체 서명 인증서 (DNS 및 포트 80 확인)

인증서 세부 정보 보기:
```bash
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
```

수동 갱신 (필요한 경우):
```bash
docker exec xmpp-proxy-stack /bin/busybox sh /app/acme.sh --renew -d your-domain.com --force
```

### 아키텍처

```
┌─────────────────────────────────────────────┐
│  Horust 프로세스 감독자                     │
│  ├─ nginx (HTTP/HTTPS 프록시)               │
│  ├─ xmpp-proxy (XMPP 리버스 프록시)         │
│  ├─ fail2ban-rs (침입 방지)                 │
│  └─ acme-renewer (매일 인증서 갱신)         │
└─────────────────────────────────────────────┘
```

### 문제 해결

**prosody 컨테이너가 `usermod: UID '0' already exists`로 크래시 루프:**
업스트림 `prosodyim/prosody` 이미지의 진입점은 내부 `prosody` 사용자(UID `100`)를 바인드 마운트된
`/var/lib/prosody` 디렉토리 소유자에 맞게 번호를 변경하려고 시도하며, 소유자가 `root`(UID 0)인 경우 실패합니다 -
업스트림 이미지의 알려진 버그입니다. 이는 `/srv/xmpp/prosody` 또는 `/srv/xmpp/logs/prosody`가
`docker compose up` 전에 존재하지 않았을 때 발생하며, Docker가 누락된 바인드 마운트 디렉토리를 `root`로 자동 생성하기 때문입니다. 수정:
```bash
docker compose down
mkdir -p /srv/xmpp/prosody /srv/xmpp/logs/prosody
chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
docker compose up -d
```

**ACME 인증서 획득 실패:**
1. DNS 확인: `dig +short your-domain.com`이 서버 IP를 반환해야 함
2. 포트 80 확인: `ss -tlnp | grep :80`
3. 로그 확인: `docker logs xmpp-proxy-stack 2>&1 | grep -i acme`
4. 테스트용 자체 서명 사용: 컨테이너가 자동으로 폴백

**볼륨 권한 오류:**
컨테이너는 현재 root로 실행되므로 드물지만, 시작 시 "쓰기 권한 없음" 오류가 표시되면
마운트된 디렉토리가 호스트에서 소유한 사용자가 쓸 수 있는지 확인하세요:
```bash
mkdir -p /srv/xmpp/{certs,logs,fail2ban,acme}
chmod 777 /srv/xmpp/{certs,logs,fail2ban,acme}
```

**서비스 로그 보기:**
```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
```

## Debian-slim에서 Distroless로 마이그레이션

이전 Debian-slim 기반 스택에서 업그레이드하는 경우:

### 1. 현재 설정 백업

```bash
# 인증서 백업
cp -r /srv/xmpp/certs /srv/xmpp/certs.backup

# 구성 백업
docker exec xmpp-proxy-stack tar czf /tmp/configs.tar.gz /etc/xmpp-proxy /etc/fail2ban-rs
docker cp xmpp-proxy-stack:/tmp/configs.tar.gz ./configs-backup.tar.gz
```

### 2. Distroless로 재빌드

```bash
# 최신 코드 가져오기
git pull origin main

# 재빌드 (docker-compose.dev.yaml은 소스에서 빌드, docker-compose.yaml은
# 대신 게시된 ghcr.io 이미지를 가져옴 - 위 빠른 시작 참조)
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack

# 이전 컨테이너 중지
docker compose stop xmpp-proxy-stack

# 새 distroless 컨테이너 시작
docker compose -f docker-compose.dev.yaml up -d xmpp-proxy-stack
```

### 3. 마이그레이션 확인

```bash
# 컨테이너가 실행 중인지 확인
docker ps | grep xmpp-proxy-stack

# 서비스 확인
docker exec xmpp-proxy-stack /bin/busybox ps aux

# 인증서 확인
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/

# nginx-proxy-ctl 테스트
docker exec xmpp-proxy-stack nginx-proxy-ctl list
```

### 롤백 (필요한 경우)

레거시 Debian-slim 빌드는 `Dockerfile.distroless`와 함께 `xmpp-proxy-stack/Dockerfile`로 여전히 존재하므로,
롤백은 `docker-compose.dev.yaml`에 한 줄만 편집하면 되며 파일 이름 변경이 필요 없습니다:

```bash
# distroless 컨테이너 중지
docker compose stop xmpp-proxy-stack

# docker-compose.dev.yaml에서 변경:
#   dockerfile: Dockerfile.distroless
# 다음으로:
#   dockerfile: Dockerfile

# 재빌드
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
docker compose -f docker-compose.dev.yaml up -d xmpp-proxy-stack
```
