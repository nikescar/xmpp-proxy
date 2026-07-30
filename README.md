
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

#### Prosody 연동

###### 리버스 프록시 및 아웃고잉 프록시

이 모드에서 Prosody는 TLS를 전혀 수행할 필요가 없습니다. xmpp-proxy는 적절한 TLS 인증서가 필요합니다. Prosody의 TLS 키를 `/etc/xmpp-proxy/le.key`로, TLS 인증서를 `/etc/xmpp-proxy/fullchain.cer`로 이동하세요.

`/etc/prosody/prosody.cfg.lua`를 편집:
```lua
-- modules_enabled에 추가 (prosody-modules 업데이트까지 포크 사용):
"net_proxy";  -- https://raw.githubusercontent.com/moparisthebest/xmpp-proxy/refs/heads/master/contrib/prosody-modules/mod_net_proxy.lua

-- localhost에서만 수신 대기
interfaces = { "127.0.0.1" }

-- 암호화 비활성화 (xmpp-proxy가 처리)
s2s_require_encryption = false
s2s_secure_auth = false
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

-- xmpp-proxy 아웃고잉
proxy_out = { "127.0.0.1", 15270 }
proxy_secure = true

-- PROXY 프로토콜
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- xmpp-proxy가 표준 포트에서 수신 대기
c2s_ports = {}
legacy_ssl_ports = {}
s2s_ports = {15268}  -- 아웃고잉 S2S를 위해 최소 하나 필요
```

###### 리버스 프록시만

이 모드에서 Prosody와 xmpp-proxy 모두 적절한 TLS 인증서가 필요합니다. `/etc/prosody/prosody.cfg.lua`를 편집:
```lua
-- modules_enabled에 추가:
"net_proxy";

-- 프록시 연결을 안전하다고 표시
proxy_secure_in = true

-- PROXY 프로토콜
proxy_port_mappings = {
    [15222] = "c2s",
    [15269] = "s2s"
}

-- xmpp-proxy가 표준 포트에서 수신 대기
c2s_ports = {}
legacy_ssl_ports = {}
s2s_ports = {15268}
```

#### Docker 배포

완전한 Docker Compose 스택 제공:
  * **Prosody XMPP 서버** - MAM, carbons, 웹 관리자 포함
  * **xmpp-proxy** - STARTTLS/TLS/QUIC/WebSocket 지원
  * **nginx** - ACME HTTP-01 챌린지 및 동적 리버스 프록시
  * **fail2ban-rs** - 속도 제한 및 남용 방지
  * **Horust** - 강화된 distroless 컨테이너에서 프로세스 감독
  * acme.sh를 사용한 자동 TLS 인증서 관리
  * 클라이언트 IP 보존을 위한 PROXY 프로토콜 지원

###### 빠른 시작

1. 환경 변수 구성:
   ```bash
   cp .env.example .env
   nano .env  # XMPP_DOMAIN 및 ACME_EMAIL 설정
   ```

2. Prosody 디렉토리를 올바른 소유권으로 생성 (UID 100:102):
   ```bash
   mkdir -p /srv/xmpp/prosody /srv/xmpp/logs/prosody
   chown -R 100:102 /srv/xmpp/prosody /srv/xmpp/logs/prosody
   ```

3. 서비스 시작:
   ```bash
   docker compose up -d
   ```

스택은 표준 XMPP 포트를 노출합니다 (5222, 5223, 5269, 443/udp, 5280, 80).
데이터는 `/srv/xmpp/`에 유지됩니다 (prosody/, certs/, logs/, fail2ban/, acme/).

개발용 (게시된 이미지 대신 소스에서 빌드):
```bash
docker compose -f docker-compose.dev.yaml build xmpp-proxy-stack
docker compose -f docker-compose.dev.yaml up -d
```

###### 아키텍처

두 개의 컨테이너:
  * **prosody** - localhost:15222 (C2S) 및 localhost:15269 (S2S)에서 PROXY 프로토콜 지원과 함께 Prosody XMPP 서버 실행
  * **xmpp-proxy-stack** - xmpp-proxy, nginx, fail2ban-rs, acme.sh를 distroless 이미지에 번들로 포함하고 Horust가 감독

xmpp-proxy는 공개 포트에서 TLS를 종료하고 PROXY 프로토콜 헤더를 전송한 다음 Prosody로 전달합니다. 이렇게 하면 로깅 및 속도 제한을 위해 실제 클라이언트 IP가 보존됩니다.

