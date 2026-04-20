import os
import json
import boto3
import requests
import subprocess

# 설정
AWS_REGION = "us-east-1"  # Bedrock Claude 3.5 Sonnet이 활성화된 리전
MODEL_ID = "anthropic.claude-3-5-sonnet-20240620-v1:0"

def get_pr_diff():
    # 깃허브 액션 환경에서 현재 PR의 변경점을 가져옵니다.
    base_sha = os.environ.get("GITHUB_BASE_REF", "main")
    try:
        diff = subprocess.check_output(["git", "diff", f"origin/{base_sha}..HEAD"], text=True)
        return diff
    except Exception as e:
        return f"Diff 추출 실패: {e}"

def get_ai_review(diff):
    # 환경변수에서 인증 정보 가져오기 (공백/줄바꿈 완벽 제거)
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "").strip()
    
    client = boto3.client(
        "bedrock-runtime", 
        region_name=AWS_REGION,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key
    )
    
    prompt = f"""당신은 최고의 SRE 및 클라우드 아키텍트입니다.
아래의 코드 변경사항(Diff)은 Y2KS EKS 인프라 자율 운영 에이전트가 생성한 것입니다.
이 변경사항을 검토하고 운영팀 팀장님에게 보고할 리뷰 의견을 작성해 주세요.

## 검토 지침
1. **타당성**: 변경된 수치(예: CPU 제한)가 인프라 안정성에 적절한가?
2. **위험 요소**: 이 변경으로 인해 발생할 수 있는 잠재적 장애나 비용 급증 요소가 있는가?
3. **보안**: 설정에 민감 정보가 포함되지는 않았는가?

## 응답 형식
- 한국어로 작성하세요.
- 친절하면서도 전문적인 톤을 유지하세요.
- 개선이 필요하다면 명확한 이유를 설명하세요.

---
[변경사항 Diff]
{diff}
"""

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1000,
        "messages": [
            {"role": "user", "content": prompt}
        ]
    })

    try:
        response = client.invoke_model(modelId=MODEL_ID, body=body)
        response_body = json.loads(response["body"].read())
        return response_body["content"][0]["text"]
    except Exception as e:
        return f"AI 리뷰 생성 중 오류 발생: {e}"

def post_github_comment(review_text):
    repo = os.environ.get("REPOSITORY")
    pr_number = os.environ.get("PR_NUMBER")
    token = os.environ.get("GITHUB_TOKEN")
    
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    data = {"body": f"### 🤖 AI 코드 리뷰 결과\n\n{review_text}"}
    
    res = requests.post(url, headers=headers, json=data)
    if res.status_code == 201:
        print("댓글 작성 성공")
    else:
        print(f"댓글 작성 실패: {res.status_code}, {res.text}")

if __name__ == "__main__":
    print("AI 리뷰 분석 시작...")
    diff = get_pr_diff()
    if len(diff) > 20000: # 너무 크면 자름
        diff = diff[:20000] + "... (생략)"
        
    review = get_ai_review(diff)
    print("리뷰 생성 완료. 깃허브에 게시합니다.")
    post_github_comment(review)
