# auto_cert.sh — 证书签发 / 续期 / 部署

acme.sh 只当执行器：负责和 CA 通信、拿证书、管它自己的续期状态。
本脚本负责：配置、域名解析与校验、产物导出、日志、退出码。

## 安装

```bash
# 1. 配置
cp .env.example .env && chmod 600 .env
vi .env            # 至少填 CERT_DOMAINS 和对应 DNS 的凭据

# 2. 签发
./auto_cert.sh issue
```

acme.sh 不存在时会自动 `git clone` 到脚本同目录。

## 域名配置

**写多少签多少，脚本不做任何自动补全。** 通配符直接写在列表里，没有单独的开关。

| 配置 | 实际签发 |
|---|---|
| `CERT_DOMAINS="a.com"` | `a.com` |
| `CERT_DOMAINS="a.com,*.a.com"` | `a.com` + `*.a.com` |
| `CERT_DOMAINS="a.com,b.com,*.a.com"` | 三个都要 |
| `CERT_DOMAINS="*.a.com"` | 报错（见下文主域名规则） |

这样配置和结果一一对应：看到 `.env` 就知道会签出什么，不需要记开关状态。

### 通配符不覆盖裸域名

`*.a.com` **不包含** `a.com` 本身，这是 RFC 6125 的规则。需要裸域名就一起写上：

```
CERT_DOMAINS="a.com,*.a.com"
```

写了 `*.a.com` 却没写 `a.com` 时，脚本会打印告警但**不拦**——确实有人只想签通配符（比如裸域名走另一张证书）。

### 主域名必须是裸域名

`CERT_DOMAINS` 的**第一个**是主域名（CN），它会用作：

- acme.sh 的证书目录名 `certs/<主域名>_ecc/`
- 本脚本的产物目录 `out/<主域名>/`

目录名里带 `*` 会让路径操作一团糟，所以第一个不能是通配符。

```bash
CERT_DOMAINS="*.a.com,a.com"   # ✗ 报错，会提示把 a.com 挪到前面
CERT_DOMAINS="a.com,*.a.com"   # ✓
```

### 分隔符

逗号、分号、空格、换行都可以，会自动去重并清理空白、保持顺序。

```
CERT_DOMAINS="a.com; b.com,*.c.com"
```

## 子命令

| 命令 | 行为 | 退出码 |
|---|---|---|
| `issue` | 首次签发；已签发且证书有效则跳过 | 0 / 1 / 2 |
| `renew` | 交给 acme.sh 按 ARI 判断 | 0 / 1 / 2 |
| `renew --force` | 强制立即续期 | 0 / 1 |
| `export` | 只把已有证书重新导出到 `out/`，不联网、不消耗配额 | 0 / 1 |
| `revoke` | 吊销 | 0 / 1 |
| `status` | 查看到期时间（不联网） | 0 / 1 |

`2` 表示「无需操作」，不是失败。cron 里可以据此区分。

参数解析很简单：只认第一个参数作为子命令，`--force` 只对 `renew` 生效；其余多余参数一律忽略。所以 `--staging`、`status --force` 这类写法相当于只执行 `status`，不会报错也不会生效。

`export` 的用途：证书签好了但导出失败（例如 `out/` 权限突变），或者手工删了 `out/` 想重新生成——都不用重新签发，省配额。

另外 `issue` / `renew` 在「证书有效、无需操作」而 `out/` 产物不全时，也会自动补一次导出，所以 cron 只跑这两个命令也能自愈产物，不需要额外挂 `export`。

## 配置项

| 变量 | 默认 | 说明 |
|---|---|---|
| `CERT_DOMAINS` | 无（必填） | 域名列表，写多少签多少 |
| `CERT_DNS` | `dns_cf` | `dns_cf` / `dns_dp`，决定凭据怎么用 |
| `CF_Token` | 无 | dns_cf 用（Cloudflare API Token） |
| `DP_Id` / `DP_Key` | 空 | dns_dp 用（DNSPod 的 ID 和 Token） |
| `CERT_EMAIL` | 空 | 账号邮箱，用于 CA 到期提醒 |
| `CERT_SERVER` | `letsencrypt` | `letsencrypt` / `zerossl` |
| `CERT_DAYS` | `30` | 续期窗口的兜底值，限制 1–89。Let's Encrypt 启用 ARI 后由 CA 决定实际续期时机，这个值只在 CA 未给出建议窗口时生效（见下文） |
| `CERT_KEYLEN` | `ec-256` | `ec-256` `ec-384` `ec-521` `2048` `3072` `4096` |
| `DO_DEPLOY` | `0` | 部署开关，当前未实现 |
| `ACME_DEBUG` | 空 | 传给 acme.sh 的 `--debug` 级别（0–3），留空不加 |
| `SHELL_DEBUG` | `0` | `1` = dry-run，只打印命令不执行 |

