output "values" {
  value = {
    rds = {
      identifier                = aws_db_instance.this.identifier
      endpoint                  = aws_db_instance.this.address
      port                      = aws_db_instance.this.port
      database_name             = aws_db_instance.this.db_name
      master_username           = aws_db_instance.this.username
      master_password_parameter = aws_ssm_parameter.db_master_password.name
      security_group_id         = aws_security_group.rds.id
      parameter_group           = aws_db_parameter_group.kafka_connect.name
      multi_az                  = aws_db_instance.this.multi_az
      availability_zone         = aws_db_instance.this.availability_zone
    }
    # rds_cluster = {
    #   cluster_identifier        = aws_rds_cluster.multi_az.cluster_identifier
    #   writer_endpoint           = aws_rds_cluster.multi_az.endpoint
    #   reader_endpoint           = aws_rds_cluster.multi_az.reader_endpoint
    #   port                      = aws_rds_cluster.multi_az.port
    #   database_name             = aws_rds_cluster.multi_az.database_name
    #   master_username           = aws_rds_cluster.multi_az.master_username
    #   master_password_parameter = aws_ssm_parameter.db_master_password.name
    #   parameter_group           = aws_rds_cluster_parameter_group.kafka_connect.name
    # }
  }
}
