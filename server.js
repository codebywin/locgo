const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

function getLocalIPs() {
  const nets = os.networkInterfaces();
  const ips = [];
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (net.family === 'IPv4' && !net.internal && !net.address.startsWith('169.254')) {
        ips.push(net.address);
      }
    }
  }
  return ips;
}

const PORT = 8080;
const HOST = '0.0.0.0';
const UPLOADS_DIR = path.join(__dirname, 'test_uploads');

// Ensure uploads dir exists
if (!fs.existsSync(UPLOADS_DIR)) {
  fs.mkdirSync(UPLOADS_DIR, { recursive: true });
}

// Store upload batches in memory for dashboard
const uploadBatches = [];

// Helper: Parse multipart/form-data
function parseMultipart(buffer, boundary) {
  const boundaryBuf = Buffer.from('--' + boundary);
  const parts = [];
  let start = 0;

  while (true) {
    const idx = buffer.indexOf(boundaryBuf, start);
    if (idx === -1) break;

    if (start > 0) {
      // Extract part between start and idx (excluding \r\n before delimiter)
      let partEnd = idx;
      if (partEnd >= 2 && buffer[partEnd - 2] === 13 && buffer[partEnd - 1] === 10) {
        partEnd -= 2;
      }
      const partBuf = buffer.slice(start, partEnd);
      const headerEnd = partBuf.indexOf(Buffer.from('\r\n\r\n'));

      if (headerEnd !== -1) {
        const headerStr = partBuf.slice(0, headerEnd).toString('utf-8');
        const data = partBuf.slice(headerEnd + 4);

        const nameMatch = headerStr.match(/name="([^"]+)"/i);
        const filenameMatch = headerStr.match(/filename="([^"]+)"/i);

        parts.push({
          name: nameMatch ? nameMatch[1] : null,
          filename: filenameMatch ? filenameMatch[1] : null,
          data: data,
          text: data.toString('utf-8')
        });
      }
    }

    start = idx + boundaryBuf.length;
    // Check if end boundary '--'
    if (start + 1 < buffer.length && buffer[start] === 45 && buffer[start + 1] === 45) {
      break;
    }
    // Skip \r\n after boundary line
    if (start + 1 < buffer.length && buffer[start] === 13 && buffer[start + 1] === 10) {
      start += 2;
    }
  }
  return parts;
}

// Helper: Extract ZIP archive
function extractZip(zipPath, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  try {
    // Try bsdtar first (built-in on Windows 10/11)
    execSync(`tar -xf "${zipPath}" -C "${destDir}"`, { stdio: 'pipe' });
    return true;
  } catch (err1) {
    try {
      // Fallback to PowerShell Expand-Archive
      execSync(`powershell -NoProfile -Command "Expand-Archive -Path '${zipPath}' -DestinationPath '${destDir}' -Force"`, { stdio: 'pipe' });
      return true;
    } catch (err2) {
      console.error('[Mock Server] Error extracting zip:', err2.message);
      return false;
    }
  }
}

