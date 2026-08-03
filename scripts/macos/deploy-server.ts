#!/usr/bin/env bun

import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dir, "../..");
const serverRoot = join(projectRoot, "server", "typing-dongnanya-api");
const sshAlias = "tencent-cloud";
const publicIPAddress = "114.132.185.123";
const remoteRelease = `/opt/typing-dongnanya-api/releases/${new Date().toISOString().replace(/[-:.TZ]/g, "")}`;
const accessToken = randomBytes(24).toString("hex");
const localSecretRoot = join(homedir(), ".config", "typing-dongnanya");
const localDeepSeekKeyPath = join(localSecretRoot, "deepseek-api-key");
const deepSeekAPIKey = readSecret(localDeepSeekKeyPath, "DeepSeek API Key");
const localBinaryPath = join(serverRoot, "build", "typing-dongnanya-api-linux-amd64");
const deploymentFiles = [
  "typing-dongnanya-api.service",
  "nginx-typing-dongnanya-api-bootstrap.conf",
  "nginx-typing-dongnanya-api.conf",
  "certbot-renew.service",
  "certbot-renew.timer",
];

for (const fileName of deploymentFiles) {
  const filePath = join(serverRoot, fileName);
  if (!readFileSync(filePath, "utf8").trim()) {
    throw new Error(`部署文件为空：${fileName}`);
  }
}

run("go", ["env", "GOVERSION"]);
run("go", ["test", "./..."], false, undefined, serverRoot);
run("go", ["build", "-trimpath", "-ldflags", "-s -w", "-o", localBinaryPath], false, {
  GOOS: "linux",
  GOARCH: "amd64",
  CGO_ENABLED: "0",
}, serverRoot);
const localBinary = readFileSync(localBinaryPath);
const localBinarySha256 = sha256(localBinary);

// 绿盾会让原生 scp/rsync 读取到不同字节，所有部署文件统一由 Bun 读取后经 SSH 标准输入传输并做哈希核对。
uploadRemoteFile("/tmp/typing-dongnanya-api", localBinary);
for (const fileName of deploymentFiles) {
  uploadRemoteFile(`/tmp/${fileName}`, readFileSync(join(serverRoot, fileName)));
}
uploadRemoteFile("/tmp/typing-dongnanya-api.env", Buffer.from(serverEnvironment()));

