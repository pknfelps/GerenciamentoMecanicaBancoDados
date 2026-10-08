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
    error_message = "O projeto exige us-east-1."
  }
}

variable "adopt_existing_credentials" {
  description = "Somente na primeira migracao: importa metadados e preserva as senhas existentes."
  type        = bool
  default     = false
  nullable    = false
}