// HTTP Server
const server = http.createServer((req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;

  console.log(`[${new Date().toLocaleTimeString()}] ${req.method} ${pathname}`);

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // 1. Chunks Upload Endpoint (matching ACB trueID)
  if (req.method === 'POST' && pathname === '/file/chunk/upload') {
    const contentType = req.headers['content-type'] || '';
    const boundaryMatch = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
    const boundary = boundaryMatch ? (boundaryMatch[1] || boundaryMatch[2]) : null;

    if (!boundary) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 400, msg: 'Missing multipart boundary' }));
      return;
    }

    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      try {
        const bodyBuf = Buffer.concat(chunks);
        const parts = parseMultipart(bodyBuf, boundary);

        let businessParams = {};
        let fileData = null;

        for (const p of parts) {
          if (p.name === 'businessParams') {
            try {
              businessParams = JSON.parse(p.text);
            } catch (e) {
              console.warn('[Mock Server] Could not parse businessParams JSON:', p.text);
            }
          } else if (p.name === 'file') {
            fileData = p.data;
          }
        }

        const batchId = businessParams.batch || `batch_${Date.now()}`;
        const chunkIndex = parseInt(businessParams.chunkNumber || '0', 10);
        const totalChunks = parseInt(businessParams.totalChunks || '1', 10);
        const cardNumber = businessParams.card || 'Unknown';
        const userName = businessParams.name || '';
        const fileName = businessParams.fileName || 'acbtrueid.zip';

        const batchDir = path.join(UPLOADS_DIR, batchId);
        if (!fs.existsSync(batchDir)) {
          fs.mkdirSync(batchDir, { recursive: true });
        }

        // Save chunk
        if (fileData) {
          const chunkPath = path.join(batchDir, `chunk_${chunkIndex}`);
          fs.writeFileSync(chunkPath, fileData);
          console.log(`[Mock Server] Saved chunk ${chunkIndex + 1}/${totalChunks} (${fileData.length} bytes) for batch ${batchId}`);
        }

        // Check if all chunks received
        let allReceived = true;
        for (let i = 0; i < totalChunks; i++) {
          if (!fs.existsSync(path.join(batchDir, `chunk_${i}`))) {
            allReceived = false;
            break;
          }
        }

        if (allReceived) {
          console.log(`[Mock Server] >> ALL ${totalChunks} CHUNKS RECEIVED FOR BATCH ${batchId}! Assembling zip...`);
          const zipPath = path.join(batchDir, fileName);
          const writeStream = fs.createWriteStream(zipPath);

          for (let i = 0; i < totalChunks; i++) {
            const chunkFile = path.join(batchDir, `chunk_${i}`);
            const data = fs.readFileSync(chunkFile);
            writeStream.write(data);
          }
          writeStream.end();

          writeStream.on('finish', () => {
            const extractDir = path.join(batchDir, 'extracted');
            const success = extractZip(zipPath, extractDir);
            let images = [];

            if (success && fs.existsSync(extractDir)) {
              images = fs.readdirSync(extractDir)
                .filter(f => f.toLowerCase().endsWith('.jpg') || f.toLowerCase().endsWith('.jpeg') || f.toLowerCase().endsWith('.png'))
                .sort((a, b) => {
                  const numA = parseInt(a, 10) || 0;
                  const numB = parseInt(b, 10) || 0;
                  return numA - numB;
                });
              console.log(`[Mock Server] Extracted ${images.length} photos:`, images);
            }

            // Save or update batch record
            const existingIdx = uploadBatches.findIndex(b => b.batchId === batchId);
            const batchRecord = {
              batchId,
              cardNumber,
              userName,
              timestamp: new Date().toLocaleString(),
              totalChunks,
              images: images.map(img => `/uploads/${batchId}/extracted/${img}`)
            };

            if (existingIdx >= 0) {
              uploadBatches[existingIdx] = batchRecord;
            } else {
              uploadBatches.unshift(batchRecord);
            }
          });
        }

        // Standard ACB 200 OK Response
        const responseData = {
          code: 200,
          msg: 'success',
          data: {
            fileInfo: {
              fileId: 'mock_file_' + Date.now(),
              batchId: batchId,
              fileName: fileName
            }
          }
        };

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(responseData));
      } catch (err) {
        console.error('[Mock Server] Error handling upload:', err);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 500, msg: err.message }));
      }
    });
    return;
  }

  // 2. Resource Callback Endpoint
  if (req.method === 'POST' && pathname === '/collect/merchatnCard/saveBatchResource') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      console.log('[Mock Server] saveBatchResource callback received:', body.slice(0, 200));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 200, msg: 'success', data: {} }));
    });
    return;
  }

  // 3. API to fetch received batches
  if (req.method === 'GET' && pathname === '/api/batches') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ batches: uploadBatches }));
    return;
  }

  // 4. Static Serving of Extracted Images
  if (req.method === 'GET' && pathname.startsWith('/uploads/')) {
    const relPath = pathname.replace('/uploads/', '');
    const safePath = path.normalize(relPath).replace(/^(\.\.[\/\\])+/, '');
    const filePath = path.join(UPLOADS_DIR, safePath);

    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
      const ext = path.extname(filePath).toLowerCase();
      const mime = ext === '.png' ? 'image/png' : 'image/jpeg';
      res.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-cache' });
      fs.createReadStream(filePath).pipe(res);
      return;
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('File Not Found');
      return;
    }
  }

  // 5. Web UI Dashboard at GET /
  if (req.method === 'GET' && pathname === '/') {
    const localIPs = getLocalIPs();
    const primaryIP = localIPs[0] || 'localhost';
    const ipListStr = localIPs.map(ip => `http://${ip}:${PORT}`).join(' | ');
    const html = `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ACB Face Client - Local Mock Server</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; }
    body { background: #f0f4f8; color: #1e293b; padding: 24px; }
    .header { background: linear-gradient(135deg, #00427c 0%, #0077c8 100%); color: white; padding: 24px 32px; border-radius: 16px; margin-bottom: 24px; box-shadow: 0 4px 20px rgba(0, 66, 124, 0.2); }
    .header h1 { font-size: 26px; font-weight: 700; margin-bottom: 8px; display: flex; align-items: center; gap: 12px; }
    .status-badge { display: inline-flex; align-items: center; gap: 6px; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; }
    .pulse-dot { width: 10px; height: 10px; border-radius: 50%; background: #4ade80; animation: pulse 1.5s infinite; }
    @keyframes pulse { 0% { opacity: 0.4; } 50% { opacity: 1; } 100% { opacity: 0.4; } }
    .endpoint-box { background: rgba(0,0,0,0.15); padding: 10px 16px; border-radius: 8px; font-family: monospace; font-size: 14px; margin-top: 12px; word-break: break-all; }
    
    .batch-card { background: white; border-radius: 16px; padding: 24px; margin-bottom: 24px; box-shadow: 0 2px 10px rgba(0,0,0,0.05); border: 1px solid #e2e8f0; }
    .batch-header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #e2e8f0; padding-bottom: 14px; margin-bottom: 18px; }
    .batch-title { font-size: 18px; font-weight: 700; color: #00427c; }
    .batch-meta { font-size: 13px; color: #64748b; }
    .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 14px; }
    .photo-item { position: relative; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); aspect-ratio: 3/4; background: #e2e8f0; cursor: pointer; transition: transform 0.2s; }
    .photo-item:hover { transform: scale(1.04); }
    .photo-item img { width: 100%; height: 100%; object-fit: cover; }
    .round-tag { position: absolute; top: 8px; left: 8px; background: rgba(0,66,124,0.85); color: white; padding: 2px 8px; border-radius: 8px; font-size: 11px; font-weight: 700; backdrop-filter: blur(4px); }
    
    .empty-state { text-align: center; padding: 60px 20px; color: #94a3b8; }
    .empty-state svg { width: 64px; height: 64px; fill: #cbd5e1; margin-bottom: 16px; }
    
    /* Lightbox Modal */
    #modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.85); z-index: 999; justify-content: center; align-items: center; }
    #modal img { max-width: 90%; max-height: 90%; border-radius: 8px; box-shadow: 0 4px 30px rgba(0,0,0,0.5); }
  </style>
</head>
<body>
  <div class="header">
    <h1>
      <span>ACB Face Mock Verification Server</span>
      <span class="status-badge"><span class="pulse-dot"></span> ĐANG CHẠY</span>
    </h1>
    <p>Máy chủ nhận ảnh và xác thực 10 rounds eKYC từ ứng dụng iOS Face Client.</p>
    <div class="endpoint-box">
      Upload Target iPhone: <b>http://${primaryIP}:${PORT}/file/chunk/upload</b> (hoặc <b>http://localhost:${PORT}/file/chunk/upload</b>)
      <br><span style="font-size: 12px; opacity: 0.85;">IPs khả dụng: ${ipListStr}</span>
    </div>
  </div>

  <div id="batches-container">
    <div class="empty-state">
      <p>Chưa có dữ liệu upload nào. Hãy mở ứng dụng ACBFace trên iPhone, nhập số thẻ và để camera tự động nhận diện!</p>
    </div>
  </div>

  <div id="modal" onclick="closeModal()">
    <img id="modal-img" src="" alt="Zoomed Face">
  </div>

  <script>
    function openModal(src) {
      document.getElementById('modal-img').src = src;
      document.getElementById('modal').style.display = 'flex';
    }
    function closeModal() {
      document.getElementById('modal').style.display = 'none';
    }

    async function pollBatches() {
      try {
        const res = await fetch('/api/batches');
        const data = await res.json();
        const container = document.getElementById('batches-container');

        if (!data.batches || data.batches.length === 0) {
          container.innerHTML = \`
            <div class="empty-state">
              <p>Chưa có dữ liệu upload nào. Hãy mở ứng dụng ACBFace trên iPhone, nhập số thẻ và để camera tự động nhận diện!</p>
            </div>
          \`;
          return;
        }

        let html = '';
        data.batches.forEach(b => {
          html += \`
            <div class="batch-card">
              <div class="batch-header">
                <div>
                  <div class="batch-title">Số thẻ: \${b.cardNumber || 'Không có'} \${b.userName ? '(' + b.userName + ')' : ''}</div>
                  <div class="batch-meta">Batch ID: \${b.batchId} | Thời gian: \${b.timestamp} | Số phần: \${b.totalChunks}</div>
                </div>
                <div>
                  <span style="background: #e0f2fe; color: #0369a1; padding: 6px 14px; border-radius: 20px; font-weight: 700; font-size: 13px;">
                    \${b.images.length}/10 Ảnh Hoàn Tất
                  </span>
                </div>
              </div>
              <div class="gallery">
          \`;

          b.images.forEach((imgUrl, i) => {
            html += \`
              <div class="photo-item" onclick="openModal('\${imgUrl}')">
                <span class="round-tag">Ảnh \${i + 1}</span>
                <img src="\${imgUrl}" alt="Ảnh \${i + 1}" loading="lazy">
              </div>
            \`;
          });

          html += \`
              </div>
            </div>
          \`;
        });

        container.innerHTML = html;
      } catch (err) {
        console.error('Lỗi lấy danh sách batches:', err);
      }
    }

    setInterval(pollBatches, 2000);
    pollBatches();
  </script>
</body>
</html>`;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

server.listen(PORT, HOST, () => {
  console.log('====================================================');
  console.log(`[ACB Mock Server] Running at http://${HOST}:${PORT}`);
  console.log(`[ACB Mock Server] Web Dashboard: http://localhost:${PORT}`);
  console.log(`[ACB Mock Server] iPhone Endpoint: http://192.168.1.135:${PORT}`);
  console.log('====================================================');
});
