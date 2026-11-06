#!/bin/bash
# auto_cert.sh - 自管证书签发/续期（acme.sh 只当执行器）
#
# 用法:
#   ./auto_cert.sh issue            首次签发（已签发则跳过）
#   ./auto_cert.sh renew            续期（由 Let's Encrypt ARI 决定时机）
#   ./auto_cert.sh renew --force    强制续期
#   ./auto_cert.sh export           只重新导出证书到 out/（不联网、不耗配额）
#   ./auto_cert.sh revoke           吊销
#   ./auto_cert.sh status           查看证书状态
#
# 域名规则：CERT_DOMAINS 写多少签多少，不做自动补全，通配符直接写在列表里。
# 退出码: 0 成功 / 1 失败 / 2 无需操作

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)

# 只给路径类变量设默认值；业务配置留到 load_env，否则会覆盖 .env
ACME_HOME=${ACME_HOME-"$SCRIPT_DIR/acme.sh"}
ACME_BIN="$ACME_HOME/acme.sh"
CONF_HOME=${CONF_HOME-"$SCRIPT_DIR/conf"}
CERT_HOME=${CERT_HOME-"$SCRIPT_DIR/certs"}
OUT_HOME=${OUT_HOME-"$SCRIPT_DIR/out"}
LOG_FILE=${LOG_FILE-"$SCRIPT_DIR/auto_cert.log"}

# 同时输出到 stdout 和日志文件。tee 在文件不可写时仍会写 stdout，
# 外层 2>/dev/null 连 printf 的报错一起吞掉，cron 里不刷屏。
log() {
    { printf '%s\n' "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; } 2>/dev/null || true
}

# 一次输出多行，每行带独立时间戳
logm() { local m; for m in "$@"; do log "$m"; done; }

# 日志超过上限时按字节保留尾部，并丢掉可能被截断的半行。
# 只在 main 里跑一次，避免每次 log 都做 stat。
rotate_log() {
    local max=${LOG_MAX_SIZE-1048576} size tmp
    [[ -f $LOG_FILE && $LOG_FILE != /dev/null ]] || return 0
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0
    (( size > max )) || return 0
    tmp="$LOG_FILE.tmp.$$"
    # 保留最后 max/2 字节，从第一个完整行开始（跳过被截断的半行）
    if tail -c $((max / 2)) "$LOG_FILE" | tail -n +2 >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$LOG_FILE" && log "日志超过 $((max / 1024)) KB，已截断保留尾部"
    else
        rm -f "$tmp"
    fi
}

warn() { log "WARN: $*"; }

die() { log "ERROR: $*" >&2; exit 1; }

# 取字段: cert_field <证书> <valid|sans|enddate|subject|issuer>
# 整个脚本只有这里调 openssl x509
cert_field() {
    local crt=$1 what=$2 out; local -a x=(openssl x509 -in "$crt" -noout)

    case "$what" in
        valid) "${x[@]}" -checkend 0 >/dev/null 2>&1 && printf 1 || printf 0; return ;;
        sans)
            "${x[@]}" -ext subjectAltName 2>/dev/null |
                tail -n +2 | tr -d ' ' | tr '\n' ',' | sed 's/DNS://g; s/,$//' | tr ',' ' '
            return
            ;;
    esac
    out=$("${x[@]}" "-$what" 2>/dev/null)
    printf '%s' "${out#*=}"
}

# 到期时间串 → 剩余天数，取不到输出 ?
cert_days_left() {
    local end=$1 end_ts now_ts
    [[ -n $end ]] || { printf '?'; return; }
    end_ts=$(date -d "$end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$end" +%s 2>/dev/null)
    now_ts=$(date +%s)
    [[ -n $end_ts ]] && printf '%s' $(((end_ts - now_ts) / 86400)) || printf '?'
}

