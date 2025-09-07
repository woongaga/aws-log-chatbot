import os, io, re, json, gzip, time, base64, shlex, random, boto3
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# ====== 환경변수 ======
LOG_BUCKET       = os.environ["LOG_BUCKET"]                 # 예: woong-log
ALB_PREFIX       = os.environ.get("ALB_PREFIX", "alb/")
VPC_PREFIX       = os.environ.get("VPC_PREFIX", "vpcflow/")
PLAYBOOK_BUCKET  = os.environ.get("PLAYBOOK_BUCKET", "woong-playbook")
PLAYBOOK_KEY     = os.environ.get("PLAYBOOK_KEY", "cases.yaml")
MODEL_ID         = os.environ.get("MODEL_ID", "anthropic.claude-3-5-sonnet-20240620-v1:0")
BEDROCK_REGION   = os.environ.get("BEDROCK_REGION") or os.environ.get("AWS_REGION") or "ap-northeast-1"

TOP_N            = int(os.environ.get("TOP_N", "5"))
MAX_OBJS         = int(os.environ.get("MAX_OBJECTS_PER_TYPE", "20"))                # 표본 스캔 객체 상한
MAX_FULL_OBJECTS = int(os.environ.get("MAX_FULL_OBJECTS", "2000"))                  # 전체 스캔 안전 상한
MAX_BYTES        = int(os.environ.get("MAX_BYTES_PER_OBJECT", str(10 * 1024 * 1024)))  # 객체 당 읽기(바이트)
TOP_TIME_EVENTS  = int(os.environ.get("TOP_TIME_EVENTS", "5"))                      # 표본 시간 응답 최대 줄 수
HARD_TIME_CAP    = int(os.environ.get("HARD_TIME_CAP", "2000"))                     # 전체 시간 응답 안전 상한(0=무제한)

# ====== 공용 클라이언트/타임존 ======
s3  = boto3.client("s3")
KST = timezone(timedelta(hours=9))

# ====== 응답 헬퍼(CORS는 Function URL에서 처리) ======
def cors(status: int, body_obj: dict):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "body": json.dumps(body_obj, ensure_ascii=False)
    }

# ====== 날짜 파싱 ======
# 예: 2025-09-03, 2025년 9월 3일, 9/3, 9-3, 9월3일 (연도 생략 허용)
DATE_RX = re.compile(r'(?:(\d{4})\s*(?:[./\-]|년)\s*)?(\d{1,2})\s*(?:[./\-]|월)\s*(\d{1,2})\s*(?:일)?')

def extract_date_kr(text: str) -> str:
    t = (text or "").strip()
    today = datetime.now(KST).date()
    tl = t.lower()

    # 자연어
    if "오늘" in t or "today" in tl:
        return today.strftime("%Y-%m-%d")
    if "어제" in t or "yesterday" in tl:
        return (today - timedelta(days=1)).strftime("%Y-%m-%d")
    if "그제" in t or "그저께" in t:
        return (today - timedelta(days=2)).strftime("%Y-%m-%d")

    # 숫자형 (연도 생략 가능)
    m = DATE_RX.search(t.replace(" ", ""))
    if m:
        year  = int(m.group(1)) if m.group(1) else today.year
        month = int(m.group(2))
        day   = int(m.group(3))
        try:
            dt = datetime(year, month, day, tzinfo=KST).date()
        except ValueError:
            return today.strftime("%Y-%m-%d")
        # 연말/연초 보정: 연도 생략으로 미래가 되면 작년으로
        if not m.group(1) and dt > today + timedelta(days=7):
            dt = datetime(year - 1, month, day, tzinfo=KST).date()
        return dt.strftime("%Y-%m-%d")

    return today.strftime("%Y-%m-%d")

# ====== 스캔 모드 판정 ======
# 날짜/오늘/어제/그제/전체/전부/하루/all/full 이 보이면 전체 스캔 선호
FULL_TRIGGER_RX = re.compile(r"(오늘|어제|그제|하루|전체|전부|all|full|\d{4}[./\-]?\d{1,2}[./\-]?\d{1,2}|[0-9]{1,2}[./\-][0-9]{1,2})",
                             re.IGNORECASE)

def wants_full_scan(q: str) -> bool:
    return bool(FULL_TRIGGER_RX.search(q or ""))

# ====== S3 키/라인 유틸 ======
def _iter_date_keys(bucket: str, prefix: str, ymd: str):
    """/YYYY/MM/DD/ 를 포함하는 키만 스트리밍으로 yield"""
    y, m, d = ymd.split("-")
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            k = obj["Key"]
            if f"/{y}/{m}/{d}/" in k:
                yield k

