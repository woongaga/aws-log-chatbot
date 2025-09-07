# AWS Log Chatbot (Terraform)
- 자연어 질의로 ALB/VPC Flow 로그를 요약, 결론/근거/원인/조치 제시
- Lambda + Bedrock, S3(Log/Playbook/Page), ALB/ASG/EC2, RDS, VPC
- IaC: Terraform

# 선행조건
- AWS 콘솔 접속 후, Amazon Bedrock -> Configure and learn -> 모델 액세스 -> Claude 3.5 Sonnet을 액세스 요청해야합니다.(사용 리전 지정 - 본 프로젝트는 서울 기준)

# 배포
```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply

# 배포
```bash
terraform destroy

