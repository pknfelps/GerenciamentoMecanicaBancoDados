variable "environment" {
  description = "Ambiente isolado do banco: hom ou prd."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["hom", "prd"], var.environment)
    error_message = "environment deve ser hom ou prd."
  }
}

variable "aws_region" {
  description = "Regiao da base e do banco."
  type        = string
  default     = "us-east-1"
  nullable    = false

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "O contrato v1 do projeto exige us-east-1."
  }
}

variable "base_context_file" {
  description = "Snapshot JSON gerado por consume_database_release.py capture e relido antes de cada mutacao."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.base_context_file)) > 0
    error_message = "Informe o caminho do snapshot database-release validado."
  }
}