def list_date_keys(bucket: str, prefix: str, ymd: str, limit: int):
    """해당 날짜 키를 최대 limit개까지 yield (limit가 매우 크면 사실상 전체)"""
    cnt = 0
    for k in _iter_date_keys(bucket, prefix, ymd):
        yield k
        cnt += 1
        if limit and cnt >= limit:
            return

def read_gz_lines(bucket: str, key: str, max_bytes: int):
    obj = s3.get_object(Bucket=bucket, Key=key, Range=f"bytes=0-{max_bytes-1}")
    with gzip.GzipFile(fileobj=io.BytesIO(obj["Body"].read())) as gz:
        for raw in gz:
            line = raw.decode("utf-8", "ignore").strip()
            if line and not line.startswith("#"):
                yield line

# ====== ALB 파서/스캐너 ======
def parse_alb(line: str):
    """
    ALB 로그(스페이스 분리, 따옴표 포함)를 shlex로 파싱해 필요한 필드만 반환
    반환: (status, client_ip, path, bucket_hhmm, ts_iso)
    """
    try:
        p = shlex.split(line)
        ts_iso = p[1]                                 # 2024-01-01T00:00:00.000000Z
        status  = int(p[8]) if p[8].isdigit() else 0  # ELB status code
        client  = p[2].split(":")[0] if ":" in p[2] else p[2]
        path = "/"
        if len(p) > 12 and p[12]:
            rq = p[12].strip('"').split(" ")
            if len(rq) >= 2:
                m = re.match(r"^(?:https?://[^/]+)?(/[^? ]*)", rq[1])
                path = m.group(1) if m else "/"

        # 5분 버킷(KST 기준 HH:MM)
        dt_utc = datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
        dt     = dt_utc.astimezone(KST)
        minute = (dt.minute // 5) * 5
        bucket = f"{dt.hour:02d}:{minute:02d}"
        return status, client, path, bucket, ts_iso
    except Exception:
        return None

def scan_alb(date_str: str, deadline_ms: float, use_full: bool) -> dict:
    limit = MAX_FULL_OBJECTS if use_full else MAX_OBJS

    c2xx=c3xx=c4xx=c5xx=0
    top_paths_4xx, top_ips, top_targets_5xx = Counter(), Counter(), Counter()

    # 버킷별 카운트
    buckets = defaultdict(lambda: {"total":0,"3xx":0,"4xx":0,"5xx":0,"non2xx":0})
    samples_5xx=[]

    # 최초 시각(HH:MM) + 시각 리스트
    first_times = {"non2xx": None, "404": None, "4xx": None, "5xx": None}
    times = {"non2xx": set(), "404": set(), "4xx": set(), "5xx": set()}

    for k in list_date_keys(LOG_BUCKET, ALB_PREFIX, date_str, limit):
        for line in read_gz_lines(LOG_BUCKET, k, MAX_BYTES):
            if time.time()*1000 > deadline_ms-1500:
                break
            parsed = parse_alb(line)
            if not parsed:
                continue

            status, client, path, bkt, ts_iso = parsed
            top_ips[client] += 1
            buckets[bkt]["total"] += 1

            # 시각(KST HH:MM)
            try:
                t_kst = datetime.fromisoformat(ts_iso.replace("Z","+00:00")).astimezone(KST).strftime("%H:%M")
            except Exception:
                t_kst = None

            if 200 <= status <= 299:
                c2xx += 1
            elif 300 <= status <= 399:
                c3xx += 1
                buckets[bkt]["3xx"] += 1
                buckets[bkt]["non2xx"] += 1
                if t_kst:
                    times["non2xx"].add(t_kst)
                if first_times["non2xx"] is None and t_kst:
                    first_times["non2xx"] = t_kst
            elif 400 <= status <= 499:
                c4xx += 1
                top_paths_4xx[path] += 1
                buckets[bkt]["4xx"] += 1
                buckets[bkt]["non2xx"] += 1
                if t_kst:
                    times["4xx"].add(t_kst)
                    times["non2xx"].add(t_kst)
                    if status == 404:
                        times["404"].add(t_kst)
                if first_times["4xx"] is None and t_kst:
                    first_times["4xx"] = t_kst
                if status == 404 and first_times["404"] is None and t_kst:
                    first_times["404"] = t_kst
            elif 500 <= status <= 599:
                c5xx += 1
                top_targets_5xx[str(status)] += 1
                buckets[bkt]["5xx"] += 1
                buckets[bkt]["non2xx"] += 1
                if len(samples_5xx) < 10:
                    samples_5xx.append({"time": ts_iso, "ip": client, "status": status, "path": path})
                if t_kst:
                    times["5xx"].add(t_kst)
                    times["non2xx"].add(t_kst)
                if first_times["5xx"] is None and t_kst:
                    first_times["5xx"] = t_kst
                if first_times["non2xx"] is None and t_kst:
                    first_times["non2xx"] = t_kst

    note = f"ALB {'전체' if use_full else '표본'} 스캔(객체 최대 {limit} · 개당 {MAX_BYTES}B)"
    return {
        "date": date_str,
        "counts": {"2xx":c2xx,"3xx":c3xx,"4xx":c4xx,"5xx":c5xx},
        "top_paths_4xx": top_paths_4xx.most_common(TOP_N),
        "top_ips": top_ips.most_common(TOP_N),
        "top_targets_5xx": top_targets_5xx.most_common(TOP_N),
        "samples_5xx": samples_5xx,
        "first_times": first_times,
        "times": {k: sorted(v) for k, v in times.items()},  # HH:MM 리스트
        "sample_note": note,
        "scan_mode": "full" if use_full else "sample",
    }

# ====== VPC 파서/스캐너 ======
def parse_vpc(line: str):
    parts = line.split()
    if len(parts) < 14:
        return None
    try:
        src, dst = parts[3], parts[4]
        dstport = int(parts[6])
        proto   = parts[7]
        start   = int(parts[10])          # epoch start time (sec)
        action  = parts[12].upper()
        return src, dst, dstport, proto, start, action
    except Exception:
        return None

def scan_vpc(date_str: str, deadline_ms: float, use_full: bool) -> dict:
    limit = MAX_FULL_OBJECTS if use_full else MAX_OBJS

    accept=reject=0
    top_reject_src, top_reject_dstport = Counter(), Counter()
    samples=[]
    scan_window=120
    per_src_bkt_ports=defaultdict(lambda: defaultdict(set))

    first_reject = None  # HH:MM
    reject_times = set() # HH:MM 리스트

    for k in list_date_keys(LOG_BUCKET, VPC_PREFIX, date_str, limit):
        for line in read_gz_lines(LOG_BUCKET, k, MAX_BYTES):
            if time.time()*1000 > deadline_ms-1500:
                break
            p = parse_vpc(line)
            if not p:
                continue

            src, dst, dstport, proto, start, action = p
            if action == "ACCEPT":
                accept += 1
            elif action == "REJECT":
                reject += 1
                top_reject_src[src] += 1
                top_reject_dstport[dstport] += 1
                st = datetime.fromtimestamp(start, tz=KST)
                hhmm = st.strftime("%H:%M")
                reject_times.add(hhmm)
                if first_reject is None:
                    first_reject = hhmm
                if len(samples) < 10:
                    samples.append({"src":src,"dst":dst,"dstport":dstport,"protocol":proto,"start":start})

            bkt = (start // scan_window) * scan_window
            per_src_bkt_ports[src][bkt].add(dstport)

    suspects=[]
    for src, bkts in per_src_bkt_ports.items():
        for bkt, ports in bkts.items():
            if len(ports) >= 20:
                suspects.append({"src":src,"window_start":bkt,"window_sec":scan_window,"unique_dstports":len(ports)})
                break

    total = accept + reject
    note = f"VPC {'전체' if use_full else '표본'} 스캔(객체 최대 {limit} · 개당 {MAX_BYTES}B)"
    return {
        "date": date_str,
        "accept": accept, "reject": reject,
        "reject_ratio": round(reject/total, 6) if total else 0.0,
        "top_reject_src": top_reject_src.most_common(TOP_N),
        "top_reject_dstport": top_reject_dstport.most_common(TOP_N),
        "first_reject": first_reject,
        "reject_times": sorted(reject_times),
        "scan_suspects": suspects[:TOP_N],
        "samples": samples,
        "sample_note": note,
        "scan_mode": "full" if use_full else "sample",
    }

# ====== Bedrock 호출 ======
def _parse_bedrock_text(out: dict) -> str:
    # 다양한 포맷 방어적으로 파싱
    if "output" in out:
        o = out["output"]
        if isinstance(o, dict):
            if "message" in o and isinstance(o["message"], dict):
                cont = o["message"].get("content", [])
                return "".join([x.get("text","") for x in cont if isinstance(x, dict) and x.get("type")=="text"]).strip()
            if "content" in o and isinstance(o["content"], list):
                return "".join([x.get("text","") for x in o["content"] if isinstance(x, dict)]).strip()
    if "content" in out and isinstance(out["content"], list):
        return "".join([x.get("text","") for x in out["content"] if isinstance(x, dict)]).strip()
    if "completion" in out:
        return str(out["completion"]).strip()
    return ""

def ask_bedrock(question: str, alb_json: dict, vpc_json: dict, playbook_text: str = "") -> str:
    system = (
        "너는 운영/보안 로그 분석가다. 입력은 ALB/VPC Flow 표본 요약과 사례집이다.\n"
        "- ALB: 2xx 정상, 3xx/4xx/5xx 비정상 경향.\n"
        "- VPC: REJECT 비율, 짧은 시간 다중 포트(스캔) 의심 주목.\n"
        "출력: 1) 결론 2) 근거 3) 가능한 원인 4) 권장 조치(<=3) 5) 표본 한계."
    )
    user = f"""질문: {question}

[ALB 요약]
{json.dumps(alb_json, ensure_ascii=False)}

[VPC FLOW 요약]
{json.dumps(vpc_json, ensure_ascii=False)}

[사례집]
{playbook_text[:8000]}
"""

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "system":   [{"type": "text", "text": system}],
        "messages": [{"role": "user", "content": [{"type": "text", "text": user}]}],
        "max_tokens": 800,
        "temperature": 0.2
    }

    # 재시도/백오프 설정
    cfg = Config(retries={"max_attempts": 10, "mode": "adaptive"}, read_timeout=60, connect_timeout=10)

    try:
        client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION, config=cfg)
        delay = 0.4  # 지수 백오프 + 지터
        for attempt in range(6):
            try:
                resp = client.invoke_model(modelId=MODEL_ID, body=json.dumps(body))
                out  = json.loads(resp["body"].read())
                text = _parse_bedrock_text(out)
                return text or "[참고] 모델 응답이 비어 있습니다. (표본 요약을 확인하세요)"
            except ClientError as e:
                code = e.response.get("Error", {}).get("Code", "")
                if code in {"ThrottlingException", "TooManyRequestsException"} and attempt < 5:
                    time.sleep(delay + random.random() * 0.3)
                    delay *= 2
                    continue
                raise
        return "[임시 안내] 재시도 후에도 모델 호출이 계속 제한되었습니다."
    except (BotoCoreError, ClientError) as e:
        return f"[임시 안내] Bedrock 호출 오류: {type(e).__name__}: {str(e)[:300]}"
    except Exception as e:
        return f"[임시 안내] 처리 중 오류: {type(e).__name__}: {str(e)[:300]}"

