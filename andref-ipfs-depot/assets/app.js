// The upload token is the last path segment of /u/<token>.
const token = location.pathname.split("/").pop();

const fileInput = document.getElementById("file");
const choose = document.getElementById("choose");
const submit = document.getElementById("submit");
const filename = document.getElementById("filename");
const statusBox = document.getElementById("status");
const statusText = document.getElementById("status-text");
const progressWrap = document.getElementById("progress-wrap");
const progressBar = document.getElementById("progress-bar");
const result = document.getElementById("result");

choose.addEventListener("click", () => fileInput.click());

fileInput.addEventListener("change", () => {
  const f = fileInput.files[0];
  filename.textContent = f ? f.name : "";
  submit.disabled = !f;
  result.className = "result hidden";
});

submit.addEventListener("click", () => {
  const file = fileInput.files[0];
  if (!file) return;

  submit.disabled = true;
  choose.disabled = true;
  result.className = "result hidden";
  showStatus("Uploading…");
  progressWrap.className = "progress";
  progressBar.style.width = "0";

  const form = new FormData();
  form.append("file", file, file.name);

  // XMLHttpRequest (not fetch) gives real upload progress via upload.onprogress.
  const xhr = new XMLHttpRequest();
  xhr.open("POST", `/api/upload/${token}`);

  xhr.upload.addEventListener("progress", (e) => {
    if (!e.lengthComputable) return;
    const pct = Math.round((e.loaded / e.total) * 100);
    progressBar.style.width = pct + "%";
    statusText.textContent = `Uploading… ${pct}%`;
  });

  // Once the body is fully sent, the backend is hashing + pinning to IPFS.
  xhr.upload.addEventListener("load", () => {
    progressWrap.className = "progress hidden";
    showStatus("Pinning to IPFS…");
  });

  xhr.addEventListener("load", () => {
    hideStatus();
    choose.disabled = false;
    if (xhr.status >= 200 && xhr.status < 300) {
      const { url } = JSON.parse(xhr.responseText);
      showResult(url);
    } else {
      submit.disabled = false;
      showError(xhr.responseText || `Upload failed (${xhr.status})`);
    }
  });

  xhr.addEventListener("error", () => {
    hideStatus();
    choose.disabled = false;
    submit.disabled = false;
    showError("Network error");
  });

  xhr.send(form);
});

function showStatus(text) {
  statusText.textContent = text;
  statusBox.className = "status";
}

function hideStatus() {
  statusBox.className = "status hidden";
}

function showResult(url) {
  result.className = "result success";
  const link = document.createElement("a");
  link.href = url;
  link.textContent = url;
  link.target = "_blank";
  link.rel = "noopener";
  const note = document.createElement("p");
  note.className = "hint";
  note.textContent = "Also posted to the channel.";
  result.replaceChildren("Uploaded ✅", document.createElement("br"), link, note);
  // Best-effort inline preview for images.
  if (/\.(png|jpe?g|gif|webp|avif|svg)$/i.test(file_name())) {
    const img = document.createElement("img");
    img.src = url;
    img.alt = "preview";
    result.appendChild(img);
  }
}

function showError(msg) {
  result.className = "result error";
  result.textContent = msg;
}

function file_name() {
  return fileInput.files[0] ? fileInput.files[0].name : "";
}
