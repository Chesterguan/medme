import { useEffect, useState } from "react";
import Sidebar from "./components/Sidebar";
import Timeline from "./components/Timeline";
import { api } from "./api";
import type { DocumentSummary } from "./types";
import "./App.css";

export default function App() {
  const [docs, setDocs] = useState<DocumentSummary[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.listTimeline().then(setDocs).catch((e) => setError(String(e)));
  }, []);

  return (
    <div className="w-screen h-screen flex bg-slate-50 overflow-hidden text-slate-800">
      <Sidebar count={docs.length} />
      <div className="flex-1 flex flex-col h-full overflow-hidden">
        {error
          ? <div className="flex-1 flex items-center justify-center text-rose-600 text-sm">加载失败:{error}</div>
          : <Timeline docs={docs} />}
      </div>
    </div>
  );
}
