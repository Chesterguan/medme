import { useCallback, useEffect, useState } from "react";
import "./App.css";
import { api } from "./api";
import type {
  TimelineGroup,
  ImportOutcome,
  ShareResult,
  PatientProfile,
} from "./types";

// doc_type / encounter kind → 中文标签(见 core-model types.rs)
const DOC_LABEL: Record<string, string> = {
  lab_report: "化验",
  imaging_report: "影像",
  discharge_summary: "出院小结",
  prescription: "处方",
  clinical_note: "病历",
  pathology: "病理",
  surgery: "手术",
  other: "其他",
  unknown: "待归类",
};
const KIND_LABEL: Record<string, string> = {
  inpatient: "住院",
  outpatient: "门诊",
  emergency: "急诊",
  exam: "检查",
};

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
    d.getDate(),
  ).padStart(2, "0")}`;
}

function groupTitle(g: TimelineGroup): string {
  if (g.group_type === "encounter") {
    const e = g.encounter;
    const kind = KIND_LABEL[e.kind] ?? e.kind;
    return e.provider ? `${kind} · ${e.provider}` : kind;
  }
  return g.doc.title ?? DOC_LABEL[g.doc.doc_type] ?? "记录";
}

function groupDate(g: TimelineGroup): string {
  return fmtDate(g.group_type === "encounter" ? g.encounter.start_date : g.doc.doc_date);
}

function groupDesc(g: TimelineGroup): string {
  if (g.group_type === "encounter") {
    const kinds = new Set(g.docs.map((d) => DOC_LABEL[d.doc_type] ?? d.doc_type));
    const parts = [`${g.encounter.doc_count} 份记录`, ...Array.from(kinds).slice(0, 3)];
    if (g.encounter.transferred) parts.push("转院");
    return parts.join(" · ");
  }
  return DOC_LABEL[g.doc.doc_type] ?? g.doc.doc_type;
}

type Tab = "capture" | "archive";

export default function App() {
  const [tab, setTab] = useState<Tab>("capture");
  const [groups, setGroups] = useState<TimelineGroup[]>([]);
  const [profile, setProfile] = useState<PatientProfile | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [lastImport, setLastImport] = useState<ImportOutcome | null>(null);
  const [share, setShare] = useState<ShareResult | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [g, p] = await Promise.all([api.loadArchive(), api.getPatientProfile()]);
      setGroups(g);
      setProfile(p);
    } catch (e) {
      console.error("refresh failed", e);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // 采集:通过系统文件/相册选择器拿到沙盒路径,交给 pipeline ingest。
  // 说明:iOS 上用 tauri-plugin-dialog 的 open() 打开原生选择器,返回沙盒内可读路径。
  // 真正的「相机内拍摄」需相机插件,列为 M2。
  const capture = useCallback(async () => {
    setShare(null);
    try {
      // 延迟加载 dialog 插件:仅在用户点击采集时才引入,避免顶层导入
      // 在插件未就绪时拖垮首屏渲染。
      const { open } = await import("@tauri-apps/plugin-dialog");
      const picked = await open({
        multiple: false,
        title: "选择病历 / 化验单 / 报告",
        filters: [{ name: "病历文件", extensions: ["jpg", "jpeg", "png", "heic", "pdf", "dcm"] }],
      });
      if (!picked || Array.isArray(picked)) return;
      setBusy("正在识别并入库…");
      const outcome = await api.ingestFile(picked as string);
      setLastImport(outcome);
      await refresh();
    } catch (e) {
      console.error("capture failed", e);
      alert(`采集失败:${e}`);
    } finally {
      setBusy(null);
    }
  }, [refresh]);

  const loadDemo = useCallback(async () => {
    setShare(null);
    try {
      setBusy("正在载入示例数据…");
      const n = await api.loadDemoData();
      setLastImport({ name: `示例数据 ${n} 份`, source_file_id: 0, status: "new", doc_type: null });
      await refresh();
      setTab("archive");
    } catch (e) {
      alert(`载入示例失败:${e}`);
    } finally {
      setBusy(null);
    }
  }, [refresh]);

  const doShare = useCallback(async () => {
    setLastImport(null);
    try {
      setBusy("正在生成端到端加密分享…");
      const r = await api.createShare(5);
      setShare(r);
    } catch (e) {
      alert(`生成分享失败:${e}`);
    } finally {
      setBusy(null);
    }
  }, []);

  const initial = profile?.name?.[0] ?? "我";
  const recent = groups.slice(0, 4);

  return (
    <div className="app">
      <div className="appbar">
        <div className="brand">
          <span className="logo">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
              <path d="M9 12l2 2 4-4" />
            </svg>
          </span>
          医我
        </div>
        <div className="who">{initial}</div>
      </div>

      {tab === "capture" ? (
        <div className="body">
          <button className="shoot" onClick={capture} disabled={!!busy}>
            <div className="cam">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z" />
                <circle cx="12" cy="13" r="3.2" />
              </svg>
            </div>
            <b>拍照存档</b>
            <span>病历 · 化验单 · 报告,拍下或选图就存</span>
          </button>

          <div className="sect">最近导入</div>
          {recent.length === 0 ? (
            <div className="card">
              <div className="ic">📄</div>
              <div className="tx">
                <b>还没有记录</b>
                <span>点上方拍照,或载入示例数据试试</span>
              </div>
            </div>
          ) : (
            recent.map((g, i) => (
              <div className="card" key={i}>
                <div className="ic">{g.group_type === "encounter" ? "🏥" : "📄"}</div>
                <div className="tx">
                  <b>{groupTitle(g)}</b>
                  <span>{groupDesc(g)}</span>
                </div>
                <span className="meta">{groupDate(g)}</span>
              </div>
            ))
          )}

          <button className="btn ghost" onClick={loadDemo} disabled={!!busy}>
            载入示例数据(张建国)
          </button>
          <button className="btn primary" onClick={doShare} disabled={!!busy || (profile?.record_count ?? 0) === 0}>
            加密分享给医生
          </button>

          <div className="synced">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
              <path d="M20 6L9 17l-5-5" />
            </svg>
            数据保存在本机保险箱(iCloud 同步:v1.1)
          </div>
        </div>
      ) : (
        <div className="body">
          <div className="phead">
            <div className="avatar">{initial}</div>
            <div>
              <div className="nm">{profile?.name ?? "我的健康档案"}</div>
              <div className="sub">
                {[profile?.gender, profile?.age].filter(Boolean).join(" · ")}
                {profile ? `${profile.gender || profile.age ? " · " : ""}${profile.record_count} 份记录` : ""}
              </div>
            </div>
          </div>

          {groups.length === 0 ? (
            <div className="empty">
              <div className="big">🗂️</div>
              健康档案还是空的
              <br />
              去「拍照」页采集或载入示例数据
            </div>
          ) : (
            <div className="tl">
              {groups.map((g, i) => (
                <div className="item" key={i}>
                  <span className="dot" />
                  <div className="c">
                    <div className="top">
                      <b>{groupTitle(g)}</b>
                      <span className="d">{groupDate(g)}</span>
                    </div>
                    <div className="desc">
                      {groupDesc(g)}
                      {g.group_type === "document" && g.doc.slice_count ? (
                        <>
                          {" · "}
                          <span className="kind">影像 {g.doc.slice_count} 张</span>
                        </>
                      ) : null}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* 识别确认(M1 简版):入库后弹条,展示自动归类结果。完整「确认/纠正」页 = M2。 */}
      {lastImport && (
        <div className="toast" onClick={() => setLastImport(null)}>
          <div className={`h ${lastImport.status === "failed" ? "warn" : "ok"}`}>
            {lastImport.status === "failed" ? "⚠️ 未能识别" : "✅ 已识别入库"}
          </div>
          <div>
            <b>{lastImport.name}</b>
            {lastImport.doc_type ? ` · 归类为「${DOC_LABEL[lastImport.doc_type] ?? lastImport.doc_type}」` : ""}
          </div>
          <div className="note">
            自动归类完成。<small>点此关闭 · 完整的「确认 / 纠正」页为 M2</small>
          </div>
        </div>
      )}

      {/* 加密分享结果(M1 简版):展示口令 + 落盘路径。系统「分享」sheet 导出 = M2。 */}
      {share && (
        <div className="toast" onClick={() => setShare(null)}>
          <div className="h ok">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
              <path d="M20 6L9 17l-5-5" />
            </svg>
            已生成 · 端到端加密 · {share.record_count} 份
          </div>
          <div className="copyline">
            <span className="k">口令</span>
            <span className="v">{share.passphrase}</span>
          </div>
          <div className="note">
            数据在对方浏览器本地解密,不经服务器。文件已存到:
            <br />
            <small>{share.path}</small>
            <br />
            <small>系统「分享」导出为 M2</small>
          </div>
        </div>
      )}

      {busy && (
        <div className="toast">
          <div className="h">{busy}</div>
        </div>
      )}

      <div className="tabbar">
        <button className={`t ${tab === "capture" ? "on" : ""}`} onClick={() => setTab("capture")}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z" />
            <circle cx="12" cy="13" r="3" />
          </svg>
          拍照
        </button>
        <button className={`t ${tab === "archive" ? "on" : ""}`} onClick={() => setTab("archive")}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="8" y1="6" x2="21" y2="6" />
            <line x1="8" y1="12" x2="21" y2="12" />
            <line x1="8" y1="18" x2="21" y2="18" />
            <line x1="3" y1="6" x2="3.01" y2="6" />
            <line x1="3" y1="12" x2="3.01" y2="12" />
            <line x1="3" y1="18" x2="3.01" y2="18" />
          </svg>
          档案
        </button>
      </div>
    </div>
  );
}
