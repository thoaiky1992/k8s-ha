# Tầng Database: AWS RDS PostgreSQL cho Kafka Connect

Tầng này tạo hai cụm PostgreSQL Multi-AZ, cùng dùng một user master và một mật khẩu:

- **RDS instance** (`02-rds.tf`): một primary và một standby đồng bộ ở AZ khác.
- **Multi-AZ DB cluster** (`03.rds-multi-cluster.tf`): một writer và hai reader, mỗi cái ở một AZ khác.

Cả hai nằm trong private subnet của `00-networking`, không có public endpoint, và đều dùng parameter group bật `wal_level = logical` để Debezium đọc được WAL.

Tầng này phải apply sau `00-networking`. Nó không phụ thuộc `01.kubernetes`, nhưng Kafka Connect (trong cụm EKS) phải truy cập được subnet của RDS.

## Tài nguyên được tạo

| File | Tài nguyên | Vai trò |
| --- | --- | --- |
| `03.rds-multi-cluster.tf` | `random_string.db_master_password` | Sinh mật khẩu master 32 ký tự, dùng chung cho instance và cluster. |
| `04.ssm-master-password.tf` | `aws_ssm_parameter.db_master_password` | Lưu mật khẩu dạng `SecureString` tại `/<env>/<db_identifier>/master-password`. |
| `03.rds-multi-cluster.tf` | `aws_rds_cluster_parameter_group.kafka_connect` | Parameter group cấp cluster, đặt `rds.logical_replication = 1`. |
| `03.rds-multi-cluster.tf` | `aws_rds_cluster.multi_az` | Multi-AZ DB cluster PostgreSQL, storage gp3. |
| `02-rds.tf` | `aws_db_subnet_group.this` | Gom 3 private subnet, dùng chung cho instance và cluster. |
| `02-rds.tf` | `aws_security_group.rds` | Chỉ cho phép TCP 5432 từ CIDR của 3 private subnet, dùng chung cho instance và cluster. |
| `02-rds.tf` | `aws_db_parameter_group.kafka_connect` | Parameter group cấp instance, đặt `rds.logical_replication = 1`. |
| `02-rds.tf` | `aws_db_instance.this` | PostgreSQL Multi-AZ instance, mã hóa, không public. |
| `outputs.tf` | `values.rds`, `values.rds_cluster` | Endpoint, port, tên database, user và tên SSM parameter chứa mật khẩu. |

Tên thật của tài nguyên là `<env>-<db_identifier>`, ví dụ `dev-kafka-source` (instance) và `dev-kafka-source-cluster` (cluster).

## Mật khẩu

Mật khẩu được sinh bởi `random_string` và lưu vào SSM Parameter Store. Cả `aws_db_instance` (`password`) lẫn `aws_rds_cluster` (`master_password`) đều nhận giá trị này.

- Ký tự được phép: chữ, số và `!#$%&*()-_=+[]{}<>:?`. RDS không cho phép `/`, `"`, `@` và khoảng trắng trong mật khẩu master.
- Đọc mật khẩu khi cần (cần quyền `ssm:GetParameter` và `kms:Decrypt` với khóa mặc định của SSM):

```shell
aws ssm get-parameter --region ap-southeast-1 \
  --name "/dev/kafka-source/master-password" \
  --with-decryption --query Parameter.Value --output text
```

- Mật khẩu vẫn nằm trong Terraform state, vì `password` và `master_password` nhận giá trị plaintext. State nằm trên S3 có mã hóa và khóa bằng `use_lockfile`, nên giữ quyền đọc bucket ở mức tối thiểu.

**Xoay mật khẩu**: dùng `-replace` cho `random_string`. Terraform sẽ cập nhật mật khẩu của instance, cluster và giá trị SSM trong cùng một lần apply:

```shell
terraform -chdir=terraform/database apply -var-file=terraform.tfvars \
  -replace=random_string.db_master_password
```

Sau khi xoay, mọi nơi đang giữ mật khẩu cũ (Secret của Kafka Connect, các phiên `psql` đã lưu) phải cập nhật lại.

## Cấu hình quan trọng

| Cấu hình | Giá trị | Lý do |
| --- | --- | --- |
| `multi_az` (instance) | `true` | RDS tạo một standby đồng bộ ở AZ khác. Khi primary lỗi, RDS failover tự động và endpoint không đổi. Standby không phục vụ đọc. |
| Multi-AZ DB cluster | `db_cluster_instance_class` có giá trị, không có `cluster_members` | Đây là cách tạo Multi-AZ DB cluster (không phải Aurora). Cluster có một writer và hai reader, mỗi cái ở một AZ. |
| `db_cluster_instance_class` | `db.m6gd.large` | Chỉ các class hỗ trợ cluster mới dùng được. `db.m6i.large` dùng được cho instance nhưng không dùng được cho cluster. |
| `storage_type` (cluster) | `gp3` | Multi-AZ DB cluster hỗ trợ gp3. `allocated_storage` là dung lượng cho mỗi instance trong cluster. |
| `rds.logical_replication` | `1` | Đặt `wal_level = logical`. Debezium cần mức này để đọc WAL qua `pgoutput`. Đây là tham số **static**: chỉ áp dụng khi tạo mới hoặc sau khi reboot. |
| `engine_version` | `16.15` | Phiên bản PostgreSQL đầy đủ, khớp với `db_parameter_group_family = postgres16`. Đã kiểm tra là có sẵn trong `ap-southeast-1` cho cả instance và cluster. |
| `publicly_accessible` | `false` | Endpoint chỉ truy cập được từ trong VPC. |
| `storage_encrypted` | `true` | Mã hóa at rest bằng KMS mặc định của RDS. |
| `max_allocated_storage` (instance) | `500` | Trần để RDS tự mở rộng gp3. Storage chỉ tăng, không giảm. |
| `backup_retention_period` | `7` | Giữ 7 ngày automated backup (PITR). |
| `deletion_protection` | `true` | Chặn `terraform destroy` cho tới khi tắt cờ này. |
| `skip_final_snapshot` | `false` | Khi xóa, RDS tạo snapshot cuối (`<env>-<db_identifier>-final` và `-cluster-final`). |
| Security group | TCP 5432 từ private subnet | Pod Kafka Connect dùng IP của private subnet (VPC CNI), nên không cần mở cho cả VPC. |

