import AppKit

/// The page an iPhone opens from the QR code: pick photos and videos, and they upload to the
/// Mac one at a time with progress. Kept on the Home Screen, it opens like an app.
enum ReceivePage {
    static func html(macName: String, folderName: String) -> String {
        let mac = escape(macName)
        let folder = escape(folderName)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="apple-mobile-web-app-title" content="Send to Mac">
        <meta name="theme-color" content="#0E0E0E">
        <link rel="apple-touch-icon" href="/icon.png">
        <title>Send to \(mac)</title>
        <style>
          :root { color-scheme: dark; --bg:#0E0E0E; --card:#1A1A1A; --border:#2E2E2E; --text:#E7E7E7; --dim:#8A8A8A; --ok:#E7E7E7; --bad:#E27676; }
          * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
          html, body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.4 -apple-system, system-ui, sans-serif; }
          main { max-width: 560px; margin: 0 auto; padding: calc(env(safe-area-inset-top) + 28px) 16px calc(env(safe-area-inset-bottom) + 24px); }
          h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.02em; }
          .sub { color: var(--dim); font-size: 14px; margin: 0 0 22px; }
          .status { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--dim); margin-bottom: 18px; }
          .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim); flex: none; }
          .dot.on { background: #6EB8FF; } .dot.off { background: var(--bad); }
          label.pick { display: flex; align-items: center; justify-content: center; gap: 10px; width: 100%; height: 64px; border-radius: 16px;
                       background: var(--text); color: #0E0E0E; font-weight: 650; font-size: 18px; cursor: pointer; user-select: none; }
          label.pick:active { opacity: 0.8; }
          label.pick.busy { background: var(--card); color: var(--dim); border: 1px solid var(--border); pointer-events: none; }
          input[type=file] { display: none; }
          .summary { margin: 18px 2px 8px; font-size: 14px; color: var(--dim); min-height: 20px; }
          .bar { height: 4px; background: var(--border); border-radius: 2px; overflow: hidden; margin: 0 2px 16px; }
          .bar > div { height: 100%; width: 0; background: var(--text); transition: width .15s; }
          ul { list-style: none; margin: 0; padding: 0; border: 1px solid var(--border); border-radius: 14px; background: var(--card); overflow: hidden; }
          ul:empty { display: none; }
          li { display: flex; align-items: center; gap: 10px; padding: 11px 14px; font-size: 14px; border-top: 1px solid var(--border); }
          li:first-child { border-top: 0; }
          li .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          li .state { color: var(--dim); font-variant-numeric: tabular-nums; font-size: 13px; flex: none; }
          li.done .state { color: var(--ok); } li.failed .state { color: var(--bad); }
          .tip { margin-top: 22px; padding: 12px 14px; border: 1px dashed var(--border); border-radius: 12px; color: var(--dim); font-size: 13px; }
          .error { margin-top: 14px; color: var(--bad); font-size: 14px; }
        </style>
        </head>
        <body>
        <main>
          <h1 id="title" data-mac="\(mac)">Send to \(mac)</h1>
          <p class="sub">Photos and videos go to “\(folder)” on the Mac.</p>
          <div class="status"><span class="dot" id="dot"></span><span id="status">Checking connection…</span></div>
          <label class="pick" id="pick" for="files">Choose Photos &amp; Videos</label>
          <input id="files" type="file" multiple accept="image/*,image/heic,image/heif,video/*">
          <div class="summary" id="summary"></div>
          <div class="bar" id="bar" hidden><div id="fill"></div></div>
          <ul id="list"></ul>
          <div class="error" id="error" hidden></div>
          <div class="tip" id="tip" hidden>Keep this as an app: tap <b>Share</b>, then <b>Add to Home Screen</b>.</div>
        </main>
        <script>
        const token = new URLSearchParams(location.search).get('t') || '';
        const macName = document.getElementById('title').dataset.mac;
        const $ = id => document.getElementById(id);
        const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches;
        if (!standalone) $('tip').hidden = false;

        function size(n) {
          if (n < 1024 * 1024) return Math.max(1, Math.round(n / 1024)) + ' KB';
          if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
          return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
        }
        function setStatus(ok, text) {
          $('dot').className = 'dot ' + (ok ? 'on' : 'off');
          $('status').textContent = text;
        }
        async function ping() {
          try {
            const r = await fetch('/ping?t=' + encodeURIComponent(token), { cache: 'no-store' });
            setStatus(r.ok, r.ok ? 'Connected to ' + macName : 'This link is out of date. Scan the QR code in TheExplorer again.');
            return r.ok;
          } catch (e) {
            setStatus(false, 'Can’t reach the Mac. Is TheExplorer open, and are both on the same Wi-Fi?');
            return false;
          }
        }
        ping();
        document.addEventListener('visibilitychange', () => { if (!document.hidden) ping(); });

        function upload(file, row, done) {
          return new Promise(resolve => {
            const xhr = new XMLHttpRequest();
            const url = '/upload?t=' + encodeURIComponent(token) + '&name=' + encodeURIComponent(file.name || 'Photo')
              + '&modified=' + (file.lastModified || '');
            xhr.open('POST', url);
            xhr.upload.onprogress = e => {
              if (!e.lengthComputable) return;
              row.querySelector('.state').textContent = Math.floor(e.loaded / e.total * 100) + '%';
              done(e.loaded);
            };
            xhr.onload = () => resolve(xhr.status === 200 ? null : (xhr.responseText || ('Error ' + xhr.status)));
            xhr.onerror = () => resolve('Lost the connection to the Mac.');
            xhr.send(file);
          });
        }

        $('files').addEventListener('change', async e => {
          const files = Array.from(e.target.files || []);
          e.target.value = '';
          if (!files.length) return;
          $('error').hidden = true;
          $('list').innerHTML = '';
          const rows = files.map(f => {
            const li = document.createElement('li');
            li.innerHTML = '<span class="name"></span><span class="state">Waiting</span>';
            li.querySelector('.name').textContent = f.name || 'Photo';
            $('list').appendChild(li);
            return li;
          });
          const total = files.reduce((n, f) => n + f.size, 0);
          let finished = 0, sent = 0, failed = 0;
          $('pick').classList.add('busy');
          $('pick').textContent = 'Sending…';
          $('bar').hidden = false;
          let lock = null;
          try { lock = await navigator.wakeLock?.request('screen'); } catch (_) {}
          for (let i = 0; i < files.length; i++) {
            const row = rows[i];
            row.querySelector('.state').textContent = '0%';
            row.scrollIntoView({ block: 'nearest' });
            const error = await upload(files[i], row, loaded => {
              $('fill').style.width = ((finished + loaded) / total * 100) + '%';
              $('summary').textContent = 'Sending ' + (i + 1) + ' of ' + files.length + ' · ' + size(finished + loaded) + ' of ' + size(total);
            });
            finished += files[i].size;
            if (error) {
              failed++;
              row.className = 'failed';
              row.querySelector('.state').textContent = 'Failed';
              $('error').hidden = false;
              $('error').textContent = error;
            } else {
              sent++;
              row.className = 'done';
              row.querySelector('.state').textContent = '✓';
            }
          }
          try { await lock?.release(); } catch (_) {}
          $('fill').style.width = '100%';
          $('summary').textContent = failed
            ? 'Sent ' + sent + ' of ' + files.length + '. ' + failed + ' failed.'
            : 'Sent ' + sent + (sent === 1 ? ' item' : ' items') + ' · ' + size(total);
          $('pick').classList.remove('busy');
          $('pick').textContent = 'Choose More';
          ping();
        });
        </script>
        </body>
        </html>
        """
    }

    static let forbidden = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Send to Mac</title></head>
    <body style="background:#0E0E0E;color:#E7E7E7;font:16px -apple-system,system-ui,sans-serif;padding:40px 20px">
    <h2>This link is out of date</h2><p style="color:#8A8A8A">Open TheExplorer on your Mac, click “From iPhone” in the sidebar, and scan the QR code again.</p>
    </body></html>
    """

    /// TheExplorer's icon for the Home Screen, made once.
    static let icon: Data = {
        let side = 180
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        appIcon.draw(in: NSRect(x: 10, y: 10, width: side - 20, height: side - 20))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
