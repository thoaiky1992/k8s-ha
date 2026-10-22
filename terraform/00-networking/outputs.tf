output "values" {
  value = {
    vpc_id                 = aws_vpc.main.id
    public_subnet_ids      = [for subnet in [aws_subnet.public_subnet_1, aws_subnet.public_subnet_2, aws_subnet.public_subnet_3] : subnet.id]
    private_subnet_ids     = [for subnet in [aws_subnet.private_subnet_1, aws_subnet.private_subnet_2, aws_subnet.private_subnet_3] : subnet.id]
    nat_gateway_id         = aws_nat_gateway.nat.id
    internet_gateway_id    = aws_internet_gateway.igw.id
    route_table_private_id = aws_route_table.private.id
    route_table_public_id  = aws_route_table.public.id
  }
}