runRemoteScript(`
set -euo pipefail
backup_root=/opt/typing-dongnanya-api/backups/$(date +%Y%m%d%H%M%S)
sudo mkdir -p "$backup_root" ${remoteRelease} /etc/typing-dongnanya-api /var/lib/typing-dongnanya-api /var/lib/letsencrypt/.well-known/acme-challenge
if ! id -u typing-dongnanya-api >/dev/null 2>&1; then
  sudo useradd --system --home-dir /var/lib/typing-dongnanya-api --shell /sbin/nologin typing-dongnanya-api
fi
for source_path in \
  /etc/nginx/conf.d/typing-dongnanya-api.conf \
  /etc/systemd/system/typing-dongnanya-api.service \
  /etc/systemd/system/certbot-renew.service \
  /etc/systemd/system/certbot-renew.timer \
  /etc/typing-dongnanya-api/typing-dongnanya-api.env; do
  if sudo test -f "$source_path"; then sudo cp -a "$source_path" "$backup_root/$(basename "$source_path")"; fi
done
if test -L /opt/typing-dongnanya-api/current; then readlink -f /opt/typing-dongnanya-api/current | sudo tee "$backup_root/previous-release" >/dev/null; fi

sudo mv /tmp/typing-dongnanya-api ${remoteRelease}/typing-dongnanya-api
remote_binary_sha256=$(sha256sum ${remoteRelease}/typing-dongnanya-api | awk '{print $1}')
test "$remote_binary_sha256" = "${localBinarySha256}"
sudo chown -R typing-dongnanya-api:typing-dongnanya-api ${remoteRelease}
sudo chmod 755 ${remoteRelease}/typing-dongnanya-api
sudo install -m 644 /tmp/typing-dongnanya-api.service /etc/systemd/system/typing-dongnanya-api.service
sudo install -m 644 /tmp/certbot-renew.service /etc/systemd/system/certbot-renew.service
sudo install -m 644 /tmp/certbot-renew.timer /etc/systemd/system/certbot-renew.timer
sudo install -o root -g root -m 600 /tmp/typing-dongnanya-api.env /etc/typing-dongnanya-api/typing-dongnanya-api.env
sudo ln -sfn ${remoteRelease} /opt/typing-dongnanya-api/current

# ACME webroot 先在 80 端口完成验证，签发成功后再切换最终 HTTPS 配置。
sudo install -m 644 /tmp/nginx-typing-dongnanya-api-bootstrap.conf /etc/nginx/conf.d/typing-dongnanya-api.conf
sudo nginx -t
sudo systemctl reload nginx.service
test -x /opt/typing-dongnanya-api/certbot/bin/certbot
sudo /opt/typing-dongnanya-api/certbot/bin/certbot certonly \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --webroot \
  --webroot-path /var/lib/letsencrypt \
  --ip-address ${publicIPAddress} \
  --cert-name typing-dongnanya-ip \
  --preferred-profile shortlived \
  --keep-until-expiring
sudo test -s /etc/letsencrypt/live/typing-dongnanya-ip/fullchain.pem
sudo test -s /etc/letsencrypt/live/typing-dongnanya-ip/privkey.pem
sudo install -m 644 /tmp/nginx-typing-dongnanya-api.conf /etc/nginx/conf.d/typing-dongnanya-api.conf
if sudo systemctl is-active --quiet firewalld.service; then
  sudo firewall-cmd --permanent --add-service=https >/dev/null
  sudo firewall-cmd --reload >/dev/null
fi

sudo systemctl daemon-reload
sudo systemctl enable typing-dongnanya-api.service
sudo systemctl restart typing-dongnanya-api.service
for attempt in $(seq 1 20); do
  if curl --fail --silent --show-error --max-time 3 http://127.0.0.1:18127/healthz >/dev/null; then break; fi
  sleep 0.5
done
curl --fail --silent --show-error --max-time 3 http://127.0.0.1:18127/healthz >/dev/null
sudo nginx -t
sudo systemctl reload nginx.service
sudo systemctl enable --now certbot-renew.timer
curl --fail --silent --show-error --max-time 10 https://${publicIPAddress}/typing-dongnanya-api/healthz >/dev/null

response_file=/tmp/typing-dongnanya-api-deploy-response.json
status=$(curl --silent --show-error --max-time 45 -o "$response_file" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash","stream":false,"thinking":{"type":"disabled"},"messages":[{"role":"system","content":"Translate Chinese to English. Output translation only."},{"role":"user","content":"你好，很高兴认识你。"}]}' \
  https://${publicIPAddress}/typing-dongnanya-api/v1/chat/completions/${accessToken})
test "$status" = 200
python3 - <<'PY'
import json
with open('/tmp/typing-dongnanya-api-deploy-response.json') as response_file:
    response = json.load(response_file)
translated_text = response['choices'][0]['message']['content'].strip()
if not translated_text:
    raise SystemExit('empty translation response')
print('server translation smoke=' + translated_text)
PY
sudo rm -f "$response_file" /tmp/typing-dongnanya-api.env /tmp/typing-dongnanya-api.service /tmp/nginx-typing-dongnanya-api-bootstrap.conf /tmp/nginx-typing-dongnanya-api.conf /tmp/certbot-renew.service /tmp/certbot-renew.timer
sudo openssl x509 -in /etc/letsencrypt/live/typing-dongnanya-ip/fullchain.pem -noout -issuer -subject -dates -ext subjectAltName
printf 'release=%s\\nbackup=%s\\nsha256=%s\\n' '${remoteRelease}' "$backup_root" "$remote_binary_sha256"
`);

mkdirSync(localSecretRoot, { recursive: true });
writeFileSync(join(localSecretRoot, "access-token"), `${accessToken}\n`, { mode: 0o600 });
console.log(`服务已通过 HTTPS 部署到 ${sshAlias}，release=${remoteRelease}`);
console.log("新的 48 位 capability 已写入本机配置，下一次构建会自动注入输入法包。");

// Go 服务直接访问 DeepSeek 官方接口，AI Key 只进入服务器 600 权限环境文件。
function serverEnvironment() {
  return `TYPING_DONGNANYA_LISTEN_HOST=127.0.0.1
TYPING_DONGNANYA_LISTEN_PORT=18127
TYPING_DONGNANYA_DEEPSEEK_API_URL=https://api.deepseek.com
TYPING_DONGNANYA_DEEPSEEK_API_KEY=${deepSeekAPIKey}
TYPING_DONGNANYA_ACCESS_TOKEN=${accessToken}
`;
}

function readSecret(secretPath: string, secretName: string) {
  const value = readFileSync(secretPath, "utf8").trim();
  if (!value) throw new Error(`${secretName} 本机配置为空：${secretPath}`);
  return value;
}

function sha256(value: string | Buffer) {
  return createHash("sha256").update(value).digest("hex");
}

function uploadRemoteFile(remotePath: string, content: Buffer) {
  const result = spawnSync("ssh", [sshAlias, `umask 077; cat > ${shellQuote(remotePath)}`], {
    input: content,
    stdio: ["pipe", "inherit", "inherit"],
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runRemoteScript(script: string) {
  const result = spawnSync("ssh", [sshAlias, "bash", "-s"], {
    input: script,
    encoding: "utf8",
    stdio: ["pipe", "inherit", "inherit"],
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function run(
  command: string,
  args: string[],
  inheritOutput = true,
  environment?: Record<string, string>,
  cwd = projectRoot,
) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, {
    cwd,
    stdio: inheritOutput ? "inherit" : "pipe",
    env: environment ? { ...process.env, ...environment } : process.env,
  });
  if (result.status !== 0) {
    if (!inheritOutput) {
      process.stdout.write(result.stdout ?? "");
      process.stderr.write(result.stderr ?? "");
    }
    process.exit(result.status ?? 1);
  }
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
