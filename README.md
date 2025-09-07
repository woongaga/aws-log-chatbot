# AWS Log Chatbot (Terraform)
- 자연어 질의로 ALB/VPC Flow 로그를 요약, 결론/근거/원인/조치 제시
- Lambda + Bedrock, S3(Log/Playbook/Page), ALB/ASG/EC2, RDS, VPC
- IaC: Terraform

# 선행조건
- AWS 콘솔 접속 후, Amazon Bedrock -> Configure and learn -> 모델 액세스 -> Claude 3.5 Sonnet을 액세스 요청해야합니다.(사용 리전 지정 - 본 프로젝트는 서울 기준)

# 사용방법
- terraform.tfvars.example파일을 자신에 맞게 수정 후, terraform.tfvars로 변경하세요.

# Windows (PowerShell)
```powershell
# 1) 레포지토리 클론
git clone https://github.com/woongaga/aws-log-chatbot.git
cd aws-log-chatbot

# 2) 변수 파일 템플릿 복사 후 값 채우기
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
# 메모장 등으로 terraform.tfvars 열어 S3 버킷명, DB 비밀번호, CORS Origin 등을 입력

# 3) AWS CLI 프로파일 설정(최초 1회)
aws configure --profile default
```

# Linux
```bash
# 1) 레포지토리 클론
git clone https://github.com/woongaga/aws-log-chatbot.git
cd aws-log-chatbot

# 2) 변수 파일 템플릿 복사 후 값 채우기
cp terraform.tfvars.example terraform.tfvars
# 편집기로 terraform.tfvars 수정(S3, DB, CORS 등)

# 3) AWS CLI 프로파일 설정(최초 1회)
aws configure --profile default
```

# 배포 및 삭제
```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply

terraform destroy
```
