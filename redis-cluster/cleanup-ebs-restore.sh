#!/usr/bin/env bash
# Dọn bộ snapshot và EBS volume cũ sau khi đã xác minh restore Redis Cluster.
# Mặc định chỉ kiểm tra và in kế hoạch; --execute mới xóa tài nguyên.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-ebs-restore.sh \
  --snapshot-map /path/to/volumes.tsv \
  --replacement-map /path/to/replacement-volumes.tsv \
  --context EKS_CONTEXT \
  --region AWS_REGION \
  --account-id AWS_ACCOUNT_ID \
  [--old-volumes] [--snapshots] [--execute]

Chọn ít nhất một trong --old-volumes và --snapshots. Không có --execute: chỉ xem trước.
--old-volumes xóa 12 EBS volume cũ và các PV Released tương ứng.
--snapshots xóa 12 snapshot trong volumes.tsv. Nếu chọn cả hai, snapshot bị xóa sau cùng.
EOF
}

die() { echo "Lỗi: $*" >&2; exit 1; }

snapshot_map=''
replacement_map=''
kube_context=''
aws_region=''
expected_account=''
delete_old_volumes=false
delete_snapshots=false
execute=false

while (($#)); do
  case "$1" in
    --snapshot-map|--replacement-map|--context|--region|--account-id)
      (($# >= 2)) || die "Thiếu giá trị cho $1"
      case "$1" in
        --snapshot-map) snapshot_map="$2" ;;
        --replacement-map) replacement_map="$2" ;;
        --context) kube_context="$2" ;;
        --region) aws_region="$2" ;;
        --account-id) expected_account="$2" ;;
      esac
      shift 2
      ;;
    --old-volumes) delete_old_volumes=true; shift ;;
    --snapshots) delete_snapshots=true; shift ;;
    --execute) execute=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Tham số không hợp lệ: $1" ;;
  esac
done

[[ "$delete_old_volumes" == true || "$delete_snapshots" == true ]] || { usage >&2; die 'Chưa chọn tài nguyên cần dọn'; }
[[ -f "$snapshot_map" && -f "$replacement_map" ]] || die 'Thiếu một trong hai file bản đồ'
[[ "$snapshot_map" != "$replacement_map" ]] || die '--snapshot-map phải là volumes.tsv (8 cột), khác --replacement-map (5 cột)'
[[ -n "$kube_context" && -n "$aws_region" ]] || die 'Phải chỉ định --context và --region'
[[ "$expected_account" =~ ^[0-9]{12}$ ]] || die 'Phải chỉ định --account-id gồm 12 chữ số'
for command in aws kubectl jq awk; do
  command -v "$command" >/dev/null || die "Thiếu $command"
done

check_map() {
  local file="$1" fields="$2"
  awk -F '\t' -v fields="$fields" '
    NF != fields && !bad { printf "Dòng %d có %d cột; cần %d\n", NR, NF, fields > "/dev/stderr"; bad = 1 }
    END {
      if (NR != 12) printf "Có %d dòng; cần 12\n", NR > "/dev/stderr"
      if (bad || NR != 12) exit 1
    }
  ' "$file" || die "Bản đồ không hợp lệ: $file"
}
check_map "$snapshot_map" 8
check_map "$replacement_map" 5

declare -A snapshot_by_pvc=() old_pv_by_pvc=() old_vol_by_pvc=()
declare -A new_pv_by_pvc=() new_vol_by_pvc=()
declare -A seen_snapshot=() seen_old_vol=() seen_new_vol=()

while IFS=$'\t' read -r pod kind pvc old_pv old_vol az size_gib snapshot; do
  [[ "$pod" =~ ^redis-cluster-(leader|follower)-[0-2]$ ]] || die "Pod không hợp lệ: $pod"
  case "$kind" in
    data) [[ "$pvc" == "${pod%-*}-${pod}" ]] || die "PVC dữ liệu không khớp: $pvc" ;;
    nodeconf) [[ "$pvc" == "node-conf-$pod" ]] || die "PVC node-conf không khớp: $pvc" ;;
    *) die "Loại PVC không hợp lệ: $kind" ;;
  esac
  [[ "$old_pv" =~ ^[a-z0-9.-]+$ && "$old_vol" =~ ^vol-[0-9a-f]+$ ]] || die "PV/volume không hợp lệ: $pvc"
  [[ "$snapshot" =~ ^snap-[0-9a-f]+$ && "$az" =~ ^[a-z0-9-]+$ && "$size_gib" =~ ^[0-9]+$ ]] || die "Snapshot/AZ/size không hợp lệ: $pvc"
  [[ -z "${snapshot_by_pvc[$pvc]:-}" && -z "${seen_snapshot[$snapshot]:-}" && -z "${seen_old_vol[$old_vol]:-}" ]] || die "Dòng trùng trong $snapshot_map: $pvc"
  snapshot_by_pvc["$pvc"]="$snapshot"
  old_pv_by_pvc["$pvc"]="$old_pv"
  old_vol_by_pvc["$pvc"]="$old_vol"
  seen_snapshot["$snapshot"]=1
  seen_old_vol["$old_vol"]=1
