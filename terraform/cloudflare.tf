# Cloudflare Provider 설정은 main.tf의 terraform 블록으로 통합되었습니다.

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Cloudflare Zone 설정 (도메인)
resource "cloudflare_zone" "y2ks_site" {
  account_id = "62637244e9a2598595e128e76c508772"
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
