# =============================================================================
# API Gateway Gateway Responses — FedRAMP AC-08 System Use Notification
#
# FedRAMP AC-08 requires a system use notification (warning banner) to be
# displayed before granting access to any U.S. Government information system.
# These gateway responses inject the notification as an HTTP response header
# (X-System-Use-Notification) on all error responses that a client receives
# before or during authentication, satisfying the requirement without requiring
# client-side changes.
# =============================================================================

locals {
  system_use_notification = "WARNING: This is a U.S. Government information system. Unauthorized use is prohibited and subject to criminal and civil penalties. By using this system, you consent to monitoring and recording of all activity. There is no expectation of privacy."
}

# -----------------------------------------------------------------------------
# UNAUTHORIZED (401) — returned before authentication succeeds
# -----------------------------------------------------------------------------

resource "aws_api_gateway_gateway_response" "unauthorized" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "UNAUTHORIZED"
  status_code   = "401"

  response_templates = {
    "application/json" = "{\"message\": \"${local.system_use_notification}\"}"
  }

  response_parameters = {
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }
}

# -----------------------------------------------------------------------------
# DEFAULT_4XX — covers all other 4xx errors (e.g., 403 ACCESS_DENIED)
# -----------------------------------------------------------------------------

resource "aws_api_gateway_gateway_response" "default_4xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_4XX"

  response_templates = {
    "application/json" = "{\"message\": \"$context.error.messageString\"}"
  }

  response_parameters = {
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }
}

# -----------------------------------------------------------------------------
# DEFAULT_5XX — covers all 5xx errors
# -----------------------------------------------------------------------------

resource "aws_api_gateway_gateway_response" "default_5xx" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  response_type = "DEFAULT_5XX"

  response_templates = {
    "application/json" = "{\"message\": \"$context.error.messageString\"}"
  }

  response_parameters = {
    "gatewayresponse.header.X-System-Use-Notification" = "'${local.system_use_notification}'"
  }
}