def load_playbook() -> str:
    try:
        obj = s3.get_object(Bucket=PLAYBOOK_BUCKET, Key=PLAYBOOK_KEY)
        return obj["Body"].read().decode("utf-8", "ignore")
    except Exception:
        return ""

# ====== 시간 즉답 보완(전체 스캔은 제한 없이, 표본은 TOP N) ======
FULL_LIST_HINT_RX = FULL_TRIGGER_RX  # 동일한 힌트 기준 사용

def _format_time_lines(date: str, label: str, times: list[str], unlimited: bool) -> list[str]:
    """시간 리스트를 줄 단위 문장으로 변환.
       unlimited=True면 TOP N 자르지 않고 모두 출력(단, HARD_TIME_CAP 초과 시 안전 상한 적용)."""
    if not times:
        return [f"{label} 시각을 찾지 못했어요."]

    times = sorted(times)
    if unlimited:
        cap = HARD_TIME_CAP if HARD_TIME_CAP > 0 else len(times)
        lines = [f"{date} {t}에 {label} 로그가 있었어요." for t in times[:cap]]
        if HARD_TIME_CAP > 0 and len(times) > HARD_TIME_CAP:
            lines.append(f"(표시 한도 {HARD_TIME_CAP}개 초과분은 생략)")
        return lines
    else:
        cut = times[:TOP_TIME_EVENTS]
        return [f"{date} {t}에 {label} 로그가 있었어요." for t in cut]

