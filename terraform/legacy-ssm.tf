variable "legacy_parameter_names" {
  description = "Adocao pontual dos parametros v1 ativos; vazio apos a importacao para planejar a retirada. Historicos ficam preservados."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for name in var.legacy_parameter_names : startswith(name, "/mecanica/${var.environment}/database/v1/") && !strcontains(name, "/attempts/")])
    error_message = "Informe apenas parametros v1 ativos do proprio componente/ambiente; nao inclua historicos de tentativas."
  }
}

data "aws_ssm_parameter" "legacy" {
  for_each        = var.legacy_parameter_names
  name            = each.value
  with_decryption = false
}

import {
  for_each = var.legacy_parameter_names
  to       = aws_ssm_parameter.legacy[each.key]
  id       = each.value
}

resource "aws_ssm_parameter" "legacy" {
  for_each = var.legacy_parameter_names
  name     = each.value
  type     = "String"
  value    = nonsensitive(data.aws_ssm_parameter.legacy[each.key].value)
  lifecycle {
    ignore_changes = all
  }
}
