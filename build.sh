#!/usr/bin/env bash
set -euo pipefail

app_name_default="botsrhere-realtime"
presenters_default="https://botsrhere.space/development/presenters.json"

# ---------- helpers ----------
die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
need(){ have "$1" || die "Missing dependency: $1"; }
ask(){ # ask "Prompt" "default"
  local p="${1:-}" d="${2:-}"
  if [ -n "${CI:-}" ]; then echo "${d}"; return; fi
  read -rp "$p [${d}]: " v || true
  echo "${v:-$d}"
}
confirm(){ # confirm "message"
  local p="${1:-Proceed?}"
  read -rp "$p [y/N]: " yn || true
  case "${yn:-N}" in y|Y) return 0;; *) return 1;; esac
}

echo "▶ Preflight checks…"
need git
need curl
need jq
need sed
need awk
need docker
if docker compose version >/dev/null 2>&1; then compose="docker compose"; else need docker-compose; compose="docker-compose"; fi

# ---------- gather inputs ----------
OWNER="$(ask "GitHub owner (user/org)" "$(git config user.name 2>/dev/null || echo "")")"
[ -n "$OWNER" ] || die "GitHub owner is required."

REPO="$(ask "GitHub repo name" "$app_name_default")"
VISIBILITY="$(ask "GitHub visibility (public/private)" "private")"
GH_TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$GH_TOKEN" ]; then
  GH_TOKEN="$(ask "GitHub Personal Access Token (repo scope)" "")"
fi
[ -n "$GH_TOKEN" ] || die "GitHub token is required."

APP_DIR="$(ask "Local project directory" "$REPO")"
PRESENTERS_JSON="$(ask "Presenters JSON URL" "$presenters_default")"

COOLIFY_URL="$(ask "Coolify base URL (leave blank to skip auto deploy)" "")"
COOLIFY_TOKEN=""
if [ -n "$COOLIFY_URL" ]; then
  COOLIFY_TOKEN="$(ask "Coolify API Token" "")"
  [ -n "$COOLIFY_TOKEN" ] || die "Coolify token required when COOLIFY_URL is set."
fi

echo "▶ Plan:"
echo "   Owner         : $OWNER"
echo "   Repo          : $REPO ($VISIBILITY)"
echo "   Dir           : $APP_DIR"
echo "   Presenters    : $PRESENTERS_JSON"
if [ -n "$COOLIFY_URL" ]; then
  echo "   Coolify       : $COOLIFY_URL (auto deploy attempt)"
else
  echo "   Coolify       : (manual after push)"
fi
confirm "Proceed to scaffold source code?" || exit 1

# ---------- scaffold ----------
if [ -e "$APP_DIR" ]; then
  confirm "Directory '$APP_DIR' exists. Overwrite contents (danger)?" || die "Aborted."
  rm -rf "$APP_DIR"
fi
mkdir -p "$APP_DIR"
cd "$APP_DIR"

mkdir -p signal/public lipsync

# .gitignore
cat > .gitignore <<'EOF'
node_modules/
__pycache__/
*.pyc
.env
outputs/
inputs/
.DS_Store
EOF

# env example
cat > .env.example <<EOF
PORT=3000
LIPSYNC_BASE=http://lipsync:8000
PRESENTERS_JSON=$PRESENTERS_JSON
EOF

# docker compose
cat > docker-compose.yml <<'EOF'
version: "3.9"
services:
  signal:
    build:
      context: ./signal
    env_file: .env
    ports:
      - "3000:3000"
    depends_on:
      - lipsync

  lipsync:
    build:
      context: ./lipsync
    environment:
      - PORT=8000
    # To enable GPU, uncomment below and configure your Coolify/host for NVIDIA runtime:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - capabilities: [gpu]
EOF