done < "$snapshot_map"

while IFS=$'\t' read -r pvc old_pv old_vol new_pv new_vol; do
  [[ -n "${snapshot_by_pvc[$pvc]:-}" ]] || die "PVC không có trong snapshot map: $pvc"
  [[ "$old_pv" == "${old_pv_by_pvc[$pvc]}" && "$old_vol" == "${old_vol_by_pvc[$pvc]}" ]] || die "PV/volume cũ không khớp: $pvc"
  [[ "$new_pv" =~ ^[a-z0-9.-]+$ && "$new_vol" =~ ^vol-[0-9a-f]+$ ]] || die "PV/volume mới không hợp lệ: $pvc"
  [[ "$new_vol" != "$old_vol" && -z "${new_pv_by_pvc[$pvc]:-}" && -z "${seen_new_vol[$new_vol]:-}" ]] || die "Volume mới trùng hoặc bằng volume cũ: $pvc"
  new_pv_by_pvc["$pvc"]="$new_pv"
  new_vol_by_pvc["$pvc"]="$new_vol"
  seen_new_vol["$new_vol"]=1
done < "$replacement_map"
[[ ${#new_pv_by_pvc[@]} -eq 12 ]] || die 'Hai bản đồ không có đủ 12 PVC khớp nhau'

actual_account="$(aws sts get-caller-identity --query Account --output text)"
[[ "$actual_account" == "$expected_account" ]] || die "AWS account hiện tại $actual_account khác $expected_account"
kubectl --context "$kube_context" -n redis-cluster get rediscluster redis-cluster -o name >/dev/null
echo "AWS account: $actual_account | region: $aws_region | context: $kube_context"

# Chỉ dọn sau khi cluster mới đã lên và topology hoạt động.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="$kube_context" NAMESPACE=redis-cluster bash "$script_dir/check-cluster.sh"

validate_replacement() {
  local pvc="$1" current_pvc current_pv new_volume_json
  current_pvc="$(kubectl --context "$kube_context" -n redis-cluster get pvc "$pvc" -o json)"
  jq -e --arg pv "${new_pv_by_pvc[$pvc]}" \
    '.status.phase == "Bound" and .spec.volumeName == $pv' <<<"$current_pvc" >/dev/null \
    || die "PVC $pvc chưa Bound vào PV mới"
  current_pv="$(kubectl --context "$kube_context" get pv "${new_pv_by_pvc[$pvc]}" -o json)"
  jq -e --arg vol "${new_vol_by_pvc[$pvc]}" --arg pvc "$pvc" \
    '.status.phase == "Bound" and .spec.csi.volumeHandle == $vol and .spec.claimRef.name == $pvc and .spec.claimRef.namespace == "redis-cluster"' \
    <<<"$current_pv" >/dev/null || die "PV mới của $pvc không trỏ tới volume dự kiến"
  new_volume_json="$(aws ec2 describe-volumes --region "$aws_region" --volume-ids "${new_vol_by_pvc[$pvc]}" --output json)"
  jq -e --arg vol "${new_vol_by_pvc[$pvc]}" --arg snap "${snapshot_by_pvc[$pvc]}" \
    '.Volumes | length == 1 and .[0].VolumeId == $vol and .[0].SnapshotId == $snap' \
    <<<"$new_volume_json" >/dev/null || die "Volume mới của $pvc không được tạo từ snapshot trong volumes.tsv"
}

validate_old_volume() {
  local pvc="$1" old_pv_json volume_json pv_refs
  old_pv_json="$(kubectl --context "$kube_context" get pv "${old_pv_by_pvc[$pvc]}" -o json)"
  jq -e --arg vol "${old_vol_by_pvc[$pvc]}" --arg pvc "$pvc" \
    '.status.phase == "Released" and .spec.persistentVolumeReclaimPolicy == "Retain" and .spec.csi.volumeHandle == $vol and .spec.claimRef.name == $pvc and .spec.claimRef.namespace == "redis-cluster"' \
    <<<"$old_pv_json" >/dev/null || die "PV cũ của $pvc không ở trạng thái Released/Retain"
  pv_refs="$(kubectl --context "$kube_context" get pv -o json)"
  jq -e --arg vol "${old_vol_by_pvc[$pvc]}" --arg pv "${old_pv_by_pvc[$pvc]}" \
    '[.items[] | select(.spec.csi.volumeHandle == $vol) | .metadata.name] == [$pv]' \
    <<<"$pv_refs" >/dev/null || die "Volume cũ của $pvc còn được PV khác tham chiếu"
  volume_json="$(aws ec2 describe-volumes --region "$aws_region" --volume-ids "${old_vol_by_pvc[$pvc]}" --output json)"
  jq -e --arg vol "${old_vol_by_pvc[$pvc]}" \
    '.Volumes | length == 1 and .[0].VolumeId == $vol and .[0].State == "available" and (.[0].Attachments | length) == 0' \
    <<<"$volume_json" >/dev/null || die "EBS volume cũ của $pvc còn đang được sử dụng"
}

backup_set=''
validate_snapshot() {
  local pvc="$1" snapshot_json snapshot_set
  snapshot_json="$(aws ec2 describe-snapshots --region "$aws_region" --snapshot-ids "${snapshot_by_pvc[$pvc]}" --output json)"
  jq -e --arg id "${snapshot_by_pvc[$pvc]}" --arg vol "${old_vol_by_pvc[$pvc]}" --arg pvc "$pvc" \
    '.Snapshots | length == 1 and .[0].SnapshotId == $id and .[0].VolumeId == $vol and .[0].State == "completed" and ([.[0].Tags[]? | select(.Key == "PVC" and .Value == $pvc)] | length) == 1' \
    <<<"$snapshot_json" >/dev/null || die "Snapshot của $pvc không khớp ID, volume nguồn, tag hoặc trạng thái"
  snapshot_set="$(jq -r '.Snapshots[0].Tags[]? | select(.Key == "BackupSet") | .Value' <<<"$snapshot_json")"
  [[ -n "$snapshot_set" ]] || die "Snapshot của $pvc thiếu tag BackupSet"
  if [[ -z "$backup_set" ]]; then backup_set="$snapshot_set"; fi
  [[ "$snapshot_set" == "$backup_set" ]] || die "Snapshot của $pvc thuộc bộ khác: $snapshot_set"
}

# Kiểm tra TOÀN BỘ tài nguyên trước khi xóa cái đầu tiên.
while IFS=$'\t' read -r pvc _old_pv _old_vol _new_pv _new_vol; do
  validate_replacement "$pvc"
  if [[ "$delete_old_volumes" == true ]]; then validate_old_volume "$pvc"; fi
  if [[ "$delete_snapshots" == true ]]; then validate_snapshot "$pvc"; fi
done < "$replacement_map"

echo "Đã kiểm tra 12 PVC mới. BackupSet=${backup_set:-không chọn snapshot}."
if [[ "$delete_old_volumes" == true ]]; then
  echo 'Volume cũ và PV Released sẽ bị dọn:'
  cut -f1-3 "$replacement_map"
fi
if [[ "$delete_snapshots" == true ]]; then
  echo 'Snapshot sẽ bị dọn:'
  cut -f3,8 "$snapshot_map"
fi
if [[ "$execute" != true ]]; then
  echo 'DRY RUN: không có tài nguyên nào bị xóa. Thêm --execute sau khi đã kiểm tra dữ liệu và bản đồ.'
  exit 0
fi

if [[ "$delete_old_volumes" == true ]]; then
  while IFS=$'\t' read -r pvc old_pv old_vol _new_pv _new_vol; do
    validate_replacement "$pvc"
    validate_old_volume "$pvc"
    aws ec2 delete-volume --region "$aws_region" --volume-id "$old_vol"
    kubectl --context "$kube_context" delete pv "$old_pv" --wait=true
    echo "Đã dọn volume cũ $old_vol và PV $old_pv"
  done < "$replacement_map"
fi

if [[ "$delete_snapshots" == true ]]; then
  while IFS=$'\t' read -r _pod _kind pvc _old_pv _old_vol _az _size_gib snapshot; do
    validate_replacement "$pvc"
    validate_snapshot "$pvc"
    aws ec2 delete-snapshot --region "$aws_region" --snapshot-id "$snapshot"
    echo "Đã dọn snapshot $snapshot ($pvc)"
  done < "$snapshot_map"
fi
