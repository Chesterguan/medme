//! `ProfileView` —— 规则引擎的**唯一**输出。渲染引擎(Flutter/查看器)只认这个形状。
//!
//! section 的顺序、标题、空态文案**全来自包**(spec §6):加一个病不发版的前提是
//! App 里没有任何一句写死的病种文案。
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct SourceOut {
    pub id: String,
    pub cite: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Section {
    /// 7 种之一:`status_card` / `score_card` / `series_chart` / `reminders` /
    /// `timeline` / `checklist` / `handoff`(spec §6)。渲染引擎认不出的 kind
    /// 整块跳过(前向兼容),不报错。
    pub kind: String,
    /// 这一块在包 `views.sections` 里那条配置的 `id`(spec §6)。
    ///
    /// **同一个 kind 会出现两次**:达标表与狼疮肾炎里程碑都是 `checklist`(复用同一
    /// 套渲染)。渲染层按这个 id 认,**不许靠「body 里有哪个键」去猜** —— 那是隐式
    /// 契约:`states_section` 哪天在 body 里多一个同名键、或者第三块 `checklist`
    /// 出现,渲染层就会静默认错。它也是渲染层把这一块对回包里那条 per-section 配置
    /// (`timeline` 的 `severity_high` 是先例)的唯一钥匙。
    ///
    /// `None` = 包里那条没写 id(或包里压根没有这块的配置)。**永远序列化**(不许加
    /// `skip_serializing_if`):`null` 与「缺这个字段」在 JSON 里要分得开,与 `title`
    /// 同一条讲究。
    #[serde(default)]
    pub id: Option<String>,
    /// 标题来自包的 `views.sections`(spec §6)。`None` = 包里没给这种 kind 写标题 ——
    /// 渲染层自己决定怎么办,引擎不垫一句中文顶上。`null` 与 `""` 有区别:后者在
    /// JSON 里看不出是包漏写了还是作者故意留白。
    pub title: Option<String>,
    /// `Some(提示语)` = 这块**没数据**,折叠成一行(spec §5.6);`None` = 展开。
    pub empty_hint: Option<String>,
    pub body: serde_json::Value,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProfileView {
    pub package_id: String,
    pub package_version: String,
    pub display_name: String,
    /// 用户从没开启过这个病时为 `false`,且 `sections` 为空。
    pub enabled: bool,
    pub disclaimer: String,
    pub sections: Vec<Section>,
    /// 包里声明的全部出处。界面上每个数值旁边的出处 id 到这里查全文。
    pub sources: Vec<SourceOut>,
}
