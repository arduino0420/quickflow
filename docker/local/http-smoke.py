#!/usr/bin/env python3
"""Local dev HTTP / check HTTPS smoke. Not browser UI, not real AI."""
import html, http.cookiejar, io, json, re, secrets, ssl, sys, time, urllib.parse, urllib.request, urllib.error, zipfile
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
MODE = sys.argv[1] if len(sys.argv) > 1 else ""
if MODE not in ("dev", "check"):
    raise SystemExit("Usage: http-smoke.py dev|check PRIVATE_FIXTURE_JSON")
BASE = {"dev": "http://localhost:18080", "check": "https://localhost:18444"}[MODE]
class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl)[:2] != urllib.parse.urlsplit(BASE)[:2]:
            raise RuntimeError("Refusing redirect outside dedicated local HTTPS endpoint")
        return super().redirect_request(req, fp, code, msg, headers, newurl)
class Tags(HTMLParser):
    def __init__(self, text):
        super().__init__(); self.tags=[]; self.feed(text)
    def handle_starttag(self, tag, attrs): self.tags.append((tag,dict(attrs)))
def check(name, condition):
    if not condition: raise RuntimeError("FAIL: " + name)
    print(json.dumps({"check":name,"passed":True}),flush=True)
def token(body):
    for tag,a in Tags(body.decode()).tags:
        if tag == "meta" and a.get("name") == "csrf-token": return a["content"]
    raise RuntimeError("CSRF token missing")
