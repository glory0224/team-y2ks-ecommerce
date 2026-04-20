# Cloudflare 연동을 위한 인프라 코드

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "main" {
  name = var.domain_name
}

# 1. 봇 방어 규칙 (WAF)
# 비정상적인 트래픽(매크로)이나 특정 악성 국가/IP 대역 차단
resource "cloudflare_ruleset" "bot_protection" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "Y2KS Bot Protection"
  description = "Block malicious bots and macros"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    action = "block"
    expression = "(cf.client.bot) or (http.request.uri.path contains \"/api/claim\" and http.request.method == \"POST\" and not ip.src in {1.1.1.1})" # 예시: 승인된 IP 외의 봇 트래픽 차단
    description = "Block bad bots from claiming coupons"
    enabled = true
  }
}

# 2. 캐싱 규칙 (CDN)
# 정적 리소스(이미지, CSS 등)를 엣지에 강제 캐싱하여 파드 부하 경감
resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "Y2KS Static Caching"
  description = "Cache static assets to reduce AWS Egress and Pod load"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules {
    action = "set_cache_settings"
    expression = "(http.request.uri.path.extension in {\"jpg\" \"jpeg\" \"png\" \"gif\" \"css\" \"js\"})"
    action_parameters {
      cache = true
      edge_ttl {
        mode    = "override_origin"
        default = 86400 # 24시간 캐싱
      }
    }
    description = "Cache static files"
    enabled = true
  }
}
