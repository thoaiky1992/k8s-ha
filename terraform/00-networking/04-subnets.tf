resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/19"
  availability_zone = var.availability_zone_1

  tags = {
    "Name"                                             = "${var.env}-private-${var.availability_zone_1}"
    "kubernetes.io/role/internal-elb"                  = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.32.0/19"
  availability_zone = var.availability_zone_2

  tags = {
    "Name"                                             = "${var.env}-private-${var.availability_zone_2}"
    "kubernetes.io/role/internal-elb"                  = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}

resource "aws_subnet" "private_subnet_3" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.64.0/19"
  availability_zone = var.availability_zone_3

  tags = {
    "Name"                                             = "${var.env}-private-${var.availability_zone_3}"
    "kubernetes.io/role/internal-elb"                  = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}

resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.96.0/19"
  availability_zone       = var.availability_zone_1
  map_public_ip_on_launch = true

  tags = {
    "Name"                                             = "${var.env}-public-${var.availability_zone_1}"
    "kubernetes.io/role/elb"                           = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.128.0/19"
  availability_zone       = var.availability_zone_2
  map_public_ip_on_launch = true

  tags = {
    "Name"                                             = "${var.env}-public-${var.availability_zone_2}"
    "kubernetes.io/role/elb"                           = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}

resource "aws_subnet" "public_subnet_3" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.160.0/19"
  availability_zone       = var.availability_zone_3
  map_public_ip_on_launch = true

  tags = {
    "Name"                                             = "${var.env}-public-${var.availability_zone_3}"
    "kubernetes.io/role/elb"                           = "1"
    "kubernetes.io/cluster/${var.env}-${var.eks_name}" = "owned"
  }
}
