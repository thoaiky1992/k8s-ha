#!/bin/bash

# Lấy context hiện tại hoặc dùng context từ biến môi trường nếu có
CONTEXT_ARG=""
if [ -n "$KUBE_CONTEXT" ]; then
    CONTEXT_ARG="--context $KUBE_CONTEXT"
    echo "Đang sử dụng KUBE_CONTEXT: $KUBE_CONTEXT"
fi

echo "Đang quét các Persistent Volume ở trạng thái Released..."

# Lấy danh sách tên các PV có status là Released
RELEASED_PVS=$(kubectl $CONTEXT_ARG get pv --no-headers | awk '$5 == "Released" {print $1}')

# Kiểm tra xem có PV nào ở trạng thái Released không
if [ -z "$RELEASED_PVS" ]; then
    echo "Tuyệt vời! Không tìm thấy PV nào ở trạng thái Released."
    exit 0
fi

echo -e "\nCác PV sau đây đang ở trạng thái Released và sẽ bị XÓA:"
echo "$RELEASED_PVS"
echo "----------------------------------------"

# Hỏi xác nhận trước khi xóa
read -p "Bạn có chắc chắn muốn xóa các PV này không? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Đang tiến hành xóa..."
    for pv in $RELEASED_PVS; do
        echo "Đang xóa PV: $pv"
        kubectl $CONTEXT_ARG delete pv "$pv"
    done
    echo "Hoàn tất! Các PV Released đã được dọn dẹp."
else
    echo "Đã hủy thao tác. Không có PV nào bị xóa."
fi