凭据变量直接用 acme.sh 原生的名字，按 `CERT_DNS` 只填对应那一组。
不做中间映射是有意的：同一时刻只有一个 provider 在用，多一层别名反而让人
分不清 acme.sh 到底读哪个变量，也和官方文档对不上。

优先级：**环境变量 > `.env` > 脚本默认值**。想临时覆盖：

```bash
CERT_DOMAINS=test.com,www.test.com ./auto_cert.sh issue
```

`LOG_MAX_SIZE`（默认 1048576，单位字节）只从环境变量读，不进 `.env`：它控制 `auto_cert.log` 的自动截断阈值，超过时保留尾部日志，避免 cron 长年运行把日志撑大。设为 `0` 可关闭轮转。

### 关于续期时机（ARI）

Let's Encrypt 会通过 ARI（ACME Renewal Information）直接给出建议的续期窗口，acme.sh 会以它为准。日志里能看到：

```
ARI suggestedWindow: 2027-01-02T11:31:43Z to 2027-01-04T06:42:32Z
It is later than the renewal time you asked for, keeping: 2026-12-03T09:46:14Z
```

所以 `CERT_DAYS` 不是「到期前 N 天就续」，而是**CA 未给出建议窗口时的兜底值**。`renew` 未到窗口时返回 `2`，这是正常的，不需要 `--force`。

## 调试

两个开关，对应原脚本的 `ACMEDEBUGNUM` 和 `SHELLDEBUGNUM`：

**`ACME_DEBUG=0..3`** —— 传给 acme.sh 的 `--debug N`。0 只打错误，3 打印完整 HTTP 报文。注意 `0` 是真值，会被显式传递。

**`SHELL_DEBUG=1`** —— dry-run。只打印将要执行的完整命令，**不调用 CA、不消耗配额**：

```bash
SHELL_DEBUG=1 ./auto_cert.sh issue
# [DRYRUN] /path/acme.sh --config-home ... --server letsencrypt --debug 2 --issue -d a.com -d *.a.com --keylength ec-256 --dns dns_cf --days 30
# dry-run 模式（SHELL_DEBUG=1），未真正执行
```

确认参数拼接是否正确时用这个，比真跑一遍安全。

## 产物

```
out/<主域名>/
├── fullchain.cer          叶子 + 中间（服务端用这个）
├── <主域名>.cer           仅叶子
├── ca.cer                 仅中间
└── <主域名>.key           私钥，权限 600
```

文件名与 acme.sh 的证书目录**完全一致**，脚本只做一次 `cp` 把 4 个文件拷过来，
不改名。`.cer` 本身就是 PEM 文本（首行 `-----BEGIN CERTIFICATE-----`），
改叫 `.pem` 不影响任何使用方，纯属多余动作。

acme.sh 目录里的 `<主域名>.conf` 和 `<主域名>.csr` **不导出**：前者是 acme.sh 的
续期状态，后者是请求文件，都不属于交付物；`.conf` 若被误拷回 `certs/` 会干扰
续期判断。

证书的元信息（到期时间、SAN、指纹等）不落盘——需要时用 `./auto_cert.sh status`
现读，或用 `openssl x509` 直接查。存一份快照会随着时间失真，不如不存。

**主域名 = `CERT_DOMAINS` 的第一个**，它决定产物目录名和 acme.sh 的证书目录名。

## 目录结构

```
auto_cert.sh        本脚本
.env                凭据，chmod 600，勿提交
acme.sh/            acme.sh 本体
conf/               acme.sh 的 --config-home
certs/              acme.sh 的 --cert-home
out/                本脚本的产物
auto_cert.log       运行日志（超过 LOG_MAX_SIZE 自动截断，默认 1 MB）
```

## 关于 conf 共享（重要）

acme.sh 的 `conf/` 目录结构是这样：

```
conf/
├── account.conf                      ← 全局唯一，存 SAVED_<凭据变量>
└── ca/<CA域名>/
    ├── account.key
    ├── account.json
    └── ca.conf                       ← 账号按 CA 隔离
```

而每个域名的配置在 `certs/<域名>_ecc/<域名>.conf`。

**结论：**

| 场景 | 安全性 |
|---|---|
| 同一 Cloudflare 账号，多个域名 / 多域名证书 | ✅ 安全 |
| 同一机器使用多个不同 CA | ✅ 安全（`conf/ca/` 按 CA 分目录） |
| 同一机器使用**多套不同 DNS 凭据** | ⚠️ `account.conf` 里的 `SAVED_CF_Token` 会被后一次覆盖 |

第三条只在「同一台机器管多个不同 Cloudflare 账号」时才出问题。真遇到的话，给不同账号各配一个 `CONF_HOME`：

```bash
CONF_HOME=/path/to/conf-a ./auto_cert.sh issue
```

