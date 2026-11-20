// Builds the Windows recorder reproducibly and packages it.
//
//   node build/build-windows.mjs [--no-selftest]
//
// 1. Fetches two pinned NuGet packages into .cache/ and checks their SHA-256: the Roslyn compiler
//    (Microsoft.Net.Compilers.Toolset) and the .NET Framework 4.8 reference assemblies. Nothing from the machine's own
//    .NET install is used, so the exe does not depend on which Windows build or SDK compiled it.
// 2. Compiles windows/AgentRecorder.cs with -deterministic and -pathmap:<repo>=/src (no timestamps, no random MVID, no
//    local paths), C# 5 language level (the same source still builds with the in-box csc.exe). Same source + same pinned
//    compiler => byte-identical AgentRecorder.exe on any machine. On Windows: tasks/net472/csc.exe. Elsewhere:
//    `dotnet tasks/netcore/bincore/csc.dll` (needs a .NET 9+ runtime; the selftest is skipped off Windows).
// 3. Runs `AgentRecorder.exe --selftest` (Windows only).
// 4. Writes dist/: AgentRecorder.exe, recorder.zip (fixed timestamps), install.ps1 (rendered from
//    windows/install.template.ps1 with the zip hash, version and the pinned ffmpeg download), uninstall.ps1 and
//    hashes.json. scripts/sha256sums.sh turns dist/ into SHA256SUMS.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateRawSync, inflateRawSync } from "node:zlib";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const win = join(root, "windows");
const dist = join(root, "dist");
const cache = join(root, ".cache", "nuget");
const selftest = process.platform === "win32" && !process.argv.includes("--no-selftest");

// Pinned toolchain (nuget.org packages; SHA-256 of the .nupkg bytes).
const TOOLSET = {
  id: "microsoft.net.compilers.toolset",
  version: "4.14.0",
  sha256: "941A9CF3EA618D88D01A3DD6B1A45A06BCF07716A9F81CE4031CAA3EDD24A845",
};
const REFS = {
  id: "microsoft.netframework.referenceassemblies.net48",
  version: "1.0.3",
  sha256: "8A7E348538E7EB91351696911689F49E3D4F63F8BAB517432BBE159B8B1104A2",
};
const REF_DIR = "build/.NETFramework/v4.8/";
const REFERENCES = ["mscorlib.dll", "System.dll", "System.Core.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.Security.dll"];

// Pinned third-party download (gyan.dev build via GitHub release; digest from the release asset metadata).
const FFMPEG_URL = "https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip";
const FFMPEG_SHA256 = "60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA";

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex").toUpperCase();

/** `public const string Version = "x.y.z";` in AgentRecorder.cs: what the recorder says in its hello frame. */
function recorderVersion() {
  const m = /public const string Version = "(\d{1,3}\.\d{1,3}\.\d{1,3})";/.exec(readFileSync(join(win, "AgentRecorder.cs"), "utf8"));
  if (!m) throw new Error("Version constant not found in windows/AgentRecorder.cs");
  return m[1];
}

/** Downloads (once) and hash-checks a pinned .nupkg; returns its bytes. */
async function nupkg({ id, version, sha256: want }) {
  const file = join(cache, `${id}.${version}.nupkg`);
  let buf = existsSync(file) ? readFileSync(file) : null;
  if (!buf || sha256(buf) !== want) {
    const url = `https://api.nuget.org/v3-flatcontainer/${id}/${version}/${id}.${version}.nupkg`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    buf = Buffer.from(await res.arrayBuffer());
    if (sha256(buf) !== want) throw new Error(`${id} ${version}: SHA-256 mismatch (got ${sha256(buf)})`);
    mkdirSync(cache, { recursive: true });
    writeFileSync(file, buf);
  }
  return buf;
}

/** Extracts the entries under `prefix` from a zip (stored or deflate) into dir; returns dir. */
function unzip(buf, prefix, dir) {
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error("not a zip");
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(p + 10);
    const size = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.toString("utf8", p + 46, p + 46 + nameLen);
    p += 46 + nameLen + extraLen + commentLen;
    if (!name.startsWith(prefix) || name.endsWith("/") || name.includes("..")) continue;
    const dataAt = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const raw = buf.subarray(dataAt, dataAt + size);
    const data = method === 0 ? raw : method === 8 ? inflateRawSync(raw) : null;
    if (!data) throw new Error(`${name}: unsupported zip method ${method}`);
    const out = join(dir, name);
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, data);
  }
  return dir;
}