# ---------- signal (Node) ----------
cat > signal/package.json <<'EOF'
{
  "name": "botsrhere-signal",
  "version": "1.0.0",
  "description": "BotsRHere signaling + static server + proxy to lipsync",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "license": "UNLICENSED",
  "dependencies": {
    "express": "^4.19.2",
    "http-proxy-middleware": "^3.0.2",
    "socket.io": "^4.7.5"
  }
}
EOF

cat > signal/server.js <<'EOF'
const express = require('express');
const http = require('http');
const path = require('path');
const { createProxyMiddleware } = require('http-proxy-middleware');
const { Server } = require('socket.io');

const PORT = process.env.PORT || 3000;
const LIPSYNC_BASE = process.env.LIPSYNC_BASE || 'http://lipsync:8000';
const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' } });

app.use(express.static(path.join(__dirname, 'public')));
app.use('/api/lipsync', createProxyMiddleware({
  target: LIPSYNC_BASE, changeOrigin: true,
  pathRewrite: { '^/api/lipsync': '' }
}));

const rooms = {};
io.on('connection', (socket) => {
  socket.on('join-room', (roomId) => {
    rooms[roomId] = rooms[roomId] || [];
    rooms[roomId].push(socket.id);
    socket.join(roomId);
    const other = rooms[roomId].find(id => id !== socket.id);
    if (other) {
      io.to(other).emit('other-user-joined', socket.id);
      io.to(socket.id).emit('other-user-joined', other);
    }
  });
  socket.on('offer', (p) => io.to(p.target).emit('offer', { sdp: p.sdp, sender: socket.id }));
  socket.on('answer', (p) => io.to(p.target).emit('answer', { sdp: p.sdp, sender: socket.id }));
  socket.on('ice-candidate', (p) => io.to(p.target).emit('ice-candidate', { candidate: p.candidate, sender: socket.id }));
  socket.on('disconnect', () => {
    for (const roomId in rooms) {
      const idx = rooms[roomId].indexOf(socket.id);
      if (idx > -1) {
        rooms[roomId].splice(idx, 1);
        const other = rooms[roomId][0];
        if (other) io.to(other).emit('peer-disconnected');
        if (!rooms[roomId].length) delete rooms[roomId];
        break;
      }
    }
  });
});

server.listen(PORT, () => console.log(`signal up on :${PORT}`));
EOF