## cron

```bash
# 每天 3 点检查续期，未到期返回 2 自然结束，不消耗配额
0 3 * * * cd /vol1/1000/Others/scripts/syno && ./auto_cert.sh renew >> cron.log 2>&1
```

**不要同时装 acme.sh 自带的 cron**（`--install-cronjob`），两个调度器会抢着改同一张证书。

## 部署（未实现）

`DO_DEPLOY=0`，`do_deploy()` 是空函数。等需要时再按目标环境（fnOS WebSocket API / 群晖文件路径 / 自定义路径）实现。

## 测试

```bash
bash .test/all.sh
```

| 套件 | 覆盖 |
|---|---|
| `run.sh` | 17 项主流程：签发、幂等、续期、吊销、`out/` 自动补导出、日志轮转、错误处理 |
| `edge.sh` | 12 组边界：CRLF、非法域名、异常返回码、证书损坏、配置覆盖 |
| `env_priority.sh` | 6 项配置优先级 |
| `domains_unit.sh` | 49 项域名解析单元测试（去重、分隔符、主域名规则、上限、控制字符、通配展开免疫） |
| `revoke.sh` | 13 项吊销相关：残骸清理、失效检测、残缺恢复、清理失败回滚 |
| `perms.sh` | 15 项产物检查：4 个文件齐全、私钥 600、其余 644、证书与私钥配对、`.conf`/`.csr` 不导出、SAN 格式、umask 077 |
| `debug.sh` | 9 项调试参数：`--debug` 传递、dry-run 不执行、非法值拒绝、`.env` 覆盖 |
| `params.sh` | 全参数矩阵：每个配置项的合法值 / 非法值 / 传参正确性 / 子命令解析 |

全部使用假 acme.sh + 自签证书，不联网、不消耗 CA 配额。

`params.sh` 是覆盖最全的一套，逐项验证：

| 参数 | 验证内容 |
|---|---|
| `CERT_DOMAINS` | 分隔符、去重、通配符位置、非法字符 |
| `CERT_EMAIL` | 传参、空值不传、无邮箱告警 |
| `CERT_SERVER` | letsencrypt / zerossl / 其他 CA |
| `CERT_DAYS` | 1/30/89 通过，0/90/150/-1/abc/3.5/空 拒绝 |
| `CERT_KEYLEN` | 6 种合法值 + 4 种非法值 + ECC/RSA 目录后缀 + `--ecc` 传递 |
| `CERT_DNS` | dns_cf/dns_dp + 凭据检查随插件切换 |
| `DO_DEPLOY` | 0/1 |
| `ACME_DEBUG` | 0-3 传递（含 0）、4/9/abc/-1 拒绝 |
| `SHELL_DEBUG` | dry-run 不执行、0 正常执行、2 拒绝 |
| 路径变量 | `ACME_HOME` / `CERT_HOME` / `OUT_HOME` / `CONF_HOME` / `LOG_FILE` |
| 子命令解析 | 6 种合法子命令、未知子命令/无参数拒绝、help、多余参数静默忽略 |

## 吊销之后

`revoke` 只让证书在 CA 侧作废，**不会删除本地文件**。所以：

- `status` 会显示证书信息但标记「已失效」，并返回 1
- `issue` 会自动清理 acme.sh 留下的 `*.revoked` 残骸，然后重新签发

acme.sh 吊销时会把 `<域名>.csr` / `<域名>.key` 改名成 `*.revoked`。这些残骸不清理，后续 `--issue` 会读到旧 CSR 而误判。

## 兼容性说明

- 只用 **bash 3.2** 兼容语法（群晖 DSM 6 的 bash 是 3.2），不使用关联数组 `declare -A`
- `date -d` 与 BSD 的 `date -j` 都兼容
- 无 `local -n`、无 `${var,,}` 等 bash 4+ 特性

## 排查

| 现象 | 原因 |
|---|---|
| `CERT_DOMAINS 未设置` | `.env` 没加载或变量名拼错 |
| `缺少 CF_Token` | `CERT_DNS=dns_cf` 但没填 `CF_Token` |
| `缺少 DP_Id` / `DP_Key` | `CERT_DNS=dns_dp` 但 DNSPod 凭据没填全 |
| `CERT_DOMAINS 第一个名字不能是通配符` | 主域名会用作目录名，把裸域名挪到第一个 |
| `域名格式非法` | 检查下划线、连续点、首尾连字符、末尾点 |
| `CERT_DAYS 必须是 1-89 的整数` | 值超出范围或不是整数。注意它只是 ARI 的兜底值，改大不会让续期提前 |
| `另一个实例正在运行` | 上一轮没结束，或删掉 `.auto_cert.lock` |
| 域名末尾莫名带 `\r` | `.env` 用了 Windows 换行，`dos2unix .env` 即可 |
