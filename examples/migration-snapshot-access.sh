#!/usr/bin/env bash
# 本轮安全修复端到端示例: 恢复前的反馈访问码效力跨记录核验
#
# 场景: 源实例在同一发布序号内发生"评语更正 -> 旧快照失效 -> 更正完成 -> 反馈
#       重新发布 (新版本/新访问码)"。会务方导出快照后, 若有人把旧快照的失效标记
#       (invalidated) 改回有效并重算内容校验和, 旧的恢复校验曾会接受该快照,
#       旧访问码随之"复活", 可再次读取已被更正的反馈并提交异议。
# 修复: POST /migration/restore 在恢复前依据快照版本、评语更正请求与论文撤回记录
#       交叉核验访问码效力——
#         * 已因更正 (同论文同发布序号、冻结的原评语收据命中快照两份收据之一)
#           或撤回失效的快照, 不能因仍属当前发布序号而复活 -> 422;
#         * 无撤回/更正证据的失效标记同样按矛盾快照拒绝 -> 422;
#         * 合法的连续更正、再次发布与跨发布序号历史快照可以迁移;
#         * 恢复后仅当前有效访问码可读取快照 (GET /feedback-snapshots/{code})
#           与提交异议 (POST /feedback-objections), 历史内容仍供会务方追溯
#           (GET /papers/{paper_id}/feedback-snapshots)。
#       矛盾快照整体回滚, 目标实例不留部分数据 (仍可重新恢复)。
#
# 需要两个实例:
#   源实例 (构造业务数据): BASE  默认 http://localhost:8000
#   目标实例 (空库):       BASE2 默认 http://localhost:8001
#   目标实例可用空库启动, 例如:
#     DB_PATH=./data/app-target.db PORT=8001 ORGANIZER_KEY=dev-organizer-key python -m app.main
# 用法: ./examples/migration-snapshot-access.sh [BASE_URL] [BASE2_URL]
set -euo pipefail

BASE="${1:-http://localhost:8000}"
BASE2="${2:-http://localhost:8001}"
ORG="X-Organizer-Key: ${ORGANIZER_KEY:-dev-organizer-key}"
CT='Content-Type: application/json'
j() { python3 -c 'import sys, json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
SNAP=/tmp/review-snapshot-access.json
TAMPERED=/tmp/review-snapshot-access-tampered.json
P1=P-SNAP-$$

rh() { # 评审人请求: rh METHOD PATH RID CRED [BODY]
  local method="$1" path="$2" rid="$3" cred="$4" body="${5:-}"
  if [ -n "$body" ]; then
    curl -s -X "$method" "$BASE$path" \
      -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred" -H "$CT" -d "$body"
  else
    curl -s -X "$method" "$BASE$path" \
      -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred"
  fi
}

echo "== 1. 源实例录入 2 名评审人与论文 $P1 并发布 (发布序号 serial) =="
curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H "$CT" -d '{
  "reviewer_id": "R-SNAP-A", "credential": "cred-a", "topics": ["AI"],
  "institution": "Inst-SNAP-A", "capacity": 3, "avoid_papers": []}'
curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H "$CT" -d '{
  "reviewer_id": "R-SNAP-B", "credential": "cred-b", "topics": ["AI"],
  "institution": "Inst-SNAP-B", "capacity": 3, "avoid_papers": []}'
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H "$CT" -d "{
  \"paper_id\": \"$P1\", \"manuscript\": \"匿名稿全文...\",
  \"topics\": [\"AI\"], \"institutions\": [\"Author-SNAP\"]}"
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
SERIAL=$(curl -s -X POST "$BASE/assignment/publish" -H "$ORG" -H "$CT" \
  -d "{\"base_revision\": $REV}" | j 'd["serial"]')
echo "    revision=$REV serial=$SERIAL"

