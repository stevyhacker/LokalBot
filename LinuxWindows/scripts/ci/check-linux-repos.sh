#!/usr/bin/env bash
set -euo pipefail
STAGE=$(cd "$1" && pwd)
NFPM=$(command -v "${NFPM:-nfpm}")
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
base=$(basename "$STAGE" | sed -E 's/^LokalBot-([0-9]+\.[0-9]+\.[0-9]+)-linux-x86_64$/\1/')
if ! [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "$STAGE is not a LokalBot-<version>-linux-x86_64 folder" >&2
  exit 2
fi
IFS=. read -r major minor patch <<<"$base"
V=("$base")
for step in 1 2 3; do V+=("$major.$minor.$((patch + step))"); done

ID="lokalbot-repos-$$"
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lokalbot-repos.XXXXXX")
chmod 755 "$WORK"
CLIENTS=(ubuntu:24.04 debian:13 fedora:latest)
cleanup() {
  docker ps -aq --filter "label=$ID" | xargs -r docker rm -f > /dev/null
  docker network rm "$ID" > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
name_of() { echo "$ID-${1%%:*}"; }
pub() {
  docker exec --user "$(id -u):$(id -g)" -e HOME=/work -e GNUPGHOME=/work/gnupg -w /src "$ID-pub" "$@"
}
in_client() { docker exec -e DEBIAN_FRONTEND=noninteractive "$(name_of "$1")" bash -c "$2"; }
refused() {
  local client=$1 what=$2 command=$3
  if in_client "$client" "/work/run 'signature|BADSIG|hash sum|checksum|not signed|size|verif' bash -c '$command'"; then
    fail "$client accepted $what"
  fi
  echo "ok: $client refused $what"
}
installed() {
  case $1 in
    fedora:*) in_client "$1" "rpm -q --queryformat '%{VERSION}' lokalbot" ;;
    *) in_client "$1" "dpkg-query --showformat '\${Version}' --show lokalbot | sed 's/-1\$//'" ;;
  esac
}
expect_version() {
  local got
  got=$(installed "$1")
  [ "$got" = "$2" ] || fail "$1 has lokalbot $got, expected $2"
  echo "ok: $1 has lokalbot $2"
}
publish() {
  local args=() v
  for v in "$@"; do
    args+=("/work/packages/LokalBot-$v-linux-amd64.deb" "/work/packages/LokalBot-$v-linux-x86_64.rpm")
  done
  pub scripts/linux-repos.sh /work/repo "$FPR" "${args[@]}"
}

step "Publisher and HTTPS server for pkg.lokalbot.com (Ubuntu 24.04, like the release runner)"
docker network create --label "$ID" "$ID" > /dev/null
docker run -d --name "$ID-pub" --label "$ID" --network "$ID" --network-alias pkg.lokalbot.com \
  -v "$ROOT:/src" -v "$WORK:/work" -v "$STAGE:/stage:ro" -v "$NFPM:/usr/local/bin/nfpm:ro" \
  ubuntu:24.04 sleep infinity > /dev/null