# 要读并 export 给 acme.sh 的键。凭据用 acme.sh 原生变量名，不做中间映射。
CONFIG_KEYS=(CERT_DOMAINS CERT_EMAIL CERT_SERVER CERT_KEYLEN CERT_DAYS
    CERT_DNS DO_DEPLOY ACME_DEBUG SHELL_DEBUG CF_Token DP_Id DP_Key)

# 优先级：环境变量 > .env > 默认值。
# .env 里的 VAR=value 不会 export，而 acme.sh 是子进程，所以最后统一导出。
load_env() {
    local -a preset=(); local v
    for v in "${CONFIG_KEYS[@]}"; do
        [[ -n ${!v+x} ]] && preset+=("$v=${!v}")
    done

    # shellcheck disable=SC1090
    [[ -f "$SCRIPT_DIR/.env" ]] && . "$SCRIPT_DIR/.env"

    for v in "${preset[@]}"; do
        printf -v "${v%%=*}" '%s' "${v#*=}"
    done

    # ${VAR-x} 只在完全未设置时生效，显式空值保留；后三个无默认值，只为 set -u 下可安全引用
    CERT_SERVER=${CERT_SERVER-letsencrypt}
    CERT_KEYLEN=${CERT_KEYLEN-ec-256}
    CERT_DAYS=${CERT_DAYS-30}
    CERT_DNS=${CERT_DNS-dns_cf}
    DO_DEPLOY=${DO_DEPLOY-0}
    SHELL_DEBUG=${SHELL_DEBUG-0}
    CERT_DOMAINS=${CERT_DOMAINS-}
    CERT_EMAIL=${CERT_EMAIL-}
    ACME_DEBUG=${ACME_DEBUG-}

    export "${CONFIG_KEYS[@]}"
}

