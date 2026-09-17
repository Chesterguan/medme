// 成员切换弹出层 + 添加成员对话框。**概览、档案两屏与档案的 tab 条末尾「+」
// 共用同一份 UI 与同一条状态更新路径**——不是各屏各拼一份。
//
// 真相只有一处:ProfileManager.instance.currentId。切换调用
// switchProfileAndReopen,它会 bumpVaultRevision() 通知全部监听
// vaultRevision 的屏(概览、档案都在监听)自动重载。这里不额外维护「当前
// 选中成员」的本地状态,避免出现两份状态不同步。
import 'package:flutter/material.dart';
import 'package:mobile_flutter/sync_engine.dart' show pendingFirstSync;

import 'package:mobile_flutter/account.dart';
import 'package:mobile_flutter/api_client.dart';
import 'package:mobile_flutter/design_tokens.dart';
import 'package:mobile_flutter/grants.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';
import 'package:mobile_flutter/widgets/app_snack_bar.dart';

/// 弹出成员切换器:列出全部成员,点即切换。**不含「添加成员」** —— 新建成员
/// 只在档案屏那颗「+」一个入口,见下方注释。
///
/// [onChanged] 供调用方在异步重开完成前先做一次同步 UI 反馈(比如 tab 条的
/// 高亮),不是必需的——各屏本就监听 `vaultRevision`,重开完成后会自动刷新;
/// 这个回调只是让调用方自己的屏幕反应快半拍。
///
/// [switchTo] 是测试注入点,默认就是真实的 [switchProfileAndReopen]——
/// `flutter test` 不能跑到它内部的 FFI 开箱,所以测试传一个包了假 `reopen` 的
/// 替身进来(见 `test/member_switcher_locked_test.dart`)。
///
/// [purgeExpired] 同一个道理:默认是真实的 [Grants.purgeExpired](被授权的成员
/// 过期后,打开切换器就是"下一次看到列表"的时机,顺手清掉);没有过期档案时
/// 它什么也不碰(不触达 FFI),所以已有的测试不用注入什么就能照常通过。
Future<void> showMemberSwitcherSheet(
  BuildContext context, {
  VoidCallback? onChanged,
  Future<void> Function(String id)? switchTo,
  Future<List<Profile>> Function()? purgeExpired,
}) async {
  final doSwitch = switchTo ?? switchProfileAndReopen;
  final doPurge = purgeExpired ??
      () => Grants(
            ApiClient.forSession(AccountSession.instance),
            AccountSession.instance,
          ).purgeExpired();
  // 清理是家务事,不是开关——它失败(网络、FFI……)绝不能挡住"打开切换器"这个
  // 主动作,否则一次瞬时的清理失败就会让切换成员永久打不开。吞掉即可:清不掉的
  // 过期档案留到下一次打开切换器时再试。
  var purged = const <Profile>[];
  try {
    purged = await doPurge();
  } catch (_) {}
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
                subtitle: _memberSubtitle(m, MedType.secondary.copyWith(color: c.ink3)),
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
  // C11 在个人模式:`purgeExpired` 的返回值原来被**扔掉**了,于是家人那份过期的
  // 共享档案照旧从列表里消失、本机目录被删,屏上一个字都没有(评审 Important 4)。
  //
  // ⚠️ **必须等 `showModalBottomSheet` 返回之后再弹。** 第一轮把它放在打开弹窗
  // **之前**,SnackBar 从屏幕底部升起、而底部弹窗整块盖在它上面 —— 那 4 秒里用户
  // 一个字都看不见(复审用 hitTest 证明)。这句话只有在弹窗收起之后才真的"说出口"。
  final notice = expiredGrantNotice(purged);
  if (notice != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text(notice)));
  }
  if (action == null || !context.mounted) return;
  if (action.startsWith('member:')) {
    // action 里带的是**成员 id**,不是名字——名字可改、可重复,不能拿来寻址。
    final id = action.substring('member:'.length);
    if (id != currentId) {
      try {
        await doSwitch(id);
        onChanged?.call();
      } catch (e) {
        // 最常见是 [ProfileLocked](目标是个锁着的云档案);但
        // `switchProfileAndReopenImpl` 回退之后会 **rethrow 原始开箱错误**,所以
        // 别的失败(FFI 开箱失败、箱子坏了)也会到这里 —— 只接 `ProfileLocked`
        // 就等于"点了没反应,也没有任何提示"(评审 Important 7)。
        // `currentId` 已经被退回原成员了,这里只需要让用户知道发生了什么。
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(appSnackBar(content: Text(friendlyApiError(e))));
      }
    }
  }
}

/// 成员那一行的小字。**不写角色/到期日**(mockup:挑人的界面上不出现任何
/// 亲属/角色词,只留名字)——只读授权还剩多久这类信息挪到成员自己的页面里说
/// (`s10`,Task 13)。眼下唯一的小字是「正在恢复」。
///
/// 「正在恢复…点这里重试」是评审 Important 2 的可见出口:首同步没成功过的成员
/// (换机领回来的那些)原来只是静静地叫「正在恢复的档案」、0 份病历,用户没有任何
/// 办法让它再试一次,也不知道还能不能好。**点这一行就是重试** —— 切过去会
/// `bumpVaultRevision()`,后台触发器随即把 `sync_engine.pendingFirstSync` 排空。
Widget? _memberSubtitle(Profile m, TextStyle style) {
  if (pendingFirstSync.contains(m.id)) return Text('正在恢复…点这里重试', style: style);
  return null;
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