# minimal frontend (uses presenters + wav2lip)
cat > signal/public/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>BotsRHere — Realtime + Wav2Lip</title>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  :root{--bg:#0b0b0c;--fg:#e6e6e6;--muted:#a1a1aa;--accent:#39d98a;--card:#141417;--border:#242428;--phone-w:390px;--phone-h:844px}
  *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font-family:Inter,system-ui,Arial}
  .container{max-width:1280px;margin:0 auto;padding:24px}
  .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
  .card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:14px}
  .btn{background:#1d1d21;border:1px solid var(--border);color:#fff;padding:10px 14px;border-radius:10px;cursor:pointer}
  .btn.primary{background:var(--accent);color:#0b0b0c;border-color:var(--accent);font-weight:600}
  input,select,textarea{width:100%;background:#0f0f12;border:1px solid var(--border);color:#e6e6e6;border-radius:10px;padding:10px}
  .grid{display:grid;gap:16px;grid-template-columns:420px 1fr}
  @media (max-width:1100px){.grid{grid-template-columns:1fr}}
  .phone{width:var(--phone-w);height:var(--phone-h);border:1px solid var(--border);border-radius:30px;overflow:hidden;background:#000;margin:0 auto}
  .phone .inner{width:100%;height:100%;display:grid;place-items:center}
  .thumbs{margin-top:12px;display:flex;gap:10px;overflow-x:auto;padding-bottom:6px}
  .thumb{flex:0 0 auto;width:88px;border:1px solid var(--border);border-radius:10px;background:#0f0f12;cursor:pointer}
  .thumb img{width:100%;height:76px;object-fit:cover;border-radius:10px 10px 0 0}
  .thumb .n{font-size:11px;color:#a1a1aa;padding:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .thumb.active{outline:2px solid var(--accent)}
  .stage{position:relative;width:100%;aspect-ratio:16/9;background:#000;border:1px solid var(--border);border-radius:12px;overflow:hidden;display:grid;place-items:center}
  .toasts{position:fixed;right:16px;bottom:16px;display:grid;gap:8px;z-index:9999}.toast{background:#111114;border:1px solid var(--border);padding:10px 12px;border-radius:10px}
  .muted{color:#a1a1aa}.small{font-size:12px}
</style>
</head>
<body>
  <main class="container grid">
    <section class="card">
      <div class="row" style="justify-content:space-between">
        <div>
          <div style="font-weight:600" id="mName">—</div>
          <div class="small muted" id="mId">—</div>
        </div>
        <div class="row small muted">
          <input id="jsonUrl" type="url" value="" placeholder="(auto) presenters.json" style="width:320px">
          <button class="btn" id="btnReload">Reload</button>
        </div>
      </div>

      <div class="phone" style="margin-top:10px">
        <div class="inner"><video id="mVideo" controls autoplay loop playsinline></video></div>
      </div>

      <div id="thumbs" class="thumbs"></div>

      <div style="height:12px"></div>
      <h3 style="margin:0">Generate via Wav2Lip</h3>
      <p class="small muted">Upload or record audio, then Generate. Output replaces both players.</p>
      <div class="row">
        <input type="file" id="audioFile" accept="audio/*" />
        <button class="btn" id="btnRec">● Record</button>
        <button class="btn primary" id="btnGen">Generate</button>
      </div>
      <audio id="recPreview" controls style="width:100%;margin-top:8px;display:none"></audio>
    </section>

    <section class="card">
      <div class="row" style="justify-content:space-between">
        <h2 style="margin:0">Web 1920×1080 Stage</h2>
        <div class="small muted" id="webMeta">—</div>
      </div>
      <div class="stage" style="margin-top:8px"><video id="wVideo" controls autoplay loop playsinline></video></div>
      <div class="small muted" style="margin-top:6px">Preview URL: <code id="urlPreview"></code></div>
      <div class="small muted" style="margin-top:2px">Standby URL: <code id="urlStandby"></code></div>
    </section>
  </main>
  <div class="toasts"></div>

<script>
const toast=(m,k="ok",t=2000)=>{const w=document.querySelector('.toasts');const d=document.createElement('div');d.className=`toast ${k}`;d.textContent=m;w.appendChild(d);setTimeout(()=>d.remove(),t)}
const pick=(o,ks,fb=null)=>{for(const k of ks){if(o&&o[k]!=null)return o[k]}return fb}
let PRESENTERS=[], CURRENT=null, rec, recChunks=[], recBlob=null;

async function loadPresenters(){
  const manual = document.getElementById('jsonUrl').value.trim();
  const envDefault = (window.PRESENTERS_JSON||'').trim();
  const cands = [manual, 'presenters.json', '/development/presenters.json', envDefault || 'https://botsrhere.space/development/presenters.json'].filter(Boolean);
  let last;
  for(const u of cands){
    try{
      const r=await fetch(u,{cache:"no-store"}); if(!r.ok) throw new Error(`HTTP ${r.status}`);
      const j=await r.json(); const arr=Array.isArray(j)?j:(Array.isArray(j.presenters)?j.presenters:[]);
      if(arr.length){ toast(`Loaded ${arr.length} presenters`); return arr; }
    }catch(e){ last=e; }
  }
  throw last||new Error('No data');
}
function norm(p,i=0){
  const id=String(pick(p,['presenter_id','id'],'item_'+i));
  const name=String(pick(p,['name','display_name','title'],id));
  const preview=String(pick(p,['talking_preview_url','preview_url','previewUrl'],'')); // talking
  const idle=String(pick(p,['idle_video','standby_video','idle'],''));                 // standby
  const thumb=String(pick(p,['thumbnail_url','thumbnail','image_url','image'],''));
  return {id,name,preview,idle,thumb,raw:p};
}
function renderThumbs(list){
  const wrap=document.getElementById('thumbs'); wrap.innerHTML='';
  list.forEach((p,idx)=>{
    const el=document.createElement('div'); el.className='thumb'; el.dataset.id=p.id;
    el.innerHTML=`<img src="${p.thumb||''}" crossorigin="anonymous"><div class="n">${p.name}</div>`;
    el.onclick=()=>selectPresenter(p.id,true);
    wrap.appendChild(el);
    if(idx===0) el.classList.add('active');
  });
}
function selectPresenter(id,userGesture=false){
  const p=PRESENTERS.find(x=>x.id===id); if(!p) return; CURRENT=p;
  document.querySelectorAll('.thumb').forEach(t=>t.classList.toggle('active',t.dataset.id===id));
  document.getElementById('mName').textContent=p.name; document.getElementById('mId').textContent=p.id;
  document.getElementById('webMeta').textContent=`${p.name} • ${p.id}`;
  document.getElementById('urlPreview').textContent=p.preview||'(none)';
  document.getElementById('urlStandby').textContent=p.idle||'(none)';
  const m=document.getElementById('mVideo'); const w=document.getElementById('wVideo');
  m.src=p.preview||p.idle||''; w.src=m.src; m.load(); w.load();
  if(userGesture){ m.play().catch(()=>{}); w.play().catch(()=>{}); }
}
async function boot(){ try{
  PRESENTERS=(await loadPresenters()).map(norm);
  renderThumbs(PRESENTERS);
  if(PRESENTERS.length) selectPresenter(PRESENTERS[0].id,false);
}catch(e){ console.error(e); toast(e.message||e,'err'); } }
document.addEventListener('DOMContentLoaded', boot);
document.getElementById('btnReload').onclick=boot;

// Recording
document.getElementById('btnRec').onclick=async ()=>{
  if(rec && rec.state==='recording'){ rec.stop(); return; }
  const stream=await navigator.mediaDevices.getUserMedia({audio:true});
  rec=new MediaRecorder(stream); recChunks=[]; rec.ondataavailable=e=>recChunks.push(e.data);
  rec.onstop=()=>{ recBlob=new Blob(recChunks,{type:'audio/webm'}); const a=document.getElementById('recPreview'); a.src=URL.createObjectURL(recBlob); a.style.display='block'; };
  rec.start(); toast('Recording… tap again to stop');
};
document.getElementById('btnGen').onclick=async ()=>{
  if(!CURRENT){ toast('Pick a presenter','err'); return; }
  const audioInput=document.getElementById('audioFile');
  const fd=new FormData();
  fd.append('image_url', CURRENT.raw.image_url || CURRENT.raw.image || CURRENT.thumb || '');
  if(audioInput.files[0]) fd.append('audio_file', audioInput.files[0], audioInput.files[0].name);
  else if(recBlob) fd.append('audio_file', recBlob, 'recording.webm');
  else { toast('Upload or record audio first','err'); return; }

  toast('Generating via Wav2Lip… please wait');
  const res=await fetch('/api/lipsync/wav2lip', { method:'POST', body:fd });
  if(!res.ok){ toast('Generation failed','err'); return; }
  const data=await res.json();
  const url=data.video_url;
  if(!url){ toast('No video_url returned','err'); return; }
  document.getElementById('mVideo').src=url;
  document.getElementById('wVideo').src=url;
  toast('Done ✔');
};
</script>
<script>
  // Expose env default from server if set (injected by Express is not available in static, so leave blank here).
  window.PRESENTERS_JSON = "";
</script>
</body>
</html>
EOF

# ---------- lipsync (FastAPI + Wav2Lip) ----------
cat > lipsync/requirements.txt <<'EOF'
fastapi==0.111.0
uvicorn[standard]==0.30.0
python-multipart==0.0.9
requests==2.32.3
numpy
torch
opencv-python
librosa
scipy
audioread
gdown
EOF

cat > lipsync/Dockerfile <<'EOF'
FROM python:3.10-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/Rudrabha/Wav2Lip.git /app/Wav2Lip
COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt
COPY app.py /app/app.py
COPY run_wav2lip.py /app/run_wav2lip.py
COPY download_models.py /app/download_models.py
RUN mkdir -p /app/inputs /app/outputs /app/Wav2Lip/checkpoints
RUN python /app/download_models.py || true
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > lipsync/download_models.py <<'EOF'
import os, subprocess, sys
CKPT_DIR = "/app/Wav2Lip/checkpoints"
os.makedirs(CKPT_DIR, exist_ok=True)
def gdown(id_or_url, out):
    subprocess.run([sys.executable, "-m", "gdown", "--fuzzy", "-O", out, id_or_url], check=True)
def ensure(file, url):
    if not os.path.exists(file) or os.path.getsize(file) < 1000:
        gdown(url, file)
def main():
    ensure(f"{CKPT_DIR}/wav2lip_gan.pth","https://drive.google.com/uc?id=1dw78ZkUM7F3afPNv7ZfN2KX2MXj1N3Ty")
    ensure(f"{CKPT_DIR}/s3fd.pth","https://drive.google.com/uc?id=1l5Q9aBN-8lY1oCEN0zE5ZbVwVQh0QZ7x")
if __name__ == "__main__":
    try:
        main(); print("Models ready.")
    except Exception as e:
        print("Model download failed (will retry at runtime):", e); sys.exit(0)
EOF

cat > lipsync/run_wav2lip.py <<'EOF'
import os, subprocess, uuid, sys
W2L = "/app/Wav2Lip"
CKPT = f"{W2L}/checkpoints/wav2lip_gan.pth"
S3FD = f"{W2L}/checkpoints/s3fd.pth"
def ensure_models():
    if not (os.path.exists(CKPT) and os.path.exists(S3FD)):
        from download_models import main as dl; dl()
def run(face_path:str, audio_path:str) -> str:
    ensure_models()
    out = f"/app/outputs/{uuid.uuid4().hex}.mp4"
    cmd = [sys.executable, f"{W2L}/inference.py", "--checkpoint_path", CKPT,
           "--face", face_path, "--audio", audio_path, "--outfile", out,
           "--pads","0","10","0","0"]
    print("Running:", " ".join(cmd)); subprocess.run(cmd, check=True)
    return out
EOF

cat > lipsync/app.py <<'EOF'
import os, uuid, requests, shutil
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from run_wav2lip import run as run_w2l
PORT = int(os.getenv("PORT", "8000"))
IN_DIR = "/app/inputs"; OUT_DIR = "/app/outputs"
os.makedirs(IN_DIR, exist_ok=True); os.makedirs(OUT_DIR, exist_ok=True)
app = FastAPI(title="BotsRHere Lipsync Service")
app.mount("/files", StaticFiles(directory=OUT_DIR), name="files")
def download(url:str, ext:str) -> str:
    local = os.path.join(IN_DIR, f"{uuid.uuid4().hex}.{ext}")
    with requests.get(url, stream=True, timeout=60) as r:
        r.raise_for_status()
        with open(local, "wb") as f: shutil.copyfileobj(r.raw, f)
    return local
@app.post("/wav2lip")
async def wav2lip(
    image_url: str = Form(default=""),
    audio_url: str = Form(default=""),
    image_file: UploadFile = File(default=None),
    audio_file: UploadFile = File(default=None)
):
    try:
        if image_file:
            img_path = os.path.join(IN_DIR, f"{uuid.uuid4().hex}_{image_file.filename}")
            with open(img_path, "wb") as f: f.write(await image_file.read())
        elif image_url:
            img_path = download(image_url, "png")
        else:
            return JSONResponse({"error":"missing image"}, status_code=400)
        if audio_file:
            aud_path = os.path.join(IN_DIR, f"{uuid.uuid4().hex}_{audio_file.filename}")
            with open(aud_path, "wb") as f: f.write(await audio_file.read())
        elif audio_url:
            aud_path = download(audio_url, "wav")
        else:
            return JSONResponse({"error":"missing audio"}, status_code=400)
        out_path = run_w2l(img_path, aud_path)
        return {"video_url": f"/api/lipsync/files/{os.path.basename(out_path)}"}
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)
EOF

# ---------- git init ----------
echo "▶ Initializing git repo…"
git init -b main >/dev/null
git add .
git commit -m "feat: bootstrap BotsRHere realtime + Wav2Lip stack" >/dev/null

# ---------- create GitHub repo ----------
echo "▶ Creating GitHub repo…"
payload=$(jq -n --arg name "$REPO" --arg vis "$VISIBILITY" '{name:$name, private:( $vis=="private")}')
# Try user endpoint first
resp=$(curl -fsS -X POST -H "Authorization: Bearer '"$GH_TOKEN"'" -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos -d "$payload" || true)
# If already exists or user cannot, try org
if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
  :
else
  resp=$(curl -fsS -X POST -H "Authorization: Bearer '"$GH_TOKEN"'" -H "Accept: application/vnd.github+json" \
    https://api.github.com/orgs/"$OWNER"/repos -d "$payload" || true)
fi
repo_url=$(echo "$resp" | jq -r '.html_url // empty')
clone_url=$(echo "$resp" | jq -r '.clone_url // empty')
if [ -z "$repo_url" ] || [ -z "$clone_url" ]; then
  # Repo may already exist; verify
  echo "⚠ Could not create repo via API. Checking if it exists…"
  resp2=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/"$OWNER"/"$REPO" || true)
  repo_url=$(echo "$resp2" | jq -r '.html_url // empty')
  clone_url=$(echo "$resp2" | jq -r '.clone_url // empty')
  [ -n "$repo_url" ] || die "Failed to create or find repo $OWNER/$REPO"
fi
echo "   Repo: $repo_url"

# ---------- push ----------
echo "▶ Pushing code to GitHub…"
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "$clone_url"
git -c http.extraheader="Authorization: Bearer $GH_TOKEN" push -u origin main

# ---------- .env ----------
echo "▶ Writing .env with defaults…"
cp .env.example .env

# ---------- local build test (optional) ----------
if confirm "Build locally with Docker now (sanity check)?"; then
  $compose build
else
  echo "Skipping local build."
fi

# ---------- Coolify deploy ----------
if [ -n "$COOLIFY_URL" ]; then
  echo "▶ Attempting Coolify auto-deploy (compose)…"
  echo "   NOTE: Coolify has multiple API versions. If this fails, use the UI with this repo."
  # We can't assume a stable Coolify API path; print instructions + try a generic ping.
  # Ping
  if curl -fsS -H "Authorization: Bearer $COOLIFY_TOKEN" "$COOLIFY_URL/api" >/dev/null 2>&1; then
    echo "   Connected to Coolify API at $COOLIFY_URL"
    echo "   Please create the app in Coolify UI with:"
    echo "     - Create ➜ Application ➜ Public Git Repository"
    echo "     - Repo: $repo_url"
    echo "     - Build Pack: Dockerfile/Compose ➜ select docker-compose.yml"
    echo "     - Expose port: 3000"
    echo "     - Env file: use .env"
    echo "   (If you want me to automate this via API, provide your Coolify API endpoint details and I’ll extend the script.)"
  else
    echo "⚠ Could not reach Coolify API at $COOLIFY_URL. Skipping auto-deploy."
  fi
else
  echo "▶ Coolify: skipped (no URL/token)."
  echo "   Next: In Coolify UI ➜ Create Application ➜ Git repo = $repo_url ➜ Build Pack = Docker Compose ➜ Port 3000 ➜ Deploy."
fi

echo "✅ Done. Repo: $repo_url"
echo "   Local run (optional):"
echo "     cd $APP_DIR && $compose up -d"
