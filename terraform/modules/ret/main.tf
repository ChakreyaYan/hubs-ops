variable "shared" { type = "map" }
terraform { backend "s3" {} }
provider "aws" { region = "${var.shared["region"]}", version = "~> 1.15" }
provider "aws" { alias = "east", region = "us-east-1", version = "~> 1.15" }
data "aws_availability_zones" "all" {}

data "terraform_remote_state" "vpc" { backend = "s3", config = { key = "vpc/terraform.tfstate", bucket = "${var.shared["state_bucket"]}", region = "${var.shared["region"]}", dynamodb_table = "${var.shared["dynamodb_table"]}", encrypt = "true" } }
data "terraform_remote_state" "base" { backend = "s3", config = { key = "base/terraform.tfstate", bucket = "${var.shared["state_bucket"]}", region = "${var.shared["region"]}", dynamodb_table = "${var.shared["dynamodb_table"]}", encrypt = "true" } }
data "terraform_remote_state" "bastion" { backend = "s3", config = { key = "bastion/terraform.tfstate", bucket = "${var.shared["state_bucket"]}", region = "${var.shared["region"]}", dynamodb_table = "${var.shared["dynamodb_table"]}", encrypt = "true" } }
data "terraform_remote_state" "hab" { backend = "s3", config = { key = "hab/terraform.tfstate", bucket = "${var.shared["state_bucket"]}", region = "${var.shared["region"]}", dynamodb_table = "${var.shared["dynamodb_table"]}", encrypt = "true" } }
data "terraform_remote_state" "ret-db" { backend = "s3", config = { key = "ret-db/terraform.tfstate", bucket = "${var.shared["state_bucket"]}", region = "${var.shared["region"]}", dynamodb_table = "${var.shared["dynamodb_table"]}", encrypt = "true" } }

data "aws_route53_zone" "reticulum-zone" {
  name = "${var.ret_domain}."
}

data "aws_acm_certificate" "ret-alb-listener-cert" {
  domain = "*.${var.ret_domain}"
  statuses = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "ret-alb-listener-public-cert" {
  domain = "${var.public_domain}"
  statuses = ["ISSUED"]
  types = ["AMAZON_ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "ret-alb-listener-cert-east" {
  provider = "aws.east"
  domain = "*.${var.ret_domain}"
  statuses = ["ISSUED"]
  most_recent = true
}

data "aws_ami" "hab-base-ami" {
  most_recent = true
  owners = ["self"]

  filter {
    name = "name"
    values = ["hab-base-*"]
  }
}

resource "aws_security_group" "ret-alb" {
  name = "${var.shared["env"]}-ret-alb"
  vpc_id = "${data.terraform_remote_state.vpc.vpc_id}"

  ingress {
    from_port = "80"
    to_port = "80"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = "443"
    to_port = "443"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "ret-alb-egress" {
  type = "egress"
  from_port = "${var.ret_http_port}"
  to_port = "${var.ret_http_port}"
  protocol = "tcp"
  security_group_id = "${aws_security_group.ret-alb.id}"
  source_security_group_id = "${aws_security_group.ret.id}"
}

resource "aws_alb" "ret-alb" {
  name = "${var.shared["env"]}-ret-alb"
  security_groups = ["${aws_security_group.ret-alb.id}"]
  subnets = ["${data.terraform_remote_state.vpc.public_subnet_ids}"]

  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "ret-alb-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_alb.ret-alb.dns_name}"
    zone_id = "${aws_alb.ret-alb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_alb_target_group" "ret-alb-group-http" {
  name = "${var.shared["env"]}-ret-alb-group-http"
  vpc_id = "${data.terraform_remote_state.vpc.vpc_id}"
  port = "${var.ret_http_port}"
  protocol = "HTTP"
  deregistration_delay = 0

  health_check {
    path = "/health"
    healthy_threshold = 2
    unhealthy_threshold = 2
    interval = 10
    timeout = 5
  }
}

resource "aws_alb_listener" "ret-ssl-alb-listener" {
  load_balancer_arn = "${aws_alb.ret-alb.arn}"
  port = 443

  protocol = "HTTPS"
  ssl_policy = "ELBSecurityPolicy-2015-05"

  certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert.arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.ret-alb-group-http.arn}"
    type = "forward"
  }
}

resource "aws_lb_listener_certificate" "ret-ssl-public-alb-listener-cert" {
  count = "${var.public_domain_enabled}"
  listener_arn = "${aws_alb_listener.ret-ssl-alb-listener.arn}"
  certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-public-cert.arn}"
}

resource "aws_alb_listener" "ret-clear-alb-listener" {
  load_balancer_arn = "${aws_alb.ret-alb.arn}"
  port = 80

  protocol = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.ret-alb-group-http.arn}"
    type = "forward"
  }
}