# 裸域名：至少两段，每段 1-63 字符，只能字母数字连字符，首尾不能是连字符
is_valid_domain() {
    local d=$1 part; local -a parts
    [[ $d == "" || $d == *" "* || $d == *. || $d == *'*'* || $d != *.* ]] && return 1
    # 必须先拒控制字符：read -ra <<<"$d" 只读到第一个换行，"a\nb.com" 会被截成 "a"
    [[ $d == *[$'\t\n\r']* ]] && return 1
    (( ${#d} <= 253 )) || return 1
    # 不能用 for part in $d，那会做文件名通配展开（cwd 有 axb 时 "a?b.com" 会通过）
    IFS=. read -ra parts <<<"$d"
    for part in "${parts[@]}"; do
        [[ -z $part || ${#part} -gt 63 || $part == *[!a-zA-Z0-9-]* || $part == -* || $part == *- ]] && return 1
    done
    return 0
}

# 裸域名或 *.域名
is_valid_domain_or_wildcard() {
    local d=$1
    case "$d" in
        '*.'*) is_valid_domain "${d#\*.}" ;;
        *'*'*) return 1 ;;
        *) is_valid_domain "$d" ;;
    esac
}

# 解析 CERT_DOMAINS，结果存进全局 DOMAINS（去重保序）和 PRIMARY（第一个）
build_domains() {
    [[ -n $CERT_DOMAINS ]] || die "CERT_DOMAINS 未设置，例如 CERT_DOMAINS=\"your.domain\""

    local raw input=() item d base bare_list="" wild_list=""
    raw=$(printf '%s' "$CERT_DOMAINS" | tr ',;' '\n' | tr -s ' \t' '\n')
    while IFS= read -r item; do [[ -n $item ]] && input+=("$item"); done <<<"$raw"
    [[ ${#input[@]} -gt 0 ]] || die "CERT_DOMAINS 解析后为空: '$CERT_DOMAINS'"

    for d in "${input[@]}"; do
        is_valid_domain_or_wildcard "$d" || die "域名格式非法: '$d'（是否带了空格、下划线、多余的点，或 * 不在开头？）"
    done

    # ${hit[$d]-} 的 - 不能省：取不存在的键在 set -u 下是 unbound variable
    local -A hit=(); local -a uniq=()
    for d in "${input[@]}"; do
        [[ ${hit[$d]-} ]] && continue
        hit[$d]=1
        uniq+=("$d")
    done
    DOMAINS=("${uniq[@]}")

    # 主域名会被用作目录名，不能含 *。不能写成 local PRIMARY=...，那会遮蔽全局
    PRIMARY=${DOMAINS[0]}
    if [[ $PRIMARY == \** ]]; then
        for d in "${DOMAINS[@]}"; do
            [[ $d != \** ]] && bare_list+="$d," || wild_list+="$d,"
        done
        [[ -n $bare_list ]] && die "CERT_DOMAINS 第一个名字不能是通配符（当前: '$PRIMARY'）。
      主域名会用作证书目录名，不能含 *。
      改成: CERT_DOMAINS=\"${bare_list}${wild_list%,}\""
        die "CERT_DOMAINS 至少要有一个非通配符域名作为主域名（当前全是通配符: $CERT_DOMAINS）"
    fi

    # *.a.com 不覆盖 a.com（RFC 6125）。只告警不拦
    for d in "${DOMAINS[@]}"; do
        [[ $d == \** ]] || continue
        base=${d#\*.}
        [[ ${hit[$base]-} ]] || warn "配置了通配符 '$d' 但没写 '$base' —— *.x 不覆盖 x 本身，裸域名将不受这张证书保护"
    done

    (( ${#DOMAINS[@]} <= 100 )) || die "域名数量 ${#DOMAINS[@]} 超过 Let's Encrypt 单证书上限 100"
}

# 调用方必须先跑过 build_domains（check_env 开头会调）
set_cert_dir() {
    case "$CERT_KEYLEN" in
        ec-*) CERT_DIR="$CERT_HOME/${PRIMARY}_ecc" ;;
        *) CERT_DIR="$CERT_HOME/$PRIMARY" ;;
    esac
}

resolve_server() { printf '%s' "$CERT_SERVER"; }

# need 必须初始化为空数组：只声明不赋值时 ${#need[@]} 在 set -u 下是
# unbound variable 错误，而不是 0，下面的 die 就永远走不到。
check_dns_creds() {
    local -a need=(); local k
    [[ $CERT_DNS == dns_cf ]] && need=(CF_Token)
    [[ $CERT_DNS == dns_dp ]] && need=(DP_Id DP_Key)
    (( ${#need[@]} > 0 )) || die "不支持的 CERT_DNS=$CERT_DNS（当前支持 dns_cf / dns_dp）"

    for k in "${need[@]}"; do
        [[ -n ${!k-} ]] || die "缺少 $k（$CERT_DNS 需要 ${need[*]}）。请写入 $SCRIPT_DIR/.env"
    done
}

# 统一的 acme.sh 调用入口
acme() {
    local args=(
        --config-home "$CONF_HOME"
        --cert-home "$CERT_HOME"
        --server "$(resolve_server)"
    )
    [[ -n $ACME_DEBUG ]] && args+=(--debug "$ACME_DEBUG")

    # 必须 exit 不能 return，否则 do_issue 会接着 export_certs 而证书不存在
    [[ $SHELL_DEBUG -eq 1 ]] && {
        printf '[DRYRUN] %s\n' "$ACME_BIN$(printf ' %q' "${args[@]}" "$@")"
        log "dry-run 模式（SHELL_DEBUG=1），未真正执行"
        exit 0
    }
    "$ACME_BIN" "${args[@]}" "$@"
}

check_env() {
    build_domains

    # 上限 89：--days 是"提前多少天开始尝试续期"，超过 90 天证书生命周期没有意义
    [[ $CERT_DAYS =~ ^[0-9]+$ ]] && ((CERT_DAYS >= 1 && CERT_DAYS <= 89)) || die "CERT_DAYS 必须是 1-89 的整数（当前: '$CERT_DAYS'）"
    [[ $CERT_KEYLEN =~ ^(ec-256|ec-384|ec-521|2048|3072|4096)$ ]] || die "CERT_KEYLEN 不支持: '$CERT_KEYLEN'（可用: ec-256 ec-384 ec-521 2048 3072 4096）"

    set_cert_dir

    [[ -z $ACME_DEBUG || $ACME_DEBUG =~ ^[0-3]$ ]] || die "ACME_DEBUG 只能是 0-3 或留空（当前: '$ACME_DEBUG'）"
    [[ $SHELL_DEBUG == [01] ]] || die "SHELL_DEBUG 只能是 0 或 1（当前: '$SHELL_DEBUG'）"

    [[ -x "$ACME_BIN" ]] || {
        log "acme.sh 不存在，开始下载..."
        git clone https://github.com/acmesh-official/acme.sh "$ACME_HOME" || die "acme.sh 下载失败，请检查网络（可尝试 gh-proxy 镜像）"
        chmod +x "$ACME_BIN" || die "无法设置 acme.sh 可执行权限"
        log "acme.sh 下载完成"
    }

    command -v openssl >/dev/null 2>&1 || die "缺少 openssl"

    check_dns_creds

    [[ -n $CERT_EMAIL ]] || warn "CERT_EMAIL 未设置，CA 无法发送到期提醒"

    mkdir -p "$CONF_HOME" "$CERT_HOME" || die "无法创建工作目录"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
}

# 把 DOMAINS 数组转成 acme.sh 的 -d 参数
build_domain_args() {
    DOMAIN_ARGS=()
    local d
    for d in "${DOMAINS[@]}"; do
        DOMAIN_ARGS+=(-d "$d")
    done
}

# 吊销痕迹：acme.sh 会把 <域名>.csr / .key 改名成 *.revoked，这是本地唯一线索
is_revoked() {
    [[ -e "$CERT_DIR/${PRIMARY}.csr.revoked" || -e "$CERT_DIR/${PRIMARY}.key.revoked" ]]
}

is_issued() {
    [[ -s "$CERT_DIR/${PRIMARY}.cer" && -s "$CERT_DIR/${PRIMARY}.key" ]] || return 1
    [[ $(cert_field "$CERT_DIR/${PRIMARY}.cer" valid) == 1 ]]
}

# 有 csr/key/cer 残留但证书与私钥不成对——这种半残状态 acme.sh 处理不好
dir_is_incomplete() {
    [[ -d $CERT_DIR ]] || return 1

    local has_trace=0
    [[ -e "$CERT_DIR/${PRIMARY}.csr" ]] && has_trace=1
    [[ -e "$CERT_DIR/${PRIMARY}.key" ]] && has_trace=1
    [[ -e "$CERT_DIR/${PRIMARY}.cer" ]] && has_trace=1
    [[ $has_trace -eq 1 ]] || return 1

    ! { [[ -s "$CERT_DIR/${PRIMARY}.cer" && -s "$CERT_DIR/${PRIMARY}.key" ]]; }
}

# 只删 *.revoked，绝对不要碰 <域名>.key：删了 key 会让 acme.sh 复用旧 CSR，
# 签出没有对应私钥的证书，整个目录报废。
clean_revoked_residue() {
    [[ -d $CERT_DIR ]] || return 0

    local f cleaned=0
    for f in "$CERT_DIR"/*.revoked; do
        [[ -e $f ]] || continue
        rm -f "$f" || { warn "无法删除 $f"; continue; }
        cleaned=$((cleaned + 1))
    done

    (( cleaned > 0 )) && log "已清理吊销残留（$cleaned 个 .revoked 文件）"
    return 0
}

do_issue() {
    build_domain_args

    # 已有有效证书：只检查 out/ 产物是否齐全，缺了就补导出，然后跳过
    is_issued && {
        if ! out_is_complete; then
            log "证书有效但 out/ 产物不全，补导出"
            export_certs || die "补导出失败"
        else
            log "已签发且证书有效，跳过: $PRIMARY"
        fi
        return 2
    }

    is_revoked && { log "检测到该域名曾被吊销，清理残留后重新签发"; clean_revoked_residue; }

    # acme.sh 会复用残留 .csr 签发，签出的证书没有对应私钥，所以 crt/key/csr 要一起删。
    # 删之前先整个备份：签发可能失败（配额不足、网络中断），失败后要能还原，
    # 否则会出现 certs/ 只剩一把孤立的 .key 而 out/ 里还是旧证书的错配状态。
    local backup=""
    if dir_is_incomplete; then
        log "检测到证书/私钥残缺，清理 $CERT_DIR 后重新签发"
        backup="$CERT_DIR.incomplete.$$"
        rm -rf "$backup"
        cp -a "$CERT_DIR" "$backup" || backup=""
        for s in .csr .csr.conf .key .cer; do rm -f "$CERT_DIR/${PRIMARY}${s}"; done
    fi

    # issue 的语义是"我要一张证书"，而 acme.sh 读残留 .conf 会按续期时间表跳过，所以必然带 --force
    log "本地无可用证书，强制签发"

    log "签发 ${#DOMAINS[@]} 个名字: ${DOMAINS[*]}"
    log "  key=$CERT_KEYLEN  server=$(resolve_server)"

    local args=("${DOMAIN_ARGS[@]}")
    args+=(--keylength "$CERT_KEYLEN")
    args+=(--dns "$CERT_DNS")
    args+=(--days "$CERT_DAYS")
    args+=(--force)
    [[ -n $CERT_EMAIL ]] && args+=(--accountemail "$CERT_EMAIL")

    if ! acme --issue "${args[@]}"; then
        if [[ -n $backup ]]; then
            rm -rf "$CERT_DIR" && mv "$backup" "$CERT_DIR" &&
                log "签发失败，已还原清理前的 $CERT_DIR"
        fi
        die "acme.sh --issue 失败"
    fi
    [[ -n $backup ]] && rm -rf "$backup"
    log "签发成功"
    export_certs
    return 0
}

do_renew() {
    is_issued || { log "尚无证书，先执行 issue"; die "没有可续期的证书"; }

    build_domain_args
    local suffix=""
    [[ $FORCE -eq 1 ]] && suffix=" (--force)"
    log "续期 ${#DOMAINS[@]} 个名字: ${DOMAINS[*]}$suffix"

    local args=("${DOMAIN_ARGS[@]}")
    args+=(--keylength "$CERT_KEYLEN")
    args+=(--dns "$CERT_DNS")
    args+=(--days "$CERT_DAYS")
    [[ $FORCE -eq 1 ]] && args+=(--force)

    acme --renew "${args[@]}"
    local rc=$?
    ((rc==0)) && { log "续期成功"; export_certs; return 0; }
    ((rc==2)) && {
        log "证书尚未到续期时间（ARI 决定），跳过"
        # 未续期也要保证 out/ 完整，否则产物丢失后没人补
        out_is_complete || { log "out/ 产物不全，补导出"; export_certs; }
        return 2
    }
    die "acme.sh --renew 失败（rc=$rc）"
}

do_export() {
    is_issued || die "acme.sh 侧没有有效证书，请先执行 issue"
    export_certs || die "导出失败"
    do_status || true
}

# out/ 里 4 个产物是否齐全；有服务直接读 out/ 时，缺一个就不算完整
out_is_complete() {
    local f dir="$OUT_HOME/$PRIMARY"
    for f in fullchain.cer "${PRIMARY}.cer" ca.cer "${PRIMARY}.key"; do
        [[ -s "$dir/$f" ]] || return 1
    done
    return 0
}

export_certs() {
    local src="$CERT_DIR" dst="$OUT_HOME/$PRIMARY"

    [[ -d $src ]] || die "acme.sh 证书目录不存在: $src"
    mkdir -p "$dst" || die "无法创建输出目录: $dst"

    # 只拷这 4 个：.conf 是续期状态，.csr 是请求文件，都不属于产物
    cp -f "$src/fullchain.cer" "$src/${PRIMARY}.cer" "$src/ca.cer" "$src/${PRIMARY}.key" "$dst/" || die "导出证书失败（$src -> $dst）"

    # 必须显式设权限：cp 建文件走 umask，umask 077 时公钥也会是 600
    chmod 644 "$dst"/*.cer
    chmod 600 "$dst/${PRIMARY}.key"

    log "产物已导出: $dst"
}

do_status() {
    local dir="$OUT_HOME/$PRIMARY" crt="$OUT_HOME/$PRIMARY/${PRIMARY}.cer"
    [[ -s "$dir/fullchain.cer" ]] || { log "尚无证书（$dir）"; return 1; }

    # revoke 只让证书在 CA 侧作废，不删本地文件，所以文件在不代表有效
    local invalid_reason=""
    is_revoked && invalid_reason="已吊销"
    [[ -z $invalid_reason ]] && ! is_issued &&
        { dir_is_incomplete && invalid_reason="证书/私钥残缺" || invalid_reason="acme.sh 侧无有效证书"; }

    local end left
    end=$(cert_field "$crt" enddate)
    [[ -n $end ]] || { log "证书解析失败: $crt"; return 1; }
    left=$(cert_days_left "$end")

    logm "主域名: $PRIMARY" "配置  : ${DOMAINS[*]}" "SAN   : $(cert_field "$crt" sans)" \
        "CA    : $(resolve_server)" "到期  : $end" "剩余  : ${left} 天" \
        "        subject=$(cert_field "$crt" subject)" "        issuer=$(cert_field "$crt" issuer)"

    [[ -n $invalid_reason ]] &&
        { warn "该证书已失效（$invalid_reason），不可用于对外服务；重新签发: $0 issue"; return 1; }

    [[ $left != "?" && $left -lt 15 ]] && warn "剩余不足 15 天，请检查续期任务"
    return 0
}

do_revoke() {
    is_issued || die "没有可吊销的证书"

    build_domain_args
    log "吊销: $PRIMARY（共 ${#DOMAINS[@]} 个名字）"

    local args=("${DOMAIN_ARGS[@]}")
    args+=(--keylength "$CERT_KEYLEN")
    args+=(--dns "$CERT_DNS")
    [[ $CERT_KEYLEN == ec-* ]] && args+=(--ecc)

    acme --revoke "${args[@]}" || die "吊销失败（证书可能已过期或已吊销）"
    log "已吊销。本地文件保留在 $OUT_HOME/$PRIMARY，可手工删除"
    return 0
}

# 部署暂未实现，接 fnOS / 群晖时在这里加
do_deploy() {
    log "部署已跳过（DO_DEPLOY=$DO_DEPLOY）"
    return 0
}

usage() {
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
}

main() {
    local action=""
    FORCE=0
    [[ ${1-} == "issue" || ${1-} == "renew" || ${1-} == "revoke" || ${1-} == "status" || ${1-} == "deploy" || ${1-} == "export" ]] && action="$1"
    [[ -n ${2-} && $action == "renew" && ${2-} == "--force" ]] && FORCE=1
    # 没有子命令：打印用法；help 类参数正常退出，其余说明参数拼错了
    [[ -z $action ]] && { usage; case "${1-}" in ""|-h|--help|help) exit 0 ;; esac; die "Error Input(${1-})"; }

    exec 9>"$SCRIPT_DIR/.auto_cert.lock"
    command -v flock >/dev/null 2>&1 && { flock -n 9 || die "另一个实例正在运行"; }

    load_env
    check_env
    rotate_log

    local rc=0
    case "$action" in
        issue) do_issue || rc=$? ;;
        renew) do_renew || rc=$? ;;
        export) do_export; exit 0 ;;
        revoke) do_revoke; exit 0 ;;
        status) do_status; exit $? ;;
        deploy) do_deploy; exit 0 ;;
    esac

    [[ $rc -eq 2 ]] && { do_status || true; exit 2; }
    [[ $rc -eq 0 ]] || die "操作失败（rc=$rc）"

    [[ $DO_DEPLOY -eq 1 ]] && do_deploy
    do_status || true
    exit 0
}

main "$@"