echo "== 2. 两评审人确认并交正式评语, 会务方发布反馈快照 v1 -> 旧访问码 CODE_OLD =="
for spec in 'R-SNAP-A cred-a 3 A原评语' 'R-SNAP-B cred-b 4 B原评语'; do
  set -- $spec
  rh POST "/reviewer/assignments/$P1/decision" "$1" "$2" \
    "{\"paper_id\":\"$P1\",\"decision\":\"confirm\"}" > /dev/null
  RECEIPT=$(rh POST "/reviewer/assignments/$P1/review" "$1" "$2" \
    "{\"paper_id\":\"$P1\",\"serial\":$SERIAL,\"score\":$3,\"comment\":\"$4\"}" | j 'd["receipt"]')
  if [ "$1" = "R-SNAP-A" ]; then RECEIPT_A="$RECEIPT"; fi
done
CODE_OLD=$(curl -s -X POST "$BASE/papers/$P1/feedback-snapshot" -H "$ORG" -H "$CT" \
  -d "{\"serial\": $SERIAL}" | j 'd["access_code"]')
echo "    CODE_OLD=$CODE_OLD (R-SNAP-A 原评语收据: $RECEIPT_A)"
echo "    旧码当前可读: HTTP $(curl -s -o /dev/null -w '%{http_code}' "$BASE/feedback-snapshots/$CODE_OLD")"

echo "== 3. 会务方对 R-SNAP-A 槽位发起评语更正请求 -> 旧访问码立即失效 =="
curl -s -X POST "$BASE/papers/$P1/review-corrections" -H "$ORG" -H "$CT" -d "{
  \"paper_id\": \"$P1\", \"serial\": $SERIAL,
  \"reviewer_id\": \"R-SNAP-A\", \"reason\": \"评分与评语事实错误, 请更正\"}" \
  | j "'更正请求 id=' + str(d['correction_id']) + ' state=' + d['state'] + ' 本次失效版数=' + str(d['invalidated_snapshots'])"
echo "    旧码在更正请求后读取: HTTP $(curl -s -o /dev/null -w '%{http_code}' "$BASE/feedback-snapshots/$CODE_OLD") (统一 404)"

echo "== 4. R-SNAP-A 凭原收据提交更正后评语; 会务方按当前评语重新发布快照 v2 -> CODE_NEW =="
rh POST "/reviewer/review-corrections/$P1" R-SNAP-A cred-a "{
  \"paper_id\": \"$P1\", \"serial\": $SERIAL,
  \"original_receipt\": \"$RECEIPT_A\", \"score\": 5, \"comment\": \"A更正后评语\"}" \
  | j "'更正完成: 新收据=' + d['receipt'] + ' changed=' + str(d['changed'])"
CODE_NEW=$(curl -s -X POST "$BASE/papers/$P1/feedback-snapshot" -H "$ORG" -H "$CT" \
  -d "{\"serial\": $SERIAL}" | j 'd["access_code"]')
echo "    CODE_NEW=$CODE_NEW"

echo "== 5. 会务方导出一致业务数据快照 (含 v1 已失效 / v2 有效两个版本与更正记录) =="
curl -s "$BASE/migration/export" -H "$ORG" > "$SNAP"
python3 - "$SNAP" "$CODE_OLD" "$CODE_NEW" <<'PY'
import json, sys
snap, code_old, code_new = sys.argv[1:4]
d = json.load(open(snap))["data"]
for s in d["feedback_snapshots"]:
    tag = "CODE_OLD" if s["access_code"] == code_old else "CODE_NEW" if s["access_code"] == code_new else "?"
    print(f"    快照 v{s['version']} serial={s['serial']} invalidated={str(s['invalidated']).lower():5} {tag}")
print("    更正记录:", [(c["id"], c["state"], c["original_receipt"]) for c in d["review_corrections"]])
PY