resource "aws_security_group" "ret" {
  name = "${var.shared["env"]}-ret"
  vpc_id = "${data.terraform_remote_state.vpc.vpc_id}"

  egress {
    from_port = "80"
    to_port = "80"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = "443"
    to_port = "443"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Reticulum HTTP
  ingress {
    from_port = "${var.ret_http_port}"
    to_port = "${var.ret_http_port}"
    protocol = "tcp"
    security_groups = ["${aws_security_group.ret-alb.id}"]
  }

  # SSH
  ingress {
    from_port = "22"
    to_port = "22"
    protocol = "tcp"
    security_groups = ["${data.terraform_remote_state.bastion.bastion_security_group_id}"]
  }

  # epmd
  ingress {
    from_port = "4369"
    to_port = "4369"
    protocol = "tcp"
    self = true
  }

  # epmd-udp
  ingress {
    from_port = "4369"
    to_port = "4369"
    protocol = "udp"
    self = true
  }

  # erlang
  ingress {
    from_port = "9000"
    to_port = "9100"
    protocol = "tcp"
    self = true
  }

  # erlang
  egress {
    from_port = "0"
    to_port = "65535"
    protocol = "tcp"
    self = true
  }

  # NTP
  egress {
    from_port = "123"
    to_port = "123"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ret" {
  name = "${var.shared["env"]}-ret"
  assume_role_policy = "${var.shared["ec2_role_policy"]}"
}

resource "aws_iam_role_policy_attachment" "bastion-base-policy" {
  role = "${aws_iam_role.ret.name}"
  policy_arn = "${data.terraform_remote_state.base.base_policy_arn}"
}

resource "aws_iam_policy" "ret-alb-register-policy" {
  name = "${var.shared["env"]}-ret-alb-register-policy"

  # Apparently these cannot be bound to resource ARNs.
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:RegisterTargets"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeTargetHealth"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DeregisterTargets"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ret-alb-register-policy" {
  role = "${aws_iam_role.ret.name}"
  policy_arn = "${aws_iam_policy.ret-alb-register-policy.arn}"
}

resource "aws_iam_instance_profile" "ret" {
  name = "${var.shared["env"]}-ret"
  role = "${aws_iam_role.ret.id}"
}

resource "aws_launch_configuration" "ret" {
  image_id = "${data.aws_ami.hab-base-ami.id}"
  instance_type = "${var.ret_instance_type}"
  security_groups = [
    "${aws_security_group.ret.id}",
    "${data.terraform_remote_state.ret-db.ret_db_consumer_security_group_id}",
    "${data.terraform_remote_state.hab.hab_ring_security_group_id}",
  ]
  key_name = "${data.terraform_remote_state.base.mr_ssh_key_id}"
  iam_instance_profile = "${aws_iam_instance_profile.ret.id}"
  associate_public_ip_address = false
  lifecycle { create_before_destroy = true }
  root_block_device { volume_size = 128 }
  user_data = <<EOF
#!/usr/bin/env bash
while ! nc -z localhost 9632 ; do sleep 1; done
systemctl restart systemd-sysctl.service

sudo mkdir -p /hab/user/reticulum/config

sudo cat > /hab/user/reticulum/config/user.toml << EOTOML
[habitat]
ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"

[pages]
page_origin = "https://s3-${var.shared["region"]}.amazonaws.com/${data.terraform_remote_state.base.assets_bucket_id}/pages/live"
EOTOML

sudo /usr/bin/hab svc load mozillareality/reticulum --strategy ${var.reticulum_restart_strategy} --url https://bldr.habitat.sh --channel ${var.reticulum_channel}
sudo /usr/bin/hab svc load mozillareality/dd-agent --strategy at-once --url https://bldr.habitat.sh --channel stable
EOF
}

resource "aws_autoscaling_group" "ret" {
  name = "${var.shared["env"]}-ret"
  launch_configuration = "${aws_launch_configuration.ret.id}"
  availability_zones = ["${data.aws_availability_zones.all.names}"]
  vpc_zone_identifier = ["${data.terraform_remote_state.vpc.private_subnet_ids}"]

  min_size = "${var.min_ret_servers}"
  max_size = "${var.max_ret_servers}"

  target_group_arns = ["${aws_alb_target_group.ret-alb-group-http.arn}"]

  lifecycle { create_before_destroy = true }
  tag { key = "env", value = "${var.shared["env"]}", propagate_at_launch = true }
  tag { key = "host-type", value = "${var.shared["env"]}-ret", propagate_at_launch = true }
  tag { key = "hab-ring", value = "${var.shared["env"]}", propagate_at_launch = true }
}

resource "aws_cloudfront_distribution" "ret-assets" {
  enabled = true

  origin {
    origin_id = "reticulum-${var.shared["env"]}-assets"
    domain_name = "${data.terraform_remote_state.base.assets_bucket_domain_name}"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = ["assets-${var.shared["env"]}.${var.ret_domain}"]

  default_cache_behavior {
    compress = true
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "reticulum-${var.shared["env"]}-assets"

    forwarded_values {
      query_string = true
      headers = ["Origin", "Content-Type"]
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "https-only"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 3600
  }

  custom_error_response {
    error_code = 403
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 404
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 500
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 502
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 503
    error_caching_min_ttl = 0
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert-east.arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }
}

resource "aws_route53_record" "ret-assets-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "assets-${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_cloudfront_distribution.ret-assets.domain_name}"
    zone_id = "${aws_cloudfront_distribution.ret-assets.hosted_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_alb" "ret-smoke-alb" {
  name = "${var.shared["env"]}-ret-smoke-alb"
  security_groups = ["${aws_security_group.ret-alb.id}"]
  subnets = ["${data.terraform_remote_state.vpc.public_subnet_ids}"]

  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "ret-smoke-alb-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "smoke-${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_alb.ret-smoke-alb.dns_name}"
    zone_id = "${aws_alb.ret-smoke-alb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_alb_target_group" "ret-smoke-alb-group-http" {
  name = "${var.shared["env"]}-ret-smoke-alb-group-http"
  vpc_id = "${data.terraform_remote_state.vpc.vpc_id}"
  port = "${var.ret_http_port}"
  protocol = "HTTP"
  deregistration_delay = 0

  health_check {
    path = "/health"
    healthy_threshold = 2
    unhealthy_threshold = 2
    interval = 10
    timeout = 5
  }
}

resource "aws_alb_listener" "ret-smoke-ssl-alb-listener" {
  load_balancer_arn = "${aws_alb.ret-smoke-alb.arn}"
  port = 443

  protocol = "HTTPS"
  ssl_policy = "ELBSecurityPolicy-2015-05"

  certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert.arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.ret-smoke-alb-group-http.arn}"
    type = "forward"
  }
}

resource "aws_alb_listener" "ret-smoke-clear-alb-listener" {
  load_balancer_arn = "${aws_alb.ret-smoke-alb.arn}"
  port = 80

  protocol = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.ret-smoke-alb-group-http.arn}"
    type = "forward"
  }
}

resource "aws_launch_configuration" "ret-smoke" {
  image_id = "${data.aws_ami.hab-base-ami.id}"
  instance_type = "${var.ret_instance_type}"
  security_groups = [
    "${aws_security_group.ret.id}",
    "${data.terraform_remote_state.ret-db.ret_db_consumer_security_group_id}",
    "${data.terraform_remote_state.hab.hab_ring_security_group_id}",
  ]
  key_name = "${data.terraform_remote_state.base.mr_ssh_key_id}"
  iam_instance_profile = "${aws_iam_instance_profile.ret.id}"
  associate_public_ip_address = false
  lifecycle { create_before_destroy = true }
  root_block_device { volume_size = 128 }
  user_data = <<EOF
#!/usr/bin/env bash
while ! nc -z localhost 9632 ; do sleep 1; done
systemctl restart systemd-sysctl.service

sudo mkdir -p /hab/user/reticulum/config

sudo cat > /hab/user/reticulum/config/user.toml << EOTOML
[phx]
url_host_prefix = "smoke-"
static_url_host_prefix = "smoke-"

[pages]
page_origin = "https://s3-${var.shared["region"]}.amazonaws.com/${data.terraform_remote_state.base.assets_bucket_id}/pages/latest"

[habitat]
ip = "$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
EOTOML

sudo /usr/bin/hab svc load mozillareality/reticulum --strategy at-once --url https://bldr.habitat.sh --channel unstable
sudo /usr/bin/hab svc load mozillareality/dd-agent --strategy at-once --url https://bldr.habitat.sh --channel stable
EOF
}

resource "aws_autoscaling_group" "ret-smoke" {
  name = "${var.shared["env"]}-ret-smoke"
  launch_configuration = "${aws_launch_configuration.ret-smoke.id}"
  availability_zones = ["${data.aws_availability_zones.all.names}"]
  vpc_zone_identifier = ["${data.terraform_remote_state.vpc.private_subnet_ids}"]

  min_size = "1"
  max_size = "1"

  target_group_arns = ["${aws_alb_target_group.ret-smoke-alb-group-http.arn}"]

  lifecycle { create_before_destroy = true }
  tag { key = "env", value = "${var.shared["env"]}", propagate_at_launch = true }
  tag { key = "host-type", value = "${var.shared["env"]}-ret", propagate_at_launch = true }
  tag { key = "hab-ring", value = "${var.shared["env"]}", propagate_at_launch = true }
  tag { key = "smoke", value = "true", propagate_at_launch = true }
}

resource "aws_cloudfront_distribution" "ret-assets-smoke" {
  enabled = true

  origin {
    origin_id = "reticulum-${var.shared["env"]}-assets-smoke"
    domain_name = "${data.terraform_remote_state.base.assets_bucket_domain_name}"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = ["smoke-assets-${var.shared["env"]}.${var.ret_domain}"]

  default_cache_behavior {
    compress = true
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "reticulum-${var.shared["env"]}-assets-smoke"

    forwarded_values {
      query_string = true
      headers = ["Origin", "Content-Type"]
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "https-only"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 3600
  }

  custom_error_response {
    error_code = 403
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 404
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 500
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 502
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 503
    error_caching_min_ttl = 0
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert-east.arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }
}

resource "aws_route53_record" "ret-assets-smoke-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "smoke-assets-${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_cloudfront_distribution.ret-assets-smoke.domain_name}"
    zone_id = "${aws_cloudfront_distribution.ret-assets-smoke.hosted_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_cloudfront_distribution" "ret-asset-bundles" {
  enabled = true

  origin {
    origin_id = "reticulum-${var.shared["env"]}-asset-bundles"
    domain_name = "${data.terraform_remote_state.base.asset_bundles_bucket_domain_name}"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = ["asset-bundles-${var.shared["env"]}.${var.ret_domain}"]

  default_cache_behavior {
    compress = true
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "reticulum-${var.shared["env"]}-asset-bundles"

    forwarded_values {
      query_string = true
      headers = ["Origin"]
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "https-only"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 3600
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert-east.arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }
}

resource "aws_route53_record" "ret-assets-bundles-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "asset-bundles-${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_cloudfront_distribution.ret-asset-bundles.domain_name}"
    zone_id = "${aws_cloudfront_distribution.ret-asset-bundles.hosted_zone_id}"
    evaluate_target_health = false
  }
}

resource "aws_cloudfront_distribution" "timecheck" {
  enabled = true

  origin {
    origin_id = "${var.shared["env"]}-timecheck"
    domain_name = "${data.terraform_remote_state.base.timecheck_bucket_website_endpoint}"

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_ssl_protocols = ["SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2"]
      origin_protocol_policy = "http-only"
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = ["timecheck-${var.shared["env"]}.${var.ret_domain}"]

  default_cache_behavior {
    compress = true
    allowed_methods = ["HEAD", "GET"]
    cached_methods = ["HEAD", "GET"]
    target_origin_id = "${var.shared["env"]}-timecheck"

    forwarded_values {
      query_string = true
      headers = ["Origin"]
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "https-only"
    min_ttl = 0
    default_ttl = 0
    max_ttl = 0
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.ret-alb-listener-cert-east.arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }
}

resource "aws_route53_record" "timecheck-dns" {
  zone_id = "${data.aws_route53_zone.reticulum-zone.zone_id}"
  name = "timecheck-${var.shared["env"]}.${data.aws_route53_zone.reticulum-zone.name}"
  type = "A"

  alias {
    name = "${aws_cloudfront_distribution.timecheck.domain_name}"
    zone_id = "${aws_cloudfront_distribution.timecheck.hosted_zone_id}"
    evaluate_target_health = false
  }
}
