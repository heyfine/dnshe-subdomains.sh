#!/usr/bin/env bash
set -euo pipefail

API_URL='https://api005.dnshe.com/index.php?m=domain_hub&endpoint=subdomains'
JQ_DEFS='
  def expires_epoch: (.expires_at | sub(" "; "T") + "Z" | fromdateiso8601);
  def needs_renewal:
    (.never_expires | tonumber) == 0 and expires_epoch <= now + 30 * 24 * 60 * 60;
'

for command in curl jq; do
  command -v "$command" >/dev/null || { echo "错误: 缺少依赖 $command" >&2; exit 1; }
done

if [[ ${1:-} == '--self-test' ]]; then
  jq -ne "$JQ_DEFS
    ({never_expires: 0, expires_at: ((now + 29 * 86400) | strftime(\"%Y-%m-%d %H:%M:%S\"))} | needs_renewal) and
    ({never_expires: 0, expires_at: ((now + 31 * 86400) | strftime(\"%Y-%m-%d %H:%M:%S\"))} | needs_renewal | not) and
    ({never_expires: 1, expires_at: ((now + 1 * 86400) | strftime(\"%Y-%m-%d %H:%M:%S\"))} | needs_renewal | not)" >/dev/null
  echo 'self-test: ok'
  exit
fi

: "${API_KEY:?错误: 请先设置环境变量 API_KEY}"
: "${API_SECRET:?错误: 请先设置环境变量 API_SECRET}"
: "${TELEGRAM_BOT_TOKEN:?错误: 请先设置环境变量 TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?错误: 请先设置环境变量 TELEGRAM_CHAT_ID}"

headers=(
  -H "X-API-Key: $API_KEY"
  -H "X-API-Secret: $API_SECRET"
)

response=$(curl --fail-with-body --silent --show-error \
  "$API_URL&action=list&page=1&per_page=200&sort_by=expires_at&sort_dir=desc" \
  "${headers[@]}")

jq -e '.success == true and (.subdomains | type == "array")' <<<"$response" >/dev/null || {
  echo "错误: 查询域名失败: $(jq -c . <<<"$response" 2>/dev/null || printf '%s' "$response")" >&2
  exit 1
}

printf '%-12s %-36s %-10s %-20s %s\n' 'ID' '域名' '永久域名' '到期时间' '本次续期'
jq -r "$JQ_DEFS
  .subdomains[] |
  [.id, .full_domain, (if (.never_expires | tonumber) != 0 then \"是\" else \"否\" end),
   (if (.never_expires | tonumber) != 0 then \"-\" else .expires_at end),
   (if needs_renewal then \"是\" else \"否\" end)] | @tsv" <<<"$response" |
while IFS=$'\t' read -r id domain permanent expires renew; do
  printf '%-12s %-36s %-10s %-20s %s\n' "$id" "$domain" "$permanent" "$expires" "$renew"
done

notification_lines=('<b>DNSHE 域名续期结果</b>')
while IFS= read -r line; do
  notification_lines+=("$line")
done < <(jq -r "$JQ_DEFS
  .subdomains[] |
  \"<code>\(.id)</code> | <code>\(.full_domain | @html)</code> | 永久: \(if (.never_expires | tonumber) != 0 then \"是\" else \"否\" end) | 到期: \(if (.never_expires | tonumber) != 0 then \"-\" else .expires_at end) | 本次续期: \(if needs_renewal then \"是\" else \"否\" end)\"" <<<"$response")

notification_lines+=('' '<b>续期执行结果</b>')
renewal_count=0
renewal_failed=0
while IFS=$'\t' read -r id domain; do
  ((renewal_count += 1))
  payload=$(jq -n --argjson id "$id" '{subdomain_id: $id}')
  if renewed=$(curl --fail-with-body --silent --show-error -X POST \
      "$API_URL&action=renew" \
      "${headers[@]}" \
      -H 'Content-Type: application/json' \
      --data "$payload") && jq -e '.success == true' <<<"$renewed" >/dev/null; then
    echo "续期成功: $id $domain"
    notification_lines+=("✅ <code>$(jq -rn --arg value "$domain" '$value | @html')</code> 续期成功")
  else
    echo "错误: 续期失败 $id: ${renewed:-无响应}" >&2
    notification_lines+=("❌ <code>$(jq -rn --arg value "$domain" '$value | @html')</code> 续期失败")
    renewal_failed=1
  fi
done < <(jq -r "$JQ_DEFS .subdomains[] | select(needs_renewal) | [.id, .full_domain] | @tsv" <<<"$response")

((renewal_count > 0)) || notification_lines+=('无需续期')

send_telegram() {
  local telegram_response
  telegram_response=$(curl --fail-with-body --silent --show-error \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode 'parse_mode=HTML' \
    --data-urlencode "text=$1")
  jq -e '.ok == true' <<<"$telegram_response" >/dev/null || {
    echo "错误: Telegram 通知发送失败: $telegram_response" >&2
    return 1
  }
}

message=''
for line in "${notification_lines[@]}"; do
  if (( ${#message} + ${#line} > 3800 )); then
    send_telegram "$message"
    message='<b>DNSHE 域名续期结果（续）</b>'
  fi
  message+="${message:+$'\n'}$line"
done
send_telegram "$message"

((renewal_failed == 0))
