output "source_repository_clone_url" {
  value = data.aws_codecommit_repository.source.clone_url_http
}

output "git_client_role_arn" {
  value = aws_iam_role.git_client.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.sync.function_name
}

output "destination_secret_arn" {
  description = "Populate out of band with {\"username\": \"...\", \"pat\": \"...\"}."
  value       = aws_secretsmanager_secret.destination.arn
}

output "lambda_outbound_ip" {
  description = "Public IP the sync pushes from; allow it if the destination filters clients."
  value       = aws_eip.nat.public_ip
}
