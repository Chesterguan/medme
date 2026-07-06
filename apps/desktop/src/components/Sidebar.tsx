import { Activity, ShieldCheck } from "lucide-react";

export default function Sidebar({ count }: { count: number }) {
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
      <nav className="flex-1 p-4">
        <div className="w-full flex items-center justify-between p-3.5 rounded-xl bg-blue-50 text-blue-700 border border-blue-100/40">
          <div className="flex items-center gap-3">
            <Activity className="w-5 h-5 text-blue-600" />
            <div>
              <span className="text-sm font-medium block text-blue-900">生命时间线</span>
              <span className="text-[10px] font-mono text-slate-400 block">Medical Lifeline</span>
            </div>
          </div>
          <span className="px-2 py-0.5 rounded-full text-[10px] font-bold font-mono bg-blue-600 text-white">{count}</span>
        </div>
      </nav>
      <div className="p-4 border-t border-slate-200 text-[10px] font-mono text-slate-400 flex justify-between">
        <span>© MedMe Team 2026</span><span>v0.1</span>
      </div>
    </div>
  );
}