### Parameter group và Debezium

Debezium đọc thay đổi qua logical replication, nên cần ba điều kiện ở phía PostgreSQL:

1. `wal_level = logical`: đặt bằng `rds.logical_replication = 1`. Với cluster phải dùng **cluster parameter group** (`aws_rds_cluster_parameter_group`), không dùng DB parameter group của instance.
2. Một user có role `rds_replication` (xem [../../kafka-cluster/README.md](../../kafka-cluster/README.md), mục 3c).
3. Một replication slot và publication, do connector tạo khi khởi động.

Các tham số khác để nguyên mặc định RDS: `max_replication_slots = 20` và `max_wal_senders = 20`. Với một connector một slot, mặc định là đủ.

Lưu ý khi đổi parameter: `rds.logical_replication` là tham số static, nên sau khi apply cần reboot. Với instance: `aws rds reboot-db-instance`. Với cluster: `aws rds reboot-db-cluster` hoặc reboot từng instance trong cluster.

### Failover và replication slot

Multi-AZ giữ endpoint và dữ liệu đồng bộ, nhưng replication slot của Debezium (`debezium_cdc`) là trạng thái của primary. Nếu slot không được sao sang standby hoặc reader mới làm writer, sau failover connector báo lỗi slot không tồn tại. Khi đó phải xóa connector, tạo lại slot và chạy lại snapshot ban đầu. Chưa kiểm chứng hành vi này cho cả hai loại trong repo, nên cần thử trước khi đưa vào production:

- Failover instance trên dev: `aws rds reboot-db-instance --db-instance-identifier dev-kafka-source --force-failover`.
- Failover cluster trên dev: `aws rds failover-db-cluster --db-cluster-identifier dev-kafka-source-cluster`.
- Sau mỗi lần, kiểm tra connector có tiếp tục đọc WAL không (`kafka-cluster/README.md`, phần kiểm tra trạng thái).

## Điều kiện trước khi apply

- Đã apply `terraform/00-networking`, và file state của nó nằm trên S3 (`networking_state` trong tfvars).
- Có quyền AWS để tạo RDS, subnet group, security group, parameter group, SSM parameter và đọc SSM.
- Bucket S3 state đã tồn tại (dùng chung với các tầng khác).
- Provider `random` được tải khi `init` (đã khai báo trong `01-providers.tf`).

## Chạy

```shell
cp terraform/database/backend.tfvars.example terraform/database/backend.tfvars
cp terraform/database/terraform.tfvars.example terraform/database/terraform.tfvars

terraform -chdir=terraform/database init -backend-config=backend.tfvars -migrate-state
terraform -chdir=terraform/database plan -var-file=terraform.tfvars
terraform -chdir=terraform/database apply -var-file=terraform.tfvars
```

Tạo instance Multi-AZ và cluster mất khoảng 15 đến 30 phút. Cluster thường xong sau instance.

Lấy các giá trị cần cho Kafka Connect:

```shell
terraform -chdir=terraform/database output -json values | jq '{rds: .value.rds, rds_cluster: .value.rds_cluster}'
```

Các trường cần dùng:

- `rds.endpoint` hoặc `rds_cluster.writer_endpoint`: điền vào `database.hostname` trong `kafka-cluster/kafka-connector-postgres.yaml`. Chọn một nguồn CDC, không dùng cả hai.
- `port`: thường là `5432`.
- `database_name`: điền vào `database.dbname`.
- `master_password_parameter`: tên SSM parameter chứa mật khẩu user master (dùng để tạo user Debezium, không đưa vào Kafka).

## Kiểm tra sau khi apply

```shell
# Instance: Multi-AZ phải là true.
aws rds describe-db-instances --region ap-southeast-1 \
  --db-instance-identifier dev-kafka-source \
  --query 'DBInstances[0].[MultiAZ,AvailabilityZone,DBParameterGroups[0].DBParameterGroupName,DBParameterGroups[0].ParameterApplyStatus]' \
  --output text

# Cluster: phải có writer và hai reader, mỗi cái một AZ.
aws rds describe-db-clusters --region ap-southeast-1 \
  --db-cluster-identifier dev-kafka-source-cluster \
  --query 'DBClusters[0].[Status,DBClusterMembers[].[DBInstanceIdentifier,IsClusterWriter]]' \
  --output json
```

Sau đó kết nối bằng `psql` với user master (xem `kafka-cluster/README.md`, mục 3c) và chạy `SHOW wal_level;`. Kết quả phải là `logical`.

## Xóa

Tắt `db_deletion_protection` trong tfvars, apply, rồi mới `destroy`. Snapshot cuối được tạo tự động cho cả instance và cluster; xóa snapshot thủ công nếu không còn cần.

```shell
terraform -chdir=terraform/database destroy -var-file=terraform.tfvars
```

```shell
terraform init --backend-config=backend.tfvars -migrate-state

terraform plan --var-file=terraform.tfvars
terraform apply --var-file=terraform.tfvars --auto-approve

terraform destroy --auto-approve
```