###### nginx-proxy-ctl 사용법

런타임에 동적 리버스 프록시 구성 관리:

```bash
# 리버스 프록시 추가
docker exec xmpp-proxy-stack nginx-proxy-ctl add /api/ http://localhost:8000/

# 웹소켓 프록시 추가
docker exec xmpp-proxy-stack nginx-proxy-ctl add /ws/ http://localhost:8080/ --websocket

# 구성된 프록시 나열
docker exec xmpp-proxy-stack nginx-proxy-ctl list

# 프록시 제거
docker exec xmpp-proxy-stack nginx-proxy-ctl remove /api/

# nginx 구성 검증
docker exec xmpp-proxy-stack nginx-proxy-ctl validate
```

###### 인증서 관리

인증서는 Let's Encrypt를 통해 자동으로 획득됩니다:
- **초기 획득**: 포트 80에서 nginx를 통한 HTTP-01 챌린지
- **갱신**: 매일 확인, 30일 이내 만료 시 자동 갱신
- **폴백**: ACME 실패 시 자체 서명 인증서

인증서 세부 정보 보기:
```bash
docker exec xmpp-proxy-stack /bin/busybox ls -la /certs/
```

###### 커스터마이징

`docker-compose.override.yaml`에 로컬 오버라이드를 넣으세요. 일반적인 커스터마이징:
  * Prosody 모듈 변경: `.env`에서 `PROSODY_ENABLE_MODULES` 설정
  * 로그 레벨 조정: `PROSODY_LOGLEVEL`, `XMPP_PROXY_LOG_LEVEL`
  * 데이터 경로 변경: 오버라이드 파일에서 볼륨 마운트 수정
  * 사용자 정의 Prosody 모듈 추가: `./prosody-modules/` 디렉토리에 넣기

###### 문제 해결

**prosody가 `usermod: UID '0' already exists`로 크래시 루프:**
Docker가 `/srv/xmpp/prosody`를 root로 자동 생성했습니다. 수정:
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

**서비스 로그 보기:**
```bash
docker exec xmpp-proxy-stack /bin/busybox cat /logs/nginx-stdout.log
docker exec xmpp-proxy-stack /bin/busybox cat /logs/xmpp-proxy-stdout.log
```

#### 빌드 커스터마이징

xmpp-proxy는 여러 컴파일 타임 기능을 가지고 있습니다:

방향 (1-4):
  1. `c2s-incoming` - 수신 c2s 연결 수락
  2. `c2s-outgoing` - 아웃고잉 c2s 연결 생성
  3. `s2s-incoming` - 수신 s2s 연결 수락
  4. `s2s-outgoing` - 아웃고잉 s2s 연결 생성

전송 프로토콜 (1-4):
  1. `tls` - STARTTLS/TLS 지원
  2. `quic` - QUIC 지원
  3. `websocket` - WebSocket 지원 (적절한 방향이 활성화된 경우 TLS 수신도 활성화)
  4. `webtransport` - WebTransport 지원 (QUIC도 활성화)

신뢰할 수 있는 CA 루트 (정확히 1개 선택, `c2s-incoming`만 활성화된 경우 불필요):
  1. `tls-ca-roots-native` - 운영 체제에서 CA 루트 읽기
  2. `tls-ca-roots-bundled` - webpki-roots에서 CA 루트 번들

선택적 기능:
  1. `logging` - 구성 가능한 로깅

예제:
```bash
# 리버스 프록시 STARTTLS/TLS만
cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls

# 리버스 프록시 STARTTLS/TLS/QUIC
cargo build --release --no-default-features --features c2s-incoming,s2s-incoming,tls,quic
```

#### 개발

1. `check-all-features.sh`는 지원되는 모든 기능 순열로 컴파일 확인
2. `integration/test.sh`는 [Rootless podman](https://wiki.archlinux.org/title/Podman#Rootless_Podman)을 사용하여 실제 네트워크에서 통합 테스트 실행. 커밋 푸시 전에 모든 테스트가 통과해야 합니다.
3. [github](https://github.com/moparisthebest/xmpp-proxy) 또는 [code.moparisthebest.com](https://code.moparisthebest.com/moparisthebest/xmpp-proxy)에 PR로 변경 사항 제출하거나 email, XMPP, fediverse, carrier pigeon으로 패치 전송.

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
