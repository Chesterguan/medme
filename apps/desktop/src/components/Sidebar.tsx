import { useState } from "react";
import {
  Activity,
  UploadCloud,
  Search,
  PanelLeftClose,
  PanelLeftOpen,
  Info,
  Settings,
} from "lucide-react";

const NAV = [
  { id: "timeline", label: "生命时间线", icon: Activity },
  { id: "search", label: "搜索", icon: Search },
  { id: "import", label: "导入 · 导出", icon: UploadCloud },
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
  const [collapsed, setCollapsed] = useState(false);

  return (
    <div
      className={`${
        collapsed ? "w-16" : "w-60"
      } bg-white border-r border-slate-200 flex flex-col h-screen text-slate-600 select-none shrink-0 transition-[width] duration-200`}
    >
      {/* Brand */}
      <div className={`${collapsed ? "px-2 py-4" : "p-5"} border-b border-slate-200`}>
        <div className={`flex items-center ${collapsed ? "justify-center" : "gap-3"}`}>
          <svg
            className="w-8 h-8 shrink-0"
            viewBox="0 0 1024 1024"
            role="img"
            aria-label="MedMe"
          >
            <defs>
              <linearGradient id="sidebar-brand-mark-g" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0" stopColor="#2bc0d2" />
                <stop offset="0.52" stopColor="#1789c1" />
                <stop offset="1" stopColor="#1560a8" />
              </linearGradient>
            </defs>
            <rect width="1024" height="1024" rx="232" fill="url(#sidebar-brand-mark-g)" />
            <path
              transform="translate(85.76,804.70) scale(0.82760,-0.82760)"
              d="M326 640C320 672 323 688 335 688C431 690 535 708 650 741C668 748 687 734 704 699C720 664 716 650 691 658C672 666 641 663 600 651C557 639 509 631 458 627C405 623 371 615 355 605C342 596 332 606 326 640ZM212 393C226 508 234 570 236 582C234 600 241 605 259 600C274 594 292 586 310 578C325 568 326 555 314 537C283 459 266 368 260 267C252 165 254 101 266 75C271 62 321 63 413 79C503 95 582 104 650 106C717 108 757 111 772 115C777 117 786 110 796 95C804 78 813 65 822 57C830 47 832 34 829 20C825 4 814 0 798 10C698 35 597 43 494 33C391 23 324 13 296 3C267 -6 246 -9 234 -4C229 -1 226 3 226 11C226 18 220 40 210 77C196 172 196 277 212 393ZM567 292C558 302 561 306 578 306C639 287 691 265 736 237C740 234 741 219 737 189C731 160 724 144 716 140C706 136 699 138 695 146C689 154 683 165 675 179C628 228 593 265 567 292ZM761 328C702 338 636 336 561 323C555 322 550 321 546 321C538 294 525 267 509 240C497 216 483 198 468 188C450 176 444 165 449 157C451 149 434 142 397 135C358 126 331 126 315 134C298 142 300 148 322 154C324 154 335 159 355 169C372 178 393 190 414 208C434 225 453 249 471 281C473 291 476 300 480 309C429 297 387 284 355 271C348 266 335 274 319 298C302 321 310 330 342 324C385 338 436 352 494 367C498 395 499 419 497 440C489 438 480 435 471 431C457 424 450 429 449 444C447 454 444 463 441 473C422 448 400 427 377 408C357 396 344 391 336 393C326 395 329 403 346 419C385 473 409 513 421 540C433 566 438 584 439 594C441 611 452 613 472 601C489 587 502 577 511 571C519 565 517 559 505 552C497 548 490 541 484 531C480 525 475 517 467 507C504 511 537 518 566 527C596 537 620 543 640 546C649 547 656 538 660 520C662 500 658 488 648 485C619 473 592 461 568 450C564 449 563 448 562 447C558 430 555 407 554 382C554 382 556 382 559 383C598 391 635 396 671 402C706 406 728 409 734 413C740 416 745 413 750 403C754 394 760 387 768 383C773 379 777 367 778 348C778 328 772 321 761 328Z"
              fill="#ffffff"
            />
          </svg>
          {!collapsed && (
            <div className="min-w-0">
              <div className="flex items-center gap-1.5">
                <span className="font-bold text-lg text-blue-600 tracking-tight">MedMe</span>
                <span className="font-bold text-lg text-slate-950">医我</span>
              </div>
              <span className="text-[10px] font-mono text-slate-400 tracking-widest uppercase block mt-0.5">
                Health Vault
              </span>
              <span className="text-[10px] text-slate-400 block mt-0.5">个人医疗数据保险箱</span>
            </div>
          )}
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 p-2 space-y-1">
        {NAV.map((item) => {
          const Icon = item.icon;
          const active = activeTab === item.id;
          return (
            <button
              key={item.id}
              onClick={() => onNav(item.id)}
              title={collapsed ? item.label : undefined}
              className={`w-full flex items-center ${
                collapsed ? "justify-center p-2.5" : "justify-between p-3"
              } rounded-xl transition-all cursor-pointer text-left ${
                active
                  ? "bg-blue-50 text-blue-700 border border-blue-100/40"
                  : "border border-transparent hover:bg-slate-50"
              }`}
            >
              <div className={`flex items-center ${collapsed ? "" : "gap-3"} min-w-0`}>
                <Icon
                  className={`w-5 h-5 shrink-0 ${active ? "text-blue-600" : "text-slate-400"}`}
                />
                {!collapsed && (
                  <span
                    className={`text-sm font-medium ${
                      active ? "text-blue-900" : "text-slate-700"
                    }`}
                  >
                    {item.label}
                  </span>
                )}
              </div>
              {!collapsed && item.id === "timeline" && (
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

      {/* Footer */}
      <div className="p-2 border-t border-slate-200">
        <div className={`flex ${collapsed ? "flex-col gap-1" : "gap-1"}`}>
          <button
            onClick={() => onNav("about")}
            title={collapsed ? "关于 · 声明" : undefined}
            className={`flex-1 flex items-center ${
              collapsed ? "justify-center" : "gap-2"
            } p-2.5 rounded-xl cursor-pointer transition-colors ${
              activeTab === "about"
                ? "bg-blue-50 text-blue-700"
                : "text-slate-400 hover:bg-slate-50 hover:text-slate-600"
            }`}
          >
            <Info className="w-5 h-5 shrink-0" />
            {!collapsed && <span className="text-xs font-medium">关于 · 声明</span>}
          </button>
          <button
            onClick={() => onNav("settings")}
            title="设置"
            className={`flex items-center justify-center p-2.5 rounded-xl cursor-pointer transition-colors shrink-0 ${
              activeTab === "settings"
                ? "bg-blue-50 text-blue-700"
                : "text-slate-400 hover:bg-slate-50 hover:text-slate-600"
            }`}
          >
            <Settings className="w-5 h-5 shrink-0" />
          </button>
        </div>
        <button
          onClick={() => setCollapsed((c) => !c)}
          title={collapsed ? "展开" : "收起"}
          className={`w-full flex items-center ${
            collapsed ? "justify-center" : "gap-2"
          } p-2.5 rounded-xl text-slate-400 hover:bg-slate-50 hover:text-slate-600 cursor-pointer transition-colors`}
        >
          {collapsed ? (
            <PanelLeftOpen className="w-5 h-5" />
          ) : (
            <>
              <PanelLeftClose className="w-5 h-5" />
              <span className="text-xs font-mono">收起侧栏</span>
            </>
          )}
        </button>
        {!collapsed && (
          <div className="px-2 pt-2 text-[10px] font-mono text-slate-400 flex justify-between">
            <span>© MedMe 2026</span>
            <span>v1.0</span>
          </div>
        )}
      </div>
    </div>
  );
}
