import { useEffect, useState } from "react";
import {
  Settings as SettingsIcon,
  FolderOpen,
  FolderSync,
  Inbox,
  UploadCloud,
  Info,
  CloudCog,
  Lock,
  AlertTriangle,
  Trash2,
  Loader2,
} from "lucide-react";
import { api } from "../api";

export default function SettingsView({
  onNav,
  onReset,
}: {
  onNav: (id: string) => void;
  /** 清空保险箱成功后调用,让 App 层刷新时间线 + 病人 banner(见 App.tsx 的 afterImport)。 */
  onReset: () => void;
}) {
  const [vaultPath, setVaultPath] = useState<string | null>(null);
  const [inboxPath, setInboxPath] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [relocating, setRelocating] = useState(false);

  useEffect(() => {
    api.getVaultPath().then(setVaultPath).catch((e) => setError(String(e)));
    api.getInboxPath().then(setInboxPath).catch((e) => setError(String(e)));
  }, []);

  // 更换保险箱位置:后端(Rust)弹出原生「选择文件夹」对话框选一个目录(选云同步文件夹
  // 即可多设备同步),把现有病历整体搬过去(或在共享文件夹里与另一台设备合并),返回新路径。
  // 安全:路径来自后端原生对话框,不再由(可能被 XSS 污染的)webview 传入。
  async function changeLocation() {
    setError(null);
    setRelocating(true);
    try {
      const newPath = await api.setVaultPath();
      setVaultPath(newPath);
    } catch (e) {
      setError(String(e));
    } finally {
      setRelocating(false);
    }
  }

  // 清空保险箱 · 重置(格式化):让示例数据/已导入内容可逆(载入 → 试用 → 清空 → 正式使用),
  // 尤其应在开启上方「云文件夹设置」之前做——否则示例数据会被同步进云盘。
  const [confirmReset, setConfirmReset] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [resetMsg, setResetMsg] = useState<
    { kind: "ok"; text: string } | { kind: "err"; text: string } | null
  >(null);

  async function doResetVault() {
    setResetting(true);
    setResetMsg(null);
    try {
      await api.resetVault();
      onReset();
      setConfirmReset(false);
      setResetMsg({ kind: "ok", text: "保险箱已清空,可以开始正式使用了。" });
    } catch (e) {
      setResetMsg({ kind: "err", text: `清空失败:${String(e)}` });
    } finally {
      setResetting(false);
    }
  }

  return (
    <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
      <div className="max-w-2xl mx-auto space-y-5">
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-block bg-seal-wash flex items-center justify-center text-seal border border-line shrink-0">
            <SettingsIcon className="w-6 h-6" />
          </div>
          <div>
            <h1 className="text-display font-bold text-ink">设置</h1>
            {/* 改版前 text-[11px],低于 12px 下限 */}
            <span className="text-caption font-mono text-ink-3 uppercase">MedMe 医我</span>
          </div>
        </div>

        {error && (
          <div className="rounded-block px-4 py-2.5 text-body bg-critical-wash text-critical">
            {error}
          </div>
        )}

        {/* 数据保险箱位置 */}
        <div className="med-card p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <FolderOpen className="w-5 h-5 text-seal" /> 数据保险箱位置
          </div>
          <div className="med-block flex items-center justify-between gap-3 px-4 py-2.5">
            <span className="text-secondary font-mono text-ink-2 truncate">
              {relocating ? "正在搬迁病历…" : vaultPath ?? "加载中…"}
            </span>
            <div className="shrink-0 flex items-center gap-2">
              <button
                type="button"
                disabled={relocating}
                onClick={changeLocation}
                className="med-focusable flex items-center gap-1.5 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 disabled:opacity-50 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
              >
                <FolderSync className="w-3.5 h-3.5" /> 云文件夹设置…
              </button>
              <button
                type="button"
                disabled={!vaultPath || relocating}
                onClick={() =>
                  vaultPath && api.openPath(vaultPath).catch((e) => setError(String(e)))
                }
                className="med-focusable flex items-center gap-1.5 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 disabled:opacity-50 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
              >
                <FolderOpen className="w-3.5 h-3.5" /> 打开文件夹
              </button>
            </div>
          </div>
          <div className="mt-3 flex items-start gap-2 text-body text-ink-2">
            <CloudCog className="w-4 h-4 text-ink-3 shrink-0 mt-1" />
            <span>
              把这个文件夹放进云同步目录,多设备就自动同步(去中心化,无需服务器):
              <b className="text-ink">设备全是苹果 → iCloud 云盘;有安卓 / Windows → 坚果云</b>。
            </span>
          </div>
          <div className="mt-2 flex items-start gap-2 text-secondary text-ink-3">
            <FolderSync className="w-3.5 h-3.5 shrink-0 mt-1" />
            <span>
              选一个云同步文件夹(iCloud 云盘 / 坚果云)即可多设备同步;换位置会把现有病历一起搬过去。
            </span>
          </div>
          <div className="mt-2 flex items-start gap-2 text-secondary text-ink-3">
            <Lock className="w-3.5 h-3.5 shrink-0 mt-1" />
            <span>
              放到云盘后,资料在云端<b className="text-ink-2">没有额外加密</b>,安全取决于你系统本身的保护。建议按下方「数据安全 · 加密」开启
              <b className="text-ink-2"> FileVault + iCloud 高级数据保护</b>。
            </span>
          </div>
        </div>

        {/* 数据安全:引导用系统级端到端加密(零口令、老人无感);app 层口令加密留后续版本 */}
        <div className="med-card p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <Lock className="w-5 h-5 text-seal" /> 数据安全 · 加密
          </div>
          <div className="text-body text-ink-2 mb-3">
            病历默认存在本机。想要更强保护(尤其把保险箱放到云盘同步时),开启系统级端到端加密即可,
            <b className="text-ink">无需在本 app 记任何口令</b>,一次设置、家人可代劳:
          </div>
          <ol className="space-y-2.5 text-body text-ink-2 list-none">
            <li className="flex gap-2.5">
              <span className="shrink-0 w-6 h-6 rounded-full bg-seal-wash text-seal-ink text-caption font-bold tabular-nums flex items-center justify-center">
                1
              </span>
              <span>
                开启 <b className="text-ink">Mac FileVault</b>(全盘加密):系统设置 › 隐私与安全性 ›
                FileVault › 打开。本机数据即加密存储。
              </span>
            </li>
            <li className="flex gap-2.5">
              <span className="shrink-0 w-6 h-6 rounded-full bg-seal-wash text-seal-ink text-caption font-bold tabular-nums flex items-center justify-center">
                2
              </span>
              <span>
                开启 <b className="text-ink">iCloud 高级数据保护</b>(端到端,苹果也读不了):系统设置 ›
                [你的名字] › iCloud › 高级数据保护 › 打开。云端同步的数据即端到端加密。
              </span>
            </li>
          </ol>
          <div className="mt-3 text-secondary text-ink-3">
            两者一起 = 本机 + 云端都端到端加密。app 内置的口令加密(适配 iCloud 之外的第三方云)将在后续版本提供。
          </div>
        </div>

        {/* 自动收件箱 */}
        <div className="med-card p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <Inbox className="w-5 h-5 text-seal" /> 自动收件箱
          </div>
          <div className="med-block flex items-center justify-between gap-3 px-4 py-2.5">
            <span className="text-secondary font-mono text-ink-2 truncate">
              {inboxPath ?? "加载中…"}
            </span>
            <button
              type="button"
              onClick={() => api.openInbox().catch((e) => setError(String(e)))}
              className="med-focusable shrink-0 flex items-center gap-1.5 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
            >
              <FolderOpen className="w-3.5 h-3.5" /> 打开
            </button>
          </div>
        </div>

        {/* 导入 / 导出 / 加密分享:不重复放控件,指向对应页面 */}
        <div className="med-card p-5">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-ink mb-2">
            <UploadCloud className="w-5 h-5 text-seal" /> 导入 · 导出 · 加密分享
          </div>
          <div className="flex items-center justify-between gap-3">
            <span className="text-body text-ink-2">在「导入·导出」页操作。</span>
            <button
              type="button"
              onClick={() => onNav("import")}
              className="med-focusable shrink-0 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
            >
              前往
            </button>
          </div>
        </div>

        {/* 危险操作:清空保险箱 · 重置(格式化)——桌面此前没有这个入口,示例数据/试用内容
            没法清掉;镜像 mobile 已有的同名功能(见 apps/mobile/src/App.tsx::resetVault)。 */}
        {/* 全屏唯一一处 critical 描边:不可撤销的删除。红只留给「真的会出事」。 */}
        <div className="med-card p-5 border-critical">
          <div className="flex items-center gap-2 text-subtitle font-semibold text-critical mb-2">
            <AlertTriangle className="w-5 h-5" /> 危险操作
          </div>
          <div className="text-body text-ink-2 mb-3">
            <b className="text-critical">清空保险箱</b>会永久删除保险箱里的<b>全部记录</b>
            (包括示例数据「张建国」和你已导入的所有病历),<b className="text-critical">此操作不可撤销</b>。
            <br />
            如果你之前用示例数据试用过 MedMe,请在正式使用前先清空一次——
            <b className="text-critical">尤其要在开启上方「云文件夹设置」之前</b>,
            否则示例数据会被同步进你的云盘。
          </div>
          <button
            type="button"
            onClick={() => setConfirmReset(true)}
            className="med-btn med-focusable text-critical bg-critical-wash border-line"
          >
            <Trash2 className="w-4 h-4" /> 清空保险箱 · 重置(格式化)
          </button>
          {resetMsg && (
            <div
              className={`mt-3 rounded-block px-4 py-2.5 text-body break-all ${
                resetMsg.kind === "ok"
                  ? "bg-seal-wash text-seal-ink"
                  : "bg-critical-wash text-critical"
              }`}
            >
              {resetMsg.text}
            </div>
          )}
        </div>

        {/* 关于 · 声明 */}
        <div className="med-card p-5">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-2 text-subtitle font-semibold text-ink">
              <Info className="w-5 h-5 text-seal" /> 关于 · 声明
            </div>
            <button
              type="button"
              onClick={() => onNav("about")}
              className="med-focusable shrink-0 text-secondary font-medium text-seal-ink bg-seal-wash hover:brightness-95 rounded-ctl px-3 py-1.5 transition-[filter] cursor-pointer"
            >
              查看
            </button>
          </div>
        </div>

        <div className="text-caption font-mono tabular-nums text-ink-3 text-center">版本 v1.0</div>
      </div>

      {/* 清空确认:破坏性操作,二次确认(镜像 mobile 的 confirmReset 弹层) */}
      {confirmReset && (
        <div
          className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4"
          onClick={() => !resetting && setConfirmReset(false)}
        >
          {/* 改版前弹层用 shadow-xl 抬起来。规范里阴影只有一档 —— 弹层的分离感
              交给背后的遮罩和一像素描边,不靠第二档阴影。 */}
          <div className="med-card max-w-md w-full p-6" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-2 text-title font-bold text-critical mb-3">
              <AlertTriangle className="w-5 h-5" /> 确定清空保险箱?
            </div>
            <div className="text-body text-ink-2 mb-5">
              这会<b className="text-critical">永久删除</b>保险箱里的全部记录
              (含示例数据和你已导入的病历),<b className="text-critical">此操作不可撤销</b>。
            </div>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setConfirmReset(false)}
                disabled={resetting}
                className="med-btn med-btn-3 med-focusable"
              >
                取消
              </button>
              {/* 破坏性确认:实心 critical。这是全 app 唯一一颗实心红按钮。 */}
              <button
                type="button"
                onClick={doResetVault}
                disabled={resetting}
                className="med-btn med-focusable text-white bg-critical"
              >
                {resetting ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Trash2 className="w-4 h-4" />
                )}
                {resetting ? "正在清空…" : "确定清空"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
