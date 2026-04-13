resource "aws_athena_workgroup" "analytics" {
  name = "y2ks-analytics"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena.bucket}/athena-results/"
    }

    # 스캔 제한 100MB (100 * 1024 * 1024)
    bytes_scanned_cutoff_per_query = 104857600
  }
}

resource "aws_glue_catalog_database" "analytics" {
  name = "y2ks_analytics"
}

resource "aws_glue_catalog_table" "k6_raw" {
  name          = "k6_raw"
  database_name = aws_glue_catalog_database.analytics.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "json"
  }

  partition_keys {
    name = "run_date"
    type = "string"
  }

  partition_keys {
    name = "run_id"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.athena.bucket}/k6/raw/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "paths" = "type,metric,data"
      }
    }

    columns {
      name = "type"
      type = "string"
    }
    columns {
      name = "metric"
      type = "string"
    }
    columns {
      name = "data"
      type = "struct<time:string,value:double,tags:struct<method:string,url:string,status:string>>"
    }
  }
}

output "athena_workgroup_name" {
  value = aws_athena_workgroup.analytics.name
}

output "glue_database_name" {
  value = aws_glue_catalog_database.analytics.name
}
