import { Activity, ShieldCheck, UploadCloud } from "lucide-react";

const NAV = [
  { id: "timeline", label: "生命时间线", sub: "Medical Lifeline", icon: Activity },
  { id: "import", label: "导入病历", sub: "Import Records", icon: UploadCloud },
];

export default function Sidebar({
  activeTab,
  onNav,
  count,
}: {
  activeTab: string;
  onNav: (id: string) => void;
  count: number;
}) {
  return (
    <div className="w-72 bg-white border-r border-slate-200 flex flex-col h-screen text-slate-600 select-none shrink-0">
      <div className="p-6 border-b border-slate-200">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-blue-50 flex items-center justify-center text-blue-600 border border-blue-100">
            <ShieldCheck className="w-6 h-6" />
          </div>
          <div>
            <div className="flex items-center gap-1.5">
              <span className="font-bold text-xl text-blue-600 tracking-tight">MedMe</span>
              <span className="font-bold text-xl text-slate-950">医我</span>
            </div>
            <span className="text-[10px] font-mono text-slate-400 tracking-widest uppercase block mt-0.5">
              Personal Health Vault
            </span>
          </div>
        </div>
      </div>

      <nav className="flex-1 p-4 space-y-1">
        {NAV.map((item) => {
          const Icon = item.icon;
          const active = activeTab === item.id;
          return (
            <button
              key={item.id}
              onClick={() => onNav(item.id)}
              className={`w-full flex items-center justify-between p-3.5 rounded-xl transition-all cursor-pointer text-left ${
                active
                  ? "bg-blue-50 text-blue-700 border border-blue-100/40"
                  : "border border-transparent hover:bg-slate-50"
              }`}
            >
              <div className="flex items-center gap-3">
                <Icon className={`w-5 h-5 ${active ? "text-blue-600" : "text-slate-400"}`} />
                <div>
                  <span
                    className={`text-sm font-medium block ${
                      active ? "text-blue-900" : "text-slate-700"
                    }`}
                  >
                    {item.label}
                  </span>
                  <span className="text-[10px] font-mono text-slate-400 block">{item.sub}</span>
                </div>
              </div>
              {item.id === "timeline" && (
                <span
                  className={`px-2 py-0.5 rounded-full text-[10px] font-bold font-mono ${
                    active ? "bg-blue-600 text-white" : "bg-slate-100 text-slate-600"
                  }`}
                >
                  {count}
                </span>
              )}
            </button>
          );
        })}
      </nav>

      <div className="p-4 border-t border-slate-200 text-[10px] font-mono text-slate-400 flex justify-between">
        <span>© MedMe Team 2026</span>
        <span>v0.1</span>
      </div>
    </div>
  );
}
