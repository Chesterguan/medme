import { useEffect, useState } from "react";
import {
  UploadCloud,
  ScanLine,
  FolderOpen,
  Inbox,
  Download,
  FileDown,
  ShieldCheck,
  Copy,
  Check,
  Sparkles,
  Loader2,
} from "lucide-react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { listen } from "@tauri-apps/api/event";
import { api } from "../api";
import type { ImportOutcome } from "../types";

// 导入结果的状态色。改版前用了 emerald / slate / amber / sky / rose 五族;设计系统
// 的色板是封闭的,这里收敛到三档:成功=主色、无需处理=中性、要你看一眼=high /
// critical。区分靠**标签文字**,不靠颜色 —— 这是规范里「色盲用户靠 pill」那条。
const STATUS_META: Record<string, { label: string; cls: string }> = {
  new: { label: "新增并索引", cls: "text-seal-ink bg-seal-wash" },
  backfilled: { label: "补充索引", cls: "text-seal-ink bg-seal-wash" },
  deduped: { label: "已存在 · 去重", cls: "text-ink-2 bg-line-2" },
  stored_no_text: { label: "已保存 · 未识别到文字", cls: "text-high bg-high-wash" },
  instance_attached: { label: "已并入检查", cls: "text-seal-ink bg-seal-wash" },
  // 同一份文件再导一次:文档已存在、但当年有页缺文本层,这次顺手补上了
  // (见 pipeline::reindex_existing_document,#63b)。
  reindexed: { label: "已补充识别", cls: "text-seal-ink bg-seal-wash" },
  failed: { label: "导入失败", cls: "text-critical bg-critical-wash" },
};