echo "== 6. 攻击构造: 把 v1 旧快照 invalidated 改回 false 并重算内容校验和 =="
python3 - "$SNAP" "$TAMPERED" "$CODE_OLD" <<'PY'
import hashlib, json, sys
src, dst, code_old = sys.argv[1:4]
snap = json.load(open(src))
target = next(s for s in snap["data"]["feedback_snapshots"] if s["access_code"] == code_old)
assert target["invalidated"] is True, "前置条件: 旧快照本应已失效"
target["invalidated"] = False
canon = json.dumps(snap["data"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
snap["checksum"] = "sha256:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()
json.dump(snap, open(dst, "w"), ensure_ascii=False)
print("    已篡改失效标记并用同一算法重算 checksum:", snap["checksum"])
PY

echo "== 7. 向空目标实例恢复篡改快照 -> 422 (跨记录核验: 更正请求冻结的收据仍命中旧快照) =="
code=$(curl -s -o /tmp/review-restore-422.json -w '%{http_code}' -X POST "$BASE2/migration/restore" \
  -H "$ORG" -H "$CT" --data-binary @"$TAMPERED")
echo "    HTTP $code"
python3 -c 'import json; print("   ", json.load(open("/tmp/review-restore-422.json"))["detail"])'
[ "$code" = "422" ] || { echo "期望 422, 实际 $code" >&2; exit 1; }

echo "== 8. 目标实例不留部分数据 (空实例仍可恢复; 业务表为空、修订号为 0) =="
curl -s "$BASE2/meta" -H "$ORG" | j "'    恢复失败后目标实例: revision=' + str(d['revision'])"
curl -s "$BASE2/papers" -H "$ORG" | j "'    目标实例论文数: ' + str(len(d['papers']))"

echo "== 9. 恢复未篡改的合法快照 -> 200; 连续更正/重新发布记录完整迁移 =="
curl -s -X POST "$BASE2/migration/restore" -H "$ORG" -H "$CT" \
  --data-binary @"$SNAP" | j "{'ok': d['ok'], 'serial': d['serial'], 'snapshots': d['counts']['feedback_snapshots'], 'corrections': d['counts']['review_corrections']}"

echo "== 10. 恢复后仅当前有效码可读取并提异议; 旧码统一 404; 历史仍供会务方追溯 =="
echo -n "     GET 旧码 CODE_OLD -> HTTP "
curl -s -o /dev/null -w '%{http_code}\n' "$BASE2/feedback-snapshots/$CODE_OLD"
echo -n "     GET 新码 CODE_NEW -> HTTP 200 "
curl -s "$BASE2/feedback-snapshots/$CODE_NEW" | j '"paper_id=" + d["paper_id"]'
echo -n "     旧码提交异议 POST /feedback-objections -> HTTP "
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE2/feedback-objections" -H "$CT" \
  -d "{\"access_code\": \"$CODE_OLD\", \"label\": 1, \"reason\": \"复活旧码提交异议应被拒绝\"}"
echo -n "     新码提交异议 -> HTTP 200 "
curl -s -X POST "$BASE2/feedback-objections" -H "$CT" \
  -d "{\"access_code\": \"$CODE_NEW\", \"label\": 1, \"reason\": \"评语一仍有疑点\"}" \
  | j '"query_token=" + d["query_token"]'
echo "     会务方追溯全部版本 (含已失效旧版及其访问码):"
curl -s "$BASE2/papers/$P1/feedback-snapshots" -H "$ORG" \
  | j '[[s["version"], s["serial"], s["active"]] for s in d["snapshots"]]'

echo "== 附: 重复恢复 -> 409; 无会务方密钥恢复 -> 401 (既有约定不变) =="
curl -s -o /dev/null -w '     重复恢复        -> HTTP %{http_code}\n' -X POST "$BASE2/migration/restore" \
  -H "$ORG" -H "$CT" --data-binary @"$SNAP"
curl -s -o /dev/null -w '     无密钥恢复      -> HTTP %{http_code}\n' -X POST "$BASE2/migration/restore" \
  -H "$CT" --data-binary @"$SNAP"
echo "== 场景演示完成: 旧失效访问码无法借快照恢复复活, 仅当前有效码可读取与提异议 =="
