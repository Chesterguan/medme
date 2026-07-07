import { useEffect, useState } from "react";
import Sidebar from "./components/Sidebar";
import PatientBanner from "./components/PatientBanner";
import Timeline from "./components/Timeline";
import DocumentView from "./components/DocumentView";
import ImportView from "./components/ImportView";
import { api } from "./api";
import type { TimelineGroup, DocumentDetail } from "./types";
import "./App.css";

export default function App() {
  const [groups, setGroups] = useState<TimelineGroup[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<DocumentDetail | null>(null);
  const [tab, setTab] = useState<string>("timeline");
  const [reloadKey, setReloadKey] = useState(0);

  const loadTimeline = () =>
    api.listTimelineGrouped().then(setGroups).catch((e) => setError(String(e)));

  useEffect(() => {
    loadTimeline();
  }, []);

  const totalDocs = groups.reduce(
    (n, g) => n + (g.group_type === "encounter" ? g.encounter.doc_count : 1),
    0,
  );

  const openDoc = (id: number) => {
    setError(null);
    api.getDocument(id).then(setDetail).catch((e) => setError(String(e)));
  };

  const nav = (id: string) => {
    setDetail(null);
    setTab(id);
  };

  const afterImport = () => {
    loadTimeline();
    setReloadKey((k) => k + 1); // 让病人 banner 重新归纳
  };

  return (
    <div className="w-screen h-screen flex bg-slate-50 overflow-hidden text-slate-800">
      <Sidebar activeTab={tab} onNav={nav} count={totalDocs} />
      <div className="flex-1 flex flex-col h-full overflow-hidden">
        <PatientBanner reloadKey={reloadKey} />
        {error && (
          <div className="px-6 py-3 text-rose-700 text-sm bg-rose-50 border-b border-rose-100">
            加载失败:{error}
          </div>
        )}
        {detail ? (
          <DocumentView detail={detail} onBack={() => setDetail(null)} />
        ) : tab === "import" ? (
          <ImportView onImported={afterImport} />
        ) : (
          <Timeline groups={groups} onSelect={openDoc} />
        )}
      </div>
    </div>
  );
}