export default function ImportView({ onImported }: { onImported: () => void }) {
  const [dragging, setDragging] = useState(false);
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<ImportOutcome[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [inboxPath, setInboxPath] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [exportMsg, setExportMsg] = useState<
    { kind: "ok"; text: string; path: string } | { kind: "err"; text: string } | null
  >(null);

  // 一键「加载示例数据」(张建国):给刚装好 .dmg 的测试者一个免找文件的试用入口
  const [demoLoading, setDemoLoading] = useState(false);
  const [demoMsg, setDemoMsg] = useState<
    { kind: "ok"; text: string } | { kind: "err"; text: string } | null
  >(null);

  const doLoadDemo = async () => {
    setDemoLoading(true);
    setDemoMsg(null);
    try {
      const n = await api.loadDemoData();
      onImported();
      setDemoMsg({ kind: "ok", text: `已加载 ${n} 份示例记录,可在生命时间线查看。` });
    } catch (e) {
      setDemoMsg({ kind: "err", text: `加载示例数据失败:${String(e)}` });
    } finally {
      setDemoLoading(false);
    }
  };

  // 加密分享
  const [shareDays, setShareDays] = useState(5);
  const [sharing, setSharing] = useState(false);
  const [copied, setCopied] = useState(false);
  const [shareResult, setShareResult] = useState<
    | { kind: "ok"; passphrase: string; count: number; days: number; path: string }
    | { kind: "err"; text: string }
    | null
  >(null);

  // 端到端加密分享:后端(Rust)弹原生「保存」对话框选保存路径 → 生成自包含加密 HTML
  // (含浏览器内查看器)→ 返回口令(需另行单独告知医生)与写入路径。数据零服务器,
  // 浏览器本地解密。安全:保存路径由后端从原生对话框获得,不再经 webview 传入。
  const doShare = async () => {
    const days = Number.isFinite(shareDays) && shareDays > 0 ? Math.floor(shareDays) : 5;
    setSharing(true);
    setShareResult(null);
    setCopied(false);
    try {
      const r = await api.createShare(days);
      if (!r) return; // 用户取消了保存对话框
      setShareResult({
        kind: "ok",
        passphrase: r.passphrase,
        count: r.record_count,
        days,
        path: r.path,
      });
    } catch (e) {
      setShareResult({ kind: "err", text: `生成失败:${String(e)}` });
    } finally {
      setSharing(false);
    }
  };

  const copyPass = async (pass: string) => {
    try {
      await navigator.clipboard.writeText(pass);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* 剪贴板不可用时忽略 —— 用户可手动选择复制 */
    }
  };

  useEffect(() => {
    api.getInboxPath().then(setInboxPath).catch(() => {});
  }, []);

  // 导出 v1:后端(Rust)弹原生「保存」对话框选保存路径 → 生成自包含 HTML → 浏览器可
  // 「打印 / 另存为 PDF」交给医生。安全:保存路径由后端从原生对话框获得,不再经 webview 传入。
  const doExport = async () => {
    setExporting(true);
    setExportMsg(null);
    try {
      const summary = await api.exportTimelineHtml();
      if (!summary) return; // 用户取消了保存对话框
      setExportMsg({
        kind: "ok",
        text: `已导出 ${summary.file_count} 份记录,可在浏览器打开后「打印 / 另存为 PDF」交给医生。`,
        path: summary.path,
      });
    } catch (e) {
      setExportMsg({ kind: "err", text: `导出失败:${String(e)}` });
    } finally {
      setExporting(false);
    }
  };

  // 拖放:只用 webview 事件驱动高亮动画;实际导入由 Rust 侧的拖放处理器完成(它拿到的
  // 是 OS 可信路径),完成后发 `import-results` 事件带回逐个文件结果。安全:webview 不再
  // 把(可能被 XSS 伪造的)路径传给后端读取。
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    getCurrentWebview()
      .onDragDropEvent((event) => {
        const p = event.payload;
        if (p.type === "enter" || p.type === "over") {
          setDragging(true);
        } else if (p.type === "leave") {
          setDragging(false);
        } else if (p.type === "drop") {
          setDragging(false);
          if ((p.paths ?? []).length) {
            setBusy(true);
            setError(null);
          }
        }
      })
      .then((f) => {
        unlisten = f;
      });
    return () => {
      if (unlisten) unlisten();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Rust 拖放处理器导入完成后带回的逐个文件结果(时间线刷新由 App 层的 vault-changed 负责)。
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    listen<ImportOutcome[]>("import-results", (event) => {
      setResults(event.payload);
      setBusy(false);
    }).then((f) => {
      unlisten = f;
    });
    return () => {
      if (unlisten) unlisten();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 「选择文件导入」:后端(Rust)弹出原生文件选择器并直接导入所选文件,返回逐个文件结果。
  const pickAndImport = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await api.importViaDialog();
      if (r.length) {
        setResults(r);
        onImported();
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
      <div className="max-w-3xl mx-auto">
        <h1 className="text-display font-bold text-ink mb-6">导入 · 导出</h1>

        {/* 一键试用:免找文件,直接加载内置的张建国示例数据集。
            改版前整块是紫色(violet,不在色板里),按钮也是紫色实心 —— 和下面
            的蓝、绿按钮抢主次。现在退成普通卡 + 次级按钮。 */}
        <div className="med-card p-5 mb-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <Sparkles className="w-5 h-5 text-seal" /> 一键试用
          </div>
          <div className="text-body text-ink-2 mb-3">
            还没有自己的病历?加载内置的<b className="text-ink">张建国</b>示例数据集
            (含检验报告、门诊病历、处方、影像检查等),立即体验完整的生命时间线。
            <br />
            <span className="text-secondary text-ink-3">
              示例数据,可随时到「设置 → 清空保险箱」删除重来。
            </span>
          </div>
          <button
            type="button"
            onClick={doLoadDemo}
            disabled={demoLoading}
            className="med-btn med-btn-2 med-focusable"
          >
            {demoLoading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <Sparkles className="w-4 h-4" />
            )}
            {demoLoading ? "加载中…" : "加载示例数据(张建国)"}
          </button>
          {demoMsg && (
            <div
              className={`mt-3 rounded-block px-4 py-2.5 text-body break-all ${
                demoMsg.kind === "ok"
                  ? "bg-seal-wash text-seal-ink"
                  : "bg-critical-wash text-critical"
              }`}
            >
              {demoMsg.text}
            </div>
          )}
        </div>

        <div
          className={`rounded-card border-2 border-dashed p-12 text-center transition-colors ${
            dragging ? "border-seal bg-seal-wash" : "border-line bg-surface"
          }`}
        >
          <UploadCloud
            className={`w-12 h-12 mx-auto mb-4 ${dragging ? "text-seal" : "text-ink-3"}`}
          />
          <div className="text-subtitle font-semibold text-ink">
            {busy ? "正在导入…" : dragging ? "松开以导入" : "把病历文件拖到这里"}
          </div>
          <div className="text-secondary text-ink-3 mt-2">
            PDF · 图片(PNG / JPG / TIFF / HEIC)· TXT · DICOM · 原始文件永久保存,自动去重
          </div>
          <div className="text-secondary text-ink-3 mt-1">
            也可以直接拖入一整个文件夹(例如一台 CT/MRI 的 DICOM 文件夹),里面的文件会被自动全部导入
          </div>
          <div className="mt-5">
            {/* 这一屏唯一的主按钮:导入才是这个页面存在的理由 */}
            <button
              type="button"
              onClick={pickAndImport}
              disabled={busy}
              className="med-btn med-btn-1 med-focusable"
            >
              <FolderOpen className="w-4 h-4" /> 选择文件导入
            </button>
          </div>
        </div>

        {/* 自动收件箱(Watch Folder):手机拍照云同步到这里即自动入库 */}
        <div className="med-card mt-5 p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <Inbox className="w-5 h-5 text-seal" /> 自动收件箱
          </div>
          <div className="text-body text-ink-2 mb-3">
            手机拍照存到这里(或其云同步目录)即自动入库,无需手动导入。
          </div>
          {/* 卡内分块 → 14px 圆角(比卡片的 20px 小一档) */}
          <div className="med-block flex items-center justify-between gap-3 px-4 py-2.5">
            <span className="text-secondary font-mono text-ink-2 truncate">
              {inboxPath ?? "加载中…"}
            </span>
            <button
              type="button"
              onClick={() => api.openInbox().catch((e) => setError(String(e)))}
              className="med-focusable shrink-0 flex items-center gap-1.5 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
            >
              <FolderOpen className="w-3.5 h-3.5" /> 打开收件箱文件夹
            </button>
          </div>
        </div>

        {/* 用户引导:怎样获得最准的识别 */}
        <div className="med-card mt-5 p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-3">
            <ScanLine className="w-5 h-5 text-seal" /> 怎样识别最准
          </div>
          <ul className="space-y-2.5 text-body text-ink-2">
            <li className="flex gap-2">
              <span className="text-seal font-bold shrink-0 tabular-nums">①</span>
              <span>
                <b className="text-ink">优先用扫描 App</b>:扫描全能王 · 微信「扫一扫」文档模式 ·
                iOS 备忘录/文件扫描 —— 自动纠偏去阴影,识别最准,导出 PDF/图片后拖进来即可。
              </span>
            </li>
            <li className="flex gap-2">
              <span className="text-seal font-bold shrink-0 tabular-nums">②</span>
              <span>
                <b className="text-ink">直接拍照也行</b>:报告平铺填满画面、光线均匀、避免阴影反光、对焦清晰。
              </span>
            </li>
            <li className="flex gap-2">
              <span className="text-seal font-bold shrink-0 tabular-nums">③</span>
              <span>
                支持 <b className="text-ink">PDF · 图片 · 文本</b>;
                <b className="text-ink">原件永久保存、自动去重</b>,内容由 OCR 自动识别并归类到时间线。
              </span>
            </li>
          </ul>
        </div>

        {/* 导出(与导入同区,功能分开):全量时间线 → 自包含 HTML,浏览器打印/另存 PDF 交给医生 */}
        <div className="med-card mt-5 p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <FileDown className="w-5 h-5 text-seal" /> 导出给医生
          </div>
          <div className="text-body text-ink-2 mb-3">
            把全部病历按时间导出为一个自包含 HTML 文件,任意浏览器可打开、原生中文显示,
            再「打印 / 另存为 PDF」交给医生或用于报销。
          </div>
          <button
            type="button"
            onClick={doExport}
            disabled={exporting}
            className="med-btn med-btn-2 med-focusable"
          >
            <Download className="w-4 h-4" /> {exporting ? "导出中…" : "导出全部病历"}
          </button>
          {exportMsg && (
            <div
              className={`mt-3 rounded-block px-4 py-2.5 text-body break-all ${
                exportMsg.kind === "ok"
                  ? "bg-seal-wash text-seal-ink"
                  : "bg-critical-wash text-critical"
              }`}
            >
              <div>{exportMsg.text}</div>
              {exportMsg.kind === "ok" && (
                <button
                  onClick={() =>
                    api
                      .openPath(exportMsg.path)
                      .catch((e) => setExportMsg({ kind: "err", text: `打开失败:${String(e)}` }))
                  }
                  className="med-focusable mt-1 rounded-ctl font-semibold text-seal-ink hover:underline cursor-pointer"
                >
                  打开文件
                </button>
              )}
            </div>
          )}
        </div>

        {/* 加密分享给医生:端到端加密、零服务器,需口令打开 */}
        {/* 改版前这一块整体是绿色(emerald):卡边、按钮、口令框、说明字。设计系统
            的色板里**没有绿** —— 绿被刻意排除掉了(正常值不上色)。安全感交给
            ShieldCheck 图标和文案,配色收回主色。 */}
        <div className="med-card mt-5 p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <ShieldCheck className="w-5 h-5 text-seal" /> 加密分享给医生
          </div>
          <div className="text-body text-ink-2 mb-3">
            生成一个<b className="text-ink">端到端加密</b>的 HTML 文件(含浏览器内查看器):
            <b className="text-ink">零服务器</b>,医生用任意浏览器打开、输入<b className="text-ink">口令</b>即在本地解密查看,数据不上传任何服务器。
          </div>
          <div className="flex items-center gap-3 mb-1.5">
            <label className="text-body text-ink-2">建议复阅期限</label>
            <input
              type="number"
              min={1}
              max={36500}
              value={shareDays}
              onChange={(e) => setShareDays(Number(e.target.value))}
              className="w-24 text-body tabular-nums text-ink border border-line bg-surface rounded-ctl px-3 py-1.5 focus:outline-none focus:border-seal focus:ring-2 focus:ring-seal-wash"
            />
            <span className="text-body text-ink-2">天</span>
          </div>
          <div className="text-secondary text-ink-3 mb-3">
            仅作为给医生的复阅提醒,<b className="text-ink-2">并非强制</b>——文件本身不会到期失效,持有文件与口令者始终可解密查看。长期分享可设很大值(如 36500 天 ≈ 100 年)。
          </div>
          <button
            type="button"
            onClick={doShare}
            disabled={sharing}
            className="med-btn med-btn-2 med-focusable"
          >
            <ShieldCheck className="w-4 h-4" /> {sharing ? "生成中…" : "生成加密分享文件"}
          </button>

          {shareResult && shareResult.kind === "err" && (
            <div className="mt-3 rounded-block px-4 py-2.5 text-body bg-critical-wash text-critical break-all">
              {shareResult.text}
            </div>
          )}
          {shareResult && shareResult.kind === "ok" && (
            <div className="med-block mt-4 p-4">
              <div className="text-caption font-mono text-ink-3 uppercase mb-1">
                口令(请务必单独告知医生)
              </div>
              <div className="flex items-center gap-2">
                {/* 口令要一个字一个字念给医生听 → 等宽 + value 一档字号,别再用正文大小 */}
                <code className="flex-1 text-value font-mono tabular-nums font-semibold text-ink bg-surface border border-line rounded-ctl px-3 py-2 break-all select-all">
                  {shareResult.passphrase}
                </code>
                <button
                  type="button"
                  onClick={() => copyPass(shareResult.passphrase)}
                  className="med-focusable shrink-0 self-stretch flex items-center gap-1.5 text-secondary font-medium text-ink-2 bg-surface border border-line hover:bg-paper rounded-ctl px-3 transition-colors cursor-pointer"
                >
                  {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                  {copied ? "已复制" : "复制"}
                </button>
              </div>
              <div className="mt-3 text-body text-ink-2">
                已生成 <span className="tabular-nums">{shareResult.count}</span> 份记录。把文件发给医生(或存到你的云盘发链接),
                <b className="text-ink">口令请另行单独告知,切勿和文件放一起</b>。
                医生用任意浏览器打开 → 输口令 → 查看。建议复阅期限{" "}
                <span className="tabular-nums">{shareResult.days}</span> 天(仅为提醒,非强制,文件不会自动失效)。
              </div>
              <button
                type="button"
                onClick={() =>
                  api
                    .openPath(shareResult.path)
                    .catch((e) => setShareResult({ kind: "err", text: `打开失败:${String(e)}` }))
                }
                className="med-focusable mt-2 rounded-ctl text-body font-semibold text-seal-ink hover:underline cursor-pointer"
              >
                打开文件
              </button>
            </div>
          )}
        </div>

        {error && <div className="mt-4 text-body text-critical">导入失败:{error}</div>}

        {results.length > 0 && (
          <div className="mt-6 space-y-2">
            {/* 改版前 text-[11px],低于 12px 下限 */}
            <div className="text-caption font-mono tabular-nums text-ink-3 uppercase">
              本次结果 · {results.length} 个文件
            </div>
            {results.map((r, i) => {
              const m = STATUS_META[r.status] ?? {
                label: r.status,
                cls: "text-ink-2 bg-line-2",
              };
              return (
                <div
                  key={i}
                  className="flex items-center justify-between bg-surface border border-line rounded-block px-4 py-2.5"
                >
                  <span className="text-body text-ink truncate">{r.name}</span>
                  <span className={`med-pill shrink-0 ml-3 ${m.cls}`}>{m.label}</span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