docker exec "$ID-pub" bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  apt-utils createrepo-c rpm gnupg openssl python3 zstd > /dev/null'
pub mkdir -p /work/gnupg /work/tls /work/packages /work/repo
pub chmod 700 /work/gnupg
pub gpg --batch --quiet --passphrase '' --quick-generate-key 'LokalBot repository check (throwaway)' rsa3072 sign 1d
FPR=$(pub gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
pub bash -c "gpg --batch --armor --export $FPR > /work/key.asc"
echo "throwaway key $FPR"
pub bash -c 'cd /work/tls &&
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=LokalBot check CA" -keyout ca.key -out ca.crt \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2> /dev/null &&
  openssl req -newkey rsa:2048 -nodes -subj /CN=pkg.lokalbot.com -keyout server.key -out server.csr 2> /dev/null &&
  printf "subjectAltName=DNS:pkg.lokalbot.com\nextendedKeyUsage=serverAuth\n" > ext &&
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile ext -out server.crt 2> /dev/null &&
  chmod 644 server.key'
cat > "$WORK/serve.py" <<'EOF'
import functools, http.server, ssl

class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

class Server(http.server.ThreadingHTTPServer):
    def shutdown_request(self, request):
        try:
            request.unwrap()
        except (OSError, ValueError):
            pass
        super().shutdown_request(request)

server = Server(("0.0.0.0", 443), functools.partial(Handler, directory="/work/repo"))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/work/tls/server.crt", "/work/tls/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
EOF
docker exec -d "$ID-pub" bash -c 'python3 -u /work/serve.py 2> /work/server.log'
cat > "$WORK/run" <<'EOF'
#!/bin/bash
pattern=$1
shift
"$@" > /tmp/run.log 2>&1
status=$?
errors='^(Err|Ign):.*lokalbot|^(E|W|Error|Warning):'
grep -iE "$pattern" /tmp/run.log | grep -vE "$errors"
if grep -E "$errors" /tmp/run.log; then exit 1; fi
exit $status
EOF
chmod 755 "$WORK/run"

step "Packages ${V[*]} with the throwaway key"
for v in "${V[@]}"; do
  pub env PACKAGE_VERSION="$v" STAGE=/stage LINUX_REPO_PUBLIC_KEY=/work/key.asc NFPM=nfpm \
    scripts/package-linux-distros.sh > /dev/null
  pub bash -c "mv dist/LokalBot-$v-linux-* /work/packages/"
done
deb="/work/packages/LokalBot-$base-linux-amd64.deb"
rpm="/work/packages/LokalBot-$base-linux-x86_64.rpm"
pub dpkg-deb --info "$deb" conffiles | grep -qx /etc/apt/sources.list.d/lokalbot.sources ||
  fail "the .deb does not mark lokalbot.sources as a conffile"
pub dpkg-deb --contents "$deb" | grep -q ' ./usr/share/keyrings/lokalbot-archive-keyring.gpg$' ||
  fail "the .deb has no keyring"
pub rpm -qp --queryformat '[%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$rpm" | grep -qx 'cn /etc/yum.repos.d/lokalbot.repo' ||
  fail "the .rpm does not mark lokalbot.repo as %config(noreplace)"
pub rpm -qpl "$rpm" | grep -qx /etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot || fail "the .rpm has no key"
if pub tar --zstd -tf "/work/packages/LokalBot-$base-linux-x86_64.pkg.tar.zst" | grep -q '^etc/'; then
  fail "the Arch package adds files under /etc"
fi
echo "ok: the .deb and .rpm add the repository as config files; the Arch package does not"

step "Publish $base"
publish "$base"

for client in "${CLIENTS[@]}"; do
  step "$client: install $base from the downloaded file"
  docker run -d --name "$(name_of "$client")" --label "$ID" --network "$ID" -v "$WORK:/work:ro" \
    "$client" sleep infinity > /dev/null
  case $client in
    fedora:*)
      in_client "$client" 'cp /work/tls/ca.crt /etc/pki/ca-trust/source/anchors/lokalbot-check.crt && update-ca-trust &&
        dnf install -y -q --setopt=install_weak_deps=False /work/packages/LokalBot-'"$base"'-linux-x86_64.rpm > /dev/null &&
        cat /etc/yum.repos.d/lokalbot.repo &&
        /work/run "lokalbot|key|metadata" dnf makecache -y --repo lokalbot --setopt=lokalbot.skip_if_unavailable=False'
      ;;
    *)
      in_client "$client" 'apt-get update -qq && apt-get upgrade -y -qq > /dev/null &&
        apt-get install -y -qq --no-install-recommends ca-certificates > /dev/null &&
        cp /work/tls/ca.crt /usr/local/share/ca-certificates/lokalbot-check.crt && update-ca-certificates > /dev/null &&
        apt-get install -y -qq --no-install-recommends /work/packages/LokalBot-'"$base"'-linux-amd64.deb > /dev/null &&
        cat /etc/apt/sources.list.d/lokalbot.sources && /work/run lokalbot apt update &&
        apt-cache policy lokalbot && apt-cache policy lokalbot | grep -q "500 https://pkg.lokalbot.com/apt stable/main"'
      ;;
  esac
  expect_version "$client" "$base"
done

step "Edit the repository files, publish ${V[1]}, upgrade"
publish "${V[1]}"
for client in "${CLIENTS[@]}"; do
  case $client in
    fedora:*)
      in_client "$client" 'echo "# edited by the check" >> /etc/yum.repos.d/lokalbot.repo &&
        /work/run "lokalbot|^upgrad|signature|key" dnf upgrade -y --refresh &&
        test "$(tail -1 /etc/yum.repos.d/lokalbot.repo)" = "# edited by the check" && ! test -e /etc/yum.repos.d/lokalbot.repo.rpmnew &&
        rpm -q --queryformat "signature: %{RSAHEADER:pgpsig}\n" lokalbot'
      ;;
    *)
      in_client "$client" 'echo "# edited by the check" >> /etc/apt/sources.list.d/lokalbot.sources &&
        /work/run "lokalbot|upgrad" apt update && /work/run "lokalbot|upgraded" apt upgrade -y &&
        test "$(tail -1 /etc/apt/sources.list.d/lokalbot.sources)" = "# edited by the check" &&
        ! test -e /etc/apt/sources.list.d/lokalbot.sources.dpkg-dist'
      ;;
  esac
  expect_version "$client" "${V[1]}"
  echo "ok: $client kept the edited repository file"
done

step "Tampered indexes"
dist=/work/repo/apt/dists/stable
pub cp "$dist/InRelease" "$dist/Release" /work/
pub sed -i '0,/^ [0-9a-f]/s/^ \([0-9a-f]\)/ f\1/' "$dist/InRelease"
for client in ubuntu:24.04 debian:13; do
  refused "$client" "a tampered InRelease" 'apt-get update'