def _wants_time_simple(q: str) -> bool:
    s = (q or "").lower()
    return any(x in s for x in ["몇시", "몇 시", "언제", "시간"]) and \
           any(x in s for x in ["비정상", "404", "4xx", "5xx", "reject", "리젝트"])

def _simple_time_answer(date: str, question: str, alb: dict, vpc: dict) -> str:
    unlimited = bool(FULL_LIST_HINT_RX.search(question or ""))

    want_404 = "404" in question
    want_4xx = "4xx" in question
    want_5xx = "5xx" in question
    want_any = ("비정상" in question) or (not (want_404 or want_4xx or want_5xx))

    alb_times = (alb or {}).get("times") or {}
    vpc_times = (vpc or {}).get("reject_times") or []

    def to_lines(times: list[str], label: str) -> list[str]:
        return _format_time_lines(date, label, times, unlimited)

    if want_404:
        return "\n".join(to_lines(alb_times.get("404", []), "ALB 404"))
    if want_4xx:
        return "\n".join(to_lines(alb_times.get("4xx", []), "ALB 4xx"))
    if want_5xx:
        return "\n".join(to_lines(alb_times.get("5xx", []), "ALB 5xx"))

    # 포괄(비정상): ALB 비정상 + VPC REJECT 합쳐 시간순
    if want_any:
        combined = []
        for t in alb_times.get("non2xx", []):
            combined.append((t, "ALB 비정상(Non-2xx)"))
        for t in vpc_times:
            combined.append((t, "VPC REJECT"))
        if not combined:
            return "표본에서 비정상 로그 발생 시각을 찾지 못했어요."

        combined.sort(key=lambda x: x[0])

        if unlimited:
            cap = HARD_TIME_CAP if HARD_TIME_CAP > 0 else len(combined)
            lines = [f"{date} {t}에 {lbl} 로그가 있었어요." for t, lbl in combined[:cap]]
            if HARD_TIME_CAP > 0 and len(combined) > HARD_TIME_CAP:
                lines.append(f"(표시 한도 {HARD_TIME_CAP}개 초과분은 생략)")
            return "\n".join(lines)
        else:
            cut = combined[:TOP_TIME_EVENTS]
            return "\n".join([f"{date} {t}에 {lbl} 로그가 있었어요." for t, lbl in cut])

    return "요청을 이해하지 못했어요."