async function toolchain() {
  const tsDir = join(cache, `${TOOLSET.id}.${TOOLSET.version}`);
  const refDir = join(cache, `${REFS.id}.${REFS.version}`);
  if (!existsSync(join(tsDir, "tasks"))) unzip(await nupkg(TOOLSET), "tasks/", tsDir);
  if (!existsSync(join(refDir, REF_DIR))) unzip(await nupkg(REFS), REF_DIR, refDir);
  const csc =
    process.platform === "win32"
      ? { cmd: join(tsDir, "tasks", "net472", "csc.exe"), pre: [] }
      : { cmd: process.env.DOTNET ?? "dotnet", pre: [join(tsDir, "tasks", "netcore", "bincore", "csc.dll")] };
  return { csc, refs: REFERENCES.map((r) => join(refDir, REF_DIR, r)) };
}

async function compile() {
  const { csc, refs } = await toolchain();
  mkdirSync(dist, { recursive: true });
  const exe = join(dist, "AgentRecorder.exe");
  const r = spawnSync(
    csc.cmd,
    [
      ...csc.pre,
      "-nologo",
      "-noconfig",
      "-nostdlib+",
      "-deterministic+",
      `-pathmap:${root}=/src`,
      "-langversion:5",
      "-target:winexe",
      "-optimize+",
      "-platform:anycpu",
      `-out:${exe}`,
      `-win32manifest:${join(win, "AgentRecorder.manifest")}`,
      ...refs.map((r) => `-r:${r}`),
      join(win, "AgentRecorder.cs"),
    ],
    { encoding: "utf8" },
  );
  if (r.error) throw new Error(`could not run ${csc.cmd}: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`csc failed:\n${r.stdout}${r.stderr}`);
  if (!selftest) {
    console.warn(process.platform === "win32" ? "selftest skipped (--no-selftest)" : "selftest skipped (not Windows)");
    return "";
  }
  const t = spawnSync(exe, ["--selftest"], { encoding: "utf8" });
  if (t.status !== 0) throw new Error(`recorder selftest failed:\n${t.stdout}${t.stderr}`);
  return t.stdout;
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** Minimal deflate zip writer with fixed timestamps. */
function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const { name, data } of files) {
    const nameBuf = Buffer.from(name);
    const comp = deflateRawSync(data, { level: 9 });
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x21, 12); // 1980-01-01
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(comp.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(comp.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBuf, comp);
    centrals.push(central, nameBuf);
    offset += 30 + nameBuf.length + comp.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

const version = recorderVersion();
const selftestOut = await compile();
const exeBuf = readFileSync(join(dist, "AgentRecorder.exe"));

const uninstall = readFileSync(join(win, "uninstall.ps1"));
const zipBuf = zip([
  { name: "AgentRecorder.exe", data: exeBuf },
  { name: "AgentRecorder.exe.config", data: readFileSync(join(win, "AgentRecorder.exe.config")) },
  { name: "uninstall.ps1", data: uninstall },
]);
writeFileSync(join(dist, "recorder.zip"), zipBuf);
const zipHash = sha256(zipBuf);

const install = readFileSync(join(win, "install.template.ps1"), "utf8")
  .replaceAll("__RECORDER_ZIP_SHA256__", zipHash)
  .replaceAll("__RECORDER_VERSION__", version)
  .replaceAll("__FFMPEG_URL__", FFMPEG_URL)
  .replaceAll("__FFMPEG_SHA256__", FFMPEG_SHA256);
if (/__[A-Z0-9_]+__/.test(install)) throw new Error("install.ps1: placeholder left after rendering");
const installBuf = Buffer.from(install, "utf8");
writeFileSync(join(dist, "install.ps1"), installBuf);
copyFileSync(join(win, "uninstall.ps1"), join(dist, "uninstall.ps1"));
const installHash = sha256(installBuf);

const hashes = {
  recorder_version: version,
  agent_recorder_exe_sha256: sha256(exeBuf),
  recorder_zip_sha256: zipHash,
  install_ps1_sha256: installHash,
  compiler: `${TOOLSET.id} ${TOOLSET.version}`,
  reference_assemblies: `${REFS.id} ${REFS.version}`,
};
writeFileSync(join(dist, "hashes.json"), JSON.stringify(hashes, null, 2) + "\n");
if (selftestOut) console.log(selftestOut.trim());
console.log(`AgentRecorder.exe ${exeBuf.length} bytes sha256=${hashes.agent_recorder_exe_sha256}`);
console.log(`recorder.zip ${zipBuf.length} bytes sha256=${zipHash}`);
console.log(`install.ps1 sha256=${installHash} recorder ${version}`);
