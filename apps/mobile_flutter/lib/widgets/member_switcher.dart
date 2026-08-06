// 成员切换弹出层 + 添加成员对话框。**概览、档案两屏与档案的 tab 条末尾「+」
// 共用同一份 UI 与同一条状态更新路径**——不是各屏各拼一份。
//
// 真相只有一处:ProfileManager.instance.currentId。切换调用
// switchProfileAndReopen,它会 bumpVaultRevision() 通知全部监听
// vaultRevision 的屏(概览、档案都在监听)自动重载。这里不额外维护「当前
// 选中成员」的本地状态,避免出现两份状态不同步。
import 'package:flutter/material.dart';

import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

/// 弹出成员切换器:列出全部成员,点即切换。**不含「添加成员」** —— 新建成员
/// 只在档案屏那颗「+」一个入口,见下方注释。
///
/// [onChanged] 供调用方在异步重开完成前先做一次同步 UI 反馈(比如 tab 条的
/// 高亮),不是必需的——各屏本就监听 `vaultRevision`,重开完成后会自动刷新;
/// 这个回调只是让调用方自己的屏幕反应快半拍。
Future<void> showMemberSwitcherSheet(
  BuildContext context, {
  VoidCallback? onChanged,
}) async {
  await ProfileManager.instance.ensureLoaded();
  final members = ProfileManager.instance.profiles;
  final currentId = ProfileManager.instance.currentId.value;
  if (!context.mounted) return;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final c = MedColors.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MedShape.s4,
                4,
                MedShape.s4,
                MedShape.s1,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '切换成员',
                  style: MedType.title.copyWith(color: c.ink),
                ),
              ),
            ),
            for (final m in members)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: c.sealWash,
                  child: Text(
                    m.name.isNotEmpty ? m.name[0] : '?',
                    style: MedType.subtitle.copyWith(color: c.sealInk),
                  ),
                ),
                title: Text(m.name, style: MedType.subtitle.copyWith(color: c.ink)),
                trailing: m.id == currentId
                    ? Icon(Icons.check, color: c.seal)
                    : null,
                onTap: () => Navigator.of(context).pop('member:${m.id}'),
              ),
            // **这里不放「添加成员」。** 新建成员是低频、一次性、且要输名字的动作,
            // 它只该有一个入口 —— 档案屏成员条末尾那颗「+」。切换器里再放一个,
            // 等于同一件事有两条路,用户下次找不到自己上回是从哪儿进的。
            // 切换器只做一件事:切换。
            const SizedBox(height: MedShape.s1),
          ],
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  if (action.startsWith('member:')) {
    // action 里带的是**成员 id**,不是名字——名字可改、可重复,不能拿来寻址。
    final id = action.substring('member:'.length);
    if (id != currentId) {
      await switchProfileAndReopen(id);
      onChanged?.call();
    }
  }
}

/// 添加成员对话框:输个名字 → 建新成员并切过去。
Future<void> promptAddMember(
  BuildContext context, {
  VoidCallback? onChanged,
}) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('添加成员'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '输入姓名'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  await createProfileAndReopen(name.trim());
  onChanged?.call();
}
