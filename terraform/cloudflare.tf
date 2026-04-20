# Cloudflare Provider 설정
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

# Cloudflare Zone 설정 (도메인)
resource "cloudflare_zone" "y2ks_site" {
  account_id = "your_account_id_here" # 팀장님의 Cloudflare 계정 ID로 교체 필요
  zone       = var.domain_name
}

# 기본 WAF 규칙 설정 (SQL Injection 방지 등)
resource "cloudflare_filter" "sql_injection" {
  zone_id     = cloudflare_zone.y2ks_site.id
  description = "Block potential SQL injection"
  expression  = "(http.request.uri.query contains \"union select\") or (http.request.uri.query contains \"information_schema\")"
}

resource "cloudflare_firewall_rule" "block_sql_injection" {
  zone_id     = cloudflare_zone.y2ks_site.id
  description = "Block SQL injection rule"
  filter_id   = cloudflare_filter.sql_injection.id
  action      = "block"
}

# CDN 및 캐싱 설정
resource "cloudflare_zone_settings_override" "y2ks_settings" {
  zone_id = cloudflare_zone.y2ks_site.id
  settings {
    minify {
      html = "on"
      css  = "on"
      js   = "on"
    }
    security_level = "medium"
    brotli         = "on"
    rocket_loader  = "on"
  }
}