# ====== 핸들러 ======
def handler(event, context):
    # Function URL / HTTP API 2.0 공통 처리
    method = (event.get("requestContext", {}).get("http", {}).get("method")
              or event.get("httpMethod", "POST"))
    if method == "OPTIONS":
        return cors(200, {"ok": True})

    # Body 파싱
    try:
        raw = event.get("body", "")
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode("utf-8")
        payload = json.loads(raw) if raw else {}
    except Exception:
        return cors(400, {"error": "invalid JSON body"})

    question = (payload.get("question") or "").strip()
    if not question:
        return cors(400, {"error": "question required"})

    # 헬스체크
    if question.lower() in {"ping", "health", "debug"}:
        return cors(200, {"ok": True, "note": "lambda alive"})

    # 날짜/모드/타임아웃
    date = extract_date_kr(question)
    use_full = wants_full_scan(question)  # 전체 스캔 여부
    remaining = getattr(context, "get_remaining_time_in_millis", lambda: 2000)()
    deadline_ms = time.time() * 1000 + remaining

    # 표본/전체 스캔 (실패해도 진행)
    try:
        alb = scan_alb(date, deadline_ms, use_full)
    except Exception as e:
        alb = {"date": date, "error": f"alb_scan:{e}", "scan_mode": "error", "sample_note": "ALB 스캔 오류"}
    try:
        vpc = scan_vpc(date, deadline_ms, use_full)
    except Exception as e:
        vpc = {"date": date, "error": f"vpc_scan:{e}", "scan_mode": "error", "sample_note": "VPC 스캔 오류"}

    # 시간 즉답 모드(LLM 생략)
    if _wants_time_simple(question):
        return cors(200, {
            "date": date,
            "answer": _simple_time_answer(date, question, alb, vpc),
            "alb_note": alb.get("sample_note", ""),
            "vpc_note": vpc.get("sample_note", ""),
            "scan_mode": {"alb": alb.get("scan_mode"), "vpc": vpc.get("scan_mode")}
        })

    # 그 외는 LLM 요약
    playbook = load_playbook()
    answer = ask_bedrock(question, alb, vpc, playbook)

    return cors(200, {
        "date": date,
        "answer": answer,
        "alb_note": alb.get("sample_note", ""),
        "vpc_note": vpc.get("sample_note", ""),
        "scan_mode": {"alb": alb.get("scan_mode"), "vpc": vpc.get("scan_mode")},
        "used": {"playbook": f"s3://{PLAYBOOK_BUCKET}/{PLAYBOOK_KEY}"}
    })
