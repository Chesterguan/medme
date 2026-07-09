import { useEffect, useRef, useState } from "react";
import { ZoomIn, ZoomOut, Maximize2, RotateCw, RefreshCw } from "lucide-react";

// 普通图片(照片/扫描件)查看器:滚轮缩放(向光标)、拖拽平移、旋转、1:1、重置。
// 高清照片的报告要能放大看清细节 —— 静态 object-contain 不够。
const MIN = 1;
const MAX = 12;
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export default function ImageViewer({ src, alt }: { src: string; alt: string }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);
  const [tx, setTx] = useState(0);
  const [ty, setTy] = useState(0);
  const [rot, setRot] = useState(0);
  const drag = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null);
  const [grabbing, setGrabbing] = useState(false);

  const reset = () => {
    setScale(1);
    setTx(0);
    setTy(0);
    setRot(0);
  };

  // 滚轮缩放(向光标位置):用非被动监听以便 preventDefault,避免页面滚动。
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const cx = e.clientX - rect.left - rect.width / 2;
      const cy = e.clientY - rect.top - rect.height / 2;
      setScale((s) => {
        const ns = clamp(s * (e.deltaY < 0 ? 1.15 : 1 / 1.15), MIN, MAX);
        const k = ns / s - 1;
        // 让光标下的点保持不动
        setTx((t) => t - (cx - t) * k);
        setTy((t) => t - (cy - t) * k);
        return ns;
      });
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  const onDown = (e: React.MouseEvent) => {
    drag.current = { x: e.clientX, y: e.clientY, tx, ty };
    setGrabbing(true);
  };
  const onMove = (e: React.MouseEvent) => {
    if (!drag.current) return;
    setTx(drag.current.tx + (e.clientX - drag.current.x));
    setTy(drag.current.ty + (e.clientY - drag.current.y));
  };
  const onUp = () => {
    drag.current = null;
    setGrabbing(false);
  };

  const btn =
    "flex items-center gap-1.5 text-xs px-3 py-1.5 rounded-lg bg-white/10 text-white/80 hover:bg-white/20 cursor-pointer transition-colors";

  return (
    <div className="flex flex-col h-full w-full" onClick={(e) => e.stopPropagation()}>
      <div className="relative z-10 flex items-center gap-2 px-3 py-2 shrink-0 flex-wrap bg-black/60">
        <button onClick={() => setScale((s) => clamp(s * 1.3, MIN, MAX))} className={btn}>
          <ZoomIn className="w-3.5 h-3.5" /> 放大
        </button>
        <button onClick={() => setScale((s) => clamp(s / 1.3, MIN, MAX))} className={btn}>
          <ZoomOut className="w-3.5 h-3.5" /> 缩小
        </button>
        <button onClick={() => setRot((r) => (r + 90) % 360)} className={btn}>
          <RotateCw className="w-3.5 h-3.5" /> 旋转
        </button>
        <button
          onClick={() => setScale((s) => (s === 1 ? MAX / 3 : 1))}
          className={btn}
          title="1:1 / 适应"
        >
          <Maximize2 className="w-3.5 h-3.5" /> 1:1
        </button>
        <button onClick={reset} className={btn}>
          <RefreshCw className="w-3.5 h-3.5" /> 重置
        </button>
        <span className="text-xs text-white/40 ml-1">{Math.round(scale * 100)}%</span>
      </div>
      <div
        ref={boxRef}
        className="flex-1 min-h-0 overflow-hidden flex items-center justify-center bg-black select-none"
        style={{ cursor: scale > 1 ? (grabbing ? "grabbing" : "grab") : "default" }}
        onMouseDown={onDown}
        onMouseMove={onMove}
        onMouseUp={onUp}
        onMouseLeave={onUp}
        onDoubleClick={() => (scale === 1 ? setScale(3) : reset())}
      >
        <img
          src={src}
          alt={alt}
          draggable={false}
          className="max-w-full max-h-full object-contain"
          style={{
            transform: `translate(${tx}px, ${ty}px) scale(${scale}) rotate(${rot}deg)`,
            transition: drag.current ? "none" : "transform 0.08s ease-out",
          }}
        />
      </div>
    </div>
  );
}