class Client:
    def __init__(self):
        # Scoped to this fixed localhost client only. No system trust or browser changes.
        ctx=ssl._create_unverified_context()
        self.jar=http.cookiejar.CookieJar()
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),SafeRedirect(),urllib.request.HTTPSHandler(context=ctx),urllib.request.HTTPCookieProcessor(self.jar))
    def request(self,path,data=None,multipart=None):
        if not path.startswith("/") or path.startswith("//"): raise RuntimeError("Unsafe request path")
        headers={"User-Agent":"Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36"}
        if multipart:
            boundary="QFRepro"+secrets.token_hex(12); parts=[]
            for k,v in data.items():
                parts.extend([f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n".encode(),str(v).encode(),b"\r\n"])
            name,blob=multipart
            parts.extend([f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"synthetic.pdf\"\r\nContent-Type: application/pdf\r\n\r\n".encode(),blob,b"\r\n",f"--{boundary}--\r\n".encode()])
            data=b"".join(parts);headers["Content-Type"]="multipart/form-data; boundary="+boundary
        elif data is not None:
            data=urllib.parse.urlencode(data).encode();headers["Content-Type"]="application/x-www-form-urlencoded"
        try:
            with self.opener.open(urllib.request.Request(BASE+path,data=data,headers=headers),timeout=30) as r:
                return r.status,r.read(),r.headers,r.url
        except urllib.error.HTTPError as e: raise RuntimeError(f"HTTP {e.code} at {path}") from None

def pdf():
    stream=b"BT /F1 18 Tf 40 700 Td (SYNTHETIC HTTP TEST ONLY: 1+1=2) Tj ET\n"
    objs=[b"<< /Type /Catalog /Pages 2 0 R >>",b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",b"<< /Length "+str(len(stream)).encode()+b" >>\nstream\n"+stream+b"endstream",b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out=b"%PDF-1.4\n"; offsets=[]
    for i,obj in enumerate(objs): offsets.append(len(out));out+=f"{i+1} 0 obj\n".encode()+obj+b"\nendobj\n"
    pos=len(out);out+=b"xref\n0 6\n0000000000 65535 f \n"
    for offset in offsets: out+=f"{offset:010d} 00000 n \n".encode()
    return out+b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"+str(pos).encode()+b"\n%%EOF\n"

def main():
    with open(sys.argv[2]) as f: identity=json.load(f)
    check("synthetic_fixture",identity["run"].startswith("HTTPLOCAL") and identity["mode"]==MODE)
    teacher,student=Client(),Client()
    status,body,headers,url=teacher.request("/login")
    check("localhost_login_page",status==200 and headers.get_content_type()=="text/html")
    check("synthetic_ai_response_marker", headers.get("X-QuickFlow-Local-AI")=="synthetic")
    status,body,_,url=teacher.request("/login",{"authenticity_token":token(body),"session[user_id]":identity["teacher_user"],"session[password]":identity["password"]})
    check("real_http_teacher_login_csrf",urllib.parse.urlsplit(url).path=="/assignments")
    if MODE=="check": check("secure_session_cookie",any(c.secure for c in teacher.jar))
    _,body,_,_=teacher.request("/assignments/new")
    title="HTTP synthetic "+identity["run"]+" "+secrets.token_hex(4)
    _,body,_,url=teacher.request("/assignments",{"authenticity_token":token(body),"assignment[title]":title,"assignment[point_per_question]":"5","assignment[classroom_ids][]":str(identity["classroom_id"])},("assignment[material_file]",pdf()))
    check("real_http_pdf_distribution",urllib.parse.urlsplit(url).path=="/assignments" and title in body.decode())
    assignment_paths=[path for path, text in re.findall(r'<a\b[^>]*href="(/assignments/\d+)"[^>]*>(.*?)</a>', body.decode(), re.S) if title in html.unescape(text)]
    check("one_synthetic_assignment",len(assignment_paths)==1)
    assignment=assignment_paths[0]; aid=assignment.rsplit("/",1)[1]
    _,body,_,_=student.request("/student/login")
    _,body,_,url=student.request("/student/login",{"authenticity_token":token(body),"student_session[school_code]":identity["school_code"],"student_session[grade]":"1","student_session[class_number]":"1","student_session[attendance_number]":"1","student_session[password]":identity["password"]})
    check("real_http_student_login_csrf",urllib.parse.urlsplit(url).path=="/student/assignments")
    student_path="/student/assignments/"+aid
    _,body,_,_=student.request(student_path)
    _,body,_,url=student.request(student_path+"/submission",{"authenticity_token":token(body)},("submission[answer_file]",pdf()))
    check("real_http_pdf_submission",urllib.parse.urlsplit(url).path==student_path)
    deadline=time.monotonic()+120
    while "5点" not in body.decode():
        if time.monotonic()>deadline: raise RuntimeError("Timed out waiting for synthetic worker grading")
        time.sleep(0.5);_,body,_,_=student.request(student_path)
    check("real_http_worker_result",True)
    _,download,_,_=student.request(student_path+"/answer")
    check("real_http_answer_pdf_preserved",download==pdf())
    _,body,_,_=teacher.request(assignment)
    submission_paths=[a["href"] for t,a in Tags(body.decode()).tags if t=="a" and re.match(assignment+r"/submissions/\d+",a.get("href",""))]
    check("teacher_review_link",bool(submission_paths))
    review=submission_paths[0];_,body,_,_=teacher.request(review)
    fields={a["name"]:a.get("value","") for t,a in Tags(body.decode()).tags if t=="input" and a.get("name","").startswith("original_final_judgments[")}
    check("one_grading_result",len(fields)==1)
    key=next(iter(fields));check("original_ai_correct",fields[key]=="correct")
    fields.update({"authenticity_token":token(body),"_method":"patch",key.replace("original_final_judgments", "final_judgments"):"incorrect"})
    _,body,_,_=teacher.request(review,fields)
    check("real_http_teacher_override", "0点" in body.decode())
    _,xlsx,headers,_=teacher.request(assignment+"/export.xlsx?classroom_id="+str(identity["classroom_id"]))
    check("real_http_excel_download",headers.get_content_type()=="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    with zipfile.ZipFile(io.BytesIO(xlsx)) as z: sheet=ET.fromstring(z.read("xl/worksheets/sheet1.xml"))
    ns={"x":"http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    check("real_http_excel_corrected_score",sheet.find(".//x:c[@r='C2']/x:v",ns).text=="0")
    _,body,_,_=student.request(student_path)
    check("real_http_student_corrected_result","0点" in body.decode())
    print(json.dumps({"outcome":"PASS","scope":"Local configured ingress with real DB/configured worker and synthetic AI; no browser Canvas", "mode":MODE, "assignment_id":int(aid)}))
if __name__=="__main__":
    try: main()
    except Exception as e:
        print(json.dumps({"outcome":"FAIL","error":str(e)}));sys.exit(1)