done
pub rm "$dist/InRelease"
pub sed -i '0,/^ [0-9a-f]/s/^ \([0-9a-f]\)/ f\1/' "$dist/Release"
for client in ubuntu:24.04 debian:13; do
  refused "$client" "a tampered Release" 'apt-get update'
done
pub cp /work/InRelease "$dist/InRelease"
pub cp /work/Release "$dist/Release"
repomd=/work/repo/rpm/repodata/repomd.xml
pub cp "$repomd" /work/repomd.xml
pub sed -i 's|<revision>|<revision>1|' "$repomd"
refused fedora:latest "a tampered repomd.xml" \
  'dnf makecache -y --refresh --repo lokalbot --setopt=lokalbot.skip_if_unavailable=False'
pub cp /work/repomd.xml "$repomd"
for client in "${CLIENTS[@]}"; do
  case $client in
    fedora:*) in_client "$client" '/work/run lokalbot dnf makecache -y --refresh --repo lokalbot --setopt=lokalbot.skip_if_unavailable=False' ;;
    *) in_client "$client" '/work/run lokalbot apt-get update' ;;
  esac
done
echo "ok: restored indexes verify again"

step "Publish ${V[2]} and ${V[3]}: the oldest version leaves"
publish "${V[2]}" "${V[3]}"
pool=$(pub find /work/repo/apt/pool -name '*.deb' -printf '%f\n' | sort -V | tr '\n' ' ')
rpms=$(pub find /work/repo/rpm -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort -V | tr '\n' ' ')
echo "apt pool: $pool"
echo "rpm: $rpms"
[ "$pool" = "lokalbot_${V[1]}-1_amd64.deb lokalbot_${V[2]}-1_amd64.deb lokalbot_${V[3]}-1_amd64.deb " ] ||
  fail "the apt repository should keep ${V[1]}, ${V[2]} and ${V[3]}"
[ "$rpms" = "lokalbot-${V[1]}-1.x86_64.rpm lokalbot-${V[2]}-1.x86_64.rpm lokalbot-${V[3]}-1.x86_64.rpm " ] ||
  fail "the rpm repository should keep ${V[1]}, ${V[2]} and ${V[3]}"
pub grep -c '^Package: lokalbot$' /work/repo/apt/dists/stable/main/binary-amd64/Packages | grep -qx 3 ||
  fail "Packages should list three versions"

step "Swapped and unsigned packages"
newest_deb="/work/repo/apt/pool/main/l/lokalbot/lokalbot_${V[3]}-1_amd64.deb"
newest_rpm="/work/repo/rpm/lokalbot-${V[3]}-1.x86_64.rpm"
pub cp "$newest_deb" "$newest_rpm" /work/
pub cp "/work/repo/apt/pool/main/l/lokalbot/lokalbot_${V[2]}-1_amd64.deb" "$newest_deb"
pub cp "/work/repo/rpm/lokalbot-${V[2]}-1.x86_64.rpm" "$newest_rpm"
for client in ubuntu:24.04 debian:13; do
  refused "$client" "a swapped .deb" 'apt-get update -qq && apt-get upgrade -y'
  expect_version "$client" "${V[1]}"
done
refused fedora:latest "a swapped .rpm" 'dnf upgrade -y --refresh lokalbot'
expect_version fedora:latest "${V[1]}"
pub cp "/work/packages/LokalBot-${V[3]}-linux-x86_64.rpm" "$newest_rpm"
pub bash -c "rm -rf /work/repo/rpm/repodata && createrepo_c --quiet --no-database /work/repo/rpm &&
  gpg --batch --yes --local-user $FPR --armor --detach-sign --output $repomd.asc $repomd"
refused fedora:latest "an unsigned .rpm" 'dnf upgrade -y --refresh lokalbot'
expect_version fedora:latest "${V[1]}"
pub cp "/work/lokalbot_${V[3]}-1_amd64.deb" "$newest_deb"
pub cp "/work/lokalbot-${V[3]}-1.x86_64.rpm" "$newest_rpm"
pub scripts/linux-repos.sh /work/repo "$FPR"

step "Upgrade to ${V[3]}"
for client in "${CLIENTS[@]}"; do
  case $client in
    fedora:*) in_client "$client" '/work/run "lokalbot|^upgrad" dnf upgrade -y --refresh' ;;
    *) in_client "$client" '/work/run lokalbot apt update && /work/run "lokalbot|upgraded" apt upgrade -y' ;;
  esac
  expect_version "$client" "${V[3]}"
done

step "Files the clients fetched"
pub grep -oE '"GET [^ ]+' /work/server.log | sed 's/"GET //' | sed -E 's/[0-9a-f]{64}/<sha256>/g' | sort | uniq -c
pub grep -q 'by-hash/SHA256/' /work/server.log || fail "apt did not fetch indexes by hash"
echo
echo "All repository checks passed."
